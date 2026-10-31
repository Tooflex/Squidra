-- Existing streams stay unmanaged; do not infer successful runtime execution.
ALTER TABLE run_event_streams
    ADD COLUMN publication_phase text NOT NULL DEFAULT 'unmanaged'
        CHECK (publication_phase IN ('unmanaged','running','succeeded','failed','cancelled','recovery_required')),
    ADD COLUMN execution_owner uuid,
    ADD COLUMN execution_lease_until timestamptz,
    ADD CONSTRAINT publication_owner_shape CHECK (
        (publication_phase = 'unmanaged' AND execution_owner IS NULL AND execution_lease_until IS NULL)
        OR (publication_phase <> 'unmanaged' AND execution_owner IS NOT NULL AND execution_lease_until IS NOT NULL
            AND isfinite(execution_lease_until) AND execution_lease_until > created_at AND execution_lease_until <= expires_at)
    ),
    ADD CONSTRAINT publication_terminal_shape CHECK (
        publication_phase = 'unmanaged'
        OR (publication_phase = 'running' AND NOT is_terminal)
        OR (publication_phase IN ('succeeded','failed','cancelled','recovery_required') AND is_terminal)
    );
