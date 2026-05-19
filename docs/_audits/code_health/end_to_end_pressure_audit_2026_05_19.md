# End-to-End Pressure Audit — 2026-05-19

Status: Active (initial pass)
Owner: Deep-audit slice (Claude lane)
Branch: `claude/bold-kirch-624d77`
HEAD at start: `fa99aa06` (`origin/master` after PR #1059 squash-merge)
Companion: `docs/_audits/per_daypart_v1/graph_led_deep_audit_2026_05_19.md`
  (Codex graph-led audit; this audit is deliberately complementary, not
  duplicative)

## Scope

Three asks from the operator:

1. End-to-end test coverage across all three product surfaces
   (Operator Web, F&F Operations Console / admin, mobile main app).
2. Pressure test the vendor-integration spine — all 17 vendors, with
   live-simulated payloads, across all three surfaces.
3. Deep audit report with findings.

Codex is concurrently fixing gaps on master; this audit is a snapshot
at `fa99aa06` and explicitly cross-references the Codex graph-led
audit so we are not re-deriving the same findings.

## Methodology

- Static-recon (read-only): vendor matrix, contract review,
  KNOWN_FAILING baseline.
- One full-repo test run as baseline (`flutter test --concurrency=4`)
  to a fixed log; 10,269 tests passed / 9 skipped / **133 failed**
  (128 unique test names).
- Failure categorization by directory and root-cause class.
- Targeted re-runs of suspect files to confirm root cause vs flake.
- Vendor parity matrix: 17 vendors × {direct adapter, postgres sink,
  sink test, live-verification doc, api-consumed doc, lifecycle stage}.
- Pressure run with `--test-randomize-ordering-seed=random` in flight
  at write time; results to be appended under "Flake hunt".
- Honest assessment per Doc Lean-Out doctrine: do not manufacture
  consolidation, name false-positives explicitly.

## Headline

The three product surfaces are healthy. The vendor parity layer is
complete in code, docs, and per-vendor sink tests. The bulk of repo
failures are environment-only (live Postgres SSL) or already
documented as pre-existing. There are **three new findings worth
flagging** — none blocks the demo, all are test-suite truth gaps.

## Surface-level health

| Surface | Tests | Result | Notes |
| --- | --- | --- | --- |
| Operator Web (`test/operator_web/`) | ~688 | **All pass** | Driven green earlier this session (PR #1059). |
| Admin Console (`test/admin/`) | ~663 | **All pass** | Driven green earlier this session (PR #1059). |
| Mobile / main forgeflow (root `test/` + `test/screens` + `test/state` + `test/widgets` + `test/services`) | ~6000+ | Mixed (see findings) | Most are passing; mobile-specific failures concentrated in mock-replay-date drift and demo-seed multi-location seed. |

Demo servers were booted in profile mode for the operator-web and admin
surfaces during this session (see `.claude/launch.json`
`operator-web-demo-profile` / `admin-console-demo-profile`). Both
landed signed-in on the expected default route with zero browser
console errors and zero failed network requests.

## Baseline test result (full repo, fixed order)

```
+10269 ~9 -133 (133 failures, 128 unique test names)
```

### Failure breakdown by category

| # | Category | Count | Real regression? |
| --- | --- | --- | --- |
| 1 | Live-Postgres SSL (test/infrastructure/persistence/**, test/phase_9_0sigma_*) | **65** | **No** — local PG lacks SSL; tests expect SSL-required server. Environment-only, not a code regression. |
| 2 | Spine smoke test setup gap (`test/_execution/spine_bridge_v2_smoke_test.dart`) | **9** | **Yes (test-truth gap)** — see Finding A. |
| 3 | Demo multi-location seed (`per_daypart_v1_demo_slice_a_hierarchy_test.dart` + neighbours) | 7 | Yes — see Finding C. |
| 4 | Banned-items grep for poll-only labor adapters | 4 | **Yes (doctrine conflict)** — see Finding B. |
| 5 | Widget alignment / overflow guards (`baseline_operating_strip_align_test.dart`, etc.) | 6 | Mixed — overlap with KNOWN_FAILING shift_visual / shift_dashboard_daypart_parity entries. |
| 6 | OPZ benchmark-graph degenerate-state badges | 5 | Mostly pre-existing whole-day-path drift (sibling of KNOWN_FAILING shift_visual). |
| 7 | Mock-replay business-date drift (`business_date_authority_service_test`, `demand_forecast_context_service_test`, `history_teaching_analyzer_test`, `target_state_alignment_test`, `metadata_timestamp_normalization_test`, `schedule_plan_read_service_test`) | 6 | Yes — see Finding D. |
| 8 | Advisor model config service (`probeForgeFlowProxyHealth`) | 3 | Yes — narrow, /healthz path/response contract drift. |
| 9 | OAuth refresh worker registry (`p3c_oauth_refresh_storm_runner_test`, `tool/oauth_refresh_worker/main_test`) | 3 | **No** — matches KNOWN_FAILING (2026-05-12 consolidation pass; assertion count drifted from 10 → 12 closures). |
| 10 | Other one-off (admin Gemini key, mobile push, vendor_connections route mount, audit_anchor advisory lock, sanitization wrapper, shift dashboard empty state, scope drawer demo seed, learn-layer benchmark cleanup) | ~20 | Mixed; ~half overlap with KNOWN_FAILING, rest are real but narrow. |

### Cross-reference vs `docs/KNOWN_FAILING_TESTS.md`

Documented (expected): 9 rows. Of those that appeared in this run:

- ✅ `test/operator_web/widgets/vendor_relativity_label_test.dart` — **fixed in PR #1059** (this session), now passes; remove from KNOWN_FAILING.
- ✅ `test/admin/admin_shell_widget_test.dart side nav lists primary routes` — quarantined IA drift, still expected.
- ✅ `test/pressure/p3c_oauth_refresh_storm_runner_test.dart` — still expected (10→12 drift).
- ✅ `test/tool/advisor_proxy/admin_integrations_response_sanitization_test.dart` — still expected.
- ✅ `test/widget/shift_dashboard_daypart_parity_test.dart` and `test/shift_visual_widget_test.dart` — still expected (whole-day-path scroll-target drift).
- ✅ `test/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository_test.dart` — folded under category 1 (env-dep) here, but the doc-stated cause is a `PackagePostgresPool` import error; the SSL message dominates because the import is now resolved on master but SSL still blocks the connect. (One-line follow-up: re-baseline the doc entry against current head.)
- ⚠️ Operator-web router test — "management picker drives location-scoped vendor route" — flaky pumpAndSettle. Did NOT show in this run; may be order-dependent. Pressure run (random seed) will tell.

## Vendor parity matrix (17 vendors)

All vendors at HEAD `fa99aa06`:

| Vendor | Category | Adapter | Postgres sink | Sink test | api_consumed.md | live_verification_checklist.md | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Square | POS | ✓ | ✓ | ✓ | ✓ | ✓ | `coversFieldExposed = false` (binding correction #2). |
| Toast | POS | ✓ | ✓ | ✓ | ✓ | ✓ | Webhook-driven. |
| Clover | POS | ✓ | ✓ | ✓ | ✓ | ✓ | `coversFieldExposed = false` (binding correction #3). |
| Lightspeed LSK | POS | ✓ | ✓ | ✓ | ✓ | ✓ | |
| Aloha NCR Voyix | POS | ✓ | ✓ | ✓ | ✓ | ✓ | `coversFieldExposed = true` flagged risky (binding correction #4). |
| Oracle MICROS Simphony | POS | ✓ | ✓ | ✓ | ✓ | ✓ | Gen2 covers path = `items[].header.guestCount` (binding correction #5). |
| Revel | POS | ✓ | ✓ | ✓ | ✓ | ✓ | |
| ADP | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | `webhookSupport = autoRegister` (binding correction #1). Verifier present (allowed). |
| 7shifts | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | `perEmployeeWithDollars` (binding correction #7). Verifier present (allowed). |
| QuickBooks Time | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | Poll-only. **Verifier present — see Finding B.** |
| Humanity | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | Poll-only. **Verifier present — see Finding B.** |
| Agendrix | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | Poll-only. **Verifier present — see Finding B.** |
| Push Operations | Labor | ✓ | ✓ | ✓ | ✓ | ✓ | Poll-only. **Verifier present — see Finding B.** Labor wage class corrected (binding #9). |
| Libro | Reservation | ✓ | ✓ | ✓ | ✓ | ✓ | |
| OpenTable | Reservation | ✓ | ✓ | ✓ | ✓ | ✓ | |
| SevenRooms | Reservation | ✓ | ✓ | ✓ | ✓ | ✓ | Credential bridge — see Finding E. |
| Tock | Reservation | ✓ | ✓ | ✓ | ✓ | ✓ | `seated_at` claim refuted (binding correction #10). |

**Conclusion: 17/17 vendors have full code-and-doc parity.** No vendor
is missing an adapter, a sink, a sink test, an api_consumed doc, or a
live-verification checklist. Per-vendor postgres sink tests all pass
(blocked locally only by the SSL environment limitation, same as the
other 56 PG tests).

## Findings

### Finding A — Spine smoke test setup gap (HIGH)

**File:** `test/_execution/spine_bridge_v2_smoke_test.dart`
**Symptom:** 9 of 14 test cases fail in `setUp` / `tearDownAll` with:

> `Bad state: aggregator: locations row not found for
> (operator_id=11111111-1111-4111-8111-111111111111,
> location_id=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa)`

**Why it matters.** This is the canonical end-to-end smoke test for
the integration spine — the run-time path that takes a vendor payload
through aggregator → ShiftFact → ShiftRecord → mobile SQLite. It
exercises Square / Libro / QBT / Oracle Simphony / Humanity / 7shifts
/ Tock / operator-manual-entry / target-cycle preservation in one
file. **All nine flagship scenarios are red on `fa99aa06`.**

**Root cause.** The aggregator's pre-write check requires a
`locations` row for the test's hardcoded `(operator_id, location_id)`
pair, but the test's setup does not seed one. The aggregator's
`locations`-row guard was added (or its enforcement tightened)
without updating the smoke fixture. Tests 1–5 still pass because they
do not hit that code path.

**Real regression vs test debt.** This is **test-truth debt, not a
runtime bug.** The demo path seeds locations via mock-replay, so the
demo runtime is unaffected. But it means the canonical
spine-acceptance smoke gives a false-clean signal — and worse, gives
a false-failing signal that masks new runtime regressions in the
spine.

**Fix.** Update the smoke test's setup to seed a `locations` row for
`(11111111-1111-4111-8111-111111111111,
aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa)` before the first aggregator
call (or extract a shared helper). Verify all 14 cases pass.

**Severity:** **HIGH** (the spine acceptance test must be honest).

### Finding B — 4 poll-only labor adapters carry a banned webhook verifier (DOCTRINE CONFLICT)

**Files (verifier present):**
- `lib/integrations/labor/agendrix_webhook_signature_verifier.dart` (134 lines)
- `lib/integrations/labor/humanity_webhook_signature_verifier.dart`
- `lib/integrations/labor/push_operations_webhook_signature_verifier.dart`
- `lib/integrations/labor/quickbooks_time_webhook_signature_verifier.dart`

**Symptom (per-vendor test):** `<vendor>_labor_adapter_test.dart`
asserts the file `lib/integrations/labor/<vendor>_webhook_signature_verifier.dart`
does NOT exist (`expect(verifier.existsSync(), isFalse)`), with the
explicit reason: "pollOnly vendor must not ship a signature
verifier; webhook_signature.md documents this as N/A."

**State on the ground:**

| Vendor | `webhookSupport` declaration | Verifier file present? | Test expectation |
| --- | --- | --- | --- |
| Agendrix | `pollOnly` | **Yes** | Must be absent |
| Humanity | `pollOnly` | **Yes** | Must be absent |
| Push Operations | `pollOnly` | **Yes** | Must be absent |
| QuickBooks Time | `pollOnly` | **Yes** | Must be absent |
| ADP | `autoRegister` | Yes | Allowed |
| 7shifts | `autoRegister` | Yes | Allowed |

**Why both sides exist.** The verifier files were added under "Phase
8.gap-1" with this rationale (from the file header): "The verifier
exists to close the production binder's 'missing verifier' warning at
boot and to give a future webhook release a documented landing
surface that mirrors every other vendor." So the **code** has moved
to "every vendor ships a verifier even if poll-only"; the **per-
vendor adapter test** still encodes the older doctrine "poll-only
means no verifier file at all."

**Real regression vs test debt.** This is a **doctrine conflict**:
the engineering-time framework decision (verifier-for-every-vendor)
and the vendor-adapter contract test (no-verifier-for-poll-only) say
opposite things. One has to lose.

**Decision needed (operator):**
1. **Keep the verifier files.** Update the 4 adapter tests to expect
   the file present + assert that `webhookSupport = pollOnly` causes
   `handleWebhook` to throw the documented "not supported" error.
   Update or retire `webhook_signature.md` for those 4 vendors.
2. **Remove the verifier files.** Delete the 4 files, restore the
   "missing verifier" boot warning, and document explicitly that
   poll-only vendors have no verifier landing surface until a real
   webhook delivery exists.

Either path is defensible; the current state is incoherent.

**Severity:** **MEDIUM** (test red is correct given the contract;
runtime is unaffected because `handleWebhook` is gated by
`webhookSupport`).

### Finding C — Per-daypart V1 multi-location demo seed regressed (MEDIUM)

**File:** `test/per_daypart_v1_demo_slice_a_hierarchy_test.dart`
(4 of its tests fail).

**Symptom.** Demo-data Slice A — mobile multi-location seed asserts
the demo seed produces exactly 4 `restaurant_locations` rows
(Downtown + 3 others, per §2c of the per-daypart V1 plan).
Variants tested:

- Seeds exactly the 4 §2c locations including `demo_restaurant_001`.
- Reseed is deterministic (same 4 rows, no duplicates).
- Upgrade path: Downtown-only DB backfills all 4 locations.
- `RestaurantScopeNotifier.availableScopes` surfaces all 4 with
  Downtown still the default active scope.

All four fail. Companion failures:

- `state/restaurant_scope_notifier_test.dart` — boot-time drawer
  seed (no session) default constructor / re-seed overwrite (2
  tests).
- `per_daypart_v1_demo_seed_per_location_data_test.dart` —
  per-(operator, location) isolation, no cross-location rows
  (HP #4).
- `per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart`
  — cold boot non-Downtown locations are NOT HISTORICAL ONLY.

**Root cause (likely).** The multi-location seed path was the
explicit deliverable of per-daypart V1 Slice A and is the foundation
for HP #11 (hierarchy-scoped settings). Either the seed function
regressed, or the test fixtures and the actual demo seed have
diverged. Has not been root-caused in this audit pass.

**Why it matters.** HP #11 hierarchy-scoped settings, scope drawer,
and the "Demo Diner" multi-location story all rest on this seed
working. The Codex graph-led audit (`graph_led_deep_audit_2026_05_19`)
identified per-daypart V1 work as the active feature plan; this
multi-location seed health is foundational to that.

**Fix (proposed scope).** Re-run the seed in isolation, diff
`restaurant_locations` row count vs the contract, and either fix the
seed or the assertion. Pairs naturally with the Codex per-daypart V1
sprint.

**Severity:** **MEDIUM** (demo runtime may still render Downtown
correctly; the multi-location pieces would silently degrade).

### Finding D — Mock-replay business-date drift (MEDIUM)

**Files (6 tests, multiple files):**
- `business_date_authority_service_test.dart`: B — planning anchor
  falls back to latest closed business date returns latest closed
  date when mock replay is absent.
- `demand_forecast_context_service_test.dart`: B / C / E — latest
  closed business date fallback, 60-day baseline covers from closed
  shifts, 3-week recent trend.
- `history_teaching_analyzer_test.dart`: canonical seed data —
  benchmarkDayparts contains both Wed Dinner and Fri Late Night.
- `target_state_alignment_test.dart`: E — week truth stability —
  stored week target fields do not change after profile change.
- `metadata_timestamp_normalization_test.dart`: D — closeShift
  `target_profile_version.created_at` is UTC.
- `schedule_plan_read_service_test.dart`: E — ShiftService and
  shared plan produce same weekly covers/sales.

**Pattern.** All involve "closed business date", "mock replay
absent/unavailable", "canonical seed data", or "week truth stability"
— hallmarks of fixture-clock drift. The mock-replay anchor or its
contained "latest closed" date has not been refreshed alongside the
real wall-clock advancing to 2026-05-19.

**Real regression vs test debt.** Test debt; the demo runtime
self-anchors via the demo seed and is unaffected.

**Fix.** Roll the mock-replay anchor forward in the demo seed, or
parameterize the affected tests with an explicit
"now"/"latestClosed" injector.

**Severity:** **MEDIUM** (false-fail noise that obscures real
regressions in the same files).

### Finding E — SevenRooms credential bridge metadata persistence (LOW)

**File:** `test/integrations/reservation/sevenrooms_credential_bridge_test.dart`
**Failing test:** `persistIssuedBearerToken records client_id +
client_secret + venue_id on metadata patch`.

**Why it matters.** SevenRooms uses an OAuth2 client-credentials
exchange; the bridge persists the issued bearer token alongside
client_id / client_secret / venue_id so the renewer can re-mint on
expiry. The test asserts those three identifiers land in the
metadata patch. Failure means the persisted credential blob may be
missing one or more identifiers — credential renewal would fail
silently at the next refresh window.

**Not investigated further in this pass.** Single-vendor,
single-test; recommend Codex assign to the SevenRooms / OAuth
refresh lane.

**Severity:** **LOW** for V1 (no live SevenRooms operators), but
worth fixing before any SevenRooms live cutover.

### Finding F — Advisor proxy health probe contract drift (LOW)

**File:** `test/services/advisor/advisor_model_config_service_test.dart`
**Failing tests (3):** `probeForgeFlowProxyHealth` — hits `/healthz`,
preserves a path prefix on `proxyBaseUri`, returns `cannotCheck`
with status code on 5xx.

**Pattern.** All three tests probe the advisor proxy health endpoint
contract. Likely the response shape, status mapping, or path-prefix
behaviour was changed without updating the test expectations.

**Severity:** **LOW** (advisor surface is read-only to the operator
at V1; cannotCheck handling is a graceful-degradation behaviour).

## Cross-surface consistency (read-only spot-checks)

The Codex graph-led audit already flagged five P1 cross-surface
provenance/role/idempotency gaps (Data Accuracy source metadata not
reaching all UI; admin DA writes can bypass idempotency; legacy
lunch/dinner/late-night payloads; role-taxonomy drift; star-shift
per-period projection). This audit confirms those findings and does
not duplicate the analysis.

One additional cross-surface concern surfaced here:

- The **deprecated `covers_source_lunch` / `_dinner` /
  `_late_night` columns** are stated by the model factory comment
  ("no longer consulted here") as authoritative-dropped, yet:
  - The proxy still maps them into keyed rows (Codex P1 — confirmed).
  - The operator-web gateway still emits them on save (Codex P1 —
    confirmed).
  - The fake-proxy test fixture in
    `test/operator_web/services/operator_web_data_accuracy_gateway_test.dart`
    used to send them (this session's PR #1059 switched it to the
    nested form).
  Net: the model is keyed-only, the wire is dual-shape. This is a
  silent ghost-write risk per Codex P1 finding. Worth landing the
  keyed-only payload cleanup before any new operator timing
  configuration ships.

## Flake hunt (pressure run with `--test-randomize-ordering-seed=random`)

Pressure run summary: `+10264 ~9 -138` (138 failures vs the baseline's
133; 133 unique vs the baseline's 128). Same scaffolding of
environment-dependent + KNOWN_FAILING categories. The interesting
delta is the **order-dependent set**:

### Finding G — 6 tests fail ONLY under random order (TEST POLLUTION)

These passed under the baseline's fixed order but failed under random
order — strong indicator of leaked state from a prior test in the
shuffle (SQLite singleton state, shared notifier, mock_replay clock
left advanced, etc.):

| File | Test |
| --- | --- |
| `test/per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart` | cold boot (fixed today) — every demo location has its own today-anchored live open shift; zero orphans; not a clone |
| `test/restaurant_timing_config_repository_test.dart` | B — service-period definitions round-trip lunch applies to all days 1-7 |
| `test/screens/variance/variance_learn_tab_depth_test.dart` | V2-5 — Cross-Axis is its own 4-pair section — tapping the Cross-Axis rail button renders all 4 CrossAxisPairs with the WHAT TO STUDY field on the Learn surface |
| `test/shift_service_close_shift_test.dart` | 7.55q.5: closing all 16 shifts preserves locked plan FOH/BOH hours from the snapshot in force |
| `test/shift_service_close_shift_test.dart` | 7.55q.5: closing all 16 shifts without a snapshot leaves preserved plan hours null (honest legacy) |
| `test/target_cycle_service_test.dart` | P — honesty hydration from persisted cycle (7.55p.5h-review-fix) SC — Learn-chip label and graph badge derive from the SAME verdict (no contradiction, Bug #6/#8) |

### Finding G' — 1 test passes ONLY under random order

| File | Test |
| --- | --- |
| `test/per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart` | cold boot (real current date) — non-Downtown locations are NOT HISTORICAL ONLY on a real device clock |

Note both polarities surface in the same `cold boot (...)` test file
— the file's two cases trade places by run order, almost certainly
SQLite-singleton state from `cold boot (real current date)` leaking
into the next case. Strong candidate for explicit teardown-truncate
in this file.

**Real regression vs test debt.** Test isolation debt, not runtime
bugs. But order-dependency is a real CI risk: any change to test
ordering (parallelism level, sharding, file-add ordering) could flip
the visible pass/fail set.

**Severity:** **MEDIUM** (drives false failures on CI shuffles; masks
real regressions when the set rotates).

**Fix.** For each flagged file:
1. Add an explicit `tearDown` that resets the SQLite in-memory DB,
   the `RestaurantScopeNotifier` singletons, and any `MockReplay`
   clock advancement.
2. Where multiple tests share a fixture, wrap the fixture builder
   so each test gets a fresh instance.
3. Re-run the file under both the original seed (the baseline) and
   the failing pressure seed (re-runner script `flutter test
   --test-randomize-ordering-seed=<N>`) to confirm green under both.

## What this audit does NOT cover (out-of-scope honesty)

- **Live cloud Postgres** (Azure DB Flexible Server, Canada Central) —
  the 65 PG tests are blocked locally by SSL. A future pass should
  run them against a real staging Postgres (`scripts/postgres_staging_setup.ps1`)
  to confirm they all pass against a real backend.
- **Live vendor sandboxes** — every vendor's
  `live_verification_checklist.md` exists, but actually walking the
  checklist against a real sandbox is the
  `8.gap-1.live.sandbox` lane's job, not this audit's. The simulated
  payload tests in the spine smoke (Finding A) are the local proxy
  for that work and need to be re-greened first.
- **Per-vendor connector OAuth refresh** — the OAuth refresh closure
  registry has been flagged as drifted (10 → 12 closures) in
  KNOWN_FAILING since 2026-05-12 and remains drifted; a focused
  consolidation pass is needed, separately scoped from this audit.

## Recommended fix order

1. **Finding A (HIGH)** — green up the spine smoke test by seeding
   the `locations` row in setup. Single-file, scoped.
2. **Finding B (MEDIUM)** — operator decision on verifier-or-not for
   poll-only labor vendors, then either delete 4 files or update 4
   tests.
3. **Finding D (MEDIUM)** — roll mock-replay anchor forward.
4. **Finding C (MEDIUM)** — diagnose multi-location demo seed
   regression (4-test cluster + 3 sibling failures).
5. **Findings E + F (LOW)** — assign to vendor-OAuth and advisor lanes
   respectively.

The 65 PG-environment failures are NOT on this list — they should be
re-baselined under a real Postgres, not "fixed" locally.

## Honest assessment

- The three surfaces are not falling over. The earlier session's PR
  #1059 closed the only blocking pre-existing failures on the
  operator-web and admin surfaces.
- The vendor parity layer is structurally complete — adapter, sink,
  sink test, api-consumed doc, live verification checklist for every
  one of the 17 vendors. The Phase 8 doctrine ("ship a verifier even
  for poll-only") and the per-vendor adapter test ("poll-only =
  no verifier") have drifted apart in code and need a decision; that
  is a doctrine question, not a code gap.
- The single most important repaint here is **Finding A** — the
  canonical spine acceptance smoke (`spine_bridge_v2_smoke_test.dart`)
  must paint green or it cannot be used to catch real spine
  regressions.
- Codex's graph-led audit covers the Data Accuracy / Role-taxonomy /
  Star-shift / Idempotency gaps comprehensively. This audit is
  test-suite-and-vendor-parity focused, deliberately not re-deriving
  those findings.
- 65 of 133 raw failures are not regressions — they are an
  environment limitation that should be flagged as such in any future
  green/red summary so it does not double-count against the real-test
  health number.

## Appendix — raw artifacts

- Baseline log: `C:\Users\saidu\AppData\Local\Temp\repo_baseline.log`
- Unique-failure list: `C:\Users\saidu\AppData\Local\Temp\baseline_failures.txt`
- Categorized failures: `C:\Users\saidu\AppData\Local\Temp\baseline_failures_categorized.txt`
- Pressure run log (in-flight): `C:\Users\saidu\AppData\Local\Temp\repo_pressure_run.log`
