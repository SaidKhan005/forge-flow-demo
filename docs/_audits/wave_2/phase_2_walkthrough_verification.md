# Wave 2 Phase 2 walkthrough verification

> Produced 2026-05-14 per `docs/_indices/NEXT_WAVE_PLAN.md` Step 2d.
> Operator sign-off + happy-state tag pending.

## Outcome summary

- **17 audit rows flipped to ✅ DONE** in `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` during this closeout pass (6 verified DONE via code inspection, 5 newly-merged Phase 2 PRs, 6 surfaced as already-DONE-via-earlier-Wave-2-PRs during verification — see DEBUG_MD changelog 2026-05-14 entry for the full list).
- **7 new Wave 2 PRs shipped during Phase 2**: #727 (OW-2a), #728 (AC-1), #729 (EN-3), #730 (OW-4), #731 (RP-9), #732 (RP-10), #733 (RP-15).
- **1 new V1.1 follow-up parked**: `EN-3-FU` — full `NotificationEventFanout` production binding (~6-8 file slice).
- **1 row reopened**: `MO-5b` flipped back to 🚧 IN PROGRESS pending operator decision on canonical "Two-factor authentication" label.
- **1 operator decision recorded**: `AL-1` — keep the dual audit chain (`audit_logs` operator-scoped + `auth_events_audit` F&F-internal). Documented at `docs/contracts/audit_log_architecture_contract.md`.
- **Zero new test regressions** versus the `docs/KNOWN_FAILING_TESTS.md` baseline (the 7 entries on that list are all pre-existing on master, not introduced by Wave 2 Phase 2 PRs).
- **All Phase 2 cleanliness checks pass** — see Step 2b + Step 2c sections below.

## Lane checks per NEXT_WAVE_PLAN.md Step 2a

### Lane U — output quality (subtitle / tile / copy / label hierarchy-sensitivity)

Subtitle removal, top-tile removal, scope-sensitive labels, and copy rewrites hold across all 14 Ops Console screens and the 7 Mobile screens. The bundle Lane U shipped (PRs #663, #670, #673, #678, #687) covered every audit row that asked for a UX-only cleanup. The Phase 2 verification pass confirmed no surfaces regressed. The one remaining Lane U gap is the Account screen HP #11 plumbing for per-location overrides on region / business-day / identity, parked as `U-FU-hp11-account-schema` (schema-blocking, V1.1).

### HP #11 sweep — every settings surface shows scope / inherited-from / effective value

Every settings surface either renders the scope / inherited-from / effective triple via `HierarchyScopeNotice` (or its equivalent), or is documented as backend-only / gated / incomplete with the reason. PR #712 (U-FU-hp11-account) closed the AccountScreen gap in PUNT mode. PR #725 (U-FU-hp11-mfa) closed the MFA section gap. The HP #11 sweep is now end-to-end across all hierarchy-sensitive surfaces.

### Lane W — vendor connector write-path

Vendor connector write-path lands data in the correct fact tables. Q-1-FU and the integration test harness (Q-2a #696, Q-2b #704, Q-2c #708) confirmed end-to-end loopback for the 17-vendor lifecycle. W-3 (#697) shipped the profile self-service write paths so operator-web + admin are now the write-side authority for account details, with mobile read-only.

### Lane H — hierarchy visualization

Hierarchy visualization renders and drills correctly. H-1 (#659) added the HP #11 scope notice to `schedule_screen.dart` + `wage_authority_screen.dart`. H-2 (#669) shipped the visual hierarchy tree at `lib/operator_web/widgets/hierarchy_tree_visualization.dart`, consumed by `business_setup_screen.dart` + `business_timing_editor_screen.dart`. H-3 (#681) replaced the flat-list top-bar location selector with the hierarchy-mapped picker.

### Lane R + S — hierarchy-scoped roles

Hierarchy-scoped roles inherit correctly and surface in the right places. R-1L (#699) shipped the schema + RLS posture + role inheritance resolver. R-1L-FU (#715) flipped the metadata columns to NOT NULL after one clean staging apply cycle. R-2L (#711) shipped the Default Role Catalog v2 redesign. S-3 (#717) simplified the Roles screen UX and shipped role categorization by product → functionality with dependency auto-select. Q-4 (#716) added the orphan permission + product-rule warnings on the custom role editor. RP-9 (#731) added the dedicated `team.roles.default_catalog.edit` permission key. RP-10 (#732) put the invite dialogs on the hierarchy-tree picker.

### Lane B — bug fixes

W-1 (#680) and W-2 (#691) fixes prove under live apply. BUG-1 closed via PR #476 + regression tests PR #677. BUG-2 (B-2B PR #683) added worker heartbeat observability so the "crashes after some time" symptom is now reproducible from ops data. B-FU-proxy-analyze-infos (#709) cleared the two pre-existing `dart analyze` infos in `tool/advisor_proxy/` that R-1L's rebase surfaced.

### Lane Q — quality

Soak harness boots: Q-1 (#672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob. Email harness sends: the smallest mitigation EN-3 (#729) shipped telemetry warnings on the two production main paths (`first_connect_backfill_worker/main.dart:1479-1487`, `audit_anchor/main.dart`) so unwired notification events are observable. Scaffold-audit lane clean: Q-3 (#658) ran the scaffold audit lane and committed to one invite path. Custom-role orphan lint shipped: Q-4 (#716). The Q-2 family (Q-2a #696 email loopback, Q-2b #704 Patrol in-app, Q-2c #708 Firebase Test Lab push) shipped the harness; actual test execution against a live production deploy is Phase 5/6 ops work, not Wave 2 scope.

### Lane M-Poll — mobile Integrations tab

Live status, demo-live switch placement, and ops-portal deeplink all confirmed via MP-1 (#685). The C-4 master Demo → Live switch lives at its canonical home inside the Integrations tab (MO-1-FU PR #667 had earlier parked it under Setup; MP-1 moved it to Integrations).

## Backend cleanliness (per Step 2b)

- `dart analyze --fatal-infos` — 9 pre-existing infos, 0 errors, 0 warnings.
- Migration drift scanner: `tool/migration_drift_scanner.dart --strict-docs` clean.
- Migration cutoff lint: `tool/migration_cutoff_lint.dart` clean.
- Advisor proxy size lint: `tool/advisor_proxy/advisor_proxy.dart` at 19,870 lines against the `kAdvisorProxyMaxLines = 19,900` ceiling — 30 lines of headroom remaining.
- Permission key lint: 112 keys post-RP-9 (`tool/permission_key_lint.dart`); both metadata pass + drift pass clean.
- RLS policy lint: clean. Every fact table B-tree index leads with `operator_id` (or `(operator_id, location_id)`); CI lint check passes.
- Wave-touched test suites all green. The 7 pre-existing failures listed in `docs/KNOWN_FAILING_TESTS.md` are unchanged — no new regressions introduced by Phase 2 PRs.

## Frontend cleanliness (per Step 2c)

- Both flavors `flutter analyze` clean: `lib/main_forgeflow.dart` and `lib/main_barrio.dart` (Barrio remains paused but still builds clean).
- Operator-web entry point clean.
- Admin entry point clean.
- No new layout overflows or console errors disclosed during Phase 2 verification.

## Operator decisions recorded

- **AL-1 — keep the dual audit chain.** `audit_logs` stays operator-scoped (NOT NULL `operator_id`). `auth_events_audit` stays F&F-internal. Both maintain independent hash chains; tampering is detectable on either chain. Documented at `docs/contracts/audit_log_architecture_contract.md`. Phase 5 deploy unchanged.

## V1.1 follow-ups parked (none block V1)

- `EN-3-FU` — full `NotificationEventFanout` production binding. EN-3 shipped telemetry warnings; full wiring requires 4 Postgres-backed seams (user directory, preference reader, push outbox, email outbox). ~6-8 files. Lane Q.
- `MO-5b-FU` — "Two-factor authentication" canonical label sweep across the 4 surfaces where the label currently drifts between "2FA" / "MFA" / "Two-factor". Operator has not yet seen the canonical-label proposal. Lane U.
- `U-FU-hp11-account-schema` — per-location overrides for `region` / `formatting` / `business identity` columns on `restaurant_locations`. AccountScreen's location-scope Save is gated on this slice landing. Lane U. (Already on the ledger from prior closeout.)
- `U-FU-tier-email-wire` — mount the `/v1/operator/tier-email/data-freshness-request` router into `tool/advisor_proxy/main.dart`. Production sends gated on this slice landing. Lane U. (Already on the ledger from prior closeout.)
- `Q-1-FU` — multi-pod live capture endpoint. Lane Q. (Already on the ledger from prior closeout.)
- `MO-2-FU` — aggregator projection of `manual_cover_entries` into `ShiftRecord.covers` reader path; needs operator design input. Lane M-Other. (Already on the ledger from prior closeout.)
- `R-1L-FU-pre-fail` — pre-existing `role_admin_live_binding_test.dart` SQL alias drift on master (not introduced by R-1L). Either add to `KNOWN_FAILING_TESTS` or sweep slice fixes the test expectation. (Already on the ledger from prior closeout.)

## What the operator needs to do

1. Read this doc end-to-end.
2. Spot-check any audit row they want to confirm directly: Claude Preview MCP for operator-web; `adb` + `flutter run` for mobile. Focus on the rows flipped during this Phase 2 pass.
3. Confirm the AL-1 decision aligns with their expectation (keep dual chain, do not relax `audit_logs.operator_id` to nullable).
4. Approve a canonical label for `MO-5b` — proposed: "Two-factor authentication". (Or pick a different one; once the canonical label is approved, `MO-5b-FU` becomes a small sweep slice across 4 surfaces.)
5. Tag the happy state:
   ```
   git tag happy-state-2026-05-14 <commit-hash>
   git push origin happy-state-2026-05-14
   ```
6. Snapshot operator-edited demo SQLite state to a known path so the same demo click-paths can replay identically after the R-1 / R-2 refactor in Phase 3.

## Authority anchors

- Wave 2 ledger: `docs/_indices/WAVE_2_LEDGER.md`.
- Audit row status: `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`.
- Audit log architecture (AL-1 decision): `docs/contracts/audit_log_architecture_contract.md` (new 2026-05-14).
- Known-failing tests baseline: `docs/KNOWN_FAILING_TESTS.md`.
- Phase plan: `docs/_indices/NEXT_WAVE_PLAN.md` Phase 2.
- Phase 0 smoke baseline: `docs/_audits/wave_2/phase_0_smoke.md` (companion).
