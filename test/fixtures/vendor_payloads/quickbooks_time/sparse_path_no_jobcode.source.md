# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: A "sparse" but valid timesheet — the vendor allows `jobcode_id = 0`
  to denote an unassigned / uncategorized punch (e.g., a brand-new hire who
  has not been bound to a jobcode yet). `pay_rate` is the empty string
  (vendor's documented shape when the OAuth grant has not been issued
  pay-rate scope or when no rate is set), and `location` is empty. The
  adapter must still write a canonical fact: `role_name = ''` (the
  jobcode-join lookup fails, falls back to empty string), `wage_source =
  app_fallback` per `field_mapping.md` ambiguity call. No reject expected
  — this is a happy-but-thin shape.
