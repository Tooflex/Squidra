# Local Web review interface

The first typed static UI supports the consolidation review routes from #29.
It does not yet implement the full T06 frame-import/question/evidence demo,
external-command approvals, or the SQD-023 browsing timeline.

Use Node 26.10.0 (`web/.nvmrc`) and the committed npm lockfile. TypeScript 7.0.2
and Playwright 1.64.1 are exact development dependencies; the shipped client has
no framework or runtime package dependencies.

```sh
npm ci --ignore-scripts --prefix web
npm run build --prefix web
npm run serve --prefix web
```

Open `http://127.0.0.1:3000`. If that port is occupied, choose another explicitly,
for example `SQUIDRA_WEB_PORT=3001 npm run serve --prefix web`. The static server
binds only 127.0.0.1 and serves three fixed built assets with no-store, nosniff,
no-referrer and a CSP. It never reads environment credentials or serves arbitrary
filesystem paths. Build outputs are ignored and regenerated from checked-in source.

Start the normal Squidra server with `SQUIDRA_UI_ORIGIN` exactly matching the
browser page origin (scheme, host and port), and its existing database/actor/token
configuration. Create a journal with `squidra consolidate --input /path/batch.json` using the
same server environment; its JSON result contains the journal UUID. The closed
input format is documented in `docs/fact-consolidation.md`. Enter the server's local
HTTP origin, its existing 64-character lowercase hexadecimal owner token, and the
journal UUID in the page. The API origin accepts only localhost or 127.0.0.1,
without credentials, paths, query or fragments. Redirects are refused. The token
is sent only as Authorization, kept only in memory, cleared from the input after
connection, and discarded on logout/page exit. No local/session storage, cookies,
URL credentials, analytics or persistent session is created. This owner token is
not a separate limited reviewer identity.

The list and preview show state, criticality, exact value, validity, quotations,
original texts and source IDs. All content uses text nodes; HTML in evidence is
inert. Approve/reject opens a confirmation dialog for the exact displayed versions.
No request is sent on cancel/Escape. A successful response must match the proposal,
expected next versions and decision before success is shown. A stale/conflicted
response removes decision controls and asks for refresh; errors/unavailability
are not represented as empty knowledge. Refresh fetches current state. After an
interrupted decision, refresh to inspect the durable server result. Logout aborts
outstanding work; late responses cannot reopen the session. Bounds: 10-second
requests, 1 MiB responses, 256 proposals, 16 evidence records per preview.

The UI uses labels, headings, a skip link, live status/alert regions, native buttons
and a modal dialog. Focus moves to loaded content and starts on Cancel in the
dialog. Source text uses wrapping; the layout becomes one column on narrow screens.
These are semantic/keyboard checks, not a claim of completed manual screen-reader
qualification.

`bash Scripts/test-issue.sh T06-REVIEW` installs locked dependencies, installs the
pinned Chromium revision, compiles the strict TypeScript client and requires all
six browser scenarios to pass without skips/flakes. On Linux CI it also installs
Playwright's system dependencies. Test serving uses dedicated loopback port 43127
and refuses to reuse an existing service. The JSON report is checked for exactly
six passed tests; a missing/partial report fails. Tests verify keyboard review,
exact POST bodies, hostile evidence, rejection, logout/storage, stale decisions,
unavailability/malformed data, off-host origin refusal and late-response isolation.
The screenshot at `web/test-results/review.png` is an authored fixture.

The `T06-REVIEW` scenarios intercept API responses for deterministic fault cases.
The integrated suite below separately verifies the live browser-to-PostgreSQL path.
Structured batch provisioning is available through the normal CLI below.
Frame import, questions and external-command approval expiry/rejection remain
part of #42. Automatic model extraction is not implemented or qualified by
the consolidation review path; see `docs/fact-consolidation.md` for its scope.
Hosted CI is still paused; its future Node/browser steps and the local gate include
this suite. Actual Linux execution awaits restored CI.


## Real browser / server / database qualification

Run `bash Scripts/test-issue.sh T06-REVIEW-LIVE` with the local container engine
configured as for other database suites. It creates an isolated database, builds
an opt-in test fixture executable and the normal `squidra` CLI, then installs and
builds the locked Web tools. The static server supports `SQUIDRA_WEB_PORT=0` for an
owned ephemeral port and prints the selected loopback address. The fixture harness
starts both listeners on ephemeral ports and configures the real CORS origin.

The fixture prepares local input files; the normal `squidra consolidate --input`
command imports them. The authored dataset contains one approvable proposal, one rejected proposal and
a contradictory pair, each with original texts and source IDs. Chromium uses the
actual page and API without request interception: inspect sources, approve/reject,
refuse contradictory decisions, logout and reject an invalid token. The harness
then stops the server cleanly, starts another normal CLI process and repeats the
browser reads. A fresh SQL client verifies review actor, private-only promotion,
source preservation, no promotion for rejection/conflict and byte-identical
canonical archives across the restart.

Three required integration markers cover loopback database isolation, completed
browser decisions plus SQL verification, and post-restart browser/SQL verification.
Only owned processes are signaled and joined. Temporary logs/manifests are private
and removed; raw browser failures are never echoed because fill errors may contain
credentials. Browser/static processes receive an allowlisted environment with no
database credentials. The normal CLI receives a fresh test token and only the
isolated database credentials. This harness does not add a production fixture mode.

This proves end-to-end consolidation review with authored data and graceful restart.
It does not claim live extraction accuracy, abrupt process-crash coverage, frame
import/questions, external-action approval, or manual screen-reader qualification.

## Exact command authorization

Open `/approvals` from the review footer and enter a local server origin, owner
session token and approval UUID. This uses the existing `/api/v1/approvals/:id`
preview and decision routes. The full tool, target, original arguments JSON,
scope, command fingerprint, decision digest, run/ledger IDs and expiry are shown
as text. The page does not interpret command arguments or invoke an executor.

Authorize, refuse and withdraw each require a confirmation dialog with initial
focus on Cancel. The POST contains only schema version, chosen decision and the
preview's exact digest. A successful response must preserve the entire displayed
command binding and advance its version once, with a decision time. A changed
command, 409 conflict, malformed response or transport failure clears controls
and requires an explicit refresh; the client never retries a decision silently.
An approved state is labelled as authorization with execution unconfirmed.

A local expiry timer closes an open confirmation and removes pending actions.
The notice explicitly refers to the browser clock; the server remains the expiry
authority, and a lagging browser cannot override a server refusal. Refresh shows
server-reported approved, denied, withdrawn or expired states. Browser suspension
is also covered by rechecking the deadline immediately before submitting.

Tokens stay in memory and are cleared on disconnect/pagehide. Only localhost or
127.0.0.1 HTTP origins are allowed, redirects and browser credentials are disabled,
and responses are capped at 128 KiB with a ten-second timeout. Native labels,
buttons, dialog focus, skip navigation and status/alert regions support keyboard
and assistive navigation. No manual screen-reader qualification is claimed.

`bash Scripts/test-issue.sh T06-APPROVALS` requires six Chromium scenarios:
exact digest and keyboard confirmation, refusal/withdrawal, local/server expiry,
changed command/conflict, unavailable/malformed/401, and local-origin/session
isolation. These fixtures intercept HTTP and do not execute commands. The separate live
authorization suite below covers browser-to-PostgreSQL decisions. Frame import
and historical questions remain part of #42; consolidation review tests do not
substitute for authorization tests. No command execution or live-provider claim is made.


## Real command authorization qualification

`bash Scripts/test-issue.sh T06-APPROVALS-LIVE` starts isolated PostgreSQL, the
normal CLI server and Chromium with no HTTP interception. A test-only opt-in
fixture creates four reserved ledger commands through the production APIs,
then requests approvals. The browser approves, refuses and withdraws three
requests. For the fourth, the real server deadline has elapsed while the browser
clock deliberately lags by a minute: the attempted authorization returns 409,
and a refresh exposes the durably expired state. Database timestamps are not
rewritten. The browser also checks exact digest/fingerprint, preservation of an
integer above JavaScript's safe range in the original arguments text, inert
script text, keyboard confirmation and rejection of an invalid owner token.

A fresh SQL client verifies all four decisions, versions, actor identities and
command bindings. Every ledger entry remains reserved at version 1, without a
result or provider receipt; no executor is configured or invoked. The normal
server is stopped cleanly and restarted, then a fresh browser reloads the four
decisions. Full approval and ledger rows must remain byte-identical after reload.
This proves durable authorization, not external command execution or SIGKILL
recovery. Seeded commands and arguments are authored test data.

The harness uses ephemeral loopback listeners and exact UI origins. Browser and
static-server environments exclude database credentials. Private temporary logs
are removed rather than echoed; fixture/browser phases have bounded waits and
owned servers are stopped and joined. No production fixture mode, model calls,
new dependency or schema migration is introduced. Linux and manual screen-reader
qualification remain separate from these local macOS checks.

## Synthetic frame import

Open `/import` from the review page. Configure the explicit synthetic import
profile described in [frame-ingestion.md](frame-ingestion.md), including the
actor-owned scene and coordinate frame. Connect using the local API origin and
owner token, select the PNG from the frozen provider fixture, and grant local
processing consent. The client accepts at most 512 KiB and checks the PNG
signature before sending the closed import body. Full PNG validation and fixture
recognition remain server responsibilities.

The receipt must match the selected image's SHA-256 and the synthetic/inferred,
non-retained profile. It displays the observation event, per-entity location
source events, camera, source image, spatial frame, model identity, and exact
`observedAt`/`knownAt` strings. These dates retain microseconds: converting them
through JavaScript Date or a datetime-local field could select the wrong instant
in the one-second validity interval. Copy the full values when querying the API.

The owner token exists only in page memory. Logout clears file selection and
receipt and discards late responses. The page blocks duplicate submissions;
after any sent request, another observation requires an explicit fresh file
selection and consent. No automatic retry occurs. Interrupted or invalid responses
are not proof of failure to write: inspect the journal/world before intentionally
creating another observation. Reloading this page does not recover receipts.

The capability endpoint reports whether a read host exists. The default CLI has
none, and the page explicitly reports that free-text questions are unavailable.
Use the linked `/questions` page to submit to a host that advertises support.
The default CLI still has no configured read host.
It does not substitute a structured temporal lookup for a free-text answer.

`bash Scripts/test-issue.sh T06-IMPORT` runs six typed Chromium scenarios with
mock API responses: keyboard/provenance/XSS, consent/size/signature, duplicate
submission/interruption, malformed or mismatched receipt, HTTP failures, and
origin/logout isolation. The screenshot was inspected locally. These tests do
not establish integrated browser/PostgreSQL behavior; `SQD-020-HTTP` separately
covers the real server import and world readback. The full import-to-question-to-
evidence workflow remains open in #42, as does real provider qualification #47.

## Real browser frame import qualification

`bash Scripts/test-issue.sh T06-IMPORT-LIVE` starts an isolated PostgreSQL
container, the static UI and the normal `squidra serve` CLI with its explicit
synthetic profile. The opt-in `squidra-frame-browser-fixture` executable provisions
only the host-owned scene and coordinate frame. It does not seed observations,
location facts or association state.

Chromium uses real HTTP without request interception. Missing consent prevents
submission. A valid PNG with an extra ancillary chunk is refused because its hash
is outside the frozen fixture. An explicit fresh selection then imports the
fixture. The browser checks the visible receipt, every source identifier and both
exact timestamp strings. A structured readback from the browser origin checks
each entity's location, source event, confidence and inferred basis. This API
readback is test verification, not a user-facing free-text question or answer.

A separate SQL client verifies that exactly one observation and two location
events exist, their causation and correlation bind to the host frame, and the
projection contains the expected inferred facts. Queries at the exact receipt
instant find the facts; queries at the exclusive one-second endpoint do not.
The normal CLI then shuts down cleanly and restarts. A fresh browser session
performs no new import and reads identical historical evidence. Full journal,
spatial fact and association rows must remain byte-identical after this reload.
Both browser phases check logout, lack of browser storage and invalid-token
rejection. Private logs and receipts are temporary and removed; only fixed
completion markers are published. Browser/static-server environments do not
receive database credentials.

This qualifies real browser import and durable structured evidence on local
macOS. It does not qualify free-text question submission, SAM, SIGKILL recovery,
manual screen-reader use or Linux execution. The full #42 workflow remains open.


## Historical question and grounded evidence client

The `/questions` page submits a free-text question to the existing run API for
one selected entity, with historical intent. The host must advertise text-run
support and authorize that entity. The normal CLI remains model-free by default;
the page shows unavailability and does not substitute a structured lookup or a
fixture answer. Moving from the import page requires a new local session and
copying the receipt's entity and exact dates into the question. No token or
receipt is passed in URLs or browser storage.

Only one admission is sent per explicit question. Interrupted admission is shown
as uncertain because the server may already have accepted it; there is no
automatic POST retry. Once accepted, the client reads finite authenticated SSE
pages and sends the exact received Last-Event-ID. Four pages are read per action;
if still pending, an explicit continuation reads the same run. Failed reads keep
the previous complete page cursor. Missing/expired retention cannot reconstruct
the answer. A new question or logout does not cancel an already accepted run.
Reloading the page loses its in-memory run and cursor.

The client validates bounded events, continuous sequence, run/thread/actor/request
bindings, the grounded-answer payload, selected entity, citation references and
message agreement. An entire response page is validated before its cursor is
committed. Only a successful terminal event with a complete matching message
reveals the answer. Server errors and cancellation remain distinct from an
unknown grounded answer. The UI displays partial/unknown status, uncertainty,
source IDs, observed/inferred basis, confidence, exact source timestamps, age and
freshness. Citation links open and focus native evidence details using the
keyboard. Content is rendered as text, never HTML. These client checks are
presentation checks; they do not replace the server's authorization and grounding.

`bash Scripts/test-issue.sh T06-QUESTIONS` requires all eleven Chromium scenarios:
paged answers and keyboard citations, absent capability, partial/unknown states,
read interruption/resume, invalid bindings/citations/order, error/cancellation/
retention, duplicate and uncertain admission, origin/logout isolation, bounded
heartbeats and change claims, UTF-8/body limits and revoked authentication,
and uppercase evidence IDs with lowercase DOM anchors. The
responses are mocked for these client tests. They do not yet prove the complete
import → free-text model planning → answer workflow against a configured host.
That integrated qualification and manual screen-reader evaluation remain open.
