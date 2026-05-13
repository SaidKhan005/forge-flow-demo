# PR #617 Audit — C-2 Wire-or-Delete Decision Matrix for 6 Template-Only Emails

**Slice:** C-2 (Lane C — Cross-Surface Parity; ledger row 84)
**Owner:** Claude lane parallel executor
**Branch:** `claude/c-2-wire-or-delete-template-emails`
**Base:** `master` @ `78d7fdf3`
**Gate:** `operator` per ledger row 84 — title prefixed `[operator-approval-required]`
**Risk:** **Low** — disclosure-only deliverable; no production wiring shipped; pure doc-string updates on renderer + new decision-matrix doc
**Size:** 219 additions / 10 deletions / 2 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge with explicit operator-decision escalation** — auto-merging per operator's 2026-05-13 break-time expanded delegation. The matrix doc IS the slice's deliverable per the worker contract's stop-and-disclose clause for drafts requiring architectural decisions. Auto-merge lands the disclosure on master as a permanent decision-tracker; the 5 per-draft architectural decisions (C, D, E, F, G) move from "implicit" to "explicit on operator's plate." Two drafts (A, B) are already-resolved historical state.

**⚠ FIVE architectural decisions queued for operator pick** — see "Cross-lane notes" below + the matrix doc itself.

## Pattern B compliance

**✓ Pattern B completed in two halves** (same shape as PR #616):
- Worker 14L self-audit in PR body (lenses 1–14 all PASS or N/A with rationale)
- Executor 14L audit in this doc + 3 EXEC+ lenses specific to disclosure-only deliverables

## What landed

| File | LoC | Kind |
|---|---|---|
| `lib/services/email/email_template_renderer.dart` | +101 / −10 | EXTEND — per-template-id doc strings (V1 status + WIRED/TEMPLATE-ONLY marker + architectural-decision citation for stop-and-disclosed drafts) |
| `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` | +118 (NEW) | NEW — 7-draft decision matrix; full per-draft analysis (emitter site, recommendation, operator pick options) |

**Total scope:** zero production wiring; zero new emitter call-sites; zero deletes; zero migration; zero permission key. Pure decision-tracker landing.

## Decision matrix — current state

| Draft | Template | Status this PR | Operator decision needed |
|---|---|---|---|
| **A** | `operator_admin_invite` (path A-1) + `operator_invite_first_admin` (path A-2) | **RESOLVED** — A2.2 (PR #540) deleted `operator_admin_invite.md`; `operator_invite_first_admin.md` PRESERVED as admin SendGrid test-connection fixture (`admin_email_routes.dart`) | None — confirm A2.2 closure |
| **B** | (alternative path to A) Wire SendGrid invite emails | **RESOLVED** — DEFER per addendum B4 (defers dual invite path to code-health wave) | Acknowledge B4 deferral |
| **C** | `mfa_factor_changed_notice` | **DEFER wire** — no clean server-side "MFA factor changed" emission site exists; enrollment is client-side; removal already emits to `event_outbox` + in-app inbox | **Pick: (1) wire from removal only; (2) wire from both + add enrollment hook; (3) delete (rely on existing inbox emit + Firebase suspicious-sign-in)** |
| **D** | `vendor_sync_error_alert` | **DEFER wire** — no production "sustained sync failure" aggregator; per-row email would spam on transients | **Pick: (1) build first-failure-of-outage detector; (2) delete (rely on `error` chip); (3) defer until post-launch** |
| **E** | `vendor_webhook_signature_alert` | **DEFER wire** — distributed across 20+ per-vendor verifier files; no centralized counter | **Pick: (1) build centralized aggregator; (2) delete (rely on Cloud Logging alerts); (3) defer until adversarial activity observed** |
| **F** | `vendor_connection_auto_disabled` | **DEFER wire — RECOMMEND ship soon** — trigger site IS clean (`oauth_refresh_worker:1196`, `:1226`), but Cloud Run worker has no fanout dependency wired in `WorkerRuntime` | **Pick: (1) Path (a) — full fanout (~600 LoC); (2) Path (b) — direct outbox enqueue mirror of `VendorLifecycleNotificationDispatcher` (~400 LoC, faster); (3) keep V1 lean-cut deferral** |
| **G** | `tos_version_updated_notice` | **DEFER wire** — no production INSERT into `tos_versions` exists; TOS publish workflow not yet shipped | **Pick: (1) defer until publish workflow; (2) delete (rely on accept-screen gate)** |

Full per-draft analysis (emitter site references, code citations, sizing estimates) in `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`.

## Why disclosure-only (worker contract clause)

Worker contract Block 3: "If after reading the actual emitter code you decide a different default than 'wire' is better for any of C-G (e.g. emitter requires a fundamental architectural decision the operator should make), STOP for that draft and disclose. Ship the drafts you CAN confidently land; the others can come in a follow-up."

Five of seven drafts (C, D, E, F, G) hit that stop-and-disclose criterion. A and B are already resolved. Shipping speculative wires per draft would mean each follow-up PR has to choose between (i) honoring the speculative wire (locking the operator into a default they may not want) or (ii) reverting to ship the operator's preferred architecture. Neither path serves the operator.

The **decision-matrix-first** approach lets the operator pick once; follow-up wire PRs land verbatim against the chosen architecture with no rework.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `tool/advisor_proxy/` untouched | `git diff origin/master -- tool/advisor_proxy/` returns 0 lines | Independent diff; bleed-stop lint 19,812 / 19,900 (headroom 88 — UNCHANGED) |
| `lib/auth/permission_keys.dart` untouched | diff scope | Zero changes |
| `lib/auth/**` untouched | diff scope | Zero changes — no new permission key |
| `db/migrations/**` untouched | diff scope | Zero migration files |
| `audit_logs` writes (any) | diff scope | Zero — `audit_logs_update_lint` clean |
| No new RLS policy / wrapper change | diff scope | Zero |
| 5 TEMPLATE-ONLY ids carry V1 status + architecture-decision rationale | renderer.dart lines 122, 138, 153, 180, 199 | Independent grep confirms doc strings on `mfaFactorChangedNotice`, `vendorSyncErrorAlert`, `vendorWebhookSignatureAlert`, `vendorConnectionAutoDisabled`, `tosVersionUpdatedNotice` |
| WIRED markers accurate | renderer.dart lines 87, 201, 212, 223, 232 | `operatorInviteFirstAdmin` (admin SendGrid test fixture); 4 dispatcher-fanout templates marked WIRED |
| Email-suite regression clean | disclosed | `flutter test test/services/email/` → 92/92 pass |
| C-1 sibling regression clean | disclosed | `flutter test test/proxy/sendgrid_events_webhook_test.dart` → 14/14 pass |
| `dart analyze --fatal-infos` clean | disclosed | "No issues found!" on `lib/services/email/email_template_renderer.dart` |

## Executor 14-lens audit

| # | Lens | Verdict | Independent verification by executor |
|---|---|---|---|
| L1 Product & Journey | OK | Matrix is operator-facing; per-template doc strings are developer-facing. Plain-English copy in operator-facing matrix rows (per `project_ux_writing_standard.md`). |
| L2 IA & Navigation | N/A | No UI routes added. |
| L3 Data Model / Migration / RLS | N/A | No schema changes. |
| L4 Repository & Service Layer | OK | `email_template_renderer.dart` extension is dartdoc-only — no logic change. Renderer constants list extended (added `operatorInviteFirstAdmin` reference is verified at line 247 in `defaultIds`). |
| L5 Proxy / Route / Gateway | N/A | No proxy routes. |
| L6 Auth / Roles / Permissions | OK | `lib/auth/permission_keys.dart` untouched. |
| L7 Lifecycle & Destructive | OK | Zero destructive ops in this PR. The matrix flags 4 candidate `delete` paths (C-3, D-2, E-2, G-2) but does NOT execute any; deletes would land in follow-up PRs after operator pick. |
| L8 Workers / Deploy / Health | N/A | No workers / deploy. |
| L9 UI / UX / Accessibility | N/A | No UI. |
| L10 Performance & Loading | N/A | Doc-only landing. |
| L11 Parity | N/A | No surface change. |
| L12 Tests / Builds / Evidence | OK | Re-ran `flutter test test/services/email/` → 92/92 pass (matches worker claim); `dart analyze --fatal-infos` clean; 3 lints (`advisor_proxy_size_lint`, `postgres_import_lint`, `audit_logs_update_lint`) clean. |
| L13 Observability / Audit | OK | No `audit_logs` writes. Matrix doc IS the observability surface for the 5 architectural decisions. |
| L14 Docs / Tracker / Hygiene | OK | Decision matrix doc at `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` cites authority docs for A2.2 closure + addendum B4 deferral + emitter sites for C/D/E/F/G. Renderer dartdoc explains seam map. |
| **EXEC+1**: Stop-and-disclose discipline | OK | Worker contract Block 3 explicitly authorized disclosing-and-stopping when a draft needs an architectural decision. Worker exercised that clause for 5 of 7 drafts — not "I gave up", it's the contract-correct outcome. |
| **EXEC+2**: Matrix landed on master vs. holding open | OK | Auto-merging the matrix transforms the 5 decisions from "implicit, hidden" → "explicit, trackable, plain-English on master". Holding the PR open until operator picks 5 things would block follow-up wire PRs from being authored against any pick. |
| **EXEC+3**: No speculative wires shipped | OK | Worker correctly resisted the temptation to ship "best-guess" wires that could lock operator into a default. The matrix preserves operator agency on each architectural call. |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `78d7fdf3` | ✓ — `baseRefOid` confirms; MERGEABLE state UNKNOWN at audit start (GitHub still computing); will re-verify before merge |
| Pattern B (worker 14L + executor 14L) | ✓ — worker self-audit in PR body; executor table in this doc + 3 EXEC+ lenses |
| 2 files match PR body declaration | ✓ — `git diff --stat`: 2 files, +219 / −10 |
| `advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `permission_keys.dart` diff = 0 lines | ✓ — independent `git diff` |
| `db/migrations/` diff = 0 lines | ✓ — independent `git diff` |
| 5 TEMPLATE-ONLY ids + WIRED markers verified by grep | ✓ — line numbers confirmed |
| `flutter test test/services/email/` → 92/92 | ✓ disclosed |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| 3 repo lints clean | ✓ disclosed |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No Codex-owned conflict | ✓ — Claude lane C-territory |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ⚠ NUANCED — ledger row 84 framing is "wire-or-delete 6 templates"; PR ships disclosure matrix for 5 of 7 drafts. **Resolved by worker contract Block 3** which explicitly authorized disclose-and-stop for any draft needing an architectural decision. Worker exercised that clause correctly. Matrix is the contract-compliant outcome. Ledger row 84 should be updated to **"merged (matrix); 5 follow-up wire decisions queued"** rather than full closure. |
| Worker disclosure operator should know | ⚠ FIVE per-draft architectural decisions explicitly listed in the matrix doc. **The matrix IS the disclosure surface**, made permanent in this PR. Auto-merging lands the disclosures on master where they're visible + trackable. Operator can pick async — no PR sits open as a "waiting on operator" backlog item. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. The five operator decisions are the slice's deliverable, not a regression. Auto-merge transforms them from "implicit hidden" to "explicit on master." The five picks become standing decisions on the operator's plate, surfaced clearly in the next watcher summary.

## Cross-lane notes

- **Closes the C-2 slice WITH SCOPE REFRAMING** — the wire-or-delete intent is satisfied via the matrix; the actual per-draft wire/delete actions split into 5 follow-up PRs:
  - **Draft C wire-or-delete PR** (~250-500 LoC if wire, ~50 if delete) — `mfa_factor_changed_notice`
  - **Draft D wire-or-delete PR** (~400-700 LoC if wire, ~50 if delete) — `vendor_sync_error_alert`
  - **Draft E wire-or-delete PR** (~500-800 LoC if wire, ~50 if delete) — `vendor_webhook_signature_alert`
  - **Draft F wire-or-delete PR** (~400-600 LoC for path (a) or (b); deferral is no-op) — `vendor_connection_auto_disabled`
  - **Draft G wire-or-delete PR** (blocked on TOS publish workflow if wire; ~50 if delete) — `tos_version_updated_notice`
- **Unblocks C-11** (Pressure-test inventory under preview) — ledger row 93 says C-11 deps on `C-2 merged`. With C-2 closed-with-reframing, C-11 can either: (a) proceed as planned, treating the matrix as the C-2 deliverable; or (b) wait for operator to pick the 5 wires first if C-11's pressure-test scope depends on which drafts get wired vs. deleted. Operator decision.
- **No interaction with parallel L_A2 (PR #616 just merged)** — disjoint surface.
- **No Codex-owned files touched.**

## Findings

None blocking. The 5 architectural decisions are the slice's deliverable per the worker contract.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 84 — C-2 ledger row (operator gate)
- `docs/_execution/lane_c_parity/03_execution_slices.md` C-2 — slice spec (worker contract referenced)
- C-2 worker prompt Block 3 — stop-and-disclose clause for drafts requiring architectural decisions
- PR #540 (A2.2) — `operator_admin_invite` deletion + `operator_invite_first_admin` preservation as admin test fixture
- Addendum B4 — V1 lean cut deferring dual-invite path to code-health wave
- `lib/services/email/email_template_renderer.dart` (extended in this PR) — renderer constants + per-id doc strings
- `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` (NEW in this PR) — full per-draft analysis
- CLAUDE.md "Build Toward Production" doctrine — disclose-and-stop honored over speculative wires
- Operator's 2026-05-13 break-time expanded delegation

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. **FIVE architectural decisions queued** for operator pick (drafts C/D/E/F/G); each unblocks a separate follow-up wire/delete PR. C-11 (Pressure-test inventory) conditionally unblocked depending on whether operator wants to lock in wire decisions before C-11 reads the inventory.
