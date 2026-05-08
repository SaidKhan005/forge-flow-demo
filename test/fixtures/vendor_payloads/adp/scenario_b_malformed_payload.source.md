# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (ADP Marketplace event-subscription envelope)
- Endpoint: inbound webhook `POST /v1/webhooks/{operator}/{location}/adp`
- Notes: malformed-payload scenario for binding B. Signature is
  assumed valid (the framework verifies signature BEFORE dispatch);
  the inbound handler reaches the adapter `handleWebhook`, which
  calls `_canonicalize`. Two parse failures fire:
  1. `time_event.entry_date_time` is an integer (`9999`), not the
     ISO-8601 string the canonicalizer requires
     (`lib/integrations/labor/adp_labor_adapter.dart` line ≈1063 —
     `if (entryRaw is! String) return null`).
  2. `worker` is a string scalar, not a Map (line ≈1082 — `if
     (workerRaw is! Map) return null`).
  The canonicalizer returns null, the framework records a
  `connector_sync_log` row via the dispatch unwind, and no canonical
  fact is written. Partner-only sourcing.
