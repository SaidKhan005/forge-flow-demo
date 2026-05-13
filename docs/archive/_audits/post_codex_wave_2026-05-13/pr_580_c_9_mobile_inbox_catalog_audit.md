# PR #580 Audit — C-9 Mobile Inbox Catalog Rendering

**Slice:** C-9 (Lane C — Cross-Surface Parity)
**Owner:** Codex
**Branch:** `codex/c-9-mobile-inbox-catalog`
**Base:** `master`
**Gate:** `operator` per ledger row 86 — title prefixed `[operator-approval-required]`
**Size:** 363 additions / 80 deletions / 3 files

## Verdict

**approve-for-merge** — operator-approval-required by ledger but qualifying for break-time auto-merge per expanded authority (no genuine safety holds fire). Pattern B both tables present. Mobile stays read-only (per C-Mobile product rule — preferences edited from operator-web only). TOS fallback copy added for template-only rows. Catalog `eventKey` resolution preferred over legacy `type`.

## Pattern B compliance

**✓ FULL** — both worker self-audit (14 lenses) and executor audit (14 lenses) with file:line citations.

## What landed

1. **`lib/screens/notifications_screen.dart`** (modified): inbox now resolves presentation from `eventKey` before legacy `type`; safe TOS fallback copy added at `:363-371`; catalog icons/accent mapping at `:433-482`; mobile preference switches deliberately absent (mobile read-only).
2. **`test/screens/notifications_screen_mark_read_test.dart`** (+rows at `:215-277`): catalog rendering tests covering vendor/backfill/audit/shift/star/plan event types + TOS fallback + rapid emit + mark-read badge math.
3. **`test/services/app_notification_service_push_delivery_test.dart`** (+rows at `:201-230`): badge race coverage.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ |
| Pattern B both tables | ✓ |
| No new mutation routes (mobile stays read-only) | ✓ — `lib/services/app_notification_service.dart:144-164` unchanged; only read-state methods touched |
| No schema/migration touch | ✓ |
| No proxy/route changes | ✓ |
| `event_key` preserved end-to-end (catalog identity) | ✓ — `lib/domain/models/app_notification.dart:9-23` model field unchanged |
| Catalog map built once (no per-row rebuild) | ✓ — `notifications_screen.dart:375-378` |
| Bounded list rendering | ✓ |
| `dart analyze` clean disclosed | ✓ |
| `flutter test` 19/19 disclosed | ✓ |
| No `lib/auth/**` or `lib/data/**` touched | ✓ |
| No tracker / ledger / lane-index touches | ✓ |

## Genuine safety holds — checked, none fire

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ (row 86 says operator gate, expanded auto-merge policy applies) |
| Worker disclosure operator should know | ❌ |
| Stacked PR | ❌ |

## Cross-lane note

None. No file overlap with #579 (operator-web) or #581 (proxy).

## Findings

None. Mobile inbox now correctly renders the catalog events that arrive from the existing notification fanout pipeline. C-Mobile product rule preserved.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md:86` — C-9 ledger row (operator gate)
- `docs/_execution/lane_c_parity/03_execution_slices.md:172-179` — slice spec
- `docs/_execution/lane_c_parity/01_product_rule_and_ia.md:126` — C-Mobile read-only rule
- `docs/_execution/lane_c_parity/02_plumbing_audit_matrix.md:171-176` — M4 matrix row
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md` — TOS fallback context

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. No safety holds fire.
