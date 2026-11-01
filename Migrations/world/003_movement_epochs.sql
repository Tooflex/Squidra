-- Sealed source epochs preserve contradictions, occlusions and unknown confidence.
CREATE TABLE movement_epochs (
    actor_id uuid NOT NULL,
    epoch_id uuid NOT NULL,
    entity_id uuid NOT NULL,
    state jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object' AND octet_length(state::text) <= 2097152),
    PRIMARY KEY (actor_id, epoch_id),
    FOREIGN KEY (actor_id, entity_id) REFERENCES world_entities(actor_id, id),
    CHECK (COALESCE(state->>'version' = '1', false)),
    CHECK (COALESCE(lower(state->>'actor') = actor_id::text, false)),
    CHECK (COALESCE(lower(state->>'entity') = entity_id::text, false)),
    CHECK (COALESCE(lower(state->>'epoch') = epoch_id::text, false))
);
CREATE TRIGGER movement_epoch_immutable BEFORE UPDATE OR DELETE ON movement_epochs
FOR EACH ROW EXECUTE FUNCTION reject_world_journal_mutation();
CREATE TRIGGER movement_epoch_no_truncate BEFORE TRUNCATE ON movement_epochs
FOR EACH STATEMENT EXECUTE FUNCTION reject_world_journal_mutation();
