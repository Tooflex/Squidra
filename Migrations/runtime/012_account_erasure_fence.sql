-- Trusted-host erasure admission fence. Does not itself delete account data.
CREATE TABLE account_erasure_fences (
    actor_id uuid PRIMARY KEY,
    erased boolean NOT NULL DEFAULT false
);
CREATE FUNCTION protect_account_erasure_fence() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP IN ('DELETE','TRUNCATE') THEN
        RAISE EXCEPTION 'Account erasure fences cannot be removed' USING ERRCODE='55000';
    END IF;
    IF NEW.actor_id IS DISTINCT FROM OLD.actor_id OR (OLD.erased AND NOT NEW.erased) THEN
        RAISE EXCEPTION 'Account erasure is irreversible' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER account_erasure_fence_guard BEFORE UPDATE OR DELETE ON account_erasure_fences
FOR EACH ROW EXECUTE FUNCTION protect_account_erasure_fence();
CREATE TRIGGER account_erasure_fence_truncate BEFORE TRUNCATE ON account_erasure_fences
FOR EACH STATEMENT EXECUTE FUNCTION protect_account_erasure_fence();

CREATE FUNCTION admit_account_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE blocked boolean;
BEGIN
    IF TG_OP='UPDATE' AND NEW.actor_id IS DISTINCT FROM OLD.actor_id THEN
        RAISE EXCEPTION 'Actor reassignment is forbidden' USING ERRCODE='55000';
    END IF;
    -- An actual row update serializes with fencing even under stale RR snapshots:
    -- PostgreSQL either sees the latest fence or raises serialization failure.
    INSERT INTO public.account_erasure_fences(actor_id) VALUES(NEW.actor_id)
    ON CONFLICT(actor_id) DO UPDATE SET actor_id=EXCLUDED.actor_id
    RETURNING erased INTO blocked;
    IF blocked THEN
        RAISE EXCEPTION 'Account is fenced for erasure' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION fence_account_for_erasure(target_actor uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO public.account_erasure_fences(actor_id,erased) VALUES(target_actor,true)
    ON CONFLICT(actor_id) DO UPDATE SET erased=true;
END $$;
-- Only the migration owner/trusted administration may initiate erasure.
REVOKE ALL ON FUNCTION fence_account_for_erasure(uuid) FROM PUBLIC;
REVOKE ALL ON account_erasure_fences FROM PUBLIC;

DO $$
DECLARE table_name text;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'coordinate_frames','world_entities','observations','world_events',
        'world_event_entities','spatial_facts','projection_versions',
        'entity_associations','movement_epochs','watch_intentions',
        'watch_notifications','watch_dispatch_cursors','retained_media',
        'agent_runs','action_ledger','approvals','outbox','run_event_streams',
        'run_events','read_run_tasks','read_run_completions','read_run_plans',
        'read_run_tool_results','read_run_answers','read_run_local_domains',
        'read_run_owners','consolidation_journals'
    ] LOOP
        EXECUTE format('CREATE TRIGGER account_write_admission BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION admit_account_write()',table_name);
    END LOOP;
END $$;
