CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE coordinate_frames (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    name text NOT NULL CHECK (length(btrim(name)) > 0),
    dimensions smallint NOT NULL CHECK (dimensions IN (2, 3)),
    units text NOT NULL CHECK (units IN ('metres', 'pixels')),
    metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),
    UNIQUE (actor_id, id)
);
CREATE TABLE world_entities (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    kind text NOT NULL CHECK (length(btrim(kind)) > 0),
    label text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(created_at)),
    UNIQUE (actor_id, id)
);
CREATE TABLE observations (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    entity_id uuid,
    frame_id uuid,
    occurred_at timestamptz CHECK (isfinite(occurred_at)),
    observed_at timestamptz NOT NULL CHECK (isfinite(observed_at)),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(recorded_at)),
    source_id text NOT NULL CHECK (length(btrim(source_id)) > 0 AND octet_length(source_id) <= 256 AND source_id !~ '[[:cntrl:]]'),
    confidence double precision NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    payload_version integer NOT NULL CHECK (payload_version > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    UNIQUE (actor_id, id),
    FOREIGN KEY (actor_id, entity_id) REFERENCES world_entities(actor_id, id),
    FOREIGN KEY (actor_id, frame_id) REFERENCES coordinate_frames(actor_id, id)
);
CREATE TABLE world_events (
    sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id uuid NOT NULL UNIQUE,
    actor_id uuid NOT NULL,
    stream_id uuid NOT NULL,
    stream_version bigint NOT NULL CHECK (stream_version > 0),
    idempotency_key text NOT NULL CHECK (length(btrim(idempotency_key)) > 0 AND octet_length(idempotency_key) <= 256),
    entity_ids uuid[] NOT NULL CHECK (array_ndims(entity_ids) = 1 AND cardinality(entity_ids) > 0 AND array_position(entity_ids, NULL) IS NULL),
    event_type text NOT NULL CHECK (length(btrim(event_type)) > 0),
    occurred_at timestamptz CHECK (isfinite(occurred_at)),
    observed_at timestamptz NOT NULL CHECK (isfinite(observed_at)),
    recorded_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(recorded_at)),
    source_id text NOT NULL CHECK (length(btrim(source_id)) > 0 AND octet_length(source_id) <= 256 AND source_id !~ '[[:cntrl:]]'),
    confidence double precision NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    payload_version integer NOT NULL CHECK (payload_version > 0),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    causation_id uuid,
    correlation_id uuid NOT NULL,
    UNIQUE (actor_id, sequence),
    UNIQUE (actor_id, event_id),
    UNIQUE (actor_id, stream_id, stream_version),
    UNIQUE (actor_id, stream_id, idempotency_key),
    FOREIGN KEY (actor_id, causation_id) REFERENCES world_events(actor_id, event_id)
);
-- These links enforce actor-scoped foreign keys for the immutable entity_ids.
-- They are derived automatically, not an independently editable event payload.
CREATE TABLE world_event_entities (
    actor_id uuid NOT NULL,
    event_id uuid NOT NULL,
    entity_id uuid NOT NULL,
    PRIMARY KEY (event_id, entity_id),
    FOREIGN KEY (actor_id, event_id) REFERENCES world_events(actor_id, event_id),
    FOREIGN KEY (actor_id, entity_id) REFERENCES world_entities(actor_id, id)
);
CREATE FUNCTION link_world_event_entities() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    INSERT INTO world_event_entities(actor_id, event_id, entity_id)
    SELECT NEW.actor_id, NEW.event_id, unnest(NEW.entity_ids);
    RETURN NEW;
END
$function$;
CREATE TRIGGER world_event_entity_links AFTER INSERT ON world_events
FOR EACH ROW EXECUTE FUNCTION link_world_event_entities();
CREATE FUNCTION validate_world_event_entity_link() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM world_events WHERE actor_id = NEW.actor_id
                   AND event_id = NEW.event_id AND NEW.entity_id = ANY(entity_ids)) THEN
        RAISE EXCEPTION 'Entity link must match the immutable event' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$function$;
CREATE TRIGGER world_event_entity_link_matches BEFORE INSERT ON world_event_entities
FOR EACH ROW EXECUTE FUNCTION validate_world_event_entity_link();
CREATE FUNCTION reject_world_journal_mutation() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION 'World journal is append-only' USING ERRCODE = '55000';
END
$function$;
CREATE TRIGGER world_journal_no_mutation BEFORE UPDATE OR DELETE ON world_events
FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER world_journal_no_truncate BEFORE TRUNCATE ON world_events
FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER world_links_no_mutation BEFORE UPDATE OR DELETE ON world_event_entities
FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER world_links_no_truncate BEFORE TRUNCATE ON world_event_entities
FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();

CREATE TABLE spatial_facts (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    subject_id uuid NOT NULL,
    predicate text NOT NULL CHECK (length(btrim(predicate)) > 0),
    object_id uuid NOT NULL,
    frame_id uuid NOT NULL,
    valid_from timestamptz NOT NULL CHECK (isfinite(valid_from)),
    valid_to timestamptz CHECK (valid_to IS NULL OR valid_to > valid_from) CHECK (isfinite(valid_to)),
    tx_from timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(tx_from)),
    tx_to timestamptz CHECK (tx_to IS NULL OR tx_to > tx_from) CHECK (isfinite(tx_to)),
    confidence double precision NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
    provenance_event_id uuid NOT NULL,
    FOREIGN KEY (actor_id, subject_id) REFERENCES world_entities(actor_id, id),
    FOREIGN KEY (actor_id, object_id) REFERENCES world_entities(actor_id, id),
    FOREIGN KEY (actor_id, frame_id) REFERENCES coordinate_frames(actor_id, id),
    FOREIGN KEY (actor_id, provenance_event_id) REFERENCES world_events(actor_id, event_id)
);
CREATE TABLE projection_versions (
    actor_id uuid NOT NULL,
    projection_name text NOT NULL CHECK (length(btrim(projection_name)) > 0),
    version integer NOT NULL CHECK (version > 0),
    last_sequence bigint CHECK (last_sequence > 0),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(updated_at)),
    PRIMARY KEY (actor_id, projection_name),
    FOREIGN KEY (actor_id, last_sequence) REFERENCES world_events(actor_id, sequence)
);
CREATE INDEX observations_actor_entity_time ON observations(actor_id, entity_id, observed_at, id);
CREATE INDEX world_events_actor_sequence ON world_events(actor_id, sequence);
CREATE INDEX world_events_occurrence ON world_events(actor_id, occurred_at, observed_at, sequence);
CREATE INDEX world_events_entities ON world_events USING gin(entity_ids);
CREATE INDEX spatial_facts_actor_subject ON spatial_facts(actor_id, subject_id, predicate);
CREATE INDEX spatial_facts_valid_time ON spatial_facts USING gist(tstzrange(valid_from, valid_to, '[)'));
CREATE INDEX spatial_facts_transaction_time ON spatial_facts USING gist(tstzrange(tx_from, tx_to, '[)'));
