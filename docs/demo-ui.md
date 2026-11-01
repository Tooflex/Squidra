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
