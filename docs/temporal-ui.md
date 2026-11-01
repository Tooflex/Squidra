# Temporal browsing UI

Build and serve `web/` as described in `docs/demo-ui.md`, then open `/timeline`
(or the chronology link in the review page footer). Configure the server's exact
UI origin. Enter its loopback HTTP address and owner bearer token. Credentials
stay in page memory, are cleared on logout/pagehide, and are never shared through
storage or URLs. Navigating between review and timeline requires a new login.
The initial form opens the local workspace; authentication is checked on reading.

Supply an entity UUID, the desired valid-time instant, explicit knowledge time,
and a half-open changes window. Native date controls display using the browser's
locale, but all entered values are interpreted as UTC, as their labels state.
There is no implicit “now” substitution after submission. Initial dates are only
editable defaults. The location and changes calls use the existing authenticated
read-only world routes and the same captured query. No model is involved.

The page displays current evidence and uncertainty, including conflicting places,
inferred evidence and projection lag. Change details show correction/current and
previous facts, original event/coordinate-frame references, source text, confidence and both
valid and transaction periods. Source strings are rendered as text. “No evidence”
and “absent or inaccessible” are separate outcomes; an unavailable or malformed
response clears results instead of presenting an empty world. HTTP 401 ends the
session. Editing any query field cancels pending reads and clears old results.

Changes are paged eight at a time. The opaque continuation retains the exact
query and projection bounds. Loading another page replaces the previous changes
page while retaining the selected state, so repeated paging does not grow the DOM
without bound. State and changes are two reads, not one atomic snapshot; their
projection lag indicators describe their respective responses. There is no
cross-query state cache. Reload after new observations to obtain a fresh view.

Native labels, buttons, details/summary, skip navigation, live status/error regions
and focus placement support keyboard and assistive navigation. Selecting a query
focuses the state heading; continuation focuses the changes heading. IDs currently
remain IDs; human-friendly entity/source previews are not supplied by this API.

`bash Scripts/test-issue.sh SQD-023` compiles TypeScript and requires six Chromium
scenarios to pass, without skipped/flaky tests: keyboard selection and late
correction retaining original evidence, service/malformed refusal, logout/401,
local-only credentials and stale-read cancellation, contradiction/continuation,
and unknown versus inaccessible state. Fixtures intercept HTTP and explicitly
assert query bodies; they are authored data, not recorded production observations.
`T06-REVIEW` separately retains the six existing review browser scenarios.

The real temporal flow is qualified separately below. Manual screen-reader
behavior, Linux execution and the rest of T06 remain unqualified. Those
limitations must remain visible when assessing parent issues #23/#42. No API contract,
migration, model, token cost or dependency change is introduced.

## Real server qualification

`SQD-023-LIVE` uses an isolated PostgreSQL database, the normal `squidra serve`
command and Chromium without HTTP interception. A test-only, explicitly opted-in
fixture creates nine observations and one late correction through the production
journal repository and location projector. Database-owned recording times straddle
a whole-second knowledge boundary; no journal timestamps are rewritten. An earlier
knowledge time shows the original location; a later one exposes the correction
and its previous evidence at the same valid instant. The browser checks keyboard
focus, original/corrected source IDs, inert hostile source text and an eight-item
page followed by the remaining item. The normal CLI is stopped cleanly and
restarted; a fresh browser repeats the flow. A separate SQL client checks both
states and byte-identical journal rows before and after each browser phase.

The fixture uses authored observations rather than perception/model output. It
is a test target, never a production server mode. Browser and static-server
environments exclude database credentials. Private temporary logs are removed
and are not echoed because browser fill errors can contain tokens. Fixture and browser phases
have bounded waits; owned servers are stopped and joined on exit. This tests graceful restart,
not SIGKILL. `frameId` is a coordinate frame and is labelled “Repère spatial”;
it is not represented as a source image.
