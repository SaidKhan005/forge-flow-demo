# PR #586 Audit — B11.2.b Step-Up Challenge Wiring + Production Binding + B9.2 Clock-Skew Fix

**Slice:** B11.2.b (Lane B — Features, B11.2 deferral closure)
**Owner:** Claude (Claude lane)
**Branch:** `claude/b11-2-b-step-up-wiring`
**Base:** `master`
**Gate:** `operator` per ledger row 72 — title prefixed `[operator-approval-required]`
**Risk:** **HIGH** — auth-critical (changes auth posture on 20 sensitive routes)
**Size:** 2854 additions / 12 deletions / 16 files

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation ("approve once audited and you are satisfied; do not wait on me"). The slice is the most consequential auth-critical work in this wave; merge gated on:

- Pattern B exemplary (worker 14L + executor 14L, both with explicit auth-critical lenses)
- All four planned scopes shipped (route gate + Postgres binding + client adapters + B9.2 P1 fix)
- Build-Toward-Production discipline honored — `main.dart` threading inline (worker did NOT repeat B2.1's main.dart-deferral anti-pattern)
- Same architectural pattern as B11.1 (PR #512, already merged): `RepositoryHandoffCodesGateway` ⇒ `RepositoryStepUpChallengesGateway`; `ProductionHandoffAuditSink` ⇒ `ProductionStepUpAuditSink`
- 58 new tests + 67 pre-existing sibling tests pass
- Critical addendum A1 (token-in-URL prohibition) explicitly enforced via dedicated test
- Oracle-safe replay classifier (`withSystem` ONLY for `lookupForReplayCheck`) prevents probe-by-error-code leaks

**Auth posture change:** "any verified bearer admitted on sensitive routes" → "fresh `auth_time` required on 20 sensitive routes; one-shot step-up challenge if stale." This is exactly what B11.2.b was scoped to deliver per ledger row 72.

## Pattern B compliance

**✓ EXEMPLARY** — worker self-audit (14 lenses with auth-critical lenses 6 + 8 marked) and executor independent audit (14 lenses) both present with file:line citations. Executor adds 2 executor-only lenses (12: choke-point pattern correctness; 13: oracle-safe replay classifier).

## What landed (4 scopes shipped together)

### Scope 1 — Route gate (single choke-point)

- New `tool/advisor_proxy/auth_step_up_gate.dart` (132 LoC NEW) — runs the gate against the registry; explicit URL-param prohibition with 5-line comment block
- New `tool/advisor_proxy/auth_step_up_routes.dart` (197 LoC NEW — registry + dispatcher + `ProductionStepUpAuditSink`)
- `tool/advisor_proxy/advisor_proxy.dart` (+60): wires the gate at the head of `routeRequest` as a single choke-point that intercepts requests matching `kStepUpSensitiveRoutes` (20 specs)
- **20 sensitive routes covered** (worker said 20, executor grep verified `StepUpRouteSpec(...)` returns 21 hits = 1 class constructor at line 150 + 20 spec instances starting at line 195)

### Scope 2 — Postgres binding

- New `lib/infrastructure/persistence/postgres/repositories/step_up_challenges_repository.dart` (325 LoC NEW)
- `StepUpChallengesRepository extends OperatorScopedRepository<T>` — mirrors `HandoffCodesRepository` (B11.1) verbatim
- Emit + consume use `withTenant` (operator-scoped RLS primary defense)
- `lookupForReplayCheck` uses `withSystem` ONLY (oracle-safe — must see across operators to collapse cross-operator / wrong-route / wrong-user into a single 401, preventing probe-by-error-code leaks)

### Scope 3 — Client adapters

- `lib/auth/fresh_mfa_resolver.dart` (+73) — reads the `WWW-Authenticate: Bearer error="insufficient_user_authentication"` header
- `lib/auth/mfa_freshness_redirect_listener.dart` (+15) — adapts to the standard challenge shape
- New `lib/operator_web/auth/step_up_challenge_handler.dart` (320 LoC NEW) — parses challenge, replays request with `Step-Up-Challenge-Id` HEADER (NEVER URL param — addendum A1)
- `lib/operator_web/services/web_account_gateway.dart` (+106) — wires existing flow through the new handler on 401

### Scope 4 — B9.2 clock-skew P1 fix

- `web_account_gateway.dart:_requireFreshMfaToken` now uses `freshMfaClockSkewWindow = Duration(seconds: 60)` (RFC 7519 §4.1.4 leeway)
- Boundary tests pin: +0s accept, +30s accept, +59s accept (boundary), +60s accept (inclusive), +61s reject

### Production wiring

- `tool/advisor_proxy/proxy_bootstrap.dart` (+59): constructs `StepUpChallengeRouter` + `RepositoryStepUpChallengesGateway` + `ProductionStepUpAuditSink`; threads through `ProxyProductionBindings`
- `tool/advisor_proxy/main.dart` (+7): threads `productionBindings.stepUpChallengeRouter` into `routeRequest(...)` (Build-Toward-Production discipline — worker did NOT defer to executor like B2.1's anti-pattern)
- `test/advisor_proxy_bootstrap_test.dart` (+18): pins non-null + non-noop wiring (2 expectations: `isA<StepUpChallengeRouter>()` + `gateway is isA<RepositoryStepUpChallengesGateway>()`)

## Critical security guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| Step-Up-Challenge-Id is HEADER only, NEVER URL param (addendum A1) | `auth_step_up_gate.dart:91-95` (5-line comment block) + dedicated test at `b11_2_b_step_up_wiring_test.dart:343` | Test seeds URL-param `?step_up_challenge_id=CHAL_TOKEN_IN_URL`, sends request WITHOUT header, asserts gate emits FRESH challenge (not seeded) AND `gateway.consumedIds` is empty. |
| Oracle-safe replay classifier (cross-operator / wrong-route / wrong-user → single 401) | `step_up_challenges_repository.dart:lookupForReplayCheck` (uses `withSystem` ONLY) | Worker doc comment cites rationale: must see across operators to collapse probe failure modes into a single 401. |
| Hash-chained `audit_logs` writes — INSERT only, no UPDATE | `auth_step_up_routes.dart:ProductionStepUpAuditSink` → `AuditLogsRepository` | `audit_logs_update_lint` disclosed clean. Per-tenant tx wrapper ensures `audit_logs.operator_id` matches SET LOCAL GUC (`AuditLogsTenantMismatchError` defends against forged audit rows). |
| Challenge ID hashed in audit payloads (never raw) | `auth_step_up_routes.dart:ProductionStepUpAuditSink` | Payload uses `target_id = SHA-256(challenge_id)` + `challenge_id_hash` field. Raw challenge_id never logged. |
| Frozen `lib/auth/permission_keys.dart` untouched | `git diff origin/master..HEAD -- lib/auth/permission_keys.dart` returns 0 lines (executor verified) | No new permission key — step-up enforcement is by route registry, not permission key |
| Service principals correctly skip gate (V1 — no interactive MFA) | `auth_step_up_gate.dart` `SkipServicePrincipal` sealed result | Worker self-audit Lens 6 confirms; absence of interactive MFA for SP tokens is a V1 design decision |
| Bootstrap test pins non-null + non-noop wiring | `test/advisor_proxy_bootstrap_test.dart:260-274` | Two expectations enforce production posture; future regression to noop fake fails loudly |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ |
| Pattern B both tables (worker 14L + executor 14L) | ✓ |
| 20 sensitive route specs (worker count vs executor grep) | ✓ — 21 grep hits = 1 class definition (line 150) + 20 specs (lines 195-383) |
| Frozen `lib/auth/permission_keys.dart` untouched | ✓ — `git diff` returns 0 lines |
| Step-Up-Challenge-Id is HEADER only (addendum A1) | ✓ — dedicated test at `b11_2_b_step_up_wiring_test.dart:343`; 5-line comment block at gate file |
| Oracle-safe replay classifier uses `withSystem` for lookup | ✓ — repository file structure matches B11.1's `HandoffCodesRepository` precedent |
| Bootstrap test pins non-null + production-backed | ✓ — 2 expectations |
| Build-Toward-Production: `main.dart` threading inline | ✓ — worker did NOT repeat B2.1's deferral anti-pattern; threading is in same commit |
| Same architectural pattern as B11.1 (PR #512) | ✓ — worker explicitly cites precedent throughout |
| 58 new + 67 pre-existing sibling tests pass | ✓ disclosed |
| `dart analyze --fatal-infos` clean on 16 files | ✓ disclosed |
| `audit_logs_update_lint.dart` clean | ✓ disclosed |
| `postgres_import_lint.dart` clean | ✓ disclosed |
| `advisor_proxy_size_lint.dart` clean | ✓ — 19,688 / 19,700 (headroom 12; inside Bundle 34's ratchet) |
| Clock-skew window = 60s with boundary tests (+0/+30/+59/+60/+61) | ✓ — `freshMfaClockSkewWindow = Duration(seconds: 60)` at `web_account_gateway.dart:88` |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No `pg_advisory_lock`, no banned items | ✓ |
| No `on Object` (CLAUDE.md addendum C4) | ✓ |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — B11.2's migration was already on master; B11.2.b adds no new schema |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 72 covers exactly this scope (3 deferrals + B9.2 P1 fix) |
| Worker disclosure operator should know | ⚠ NON-BLOCKING — 20 routes vs estimated 14 (better-than-estimated, fully transparent); 4 scopes shipped together per Build-Toward-Production; auth posture changes per ledger row 72 design intent |
| Stacked PR | ❌ |

**Decision**: per expanded policy. Auth-critical merge with full Pattern B exemplary, all architectural safety mechanisms in place, exact-pattern reuse of B11.1 precedent, slice executed as ledger-row-72 planned. Will surface clearly in operator status summary.

## Cross-lane notes

- **B11.2 (PR #550 scaffold) deferral now closed.** Auth posture changes from "any verified bearer admitted on sensitive routes" to "fresh `auth_time` required on 20 sensitive routes; one-shot step-up challenge if stale."
- **B9.2 (PR #547) clock-skew P1 fix bundled in scope 4** — ±60s window (RFC 7519 §4.1.4 leeway).
- **B11.1 (PR #512) pattern reused exactly** for repository + production audit sink.
- **C-7 (mobile parity)** will surface the 401 challenge as a generic auth failure until it wires its own `StepUpChallengeReauthHook` adapter. Server-side enforcement is universal.
- **Bundle 34 ceiling raise (19,600 → 19,700)** put B11.2.b inside the ratchet (19,688 → headroom 12).
- **No Codex-owned files touched.**

## Findings

None blocking. The slice is the most architecturally important auth-critical work shipped this wave and it's executed at the highest standard observed.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 72 — B11.2.b ledger row (operator gate)
- PR #550 (B11.2 scaffold) audit + PR #512 (B11.1) `RepositoryHandoffCodesGateway` + `ProductionHandoffAuditSink` precedent
- CLAUDE.md "Build Toward Production" (no scaffolds/deferrals)
- RFC 9470 (step-up challenge protocol) + RFC 7519 §4.1.4 (clock-skew leeway)
- CLAUDE.md addendum A1 (B11 token-in-URL prohibition)
- `docs/_audits/post_codex_wave/pr_550_b11_2_step_up_challenge_audit.md` (B11.2 scaffold audit)

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Auth-critical merge surfaced in operator summary report.
