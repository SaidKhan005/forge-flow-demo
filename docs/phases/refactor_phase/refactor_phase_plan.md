# Refactor Phase Plan — Guardrails-First Structural Cleanup

Status: **Planned (not started).** Created 2026-05-22.
Owner: orchestrator drives sequencing; worker agents execute per
`CLAUDE.md` "Agent-led slices".

This is the "refactor phase doc (TBD location)" promised by
`docs/POST_HARDENING_FOLLOWUPS.md` R-3. It sequences and scopes:

- `NEXT_WAVE_PLAN.md` **Phase 3 (R-1 + R-2)** + **Phase 4 (re-test)**.
- `docs/_audits/code_health/code_hardening_plan_2026_05_21.md` **§7 held
  backlog items 1, 4, 8** + the `dart_code_metrics` ratchet (items 2/6
  landed advisory).
- `docs/POST_HARDENING_FOLLOWUPS.md` **"Refactor phase scope" (R-1/R-2/R-3)**
  + the **P3 orphaned-`AuditLogHierarchyFilterPane`** flag (2026-05-22).

**Binding doctrine:** every Phase B slice is structural extraction with
**zero behavior change**, governed by the reusable
`docs/archive/phases/7_55o/phase_7_55o_refactor_non_behavior_change_contract.md`
(Core Rule, Behavior-Freeze List, "Proof Required For Every Refactor
Slice"). Do not re-derive it; cite it.

---

## 0 — The one-sentence shape

> Build the safety net first (Phase A — guardrails + behavior-pinning
> tests, **do now, not gated**), then do the structural cleanup against
> it (Phase B — **gated on the happy-state tag**), then prove behavior is
> byte-for-byte unchanged (Phase C — the regression gate).

The cleanup is only safe if "no behavior change" is **provable**. So the
prep the operator is asking for **is** Phase A: tests tightened, anti-
regrowth lints in place, a ratchet that makes debt only ever go down.

---

## 1 — Why guardrails-first (the risk we are removing)

The targets are the biggest, highest-traffic files in the app (admin
god-screens, two routers, the proxy monolith). The failure modes a naive
"just split it" pass would hit:

1. **Silent behavior drift** — a moved widget/route loses a key, a guard,
   an idempotency call, or a copy string, and no test catches it (exactly
   what produced the 6 stale operator-web failures on 2026-05-22).
2. **Regrowth** — a god-screen is split, then re-accumulates because no
   lint enforces the new ceiling (this already happened to
   `advisor_proxy.dart`: ceiling raised 19,071 → 19,900 in 5 hours).
3. **Metric backslide** — function-length / complexity counts creep up
   during the churn because nothing fails when they grow.
4. **Skipped-test rot** — a test gets `skip:`-ed "temporarily" mid-refactor
   and never comes back.

Phase A closes all four **before** a single file moves.

---

## 2 — Target inventory (from the 2026-05-22 full metrics run)

`lib/` only (proxy is in `tool/`). Worst offenders the phase targets:

| Target | Size / metric | Phase B slice | Gate |
|---|---|---|---|
| `admin/screens/operator_location_admin_screen.dart` | 5,162 lines | B2 | happy-state |
| `admin/admin_routes.dart` | 4,078 lines | B2 | happy-state |
| `admin/screens/roles_hierarchy_sessions_admin_screen.dart` | 3,255 lines | B2 | happy-state |
| `admin/screens/observability_admin_screen.dart` | 3,152 lines | B6 (after split) | happy-state |
| `operator_web/router/operator_web_router.dart` | 2,911 lines; `_buildPostOnboardingShell` 478 SLOC / CC 57 | B2 | happy-state |
| `operator_web/screens/my_account_screen.dart` | ~2,051+ lines; god-screen | B1 (R-1) | happy-state |
| `operator_web/screens/account_screen.dart` | `build()` CC **67** (worst) | B2 | happy-state |
| `tool/advisor_proxy/**` | monolith; 3 hybrid dispatchers | B3 (R-2) → B4 | proxy happy-state |
| `operator_web/screens/audit_log_hierarchy_filter_pane.dart` | 693 lines, **orphaned dead code** | B0 | none (dead) |

Whole-codebase debt baseline to ratchet down (never up): **340**
long methods (>80 SLOC), **261** complex (>CC 12), **122** over-param
(>7), **4** deep-nest (>5). Source: `runbooks/dart_code_metrics_runbook.md`.

---

## 3 — Phase A: Guardrails & safety net (DO NOW — not gated)

All additive (tests + lints + gitignore). No behavior change, no file
restructuring → **not** gated on surfaces-happy. This is the "now" work.
Each is an independent worker-agent slice; A1–A6 can fan out in parallel.

| Slice | Scope | Effort | Output |
|---|---|---|---|
| **A1 — Test baseline + flake pin** | Capture the current full-suite result (11,484 pass / 0 fail / 8 skip on master @ 2026-05-22) as a committed regression reference. Multi-seed run of `test/operator_web` + `test/admin` widget tests to confirm only the one quarantined router test flakes. Build `tool/flake_counter.dart` (§8 gap) to parse multi-seed JSON. | S | `docs/_audits/code_health/test_baseline_2026_05_22.md` + `tool/flake_counter.dart` |
| **A2 — Characterization tests for refactor targets** | **DEFERRED to each B slice's start (post-happy-state) — see "A2 timing" note below.** Add behavior-pinning tests **only where coverage is thin**, for the exact files Phase B moves: (a) `my_account_screen` panes (MFA / sessions / profile / security); (b) the 3 proxy hybrid dispatchers (B2.1, B11.2, C-4) — route tests pinning request/response envelope, auth guard, idempotency key, error shape **before** helper extraction; (c) `operator_location_admin`, `admin_routes`, `roles_hierarchy_sessions`, `operator_web_router` — smoke/widget tests pinning the key render + scope paths. Satisfies the contract's "Proof Required". | L | New `*_characterization_test.dart` files, per B slice |
| **A3 — Size-ceiling lints (anti-regrowth)** | Build `tool/operator_web_size_lint.dart` (R-1 #1) mirroring `advisor_proxy_size_lint.dart`. Generalize to a per-file ceiling map covering the admin god-screens too (`tool/screen_size_lint.dart` or extend). Set each ceiling at **current** size (freeze — they cannot grow during the phase); lowered per file as B1/B2 land. | M | `tool/operator_web_size_lint.dart` (+ admin coverage); pre-push wire |
| **A4 — Metrics ratchet check (core "do not regress" gate)** | `tool/metrics_ratchet_check.dart`: run `dart_code_linter` JSON, count warning/alarm per metric, compare to the committed baseline (340 / 261 / 122 / 4), **fail if any count grows**. Wire into pre-push (advisory → ratchet). Per the runbook, per-metric promotion to *blocking* happens later (B5) once counts drop; this is the intermediate guardrail that guarantees cleanup only reduces debt. | M | `tool/metrics_ratchet_check.dart` + committed baseline JSON |
| **A5 — Skip-quarantine lint** | `tool/skip_quarantine_lint.dart` (§8 gap): fail if any `skip:` / `.skip(` in `test/` lacks a matching row in `docs/KNOWN_FAILING_TESTS.md`. Stops silent test-skipping during the churn. | S | `tool/skip_quarantine_lint.dart` + pre-push wire |
| **A6 — Test-output hygiene** | Gitignore the two tracked files that running the suite rewrites (`test/integration/pressure/p2c_spine_findings.jsonl`, `p2d_mobile_sync_findings_summary.txt`) so refactor PRs don't carry spurious diffs / dirty the worktree. | S | `.gitignore` patterns + force-keep the canonical committed copy if needed |
| **A7 — (optional) TODO age lint** | `tool/todo_age_lint.dart` (§8 gap) — `git blame` TODOs, warn > 90 days. Low priority; keeps debt visible. | S | `tool/todo_age_lint.dart` |

**Phase A exit:** A1 + A3 + A4 + A5 + A6 lints/tools green on master;
ratchet baseline frozen; full suite still ~11,485 pass. **This is the
gate that lets Phase B start safely.**

**A2 timing (refinement 2026-05-22):** characterization tests pin a
surface's current behavior, so they are written **just before each B
slice runs, against the happy-state-frozen surface** — not in the
upfront Phase A batch. Writing them now would pin surfaces that are
still moving (operator-web is actively polished; the proxy is still
taking feature work per the code_hardening §7 item-1 hold), which
reproduces the stale-test failure mode this whole phase exists to
prevent (see the 6 stale operator-web tests fixed in PR #1157). So A2 is
a **per-B-slice prerequisite**, listed under each B row's "Pre-req"
column, not an ungated now-slice. Everything else in Phase A is
surface-independent and lands now.

---

## 4 — Phase B: Cleanup execution (gated on the happy-state tag)

Every slice obeys the non-behavior-change contract. Each PR must show the
contract's "Proof Required" block: A2 characterization tests identical
pre/post, full suite same pass count, `analyze --fatal-infos` clean, A4
ratchet count strictly down (never up). Pure structural extraction —
**no** route-logic, auth-posture, copy, or UX changes.

| Slice | Scope | Effort | Gate | Pre-req |
|---|---|---|---|---|
| **B0 — Codex follow-up: remove orphaned pane** | Delete `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart` (~693 lines) + fix the stale doc comment at `audit_log_screen.dart:123-124`. Its test is already deleted (PR #1157). Proof: `rg AuditLogHierarchyFilterPane lib` = 0 refs; full suite green; live screen still covered by `audit_log_screen_test` + `audit_log_integrity_badge_test`. **Operator-web = Codex's lane** → execute in Codex lane or with operator approval. | S | none (dead code) | A1 |
| **B1 — R-1: `my_account_screen` decomposition** | Extract MFA / sessions / profile / security panes into siblings; parent becomes a thin tab-host. Inherits whatever IA Wave 2 settled (OW-5a / OW-8d). | M | happy-state | A2(a), A3 |
| **B2 — Item 4: top-3 screen splits + `operator_web_router`** | Verbatim-relocation `part`-file split (the proven `sqlite_database_seed` pattern, item 7) of `operator_location_admin_screen`, `admin_routes`, `roles_hierarchy_sessions_admin_screen`, and `operator_web_router` (`_buildPostOnboardingShell`). 4 independent PRs. | M each | happy-state | A2(c), A3 |
| **B3 — R-2: proxy helper extraction + ceiling re-lock** | Promote envelope helpers to `tool/advisor_proxy/route_helpers.dart`; migrate the 3 hybrid dispatchers (B2.1, B11.2, C-4) to Pattern A (`router.tryHandle`); **lower** `kAdvisorProxyMaxLines` to new size + ~200 headroom. | M | **proxy** happy-state | A2(b) |
| **B4 — Item 1: proxy 3-bounded-context decomposition** | The larger split per `docs/phases/proxy_split/proxy_split_plan.md` + `docs/_audits/code_health/a3_proxy_monolith_decomposition.md`. B3 is the enabling step (helpers must move first). | L | **proxy** happy-state | B3 |
| **B5 — Metrics ratchet-down + per-metric promotion** | Per runbook order: **params + nesting first** (122 + 4, smallest/lowest-risk), then complexity (261), then SLOC (340). B1–B4 naturally drop SLOC/complexity; this slice captures the drop, lowers the A4 baseline, and promotes each metric to *blocking* (operator-approved, ceiling-raise gate). Never refactor + promote in the same PR. | M (per metric) | happy-state | B1–B4 land first |
| **B6 — Item 8: HP #5 / HP #9 observability** | Surface AI cost telemetry + RAG retrieval status in `observability_admin_screen`. Sequence **after** that screen is split in B2 (it is a 3,152-line god-screen). Functional addition, so it carries its own tests + `Frontend Exposure` per HP #10. | L | happy-state | B2 (observability split) |

**Sequencing within B (after happy-state tag):** B0 anytime · B1 ∥ B2
(independent files) · B3 → B4 (serial, proxy gate) · B5 after B1–B4 ·
B6 after B2's observability split.

---

## 5 — Phase C: Regression gate (= NEXT_WAVE_PLAN Phase 4)

Run after each B slice **and** as a phase-close sweep:

- A2 characterization suite → **identical** pass set pre/post.
- Full suite → same pass count as the A1 baseline; no new
  `KNOWN_FAILING_TESTS` rows; A5 skip-quarantine clean.
- `dart analyze --fatal-infos` → clean, no new findings vs baseline.
- A4 ratchet → every metric count **≤ baseline** (strictly down where the
  slice targeted it); A3 size lints green at the new (lower) ceilings.
- Live spot-check of touched surfaces (Preview for operator-web, `adb`
  for mobile) per NEXT_WAVE_PLAN Phase 4.

**Exit:** zero behavior regressions vs happy state; debt counts strictly
lower; ceilings locked so they cannot regrow.

---

## 6 — Gates & "what's gated on what"

| Work | Gated on |
|---|---|
| **Phase A guardrails (A1, A3–A7)** | **Nothing — start now.** Additive guardrails. |
| **A2 (characterization tests)** | Written per-B-slice at each slice's start (post-happy-state) — see "A2 timing" note. |
| **B0 (orphaned pane)** | Nothing (dead code); Codex-lane or operator OK. |
| **B1, B2, B5, B6** | **Happy-state tag** (operator marks operator-web/admin surfaces feature-stable). |
| **B3, B4** | **Proxy** surfaces feature-stable (separate "happy" mark per code_hardening §7 item 1). |
| Metric promotion to blocking (in B5) | Operator approval (CLAUDE.md Ceiling-Raise Rule R-2). |
| Each B PR | Non-behavior-change contract "Proof Required" + Pattern B audit. |

---

## 7 — Cross-references

- Pipeline home: `docs/_indices/NEXT_WAVE_PLAN.md` Phase 3 + Phase 4.
- Held backlog + bars: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §5.2, §7, §8.
- Refactor scope (R-1/R-2/R-3) + P3 orphaned-pane flag: `docs/POST_HARDENING_FOLLOWUPS.md`.
- Non-behavior-change doctrine: `docs/archive/phases/7_55o/phase_7_55o_refactor_non_behavior_change_contract.md`.
- Proxy split detail: `docs/phases/proxy_split/proxy_split_plan.md` + `docs/_audits/code_health/a3_proxy_monolith_decomposition.md`.
- Metrics ratchet mechanics: `runbooks/dart_code_metrics_runbook.md` ("Capture-and-track flow" + "Advisory posture / promotion gate").
- Workflow + ceiling-raise gate: `CLAUDE.md` "Agent-led slices" + "Ceiling-raise rule (R-2)".
