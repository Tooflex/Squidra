-- Bound the background scan to actor-owned running publications by lease order.
CREATE INDEX run_publication_recovery ON run_event_streams(actor_id,execution_lease_until,run_id)
    WHERE publication_phase='running';
