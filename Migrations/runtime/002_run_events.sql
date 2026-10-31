-- Publication metadata may exist before a worker creates its runtime FSM row.
-- It authorizes no dispatch and carries no model/tool credentials or raw prompt.
CREATE TABLE run_event_streams (
    run_id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    request_id uuid NOT NULL,
    schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version = 1),
    protocol_version text NOT NULL DEFAULT '1.0' CHECK (protocol_version = '1.0'),
    next_sequence bigint NOT NULL DEFAULT 1 CHECK (next_sequence BETWEEN 1 AND 129),
    minimum_retained_sequence bigint NOT NULL DEFAULT 1 CHECK (minimum_retained_sequence BETWEEN 1 AND next_sequence),
    retained_bytes bigint NOT NULL DEFAULT 0 CHECK (retained_bytes BETWEEN 0 AND 1048576),
    is_terminal boolean NOT NULL DEFAULT false,
    retention_seconds integer NOT NULL CHECK (retention_seconds BETWEEN 1 AND 604800),
    created_at timestamptz NOT NULL CHECK (isfinite(created_at)),
    expires_at timestamptz NOT NULL CHECK (isfinite(expires_at) AND expires_at > created_at),
    UNIQUE (actor_id, run_id),
    CHECK (next_sequence < 129 OR is_terminal)
);
CREATE TABLE run_events (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    sequence bigint NOT NULL CHECK (sequence BETWEEN 1 AND 128),
    event_type text NOT NULL CHECK (event_type IN ('RUN_STARTED','RUN_FINISHED','RUN_ERROR','TEXT_MESSAGE_START','TEXT_MESSAGE_CONTENT','TEXT_MESSAGE_END','CUSTOM')),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 65536),
    PRIMARY KEY (actor_id, run_id, sequence),
    FOREIGN KEY (actor_id, run_id) REFERENCES run_event_streams(actor_id, run_id),
    CHECK (COALESCE(payload->>'type' = event_type, false)),
    CHECK (event_type NOT IN ('RUN_STARTED','RUN_FINISHED') OR COALESCE(payload->>'runId' = run_id::text, false)),
    CHECK (event_type <> 'CUSTOM' OR COALESCE(payload->>'name' = 'squidra.grounded_answer.v1' AND lower(payload#>>'{value,actorId}') = actor_id::text, false))
);
CREATE FUNCTION reject_run_event_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Run event payloads are immutable' USING ERRCODE = '55000';
END;
$$;
CREATE TRIGGER run_events_immutable_update BEFORE UPDATE ON run_events
FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
-- DELETE is intentionally available to a separately authorized retention purge.
-- Replay validates holes/counters and cannot use deletion to invent fresh history.
