# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/labour (in-progress shift with active break)
- Notes: Tests the labour endpoint's break sub-array shape with a
  shift still in progress (`clocked_out_at = null`,
  `actual_end_at = null`, `hours = null`) and a break that is itself
  in progress (`breaks[1].end_at = null`). Per `field_mapping.md`
  the `documented` slice maps `/shifts` only; the labour-side
  punch-level facts (clocked_in / clocked_out / breaks) are
  follow-ups in `8.S.PU.live.*`. Phase 2A harness should treat
  null clock-out as "punch not yet complete" — adapter should
  defer the canonical write or write a partial fact, not crash.
  Break `type` (`meal` / `rest`) is documented as a vendor-defined
  enum on the break sub-record.
