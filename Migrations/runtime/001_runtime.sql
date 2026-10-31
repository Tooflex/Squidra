CREATE TABLE agent_runs (
    id uuid PRIMARY KEY,
    actor_id uuid NOT NULL,
    state text NOT NULL DEFAULT 'CREATED' CHECK (state IN ('CREATED','VALIDATING','CONTEXT_LOADING','PLANNING','WAITING_APPROVAL','EXECUTING_TOOL','RESPONDING','COMPLETED','FAILED','CANCELLED','TIMED_OUT','BUDGET_EXCEEDED')),
    substate text,
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    step_count integer NOT NULL DEFAULT 0 CHECK (step_count >= 0),
    tool_call_count integer NOT NULL DEFAULT 0 CHECK (tool_call_count >= 0),
    active_elapsed_ms bigint NOT NULL DEFAULT 0 CHECK (active_elapsed_ms >= 0),
    active_budget_ms bigint NOT NULL DEFAULT 180000 CHECK (active_budget_ms > 0),
    checkpoint jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(checkpoint) = 'object'),
    trace_id uuid NOT NULL,
    deadline timestamptz CHECK (isfinite(deadline)),
    terminal_code text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(created_at)),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(updated_at)),
    UNIQUE (actor_id, id),
    CHECK (state <> 'WAITING_APPROVAL' OR deadline IS NULL),
    CHECK (state IN ('COMPLETED','FAILED','CANCELLED','TIMED_OUT','BUDGET_EXCEEDED') OR terminal_code IS NULL)
);
CREATE FUNCTION protect_agent_run() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF OLD.state IN ('COMPLETED','FAILED','CANCELLED','TIMED_OUT','BUDGET_EXCEEDED') THEN
        RAISE EXCEPTION 'Terminal run cannot be changed' USING ERRCODE='55000';
    END IF;
    IF ROW(NEW.id,NEW.actor_id,NEW.trace_id,NEW.created_at) IS DISTINCT FROM ROW(OLD.id,OLD.actor_id,OLD.trace_id,OLD.created_at)
       OR NEW.version <> OLD.version + 1 OR NEW.step_count < OLD.step_count
       OR NEW.tool_call_count < OLD.tool_call_count OR NEW.active_elapsed_ms < OLD.active_elapsed_ms THEN
        RAISE EXCEPTION 'Invalid run version or immutable metadata' USING ERRCODE='23514';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END $function$;
CREATE TRIGGER protect_agent_run_update BEFORE UPDATE ON agent_runs FOR EACH ROW EXECUTE FUNCTION protect_agent_run();
CREATE FUNCTION compare_and_set_run(p_actor uuid, p_run uuid, p_expected_version bigint, p_state text,
    p_checkpoint jsonb DEFAULT NULL, p_terminal_code text DEFAULT NULL, p_deadline timestamptz DEFAULT NULL,
    p_steps integer DEFAULT NULL, p_calls integer DEFAULT NULL, p_active_ms bigint DEFAULT NULL)
RETURNS agent_runs LANGUAGE plpgsql AS $function$
DECLARE current_run agent_runs;
BEGIN
    SELECT * INTO current_run FROM agent_runs WHERE actor_id=p_actor AND id=p_run FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Run not found' USING ERRCODE='P0002'; END IF;
    IF current_run.version <> p_expected_version THEN
        RAISE EXCEPTION 'Run version conflict' USING ERRCODE='40001';
    END IF;
    UPDATE agent_runs SET state=p_state, checkpoint=coalesce(p_checkpoint,current_run.checkpoint),
        terminal_code=p_terminal_code, deadline=p_deadline, version=current_run.version+1,
        step_count=coalesce(p_steps,current_run.step_count), tool_call_count=coalesce(p_calls,current_run.tool_call_count),
        active_elapsed_ms=coalesce(p_active_ms,current_run.active_elapsed_ms)
    WHERE actor_id=p_actor AND id=p_run RETURNING * INTO current_run;
    RETURN current_run;
END $function$;

CREATE FUNCTION normalize_action_scope(p_scope jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE STRICT AS $function$
    SELECT CASE WHEN jsonb_typeof(p_scope)='array' THEN
        (SELECT coalesce(jsonb_agg(value ORDER BY value),'[]'::jsonb)
         FROM (SELECT DISTINCT value FROM jsonb_array_elements(p_scope)) AS entries)
    ELSE NULL END
$function$;
CREATE TABLE action_ledger (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    tool_name text NOT NULL CHECK (tool_name ~ '^[a-z][a-z0-9_.]{0,127}$'),
    tool_version text NOT NULL CHECK (length(btrim(tool_version)) > 0),
    idempotency_key text NOT NULL CHECK (length(btrim(idempotency_key)) > 0 AND octet_length(idempotency_key) <= 256),
    target text NOT NULL CHECK (length(btrim(target)) > 0),
    arguments jsonb NOT NULL CHECK (jsonb_typeof(arguments)='object'),
    scope jsonb NOT NULL CHECK (jsonb_typeof(scope)='array') CHECK (jsonb_array_length(scope)<=256)
        CHECK (NOT jsonb_path_exists(scope,'$[*] ? (@.type() != "string")'))
        CHECK (scope=normalize_action_scope(scope)),
    command_hash bytea NOT NULL CHECK (octet_length(command_hash)=32),
    status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved','pending','succeeded','failed','unknown')),
    result jsonb CHECK (jsonb_typeof(result)='object'),
    provider_reference text,
    version bigint NOT NULL DEFAULT 1 CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(created_at)),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(updated_at)),
    UNIQUE(actor_id,tool_name,idempotency_key),
    UNIQUE(actor_id,id),
    UNIQUE(actor_id,id,command_hash),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    CHECK ((status IN ('succeeded','failed')) = (result IS NOT NULL))
);
CREATE FUNCTION protect_action_ledger() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF ROW(NEW.id,NEW.actor_id,NEW.run_id,NEW.tool_name,NEW.tool_version,NEW.idempotency_key,NEW.target,
           NEW.arguments,NEW.scope,NEW.command_hash,NEW.created_at)
       IS DISTINCT FROM ROW(OLD.id,OLD.actor_id,OLD.run_id,OLD.tool_name,OLD.tool_version,OLD.idempotency_key,OLD.target,
           OLD.arguments,OLD.scope,OLD.command_hash,OLD.created_at) THEN
        RAISE EXCEPTION 'Action command is immutable' USING ERRCODE='55000';
    END IF;
    IF OLD.status IN ('succeeded','failed') THEN
        RAISE EXCEPTION 'Final action result is immutable' USING ERRCODE='55000';
    END IF;
    IF NEW.version <> OLD.version+1 THEN RAISE EXCEPTION 'Action version conflict' USING ERRCODE='40001'; END IF;
    IF NEW.status='reserved' AND OLD.status<>'reserved' THEN
        RAISE EXCEPTION 'Reconciliation cannot reset a reservation' USING ERRCODE='55000';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END $function$;
CREATE TRIGGER protect_action_update BEFORE UPDATE ON action_ledger FOR EACH ROW EXECUTE FUNCTION protect_action_ledger();
CREATE FUNCTION reject_action_ledger_delete() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    RAISE EXCEPTION 'Durable idempotency records cannot be deleted' USING ERRCODE='55000';
END $function$;
CREATE TRIGGER action_ledger_no_delete BEFORE DELETE ON action_ledger
FOR EACH ROW EXECUTE FUNCTION reject_action_ledger_delete();
CREATE TRIGGER action_ledger_no_truncate BEFORE TRUNCATE ON action_ledger
FOR EACH STATEMENT EXECUTE FUNCTION reject_action_ledger_delete();
CREATE FUNCTION reserve_action(p_actor uuid,p_run uuid,p_tool text,p_key text,p_tool_version text,
    p_target text,p_arguments jsonb,p_scope jsonb,p_command_hash bytea)
RETURNS TABLE(ledger_id uuid,created boolean,status text,result jsonb,version bigint)
LANGUAGE plpgsql AS $function$
DECLARE reserved_id uuid; existing action_ledger; canonical_scope jsonb;
BEGIN
    PERFORM 1 FROM agent_runs WHERE actor_id=p_actor AND id=p_run FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Run not found in actor scope' USING ERRCODE='23503'; END IF;
    canonical_scope := normalize_action_scope(p_scope);
    INSERT INTO action_ledger(actor_id,run_id,tool_name,idempotency_key,tool_version,target,arguments,scope,command_hash)
    VALUES(p_actor,p_run,p_tool,p_key,p_tool_version,p_target,p_arguments,canonical_scope,p_command_hash)
    ON CONFLICT(actor_id,tool_name,idempotency_key) DO NOTHING RETURNING id INTO reserved_id;
    IF reserved_id IS NOT NULL THEN
        SELECT * INTO existing FROM action_ledger WHERE id=reserved_id;
        IF (SELECT state FROM agent_runs WHERE actor_id=p_actor AND id=p_run) IN ('COMPLETED','FAILED','CANCELLED','TIMED_OUT','BUDGET_EXCEEDED') THEN
            RAISE EXCEPTION 'Cannot reserve a new action for a terminal run' USING ERRCODE='55000';
        END IF;
    ELSE
        SELECT * INTO existing FROM action_ledger AS ledger
        WHERE ledger.actor_id=p_actor AND ledger.tool_name=p_tool AND ledger.idempotency_key=p_key FOR UPDATE;
        IF NOT FOUND THEN RAISE EXCEPTION 'Reservation changed concurrently' USING ERRCODE='40001'; END IF;
        IF existing.command_hash IS DISTINCT FROM p_command_hash OR existing.tool_version IS DISTINCT FROM p_tool_version
           OR existing.target IS DISTINCT FROM p_target OR existing.arguments IS DISTINCT FROM p_arguments
           OR existing.scope IS DISTINCT FROM canonical_scope THEN
            RAISE EXCEPTION 'Idempotency key reused for a different command' USING ERRCODE='23505';
        END IF;
    END IF;
    RETURN QUERY SELECT existing.id,reserved_id IS NOT NULL,existing.status,existing.result,existing.version;
END $function$;

CREATE TABLE approvals (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid NOT NULL,
    run_id uuid NOT NULL,
    ledger_id uuid NOT NULL,
    command_hash bytea NOT NULL CHECK (octet_length(command_hash)=32),
    approval_digest bytea NOT NULL CHECK (octet_length(approval_digest)=32),
    decision text NOT NULL DEFAULT 'pending' CHECK (decision IN ('pending','approved','denied','expired','withdrawn')),
    approver_id uuid,
    requested_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(requested_at)),
    expires_at timestamptz NOT NULL DEFAULT (clock_timestamp()+interval '10 minutes') CHECK (isfinite(expires_at)),
    decided_at timestamptz CHECK (isfinite(decided_at)),
    version bigint NOT NULL DEFAULT 1 CHECK (version>0),
    UNIQUE(actor_id,id),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    FOREIGN KEY(actor_id,ledger_id,command_hash) REFERENCES action_ledger(actor_id,id,command_hash),
    CHECK (expires_at>requested_at),
    CHECK ((decision='pending' AND decided_at IS NULL AND approver_id IS NULL)
        OR (decision<>'pending' AND decided_at IS NOT NULL)),
    CHECK (decision NOT IN ('approved','denied','withdrawn') OR approver_id IS NOT NULL),
    CHECK (decision<>'approved' OR decided_at<expires_at)
);
CREATE FUNCTION protect_approval() RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF ROW(NEW.id,NEW.actor_id,NEW.run_id,NEW.ledger_id,NEW.command_hash,NEW.approval_digest,NEW.requested_at,NEW.expires_at)
       IS DISTINCT FROM ROW(OLD.id,OLD.actor_id,OLD.run_id,OLD.ledger_id,OLD.command_hash,OLD.approval_digest,OLD.requested_at,OLD.expires_at)
       OR OLD.decision<>'pending' THEN
        RAISE EXCEPTION 'Approval binding or decision is immutable' USING ERRCODE='55000';
    END IF;
    IF NEW.version<>OLD.version+1 THEN RAISE EXCEPTION 'Approval version conflict' USING ERRCODE='40001'; END IF;
    RETURN NEW;
END $function$;
CREATE TRIGGER protect_approval_update BEFORE UPDATE ON approvals FOR EACH ROW EXECUTE FUNCTION protect_approval();

CREATE TABLE outbox (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id uuid NOT NULL,
    run_id uuid,
    ledger_id uuid,
    deduplication_key text NOT NULL CHECK (length(btrim(deduplication_key))>0 AND octet_length(deduplication_key)<=512),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload)='object'),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','delivering','delivered','failed')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts>=0),
    available_at timestamptz NOT NULL DEFAULT clock_timestamp() CHECK (isfinite(available_at)),
    delivered_at timestamptz CHECK (isfinite(delivered_at)),
    UNIQUE(actor_id,deduplication_key),
    FOREIGN KEY(actor_id,run_id) REFERENCES agent_runs(actor_id,id),
    FOREIGN KEY(actor_id,ledger_id) REFERENCES action_ledger(actor_id,id),
    CHECK ((status='delivered')=(delivered_at IS NOT NULL))
);
CREATE INDEX agent_runs_actor_state ON agent_runs(actor_id,state);
CREATE INDEX action_ledger_reconciliation ON action_ledger(actor_id,updated_at) WHERE status IN ('pending','unknown');
CREATE INDEX approvals_pending_expiry ON approvals(expires_at) WHERE decision='pending';
CREATE INDEX outbox_pending_delivery ON outbox(available_at,id) WHERE status IN ('pending','failed');
