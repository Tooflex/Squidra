\set ON_ERROR_STOP on
BEGIN;
INSERT INTO agent_runs(id,actor_id,trace_id) VALUES
('70000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000001'),
('70000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','80000000-0000-0000-0000-000000000002'),
('70000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000003');
DO $test$ BEGIN
    IF to_regclass('action_ledger') IS NULL OR to_regclass('approvals') IS NULL OR to_regclass('outbox') IS NULL THEN
        RAISE EXCEPTION 'Missing runtime tables';
    END IF;
    IF (SELECT active_budget_ms FROM agent_runs LIMIT 1)<>180000 THEN RAISE EXCEPTION 'Unexpected active budget'; END IF;
END $test$;
\echo SQUIDRA_TEST_PASS:runtime_tables

DO $test$ DECLARE first record; replay record; BEGIN
    SELECT * INTO first FROM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',
        'world.watch_entity','same-key','1.0.0','object:1','{"x":1}','["world:write","world:read","world:read"]',decode(repeat('11',32),'hex'));
    IF NOT first.created OR first.status<>'reserved' THEN RAISE EXCEPTION 'No fresh reservation'; END IF;
    UPDATE action_ledger SET status='succeeded', result='{"ok":true}', version=version+1 WHERE id=first.ledger_id;
    SELECT * INTO replay FROM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','1.0.0','object:1','{"x":1}','["world:read","world:write"]',decode(repeat('11',32),'hex'));
    IF replay.created OR replay.ledger_id<>first.ledger_id OR replay.result<>'{"ok":true}'::jsonb THEN
        RAISE EXCEPTION 'Replay changed the stored result';
    END IF;
    BEGIN UPDATE action_ledger SET result='{"ok":false}',version=version+1 WHERE id=first.ledger_id;
        RAISE EXCEPTION 'Final result changed'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN DELETE FROM action_ledger WHERE id=first.ledger_id;
        RAISE EXCEPTION 'Idempotency record deleted'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:ledger_replay

DO $test$ BEGIN
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','1.0.0','object:2','{"x":1}','["world:read","world:write"]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Changed target accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','2.0.0','object:1','{"x":1}','["world:read","world:write"]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Changed tool version accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','1.0.0','object:1','{"x":2}','["world:read","world:write"]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Changed arguments accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','1.0.0','object:1','{"x":1}','["admin:all"]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Changed scope accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','same-key','1.0.0','object:1','{"x":1}','["world:read","world:write"]',decode(repeat('22',32),'hex'));
        RAISE EXCEPTION 'Changed hash accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:ledger_conflict

DO $test$ DECLARE reservation record; BEGIN
    SELECT * INTO reservation FROM reserve_action('00000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000002',
        'world.watch_entity','same-key','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
    IF NOT reservation.created THEN RAISE EXCEPTION 'Actors collided on equal keys'; END IF;
    SELECT * INTO reservation FROM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.other_tool','same-key','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
    IF NOT reservation.created THEN RAISE EXCEPTION 'Tools collided on equal keys'; END IF;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000001',
        'world.watch_entity','cross-run','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Cross-actor run accepted'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.watch_entity','bad-scope','1.0.0','object:1','{}','[1]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Non-string capability accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:scoped_keys

DO $test$ DECLARE updated agent_runs; BEGIN
    SELECT * INTO updated FROM compare_and_set_run('00000000-0000-0000-0000-000000000001',
        '70000000-0000-0000-0000-000000000001',1,'VALIDATING',p_steps=>1,p_active_ms=>100);
    IF updated.version<>2 OR updated.step_count<>1 THEN RAISE EXCEPTION 'CAS did not advance exactly once'; END IF;
    BEGIN PERFORM compare_and_set_run('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',1,'PLANNING');
        RAISE EXCEPTION 'Stale version accepted'; EXCEPTION WHEN serialization_failure THEN NULL; END;
    BEGIN PERFORM compare_and_set_run('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',2,'PLANNING',p_steps=>0);
        RAISE EXCEPTION 'Budget counter regressed'; EXCEPTION WHEN check_violation THEN NULL; END;
    PERFORM compare_and_set_run('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',2,'FAILED',p_terminal_code=>'FIXTURE_FAILURE');
    BEGIN PERFORM compare_and_set_run('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',3,'PLANNING');
        RAISE EXCEPTION 'Terminal run resumed'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN PERFORM compare_and_set_run('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',1,'WAITING_APPROVAL',p_deadline=>now());
        RAISE EXCEPTION 'Active deadline retained while waiting'; EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',
        'world.watch_entity','new-terminal-action','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'New action reserved for terminal run'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:optimistic_runs

DO $test$ DECLARE reservation record; approval_id uuid:=gen_random_uuid(); BEGIN
    SELECT * INTO reservation FROM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
        'world.approval_fixture','approval','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
    INSERT INTO approvals(id,actor_id,run_id,ledger_id,command_hash,approval_digest,requested_at,expires_at)
    VALUES(approval_id,'00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',reservation.ledger_id,
        decode(repeat('11',32),'hex'),decode(repeat('33',32),'hex'),now()-interval '11 minutes',now()-interval '1 minute');
    BEGIN UPDATE approvals SET decision='approved',approver_id='00000000-0000-0000-0000-000000000001',decided_at=clock_timestamp(),version=version+1 WHERE id=approval_id;
        RAISE EXCEPTION 'Expired approval accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN UPDATE approvals SET approval_digest=decode(repeat('44',32),'hex'),version=version+1 WHERE id=approval_id;
        RAISE EXCEPTION 'Approval digest changed'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    UPDATE approvals SET decision='expired',decided_at=clock_timestamp(),version=version+1 WHERE id=approval_id;
    BEGIN UPDATE approvals SET decision='approved',version=version+1 WHERE id=approval_id;
        RAISE EXCEPTION 'Approval decision replayed'; EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN INSERT INTO approvals(actor_id,run_id,ledger_id,command_hash,approval_digest)
        VALUES('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',reservation.ledger_id,
            decode(repeat('99',32),'hex'),decode(repeat('33',32),'hex'));
        RAISE EXCEPTION 'Approval bound to different command'; EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:approval_constraints

DO $test$ BEGIN
    INSERT INTO outbox(actor_id,run_id,deduplication_key,payload)
    VALUES('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003','intention:event','{}');
    BEGIN INSERT INTO outbox(actor_id,run_id,deduplication_key,payload)
        VALUES('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003','intention:event','{}');
        RAISE EXCEPTION 'Outbox duplicate accepted'; EXCEPTION WHEN unique_violation THEN NULL; END;
    INSERT INTO outbox(actor_id,run_id,deduplication_key,payload)
    VALUES('00000000-0000-0000-0000-000000000002','70000000-0000-0000-0000-000000000002','intention:event','{}');
    BEGIN UPDATE outbox SET status='delivered' WHERE actor_id='00000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'Delivery without confirmation time'; EXCEPTION WHEN check_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:outbox_unique

DO $test$ BEGIN
    BEGIN
        PERFORM reserve_action('00000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000003',
            'world.rollback','rolled-back','1.0.0','object:1','{}','[]',decode(repeat('11',32),'hex'));
        RAISE EXCEPTION 'Force rollback' USING ERRCODE='23505';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    IF EXISTS(SELECT 1 FROM action_ledger WHERE idempotency_key='rolled-back') THEN
        RAISE EXCEPTION 'Reservation survived rollback';
    END IF;
END $test$;
\echo SQUIDRA_TEST_PASS:reservation_rollback
ROLLBACK;
