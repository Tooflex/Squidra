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
in place, also paused. The targeted Swift SAST gate below is integrated locally;
lint and secret scanning still need integration before #35 is complete. Do not
treat either component as completing #35 or reactivate CI early.

## Swift static analysis

Install Swift 6.4.2 and Semgrep CE 1.180.0 and run `SQD-035-SWIFT-SAST-CONTRACTS` followed by
`SQD-035-SWIFT-SAST` through `Scripts/test-issue.sh`. The native analyzer runs
locally on snapshots of every tracked `Sources/**/*.swift` file; exact coverage
is required. Before scanning, Swift 6.4.2 parses those same snapshots without
typechecking or linking. This is necessary because Semgrep can recover some
malformed Swift without reporting errors. Missing files, parser errors, unknown findings, ignored findings,
wrong analyzer versions and inconsistent exit statuses fail. Neither Git ignore
rules nor inline `nosemgrep` comments can suppress this gate. Telemetry, version
checks and remote rule retrieval are disabled. No account login is used.

Three checked-in Swift AST rules reject calls to `Insecure.MD5.hash`,
`Insecure.SHA1.hash` and `SecTrustSetExceptions`. This is targeted detection of
weak hash APIs and certificate-trust exceptions, not a full security audit,
interprocedural analysis or a claim to detect all equivalent wrappers/aliases.
Framework-specific Pro rules are not silently assumed to work in CE; see the
[upstream Swift coverage documentation](https://docs.semgrep.dev/languages/swift).
The actual analyzer must detect all three negative fixtures (including an inline
suppression attempt), while a SHA256 fixture and an MD5 call inside a comment
must pass. The report records analyzer version, source hashes and UTC time;
findings contain only rule, path and line, never source snippets. Failure replaces
any prior success report at `.build/security/swift-sast.json`.

The manual-only Security workflow includes `Swift static analysis`. This job
must receive an actual hosted execution and required-status configuration when
CI is finally restored. Local qualification does not establish hosted success.
Lint and secret scanning remain outstanding; these rules do not substitute for
either gate or close #35 on their own.
