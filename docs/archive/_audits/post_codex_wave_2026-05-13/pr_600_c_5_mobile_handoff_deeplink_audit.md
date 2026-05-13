# PR #600 Audit — C-5 Mobile Handoff Deep Links

**Slice:** C-5 (Lane C — Cross-Surface Parity)
**Owner:** Codex
**Branch:** `codex/c-5-mobile-handoff-deeplink`
**Base:** `master`
**Gate:** `operator` per ledger row 87 — title prefixed `[operator-approval-required]` (auth-flow, high risk)
**Risk:** **Medium-High** — auth-flow bridge mobile → Operator Web; bears B11.1 handoff-code primitive
**Size:** 878 additions / 64 deletions / 11 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L with file:line citations). C-5 consumes B11.1's handoff-code primitive verbatim — mobile mints via `HandoffCodeClient`, opens `https://app.forgeflow.app/handoff?code=...&nav=...`, operator-web `/handoff` route redeems via body-only `POST /v1/auth/handoff/redeem` requiring current ID token. **CLAUDE.md addendum A1 satisfied**: JWTs and Step-Up-Challenge-Id NOT in URL; handoff CODE in URL is by design (B11.1's purpose). Defense-in-depth: redeem also requires current ID token, so handoff code alone is insufficient.

Worker disclosed a **cross-lane finding** that does NOT block C-5: existing B11.2.b test failure on master at `test/proxy/b11_2_b_step_up_wiring_test.dart:175`. Codex respected ownership boundary and did NOT touch Claude-owned files. This finding is escalated separately at the bottom of this audit doc for orchestrator follow-up investigation.

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables (worker self-audit + executor independent audit) present in PR body with file:line citations and disclosed verification commands.

## What landed (4 surfaces wired)

### 1. Mobile mint flow (`lib/services/auth/handoff_code_gateway.dart`, 71 LoC NEW)

Mobile wrapper delegating to B11.1's `HandoffCodeClient`. Runtime-wired only when proxy auth exists (`firebase_auth_runtime_bindings.dart:219`). Mints short-TTL opaque code via existing B11 endpoint; no schema change.

### 2. Mobile pointer row launch (`lib/screens/settings/settings_pointer_row.dart`, +118/-19)

Settings "pointer rows" (mobile→Operator-Web bridges) now:
- Mint a handoff code via the gateway
- Open `https://app.forgeflow.app/handoff?code=...&nav=...` via `url_launcher` (`launchMode.externalApplication`)
- Fall back to clipboard when launch fails OR proxy returns 5xx OR offline (`shouldFallbackToClipboardForHandoff(error)`)
- Plain-English snackbar copy throughout ("Opening Operator Web", "Handoff link copied — open in browser")

### 3. Operator-web `/handoff` redeem (`lib/operator_web/auth/operator_web_handoff_redeem_gateway.dart`, 119 LoC NEW + `operator_web_router.dart` +294)

- New `OperatorWebHandoffRedeemGateway` POSTs to `/v1/auth/handoff/redeem` with `{'code': code}` body — code in JSON body, NOT URL
- Requires current ID token (`_idTokenProvider`); throws `no_id_token` 401 if absent
- `/handoff` route parser maps URL/nav/returned-path to stable shell nav IDs (`operator_web_router.dart:168, :203, :231`)
- Missing/expired/rejected handoff fails closed on the landing surface (`operator_web_router.dart:376-422, :427`)

### 4. Bootstrap wiring

- `lib/main_forgeflow.dart` (+3/-2) + `lib/forge_flow_app.dart` (+13/-9) thread the gateway into the live mobile bootstrap
- No deploy/script/cloud action

### Test coverage (51 disclosed pass)

- `test/screens/settings_pointer_row_test.dart` (+99 LoC, NEW) — mint/launch/fallback paths
- `test/operator_web/operator_web_router_test.dart` (+100 LoC) — `/handoff` parser + redeem routing + missing/expired/rejected handling
- `test/auth/step_up_challenge_handler_test.dart` (unchanged, pre-existing 67 pass)
- `test/proxy/auth_handoff_routes_test.dart` (unchanged, pre-existing pass)

## Critical security guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| Redeem endpoint is body-only (CLAUDE.md addendum A1) | `operator_web_handoff_redeem_gateway.dart:59,78-81` | `redeemPath = '/v1/auth/handoff/redeem'`; `body: <String, Object?>{'code': code}` — code lives in JSON body, NOT URL |
| ID token in HTTP header (not URL) | `operator_web_handoff_redeem_gateway.dart:67-76` | `idToken: token` passed to `postJson`; no `?token=` or query-string token path |
| Handoff CODE in URL is by design (B11.1 primitive) | `settings_pointer_row.dart:151-179` | URL is `https://app.forgeflow.app/handoff?code=...&nav=...`. The `code` is a short-TTL opaque dedupe key, NOT a JWT — addendum A1 explicitly bans tokens and step-up IDs; handoff codes are the bridge primitive |
| Web redeem requires current bearer token (defense-in-depth) | `operator_web_handoff_redeem_gateway.dart:67-76` | Throws `no_id_token` 401 if `idToken` is null/empty before any proxy call. Handoff code ALONE is insufficient to authenticate |
| No step-up challenge IDs in URL | diff scope | C-5 doesn't touch `tool/advisor_proxy/auth_step_up_*` or any step-up surface; verified by independent grep |
| Frozen `lib/auth/**` untouched | diff scope | Zero changes under `lib/auth/`; verified by `git diff --name-status` |
| No `db/migrations/**` touch | diff scope | Schema unchanged; consumes existing B11.1 handoff schema |
| No `tool/advisor_proxy/**` touch | diff scope | Proxy contract unchanged; C-5 consumes existing `/v1/auth/handoff/{mint,redeem}` endpoints |
| Missing/expired/rejected handoff fail closed | `operator_web_router.dart:376-422, :427-439` | Fails to a dedicated landing surface; no silent fallback to authenticated state |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — UNKNOWN/MERGEABLE at audit start (GitHub still computing); CLEAN at merge time |
| Pattern B both tables present | ✓ — worker 14L + executor 14L with file:line citations |
| Body-only redeem verified | ✓ — `redeemPath` + `body: {'code': code}` at expected lines |
| ID token in header, not URL | ✓ — `idTokenProvider` invoked + result passed via `idToken:` named param |
| Addendum A1 satisfied (JWTs + Step-Up-Challenge-Id NOT in URL) | ✓ — only the B11.1 handoff CODE is in URL, which is the primitive's purpose |
| Defense-in-depth on redeem (token required even with valid code) | ✓ — `no_id_token` 401 throw at line 67-76 |
| Mobile fallback to clipboard for offline/5xx | ✓ — `shouldFallbackToClipboardForHandoff(error)` + snackbar copy |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No frozen `lib/auth/**` touch | ✓ |
| No proxy/auth/migration touch | ✓ — consumes existing B11.1 endpoints |
| 51 disclosed tests pass | ✓ — slice tests + cross-cutting sibling tests |
| `dart analyze --fatal-infos` clean on touched files | ✓ disclosed |
| `postgres_import_lint` clean | ✓ disclosed |
| No `--no-verify` traces | ✓ |
| Cross-lane disclosure (B11.2.b test failure) properly bounded | ✓ — Codex respected ownership; did NOT fix Claude-owned B11.2.b code |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables (worker self-audit + executor independent audit) present in PR body with file:line citations.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration in this slice |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 87 sets C-5 operator-gate auth-flow; matches PR scope |
| Worker disclosure operator should know | ⚠ NON-BLOCKING for C-5 — Codex worker disclosed a pre-existing B11.2.b test failure on master (`test/proxy/b11_2_b_step_up_wiring_test.dart:175`). C-5 does NOT introduce this; Codex correctly respected ownership boundary and did NOT touch the failing test or `tool/advisor_proxy/auth_step_up_*`. **Escalated below for separate orchestrator follow-up.** |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. C-5 itself is clean; B11.2.b test failure is a SEPARATE finding for a SEPARATE slice that warrants investigation but does not block C-5.

## Cross-lane finding escalated for orchestrator follow-up

**B11.2.b test failure on master** (NOT introduced by C-5):

- **File**: `test/proxy/b11_2_b_step_up_wiring_test.dart:175`
- **Test**: "valid presented Step-Up-Challenge-Id HEADER admits the request"
- **Failure**: expected `false`, actual `true`
- **Codex worker reproduced on master pre-C-5**; the failure is NOT introduced by this PR
- **Possible causes** (executor hypotheses, not verified yet):
  - (a) Pre-existing master breakage from a later slice that wasn't caught by my B11.2.b audit (PR #586) — my audit claimed "58 new + 67 pre-existing sibling tests pass"; this contradicts that claim
  - (b) Test-side drift like the admin_cors_bootstrap_test pattern (PR #588) — production code shifted, test snapshot didn't
  - (c) A real B11.2.b regression that landed via a later commit and modified the gate's accept/reject semantics

**Follow-up action**: spawn background investigation agent (mirror `admin_cors_bootstrap_test` pattern from PR #588). Agent should produce a written diagnosis distinguishing test-side drift vs. production regression. **Not blocking C-5 merge**; will surface in operator status summary.

## Cross-lane notes (C-5 specific)

- **Consumes B11.1 handoff primitive verbatim** — no extension of `HandoffCodeClient`, `HandoffCodesRepository`, or the proxy `/v1/auth/handoff/{mint,redeem}` contract. C-5 is the consumer side B11.1 was built for.
- **No interaction with B11.2.b** despite the test-failure disclosure — C-5 touches `lib/services/auth/`, `lib/screens/settings/`, `lib/operator_web/`, `lib/forge_flow_app.dart` only. B11.2.b's step-up wiring (`tool/advisor_proxy/auth_step_up_*`) is untouched.
- **No interaction with parallel C-1a** (just merged via PR #599) — disjoint surfaces.
- **Mobile-side fallback discipline preserved** — offline / proxy-5xx / launchUrl failure all fall through to clipboard with plain-English copy.
- **Codex respected cross-lane ownership** — disclosed the B11.2.b finding cleanly, did NOT attempt a cross-lane fix. Exemplary discipline.

## Findings

None blocking C-5. One follow-up escalated (B11.2.b test failure investigation).

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 87 — C-5 ledger row (operator gate, auth-flow)
- `docs/_execution/lane_c_parity/03_execution_slices.md:97-113` — C-5 slice spec
- `docs/_execution/lane_c_parity/02_plumbing_audit_matrix.md:110-117, :152` — C-5 plumbing audit
- `docs/_execution/lane_b_features/01_product_rule_and_ia.md:163-175` — handoff bridge product rule
- `CLAUDE.md:42` (HP architecture) `:52` (proxy conventions) `:55` (frozen `lib/auth/**`) `:81` (RLS-Ready Schema) `:84` (proxy + API conventions) `:136` (HP #2 demo carve-outs)
- CLAUDE.md addendum A1 — token-in-URL prohibition (this slice satisfies via body-only redeem; handoff code is the primitive itself, not a token)
- PR #512 (B11.1) — handoff primitive that C-5 consumes
- PR #586 (B11.2.b) — step-up wiring (cross-lane test failure disclosed; investigation pending)

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. B11.2.b test failure surfaced in change-log entry + escalated for separate orchestrator investigation (mirror `admin_cors_bootstrap_test` pattern from PR #588).
