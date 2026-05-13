# PR #561 Audit — B1.c Admin Gateway actorKind Peer-Bug Sweep

**Slice:** B1.c (Lane B — Features, deep-audit P1 deposit)
**Owner:** Claude lane (parallel session — see Salvage note)
**Branch:** `claude/b1-c-admin-gateway-actorkind-sweep`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 53 — audit-log honesty + auth-adjacent
**Size:** 353 additions / 9 deletions / 3 files (medium)

## Verdict

**approve-pending-operator** — substance is high, slice scope matched exactly, all 4 sites flipped + 4 audit-chain integrity tests added + B1.b idiom mirrored faithfully. Salvage path inspected — no drift artifacts from the mid-task relaunch.

**Pattern B violation**: 3rd occurrence from Claude lane session — prompt-drift flag now lit. Substance is honest; counter logged for operator awareness.

## Salvage path verification (relaunch-impact check)

PR body openly discloses: *"This PR was finished by the orchestrator after a Claude Code relaunch killed the spawned worker mid-task. The worker had completed all 4 production edits + the 302-line test file before dying; the orchestrator added the deep-audit doc resolution banner, ran tests (15/15 pass), and pushed."*

| Risk vector | Inspection | Outcome |
|---|---|---|
| Half-completed production edits | All 4 `_audit` helper flips present, each at the expected class. No trailing TODO/FIXME/`print()`. | ✓ Clean |
| Incomplete test cases | 4 test cases, one per gateway, each end-to-end (gateway → recording-fake → assert `actorKind` + `eventType`). All named in the 15/15 pass output. | ✓ Clean |
| Off-scope production code changes | Only the 4 flips + comment expansions in `proxy_bootstrap.dart`. No other production file touched. | ✓ Clean |
| Stale base | `baseRefName=master`; the spec's pre-shift line numbers (4083/5638/6287/6745) drifted to (4099/5660/6320/6788) but class-name anchoring is correct. The PR body table cites the new lines. | ✓ Clean |
| Parent-session salvage artifacts | Audit-doc edit is the only non-worker-authored change. The `**RESOLVED 2026-05-13 by B1.c**` banner is the disclosed scope of the salvage commit. | ✓ Clean |

**Net:** the relaunch produced no observable drift. Operator's extra-care request is satisfied — substance is intact.

## Pattern B compliance

**❌ MISSING — 3rd occurrence from Claude lane session (PRs #550, #552, #561).** Counter is now **3/3 — prompt-drift flag triggered.**

PR body has narrative sections (Summary / Sites flipped table / Tests / Deep-audit finding #1 closed / Authority / Operator gate / Salvage note / Test plan) but does NOT include:

- ❌ Worker self-audit table (14 lenses with file:line citations)
- ❌ Executor independent audit table (14 lenses with file:line citations)

**Action for operator:** the Claude lane session prompt likely needs the Pattern B audit-table requirement reinforced. The substance has been honest every time — this is a format/template drift, not a process integrity issue. Recommend a one-line reminder in the next slice prompt: *"Per Pattern B, your PR body must include both a worker self-audit table (14 lenses with file:line citations) and an executor independent audit table. Same shape as Codex's PRs."*

## What landed

### 1. Four `actorKind` flips in `tool/advisor_proxy/proxy_bootstrap.dart`

| Gateway | Function | Line on master pre-PR | Trigger events | Role gate |
|---|---|---|---|---|
| `RepositoryPricingTierAdminProxyGateway` | `_audit` | `:4087` (was `:4083` per spec) | `admin.pricing.cap_upserted`, `admin.pricing.template_applied` | `kFfPricingAdminWriteRoles` / `kFfPricingAdminReadRoles` |
| `RepositoryCorpusAdminProxyGateway` | `_audit` | `:5642` (was `:5638` per spec) | `admin.corpus.rollback`, `admin.corpus.list` | `kFfCorpusAdminWriteRoles` / `kFfCorpusAdminReadRoles` |
| `RepositoryGraphCandidatesProxyGateway` | `_audit` | `:6291` (was `:6287` per spec) | `admin.graph.*`, `admin.corpus.graph_candidates.list` | `kFfCorpusAdminWriteRoles` / `kFfCorpusAdminReadRoles` (graph shares corpus admin gate) |
| `RepositoryIntegrationAdminProxyGateway` | `_audit` | `:6749` (was `:6745` per spec) | `admin.integrations.*`, `admin.integrations.list` | `kFfIntegrationAdminWriteRoles` / `kFfIntegrationAdminReadRoles` |

Each comment block expanded with: role-gate authority + CLAUDE.md actor-taxonomy citation + B1.b reference. **Additive context, not scope creep.**

### 2. Four audit-chain integrity tests in `test/advisor_proxy_bootstrap_test.dart`

302 LoC added. Each test:
1. Wires a `_RecordingSystemAuditRepository` (existing test helper)
2. Drives a representative list method (`listOperatorsWithCaps`, `listVersions`, `listGraphCandidates`, `listBundle`)
3. Asserts the captured audit row carries `actor_kind = 'forge_admin'` AND matches the expected `eventType`

Test helpers include `_StubOperatorsRepository`, `_StubLocationsRepository`, `_StubUsageCapsRepository`, `_StubOrgUnitsRepository`, `_StubCorpusRepository`, `_StubProviderCredentialsRepository`, `_UnusedKmsProvider`, `_UnusedCloudRunAdminClient`. The KMS + Cloud Run stubs intentionally **throw** if exercised, ensuring tests don't accidentally hit those paths.

Graph candidates test creates a temp directory with empty manifest + JSONL files to satisfy the gateway's filesystem load path. Clean handling.

### 3. Deep-audit doc resolution banner

`docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md:189-196` — finding #1 (B1.b-1 peer-bug) flipped to **RESOLVED 2026-05-13 by B1.c** banner. Per `feedback_audit_plan_status_flips.md` memory rule — this is the right pattern when closing a deep-audit finding.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, draft=false |
| **All 4 spec sites flipped** | ✓ — diff confirms `actorKind: 'user' → 'forge_admin'` at each of the 4 `_audit` helpers |
| **B1.b idiom mirrored** | ✓ — comments + role-gate citation pattern matches PR #500's idiom |
| **Tests assert `actorKind`, not just `eventType`** | ✓ — each test has `expect(auditRepository.events.single.actorKind, equals('forge_admin'))` |
| **No off-scope production code** | ✓ — only the 4 flips + comment expansions in `proxy_bootstrap.dart`; no schema/migration/RLS/proxy-route touched |
| **No frozen `lib/auth/**` / `lib/data/**` touched** | ✓ — diff scope confirms |
| **Deep-audit doc resolution flip** | ✓ — `wave_completion_deep_audit_2026_05_13.md` finding #1 marked RESOLVED |
| **15/15 test pass disclosed** | ✓ — output blob in PR body shows all 4 new B1.c tests plus 11 pre-existing tests pass |
| **`dart analyze --fatal-infos` disclosed** | ⚠️ — PR body's "Test plan" lists this as a post-merge check rather than a worker-disclosed pre-push run. Minor disclosure gap. Counter to the worker discipline established by Codex's recent PRs. |
| **CI-dark-window discipline** | ✓ — high-risk surface (`tool/advisor_proxy/**`); worker disclosed 15 local test passes targeting the touched file; `flutter analyze` not explicitly disclosed but file is in scope of the analyze sweep |
| **Salvage path didn't introduce drift** | ✓ — diff is focused, complete, no telltale interrupted-work artifacts |
| **Slice scope match** | ✓ — ledger row's "4 mechanical fixes; mirror B1.b's idiom" delivered as specified |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` traces** | ✓ — commit message clean |
| **Pattern B both tables** | ❌ — neither table present (3rd occurrence from Claude lane → prompt-drift flag) |

## Findings

### P1 — Pattern B violation, 3rd occurrence from Claude lane session

PRs #550 (B11.2), #552 (A4.2), #561 (B1.c) all lack the required worker self-audit + executor independent audit tables. Substance has been honest every time; this is template-format drift, not process integrity. **Prompt-drift flag now lit per the watcher cron rule** — Claude lane session prompt should be updated to require both Pattern B tables explicitly.

**Recommended action:** add a one-line reminder to the next Claude lane prompt (e.g., "Per Pattern B, your PR body must include both a worker self-audit table (14 lenses with file:line citations) and an executor independent audit table. Same shape as Codex's PRs at PRs #547, #556, #557.") and reset the counter after the next compliant PR.

### P3 — Minor disclosure gap: `dart analyze` results

PR body's "Test plan" checkbox says `[ ] After merge, re-run dart analyze --fatal-infos on master to confirm no spillover` rather than disclosing a pre-push analyze run. Codex's recent PRs explicitly disclose `dart analyze` clean output on changed files in the PR body. Not a blocker — fix is just to have the worker disclose pre-push analyze on the next slice.

## What operator should confirm

1. **`actor_kind = 'forge_admin'` is the right taxonomy bucket** for these 4 cross-operator F&F admin paths. This matches B1.b's precedent (PR #500). Confirmation matters because once written, audit rows are immutable (hash-chained) — choosing the wrong label now creates legacy rows that future tools must understand.

2. **The 4 sites are the complete population.** The PR body says *"Other ~5 `actorKind: 'user'` sites in the file (non-admin caller paths) are untouched — precision sweep, not blanket flip."* This restraint matches the deep-audit's scope (only the 4 admin-gateway `_audit` helpers).

3. **Pattern B prompt-drift remediation strategy.** Substance is fine; the worker has been doing the audit work mentally but not formalizing it into the PR-body tables. Cheapest fix is a prompt update for the next slice; harder fix is auto-rejecting at PR-creation time. Operator's call.

## Recommendation

**approve-for-merge.** Audit-log honesty change is auth-adjacent, operator gate is correct, slice substance is high and matches the deep-audit's prescription exactly. Salvage path is clean. The Pattern B violation is process drift, not slice integrity, and is best fixed in the next prompt rather than gating this PR.

If approved, I will:
1. Merge PR #561.
2. Update ledger B1.c → merged + PR #561.
3. Triple-safeguard verification on the 4 actor_kind sites on master.
4. Open a follow-up prompt-drift remediation item for the Claude lane session (one-line reminder).

## Authority anchors

- `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` finding #1
- `docs/_audits/post_codex_wave/pr_500_b1_b_admin_audit_actor_audit.md` (B1.b precedent)
- `CLAUDE.md` "Proxy & API Conventions" — `actor_kind` honesty in `audit_logs`
- `docs/_indices/WAVE_EXECUTION_LEDGER.md:53` — B1.c row, Gate=operator
- `~/.claude/projects/.../memory/feedback_audit_plan_status_flips.md` — deep-audit RESOLVED flip pattern (honored)

## Status

Awaiting operator approval.
