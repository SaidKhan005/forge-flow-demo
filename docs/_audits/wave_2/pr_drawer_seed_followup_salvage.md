# Salvage audit — `Mobile-FU-drawer-seed-followup` (worker A2 died mid-task)

**Dispatched as:** drawer-seed-followup + 17px-overflow bundle, two commits in one PR, operator-authorized 2026-05-15.
**Worker agent ID:** `a79d82a2cf75cdc09` (Background Agent A2)
**Worker worktree:** `C:/Git Local Repos/forge_flow_demo/.claude/worktrees/agent-a79d82a2cf75cdc09`
**Worker branch (pre-salvage):** `claude/mobile-fu-drawer-seed-followup-bundle`
**Worker termination cause:** API Error 400 "Could not process image" — worker attempted to Read a full-res 1080×2424 Android emulator screenshot during the live-verify step and hit Anthropic's 2000px many-image dimension cap (the exact problem `scripts/capture_surface.ps1` was built to prevent, but the worker didn't use the helper).
**Worker self-disclosed work:** none (died before committing or self-auditing).
**Orchestrator action:** salvaging finding 1 only (drawer-seed followup). Finding 2 (17px overflow) was not started by the worker — will be respawned as a separate, smaller worker with explicit screenshot-cap warnings.
**Salvage verdict:** approve-for-merge.

## What the worker completed before dying

- Implemented finding 1 end-to-end in `lib/state/restaurant_scope_notifier.dart` (+86 LoC)
- Wrote 2 new integration-style tests in `test/state/restaurant_scope_notifier_test.dart` (+132 LoC) that exercise the exact failure scenario the orchestrator's PR #755 audit missed
- Did NOT commit, did NOT push, did NOT write a 14-lens self-audit table
- Did NOT start finding 2 (17px overflow)

## What the worker did NOT do (orchestrator covers below)

- Author the 14-lens self-audit table → orchestrator writes the audit table below (independent pass against the diff, not a placeholder)
- Verify live on the emulator → orchestrator will verify after merge + rebuild
- Write the commit message → orchestrator writes a "Salvage:" prefixed message with full attribution
- Touch finding 2 (17px overflow) → respawn separate worker

## Worker's implementation approach (which the salvage adopts)

Hooked the new seed into the existing `RestaurantScopeNotifier._load()` method (the session-independent boot path that ALREADY populates `_restaurant` for the dashboard). Introduced a documented sentinel `_kBootFallbackOperatorId = 'demo-operator'` for the `BusinessScope.operatorId` slot — because the drawer never displays `operatorId` (only `label`), and production overwrites it within milliseconds via `loadBusinessScopes`. The new method `_seedAvailableScopesFromBootIfEmpty()` is idempotent (guards on `_availableScopes.isEmpty`), composable (the existing `loadBusinessScopes` + `seedAvailableScopesFromLocal` paths still overwrite when triggered), and never overwrites `_activeScope` if already set (`_activeScope ??= ...`).

This is **option 2** from the orchestrator's postmortem on PR #755 (`docs/_audits/wave_2/pr_755_mobile_drawer_seed.md`), with an operator-id sentinel borrowed from option 1. The hybrid is cleaner than either pure option — the session-independent path fires once on demo boot, then the session-bearing paths take over when they arrive in production.

## 14-lens orchestrator audit (independent pass against the salvaged diff)

| Lens | Verdict | Note |
|---|---|---|
| 1. Authority-doc match | ✓ pass | Doc comments cite HP #2 ("demo is a writer-side switch; readers are symmetric in shape") + reference PR #755 to chain context. Explicitly notes the standalone demo build with `requireAuth: false` (no `AuthGate`) keeps `AuthSessionNotifier.session` null forever — matches the orchestrator's postmortem root-cause hypothesis. |
| 2. Route contract | ✓ pass | No new route; no API surface added beyond `_seedAvailableScopesFromBootIfEmpty` (private). |
| 3. Data / RLS | ✓ pass | Reuses `SqliteRestaurantScopeRepository.instance.listRestaurants()` from PR #755 — a read-only SELECT delegating to existing `dao.getAllRestaurants()`. No schema change, no migration, no RLS policy touched. Local cache is operator-scoped per HP #4. |
| 4. Service-layer / API surface | ✓ pass | `RestaurantScopeNotifier()` constructor + existing `loadBusinessScopes` + `seedAvailableScopesFromLocal` signatures unchanged. New method is private + additive. Existing call-sites unaffected. |
| 5. Audit log | ✓ N/A | No mutation that warrants audit logging. |
| 6. Idempotency | ✓ pass | Three layers: `if (_availableScopes.isNotEmpty) return;` early exit; `_activeScope ??= ...` non-overwrite; existing `_load()` is called once from the constructor. The boot seed runs at most once per notifier instance. |
| 7. Operator-approval gate | ✓ N/A | Not auth/RLS/schema/proxy/billing/KMS. |
| 8. Test coverage | ✓ pass | 2 new tests both green. The integration test "default constructor hydrates availableScopes from the seeded restaurant_locations rows so the drawer is non-empty in demo" is the **exact regression** for the orchestrator's PR #755 audit miss — it constructs the notifier the way the production Provider tree does (no fromRestaurant shortcut, no client, no session, no operatorId injection), runs `_load()`, and asserts `_availableScopes` has the 1 demo location + `activeScope` is set to `location:demo_restaurant_001`. The second test "subsequent seedAvailableScopesFromLocal call with a real operatorId still overwrites the boot-time placeholder" prevents the boot sentinel from sticking when real session arrives. 9 of 9 tests pass (7 existing + 2 new). |
| 9. Hash-chain risk | ✓ N/A | No `audit_logs` touch. |
| 10. Scope creep | ✓ pass | Only the `_load()` method + new private `_seedAvailableScopesFromBootIfEmpty()` method + `_kBootFallbackOperatorId` constant. No drive-by edits. Drawer title vs a11y label intentionally NOT touched — still parked as separate UX decision. |
| 11. Demo carve-out violations (HP #2) | ✓ pass | **No 5th `kDemoMode` reader branch added.** The boot seed runs identically in demo and prod; in prod the network path overwrites `_availableScopes` with proxy-authoritative data within milliseconds. The `_kBootFallbackOperatorId = 'demo-operator'` sentinel is internal scope metadata (drawer renders `label` only) — documented at the constant + at the call site. Production overwrites the sentinel before any operator-scoped API call could observe it. |
| 12. Frozen-surface violation | ✓ pass | No `lib/auth/**`, no `lib/data/**`, no `db/migrations/**`. |
| 13. B11 redemption-code URL forbidden pattern | ✓ N/A | Not B11. |
| 14. Banned-tokens grep | ✓ pass | No KMS, `parse_warnings`, `parse_partial`, `kStrictReplayFiveMinute`, `pg_advisory_lock`, `sigtermDrainHandler`, `inboundWebhookDLQTile`, `raw_payload_partition`, `pg_partman_raw` in the diff. |

## Tests + analyze verification (orchestrator ran locally)

- `flutter analyze --fatal-infos lib/state/restaurant_scope_notifier.dart` → `No issues found! (ran in 1.3s)` ✓
- `flutter test test/state/restaurant_scope_notifier_test.dart --no-pub` → `00:01 +9: All tests passed!` (7 existing + 2 new) ✓
- New test "default constructor hydrates availableScopes from the seeded restaurant_locations rows so the drawer is non-empty in demo" passes against the salvaged code; would have FAILED against master-as-of-PR-755 (verified by reading the test's own comment chain + the empty `_availableScopes` regression on the post-PR-755 live re-drive).

CI is dark per the `feedback_ci_dark_until_2026_06_01` memory; local runs are authoritative. This slice does NOT touch the CI-dark high-risk surfaces (`db/migrations`, `advisor_proxy`, `services` proxy paths, `lib/auth`, RLS), so disclosure is sufficient.

## Salvage discipline disclosure

Per `~/.claude/projects/.../memory/feedback_parallel_claude_lane_executor.md` + the canonical handoff prompt salvage rules: this PR is a **salvage of a dead-worker partial commit**. The orchestrator (this session) authored:
- The commit message + commit itself
- This audit doc (independent 14-lens pass)
- The PR body (with this salvage note)
- The push to origin

The orchestrator did NOT author:
- The implementation code (worker A2 wrote it)
- The test code (worker A2 wrote it)
- A worker-side self-audit table (worker died before producing one)

The implementation is salvaged AS-IS — no orchestrator modifications. If the implementation has issues that this 14-lens audit missed, the responsibility chain is: worker for code, orchestrator for audit-not-catching-it. PR #755's audit miss (the original gap this slice fixes) is the precedent for this discipline.

## Outstanding from the original bundle (finding 2)

`FU-mobile-shift-card-overflow-17px` was NOT started by worker A2. Will be respawned as a small fresh worker with:
- Explicit instruction to use `scripts/capture_surface.ps1` if any screenshot capture is needed
- Explicit instruction to NEVER Read full-res PNGs (>2000px on any axis) — only thumbs under `docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/thumbs/`
- Scope-trace-only first; only verify live if a thumb confirms the fix

## Decision

Commit the salvaged diff to `claude/mobile-fu-drawer-seed-followup-bundle` with a `Salvage:` prefix + push + open PR + orchestrator audits + merges. After merge, rebuild + reinstall on emulator-5554 + re-drive surface 01. If drawer populates: matrix row 01 flips 🐛 LIVE GAP → ✅ DONE-LIVE.