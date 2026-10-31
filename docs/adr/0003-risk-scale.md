# ADR-003: Authoritative risk scale R0–R4

- Status: **Accepted** (maintainer approval, 2026-10-31)
- Date: 2026-10-29
- Sources: SRS §6 (+ P-02/P-03, NFR-10); SDD §9 (+ §4.3 pipeline)
- Implements: T00 executable task 1 (risks)

## Context

SRS §6 fixes an authoritative 5-level scale:

| Level | Example (SRS) | Default policy (SRS) |
|---|---|---|
| R0 | Bounded local read (authorized event) | Allowed with valid scope |
| R1 | Reversible mutation (move file in workspace) | Allowed only with explicit capability |
| R2 | External communication (send mail / publish / share) | **Mandatory human approval** |
| R3 | Destructive mutation (delete files / overwrite data) | **Mandatory human approval** |
| R4 | Finance / rights (payment, permissions, secrets) | Mandatory approval + additional controls |

SDD §9 proposes a 4-class scale: L0 read, L1 reversible, L2 sensitive
(e.g. modifying a user file → approval *per policy*), L3 critical
(payment, deletion, external message → mandatory explicit human
approval).

## Decision

1. **R0–R4 is the sole authoritative scale.** Every `ToolDefinition`
   carries an SRS risk level; policy evaluation, approval routing and
   audit all record it.
2. **L→R mapping** (for reading SDD text and classifying tools):

| SDD class | Maps to | Rule |
|---|---|---|
| L0 read | R0 | State reads within a valid scope |
| L1 reversible | R1 | Workspace-local reversible effects; explicit capability still required |
| L2 sensitive | R1 or R2 by effect | Local reversible → R1; externally visible or sensitive → R2 |
| L3 critical | R2 / R3 / R4 by effect | External message → R2; deletion/destruction → R3; payment, permission or secret operation → R4 |

3. **No waiver by policy.** Policy may *add* approval where the SRS
   allows execution (R0/R1), but may never *remove* approval where the
   SRS requires it: **every R2 external communication requires human
   approval**, even where an SDD example or policy default might suggest
   otherwise. R4 additionally requires the extra controls of its tool
   definition.
4. **Approval binds the exact command** (SRS §6 + SDD §9): the decision
   references a canonical hash of (actor, tool, version, target,
   parameters, scope, expiration). Any change invalidates it; policy is
   revalidated after approval and immediately before effects
   (NFR-10).

## Consequences

- SQD-008 (gateway/policy) and SQD-009 (approvals) implement R-levels;
  SDD L-classes appear nowhere in code or schemas except this mapping.
- Tool onboarding must classify effects honestly: "sensitive" is not a
  level — its R-level is decided by reversibility and external
  visibility.
- SDD §9's "approval per policy" for L2 cannot legalize unapproved R2+
  effects.

## Verification

- `POLICY-008` style tests: allow/deny/fail-closed matrix per R-level;
  forged R2-without-approval attempt rejected; mutated-argument approval
  invalidated; sub-agent privilege-escalation attempt denied (SRS §6).
