# p2a_adapter_pressure_harness — Phase 2A adapter-level pressure

**Runner:** `test/integration/pressure/p2a_adapter_pressure_harness_test.dart`

**What it pressures:** the layer that turns vendor JSON into a canonical
fact (or refuses) — drives the 17 vendor adapters' fixture corpora at
`test/fixtures/vendor_payloads/<vendor>/` through their adapter parse
paths and catalogs every divergence from the per-vendor README's
documented expectation. The harness is a FINDING GENERATOR, not a gate:
every divergence becomes a JSON line; the test itself only fails when
the harness can no longer keep going.

**Status at f0bf2702:** PASS (writes findings unconditionally; the
asserted-on test only checks the findings artifact exists).

## Inputs

- No env vars. Hermetic.
- Fixture corpus root: `test/fixtures/vendor_payloads/<vendor>/`.
- `kHarnessNow = 2026-05-08T18:00:00Z` — the documented "test now"
  anchor for future-dated fixtures.
- Vendor catalog: `_helpers/p2a_vendor_registry.dart` (17 entries).
- Cross-vendor pair set: `kP2aCrossVendorPairs`.
- Pre-flagged bugs probed: Square + Lightspeed naive-timestamp silent-
  coerce; Humanity time-off-as-24h-shift.

## What it asserts

- Per-vendor walk: every JSON fixture is loaded; unparseable JSON →
  `fixture_unparseable` finding; missing-from-README →
  `readme_unparseable`.
- Scenario-specific structural probes:
  - `scenario_a_forged_signature` — fixture body carries a signature
    marker (or `wrong_reject_reason` finding).
  - `scenario_c_future_dated_event` — at least one timestamp falls
    after the test-now anchor.
  - `scenario_e_ambiguous_timestamp` — naive (offset-less) ISO
    timestamps surfaced; for Square + Lightspeed the silent-coerce
    bug is confirmed via `DateTime.tryParse`.
- Public-DTO drivers for Humanity (`HumanityShiftDto.tryFromMap`) and
  Libro (`LibroReservationDto.fromMap`): pass / reject divergences
  vs the README's outcome cell.
- Cross-vendor `scenario_f` pairs: paired vendors do NOT share a
  `vendor_id`; each fixture references the other vendor.
- Audit-claim mismatch: Oracle Simphony declares
  `VendorAuthMode.oauth` (audit's "mTLS" claim is wrong); Agendrix
  declares `oauth` (audit's "static API key" was wrong).
- Pre-flagged bugs: Square + Lightspeed `DateTime.tryParse(...).toUtc()`
  silently coerces naive timestamps; Humanity DTO parses time-off as
  a 24h shift.

## How to read the output

- Findings artifact: `test/integration/pressure/p2a_adapter_findings.jsonl`
  (gitignored; overwritten every run). Each line is one JSON finding
  with `vendor`, `scenario`, `divergence_type`, `detail`, `fixture_path`.
- The test prints a summary table to stdout when run; a non-empty
  findings file is expected and healthy.
- Regression on a pre-flagged bug surfaces as
  `pre_flagged_bug_silently_fixed` (the bug stopped reproducing — open
  the corresponding Phase 5 follow-up). A `harness_defensiveness_gap`
  means a probe threw and the harness swallowed it — investigate the
  stack frame in the finding `detail`.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Companion harnesses: `p2b_sink_pressure_harness_test.dart` (sink
  layer), `p2c_spine_pressure_harness_test.dart` (spine layer),
  `p2d_mobile_sync_pressure_harness_test.dart` (mobile sync)
- Vendor adapters: `lib/integrations/<category>/<vendor>_*_adapter.dart`
- Last touched: see `git log -- test/integration/pressure/p2a_adapter_pressure_harness_test.dart`
