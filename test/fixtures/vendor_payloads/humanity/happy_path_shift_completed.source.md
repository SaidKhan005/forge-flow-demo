# Source

- URL: https://platform.humanity.com/v1.0/shifts (documented in `docs/integrations/humanity/api_consumed.md`)
- Mirror docs: https://developers.humanity.com/ (vendor docs surface; partial public coverage)
- Retrieved: 2026-05-08
- API version: v1.0
- Endpoint: GET /v1.0/shifts (poll listing — Humanity is `pollOnly`; vendor exposes no webhook delivery surface per `webhook_signature.md`)
- Notes:
  - Field shapes (`id`, `employee_id`, `position_name`, `in_time`, `out_time`, `updated`) are mirrored verbatim from the adapter's `documentedPerHumanityV10FieldMapping` constant in `lib/integrations/labor/humanity_labor_adapter.dart` lines 74-132 and the `humanityBackfillBatchPage1` reference fixture in `test/integrations/labor/fixtures/humanity_punches_fixture.dart`.
  - Both `id` and `employee_id` are typed `string_or_int` per `field_mapping.md`; this happy-path fixture uses the integer-as-string shape (vendor doc shows it as an integer in some endpoint examples).
  - Auxiliary fields (`status`, `schedule`, `location`, `paid`) are documented Humanity v1 shift attributes the adapter currently ignores; included verbatim so the field-mapping diff in `*.live.sandbox` can confirm the adapter still drops them cleanly.
- Outcome: adapter writes one canonical fact (vendorEntityId="9001"); `paid=1` is ignored; PII fields absent.
