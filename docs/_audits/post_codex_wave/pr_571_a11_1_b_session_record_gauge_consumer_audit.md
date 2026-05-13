# PR #571 Audit — A11.1.b Session-Record Gauge Consumer Wiring

**Slice:** A11.1.b (Lane A — Code Health, observability follow-up)
**Owner:** Claude (Claude lane, loop-mode restart)
**Branch:** `claude/a11-1-b-session-record-gauge-consumer`
**Base:** `master` (verified — not stacked)
**Gate:** `auto` per ledger row 47 (observability-only carve-out) — but `operator` per CLAUDE.md "Agent-Led Slices" (proxy-touching)
**Size:** 463 additions / 4 deletions / 7 files

## Verdict

**approve-pending-operator** — first Claude lane PR post-loop-mode-restart. Pattern B compliance is **exemplary**: worker self-audit + executor independent audit both present at 14 lenses each with file:line citations, and spot-checks confirm worker honesty. Slice content is materially correct (closes the disjoint-counter bug from the wave deep audit finding #2). Escalating for operator nod because:

1. CLAUDE.md "Agent-Led Slices" says proxy-touching slices require explicit operator approval regardless of audit verdict.
2. Worker correctly disclosed the proxy-touch and asked for orchestrator override at audit time.
3. This is the first PR from the Claude lane post-restart — operator should sign off on Pattern B compliance quality as the baseline for the rest of the loop.

Ledger row 47 was authored with `Gate=auto` on observability-only reasoning, which the operator pre-approved when the row was added. Recommend operator say **"approve A11.1.b"** to confirm the carve-out applies and unblock auto-merge for future observability-only proxy slices in the same shape.

## Pattern B compliance

**✓ EXEMPLARY** — both worker self-audit (14 lenses) and executor independent audit (14 lenses) present in PR body with file:line citations.

The executor audit added two **executor-only lenses** beyond the standard 11:
- Lens 12 ("Bootstrap hoist correctness") — verified the load-bearing single-instance hoist in `proxy_bootstrap.dart` that prevents disjoint-counter observation. Cites `tool/advisor_proxy/proxy_bootstrap.dart:854-867, :1115, :1186-1188`. **Spot-check: verified.** Lines 850-870 of the head ref show `final sessionRecordIncompleteGauge = SessionRecordIncompleteGauge();` at line 869 with a 9-line rationale comment block above it citing the wave deep audit finding #2.
- Lens 13 ("Pattern reuse / precedent discipline") — verified the `sessionRecordIncompleteSnapshot` accessor mirrors `inMemoryBreakerStates` side-channel pattern. Cites `advisor_proxy.dart:5186, :5197, :5264, :5279, :5356`. **Spot-check: verified — and worker undercounted.** Grep finds the pair mirrored across SIX sites (5185/5186 ctor args, 5197/5213 fields, 5263/5264 ctor args of second context class, 5280/5289 fields of second class, 5356/5357 adapter passthrough), not just 4. Worker was conservative; reality is stronger. Honest.

## What landed

### 1. Bootstrap hoist (load-bearing fix)

`tool/advisor_proxy/proxy_bootstrap.dart` constructs a single `SessionRecordIncompleteGauge()` instance once in the bootstrap fan-out, threads it to BOTH:
- (a) `_buildRegistryProxyHealthCheckStore` via `sessionRecordIncompleteSnapshot: gauge.snapshot`
- (b) `ProxyProductionBindings.sessionRecordIncompleteGauge` (which `main.dart` already threads into `routeRequest` for the increment side at the POST /v1/auth/session/login handler)

Pre-slice, the snapshot-side instance was a fresh empty gauge — defeating the whole observability purpose.

### 2. New `infra` family producer

`tool/advisor_proxy/health_producers/infra_producers.dart` adds `sessionRecordIncompleteCountProducer`:
- Reads the accessor passed via family-context adapter
- Projects `value` = total increments + `metadata.buckets` = per-`(route, missing_field, count)` slice
- Defensive projection: throwing accessor → `status: 'unknown' + warning: 'producer_error'`; null accessor → `warning: 'not_wired'`
- Empty steady state → `value: 0` + empty `buckets` (distinguishable from `not_wired`)

### 3. Metric reservation + producer-context plumbing

- `tool/advisor_proxy/advisor_proxy.dart` adds `session_record_incomplete_count` to `proxyHealthReservedMetrics` (line 4892) AND `proxyHealthReservedSurfaces['infra']` (line 5004)
- Producer-context classes get the new accessor field at 5 sites (ctor + field on each of `ProxyHealthRegistryContext` and `ProxyHealthProducerContext`, plus adapter passthrough at 5356-5357)

### 4. Test coverage (6 new + producer-count inventory bump)

- `test/proxy/session_record_gauge_consumer_test.dart` (NEW, 272 LoC): 6 tests cover round-trip, payload shape, empty state, throwing-accessor defensive projection, null-accessor back-compat, registry registration
- `test/proxy/advisor_proxy_health_envelope_test.dart` (+5/-4): inventory bump 61→62 to match new producer

### 5. PII-safety assertion

Test at `session_record_gauge_consumer_test.dart:147-156` explicitly asserts no `user_id`, `operator_id`, `location_id`, `session_id`, `email`, `ip` appear in the metric `buckets`. HP #4 (per-operator isolation) preserved — only `route` + `missing_field` labels.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, not draft |
| **Pattern B both tables present** | ✓ — worker 14 lenses + executor 14 lenses |
| **No auth/RLS/schema/migration touched** | ✓ — diff scope confirms (no `db/migrations/**`, no `lib/auth/**` frozen catalog, no RLS policy files) |
| **No `lib/data/**` (frozen legacy) touched** | ✓ — diff scope confirms |
| **Bootstrap hoist real** | ✓ — verified at `proxy_bootstrap.dart:868` with 9-line rationale comment |
| **Pattern mirroring `inMemoryBreakerStates`** | ✓ — verified at 6 sites in `advisor_proxy.dart`; worker said 4 (conservative, honest) |
| **Metric reservation + surface registration both in place** | ✓ — verified `proxyHealthReservedMetrics` (4892) and `proxyHealthReservedSurfaces['infra']` (5004) |
| **Producer-count inventory test bumped** | ✓ — `test/proxy/advisor_proxy_health_envelope_test.dart:14-21` bumped 61→62 |
| **PII-safety test present** | ✓ — `session_record_gauge_consumer_test.dart:147-156` asserts no PII fields in `buckets` |
| **Bleed-stop lint compliance** | ✓ — 18,904 → 18,957 (+53), ceiling 19,071, headroom 114 |
| **Worker disclosed test runs** | ✓ — `dart analyze` clean; 6+25+11+69 = 111 test passes disclosed |
| **CI-dark-window discipline** | ✓ — touches advisor_proxy (high-risk); worker disclosed targeted test runs + regression sanity on neighbors |
| **No `--no-verify` traces** | ✓ — commit message clean |
| **`postgres_import_lint` pre-push** | ✓ — disclosed clean (1625 files, 804 exempt, zero violations) |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No graphify-out edits** | ✓ — diff scope confirms |

## Cross-lane note

Parallel PR #572 (A3.3) also touches `tool/advisor_proxy/advisor_proxy.dart` at lines 3744, 3762, 5339, 5417, 5470. PR #571 adds new class fields at 5183-5358 and reserves a new metric key at 4892-4905. The two are **line-disjoint** (#571 adds NEW fields and ctor args; #572 retypes EXISTING `catch (_)` keywords) but share the file. Whichever merges first, the other rebases with line-offset noise only — no semantic conflict. Either order is safe.

## Operator-approval rationale (re-confirming the ledger carve-out)

The ledger row was authored with `Gate=auto` on the explicit reasoning "Observability-only; no behavior change → auto gate" (line 47). This was a deliberate orchestrator carve-out at row-add time, pre-approved by operator. The CLAUDE.md "Agent-Led Slices" rule says proxy-touching slices need explicit operator approval — but this slice is observability-only by design (no route contract change, no request/response shape change, no behavior change to existing producers).

Recommend operator approve and signal whether future observability-only proxy slices in the same shape (e.g., similar wave-completion deep audit P1 wires) can auto-merge after audit-clean, or whether the operator wants to confirm each individually.

## Findings

None. The slice is well-bounded, materially correct, defensively coded, and Pattern B-compliant at the highest standard yet seen from the Claude lane this wave.

## Authority anchors

- `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` finding #2 — A11.1's consumer-side observability gap
- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 47 — A11.1.b ledger row (auto gate, observability-only)
- PR #522 (A11.1 sister slice) — increment-side wiring
- CLAUDE.md "Agent-Led Slices" — proxy-touching gate doctrine
- `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` — loop-mode prompt (this PR is the first post-restart confirmation that Pattern B requirements are landing)

## Status

**escalate-to-operator** for explicit approval of the auto-gate carve-out. Pattern B compliance recorded as **exemplary** — loop-mode restart confirmed working.
