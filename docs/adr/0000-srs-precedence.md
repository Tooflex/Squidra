# ADR-000: SRS precedence and change control

- Status: **Accepted** (maintainer approval, 2026-10-31)
- Date: 2026-10-29
- Sources: SRS v1.0 status line; SDD v0.1 §0 header + p.1 companion note

## Context

Two source documents govern SQUIDRA and disagree on several contracts:

- The SRS (v1.0, 29 Oct 2026) declares itself the *"proposition de
  référence"* (reference proposal) and defines 35 user stories plus
  normative principles (P-01–P-10), tool contracts (FR-TOOL-01–05) and
  NFRs.
- The SDD (v0.1, 29 Oct 2026) declares itself a *"proposition technique à
  valider"* (technical proposal to validate) and states: *"Le SRS définit
  le QUOI ; ce SDD décrit le COMMENT, sans modifier les 35 stories
  SQD-001 à SQD-035"* — the SRS defines the WHAT, the SDD the HOW,
  without modifying the 35 stories (SDD p.1).

Known discrepancies span run budgets, FSM granularity, the risk scale,
idempotency-key scope, Swift port names and health routes (see
[README](README.md) mapping table).

## Decision

1. **The SRS takes precedence.** Where SRS and SDD conflict, the SRS
   requirement is mandatory and the SDD text is treated as a proposal to
   be reconciled, never as an override.
2. **Reconciliation is explicit.** Every discrepancy is resolved by a repo
   ADR in `docs/adr/` (this series) recording the SRS rule, the SDD
   proposal, the frozen decision and its consequences. No silent
   deviation in code, schemas or migrations.
3. **Changes go through ADRs.** After T00, any change to a frozen
   contract requires a new ADR (or a superseding ADR revision) reviewed
   by the maintainer before implementation. Affected issues must
   reference the ADR.

## Consequences

- ADR-001–ADR-008 freeze the T00 contract surface; downstream issues
  (T01 onward) implement against these ADRs, not directly against the
  PDFs.
- Stricter-than-SRS behaviour is allowed only where an ADR says so
  (e.g. SDD detail adopted as internal substate in ADR-002); weaker
  behaviour is never allowed.
- SDD §14 `ADR-001`–`ADR-010` remain SDD-internal rationale. Citations
  must disambiguate them from this repo series (see README numbering
  note).

## Verification

Maintainer document review (T00 evidence `ADR-000`): source links,
decision table and administrative checklist in the
[README](README.md). No application test exists at this stage, and none
is simulated.
