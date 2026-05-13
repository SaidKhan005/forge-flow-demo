# PR #629 Audit — C-2-C `mfa_factor_changed_notice` Wire (Removal-Only Sub-Path) (Claude)

**Slice:** C-2-C (Lane C — Cross-Surface Parity; matrix Draft C WIRE)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/c-2-c-mfa-factor-changed-wire`
**Base:** `master` @ `ab4606ef` (post-C-2-Del)
**Gate:** **operator-approval-required** — auth-critical (MFA factor lifecycle email) + proxy-touching (`proxy_bootstrap.dart` +33 LoC dispatcher wiring)
**Risk:** **Medium** — new dispatcher invoked inside the MFA removal worker's atomic-completion transaction; new admin-pool read on `users` table; new `NotificationCategory.security`; new catalog event `notif.mfa.factor_changed`; ~470 LoC production code
**Size:** 1252 additions / 2 deletions / 8 files

## Verdict

**approve pending operator OK** — audit clean. Worker self-flagged `[operator-approval-required]` correctly. Implementation is careful: pre-transaction contact lookup (non-fatal failure path: removal completes regardless of email reachability), atomic in-transaction enqueue + audit + outbox commit, single-recipient direct dispatcher (not fanout — correct call for 1:1 event), backendOnly/Always-on catalog entry (security notification cannot be opt-out toggled), proxy `advisor_proxy.dart` headroom unchanged at 88.

Operator picked WIRE for Draft C on 2026-05-13's open-decisions slate. Worker picked sub-path (1): **removal-only** (skip enrollment until server-side enrollment hook exists) — correct given MFA enrollment is currently client-side at `lib/services/mfa/mfa_enrollment_service.dart` with no server-side trigger point. The per-PR sign-off is the merge-time gate.

## Pattern B compliance

**✓ EXEMPLARY** — Pattern B 8-lens self-audit in PR body. Honest disclosures: catalog-key naming (new `NotificationCategory.security`), choice rationale (direct dispatcher vs fanout: MFA is 1:1, fanout would broaden role-gate machinery for one event), backendOnly registration (security notification, not toggleable), idempotency-key shape for reconciliation tooling.

## What landed

| File | LoC | Kind |
|---|---|---|
| `lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart` | +318 / 0 | **NEW** — single-recipient dispatcher; on-executor `enqueue` seam so email enqueue commits atomically with worker's completion transaction; mirrors `VendorLifecycleNotificationDispatcher` orchestrator shape |
| `lib/services/mfa/mfa_removal_worker.dart` | +67 / 0 | EXTEND — optional `factorChangedNoticeDispatcher` param (null-tolerant); pre-transaction system-pool contact lookup with non-fatal failure path; in-transaction dispatch invoked inside existing atomic-completion body |
| `lib/infrastructure/persistence/postgres/repositories/users_repository.dart` | +86 / 0 | EXTEND — new `findUserContactSystem` admin-pool read (email + display_name with GDPR-redaction skip); new `UserContactProjection` narrow projection class |
| `lib/domain/models/notification_event_catalog.dart` | +20 / -1 | EXTEND — new `NotificationCategory.security` enum value; new `notif.mfa.factor_changed` catalog entry with `roleGate: any` + `defaultChannels: {email, inbox}`; new "Account security" label |
| `lib/operator_web/screens/settings_notifications_screen.dart` | +8 / 0 | EXTEND — `notif.mfa.factor_changed` registered as `_NotifEventState.backendOnly` (label: "Always on"; security event, not toggleable from prefs screen) |
| `tool/advisor_proxy/proxy_bootstrap.dart` | +33 / 0 | EXTEND — production binding wires `MfaFactorChangedNoticeDispatcher` into `MfaRemovalWorker` with admin-audit emit closure + production `accountSecurityUrl` = `https://app.forgeflow.app/account/security` |
| `test/services/mfa/mfa_factor_changed_notice_dispatcher_test.dart` | +523 / 0 | **NEW** — 7 cases: happy path, idempotency-key stability + change on different `removedAt`, salutation resolution (display name / local-part / fallback "there"), blank-email skip, changeDescription branching |
| `test/mfa/mfa_removal_worker_test.dart` | +197 / -1 | EXTEND — 2 new worker-integration cases driving the wire end-to-end with `_UsersFake` extension |

**Net effect:** when the MFA removal worker completes a 24-hour revocation, it now enqueues one `email_outbox` row addressed to the user whose factor was removed (single-recipient), audits the enqueue under `system.mfa_factor_changed_notice_audit`, and commits atomically with the existing `markCompleted + audit + outbox` transaction. Recipient is always the affected user (not cross-operator admins).

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` untouched | `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines | **bleed-stop ceiling preserved at 88 headroom** per worker disclosure |
| `lib/auth/` untouched | diff scope | 0 lines — auth permission catalog unchanged |
| `db/migrations/` untouched | diff scope | 0 lines — no schema change; uses existing `email_outbox` + `audit_logs` + `users` |
| `pubspec.yaml` untouched | diff scope | 0 lines — no new package dep |
| `WAVE_EXECUTION_LEDGER.md` untouched | diff scope | 0 lines (orchestrator's job at merge) |
| `mfa_factor_changed_notice.md` template UNTOUCHED | diff scope | 0 lines (only wired, not modified) |
| No new permission key | diff scope | system actor uses existing service-principal posture |
| Optional dispatcher seam (null-tolerant) | `mfa_removal_worker.dart:79` | `MfaFactorChangedNoticeDispatcher? factorChangedNoticeDispatcher` — existing tests + degraded mode work unchanged |
| Pre-transaction contact lookup, non-fatal | `mfa_removal_worker.dart:204-225` | Lookup failure → `userContact = null`; removal completes regardless |
| In-transaction enqueue + audit + outbox commit atomically | `mfa_removal_worker.dart:308+` | Dispatcher invoked inside `MfaFactorRemovalRequestsRepository.withTenant` body after `markCompletedInTransaction` returns >0 |
| Single-recipient (not cross-tenant fanout) | dispatcher impl | Direct email to the user whose factor was removed; mirrors existing in-app inbox emit posture (`AppNotificationService.emitMfaAuthenticatorRemoved`) |
| Idempotency: `markCompletedInTransaction` short-circuit + stable key | dispatcher + worker | Primary boundary = worker's `markCompletedInTransaction > 0` guard; secondary key `notif.mfa.factor_changed:<userId>:<factorId>:<removedAtIso>` for reconciliation tooling |
| Append-only `audit_logs` | dispatcher | INSERT only via `AuthEventsAuditRepository.insertSystemEventOn`; SOC-2 hash chain preserved |
| `backendOnly` (Always on) catalog state | `settings_notifications_screen.dart:[notif.mfa.factor_changed]` | Security event cannot be opt-out toggled from prefs screen |
| `NotificationCategory.security` added correctly | `notification_event_catalog.dart:28 + :189` | Enum + label map both updated |
| `roleGate: any` + `defaultChannels: {email, inbox}` | catalog entry | Correct shape; recipient is the affected user regardless of role |
| Production `accountSecurityUrl` hardcoded | `proxy_bootstrap.dart:1152` | `https://app.forgeflow.app/account/security`; worker disclosed future per-flavor parameterization |
| `dart analyze --fatal-infos` clean | disclosed | No issues |
| `advisor_proxy_size_lint` clean — **headroom unchanged at 88** | disclosed | 19812 lines, ceiling 19900 |
| `postgres_import_lint` clean | disclosed | Pre-push hook clean |
| `audit_logs_update_lint` clean | disclosed | Pre-push hook clean |
| 7 dispatcher tests + 2 worker-integration tests pass | disclosed | New tests |
| 169 existing MFA + email-service tests pass | disclosed | No regression |
| 11 existing `mfa_operations_gateway` tests pass | disclosed | No regression |
| 10 existing `settings_notifications_screen` tests pass | disclosed | No regression on the rendering surface |
| No `--no-verify` traces | confirmed | Pre-push hooks ran clean |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Product & Journey | OK | Operator picked WIRE for Draft C; sub-path 1 (removal-only) is correct given client-side enrollment lacks a server-side hook. Adaptive 2FA button (C-7) reads `recovery_codes_viewed_at` independent of this wire |
| L2 IA & Navigation | OK | `accountSecurityUrl` deeplinks to `/account/security`; matches operator-web routing |
| L3 Data Model / Migration / RLS | OK | No schema change; uses existing `email_outbox` + `audit_logs` + `users`; `findUserContactSystem` uses admin pool with explicit `adminReason` audit |
| L4 Repository & Service | OK | New `UserContactProjection` narrow read; dispatcher accepts `PostgresExecutor` from caller's transaction (proper transaction discipline) |
| L5 Proxy / Route / Gateway | OK | `proxy_bootstrap.dart` adds dispatcher wiring only (no new route); proxy.dart headroom unchanged at 88 |
| L6 Auth / Roles / Permissions | OK | `lib/auth/` 0-line diff; no new permission key; system-principal actor reused; `roleGate: any` correct for self-event |
| L7 Lifecycle | OK | Hooks off existing MFA removal worker completion; non-fatal contact lookup; one-shot per request matches removal lifecycle |
| L8 Workers / Deploy / Health | OK | Cloud Run binary picks up new dispatcher via `buildProxyProductionBindings`; existing fanout/dispatch infra unchanged |
| L9 UI / UX / Accessibility | OK | Settings Notifications screen registers entry as backendOnly ("Always on" label) — security events are non-toggleable, correct UX posture |
| L10 Performance | OK | One extra SELECT + INSERT per removal (rare event); idempotency via worker short-circuit; no additional fanout walking |
| L11 Parity | OK | Mirrors `VendorLifecycleNotificationDispatcher` orchestrator shape; same `email_outbox` shape; same `system.X_audit` action naming |
| L12 Tests / Builds / Evidence | OK | 9 new tests; 4 existing test suites still pass; all lints clean |
| L13 Observability / Audit | OK | Audit row per enqueue under `system.mfa_factor_changed_notice_audit`; SOC-2 hash chain preserved (append-only INSERT) |
| L14 Docs / Tracker / Hygiene | OK | No tracker/ledger touch per worker contract; matrix doc already reflects WIRE pick from PR #619 |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `ab4606ef` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables | ✓ — worker 8-lens + this 14-lens table |
| 8 files match PR body declaration | ✓ — `git diff --stat` confirms (note: `+1252/-2` vs worker's `+1252/-2`) |
| `tool/advisor_proxy/advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `lib/auth/` diff = 0 lines | ✓ |
| `db/migrations/` diff = 0 lines | ✓ |
| `pubspec.yaml` diff = 0 lines | ✓ |
| `mfa_factor_changed_notice.md` template diff = 0 lines | ✓ |
| `WAVE_EXECUTION_LEDGER.md` diff = 0 lines | ✓ |
| `NotificationCategory.security` added + labeled | ✓ — both enum + label map |
| Catalog entry `notif.mfa.factor_changed` correct shape | ✓ — `roleGate: any` + `defaultChannels: {email, inbox}` |
| `backendOnly` registration on Settings screen | ✓ — non-toggleable "Always on" |
| Optional dispatcher param wired through worker | ✓ |
| Pre-transaction contact lookup with non-fatal swallow | ✓ |
| In-transaction enqueue + audit commit atomically | ✓ |
| Production `accountSecurityUrl` hardcoded | ✓ — worker disclosed; future per-flavor parameterization noted |
| No `--no-verify` traces | ✓ |
| `advisor_proxy_size_lint` headroom = 88 | ✓ disclosed |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — matches operator's 2026-05-13 WIRE pick for Draft C |
| Worker disclosure operator should know | ⚠ ONE disclosure: new `NotificationCategory.security` introduced (no existing category fit MFA). Backward-compatible (additive). |
| Stacked PR | ❌ — base is master |
| **Auth-critical / proxy-touching** | **✓ TRIGGERED** — MFA factor lifecycle email + `proxy_bootstrap.dart` wiring — operator approval gate per CLAUDE.md |

**Decision**: **HOLD for explicit operator approval**. Audit verdict: approve-on-sign-off.

## Cross-lane notes

- **Advances C-2** — Draft C WIRE landing means matrix is D in flight + E, G deleted + C, F about-to-land.
- **Removal-only sub-path** — enrollment-side email deferred until server-side enrollment hook exists (worker disclosure correct: `lib/services/mfa/mfa_enrollment_service.dart` is currently client-side; no server trigger point).
- **`NotificationCategory.security` is now available** for future security-event catalog entries (no other consumers yet).
- **Backend-only catalog state is correct UX** — security notifications should not be opt-out toggleable from the prefs screen.
- **`accountSecurityUrl` hardcoded for V1** — future slice parameterizes per-flavor when F&F operator-web flavor split happens; dispatcher signature is stable.

## Findings

None blocking. One non-blocking note: `accountSecurityUrl` is hardcoded; if F&F operator-web ever splits into per-flavor entries (e.g. Barrio rebrand), this URL needs a config seam. Worker disclosed inline.

## Authority anchors

- `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` Draft C WIRE pick (operator 2026-05-13)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row C-2-C
- `tool/advisor_proxy/email_templates/mfa_factor_changed_notice.md` — template the dispatcher feeds (untouched on master)
- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart` — precedent pattern this PR mirrors
- `lib/services/mfa/mfa_removal_worker.dart` (master) — existing atomic-completion transaction this PR hooks off
- `lib/services/notification/app_notification_service.dart` — existing `emitMfaAuthenticatorRemoved` in-app inbox emit posture (complementary)
- CLAUDE.md "Proxy & API Conventions" (idempotency) + "RLS-Ready Schema" + "Agent-Led Slices"
- Operator's 2026-05-13 "keep 2fa, pos connection and vendor connection only" answer (covers slice-level WIRE approval; per-PR merge sign-off pending)

## Status

**HELD for operator approval.** Audit verdict: approve-on-sign-off.
