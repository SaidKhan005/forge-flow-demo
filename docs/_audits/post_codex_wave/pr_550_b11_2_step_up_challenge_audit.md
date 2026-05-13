# PR #550 Audit — B11.2 RFC 9470 Step-Up Challenge

**Slice:** B11.2 (Lane B — Features)
**Owner:** Claude lane executor
**Branch:** `claude/b11-2-step-up-challenge`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 66 + **four** explicit triggers (auth-critical, RLS-touching, schema-touching, proxy-touching)
**Size:** 2,084 additions / 15 deletions / 8 files (medium)
**Chunking:** light variant — single-author, single-vertical, but high-blast-radius surface (auth posture)
**Dependency:** B11.1 merged ✓ (PR #512 — handoff codes; this PR explicitly mirrors its idiom)

## Verdict

**approve-pending-operator with binding follow-up** — this is a partial-vertical delivery (schema + seam + tests, no wiring). Audit is clean on what shipped, but the **deferred scope is exactly the server-side gap B9.2 was conditionally approved against**. Operator decision needed on whether scaffold-only is acceptable AND on logging the deferrals durably before merge.

## Pattern B compliance

**❌ PARTIAL — first occurrence of Pattern B drift from this Claude session.**

PR body has narrative sections (Summary / Files changed / Schema additions / Route additions / Test cases / Out of scope / Verification / Operator approval gates / Test plan) but does NOT include the two required tables:
- ❌ Worker self-audit table (14 lenses with file:line citations)
- ❌ Executor independent audit table

The PR body IS substantive and honest (test enumeration, explicit out-of-scope deferrals, all the lint runs disclosed). But the Pattern B doctrine requires the structured tables so the orchestrator can do per-lens spot-checks against citations. This is the first violation tracked for this Claude lane session — flag but don't block.

Per the watcher prompt: "third occurrence from the same executor session indicates a prompt-drift problem; flag it." Counter: 1/3.

## What the slice spec asked for vs what landed

The B11.2 slice spec at `docs/_execution/lane_b_features/03_execution_slices.md:198-205` "Files" row lists **4 production paths**:

| Spec-listed path | Status in this PR |
|---|---|
| `tool/advisor_proxy/advisor_proxy.dart` (challenge emitter wired into handlers) | ❌ NOT touched |
| `lib/auth/fresh_mfa_resolver.dart` (client adapter) | ❌ NOT touched |
| `lib/auth/mfa_freshness_redirect_listener.dart` (client adapter) | ❌ NOT touched |
| `lib/operator_web/auth/step_up_challenge_handler.dart` (new) | ❌ NOT created |

What landed instead:
- ✓ `db/migrations/202605131400_b11_2_auth_step_up_challenges.sql` — new operator-scoped table (NOT in spec Files row but obviously required)
- ✓ `tool/advisor_proxy/auth_step_up_routes.dart` — registry + pure-function policy + dispatch router + 4 abstract seams (NEW scaffold; the spec said modify `advisor_proxy.dart` directly)
- ✓ `test/proxy/auth_step_up_routes_test.dart` — 27 test cases
- ✓ 5 drift-scanner watched docs (POST_HARDENING_FOLLOWUPS, phase docs, runbook, staging-setup script)

**Net:** 0/4 of the spec's production paths were touched. 2 new scaffold paths were added instead. The auth posture on master is **unchanged after this PR merges** — sensitive routes still accept any bearer token without freshness gate, exactly as before.

The worker discloses this explicitly in "Out of scope (intentional)":
> - Per-route wiring into `advisor_proxy.dart` / decomposed `*_routes.dart` handlers — deferred
> - Client-side adapter (3 lib/auth + operator_web files) — deferred
> - Postgres-backed `StepUpChallengesGateway` implementation — deferred

Justification given by worker:
1. File-isolation with in-flight **A3.2** (bare-catch tail chunk 1/3, currently `assigned` in ledger) and **A4.2** (perf fixes incl PG pool 4→20, currently `assigned`)
2. Bleed-stop ceiling (`tool/advisor_proxy_size_lint.dart`): 18,871 / 19,071 — only 200 lines of headroom; wiring 14+ sensitive routes inline would burst it

Both justifications are **real constraints**, not excuses.

## Executor spot-checks (on what DID ship)

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, mergeable=true, mergeStateStatus=CLEAN |
| **Schema: operator-scoped from creation** (HP #4) | ✓ — `auth_step_up_challenges` has `operator_id uuid not null`, `location_id uuid not null` from `create table`; RLS enabled |
| **Schema: wrapper-only RLS** (RLS-Ready Schema rule) | ✓ — policy at migration:230-238 uses `operator_id = public.app_current_operator()`; no bare `current_setting()` reads |
| **Schema: operator-leading B-tree indexes** (CI lint rule) | ✓ — `auth_step_up_challenges_operator_expires_at_active_idx (operator_id, expires_at) WHERE consumed_at IS NULL` + `auth_step_up_challenges_operator_user_idx (operator_id, user_id, created_at desc)` |
| **Schema: TIMESTAMPTZ throughout** (Time Guardrails) | ✓ — `expires_at`, `consumed_at`, `created_at` all `timestamptz` |
| **Schema: TTL ceiling** | ✓ — CHECK `expires_at <= created_at + interval '15 minutes'` rejects buggy emitter that mints forever-challenge |
| **Schema: id shape CHECK** | ✓ — CHECK `char_length(challenge_id) between 22 and 64 and challenge_id ~ '^[A-Za-z0-9_-]+$'` rejects malformed ids |
| **Schema: idempotent DDL** | ✓ — `create extension if not exists`, `create table if not exists`, `create index if not exists`, `drop policy if exists` |
| **Schema: grants minimal** | ✓ — `revoke all ... from public`, `grant select/insert/update/delete to service_role`, `grant select/delete to forge_admin` (PR body's claim verified) |
| **Schema: expand-contract phase** (A5+A8 doctrine) | ✓ — table is purely additive, lives in `db/migrations/` (top-level expand-only), no contract-phase post-deploy file needed |
| **Policy: pure-function** | ✓ — `StepUpPolicy.evaluate` at `auth_step_up_routes.dart:464-500` takes only `spec`/`authTime`/`actorKind`/`now`; returns sealed result variants; no I/O |
| **Policy: service-principal skip is explicit** | ✓ — `actorKind == 'service_principal' || actorKind.startsWith('sp:')` returns `SkipServicePrincipal`. V1 carve-out; future work can demand mTLS reauth |
| **Router: oracle-safe failure classification** | ✓ — `_consumeOrReject` at `auth_step_up_routes.dart:881-911`: returns 410 ONLY when the row exists in this operator AND user+route match AND `consumed_at IS NOT NULL`. Every other failure (expired, route mismatch, user mismatch, wrong operator, unknown id) returns 401. This prevents using `/v1/.../revoke` as a challenge-id oracle |
| **Router: atomic consume via gateway** | ✓ — `StepUpChallengesGateway.consume` interface returns `StepUpChallengeConsumed?`; production binding will use `UPDATE ... RETURNING` per PR body claim. Caveat: production binding is NOT in this PR (see deferrals below) |
| **Router: defense-in-depth consume on fresh caller** | ✓ — `_tryConsumeAndIgnore` at `auth_step_up_routes.dart:931-957` swallows exceptions. Comment justifies: "Fresh-enough caller — best-effort consume only. Swallow." Trade-off: a stolen `challenge_id` cannot be replayed later, but a malicious-replay attempt is not audit-logged when caller is fresh. Acceptable trade-off; the row's `consumed_at` flip is the audit trail |
| **Header: RFC 9470 shape** | ✓ — `buildWwwAuthenticateHeader` at `auth_step_up_routes.dart:511-525`: `Bearer error="...", acr_values="...", max_age=300, error_description="..."`. Quoted-string helper at `:504-507` escapes `"` and `\` per RFC 7235 §2.1 |
| **Tests: 27 cases enumerated by category** | ✓ — registry matcher (5), policy classifier (7), header (2), router dispatch (12), hash helper (1). 26/26+1 = 27. Worker disclosed `flutter test test/proxy/auth_step_up_routes_test.dart → 27/27 pass` |
| **Lints: all green per worker disclosure** | ✓ — migration_drift_scanner, migration_cutoff_lint, advisor_proxy_size_lint (18,871/19,071 headroom 200), index_leading_column_lint, rls_policy_lint, postgres_import_lint, flutter analyze on new files |
| **CI-dark-window discipline** (per `feedback_ci_dark_until_2026_06_01.md`) | ✓ — this is a high-risk slice (auth + schema + RLS + proxy). Worker disclosed all required local checks (`dart analyze`, `flutter test`, plus the 6 dart lints). For full coverage, **operator should manually dispatch CI from Actions tab before merge** |

## P1 Findings (material — operator decision needed)

### Finding 1: Three deferrals disclosed in PR body but NOT logged in POST_HARDENING_FOLLOWUPS.md

**Evidence:** PR body lists 3 explicit deferrals:
- per-route wiring into proxy handlers
- client-side adapter (`lib/auth/fresh_mfa_resolver.dart`, `lib/auth/mfa_freshness_redirect_listener.dart`, new `lib/operator_web/auth/step_up_challenge_handler.dart`)
- Postgres-backed `StepUpChallengesGateway` implementation

Spot-checked the PR's `docs/POST_HARDENING_FOLLOWUPS.md` diff: only the "Production1 Migration Apply Gap" P0 section is updated (count `38 → 39` for the new migration file). **No new P1 entry was added for the wiring deferrals.** No new B11.2.b row exists in `docs/_indices/WAVE_EXECUTION_LEDGER.md`.

**Authority anchor:** `~/.claude/projects/C--Git-Local-Repos-forge-flow-demo/memory/feedback_production_not_backlog.md` ("Build Toward Production — Default to production end-state; no scaffold/stub/follow-up deferrals").

**Severity:** P1. The deferrals are real; durably logging them is required so the wiring doesn't fall through the cracks.

### Finding 2: B9.2 operator-approval condition is technically not yet satisfied

**Evidence:** Earlier today (2026-05-13) the operator approved B9.2 (PR #547) "conditional on B11.2 server-side step-up being planned." At that point B11.2 was an `assigned` row in the ledger — the plan existed.

Now B11.2's PR ships only the scaffolding. The server-side enforcement on `/v1/auth/session/revoke` (the specific gap from B9.2's cross-lane note) is still **not in force on master** until the wiring follow-up lands. If we merge this PR and the wiring follow-up never opens, the conditional approval was satisfied in letter (B11.2 row → merged) but not in spirit (the gap is still open).

**Authority anchor:** Operator's 2026-05-13 conditional approval message + ledger row 61 B9.2 cross-lane note.

**Severity:** P1. Resolution: require a B11.2.b row in the ledger BEFORE merging this PR, so the wiring slice is durably assigned.

### Finding 3: Pattern B violation (no executor audit tables)

**Evidence:** PR body has narrative sections only. Pattern B doctrine requires BOTH a worker self-audit table AND an executor independent audit table.

**Authority anchor:** `docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Agent-Led Slices" + `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` 14-lens framework.

**Severity:** P3 nit on this PR (substance is honest and complete), but counter increments to 1/3 for this Claude lane session. If we see this twice more, prompt drift needs addressing.

## What operator should confirm

1. **Is scaffold-only acceptable as "B11.2"?** The schema + seam + 27 tests are high-quality and the file-isolation justification is real. But the spec asked for the full vertical and this PR ships ~25% of it.

2. **Open a B11.2.b row in the ledger now** for the wiring + Postgres gateway + client adapter, so the conditional approval from B9.2 stays honest? Recommended phrasing:
   > **B11.2.b — Step-up challenge wiring (proxy handlers + client adapters)** | Claude | Medium | High | operator | B11.2 merged + A3.2 merged + A4.2 merged | assigned | — | Wires `StepUpChallengeRouter.dispatch` into the 14 sensitive route handlers; adds `RepositoryStepUpChallengesGateway` Postgres binding; adapts `lib/auth/fresh_mfa_resolver.dart` + `mfa_freshness_redirect_listener.dart` + new `lib/operator_web/auth/step_up_challenge_handler.dart` per slice spec Files row.

3. **Log the 3 deferrals in POST_HARDENING_FOLLOWUPS.md** as P1 entries pointing at the new B11.2.b row?

4. **Should I manually dispatch CI from the Actions tab** before merging (high-risk slice during CI-dark window — auth + schema + RLS + proxy)?

## Recommendation

**Option A (recommended):** Approve-pending-operator on the condition that:
1. I add a B11.2.b row to the ledger (orchestrator self-merge per audit-first-then-pr-then-merge doctrine)
2. I add a P1 entry to POST_HARDENING_FOLLOWUPS.md for the 3 deferrals
3. Operator manually dispatches CI before approving

Then merge this PR + the ledger amendment together.

**Option B:** Send back. Ask Claude lane to ship the full vertical (schema + wiring + Postgres binding + client adapter) in a single PR, accepting the bleed-stop burst (the limit is intentionally conservative, can be ratcheted up with explicit operator sign-off).

**Option C:** Reject and re-scope into a slice family (B11.2.a schema, B11.2.b wiring, B11.2.c client adapter) with all three rows in the ledger BEFORE Claude lane starts.

My recommendation is **Option A**. Reasoning:
- The schema + seam + tests are correct and high-quality
- The bleed-stop burst is a real constraint that Option B would have to actively override
- A3.2 (bare-catch chunk) is `assigned` and unblocks the wiring without collision risk
- Option C is the cleanest pattern but the work is already done — backing out the orchestrator's scoping decision after the fact is process churn

## Authority anchors verified

- `docs/_execution/lane_b_features/03_execution_slices.md:198-205` — B11.2 spec (Files row + Scope text)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md:66` — B11.2 row, Gate=operator, deps on B11.1 (✓ merged)
- `CLAUDE.md` "Hard Promises" #4 (per-operator isolation)
- `CLAUDE.md` "RLS-Ready Schema" (wrapper-only RLS, operator-leading indexes)
- `CLAUDE.md` "Time Guardrails" (TIMESTAMPTZ in operator-scoped tables)
- `CLAUDE.md` "Service principals" (`sp:`-prefixed actor_kind taxonomy)
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` (wrapper-only RLS posture + SET LOCAL via tenant tx wrapper)
- RFC 9470 — Bearer challenge header shape verified against §3/§4 examples

## Status

Awaiting operator decision on Option A vs B vs C.
