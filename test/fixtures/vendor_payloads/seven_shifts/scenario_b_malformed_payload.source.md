# Source

- URL: https://developers.7shifts.com/reference/listtimepunches
- URL (webhooks): https://developers.7shifts.com/reference/webhooks
- Retrieved: 2026-05-08
- API version: v2 (pinned `v2-2026-05-04`)
- Endpoint: documented `time_punch.edited` envelope, mutated to
  violate documented field shapes
- Notes: adversarial Scenario B. Each documented violation is
  intentional:
  - `time_punch.id` is missing → `_canonicalizePunch` returns null at
    line ~1349 (`if (id == null) return null`).
  - `clocked_in` is the string "yesterday at six pm" → fails
    `DateTime.tryParse`, function returns null at line ~1356.
  - `user_id` documented as int but provided as string —
    canonicalizer would coerce via `toString`, but the punch is
    already rejected upstream by the missing id.
  - `role.name` missing — adapter defaults `roleName` to '' (would
    canonicalize on a survivor) but rejected upstream.
  - `approved` documented as bool, provided as string "yes" — adapter
    treats as `false` per `approvedRaw is bool ? approvedRaw : false`
    at line ~1385.
  Outcome: no canonical fact written; the framework's parse boundary
  drops the payload before the adapter is invoked.
