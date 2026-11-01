-- Private consolidation evidence is retained; no delete or replacement API.
CREATE TABLE consolidation_journals (
    actor_id uuid NOT NULL,
    id uuid NOT NULL,
    version bigint NOT NULL CHECK(version BETWEEN 0 AND 512),
    archive text NOT NULL CHECK(octet_length(archive) BETWEEN 1 AND 2097152),
    PRIMARY KEY(actor_id,id),
    CHECK(coalesce((archive::jsonb->>'schemaVersion')::integer=1,false)),
    CHECK(coalesce(lower(archive::jsonb->>'actorID')=actor_id::text,false)),
    CHECK(coalesce(lower(archive::jsonb->>'id')=id::text,false)),
    CHECK(coalesce(jsonb_typeof(archive::jsonb->'commands')='array',false)),
    CHECK(coalesce(jsonb_array_length(archive::jsonb->'commands')=version,false))
);
CREATE FUNCTION guard_consolidation_journal() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_doc jsonb; new_doc jsonb;
BEGIN
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
CREATE TRIGGER consolidation_journal_guard BEFORE INSERT OR UPDATE OR DELETE ON consolidation_journals
    FOR EACH ROW EXECUTE FUNCTION guard_consolidation_journal();
CREATE TRIGGER consolidation_journal_truncate BEFORE TRUNCATE ON consolidation_journals
    FOR EACH STATEMENT EXECUTE FUNCTION reject_run_event_update();
