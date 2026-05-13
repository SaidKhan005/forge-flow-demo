# PR #628 Audit — C-2-F `vendor_connection_auto_disabled` Wire (Path b) (Claude)

**Slice:** C-2-F (Lane C — Cross-Surface Parity; matrix Draft F WIRE)
**Owner:** Claude (orchestrator-dispatched, isolated worktree agent)
**Branch:** `claude/c-2-f-vendor-connection-auto-disabled-wire`
**Base:** `master` @ `ab4606ef` (post-C-2-Del)
**Gate:** **operator-approval-required** — auth-adjacent (OAuth credential auto-disable runtime path; worker-side production email enqueue)
**Risk:** **Medium** — adds new runtime path inside the OAuth refresh worker (Cloud Run binary); writes to `email_outbox` + `audit_logs`; ~715 LoC production code; new dispatcher with Postgres-backed enqueue + audit + recipient resolver
**Size:** 1711 additions / 0 deletions / 4 files

## Verdict

**approve pending operator OK** — audit clean. Worker self-flagged `[operator-approval-required]` correctly. Implementation is careful: optional dispatcher seam (null-tolerant; existing rigs unaffected), best-effort posture (dispatcher errors swallowed inside so cap trip is never blocked), RLS discipline preserved (`withSystem` for cross-tenant operator lookup with explicit `reason`; `withTenant` for operator-scoped enqueue + audit), idempotency via SELECT-then-INSERT keyed on `(operator_id, template_id, idempotency_key)`, audit row written on both new + duplicate paths.

**Operator picked WIRE for Draft F** on 2026-05-13's open-decisions slate; the per-PR sign-off is the merge-time gate.

## Pattern B compliance

**✓ EXEMPLARY** — worker shipped Pattern B 8-lens self-audit in PR body. Honest LoC disclosure (`~715 LoC production vs ~400 LoC estimate`; explanation: estimate covered orchestrator + thin seam only, full implementation added Postgres-backed enqueue+audit repo, recipient resolver, idempotency-key collapse, human-readable formatters). Still under Path (a)'s ~600 LoC estimate AND avoids `NotificationEventFanout` bootstrap blocker.

## What landed

| File | LoC | Kind |
|---|---|---|
| `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart` | +591 / 0 | **NEW** — dispatcher class + Postgres-backed `AutoDisabledEmailEnqueueRepository` impl + `PostgresAutoDisabledRecipientResolver` (cross-tenant `withSystem` read of `public.operators.owner_email`) + outcome enum + idempotency-key builder + truncation helpers |
| `tool/oauth_refresh_worker/main.dart` | +124 / 0 | EXTEND — adds optional `autoDisabledEmailDispatcher` param to `runWorkerTick` + `OAuthRefreshWorkerLoop` + `WorkerRuntime`; invokes dispatcher AFTER `gateway.autoDisableConnection` returns at both trigger sites (`VendorCredentialBrokerError` branch + unexpected-error branch); emits stdout JSON telemetry line per dispatch; production wires real dispatcher via `buildWorkerRuntime` |
| `test/services/email/vendor_connection_auto_disabled_dispatcher_test.dart` | +551 / 0 | **NEW** — 11 cases pinning dispatcher behaviour: recipient resolution, template-data shape, idempotency-key shape (minute-granular), duplicate collapse audit, enqueue error swallow, vendor-display-name fallback, all skip-reason variants, occurredAt normalization, error-message truncation |
| `test/proxy/oauth_refresh_worker_auto_disabled_email_test.dart` | +445 / 0 | **NEW** — 5 cases driving `runWorkerTick` end-to-end with fake gateway + fake dispatcher: cap-trip → exactly 1 dispatch per trip; 1st + 2nd failures → no dispatch; success → no dispatch; null dispatcher → no regression; unexpected-error branch → cap-trip path still dispatches |

**Net effect:** when the OAuth refresh worker auto-disables a vendor credential (3rd consecutive refresh failure), it now enqueues one `vendor_connection_auto_disabled` email per cap-trip into `public.email_outbox` with a stable idempotency key, and writes one audit row (`action='vendor_credential_auto_disabled_email_enqueue'`, `actor_kind='service'`, `target_kind='email_outbox'`) per enqueue (whether new or duplicate-collapsed).

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` untouched | `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines | Independent diff confirms; **bleed-stop ceiling preserved at 88 headroom** (worker disclosed) |
| Other `tool/advisor_proxy/` files untouched | diff scope | Only `oauth_refresh_worker/` and test files in diff |
| `lib/auth/` untouched | diff scope | 0 lines — auth permission catalog unchanged |
| `db/migrations/` untouched | diff scope | 0 lines — no new tables, no new columns; reuses `email_outbox` + `audit_logs` |
| `pubspec.yaml` untouched | diff scope | 0 lines — no new package dep |
| `WAVE_EXECUTION_LEDGER.md` untouched | diff scope | 0 lines (orchestrator's job at merge) |
| Optional dispatcher seam (null-tolerant) | `main.dart:1130-1131` | `VendorConnectionAutoDisabledDispatcher? autoDisabledEmailDispatcher` — existing test rigs pass null → no regression |
| Error swallow inside dispatcher | `dispatcher.dart` outcome surface | `enqueue_error` skip reason returned, never re-thrown; worker logs but doesn't crash |
| Cap-trip path commits BEFORE dispatcher fires | `main.dart:1213+` | Dispatcher invoked AFTER `gateway.autoDisableConnection` returns; status flip + audit row are durable before email path runs |
| Idempotency: SELECT-then-INSERT keyed on `(operator_id, template_id, idempotency_key)` | dispatcher `enqueueAutoDisabledEmail` | Stable key `auto_disable:{op}:{cred}:{minute_iso}` collapses sub-minute retries |
| Audit row on BOTH new + duplicate | dispatcher implementation | `duplicate_collapsed: true/false` payload field distinguishes; both write to `audit_logs` |
| RLS discipline: cross-tenant lookup explicit | `PostgresAutoDisabledRecipientResolver:kLookupReason` | `withSystem(reason: 'oauth_refresh_worker.auto_disabled_recipient_lookup')` — the GUC bypass-audit captures reason; matches existing worker pattern |
| RLS discipline: operator-scoped enqueue + audit | dispatcher impl | `withTenant` wraps both `email_outbox` INSERT and `audit_logs` write |
| Append-only `audit_logs` honored | dispatcher impl | INSERTs only; no UPDATE; `audit_logs_update_lint` clean per worker |
| Template variable contract pinned | dispatcher comment + test | Every variable from `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md` listed inline + renderer smoke test asserts presence |
| Error-message truncation | `_truncateMessage` (1024 char cap) | Mirrors worker's existing helper; prevents `audit_logs.payload` bloat |
| Telemetry line emitted per dispatch | `main.dart:1230+ / :1290+` | `event: oauth_refresh_auto_disabled_email` + outcome fields → Cloud Run captures into Cloud Logging |
| `dart analyze --fatal-infos` clean | disclosed | No issues |
| `advisor_proxy_size_lint` clean | disclosed | Ceiling preserved |
| `postgres_import_lint` clean | disclosed | Pre-push hook clean |
| `audit_logs_update_lint` clean | disclosed | Pre-push hook clean |
| 11 dispatcher tests + 5 worker-integration tests pass | disclosed | New tests |
| 12 existing oauth_refresh_worker tests pass | disclosed | No regression |
| 103 email-service tests pass | disclosed | No regression |
| 23 vendor-lifecycle + sendgrid tests pass | disclosed | No regression |
| No `--no-verify` traces | confirmed | Pre-push hooks ran clean |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict | Re-verification |
|---|---|---|---|
| L1 Product & Journey | OK | Operator picked WIRE for Draft F; operator-facing surface = `vendor_connection_auto_disabled` email arrives within ~minute of OAuth cap trip |
| L2 IA & Navigation | OK | Email links to integration-console URL built via `_consoleUrlBuilder`; no in-app route change |
| L3 Data Model / Migration / RLS | OK | No schema/migration; uses existing `email_outbox` + `audit_logs`; RLS discipline preserved (withSystem reason'd for cross-tenant; withTenant for operator-scoped) |
| L4 Repository & Service | OK | New `PostgresAutoDisabledEmailEnqueueRepository` extends `OperatorScopedRepository` per project pattern |
| L5 Proxy / Route / Gateway | OK | Proxy code untouched; new worker-side path through existing `email_outbox` (advisor_proxy sender daemon picks it up unchanged) |
| L6 Auth / Roles / Permissions | OK | `lib/auth/` 0-line diff; service-principal-id (`kOauthRefreshWorkerServicePrincipalId`) reused from existing worker audit pattern |
| L7 Lifecycle | OK | Cap-trip is the existing lifecycle; dispatcher hangs off it as best-effort sibling |
| L8 Workers / Deploy / Health | OK | Cloud Run binary's classpath unchanged at runtime (existing imports); new dispatcher constructed in `buildWorkerRuntime` only when real Postgres seams are wired |
| L9 UI / UX / Accessibility | OK | Email body unchanged (existing `.md` template); no in-app UI |
| L10 Performance | OK | One extra SELECT + INSERT per cap-trip (rare event); idempotency collapses retries; truncation prevents payload bloat |
| L11 Parity | OK | Mirrors `VendorLifecycleNotificationDispatcher`'s pattern; same `email_outbox` shape; same audit `action` naming convention |
| L12 Tests / Builds / Evidence | OK | 16 new tests; all lints clean; all existing tests pass |
| L13 Observability / Audit | OK | Audit row per enqueue (success + duplicate paths); stdout telemetry line per dispatch; lookup `reason` recorded in `withSystem` bypass-audit |
| L14 Docs / Tracker / Hygiene | OK | No tracker/ledger touch per worker contract; matrix doc already reflects WIRE pick from PR #619 |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `ab4606ef` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables | ✓ — worker 8-lens + this 14-lens table |
| 4 files match PR body declaration | ✓ — `git diff --stat` confirms |
| `tool/advisor_proxy/` diff = 0 lines | ✓ — independent `git diff` |
| `lib/auth/` diff = 0 lines | ✓ |
| `db/migrations/` diff = 0 lines | ✓ |
| `pubspec.yaml` diff = 0 lines | ✓ |
| `WAVE_EXECUTION_LEDGER.md` diff = 0 lines | ✓ |
| Optional `autoDisabledEmailDispatcher` param wired through all 3 layers | ✓ — `runWorkerTick` + `OAuthRefreshWorkerLoop` + `WorkerRuntime` |
| Both trigger sites covered | ✓ — `VendorCredentialBrokerError` branch + unexpected-error branch |
| Idempotency-key shape stable | ✓ — minute-granular: `auto_disable:{op}:{cred}:{minute_iso}` |
| `withSystem(reason: ...)` for cross-tenant operator lookup | ✓ — `kLookupReason` constant; explicit audit trail |
| Audit row writes on BOTH new + duplicate paths | ✓ — `duplicate_collapsed` payload field distinguishes |
| Vendor display-name fallback documented | ✓ — returns raw vendor id; future hoist via shared registry noted in inline comment |
| Template variable shape pinned in test | ✓ — renderer smoke test asserts full variable list |
| No `--no-verify` traces | ✓ |
| Honest LoC disclosure (715 vs 400 estimate) | ✓ — worker explained gap; still under Path (a)'s ~600 |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — matches operator's 2026-05-13 WIRE pick for Draft F |
| Worker disclosure operator should know | ⚠ ONE disclosure: production code came in ~715 LoC vs the ~400 LoC matrix estimate (estimate covered orchestrator+seam only; full implementation added Postgres-backed enqueue+audit repo, recipient resolver, idempotency-key collapse, human-readable formatters). Still under Path (a)'s ~600 LoC estimate AND avoids `NotificationEventFanout` bootstrap blocker. |
| Stacked PR | ❌ — base is master |
| **Auth-critical / proxy / schema / RLS touch** | **✓ TRIGGERED — auth-adjacent** (OAuth credential auto-disable runtime path; oauth_refresh_worker handles credential lifecycle) — operator approval gate per CLAUDE.md |

**Decision**: **HOLD for explicit operator approval**. Audit verdict: approve-on-sign-off. Operator's 2026-05-13 WIRE pick covers the slice-level decision; the per-PR sign-off is the merge-time gate.

## Cross-lane notes

- **Advances C-2** — Draft F WIRE landing means matrix is C, D in flight + E, G deleted + F about-to-land.
- **Mirrors `VendorLifecycleNotificationDispatcher` pattern** — same `email_outbox` shape, same audit `action` naming, parallel test harness shape.
- **No proxy code touch** — `advisor_proxy_size_lint` ceiling preserved at 88 headroom (per worker disclosure). Future hoist of vendor display-name registry to `lib/integrations/ui/` can be a tiny follow-up; dispatcher signature is stable.
- **`oauth_refresh_worker` is auth-adjacent** but separate from `advisor_proxy` and from `lib/auth/`. The auth-critical-path verdict is "auth-adjacent runtime worker handling vendor OAuth credentials" — operator approval is the right gate.

## Findings

None blocking. One non-blocking note for the operator: vendor display-name resolver returns `null` today (renders raw vendor id like `lightspeed_lsk` instead of `Lightspeed`); a follow-up slice can hoist a shared display-name registry without changing this dispatcher's signature. Worker explicitly disclosed this in the dispatcher inline comment.

## Authority anchors

- `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` Draft F WIRE pick (operator 2026-05-13)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row C-2-F
- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart` — precedent pattern this PR mirrors
- `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md` — template the dispatcher feeds (untouched on master)
- CLAUDE.md "Proxy & API Conventions" (idempotency) + "RLS-Ready Schema" + "Agent-Led Slices"
- Operator's 2026-05-13 "keep 2fa, pos connection and vendor connection only" answer (covers slice-level WIRE approval; per-PR merge sign-off pending)

## Status

**HELD for operator approval.** Audit verdict: approve-on-sign-off.
