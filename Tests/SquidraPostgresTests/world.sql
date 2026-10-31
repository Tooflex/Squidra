\set ON_ERROR_STOP on
BEGIN;
DO $test$ BEGIN
    IF (SELECT extversion FROM pg_extension WHERE extname = 'postgis') <> '3.6.4'
       OR (SELECT extversion FROM pg_extension WHERE extname = 'vector') <> '0.8.7'
       OR current_setting('server_version_num')::integer <> 170011 THEN
        RAISE EXCEPTION 'Unexpected database or extension version';
    END IF;
    IF ST_AsText(ST_GeomFromText('POINT(1 2)')) <> 'POINT(1 2)'
       OR ('[1,2,3]'::vector <-> '[1,2,3]'::vector) <> 0 THEN
        RAISE EXCEPTION 'Extensions do not execute correctly';
    END IF;
END $test$;
\echo SQUIDRA_TEST_PASS:extensions

INSERT INTO coordinate_frames(id, actor_id, name, dimensions, units)
VALUES ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','desk',3,'metres');
INSERT INTO world_entities(id, actor_id, kind) VALUES
('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','object'),
('20000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001','object'),
('20000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000002','object');
INSERT INTO observations(id, actor_id, entity_id, frame_id, occurred_at, observed_at, source_id, confidence, payload_version, payload)
VALUES ('30000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',
'20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',NULL,'2026-10-01T00:00:00Z','fixture',0.9,1,'{}');
DO $test$ BEGIN
    IF (SELECT occurred_at FROM observations WHERE id = '30000000-0000-0000-0000-000000000001') IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown occurrence was replaced';
    END IF;
    IF to_regclass('projection_versions') IS NULL THEN RAISE EXCEPTION 'Missing projection versions'; END IF;
END $test$;
\echo SQUIDRA_TEST_PASS:tables

DO $test$ DECLARE invalid double precision; BEGIN
    FOREACH invalid IN ARRAY ARRAY[-0.1, 1.1, 'NaN'::double precision, 'Infinity'::double precision] LOOP
        BEGIN
            INSERT INTO observations(id, actor_id, observed_at, source_id, confidence, payload_version, payload)
            VALUES (gen_random_uuid(),'00000000-0000-0000-0000-000000000001',now(),'fixture',invalid,1,'{}');
            RAISE EXCEPTION 'Invalid confidence accepted';
        EXCEPTION WHEN check_violation THEN NULL; END;
    END LOOP;
END $test$;
\echo SQUIDRA_TEST_PASS:confidence

INSERT INTO world_events(event_id, actor_id, stream_id, stream_version, idempotency_key, entity_ids,
    event_type, occurred_at, observed_at, source_id, confidence, payload_version, payload, correlation_id)
VALUES ('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',
'20000000-0000-0000-0000-000000000001',1,'event-1',ARRAY['20000000-0000-0000-0000-000000000001'::uuid],
'observed','2026-10-02T00:00:00Z','2026-10-02T00:00:00Z','fixture',0.9,1,'{}','50000000-0000-0000-0000-000000000001'),
('40000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',
'20000000-0000-0000-0000-000000000001',2,'event-2',ARRAY['20000000-0000-0000-0000-000000000001'::uuid],
'corrected','2026-10-01T00:00:00Z','2026-10-03T00:00:00Z','fixture',0.8,1,'{}','50000000-0000-0000-0000-000000000001');
INSERT INTO spatial_facts(id, actor_id, subject_id, predicate, object_id, frame_id,
    valid_from, valid_to, confidence, provenance_event_id)
VALUES ('60000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',
'20000000-0000-0000-0000-000000000001','next_to','20000000-0000-0000-0000-000000000002',
'10000000-0000-0000-0000-000000000001','2026-10-01T00:00:00Z','2026-10-02T00:00:00Z',0.9,'40000000-0000-0000-0000-000000000001');
DO $test$ DECLARE fact spatial_facts; BEGIN
    SELECT * INTO fact FROM spatial_facts LIMIT 1;
    IF NOT tstzrange(fact.valid_from,fact.valid_to,'[)') @> fact.valid_from
       OR tstzrange(fact.valid_from,fact.valid_to,'[)') @> fact.valid_to THEN
        RAISE EXCEPTION 'Invalid interval inclusivity';
    END IF;
    BEGIN UPDATE spatial_facts SET valid_to=valid_from; RAISE EXCEPTION 'Empty stored fact accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN UPDATE spatial_facts SET tx_to=tx_from; RAISE EXCEPTION 'Empty transactional version accepted';
    EXCEPTION WHEN check_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:intervals

DO $test$ BEGIN
    BEGIN
        INSERT INTO observations(id,actor_id,entity_id,observed_at,source_id,confidence,payload_version,payload)
        VALUES(gen_random_uuid(),'00000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000003',now(),'fixture',1,1,'{}');
        RAISE EXCEPTION 'Cross-actor foreign key accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL; END;
    BEGIN
        INSERT INTO world_event_entities(actor_id,event_id,entity_id)
        VALUES('00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000002');
        RAISE EXCEPTION 'Entity added to immutable event';
    EXCEPTION WHEN check_violation THEN NULL; END;
    BEGIN DELETE FROM world_entities WHERE id='20000000-0000-0000-0000-000000000001';
        RAISE EXCEPTION 'Referenced entity deleted';
    EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:foreign_keys

DO $test$ BEGIN
    BEGIN UPDATE world_events SET source_id='changed'; RAISE EXCEPTION 'Journal update accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN DELETE FROM world_events; RAISE EXCEPTION 'Journal delete accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN TRUNCATE world_events CASCADE; RAISE EXCEPTION 'Journal truncate accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
    BEGIN DELETE FROM world_event_entities; RAISE EXCEPTION 'Event link delete accepted';
    EXCEPTION WHEN object_not_in_prerequisite_state THEN NULL; END;
END $test$;
\echo SQUIDRA_TEST_PASS:journal_immutable

DO $test$ DECLARE first_seq bigint; next_seq bigint; BEGIN
    SELECT sequence INTO first_seq FROM world_events ORDER BY sequence LIMIT 1;
    SELECT sequence INTO next_seq FROM world_events WHERE sequence>first_seq ORDER BY sequence LIMIT 1;
    IF next_seq IS NULL OR next_seq <= first_seq THEN RAISE EXCEPTION 'Unstable journal pagination'; END IF;
    IF (SELECT event_id FROM world_events ORDER BY sequence LIMIT 1) <> '40000000-0000-0000-0000-000000000001' THEN
        RAISE EXCEPTION 'Late event reordered journal';
    END IF;
    INSERT INTO projection_versions(actor_id,projection_name,version,last_sequence)
    VALUES('00000000-0000-0000-0000-000000000001','world',1,next_seq);
END $test$;
\echo SQUIDRA_TEST_PASS:pagination
ROLLBACK;
