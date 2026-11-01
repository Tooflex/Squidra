CREATE TABLE read_run_tool_results (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    request_id uuid NOT NULL,
    call_id uuid NOT NULL,
    execution_version bigint NOT NULL CHECK(execution_version>0),
    command_fingerprint text NOT NULL CHECK(command_fingerprint ~ '^[0-9a-f]{64}$'),
    tool_identifier text NOT NULL CHECK(octet_length(tool_identifier) BETWEEN 1 AND 164),
    payload bytea NOT NULL CHECK(octet_length(payload) BETWEEN 2 AND 65536),
    PRIMARY KEY(actor_id,run_id),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    FOREIGN KEY(actor_id,run_id) REFERENCES read_run_tasks(actor_id,run_id)
);
CREATE TRIGGER read_run_tool_result_update BEFORE UPDATE ON read_run_tool_results FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
