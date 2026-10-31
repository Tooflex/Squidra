-- Mutable association cache. Immutable world evidence is never rewritten here.
CREATE TABLE entity_associations (
    actor_id uuid NOT NULL,
    camera_id uuid NOT NULL,
    revision bigint NOT NULL CHECK (revision > 0),
    schema_version integer NOT NULL CHECK (schema_version = 1),
    state jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object' AND octet_length(state::text) <= 262144),
    PRIMARY KEY (actor_id, camera_id),
    CHECK (COALESCE(state->>'schemaVersion' = '1', false)),
    CHECK (COALESCE(state->>'revision' = revision::text, false)),
    CHECK (COALESCE(state->>'actorID' = actor_id::text, false)),
    CHECK (COALESCE(state->>'cameraID' = camera_id::text, false)),
    CHECK (state ?& ARRAY['schemaVersion','revision','actorID','cameraID'])
);
