# Source

- URL: https://restaurant.opentable.com/products/opentable-platform/
- Retrieved: 2026-05-08
- API version: `partner-v1-2026-05-04-assumed`
- Endpoint: webhook event `reservation.modified` (assumed envelope)
- Notes: Adversarial scenario E exercises the local
  `openTableTimestampPolicy` declared at lines 160-170 of
  `lib/integrations/reservation/opentable_reservation_adapter.dart`
  (`ambiguousConvention: AmbiguousTimestampConvention.refuse`). The
  field-mapping doc's "Timestamp shapes" section locks the contract:
  > OpenTable's published reservation envelope is assumed to emit
  > ISO-8601 UTC instants with explicit `Z`. The adapter binds
  > `AmbiguousTimestampConvention.refuse` so that ambiguous shapes
  > (no `Z`, no offset) are dropped at the parse boundary instead of
  > silently treated as UTC — the bug Scenario E is designed to
  > catch.
  This fixture's `reserved_at = 2026-05-12T19:30:00` carries neither
  `Z` nor an offset (`+05:00` / `-04:00`); same for `modified_at`. A
  naive parser would treat the value as a wall-clock local time;
  Dart's `DateTime.parse` actually returns a local DateTime (host
  TZ) for offset-less ISO strings, which is exactly the silent
  fallback the contract bans for OpenTable. Phase 2 harness asserts
  the adapter rejects via the policy guard before the canonicalizer
  produces a fact.
- Adapter assertion (Phase 2): the canonicalizer (or the
  framework's policy-aware preflight in
  `vendor_timestamp_policy.dart`) refuses the timestamp; no
  canonical fact is produced. Sink assertion: no row written.
  Important: the live-sandbox slice MAY discover OpenTable
  legitimately emits offset-less ISO strings; if so, the live slice
  switches the policy to `asUtc` (industry standard) or
  `asLocationLocal` and this scenario's expected outcome flips to
  "accept with explicit conversion". Until then, the documented
  posture is REFUSE.
