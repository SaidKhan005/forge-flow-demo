# Source

- URL: <https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog>
- Retrieved: 2026-05-08
- API version: `v1-2026-05-04-assumed` (Team Time Cards v2 / Time Events v2)
- Endpoint: ADP Marketplace event subscription `time.timeEvent.modify`;
  worker open-punch state with no `position` / `workAssignment` block
- Notes: open punch (`exit_date_time: null`) plus worker block missing
  both the WFN-side `position.position_title` and the WFM-side
  `workAssignment.jobTitle`. Canonicalizer policy per
  `lib/integrations/labor/adp_labor_adapter.dart:_canonicalize` —
  rejects when neither role path is populated (returns null →
  framework drops the row at the adapter boundary, no canonical fact
  written). The webhook path falls through to
  `GET /hr/v2/workers/{associate_oid}` to attempt to repopulate the
  role — that fall-through path is exercised by adapter tests, not
  this fixture. Partner-only sourcing.
