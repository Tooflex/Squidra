# Dated Spark qualification budget renewal

This is an explicit qualification policy, not a billing service. The task owner
has authorized 100 EUR total across Meta and SAM. Reserved amounts are
conservative allocations, not measured charges. Failures and cancellations never
refund them; usage estimates cannot justify a refund.

The `spark-standard-2026-11-03` policy preserves the entire schema-1 ledger as
base64-encoded original bytes plus its SHA-256. Its old attempts retain their
original 1000-cent reservations, statuses and reports. Only new Standard Spark
(`muse-spark-1.3`) attempts may reserve 250 cents. The sum of historical and new
reservations must remain at most 10000 cents. Nine historical attempts therefore
leave room for four new attempts, including failed or interrupted attempts.
Wonder and SAM are not qualified by this renewal.

The reviewed sources on 2026-11-03 are:

- [Meta pricing](https://dev.meta.ai/docs/pricing-rate-limits): Standard Spark
  input $1.25/M tokens, output $4.25/M tokens, no long-context premium.
- [Meta context limit](https://dev.meta.ai/docs/cookbook/long-context): 1,048,576
  tokens, shared between input and output. Counting the full limit as input plus
  4096 output tokens deliberately overbounds that shared limit.
- [Meta reasoning](https://dev.meta.ai/docs/reasoning): reasoning is included in
  the output-token limit and billed as output.
- [ECB USD reference](https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/eurofxref-graph-usd.en.html):
  1 EUR = 1.1179 USD on 2026-11-03.

The text-only request has no provider tools and at most 4096 output tokens. Its
full-context published-price bound is $1.328128. The native qualification ceiling
is $1.50 per attempt, below the 250-cent allocation ($2.79475 at the reviewed FX).
The host limits a two-attempt run to $3, with zero retries. This policy does not
qualify Contributor models, media, web search, other fees or another price/FX
regime. As with the original qualification, the operator must review applicable
billing terms (including failures); this is not an invoice guarantee or an
account-level provider spending limit. The policy expires at 2026-11-05 00:00 UTC.

Renewal is never automatic. With no inference process running, use the existing
canonical private budget directory and the SHA-256 of its current ledger:

```sh
python3 Scripts/upgrade-meta-budget.py --directory /absolute/private/provider-access \
  --expected-sha256 REVIEWED_CURRENT_LEDGER_SHA256
```

The command requires the existing private lock and ledger, holds the same
nonblocking exclusive lock used by native reservations, validates the original
bytes, then fsyncs an atomic replacement. A stale digest, unsafe file or competing
writer refuses migration. Retrying with the same original digest preserves all
new reservations. It never creates a fresh allowance. Keep this one ledger across
all probes; do not duplicate it across checkouts or reset it after a failure.

For a native text host, explicitly set
`SQUIDRA_META_BUDGET_POLICY=spark-standard-2026-11-03` with the existing cloud
consent, Spark model, entity scope, credential and budget-directory configuration.
The historical demo supplies this policy. Both Python admission and native
reservation enforce the shared cap; preflight does not reserve capacity against
concurrent requests. The native lock remains authoritative before each dispatch.
No live probe is part of CI or the offline local gate.
