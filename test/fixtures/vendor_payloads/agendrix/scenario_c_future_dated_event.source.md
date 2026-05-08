# Source

- URL: https://developers.agendrix.com/en/documentation
- Retrieved: 2026-05-08
- API version: v2 (Agendrix Public REST API)
- Endpoint: GET /v2/companies/{company_id}/time_entries
- Notes: Verbatim copy of `futureDatedAgendrixTimeEntry` from
  `test/integrations/labor/fixtures/agendrix_punches_fixture.dart`.
  `start_time` is set one year past the retrieval date so the
  framework's `VendorTimestampSanity` flags it as `shift_in_future`
  (rule: `shift_start > now() + 1 hour`) regardless of when Phase 2
  harnesses replay the fixture. Adapter `pollIncremental` /
  `backfill` invokes `command.sanityHook(...)`; on a `false` return
  the canonical sink is skipped, the framework writes
  `connector_sync_log` with `eventKind = sanity_drop`, and
  `recordsWritten` is not incremented.
