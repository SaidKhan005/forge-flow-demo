# Wave 2 Execution Ledger

> **Created:** 2026-05-13, immediately after Wave 1 closed + debug.md
> audit completed (PR #646). Operator-locked decisions: roles are
> hierarchy-scoped, keep all 29 audit slices + 4 bug fixes, dual-Claude
> execution. **Status:** OPEN.
> **Owner:** main orchestrator (single writer; both executors read).

Single-source-of-truth tracker for every slice across Wave 2. Both
Claude lane orchestrators (main + second account) read this before
picking work. Pick the first slice with `state = assigned` on your lane.
Lock it by opening the PR (you don't edit this file).

Forward plan: `docs/_indices/NEXT_WAVE_PLAN.md` (the 6-phase pipeline).
Second-Claude paste-ready prompt: `docs/_indices/WAVE_2_PARALLEL_LANE_HANDOFF.md`.

## How this works

- **Executors** (main Claude orchestrator + second Claude lane orchestrator) read this ledger before picking their next slice. Pick the first slice with `state = assigned` on your owner column.
- **Main orchestrator** updates `state`, `pr`, `merged_at` columns post-merge. Executors do NOT write to this file.
- **State machine**: `assigned` → `in-progress` (PR open) → `audit-pending` (PR approved by executor's own audit, waiting on operator gate or main orchestrator merge) → `merged` (on master). Reject path: `audit-pending` → `back-to-author` (executor reopens or follow-up PR).
- **Gate column**:
  - `auto` — executor can auto-merge after their own clean audit (only for non-operator-gated lanes).
  - `operator` — operator approves before merge; main orchestrator pings.
  - `me-only` — main orchestrator handles end-to-end (some auth/RLS/schema slices stay with main to preserve audit context).
- **Owner column**: `Main` (main orchestrator session) or `Claude2` (second-Claude lane orchestrator).
- **Dependency column**: must be `merged` before the dependent slice opens.

## Concurrency rule

Two executors must not work the same slice. Owner assignment in the
ledger prevents this — Main lanes and Claude2 lanes touch different
surfaces by design. If a cross-lane dependency arises, it must be
explicit in the Dependency column.

## Operator-approval gates (recap)

Triggers the `operator` gate: auth-critical, RLS-touching, schema-touching
(migration), proxy-touching, demo-mode reader carve-out, KMS, billing,
vendor-live carve-out, **bleed-stop ceiling raises** (R-2 codified rule).

---

## Slice ledger

Source of truth for every Wave 2 slice. 33 rows (29 from
`docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md` + 4 bug fixes pulled
into Wave 2 per operator 2026-05-13).

### Lane U — UX polish bundle (Claude2)

High-velocity trivial sweeps across 14 Ops Console + 7 Mobile screens.
Each row is sub-bundle-able; Claude2 decides whether to ship as a single
mega-PR or split into per-screen PRs.

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| U-1 | Ops Console — Login screen cleanup (green-logo + subtitle removal) | Claude2 | auto | merged | #663 | – | debug.md:102-107 (OW-0a, OW-0b) |
| U-2 | Ops Console — Top bar redesign + hierarchy-map location selector | Claude2 | auto | merged | #687 | – | debug.md:102-107 (OW-0c) |
| U-3 | Ops Console — Business Account screen UX cleanup (subtitle + 4-tile removal + scope-sensitive labels) | Claude2 | auto | merged | #663 | – | debug.md:116-124 (OW-2b, OW-2c, OW-2e) |
| U-4 | Ops Console — Business Setup screen UX cleanup (subtitles, tiles, scope-sensitive tab names, simplify hierarchy labels, service-period note) | Claude2 | auto | merged | #663 | – | debug.md:127-140 (OW-3a..g) |
| U-5 | Ops Console — Locations + My Account + Team Members + Roles + Sign-in-Security + Active Sessions UX cleanup (subtitles + tiles across 6 screens) | Claude2 | auto | merged | #670 | – | debug.md:141-181 (OW-4..OW-9) |
| U-6 | Ops Console — Audit Log + Vendor Connections (rename to Vendor Integration is V-1) + Data Accuracy + Wage Authority + Notifications UX cleanup | Claude2 | auto | merged | #673 | – | debug.md:181-256 (OW-10, OW-11b/c, OW-12, OW-13a-c minus formula UI, OW-14) |
| U-7 | Mobile UX cleanup (Settings tab reorder + Setup section + Wage Setup + 2FA + Sign-in-details + Active Sessions subtitles/tiles) | Claude2 | auto | merged | #678 | – | debug.md:259-306 (MO-3a/b, MO-4, MO-5a/d, MO-6, MO-7c/d, MO-S) |
| U-FU-hp11-account | Lane U | Claude2 | operator | merged | #712 | U-1+U-3+U-4 | PR #663 worker disclosed: AccountScreen settings widgets (region, business day, identity) miss the HP #11 scope+inherited+effective triple. OW-2b / OW-2e / OW-3a scope-sensitive labels also skipped — needs scope provider plumbing into AccountScreen + BusinessSetupScreen router nav title. Shipped 2026-05-14 via PR #712 in PUNT mode (schema doesn't yet support per-location overrides for region/business-day/identity — see follow-up U-FU-hp11-account-schema). |
| U-FU-mobile-deeplink | Lane U | Claude2 | operator | merged | #600 | U-7 | PR #678 + PR #693 disclosed: MO-3c / MO-4b / MO-6d mobile deep-link patterns explicitly skipped pending B11.1. Dedicated slice to wire mobile deep-link contract once B11.1 lands. Shipped via PR #600 (Codex C-5 handoff-code deeplink, commit `161e6b85`). |
| U-FU-tier-email | Lane U | Claude2 | operator | merged | #713 | U-6 | PR #673 worker disclosed: "Request faster data freshness" dialog (OW-12h) writes audit row + toast but no email yet. Wire actual email send. Phase 9 / notification routing dependency. Shipped 2026-05-14 via PR #713 (router not yet mounted in main.dart — see follow-up U-FU-tier-email-wire). |
| U-FU-summary-strip-cleanup | Lane U | Claude2 | operator | merged | #710 | U-5 | PR #670 worker disclosed: `lib/operator_web/widgets/operator_web_summary_strip.dart` left as-is despite 3 of 5 consumers removed in U-5. Migrate or remove the remaining 2 consumers (hierarchy + audit_log + data_accuracy mount it; check current state) and delete the widget. Shipped 2026-05-14 via PR #710. |
| U-FU-hp11-account-schema | Lane U | Main | operator | parked | – | U-FU-hp11-account | PR #712 worker disclosed: AccountScreen ships HP #11 scope notice in PUNT mode because the `operators` / `restaurant_locations` schema today only supports per-location override for `locations.business_day_rollover_hour`. Per-location overrides for `region`, `formatting`, `business identity` (name, contact email, contact phone) need new nullable columns on `restaurant_locations` (or a `location_account_overrides` table) before AccountScreen's location-scope Save can be enabled. Defer to V1.1. |
| U-FU-tier-email-wire | Lane U | Main | operator | parked | – | U-FU-tier-email | PR #713 worker disclosed: the `/v1/operator/tier-email/data-freshness-request` router is tested via the test seam (`tryHandle`) but not yet mounted in `tool/advisor_proxy/main.dart`. Small mount-block addition similar to `OperatorBenchmarkOverridesRouter` at `tool/advisor_proxy/main.dart:1300-1371`. Production sends are gated on this slice landing. |

### Lane V — Vendor Connection → Vendor Integration rename sweep (Claude2)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| V-1 | Rename Vendor Connection → Vendor Integration across all consoles + mobile + notification copy | Claude2 | auto | merged | #660 | – | debug.md:183-187 (OW-11a) + notif copy debug.md:241-256 |

### Lane D — Docs + tooling (Claude2)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| D-1 | Frameworks → runbooks conversion + cross-ref updates in PROJECT_TRACKER + CLAUDE.md | Claude2 | auto | merged | #657 | – | debug.md:88 (QI-4) |
| D-2 | Central agent-self-audit script + automation glue (cleanup + archiving + audit-doc generation) | Claude2 | auto | merged | #664 | – | debug.md:88 (QI-5) |

### Lane M-Poll — Mobile new feature: Integrations tab (Claude2)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| MP-1 | Mobile new "Integrations" tab (live POS / reservation / labor status + demo-live switch placement + ops-portal deeplink with JWT handoff) | Claude2 | operator | merged | #685 | – | debug.md:289-296 (MO-7a, MO-7b) |

### Lane W — Write-path completeness (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| W-1 | Members edit-user write path (change email + name + role + hierarchy assignment end-to-end including Firebase API) | Main | operator | merged | #680 | – | debug.md:34, 152-156 (RP-11, OW-6d) |
| W-1-FU | W-1 follow-up: unlock role + hierarchy rotation in edit-member dialog (operator picked option 1 for role + hierarchy lockdown then unlock) | Main | operator | merged | #689 | W-1 | W-1 audit fallout 2026-05-14 |
| W-2 | Cancel pending invite end-to-end (operator-web + admin + Firebase API) | Main | operator | merged | #691 | – | debug.md:43 (RP-16) |
| W-3 | Profile self-service write paths (change own email + name + display details on operator-web + admin My Account; mobile becomes read-only with deep-link to operator-web) | Main | operator | assigned | – | – | debug.md:45-52, 297-302 (P-1, P-2, P-3, MO-6c/d) |
| W-4 | Admin console My Account parity (full surface on admin-side, currently missing) | Main | operator | merged | #688 | – | debug.md:52 (P-5) |
| W-5 | Business logo upload + propagation (operator-web → console header + mobile dashboard header, PNG format) | Main | operator | merged | #686 | – | debug.md:118 (OW-2d) |
| W-5-mobile-FU | W-5 follow-up: mobile dashboard header logo propagation (W-5 worker explicitly deferred mobile dashboard header logo propagation) | Claude2 | operator | assigned | – | W-5 | handoff doc `docs/_indices/CLAUDE2_HELP_QUEUE_2026_05_14.md` |
| W-5-mobile-FU-2 | Lane W | Claude2 | operator | merged | #714 | W-5-mobile-FU | PR #695 worker disclosed: proxy `AccountInfoGateway` does not yet serialize `logo_url` in its wire format. Client `fromJson` is forward-compatible so this is non-blocking, but the proxy half should ship for full round-trip. Shipped 2026-05-14 via PR #714. |
| W-6 | Account screen — timezone + missing-field exposure (location/business settings audit + write paths) | Main | operator | merged | #682 | – | debug.md:122 (OW-2g) |
| W-6-backend | W-6 backend: proxy handler for `PATCH /v1/operator/location-timezone` (W-6 worker shipped frontend wire contract; backend parked for future slot) | Main | operator | merged | #705 | W-6 | W-6 follow-up 2026-05-14; shipped 2026-05-14 via PR #705 |

### Lane H — Hierarchy visualization + HP #11 sweep (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| H-1 | HP #11 (scope/source/value) sweep for `schedule_screen.dart` + `wage_authority_screen.dart` (the 2 surfaces flagged in C-12 closeout F-OW-2) | Main | operator | merged | #659 | – | debug.md:20-25, wave audit M-4 |
| H-2 | Inheritance tree visualization on identity pages (replace text-based labels with visual hierarchy tree on business_setup_screen + business_timing_editor_screen) | Main | operator | in-progress | – | – | debug.md:131 (OW-3e) |
| H-3 | Top bar location selector — hierarchy-map picker (NOT a flat list) on operator-web + admin | Main | operator | merged | #681 | – | debug.md:106 (OW-0c, deeper part) |

### Lane R — Roles hierarchy-scoped redesign + Default Role Catalog v2 (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| R-1L | Roles hierarchy-scoped infrastructure — schema migration + RLS posture + role inheritance resolver (per locked decision: hierarchy-scoped) | Main | operator | assigned | – | – | debug.md:28, audit RP-4 / RP-6 |
| R-1L-FU | Lane R | Main | operator | merged | #715 | R-1L | PR #699 worker disclosed: R-1L shipped `permission_keys.product_label` / `category_label` / `scope_kind` as NULLABLE with inline backfill (expand-contract escape hatch per slice prompt). After one clean apply cycle on staging, flip to NOT NULL via a follow-up migration. Defense-in-depth Dart-side NOT-NULL-at-source lint already in `tool/permission_key_lint.dart` (METADATA pass). Shipped 2026-05-14 via PR #715 (R-1L-FU + R-2L-FU NOT NULL flip). |
| R-2L | Default Role Catalog v2 redesign — operator suggests seeded roles based on audit; redesign default permission set; admin selects + adjusts per-role across F&F | Main | operator | merged | #711 | R-1L | debug.md:30-32 (RP-3); 161-167 (OW-7); shipped 2026-05-14 via PR #711 |

(Lane label `R` for Roles overlaps with the refactor item names R-1 / R-2 in NEXT_WAVE_PLAN. To disambiguate, Wave 2 Lane R slices are suffixed `R-1L` / `R-2L` — the `L` is for "role lane".)

### Lane S — Specialist redesigns (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| S-1 | Wage Authority — blended-mix formula UI rewrite (FOH/BOH/Management role list with @/hr inputs + blended-mix calc display + vendor-applicability label) | Main | operator | merged | #679 | – | debug.md:198-220 (OW-13a, OW-13b) |
| S-2 | Wage Authority + Data Accuracy unified IA on single Data Accuracy page | Main | operator | merged | #684 | S-1 | debug.md:220 (OW-13c) |
| S-3 | Roles screen UX simplification (name + short description + edit button only) + role categorization by product → functionality with dependency auto-select | Main | operator | merged | #717 | R-2L | debug.md:31-32, 38-39 (RP-8, RP-12, RP-14, OW-7a..g) |

### Lane B — Bug fixes (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| B-W1 | W-1 fix: create Phase 8 base-schema migration for the 4 legacy fact tables (`shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`) — must lex-order before `202605061700_phase_8_timing_provenance_shift_records.sql` | Main | operator | merged | #662 | – | POST_HARDENING_FOLLOWUPS "Wave bugs surfaced 2026-05-13" W-1 |
| B-W2 | W-2 fix: tagged dollar-quote in `db/migrations/202605081100_partman_maintenance_hourly_cron.sql` (`do $partman$ ... $partman$;`) | Main | operator | merged | #655 | – | POST_HARDENING_FOLLOWUPS "Wave bugs surfaced 2026-05-13" W-2 |
| B-1B | BUG-1 triage: proxy returned incomplete session record after support-check sign-in — reproduce + fix + regression test | Main | operator | merged | #677 | – | debug.md:14 (BUG-1); shipped via PR #476 + regression tests PR #677 (commit `b0477670`) |
| B-2B | BUG-2 triage: proxy crash after some time — reproduce + root cause + fix (likely needs soak-harness assist from Q-1) | Main | operator | merged | #683 | Q-1 | debug.md:15 (BUG-2) |
| R-1L-FU-pre-fail | Lane B | Main | operator | parked | – | – | PR #699 worker disclosed: `test/role_admin_live_binding_test.dart` 'listVisibleRoles' expects SQL without the `r.` table alias prefix; reproduced on master `14b72714` WITHOUT R-1L changes, so it's a pre-existing master failure not introduced by R-1L. NOT in `docs/KNOWN_FAILING_TESTS.md` yet. Either: (a) add to KNOWN_FAILING_TESTS with a note pointing at the SQL alias drift, or (b) sweep slice fixes the test expectation. Out of scope for R-1L. |
| B-FU-proxy-analyze-infos | Lane B | Main | operator | merged | #709 | – | R-1L rebase worker disclosed: two pre-existing `dart analyze --fatal-infos` infos surfaced during R-1L rebase verification, both predate R-1L on master: (1) `tool/advisor_proxy/main.dart:64` duplicate import of `permission_effect.dart` introduced by commit `f651f05c` (Lane B B8.b, 2026-05-13); (2) `tool/advisor_proxy/integration_oauth_routes.dart:84` unnecessary `log.dart` import introduced by commit `363160e6` (2026-05-09). Janitorial only — delete the duplicate + the unused import. Shipped 2026-05-14 via PR #709. |

### Lane Q — Quality + longer-running (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| Q-1 | Soak harness completion + Azure Blob swap (replace GCS uploader; expose heap-snapshot capture for live multi-pod use) | Main | operator | merged | #672 | – | debug.md:16, POST_HARDENING_FOLLOWUPS "Soak Heap-Snapshot Uploader"; shipped via PR #672 (commit `a33fb80a`) |
| Q-1-FU | Q-1 follow-up: multi-pod live capture endpoint (Q-1 worker shipped Azure Blob heap-snapshot uploader; multi-pod live capture endpoint parked) | Main | operator | parked | – | Q-1 | Q-1 follow-up 2026-05-14 |
| Q-2 | Email/notification soak harness (Patrol + Firebase Test Lab + Mailosaur + SendGrid event webhook) for end-to-end loopback testing of all email + push + in-app scenarios | Main | operator | assigned | – | – | debug.md:58-67 (EN-5), 322-325 (BC-3); split into Q-2a/Q-2b/Q-2c sub-slices |
| Q-2b | Patrol harness for in-app notification surface (sub-slice of Q-2) | Claude2 | operator | merged | #704 | Q-2 | Q-2 sub-slice; shipped 2026-05-14 via PR #704 |
| Q-2c | Firebase Test Lab integration for mobile push delivery (sub-slice of Q-2) | Claude2 | operator | merged | #708 | Q-2 | Q-2 sub-slice; shipped 2026-05-14 via PR #708 |
| Q-3 | Scaffold audit lane — orphan email template purge + dispatcher cleanup + dormant invite path resolution (wire dedicated invite template OR remove + commit to Firebase password-reset path) | Main | operator | merged | #658 | – | debug.md:308-320 (BC-1, EN-2, EN-4) |
| Q-4 | Custom role editor — orphan permission lint + product-rule warnings (warn when "can manage members" excludes team.users.view; warn on location-scoped roles attempting org-wide actions; warn on orphan permission combos) | Main | operator | merged | #716 | – | debug.md:78-80 (AC-2); shipped 2026-05-14 via PR #716 |

### Lane M-Other — Mobile rest (Main)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| MO-1 | Mobile Data tab role-gated visibility (only F&F admin users see it; seeded role check) | Main | operator | merged | #661 | – | debug.md:260 (MO-2) |
| MO-1-FU | MO-1 follow-up: move `SettingsDemoLiveSwitch` out of the F&F-internal Data tab into the operator-visible Setup tab so the demo operator can still reach the master Demo→Live switch on mobile (operator picked option C 2026-05-13) | Main | operator | merged | #667 | MO-1 | MO-1 audit fallout 2026-05-13; shipped via PR #667 (commit `e73228f5`) |
| MO-2 | Mobile covers manual entry — first item on Covers Setup screen; vendor-fallback when reservation system doesn't support covers | Main | operator | merged | #676 | – | debug.md:283-285 (MO-6); shipped via PR #676 (commit `e16dff45`) |
| MO-2-FU | MO-2 follow-up: aggregator projection of `manual_cover_entries` into `ShiftRecord.covers` reader path — needs operator design input | Main | operator | parked | – | MO-2 | MO-2 audit fallout 2026-05-14 |

### Phase-7 deferred but tracked (no Wave 2 engineering)

| # | Slice | Owner | Gate | State | PR | Dep | Source |
|---|---|---|---|---|---|---|---|
| QI-10 | Operator SOP authoring | Operator | operator-only | parked-phase-7 | – | post-V1 deploy | debug.md:91 |
| QI-11 | Vendor outreach kickoff | Operator | operator-only | parked-phase-7 | – | post-V1 deploy | debug.md:92 |

---

## Counts

- 4 lanes × ~3 slices = **11 Claude2 slices**
- 7 lanes × ~3 slices = **20 Main slices**
- **2 Phase-7 deferred** (SOPs, vendor outreach)
- **33 base rows + follow-up rows accreted during execution (FU, FU-2, sub-slices, V1.1) — see live row count**

(Slight delta vs the "29 + 4 bug fixes = 33" napkin math because Lane U bundles multiple debug.md ✗ NOT DONE UX rows into per-section slices, which expanded from 1 conceptual "UX polish bundle" to 7 sub-slices. As of 2026-05-14 closeout sweep, the ledger carries Wave 2's 33 base rows plus accreted follow-up rows: Q-2 sub-slices (Q-2b, Q-2c), V1.1 FU rows (U-FU-hp11-account-schema, U-FU-tier-email-wire), and earlier-added FU rows. Detailed snapshot: `docs/_indices/NEXT_WAVE_PLAN.md` "Wave 2 status snapshot".)

## Changelog

- 2026-05-14: Wave 2 closeout sweep: 18 rows flipped to merged (5 stale-label, 13 newly-merged), 2 V1.1 follow-up rows added (U-FU-hp11-account-schema, U-FU-tier-email-wire). Stale-label rows: Q-1 (#672), MO-1-FU (#667), MO-2 (#676), U-FU-mobile-deeplink (#600 via Codex C-5), B-1B (#677). Newly-merged from this session: B-FU-proxy-analyze-infos (#709), U-FU-summary-strip-cleanup (#710), R-2L (#711), U-FU-hp11-account (#712, PUNT mode), U-FU-tier-email (#713, router not yet mounted), W-5-mobile-FU-2 (#714), R-1L-FU NOT NULL flip (#715), Q-4 (#716), S-3 (#717), Q-2b (#704, new row), W-6-backend (#705), Q-2c (#708, new row). DEBUG_MD_IMPLEMENTATION_STATUS synced; NEXT_WAVE_PLAN completed items removed; 4 pre-existing test failures added to KNOWN_FAILING_TESTS.
- 2026-05-14: R-1L merged (PR #699, commit `c92ba2e8`). Added 3 follow-up rows for disclosed gaps: R-1L-FU (NOT NULL flip on `permission_keys.product_label` / `category_label` / `scope_kind` after one clean staging apply cycle), R-1L-FU-pre-fail (pre-existing `role_admin_live_binding_test.dart` 'listVisibleRoles' SQL alias drift on master, not introduced by R-1L), B-FU-proxy-analyze-infos (2 pre-existing `dart analyze --fatal-infos` infos in `tool/advisor_proxy/` predating R-1L). None V1-blocking, all parked for after demo-validate.
- 2026-05-14: Orchestrator audited all Claude #2 merged PRs (657, 663, 664, 670, 673, 678, 685, 687, 693, 695). Added 5 follow-up rows for legitimate disclosed gaps: U-FU-hp11-account, U-FU-mobile-deeplink, U-FU-tier-email, W-5-mobile-FU-2, U-FU-summary-strip-cleanup. None V1-blocking.
- 2026-05-14: Wave 2 batch 2 flips — Main lane 10 slices (S-1, S-2, H-3, W-6, B-2B, W-1, W-1-FU, W-4, W-5, W-2) and Claude2 lane bundle merged. Added 5 follow-up rows (W-1-FU now merged; W-5-mobile-FU handed to Claude #2; W-6-backend, MO-2-FU, Q-1-FU parked). 21 of 22 Main slices merged. W-3 in flight.
- **2026-05-13** Ledger created. All 33 slices `assigned`. Lane split locked per operator decision.
- **2026-05-14** Batch 1 merged (10 slices):
  - Main orchestrator: B-W2 (#655), Q-3 (#658), H-1 (#659), MO-1 (#661), B-W1 (#662).
  - Second-Claude: V-1 (#660), U-1 + U-3 + U-4 bundle (#663), D-2 (#664).
  - New row added: MO-1-FU (in-progress) — operator picked option C on the MO-1 audit fallout (move `SettingsDemoLiveSwitch` out of the gated Data tab into the Setup tab).
  - Batch 2 in-progress (4 slices dispatched 2026-05-14): MO-1-FU, H-2, Q-1, MO-2.

## Authority anchors

- Forward plan: `docs/_indices/NEXT_WAVE_PLAN.md` (the 6-phase pipeline).
- Second-Claude handoff prompt: `docs/_indices/WAVE_2_PARALLEL_LANE_HANDOFF.md`.
- Debug-md source-of-truth: `docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md`.
- Wave 1 closeout: `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`.
- Workflow doctrine (executor-agnostic): `CLAUDE.md` "Workflow".
- Audit doc location: `docs/_audits/wave_2/pr_<n>_<topic>_audit.md` (created per slice).
