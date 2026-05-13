# PR #636 Audit — C-7 Adaptive MFA Recovery CTA (Codex)

**Slice:** C-7 (Lane C — Cross-Surface Parity; ledger row 93)
**Owner:** Codex
**Branch:** `codex/c-7-adaptive-2fa-button`
**Base:** `master` @ `540b848c` (post-B6 decompose)
**Gate:** **operator-approval-required** — proxy-touching (`advisor_proxy.dart` +67) + auth-critical (MFA recovery codes view path)
**Risk:** **Low-Medium** — net +65 LoC into proxy monolith reduces headroom 88 → 23; pure additive feature (no schema change, no RLS change); uses C-7a's `recovery_codes_viewed_at` column with `Idempotency-Key` replay guard
**Size:** 940 additions / 152 deletions / 17 files

## Verdict

**approve-for-merge** — auto-merged at master `55bbacc3` per expanded delegation. Pattern B exemplary (worker 14L + executor 14L with file:line citations); 142 tests pass; `dart analyze` clean; uses C-7a's prep migration column verbatim. Slice dependency `B9.2 merged + C-7a merged` satisfied (both on master).

**Caveat noted but non-blocking:** advisor_proxy.dart post-merge ceiling headroom drops from 88 → **23** lines (19,877 / 19,900). C-7's +65 LoC inline added a single new MFA route handler (`/v1/auth/mfa/recovery-codes/viewed`) co-located with the existing MFA route surface — the choice is defensible (one route, auth-critical, benefits from co-location for grep-ability) but it leaves zero buffer for the next slice that adds inline routes. **Wave audit flag:** any future inline addition >23 LoC will breach. Future slices should follow C-1 / B8 / B6 / B8.b sibling-file precedent.

## Pattern B compliance

**✓ EXEMPLARY** — both Pattern B 14-lens tables present in PR body with file:line citations:
- `lib/operator_web/screens/my_account_screen.dart:244` — View Recovery Codes writes before dialog and refreshes after
- `lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart:322` — Update always sets latest `recovery_codes_viewed_at`
- `tool/advisor_proxy/advisor_proxy.dart:11152` — Route uses `runOrReplay` for same-key retry behavior
- `lib/operator_web/account/mfa_card_controller.dart:318` — CTA remains constrained to the four C-7 labels
- `test/proxy_auth_operations_route_test.dart:1615` — Test proves same-key replay and fresh-key later timestamp

## What landed

| File | LoC | Kind |
|---|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` | +67 / -2 | EXTEND — `/v1/auth/mfa/recovery-codes/viewed` POST route handler with `runOrReplay` Idempotency-Key replay guard at `:11152`; existing actor/operator/location scope forwarded |
| `lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart` | +57 / -2 | EXTEND — `markRecoveryCodesViewedAt` repository method writes `recovery_codes_viewed_at = $now` via `withTenant`; scoped by `(operator_id, location_id, user_id, factor_type='totp', revoked_at IS NULL)`; 404 on no-match |
| `lib/services/mfa/mfa_operations_gateway.dart` | +90 / 0 | EXTEND — gateway method emits `auth.mfa_recovery_codes_viewed` audit event (no code values in audit row) + writes timestamp via repository |
| `lib/services/mfa/proxy_mfa_operations_gateway.dart` | +25 / -2 | EXTEND — operator-web ↔ proxy gateway path consumes the new viewed-timestamp contract |
| `lib/operator_web/account/mfa_card_controller.dart` | +51 / -6 | EXTEND — adaptive label compute over `(session.mfaEnrolled, factorCount, recoveryCodesViewedAt)`; 4 exact labels constrained |
| `lib/operator_web/account/operator_web_account_actions.dart` | +14 / 0 | EXTEND — action handler triggers MFA recovery codes view |
| `lib/operator_web/screens/my_account_screen.dart` | +37 / -9 | EXTEND — UI integration; View Recovery Codes button writes BEFORE dialog opens (no race) |
| `lib/operator_web/services/web_security_gateway.dart` | +84 / -28 | EXTEND — adds `markRecoveryCodesViewed` method; refactor of inputs |
| `lib/operator_web/services/demo_security_gateway.dart` | +44 / -14 | EXTEND — demo gateway mirror |
| `lib/screens/settings/settings_mfa_section.dart` | +23 / -3 | EXTEND — mobile MFA section adapts to the same R1 state pattern (read-only on mobile per C-Mobile rule) |
| 7 test files | +405 / -86 | EXTEND + NEW — 142 tests across repository, gateway, controller, screen, route, settings_mfa surfaces |

**Net effect:** My Account MFA card primary CTA adapts to the R1 state pattern:
1. `session.mfaEnrolled == false` → no card visible
2. `factorCount == 0` → `Add a method`
3. `factorCount > 0 && recoveryCodesViewedAt == null` → `View recovery codes`
4. `factorCount == 1 && recoveryCodesViewedAt != null` → `Add another method`
5. `factorCount > 1 && recoveryCodesViewedAt != null` → `Manage two-factor sign-in`

Clicking "View recovery codes" issues `POST /v1/auth/mfa/recovery-codes/viewed` BEFORE the dialog opens; repository updates the column; gateway audits `auth.mfa_recovery_codes_viewed`; UI refreshes the controller state; label transitions to "Add another method" or "Manage two-factor sign-in". Same-key replay short-circuits at proxy returning original timestamp; fresh-key later-clicks update to a later timestamp.

## Critical safety guarantees

| Guarantee | Verification |
|---|---|
| `lib/auth/**` UNTOUCHED | ✓ — 0-line diff; no new permission key needed (route uses `operator_owner/operator_admin/team_lead/team_member` self-read posture; management/removal remains gated as on master) |
| `db/migrations/**` UNTOUCHED | ✓ — uses C-7a's column (already on master from PR #626) |
| `pubspec.yaml` UNTOUCHED | ✓ — 0-line diff |
| `WAVE_EXECUTION_LEDGER.md` UNTOUCHED | ✓ — 0 lines (orchestrator's job) |
| `audit_logs` writes are INSERT-only | ✓ — `audit_logs_update_lint` clean (worker disclosure); `auth.mfa_recovery_codes_viewed` action emitted via Phase 9 auth audit pipeline (no direct `UPDATE audit_logs`) |
| No recovery code values in audit payload | ✓ — `lib/services/mfa/mfa_operations_gateway.dart:603` confirms only timestamp + actor surfaces; codes never serialized to audit |
| `Idempotency-Key` replay short-circuit | ✓ — `runOrReplay` at proxy line 11152; same-key replay returns original timestamp; fresh keys update + audit again (pinned by test at `proxy_auth_operations_route_test.dart:1615`) |
| RLS clamp via `withTenant` | ✓ — repository UPDATE rides `withTenant` per `OperatorScopedRepository` pattern (line 322) |
| 142 tests pass | ✓ disclosed |
| `dart analyze` clean | ✓ disclosed |
| `git diff --check` clean | ✓ disclosed |
| No `--no-verify` traces | ✓ |

## Executor 14-lens audit (re-verified)

| # | Lens | Verdict |
|---|---|---|
| L1 Product Journey | OK — 4 exact labels covered by tests |
| L2 IA/Nav | OK — My Account is only entry point |
| L3 Data/Schema | OK — uses C-7a column; no new schema |
| L4 Service | OK — actor user / operator / location scoping; 404 on no match |
| L5 Proxy | OK — `/v1/auth/mfa/recovery-codes/viewed` with replay guard |
| L6 Auth/Scope | OK — no new permission key; read-only operators can view their own codes |
| L7 Lifecycle | OK — same-key replay returns original; fresh keys update + audit |
| L8 Runtime | OK — no deployment / env / KMS / billing change |
| L9 UX/A11y | OK — tooltip + sub-copy track CTA state; role-aware enablement |
| L10 Performance | OK — one write + refresh per fresh click; retry short-circuits at proxy |
| L11 Parity | OK — mobile + shared MFA interface compile with explicit unsupported stubs (mobile read-only per C-Mobile rule) |
| L12 Tests | OK — 142 tests; analyze clean |
| L13 Audit | OK — `auth.mfa_recovery_codes_viewed` emitted via Phase 9 auth audit; no recovery code values |
| L14 Hygiene | OK — no `lib/auth/**`, `lib/data/**`, tracker, ledger, demo-carveout touches |

## Genuine safety holds — checked

| Hold | Status |
|---|---|
| Migration already applied | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — row 93 dep `B9.2 merged + C-7a merged` satisfied |
| Worker disclosed something operator should know | ⚠ Headroom drops to 23 lines on advisor_proxy.dart; defensible inline choice (co-located MFA routes) but next slice should sibling-decompose. Worker did not flag the headroom explicitly; orchestrator surfacing here. |
| Stacked PR | ❌ — base was master |

**Decision**: auto-merged per expanded delegation.

## Triple-safeguard

- ✅ Merge commit on master at `55bbacc3`
- ✅ Ancestor verified
- ✅ `kMfaRecoveryCodesViewedRoutePath` substring (or `/v1/auth/mfa/recovery-codes/viewed` literal) confirmed in `tool/advisor_proxy/advisor_proxy.dart` on master

## Cross-lane notes

- **Closes C-7** — the wave's last C-feature slice. Operator picked C-7a → C-7 cadence on 2026-05-13. Data contract from C-7a (column existence) consumed verbatim.
- **C-12 unblocks** — the orchestrator-owned Lane-C closeout slice can now spawn (was waiting on C-7 + B8.b + C-2-D-binding to land).
- **Bleed-stop trajectory:** wave start = 18,871 → wave end (this commit) = 19,877 → headroom 23. The next inline route addition will breach; future PRs MUST use sibling-file decomposition.

## Findings

None blocking. One observational concern surfaced in this audit: bleed-stop headroom now at 23 lines (down from 88 before this PR). Track for wave closeout doc.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 93 — C-7 ledger row
- `docs/_execution/lane_c_parity/03_execution_slices.md:137-153` — C-7 slice spec
- `db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql` — C-7a prep migration (column source of truth)
- `docs/_audits/post_codex_wave/pr_626_c_7a_recovery_codes_viewed_at_prep_audit.md` — C-7a precedent audit
- CLAUDE.md "Architecture Guardrails" + "Time Guardrails" + "Agent-Led Slices"

## Status

**Merged.** Master `55bbacc3` (now subsumed in `63b67753` post-B8.b merge).
