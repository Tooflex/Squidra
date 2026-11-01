-- Actor ownership domains outlive run retention; never silently reset them.
CREATE TABLE read_run_local_domains (
    actor_id uuid PRIMARY KEY,
    domain_id uuid NOT NULL,
    file_id text NOT NULL CHECK(file_id ~ '^[0-9]+:[0-9]+$' AND octet_length(file_id)<=64),
    UNIQUE(actor_id,domain_id,file_id)
);
CREATE TRIGGER read_run_domain_guard BEFORE UPDATE OR DELETE ON read_run_local_domains
    FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
CREATE TRIGGER read_run_domain_truncate BEFORE TRUNCATE ON read_run_local_domains
    FOR EACH STATEMENT EXECUTE FUNCTION reject_run_event_update();
CREATE TABLE read_run_owners (
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    domain_id uuid NOT NULL,
    file_id text NOT NULL,
    owner_id uuid NOT NULL,
    PRIMARY KEY(actor_id,run_id),
    FOREIGN KEY(actor_id,run_id) REFERENCES read_run_tasks(actor_id,run_id),
    FOREIGN KEY(actor_id,domain_id,file_id) REFERENCES read_run_local_domains(actor_id,domain_id,file_id)
);
CREATE TRIGGER read_run_owner_guard BEFORE UPDATE ON read_run_owners
    FOR EACH ROW EXECUTE FUNCTION reject_run_event_update();
CREATE INDEX read_run_previous_owners ON read_run_owners(actor_id,domain_id,file_id,run_id);
