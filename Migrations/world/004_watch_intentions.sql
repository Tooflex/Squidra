CREATE TABLE watch_intentions (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    entity_id uuid NOT NULL,
    request_key text NOT NULL CHECK (length(btrim(request_key))>0 AND octet_length(request_key)<=128),
    after_sequence bigint NOT NULL CHECK (after_sequence>=0),
    status text NOT NULL CHECK (status IN ('active','cancelled','fulfilled')),
    UNIQUE(actor_id,id),
    UNIQUE(actor_id,request_key),
    FOREIGN KEY(actor_id,entity_id) REFERENCES world_entities(actor_id,id)
);
CREATE FUNCTION protect_watch_intention() RETURNS trigger LANGUAGE plpgsql AS $body$
BEGIN
    IF ROW(NEW.id,NEW.actor_id,NEW.entity_id,NEW.request_key,NEW.after_sequence)
        IS DISTINCT FROM ROW(OLD.id,OLD.actor_id,OLD.entity_id,OLD.request_key,OLD.after_sequence)
        OR OLD.status<>'active' OR NEW.status NOT IN ('cancelled','fulfilled') THEN
        RAISE EXCEPTION 'Watch binding or terminal state is immutable' USING ERRCODE='55000';
    END IF;
    RETURN NEW;
END $body$;
CREATE TRIGGER watch_update BEFORE UPDATE ON watch_intentions FOR EACH ROW EXECUTE FUNCTION protect_watch_intention();
CREATE TRIGGER watch_delete BEFORE DELETE ON watch_intentions FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER watch_truncate BEFORE TRUNCATE ON watch_intentions FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TABLE watch_notifications (
    actor_id uuid NOT NULL,
    intention_id uuid NOT NULL,
    source_event_id uuid NOT NULL,
    notification_event_id uuid NOT NULL,
    PRIMARY KEY(actor_id,intention_id,source_event_id),
    UNIQUE(actor_id,intention_id),
    FOREIGN KEY(actor_id,intention_id) REFERENCES watch_intentions(actor_id,id),
    FOREIGN KEY(actor_id,source_event_id) REFERENCES world_events(actor_id,event_id),
    FOREIGN KEY(actor_id,notification_event_id) REFERENCES world_events(actor_id,event_id)
);
CREATE TRIGGER watch_notification_immutable BEFORE UPDATE OR DELETE ON watch_notifications FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER watch_notification_truncate BEFORE TRUNCATE ON watch_notifications FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();
CREATE INDEX watch_active_entity ON watch_intentions(actor_id,entity_id) WHERE status='active';
