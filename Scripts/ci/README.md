# Security gates — SQD-035

## Dependency analysis

Run both from the repository root with Docker available:

```sh
bash Scripts/test-issue.sh SQD-035-DEPENDENCY-CONTRACTS
bash Scripts/test-issue.sh SQD-035-DEPENDENCIES
```

The pinned OSV-Scanner 2.4.0 multi-architecture image analyzes `Package.resolved`
and `web/package-lock.json`. Its actual output covers SwiftURL and npm package
names and versions, including resolved transitive/optional/dev entries. The
wrapper independently builds inventories from both lockfiles and requires exact
multiset equality with `--all-packages` output. Missing, duplicate, substituted,
unsupported and empty inputs fail closed. Any advisory blocks the gate. An
execution, network, parser, coverage or cleanup error is an error, never a clean
scan. No vulnerability suppression configuration is copied into the scanner.

Only copies of the two lockfiles are mounted read-only. Source files, Git history,
local credentials, caches and unrelated projects are not mounted. Package metadata
is queried against OSV; this is a live vulnerability lookup, not an offline test.
The scanner has no privileged capabilities and runs with bounded CPU, memory and
time. Each owned container is removed by verified identity before a success marker.
The report at `.build/security/dependencies.json` records scanned-file hashes,
UTC check time, counts, advisory IDs and image digest; failure replaces an older
success report. It does not establish reachability, absence of unknown CVEs,
container OS security, or supply-chain authenticity.

The six contract tests include a real lookup of intentionally vulnerable
`lodash@4.17.20`; it must be reported as affected. No vulnerable dependency is
installed or executed. Deterministic cases verify inventory and exit-code error
handling. On 1 November 2026 the actual repository scan covered 28 Swift and 24 npm
entries with no advisories. This is dated evidence, not a permanent exemption.

OSV's public [supported-artifact documentation](https://google.github.io/osv-scanner/supported-languages-and-lockfiles/)
does not list every extractor, so support here is based on the pinned tool's
actual complete inventory, not an assumption from its documentation table.
[OSV-Scanner](https://github.com/google/osv-scanner) provides the upstream implementation.

## CI state and remaining work

`security.yml` is manual-only during the explicitly authorized CI suspension.
No hosted run has been claimed. At final restoration, add pull-request and push
triggers and require the `Dependency analysis` status in the actual repository
ruleset after a real runner execution. A workflow file does not change a ruleset.
Existing Bootstrap contracts, database integration and offline evaluations remain
in place, also paused. Swift-compatible SAST, lint, secret scanning and their
negative fixtures still need integration before #35 is complete. Do not treat
this dependency gate alone as completing #35 or reactivate CI early.
