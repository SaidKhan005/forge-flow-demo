# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified` (synthetic
  variant — Aloha documented shape ALWAYS includes the trailing
  `Z`).
- Notes: Adversarial scenario E. `field_mapping.md` § "Timestamp
  shapes" notes that scenario E does not naturally arise for Aloha
  (vendor always emits Z-suffixed UTC). The fixture forces the
  ambiguous case anyway so the refuse-by-default protection is
  exercised. Phase 2 harness asserts canonicalizer rejects with
  `TimestampPolicyViolation` (or framework equivalent); the
  `(operator_id, location_id)` partition is untouched.
- The base date 2026-03-08 was chosen deliberately to overlap with
  the US DST spring-forward fixture so a Phase 2 reviewer can see
  the contrast: same date, two failure modes (DST gap vs missing
  TZ).
