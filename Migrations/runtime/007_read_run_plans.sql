CREATE TABLE read_run_plans (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    request_id uuid NOT NULL,
    planning_version bigint NOT NULL CHECK(planning_version>0),
    archive bytea NOT NULL CHECK(octet_length(archive) BETWEEN 2 AND 65536),
    PRIMARY KEY(actor_id,run_id),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    FOREIGN KEY(actor_id,run_id) REFERENCES read_run_tasks(actor_id,run_id)
);
CREATE TRIGGER read_run_plan_update BEFORE UPDATE ON read_run_plans FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
