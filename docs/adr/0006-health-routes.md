# ADR-006: Health and readiness routes

- Status: **Proposed** (T00; awaits human contract review)
- Date: 2026-10-29
- Sources: SRS SQD-001 + §9; SDD §10
- Implements: T00 executable task 1 (health routes)

## Context

SRS SQD-001 requires `API /health et /ready` (also "API
health/readiness", SRS §9). SDD §10 specifies `GET /health/live → 200`
(process) and `GET /health/ready → 200/503` (dependencies).

## Decision

1. **Canonical routes are the SDD pair**, served by the Hummingbird
   composition root:
   - `GET /health/live` — liveness. Always 200 when the process serves
     HTTP. Minimal body, no dependency checks, no secrets.
   - `GET /health/ready` — readiness. 200 when the database is
     reachable, migrations are current, and every service required by
     the active profile is available; otherwise 503. Minimal body
     naming only the failing dependency class (never credentials or
     connection strings).
2. **SRS aliases are served permanently**: `GET /health` behaves as
   `/health/live`, `GET /ready` behaves as `/health/ready`. Aliases
   exist for SRS/SQD-001 compatibility and are covered by the same
   tests.
3. **Readiness scope is profile-required services only** (database,
   migrations, services the profile needs). Optional integrations —
   model providers, vision backends — never gate readiness; their
   absence is reported through capability/degradation endpoints and
   telemetry instead (SRS P-10; SDD §10 200/503 contract).
4. **Bodies are minimal and versioned.** Live: `{"status":"alive"}`;
   ready: `{"status":"ready"}` / 503 `{"status":"not_ready", …}`.
   Additive fields require the API versioning rules of ADR-007
   (NFR-08).

## Consequences

- SQD-001 acceptance (`/health`, `/ready`) is satisfied via aliases
  while operators standardize on the `/health/*` pair.
- Load-balancer liveness checks use `/health/live` (cheap, no DB
  load); deploy gates use `/health/ready`.
- T04 wires authentication so probes stay usable by orchestrators
  without exposing protected data.

## Verification

- `IT-BOOT-001` style tests: all four routes; ready 503 with database
  down and 200 after migrate; live stays 200 throughout; unavailable
  model provider does not flip readiness; response bodies contain no
  secrets.
