# PR #568 Audit — B9.3 Adaptive 2FA Card

**Slice:** B9.3 (Lane B — Features)
**Owner:** Codex
**Branch:** `codex/b9-3-adaptive-2fa-button`
**Base:** `master` (verified — not stacked)
**Gate:** `auto` per ledger row 65
**Size:** 1413 additions / 51 deletions / 7 files

## Verdict

**approve-for-merge** — auto-gate clean. Pattern B both tables present. Material substance is high (4-state machine + server-backed factor list integration + client-side clock-skew handling + plain-English grace copy). Cross-lane note is honest about B11.2.b owning the server-side step-up wiring. Spot-checks confirm the clock-skew window + skew tolerance is correctly bounded.

## Pattern B compliance

**✓ FULL** — both worker self-audit (14 lenses with file:line citations) and executor independent audit (14 lenses with file:line citations) present in PR body. Codex Pattern B compliance preserved post-housekeeping sweep.

## What landed

### 1. New `MfaCardController` state machine (`lib/operator_web/account/mfa_card_controller.dart`, 394 LoC)

Four-state machine:
- `MfaCardStage.notEnrolled` — no factors registered
- `MfaCardStage.enrolled` — factors present, no removal requested
- `MfaCardStage.removalRequested` — pending removal, 24h grace timer counting
- `MfaCardStage.removable` — grace expired, "Turn off 2FA" CTA available

State is derived from server-owned factor/removal state via `/v1/auth/mfa/factors/list`. Optional 1-min auto-sync timer (off by default) for multi-device sync.

### 2. Client-side clock-skew handling (`lib/operator_web/auth/firebase_operator_web_auth_source.dart`)

Replaces rigid `authTime.isAfter(now)` check with windowed `_isFreshForAccountMfa(authTime, now)`:

```
final earliest = utcNow.subtract(_accountMfaFreshnessWindow);
final latest = utcNow.add(_accountMfaFreshnessSkew);
return !authTime.toUtc().isBefore(earliest) &&
    !authTime.toUtc().isAfter(latest);
```

Three test paths cover: recent auth_time, auth_time within skew window, stale auth_time → redirect.

This **complements** B11.2.b's planned server-side fix at `web_account_gateway.dart` — different file, different layer. Not redundant.

### 3. My Account screen integration (`lib/operator_web/screens/my_account_screen.dart`, +245/-42)

Card stages render the 4 states with correct CTA labels + grace countdown copy. Confirmation, cancel, countdown, and final turn-off all gated through `OperatorWebAccountActions.requireFreshMfa` fallback.

### 4. New gateway actions (`lib/operator_web/account/operator_web_account_actions.dart`, +101)

`listAccountMfaFactors`, `requestAccountMfaRemoval`, `cancelAccountMfaRemoval` — wrappers around `WebSecurityGateway` calls with the fresh-MFA fallback gate.

### 5. Test coverage (603 LoC across 3 test files)

- `mfa_card_controller_test.dart` (276 LoC, NEW) — state transitions, removal request/cancel, error paths
- `firebase_operator_web_auth_source_test.dart` (+83) — clock-skew window cases
- `my_account_screen_test.dart` (+244/-3) — widget-level state rendering + CTA gating

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, draft=false |
| **Pattern B both tables present** | ✓ — worker + executor 14 lenses each |
| **No auth/RLS/schema/migration touched** | ✓ — diff scope confirms (no `db/migrations/**`, no `lib/auth/**` frozen catalog, no RLS policy files) |
| **No `lib/auth/**` (frozen catalog) touched** | ✓ — diff scope: only `lib/operator_web/auth/firebase_operator_web_auth_source.dart` (operator-web client, not frozen catalog) |
| **No proxy routes touched** | ✓ — diff scope: no `tool/advisor_proxy/**` |
| **4-state machine has all 4 stages** | ✓ — `MfaCardStage` enum has `notEnrolled`, `enrolled`, `removalRequested`, `removable` |
| **Clock-skew handling has both window + skew** | ✓ — `_isFreshForAccountMfa` checks `earliest = now - window` AND `latest = now + skew`; stale tokens redirect via existing freshness listener |
| **Cross-lane note honesty** | ✓ — B11.2.b's planned fix is at `web_account_gateway.dart:184` (different file from this PR's `firebase_operator_web_auth_source.dart` changes); the two are complementary not redundant. Grep confirms `_requireFreshMfaToken` is NOT in `advisor_proxy.dart`, so the server-side step-up wiring is genuinely owned by B11.2.b. |
| **Worker disclosed test runs** | ✓ — `dart analyze` clean on 7 files; `flutter test` 24/24 (controller + screen) + 26/26 (auth source + gateway) + 4/4 (freshness redirect) = 54 disclosed test passes |
| **CI-dark-window discipline** | ✓ — touches client-side auth surface (medium-risk); worker disclosed targeted test runs covering the changed files plus regression coverage on neighbors |
| **Cross-lane note is honest, not a deferral excuse** | ✓ — the deferred work (server step-up on cancel route) genuinely belongs to B11.2.b's bundled scope per ledger row 70. Not scope-creep avoidance. |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` traces** | ✓ — commit message clean |
| **`postgres_import_lint` pre-push** | ✓ — disclosed clean in PR body |

## Findings

None. The slice is well-bounded despite the 1413-addition size — the scope expansion (vs ledger's "Small" sizing) is coherent: full state machine + server-backed integration + clock-skew fix + test coverage. Not scope creep.

## What this means for B11.2.b

When B11.2.b lands, it will add the **server-side** step-up challenge wiring at the cancel route + the **server-side** clock-skew handling in `web_account_gateway.dart:184` (`_requireFreshMfaToken`). B9.3's **client-side** clock-skew handling in `firebase_operator_web_auth_source.dart` is the complementary client half — the two layers work together:

- Client (B9.3): accepts auth_time within `[now - window, now + skew]`, redirects otherwise
- Server (B11.2.b): same window logic for the cancel/revoke routes, plus RFC 9470 step-up challenge dispatch

The B9.3 cross-lane note correctly flags this division. No double-implementation expected.

## Authority anchors

- `docs/_execution/lane_b_features/03_execution_slices.md:158-165` — B9.3 spec
- `docs/_execution/lane_b_features/04_verification_deploy_and_e2e.md:164-182` — verification expectations
- `docs/_execution/lane_b_features/01_product_rule_and_ia.md:110-123` — product rule for adaptive 2FA states
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 65 — B9.3 ledger row (auto gate)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 70 — B11.2.b cross-lane scope

## Status

Auto-merging per orchestrator-auto-merge-after-audit memory rule (auto-gate + no escalations + Pattern B compliant + audit clean).
