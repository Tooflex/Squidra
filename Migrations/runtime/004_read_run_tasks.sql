-- Original task data is private recovery input, not a policy grant.
ALTER TABLE run_event_streams ADD CONSTRAINT run_stream_task_binding UNIQUE(actor_id,run_id,thread_id,request_id);
CREATE TABLE read_run_tasks (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    thread_id uuid NOT NULL,
    request_id uuid NOT NULL,
    task jsonb NOT NULL CHECK(jsonb_typeof(task)='object' AND octet_length(task::text)<=16384),
    PRIMARY KEY(actor_id,run_id),
    FOREIGN KEY(actor_id,run_id,thread_id,request_id) REFERENCES run_event_streams(actor_id,run_id,thread_id,request_id)
);
CREATE TRIGGER read_run_task_update BEFORE UPDATE ON read_run_tasks FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
