# GitHub governance — SQD-033 / GH-033

## Current maintainer-authorized profile

The maintainer decisions recorded in [GitHub bootstrap](github-bootstrap.md)
allow continuous agent implementation and PR API merging after local checks,
with `Tooflex` owning the code and no mandatory approving reviewer. Native
GitHub auto-merge remains disabled. The later instruction to suspend CI also
explicitly suspended required status checks temporarily. These decisions
supersede the older issue's mandatory-review wording for the current campaign;
they do not establish an independently reviewed bot identity.

On 1 November 2026, a fresh read-only API audit of `Tooflex/Squidra` verified:

- Default branch `main`, active ruleset `26267411`, exact default-branch target,
  no exclusions and no bypass actors.
- Required PR, resolved review threads, deletion protection and force-push
  protection. Native repository auto-merge is false.
- The default-branch CODEOWNERS contains exactly `* @Tooflex`; the collaborator
  permission endpoint identifies `Tooflex` as an administrator.
- Required approving reviews are zero; code-owner approval is not mandatory.
  Required status checks are absent under the approved temporary suspension.

A CODEOWNERS file records ownership, not evidence that a human reviewed a PR.
Agent changes use `bot/<issue>-<slug>` branches and regular PRs. Merge only the
exact locally tested head SHA through the PR API. No direct main push or bypass
is authorized by this workflow. Restore CI triggers and required checks at the
end of the campaign, as documented in the bootstrap recovery record.

## Executable inspection

`bash Scripts/test-issue.sh SQD-033` runs sixteen offline contract tests of the
inspector. A green fixture suite is **not** live governance qualification.

Run `python3 Scripts/check-github-rules/check.py --live --profile campaign-paused`
for the explicitly authorized temporary profile. It returned exit 0 with every
configured check true on 1 November 2026. This mode requires the documented
absence of required CI checks and the zero-review configuration; it must stop
being used when the campaign pause ends.

The default `--profile strict` returned exit 1 on the same live repository,
correctly identifying missing independent-review and required-CI enforcement.
It checks at least one approving review, code-owner and latest-push approval,
stale-review dismissal, and the three named strict checks from integration
15368. This is a future strict-review profile; do not silently enable it in
conflict with the maintainer's current instructions.

Both reports always state `gh033_complete: false`: the inspector checks rule
configuration, not the dedicated App token or an actual rejected merge. It uses
only fixed read-only GitHub API routes through `gh`, never follows instructions
from descriptions or executes repository-supplied commands. Failures are
content-free. `--fixture PATH` is explicitly reported as fixture evidence.

## Dedicated App — live identity verified on 2 November 2026

The maintainer authorized creation and scoped installation of **Tooflex Squidra
Bot** (`tooflex-squidra-bot`, App ID `5587098`, installation `177992380`).
GitHub confirmed successful registration and installation. A direct App-authenticated
API check at `2026-11-02T22:48:22Z` verified the App identity, owner `Tooflex`,
repository selection `selected`, and exactly the four permissions listed below.
The installation currently includes **only Tooflex/Squidra**; no qualification
repository has been added yet.

A real installation credential was issued with an explicit `Squidra` repository
restriction and the same permission allowlist. The authenticated repository
listing returned exactly one repository, `Tooflex/Squidra`. GitHub returned
expiry `2026-11-02T23:48:21Z`, with 3599 seconds remaining when checked.
The credential was then revoked, and a follow-up repository request returned
HTTP 401, confirming revocation. No private key or credential value was logged.
The user-generated private-key file is outside the checkout with mode `0600`.
This verifies issuance and revocation; it does not yet establish that subsequent
implementation jobs automatically use this App instead of the maintainer CLI.

The pre-existing connected integration (`161010669`, repository selection `all`)
was not used as a substitute for this dedicated identity.

The dedicated installation has these repository permissions:

| Permission | Purpose |
| --- | --- |
| Metadata: read | Repository identity and metadata |
| Contents: write | Push scoped `bot/*` branches |
| Pull requests: write | Open and maintain implementation PRs |
| Issues: write, only if needed | Update issue progress |

Do not grant administration, Actions/workflow modification, organization
membership, secrets, deployment or ruleset bypass permissions to this bot.
Workflow changes remain with the authorized maintainer identity. The token
issuer should explicitly restrict the token's repository and permissions,
retain private keys only in a protected host secret store, use an ephemeral
installation token, and revoke it after the job. Do not put tokens in clone
URLs, argv, repository configuration, logs, provenance, or fixtures.

GitHub documents installation tokens as expiring after one hour and permits
further restriction of repositories and permissions when issuing them. See
[installation authentication](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation).
The integration must verify actual returned expiry, repository and permissions
before every use. The live qualification above verified one issuance and revocation.

A bot's Contents write capability alone does not constrain branch names.
Enforce the PR-only default-branch ruleset with no bot bypass and validate the
allowed branch in the job before pushing. GitHub's [ruleset documentation](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
distinguishes requiring a PR from requiring its approval.

## Remaining evidence for SQD-033

The dedicated registration, scoped installation, short-lived credential and
revocation are verified. The local App job runner below enforces the restrictions at every issuance
and revokes credentials after each job. Hosted CI integration remains outside
this local runner; CI is still temporarily suspended.
For the original strict-review profile, use an explicitly designated disposable
test repository and a reviewer separate from the bot to demonstrate that a
merge without approval is rejected, then that an approved tested head can be
merged. Record request outcome and immutable SHA, never credentials. No such
live negative merge experiment has been run. SQD-033 remains open for that
missing evidence and reconciliation of its future profile with the maintainer's
chosen workflow. The production campaign ruleset has not been changed by this
qualification, and CI restoration remains part of the final campaign phase.

## Local App jobs

`Scripts/check-github-rules/app_job.py` now issues a fresh installation credential
for each job and validates App identity, installation owner, exact permission
allowlist, expiry and a single repository before executing an API operation.
It revokes the credential in a `finally` block on success, validation failure or
job failure. SIGTERM and keyboard interruption also unwind cleanup; a forced
process kill or network outage can prevent revocation, so the maximum one-hour
expiry remains the backstop. Credentials are never written to disk or printed.
The private-key path is supplied by the operator with `--key-file`; the file
must be a regular owner-only file. Do not place it in the repository.

The default operation checks the main branch read-only. To merge an already
locally tested PR, supply `--merge-pr NUMBER --tested-sha FULL_SHA`. The job
requires a same-repository `bot/<issue>-<slug>` branch, base `main`, a non-draft
PR and the exact tested head, then uses GitHub's expected-SHA merge API.
The caller must run the relevant local checks before passing the SHA. This
runner does not claim to attest that the caller actually ran tests, and never
bypasses GitHub rules or falls back to a maintainer credential.

The two allowed job repositories are `Tooflex/Squidra` and the private fixture
repository `Tooflex/Squidra-governance-qualification`. Each credential is limited
to one of them. The qualification repository has active ruleset `26481487`,
CODEOWNERS `* @Tooflex`, one approving review, latest-push approval, stale-review
dismissal and no bypass. Its App installation is still pending GitHub's
interactive reauthentication; no negative merge result is claimed yet.
