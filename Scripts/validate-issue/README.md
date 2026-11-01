# Structured task validation (SQD-032)

The story, bug, task and eval-failure forms require context, measurable
acceptance criteria, repository paths, authorized fixtures, test commands,
risks/rollback and a bounded time/file budget. Definitions use JSON syntax,
a strict YAML 1.2 subset, so their structure can be verified without another
runtime dependency. Follow the form descriptions, including one path per
line and `minutes` followed by `files` in the budget.

The validator accepts at most 32 KiB, rejects missing/duplicate fields,
placeholder responses, malformed checklists, traversal/absolute paths and
budgets above 480 minutes or 50 files. These are dispatch input limits, not
automatic authorization to change every listed path.

The GitHub workflow checks out trusted default-branch code, fetches the current
issue through `gh api`, and verifies both its human author's and the triggering
actor's current write/admin permission. Repository identity and issue state
must match. A denied or unavailable API fails closed. It uses a read-only
token and does not send comments, add labels, modify issues or start agents.
Issue text, paths and test commands remain untrusted data and are never
executed by the validator. Output contains only a content hash and bounded
metadata; raw issue text and API errors are not logged.

Any future dispatcher must require a successful validation of the same issue
body hash and revalidate current permissions immediately before dispatch.
Validation is not an authorization token, and editing an issue invalidates
the recorded hash. Local environment variables alone are not proof of identity.

During the requested CI pause, the workflow has a manual trigger only. At CI
restoration, enable `issues: [opened, edited, reopened]` and use the event's issue
number in the workflow, while retaining trusted default-branch checkout and
permission checks. This task does not claim an agent dispatcher is implemented.

Run `bash Scripts/test-issue.sh SQD-032` for positive/negative fixtures and
form validation. No fixture test starts a real agent or requires a token.

References:
- https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms
- https://docs.github.com/en/rest/collaborators/collaborators#get-repository-permissions-for-a-user
