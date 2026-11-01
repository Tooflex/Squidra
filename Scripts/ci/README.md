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
the lint gate below and final hosted checks are also required for #35. Do not
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
These rules do not substitute for lint or the separate secret gate below and
do not close #35 on their own.

## Tracked secret detection

Run `SQD-035-SECRET-CONTRACTS` then `SQD-035-SECRETS` through the issue runner.
Gitleaks 8.30.1 is pinned by its multi-architecture image digest and runs with
no network, a read-only root, no capabilities and bounded CPU/memory/time.
Only snapshots of Git-tracked files are supplied. Local keys, ignored build
artifacts and Git history are never mounted. Unsupported linked objects,
missing reports, scanner failures and inconsistent exit codes fail the gate.

The checked-in configuration explicitly extends the pinned built-in rules.
Repository-local override files, ignore fingerprints and inline allow comments
cannot disable scanning. No broad file/path exemption is introduced. Four
reviewed false positives are recorded in `secret-false-positives.json`: three
Swift key-length guards and one synthetic governance-test canary. Each exception
requires the exact rule, path, line AND SHA-256 of the entire file. Any edit to
that file invalidates its review. Unexpected findings in an unchanged file still
block. The report distinguishes these reviewed candidates from unresolved ones.

Gitleaks redacts 100% of values. The wrapper captures its raw streams and exports
only rule/path/line, counts, time and snapshot hash; it never prints matches,
secrets, entropy or source text. Temporary reports are deleted. An actual
unregistered token-shaped fixture must be detected despite inline/config/ignore
suppression attempts, and its value must not appear in the wrapper result.
Sequential placeholder tokens can be excluded by built-in detector rules; the
negative fixture therefore uses realistic entropy without being a credential.

This is current tracked-content detection using Gitleaks' built-in patterns and
allowlists. It is not a Git-history audit or proof that every encoded, binary,
archived or unknown-format secret can be detected. File/total snapshot bounds
fail instead of silently dropping oversized files. `.build/security/secrets.json`
is replaced with an explicit failure on errors, so stale success is not reported.

The manual-only job `Tracked secret scan` needs a real hosted run and actual
required-status registration at final CI restoration. The lint gate is described
below; CI restoration and issue #35 completion are still pending.

## Swift lint

Run `SQD-035-LINT-CONTRACTS` and `SQD-035-LINT` with SwiftLint 0.65.1 on PATH.
The Linux installer downloads the official ARM64 or AMD64 release archive,
verifies its fixed SHA-256 and installs only the named executable under `.build`.
It does not install system packages. Ubuntu needs `libcurl4t64`, `libstdc++6`
and `libxml2`; the CI setup explicitly supplies these prerequisites. The local
macOS qualification uses the same
SwiftLint version. The workflow has no automatic trigger during the CI pause.

Four explicit rules cover duplicate imports, redundant nil coalescing, unused
control-flow labels and unused optional bindings. They do not need SourceKit;
sourcekit loading and caching are disabled. No automatic formatting is applied.
The gate supplies isolated tracked production Swift snapshots and requires a
complete per-file progress count and summary, a matching JSON result, qualified
version and consistent exit status. Inline lint suppressions are rejected.
Diagnostics contain only rule/path/line. Tool failures replace the prior report
with a failure at `.build/security/swift-lint.json`.

Actual safe and four-rule negative fixtures verify that every configured rule
runs; malformed coverage, exit errors and suppression attempts must fail.
This is a documented correctness/idiom policy, not all available SwiftLint style
rules. The separate Swift syntax/SAST gate validates parsing.

The recovery task-group result is `ActionResult??`. SwiftLint flagged the former
`group.next() ?? nil` as redundant, but deleting it could change optional
flattening. Recovery now explicitly flattens one layer with `flatMap`; all seven
existing recovery unit tests pass, preserving successful and uncertain outcomes.

At final restoration, require `Swift lint` along with `Dependency analysis`,
`Swift static analysis` and `Tracked secret scan`, after actual hosted execution.
The existing Bootstrap build/contracts/integration/evaluation statuses also need
restoration. Local green results and checked-in workflow files do not establish
required-status configuration or hosted success. #35 remains open for that audit.

## Combined local Security gate

`bash Scripts/test-issue.sh SQD-035` runs all eight Security checks (four tools
and their contract suites), stops on failure and requires nonzero complete
results with no skipped/unexecuted tests. This covers the Security workflow.
The existing `python3 Scripts/check-local.py` separately covers Bootstrap
builds, contracts, database integration and offline evaluations. Both are
required for the final campaign audit; this aggregate does not claim Bootstrap
ran or that hosted required checks have been restored.

Linux ARM64 qualification used the checksummed upstream binary in Ubuntu 24.04
without a Swift compiler: all six lint contracts and 167 production files passed.
The initial minimal runtime lacked libxml2, which is now an explicit prerequisite
in the fixture Dockerfile and CI setup. AMD64 archive integrity is pinned, but
its hosted execution remains to be verified at final CI restoration.
