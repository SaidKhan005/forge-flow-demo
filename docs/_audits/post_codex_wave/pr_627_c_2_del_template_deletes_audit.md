# PR #627 Audit — C-2-Del Template Deletes (E + G) (Claude)

**Slice:** C-2-Del (Lane C — Cross-Surface Parity; operator-picked DELETE for matrix drafts E + G)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/c-2-del-webhook-signature-tos`
**Base:** `master` @ `c9266236`
**Gate:** auto — operator pre-approved DELETE for both E + G on 2026-05-13 picks (recorded in PR #619)
**Risk:** **Low** — mechanical content delete; no proxy code, auth, migration, or runtime path touched; mirrors A2.2 PR #540 verbatim
**Size:** 63 additions / 134 deletions / 8 files (light variant audit)

## Verdict

**approve-for-merge** — auto-merging per expanded delegation. Operator already approved DELETE for both Draft E (`vendor_webhook_signature_alert`) and Draft G (`tos_version_updated_notice`) on 2026-05-13's open-decisions slate. Worker executed a mechanical delete mirroring A2.2 PR #540's idiom verbatim: 2 `.md` templates deleted, 2 `EmailTemplateIds` constants + subject-map entries removed, 2 pressure-inventory rows removed, plus matrix doc + inventory doc reconciliation.

## Pattern B compliance

**✓ EXEMPLARY** — PR body includes Pattern B 8-lens self-audit; new pinning test in `p5_email_scenario_loopback_test.dart` asserts the deleted ids are absent (regression armor for any future drift). Citations to A2.2 PR #540 precedent + operator's C-2 picks doc (`docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` Drafts E + G).

## What landed

| File | LoC | Kind |
|---|---|---|
| `tool/advisor_proxy/email_templates/vendor_webhook_signature_alert.md` | 0 / -20 | **DELETED** — Draft E content template |
| `tool/advisor_proxy/email_templates/tos_version_updated_notice.md` | 0 / -17 | **DELETED** — Draft G content template |
| `lib/services/email/email_template_renderer.dart` | 0 / -40 | DELETE — `EmailTemplateIds.vendorWebhookSignatureAlert` + `tosVersionUpdatedNotice` constants + their subject map entries + `EmailTemplateIds.all` list entries |
| `tool/pressure/p5_email_scenario_loopback.dart` | +8 / -20 | DELETE inventory rows — 2 deferred scenarios removed; rationale comment added |
| `test/services/email/email_template_renderer_test.dart` | +15 / -16 | UPDATE — `EmailTemplateIds.all` count 10 → 8; `isNot(contains(...))` pins for deleted ids; deleted variable bindings for now-unused template vars |
| `test/pressure/p5_email_scenario_loopback_test.dart` | +18 / -3 | UPDATE — deferred-ids test list trims to 3 (was 5); new "does not contain the C-2-Del deleted templates" pinning test |
| `docs/_audits/code_health/c_email_notification_scenario_inventory.md` | +18 / -14 | RECONCILE — mark §4.c and §8.a as DELETED via C-2-Del; aggregate matrix row updates; count "8 repo-owned Markdown templates" |
| `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` | +4 / -4 | RECONCILE — flip Drafts E + G rows from "DEFER wire" to "DELETED — landed via C-2-Del" |

**Net effect:** scope reduction. Email template catalog drops from 10 → 8 ids. C-2 matrix Drafts E + G permanently retired per operator pick. The runtime signals operator opted for instead:
- **E**: Cloud Logging alerts + existing signature-verifier unit tests (`test/integrations/**/*_webhook_signature_verifier_test.dart`).
- **G**: In-app TOS-accept screen gate at `lib/operator_web/screens/tos_accept_screen.dart` fires the next time the operator signs in after a new TOS version lands.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` untouched | `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines | Independent diff confirms; bleed-stop posture preserved (template `.md` files in `email_templates/` subdir are content assets, not proxy code per A2.2 PR #540 precedent) |
| `tool/advisor_proxy/main.dart` untouched | diff scope | 0 lines |
| `tool/advisor_proxy/proxy_bootstrap.dart` untouched | diff scope | 0 lines |
| `tool/advisor_proxy/email_dispatch/` untouched | diff scope | 0 lines (dispatcher code unchanged; only template content removed) |
| `lib/auth/` untouched | diff scope | 0 lines |
| `db/migrations/` untouched | diff scope | 0 lines |
| `pubspec.yaml` untouched | diff scope | 0 lines |
| `WAVE_EXECUTION_LEDGER.md` untouched | diff scope | 0 lines (orchestrator's job at merge) |
| 2 template files deleted | `git diff --stat` | `vendor_webhook_signature_alert.md` + `tos_version_updated_notice.md` confirmed deleted |
| 2 `EmailTemplateIds` constants removed | `email_template_renderer.dart:138-154, :167-183` | Confirmed in diff |
| 2 subject map entries removed | `email_template_renderer.dart:233-237` | Confirmed in diff |
| `EmailTemplateIds.all` count 10 → 8 | test diff | Test pins new count + `isNot(contains(...))` for both deleted ids |
| Pinning test added | `p5_email_scenario_loopback_test.dart` "does not contain the C-2-Del deleted templates" | Regression armor: future drift would trip the test |
| 92 email service tests pass | disclosed | `flutter test test/services/email/` → green |
| 36 pressure loopback tests pass | disclosed | includes new pinning test |
| 5 notifications screen tests pass | disclosed | `lib/screens/notifications_screen.dart` untouched (in-app inbox eventKey, separate subsystem; correctly left alone per worker disclosure) |
| `dart analyze --fatal-infos` clean | disclosed | No issues on all touched dart files |
| `advisor_proxy_size_lint` clean | disclosed | Pre-push hook clean |
| `postgres_import_lint` clean | disclosed | Pre-push hook clean |
| `audit_logs_update_lint` clean | disclosed | Pre-push hook clean |
| No `--no-verify` traces | confirmed | Pre-push hooks ran clean |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Product & Journey | OK | Operator picked DELETE for both — alternative operator signals (Cloud Logging for E, in-app TOS gate for G) remain intact |
| L2 IA & Navigation | OK | No screen/route change |
| L3 Data Model / Migration / RLS | OK | No schema/migration touch |
| L4 Repository & Service | OK | `email_template_renderer.dart` shrinks; no service contract change |
| L5 Proxy / Route / Gateway | OK | Proxy code untouched; only content templates removed (per A2.2 PR #540 precedent) |
| L6 Auth / Roles / Permissions | OK | `lib/auth/` 0-line diff |
| L7 Lifecycle | OK | No new lifecycle introduced; templates simply no longer exist |
| L8 Workers / Deploy / Health | OK | No worker config touched; no runtime path affected (templates had no enqueuers per the matrix doc) |
| L9 UI / UX / Accessibility | OK | In-app TOS-accept screen UX preserved (worker correctly identified this as the operator's chosen TOS signal) |
| L10 Performance | OK | Catalog shrinks; renderer hot path simpler |
| L11 Parity | OK | Mirrors A2.2 PR #540 (operator_admin_invite + password_reset_request deletes) verbatim |
| L12 Tests / Builds / Evidence | OK | 92 + 36 + 5 = 133 tests pass; all lints clean; pinning test armor added |
| L13 Observability / Audit | OK | No audit-bearing path changed |
| L14 Docs / Tracker / Hygiene | OK | Inventory + decisions doc reconciled in lockstep; no ledger touch (orchestrator's job) |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `c9266236` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables present | ✓ — worker 8-lens + this 14-lens executor table |
| 8 files match PR body declaration | ✓ — `git diff --stat` confirms |
| `tool/advisor_proxy/advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `tool/advisor_proxy/main.dart` diff = 0 lines | ✓ |
| `tool/advisor_proxy/proxy_bootstrap.dart` diff = 0 lines | ✓ |
| `tool/advisor_proxy/email_dispatch/` diff = 0 lines | ✓ |
| `lib/auth/` diff = 0 lines | ✓ |
| `db/migrations/` diff = 0 lines | ✓ |
| Pinning test against the 2 deleted ids present | ✓ — `test/pressure/p5_email_scenario_loopback_test.dart` new "does not contain the C-2-Del deleted templates" test |
| In-app TOS-accept screen path untouched | ✓ — `lib/operator_web/screens/tos_accept_screen.dart` not in diff |
| `notifications_screen.dart` untouched (separate inbox eventKey subsystem) | ✓ — worker disclosure correct; not in diff |
| Operator's pre-approval recorded | ✓ — `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` "Operator picks — 2026-05-13" landed via PR #619 |
| No `--no-verify` traces | ✓ |
| No tracker / ledger touches | ✓ |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — C-2 picks already approved + recorded on master (PR #619) |
| Worker disclosure operator should know | ❌ — none |
| Stacked PR | ❌ — base is master |
| Schema/RLS/proxy-code/auth touch | ❌ — content-only delete |

**Decision**: auto-merge per expanded delegation. Operator pre-approved both DELETE picks 2026-05-13.

## Cross-lane notes

- **Advances C-2** — Drafts E + G now fully resolved (DELETED, with armor).
- **C-2 group state after this PR**: Drafts C, D, F still in flight (3 background agents running for wire-side slices).
- **No conflict with C-2-C / C-2-D / C-2-F** — those wires add new ids; this delete removes 2 different ids; no overlap on the same template id.
- **No Codex-owned files touched** — pure Claude-territory.

## Findings

None.

## Authority anchors

- `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` (Drafts E + G "DELETED — landed via C-2-Del" rows)
- `docs/_audits/post_codex_wave/pr_540_a_2_2_template_delete_audit.md` — precedent same-shape PR (`operator_admin_invite` + `password_reset_request` deletes)
- `docs/_audits/post_codex_wave/pr_619_c_2_picks_recorded_audit.md` — operator's pre-approval recording
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md` — inventory doc reconciled in this PR
- Operator's 2026-05-13 "keep 2fa, pos connection and vendor connection only" answer + "yes to all" delegation

## Status

**Auto-merging** per expanded delegation.
