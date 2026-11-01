CREATE TABLE watch_dispatch_cursors (
    actor_id uuid PRIMARY KEY,
    last_sequence bigint NOT NULL CHECK (last_sequence>0),
    FOREIGN KEY(actor_id,last_sequence) REFERENCES world_events(actor_id,sequence)
);
CREATE FUNCTION protect_watch_cursor() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    IF NEW.actor_id<>OLD.actor_id OR NEW.last_sequence<OLD.last_sequence THEN
        RAISE EXCEPTION 'Watch cursor cannot change scope or regress' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $body$;
CREATE TRIGGER watch_cursor_update BEFORE UPDATE ON watch_dispatch_cursors FOR EACH ROW EXECUTE FUNCTION protect_watch_cursor();
CREATE TRIGGER watch_cursor_delete BEFORE DELETE ON watch_dispatch_cursors FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER watch_cursor_truncate BEFORE TRUNCATE ON watch_dispatch_cursors FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();
