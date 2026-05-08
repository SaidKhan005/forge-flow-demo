# Source

- URL: https://libroreserve.github.io/api-documentation/#section/Webhooks
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: webhook delivery (event: `reservation.confirmed`)
- Notes: **Reservation domain nuance** — unlike POS / Labor, the
  reservation domain has a legitimate "future-dated" field
  (`reservation_at` is the future booking time). The pressure-test
  guard bounds on the EVENT-creation timestamp, not the booking time:

  - For backfill / poll: bound on `created_at` / `updated_at`.
  - For webhook delivery: bound on `occurred_at`.

  This fixture sets the event timestamps (`occurred_at`, `created_at`,
  `confirmed_at`, `updated_at`) all 2 days past the reference now
  (2026-05-08), past any reasonable clock-skew tolerance. The
  `reservation_at` booking time is left at a normal 5-week-out
  reservation so the only bounded value that fails is the event
  timestamp.

  The framework's sanity hook (called by `pollIncremental` and
  `backfill` per lines 599-606 / 678-687 of
  `libro_reservation_adapter.dart`) MUST return `false`; the adapter
  skips the canonical write and the framework records a `sanity_log`
  row.
