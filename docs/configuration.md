# Credentials and public settings (SQD-004)

Authentication consumers receive an opaque `CredentialReference` and an
injected `CredentialProvider`, never a serializable secret field. A
`BearerCredential` can validate a bearer header but has no raw-value accessor
and does not conform to Codable. Its description and reflection redact the
value. The provider also has redacted diagnostic representations. Raw values
must still be handled carefully by the host during provisioning; this is not
a secure-memory erasure guarantee.

`RotatingCredentialProvider` is an in-memory, host-owned adapter. Rotation uses
an expected version so stale updates cannot overwrite a newer credential;
passing nil revokes it. Subsequent HTTP requests resolve the current value.
A request already authenticated before rotation retains its authority until
completion. No remote rotation route or credential-list API is exposed.
References grant no authority to mutate the provider.

Server composition can inject a provider/reference into `ServerConfiguration`
while omitting `SQUIDRA_AUTH_TOKEN`. The CLI retains its existing environment
provisioning for compatibility: it creates a private provider at startup.
Changing the parent shell environment cannot rotate a running process. Live
rotation requires an embedding host retaining the injected provider; CLI
operators replace the environment secret and restart the process. Database
credentials still use the existing redacted PostgreSQL configuration; this
change does not rotate an existing database pool or add a provider API key.

Providers must cooperate with task cancellation and a monotonic deadline.
HTTP credential lookup is limited to the smaller of the request timeout and
two seconds. Missing, revoked, timed-out and failing providers cannot
authenticate. The boundary emits static errors rather than provider exception
details. Credentials never become model context or trace attributes; no new
configuration endpoint exposes them. Comparison visits every byte after length
validation, without claiming formally constant-time compiled Swift behavior.

Run `bash Scripts/test-issue.sh SQD-004`: rotation/revocation, stale versions,
wrong references, deadlines, cancellation, invalid values, injected host
configuration, HTTP authentication and redaction, and real OpenTelemetry
snapshot canaries. The tracing test checks the existing private recorder;
full live run tracing remains tracked by SQD-030.
