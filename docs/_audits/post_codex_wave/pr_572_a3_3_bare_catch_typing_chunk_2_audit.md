# PR #572 Audit — A3.3 Bare-Catch Typing Chunk 2 of 3

**Slice:** A3.3 (Lane A — Code Health)
**Owner:** Claude (Claude lane, loop-mode restart)
**Branch:** `claude/a3-3-bare-catch-typing-chunk-2`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 36 (proxy-touching) — title prefixed `[operator-approval-required]`
**Size:** 76 additions / 11 deletions / 2 files

## Verdict

**approve-pending-operator** — title-flagged `[operator-approval-required]` per ledger row 36. Pattern B compliance is **exemplary**: worker self-audit + executor independent audit both at 14 lenses with file:line citations, and spot-checks confirm worker honesty. Slice content is a pure-refactor continuation of A3.2's idiom (PR #563 merged). Recommend operator approve as **Option A continuation** — same shape, same justification, same exemplar discipline that A3.2 received.

## Pattern B compliance

**✓ EXEMPLARY** — both worker self-audit (14 lenses) and executor independent audit (14 lenses) present in PR body with file:line citations.

The executor audit adds two **executor-only lenses** beyond the standard 11:
- Lens 12 ("Site-coverage independent verification") — executor's own grep of master clusters 4-8 (lines 2292-8511) finds exactly 10 `catch (_)` matches: 5 in-scope bare sites (all typed in this PR), 1 documented retention (2426 — correctly skipped per A3.2 doctrine), 2 already-typed by A3.2 (2658, 2738 — correctly skipped), 1 doc comment string (5907 — not a real catch), 1 inside `SessionRecordIncompleteGauge.observe()` at 7024 (out-of-scope per slice brief). **Spot-check: verified.** Line 2426 head-ref view shows `try { raw = (environment ?? Platform.environment)[kMaxTokensPerRequestEnvVar]; } catch (_) { return kMaxTokensPerRequestDefault; }` — correct retention; UnsupportedError is `Error` not `Exception` so narrowing would re-throw the very failure this fallback absorbs.
- Lens 13 ("Narrowing quality") — defends `on Exception catch (_)` choice for all 5 sites by naming the concrete throw classes each site protects against (postgres `PgException`, `TimeoutException` from budget helper, `IOException` for network, `FormatException` for parse). **Spot-check: verified.** Sites 3744 and 3762 in the head ref show 5-line rationale comment blocks above each catch naming the concrete throws AND citing the "`Error`s keep propagating" invariant from CLAUDE.md addendum C4.

## What landed

### 1. Five sites typed in clusters 4-8

| Master line | Site | Action |
|---|---|---|
| 3744 | `ProxyRuntimeGauges.snapshotJson` / Postgres pool collector closure | `on Exception catch (_)` |
| 3762 | `ProxyRuntimeGauges.snapshotJson` / pubsub ring-buffer collector closure | `on Exception catch (_)` |
| 5339 | `RegistryProxyHealthCheckStore._runOne` / producer under budget | `on Exception catch (_)` |
| 5417 | `defaultProxyHealthDependencyProbe.probe` / dependency liveness | `on Exception catch (_)` |
| 5470 | `strictProxyHealthDependencyProbe.probe` / HARD-A dependency liveness | `on Exception catch (_)` |

Each catch carries a 5-line rationale comment naming the concrete throw surface plus the C4 invariant.

### 2. Two intentional skips

- Line 2426: `Platform.environment` swallow — A3.2's documented retention; UnsupportedError is `Error` not `Exception`, narrowing would break the fallback.
- Line 7024: Inside `SessionRecordIncompleteGauge.observe()` — A11.1 owns that class, A11.1.b owns the consumer wiring (PR #571 in flight).

### 3. Decomposition doc registry updated

`docs/_audits/code_health/a3_proxy_monolith_decomposition.md`:
- A3.2 row flipped to `merged (PR #563)`
- A3.3 row opens with actual line range + site count + per-site rationale subsection (mirroring A3.2's format)
- A3.4 site estimate revised ~16 → ~22 based on fresh grep of clusters 9-12 (admin delegates + predicates + `routeRequest` mega-function bodies have higher density)

### 4. Bleed-stop lint compliance

- Pre 18,904 → post 18,934 (+30 lines net; rationale comments)
- Ceiling 19,071; headroom 137 (was 167)
- PASS

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, not draft |
| **Pattern B both tables present** | ✓ — worker 14 lenses + executor 14 lenses |
| **No auth/RLS/schema/migration touched** | ✓ — diff scope: 2 files (advisor_proxy.dart + decomposition doc) |
| **No `lib/auth/**` (frozen catalog) touched** | ✓ — diff scope confirms |
| **No `lib/data/**` (frozen legacy) touched** | ✓ — diff scope confirms |
| **Site 2426 retention preserved** | ✓ — head ref shows `Platform.environment` swallow still bare; UnsupportedError correctly preserved |
| **All 5 sites narrowed to `on Exception catch (_)`** | ✓ — sites 3744/3762 spot-checked, rationale comments present |
| **`on Object` deliberately NEVER used** | ✓ — grep of diff returns no `on Object` |
| **A3.4 site count revised from grep, not from estimate** | ✓ — decomposition doc revision discloses the fresh grep methodology |
| **Bleed-stop lint compliance** | ✓ — 18,904 → 18,934 (+30), ceiling 19,071, headroom 137 |
| **Worker disclosed test runs** | ✓ — 223 advisor_proxy + 25 envelope = 248 existing test passes (no regression, no backfill needed per A3.2 Option A) |
| **CI-dark-window discipline** | ✓ — touches advisor_proxy (high-risk); worker disclosed targeted test runs on the two test files that cover the touched surfaces |
| **No `--no-verify` traces** | ✓ — commit message clean |
| **`postgres_import_lint` pre-push** | ✓ — disclosed clean |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **Title prefix `[operator-approval-required]`** | ✓ — escalating to operator |

## Cross-lane note

Parallel PR #571 (A11.1.b) also touches `advisor_proxy.dart` at lines 4892-4905 (reserved-metric block) and 5183-5358 (class-field additions). PR #572 modifies existing catch keywords at lines 3744, 3762, 5339, 5417, 5470 — line-disjoint at the semantic level (different operations). Both worker and executor note: whichever merges first, the other rebases with line-offset noise only. Worker correctly flagged this in the "Cross-lane notes" section of the PR body.

## Operator-approval rationale

Same shape as A3.2 (PR #563): operator-approved Option A on 2026-05-13 — cluster-aligned chunking (12 + 16 + 16 + 1 retained) + pure-refactor reasoning for the test-backfill gap (typed catches preserve all observable behavior except `Error` propagation, which is the intended improvement). A3.3 actual count came in lower (5 vs 16) because clusters 4-8 turned out sparser than the seam-map estimate; A3.4 revised up correspondingly. Net 45-site sweep target preserved.

Recommend operator confirm **continuation of Option A** for A3.3 — and pre-approve A3.4 in the same shape so the Claude lane can pick A3.4 without re-escalation.

## Findings

None. The slice is well-bounded, materially correct, behavior-preserving on `Exception`-class failures, intentionally `Error`-propagating per addendum C4, and Pattern B-compliant at the highest standard.

## Authority anchors

- `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` "Bare-catch sweep progress" registry — exemplar precedent
- PR #563 (A3.2 sister slice, merged at `be7010dc`) — live exemplar idiom
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 36 — A3.3 ledger row (operator gate)
- CLAUDE.md "addendum C4 — no silent failures" — `on Object` deliberately never used so genuine `Error`s propagate
- `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` — loop-mode prompt (this is the second post-restart confirmation that Pattern B requirements are landing exemplarily)

## Status

**escalate-to-operator** for explicit approval — title-flagged `[operator-approval-required]`. Recommend operator say "approve A3.3" (and optionally "and pre-approve A3.4 in same shape") to unblock both the merge and the next chunk pickup.
