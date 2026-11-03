-- Trusted administrator only. External decision and host quiescence are prerequisites.
CREATE TABLE account_database_erasure_receipts (
    actor_id uuid PRIMARY KEY,
    receipt_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    authority_digest text NOT NULL CHECK(authority_digest ~ '^[0-9a-f]{64}$'),
    transaction_id xid8 NOT NULL,
    complete boolean NOT NULL DEFAULT false
);
REVOKE ALL ON account_database_erasure_receipts FROM PUBLIC;
CREATE FUNCTION account_erasure_delete_allowed(actor uuid) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
    SELECT EXISTS(SELECT 1 FROM public.account_database_erasure_receipts
        WHERE actor_id=actor AND transaction_id=pg_current_xact_id_if_assigned() AND NOT complete)
$$;
CREATE FUNCTION protect_account_erasure_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP<>'UPDATE' THEN RAISE EXCEPTION 'Erasure receipt is retained' USING ERRCODE='55000'; END IF;
    IF OLD.complete OR NOT NEW.complete OR
       ROW(OLD.actor_id,OLD.receipt_id,OLD.authority_digest,OLD.transaction_id)
       IS DISTINCT FROM ROW(NEW.actor_id,NEW.receipt_id,NEW.authority_digest,NEW.transaction_id)
       OR OLD.transaction_id<>pg_current_xact_id_if_assigned()
    THEN RAISE EXCEPTION 'Invalid erasure receipt transition' USING ERRCODE='55000'; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER erasure_receipt_guard BEFORE UPDATE OR DELETE ON account_database_erasure_receipts
FOR EACH ROW EXECUTE FUNCTION protect_account_erasure_receipt();
CREATE TRIGGER erasure_receipt_truncate BEFORE TRUNCATE ON account_database_erasure_receipts
FOR EACH STATEMENT EXECUTE FUNCTION protect_account_erasure_receipt();

CREATE OR REPLACE FUNCTION reject_world_journal_mutation() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_LEVEL='ROW' AND TG_OP='DELETE' THEN
        IF public.account_erasure_delete_allowed(OLD.actor_id) THEN RETURN OLD; END IF;
    END IF;
    RAISE EXCEPTION 'World journal is append-only' USING ERRCODE = '55000';
END
$function$;

CREATE OR REPLACE FUNCTION reject_action_ledger_delete() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_LEVEL='ROW' AND TG_OP='DELETE' THEN
        IF public.account_erasure_delete_allowed(OLD.actor_id) THEN RETURN OLD; END IF;
    END IF;
    RAISE EXCEPTION 'Durable idempotency records cannot be deleted' USING ERRCODE='55000';
END $function$;

CREATE OR REPLACE FUNCTION reject_run_event_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_LEVEL='ROW' AND TG_OP='DELETE' THEN
        IF public.account_erasure_delete_allowed(OLD.actor_id) THEN RETURN OLD; END IF;
    END IF;
    RAISE EXCEPTION 'Run event payloads are immutable' USING ERRCODE = '55000';
END;
$$;

CREATE OR REPLACE FUNCTION protect_retained_media() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF TG_LEVEL='ROW' AND TG_OP='DELETE' THEN
        IF public.account_erasure_delete_allowed(OLD.actor_id) THEN RETURN OLD; END IF;
    END IF;
    IF TG_OP <> 'UPDATE' THEN
        RAISE EXCEPTION 'Media references cannot be removed' USING ERRCODE='55000';
    END IF;
    IF ROW(NEW.actor_id,NEW.frame_id,NEW.captured_us,NEW.expires_us,NEW.media_type,NEW.byte_count)
        IS DISTINCT FROM ROW(OLD.actor_id,OLD.frame_id,OLD.captured_us,OLD.expires_us,OLD.media_type,OLD.byte_count)
        OR OLD.blob IS NULL OR NEW.blob IS NOT NULL THEN
        RAISE EXCEPTION 'Only irreversible media unavailability is allowed' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END
$function$;

CREATE OR REPLACE FUNCTION guard_consolidation_journal() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_doc jsonb; new_doc jsonb;
BEGIN
    IF TG_LEVEL='ROW' AND TG_OP='DELETE' THEN
        IF public.account_erasure_delete_allowed(OLD.actor_id) THEN RETURN OLD; END IF;
    END IF;
    IF TG_OP='INSERT' THEN
        IF NEW.version<>0 THEN RAISE EXCEPTION 'consolidation requires genesis'; END IF;
        RETURN NEW;
    END IF;
    IF TG_OP<>'UPDATE' THEN RAISE EXCEPTION 'consolidation history is retained'; END IF;
    old_doc := OLD.archive::jsonb; new_doc := NEW.archive::jsonb;
    IF NEW.actor_id<>OLD.actor_id OR NEW.id<>OLD.id OR NEW.version<>OLD.version+1
        OR (new_doc-'commands') IS DISTINCT FROM (old_doc-'commands')
        OR ((new_doc->'commands')-(jsonb_array_length(new_doc->'commands')-1)) IS DISTINCT FROM (old_doc->'commands')
    THEN RAISE EXCEPTION 'consolidation history must append exactly one operation'; END IF;
    RETURN NEW;
END $$;

CREATE FUNCTION erase_fenced_account_rows(target_actor uuid, decision_digest text) RETURNS uuid
LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE tables text[] := ARRAY[
    'read_run_answers','read_run_tool_results','read_run_plans','read_run_completions',
    'read_run_owners','read_run_tasks','read_run_local_domains','run_events','run_event_streams',
    'outbox','approvals','action_ledger','agent_runs','consolidation_journals',
    'watch_notifications','watch_intentions','watch_dispatch_cursors','movement_epochs',
    'entity_associations','retained_media','projection_versions','spatial_facts',
    'world_event_entities','observations','world_events','world_entities','coordinate_frames'];
    actual text[]; expected text[]; table_name text; receipt uuid; blocked boolean;
BEGIN
    IF target_actor IS NULL OR decision_digest IS NULL OR decision_digest !~ '^[0-9a-f]{64}$' THEN
        RAISE EXCEPTION 'Invalid erasure request' USING ERRCODE='22023';
    END IF;
    SELECT array_agg(c.table_name::text ORDER BY c.table_name::text COLLATE "C") INTO actual
    FROM information_schema.columns c
    WHERE c.table_schema='public' AND c.column_name='actor_id'
      AND c.table_name NOT IN ('account_erasure_fences','account_database_erasure_receipts');
    SELECT array_agg(t ORDER BY t COLLATE "C") INTO expected FROM unnest(tables) t;
    IF actual IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'Actor table inventory changed; erasure refused' USING ERRCODE='55000';
    END IF;
    SELECT erased INTO blocked FROM public.account_erasure_fences WHERE actor_id=target_actor FOR UPDATE;
    IF blocked IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'Committed account fence required' USING ERRCODE='55000';
    END IF;
    SELECT receipt_id INTO receipt FROM public.account_database_erasure_receipts
      WHERE actor_id=target_actor AND complete;
    IF FOUND THEN RETURN receipt; END IF;
    INSERT INTO public.account_database_erasure_receipts(actor_id,authority_digest,transaction_id)
      VALUES(target_actor,decision_digest,pg_current_xact_id()) RETURNING receipt_id INTO receipt;
    FOREACH table_name IN ARRAY tables LOOP
        EXECUTE format('DELETE FROM public.%I WHERE actor_id=$1',table_name) USING target_actor;
    END LOOP;
    UPDATE public.account_database_erasure_receipts SET complete=true WHERE actor_id=target_actor;
    RETURN receipt;
END $$;
REVOKE ALL ON FUNCTION erase_fenced_account_rows(uuid,text) FROM PUBLIC;
