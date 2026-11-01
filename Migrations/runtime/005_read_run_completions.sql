-- Private grounded result, saved before the FSM commits COMPLETED. This archive
-- alone never proves that a run completed or authorizes publication.
CREATE TABLE read_run_completions (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    request_id uuid NOT NULL,
    responding_version bigint NOT NULL CHECK(responding_version>0),
    answer bytea NOT NULL CHECK(octet_length(answer) BETWEEN 2 AND 65536),
    PRIMARY KEY(actor_id,run_id),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    FOREIGN KEY(actor_id,run_id) REFERENCES read_run_tasks(actor_id,run_id)
);
CREATE TRIGGER read_run_completion_update BEFORE UPDATE ON read_run_completions FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
