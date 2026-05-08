# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets
- Notes: Cross-timezone resolver case. The F&F location is in Vancouver
  (`America/Vancouver`, PDT = UTC-7 in May). The vendor user
  (`users[].tz_str = -04:00`) is registered in QBT under a Toronto
  (`America/Toronto`, EDT) timezone — perhaps because the operator
  manages this employee from a head office in Toronto. The punch's UTC
  timestamps are unambiguous (`start = 2026-05-05T03:30:00Z`, `end =
  2026-05-05T07:00:00Z`), but interpreting that for business-date
  bucketing requires choosing between two zones:

  | Choice | Resulting business_date |
  |---|---|
  | Vendor `users[].tz_str` (-04:00 / Toronto) | 2026-05-04 (23:30 → 03:00 EDT) |
  | F&F location IANA zone (America/Vancouver) | 2026-05-04 (20:30 → 00:00 PDT) |

  The two zones happen to coincide on the date in this fixture (both
  bucket to 2026-05-04), but the framework's contract is **always
  resolve via the F&F location's IANA zone, never the vendor user
  zone**, per `core_app_architecture.md` Time Guardrails (restaurant-
  local timing wins; business date is the anchor). The Phase 2 adapter
  harness asserts the resolver picked the location zone path even
  though the vendor `tz` / `tz_str` siblings exist on the payload.
