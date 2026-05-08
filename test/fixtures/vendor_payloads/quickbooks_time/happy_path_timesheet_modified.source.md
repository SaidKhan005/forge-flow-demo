# Source

- URL: https://tsheetsteam.github.io/api_docs/?javascript#timesheets
- Retrieved: 2026-05-08
- API version: v1
- Endpoint: GET https://rest.tsheets.com/api/v1/timesheets (incremental,
  `?modified_since=...`)
- Notes: A previously-closed timesheet that was edited by an admin after the
  fact. `last_modified` (`2026-05-05T08:15:42Z`) is later than the
  `start` / `end` instants and later than the original `created` instant.
  This is the canonical incremental-poll shape: a row whose `last_modified`
  has advanced past the previous watermark and must be re-emitted to the
  canonical fact table by `pollIncremental()`. Field paths
  (`timesheets[].last_modified`) align with the field-mapping doc.
