#!/usr/bin/env bash
# Isolated Squidra development database; never resets a VM or deletes data volumes.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
if [[ -n "${SQUIDRA_CONTAINER_ENGINE:-}" ]]; then
  container_engine="$SQUIDRA_CONTAINER_ENGINE"
elif command -v docker >/dev/null 2>&1; then
  container_engine=docker
elif command -v podman >/dev/null 2>&1; then
  container_engine=podman
else
  echo 'Docker or Podman is required; no database check was executed.' >&2; exit 2
fi
db_image=localhost/squidra-postgres:17-postgis3.6.4-vector0.8.7
db_container="${SQUIDRA_DB_CONTAINER:-squidra-dev-db}"
[[ "$db_container" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]] || exit 2

assert_owned() {
  local purpose
  purpose="$("$container_engine" inspect --format '{{index .Config.Labels "io.squidra.database"}}' "$db_container")"
  [[ "$purpose" == development || "$purpose" == test ]] || { echo 'Refusing an unrelated container' >&2; exit 2; }
}
sql() {
  "$container_engine" exec -i "$db_container" psql -X -q -v ON_ERROR_STOP=1 --username squidra --dbname squidra
}
scalar() {
  "$container_engine" exec -i "$db_container" psql -X -A -t -q -v ON_ERROR_STOP=1 --username squidra --dbname squidra
}
ready() {
  for _ in {1..60}; do
    if "$container_engine" exec "$db_container" pg_isready -U squidra -d squidra >/dev/null 2>&1; then return; fi
    sleep 1
  done
  echo 'Database readiness timed out' >&2; exit 1
}
write_credentials() {
  python3 - "$1" <<'PY'
from pathlib import Path
import os,secrets,sys
p=Path(sys.argv[1]);p.touch(mode=0o600,exist_ok=True);os.chmod(p,0o600)
p.write_text('POSTGRES_DB=squidra\nPOSTGRES_USER=squidra\nPOSTGRES_PASSWORD='+secrets.token_urlsafe(32)+'\n')
PY
}
apply_migrations() {
  assert_owned
  python3 - "${1:-$repo_root/Migrations}" <<'PY' | sql
import hashlib,re,sys
from pathlib import Path
root=Path(sys.argv[1])
print(r'\set ON_ERROR_STOP on')
print("BEGIN; SET LOCAL TIME ZONE 'UTC';")
print("SELECT pg_advisory_xact_lock(1936818034)\n\\g /dev/null")
print('CREATE TABLE IF NOT EXISTS squidra_schema_migrations(namespace text NOT NULL, version text NOT NULL, checksum text NOT NULL CHECK (checksum ~ \'^[0-9a-f]{64}$\'), applied_at timestamptz NOT NULL DEFAULT clock_timestamp(), PRIMARY KEY(namespace,version));')
for namespace in ['world','runtime']:
 for p in sorted((root/namespace).glob('*.sql')):
  if not re.fullmatch(r'[0-9]{3}_[a-z0-9_]+\.sql',p.name):raise ValueError('Invalid migration filename')
  checksum=hashlib.sha256(p.read_bytes()).hexdigest()
  where=f"namespace='{namespace}' AND version='{p.name}'"
  print(f"SELECT EXISTS(SELECT 1 FROM squidra_schema_migrations WHERE {where}) AS applied, EXISTS(SELECT 1 FROM squidra_schema_migrations WHERE {where} AND checksum<>'{checksum}') AS mismatch \\gset")
  print(r'\if :mismatch')
  print(r'\echo Migration checksum mismatch; refusing to modify the database')
  print("DO $checksum_guard$ BEGIN RAISE EXCEPTION 'Migration checksum mismatch'; END $checksum_guard$;")
  print(r'\endif')
  print(r'\if :applied')
  print(r'\else')
  print(p.read_text())
  print(f"INSERT INTO squidra_schema_migrations(namespace,version,checksum) VALUES('{namespace}','{p.name}','{checksum}');")
  print(r'\endif')
print('COMMIT;')
PY
}

case "${1:-}" in
  build)
    "$container_engine" build -f infra/postgres.Dockerfile -t "$db_image" infra ;;
  up|up-local)
    if [[ "$1" == up-local ]]; then
      db_container="${SQUIDRA_DB_CONTAINER:-squidra-dev-db-local}"
      local_port="${SQUIDRA_DB_LOCAL_PORT:-5432}"
      [[ "$local_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$local_port >= 1 && 10#$local_port <= 65535 )) || exit 2
      local_port=$((10#$local_port))
      credentials="$repo_root/infra/.env.squidra-db-local"
      volume=squidra-postgres-local-data
      network_args=(--publish "127.0.0.1:$local_port:5432")
    else
      credentials="$repo_root/infra/.env.squidra-db"
      volume=squidra-postgres-data
      network_args=(--network none)
    fi
    if "$container_engine" inspect "$db_container" >/dev/null 2>&1; then
      assert_owned; "$container_engine" start "$db_container" >/dev/null
    else
      [[ -f "$credentials" ]] || write_credentials "$credentials"
      "$container_engine" run -d --name "$db_container" --label io.squidra.database=development \
        "${network_args[@]}" --env-file "$credentials" -v "$volume":/var/lib/postgresql/data "$db_image" >/dev/null
    fi
    binding="$("$container_engine" port "$db_container")"
    if [[ "$1" == up-local ]]; then
      [[ "$binding" == "5432/tcp -> 127.0.0.1:$local_port" ]] || { echo 'Unexpected development port binding' >&2; exit 1; }
    else
      [[ -z "$binding" ]] || { echo 'Isolated development mode cannot use a published port' >&2; exit 1; }
    fi
    ready; apply_migrations
    if [[ "$1" == up-local ]]; then echo "Squidra local database ready on 127.0.0.1:$local_port."
    else echo 'Squidra development database ready; no host port is published.'; fi ;;
  migrate)
    ready; apply_migrations ;;
  down)
    assert_owned; "$container_engine" rm -f "$db_container" >/dev/null
    echo 'Container removed; development data volume retained.' ;;
  test-run-recovery|test-client|test-server|test-run-store|test-ledger|test-approvals|test-journal|test-projection|test-changes|test-world-tools|test-read-runs|test-recovery|test-restart|test-run-events|test-run-publication|test-run-workers|test-run-http|test-associations|test-frame-ingestion|test-tracing)
    # Explicit integration-only exception: ephemeral TCP port on loopback, never 0.0.0.0.
    db_container="squidra-client-test-$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
    credentials="$(mktemp)"; created=false
    cleanup() {
      if [[ "$created" == true ]]; then "$container_engine" rm -f "$db_container" >/dev/null 2>&1 || true; fi
      rm -f "$credentials"
    }
    trap cleanup EXIT
    write_credentials "$credentials"
    "$container_engine" run -d --name "$db_container" --label io.squidra.database=test \
      --publish 127.0.0.1::5432 --env-file "$credentials" \
      --tmpfs /var/lib/postgresql/data:rw,nosuid,size=1g "$db_image" >/dev/null
    created=true; ready
    binding="$("$container_engine" port "$db_container" 5432/tcp)"
    [[ "$binding" =~ ^127\.0\.0\.1:([0-9]+)$ ]] || { echo 'Client test port is not exclusively loopback' >&2; exit 1; }
    test_port="${BASH_REMATCH[1]}"
    # A ready container is insufficient when a VM's host port forwarding fails.
    python3 - "$test_port" <<'PY'
import socket,sys,time
deadline=time.monotonic()+10
while True:
  try:
    with socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=1):
      break
  except OSError:
    if time.monotonic()>=deadline:
      sys.exit('Test database is ready inside Docker but its host loopback port is unreachable. Check VM port forwarding; see docs/development.md.')
    time.sleep(0.1)
PY
    echo 'SQUIDRA_TEST_PASS:client_loopback_boundary'
    apply_migrations
    if [[ "$1" == test-restart ]]; then
      python3 Scripts/run-restart-tests.py "$credentials" "$test_port"
    elif [[ "$1" == test-recovery ]]; then
      bash Scripts/test-issue.sh SQD-025-UNIT
      echo 'SQUIDRA_TEST_PASS:projection_recovery_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-025-RECOVERY-SWIFT
      echo 'SQUIDRA_TEST_PASS:durable_projection_recovery'
    elif [[ "$1" == test-read-runs ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T14-SQL-SWIFT
      echo 'SQUIDRA_TEST_PASS:durable_grounded_read_runs'
    elif [[ "$1" == test-run-http ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T05-HTTP-SWIFT
      echo 'SQUIDRA_TEST_PASS:authenticated_bounded_run_transport'
    elif [[ "$1" == test-run-workers ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T05-WORKERS-SWIFT
      echo 'SQUIDRA_TEST_PASS:owned_bounded_read_workers'
    elif [[ "$1" == test-run-publication ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T05-PUBLICATION-SWIFT
      echo 'SQUIDRA_TEST_PASS:single_owner_terminal_publication'
    elif [[ "$1" == test-run-events ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T05-SQL-SWIFT
      echo 'SQUIDRA_TEST_PASS:durable_scoped_run_replay'
    elif [[ "$1" == test-associations ]]; then
      apply_migrations
      echo 'SQUIDRA_TEST_PASS:repeatable_association_migration'
      bash Scripts/test-issue.sh SQD-021-UNIT
      echo 'SQUIDRA_TEST_PASS:association_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-021-SQL-SWIFT
      echo 'SQUIDRA_TEST_PASS:durable_association_cas'
    elif [[ "$1" == test-frame-ingestion ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-020-PUBLISH-SWIFT
      echo 'SQUIDRA_TEST_PASS:durable_frame_grounded_answers'
    elif [[ "$1" == test-tracing ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-030-SQL-SWIFT
      echo 'SQUIDRA_TEST_PASS:private_trace_postgres_sources'
    elif [[ "$1" == test-world-tools ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" T13-READS-SQL
      echo 'SQUIDRA_TEST_PASS:gateway_postgres_evidence'
    elif [[ "$1" == test-changes ]]; then
      bash Scripts/test-issue.sh SQD-015-UNIT
      echo 'SQUIDRA_TEST_PASS:bounded_change_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-015-SQL
      echo 'SQUIDRA_TEST_PASS:stable_change_evidence'
    elif [[ "$1" == test-projection ]]; then
      bash Scripts/test-issue.sh SQD-014-UNIT
      echo 'SQUIDRA_TEST_PASS:bitemporal_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-014-SQL
      echo 'SQUIDRA_TEST_PASS:durable_bitemporal_state'
    elif [[ "$1" == test-journal ]]; then
      bash Scripts/test-issue.sh SQD-016-UNIT
      echo 'SQUIDRA_TEST_PASS:journal_rebuild_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-016-SQL
      echo 'SQUIDRA_TEST_PASS:durable_journal_snapshot'
    elif [[ "$1" == test-approvals ]]; then
      bash Scripts/test-issue.sh SQD-009-UNIT
      echo 'SQUIDRA_TEST_PASS:approval_contracts'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-009-SQL
      echo 'SQUIDRA_TEST_PASS:durable_approvals'
    elif [[ "$1" == test-run-recovery ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-028-SQL
      echo 'SQUIDRA_TEST_PASS:durable_run_recovery'
    elif [[ "$1" == test-ledger ]]; then
      bash Scripts/test-issue.sh SQD-007-UNIT
      echo 'SQUIDRA_TEST_PASS:canonical_fingerprints'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-007-SQL
      echo 'SQUIDRA_TEST_PASS:swift_action_ledger'
    elif [[ "$1" == test-run-store ]]; then
      bash Scripts/test-issue.sh SQD-005-UNIT
      echo 'SQUIDRA_TEST_PASS:host_fsm_budgets'
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-005-SQL
      echo 'SQUIDRA_TEST_PASS:durable_run_store'
    elif [[ "$1" == test-server ]]; then
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port" SQD-001-SWIFT "$container_engine" "$db_container"
      echo 'SQUIDRA_TEST_PASS:swift_server_integration'
    else
      python3 Scripts/run-db-client-tests.py "$credentials" "$test_port"
      echo 'SQUIDRA_TEST_PASS:swift_client_integration'
    fi
    ;;
  test|test-runtime)
    db_container="squidra-test-$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
    credentials="$(mktemp)"; failure_root="$(mktemp -d)"; created=false
    cleanup() {
      if [[ "$created" == true ]]; then "$container_engine" rm -f "$db_container" >/dev/null 2>&1 || true; fi
      rm -f "$credentials"; rm -rf "$failure_root"
    }
    trap cleanup EXIT
    write_credentials "$credentials"
    "$container_engine" run -d --name "$db_container" --label io.squidra.database=test \
      --network none --env-file "$credentials" --tmpfs /var/lib/postgresql/data:rw,nosuid,size=1g "$db_image" >/dev/null
    created=true; ready
    [[ -z "$("$container_engine" port "$db_container")" ]] || { echo 'Test database published a host port' >&2; exit 1; }
    echo 'SQUIDRA_TEST_PASS:network_boundary'
    apply_migrations
    before="$(printf '%s\n' "SELECT string_agg(namespace||version||checksum||applied_at::text,',' ORDER BY namespace,version) FROM squidra_schema_migrations;" | scalar)"
    apply_migrations
    after="$(printf '%s\n' "SELECT string_agg(namespace||version||checksum||applied_at::text,',' ORDER BY namespace,version) FROM squidra_schema_migrations;" | scalar)"
    [[ "$before" == "$after" ]] || { echo 'Migration rerun changed metadata' >&2; exit 1; }
    echo 'SQUIDRA_TEST_PASS:repeatable_migration'
    real_checksum="$(python3 -c 'import hashlib;print(hashlib.sha256(open("Migrations/world/001_world.sql","rb").read()).hexdigest())')"
    printf '%s\n' "UPDATE squidra_schema_migrations SET checksum=repeat('0',64) WHERE namespace='world' AND version='001_world.sql';" | sql
    set +e; apply_migrations > "$failure_root/checksum.log" 2>&1; result=$?; set -e
    [[ "$result" == 3 ]] || { cat "$failure_root/checksum.log" >&2; echo 'Checksum mismatch was not rejected' >&2; exit 1; }
    printf '%s\n' "UPDATE squidra_schema_migrations SET checksum='$real_checksum' WHERE namespace='world' AND version='001_world.sql';" | sql
    echo 'SQUIDRA_TEST_PASS:checksum_guard'
    python3 - "$failure_root" <<'PY'
from pathlib import Path
import shutil,sys
root=Path(sys.argv[1]);shutil.copytree('Migrations/world',root/'world')
(root/'world/999_forced_failure.sql').write_text('CREATE TABLE rollback_probe(id integer); SELECT 1/0;')
PY
    set +e; apply_migrations "$failure_root" > "$failure_root/rollback.log" 2>&1; result=$?; set -e
    [[ "$result" == 3 ]] || { cat "$failure_root/rollback.log" >&2; echo 'Failed migration was not rejected' >&2; exit 1; }
    intact="$(printf '%s\n' "SELECT to_regclass('rollback_probe') IS NULL AND NOT EXISTS(SELECT 1 FROM squidra_schema_migrations WHERE version='999_forced_failure.sql');" | scalar)"
    [[ "$intact" == t ]] || { echo 'Failed migration left changes behind' >&2; exit 1; }
    echo 'SQUIDRA_TEST_PASS:transactional_rollback'
    sql < Tests/SquidraPostgresTests/world.sql
    if [[ "$1" == test-runtime ]]; then
      sql < Tests/SquidraPostgresTests/runtime.sql
      python3 Tests/SquidraPostgresTests/concurrency.py "$container_engine" "$db_container"
    fi
    ;;
  *) echo 'Usage: Scripts/dev-db.sh build|up|up-local|migrate|test|test-runtime|test-run-recovery|test-client|test-server|test-run-store|test-ledger|test-approvals|test-journal|test-projection|test-changes|test-world-tools|test-read-runs|test-recovery|test-restart|test-run-events|test-run-publication|test-run-workers|test-run-http|test-associations|test-frame-ingestion|test-tracing|down' >&2; exit 2 ;;
esac
