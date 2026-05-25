# Support logs (admin debug console) UX overhaul — Lens Audit + Implementation Plan

Status: in execution. Decisions: STATS-ONLY (no AI message content), 30-day retention, fold
tabs into a Type filter, dedicated `proxy_request_stats` table (§12 supersedes the §9.2 B1
write path). LANDED on origin/master: P1a (#1277), P1a' (#1285), P1b (#1291), P2 (#1301),
P3 screen redesign (#1312, `07d9574`). **Backend + UI complete end-to-end.** P4 browser QA
DONE 2026-05-25 (admin console built + served on :8188; Support logs verified live: plain
rows "Advisor answers · Worked · 21 days ago", folded Type/When/Result filter, "Updated …",
Live chip, expandable "Technical reference" with Copy buttons, no `{ }` dump, scope pane
untouched, zero console errors). **CORE EFFORT COMPLETE.** QUEUED follow-ups: P1b.2
(failure/timeout telemetry), P3.2 (actor uid → name/role at render).
Branch/worktree: claude/kind-knuth-b68509
Date: 2026-05-24
Scope surface: `lib/admin/screens/debug_console_admin_screen.dart` (the RIGHT content
pane only). The left scope picker (`AdminSetupWorkspace` tree) and the scope banner /
scope-mirroring filters are explicitly OUT of scope per operator instruction
("leave the scope as is").
Mockup: `docs/_mockups/admin_support_logs_redesign.html` (before/after).

---

## 0. The headline finding (read this first)

**The redesign mockup shows data that does not exist in production.** The screen
reads the `proxy_requests` projection, which is an **idempotency ledger, not a
request-telemetry log**. Ground truth:

- Table `public.proxy_requests` has 9 columns only: `request_id`, `idempotency_key`,
  `request_type`, `operator_id`, `location_id`, `usage_class`, `response_payload`,
  `created_at`, `updated_at` (`db/migrations/202604250005_advisor_cloud_foundation.sql:196-211`;
  the later RLS migration `202604250007_*` adds zero columns).
- The production projection (`tool/advisor_proxy/proxy_bootstrap.dart:9772-9895`) emits
  `request_meta` as **3 synthesized keys**: `request_type`, `response_recorded` (bool),
  `content_logging: 'meta_only'`. Nothing else.
- `status` is **derived** as only `success` | `unknown` — production never emits
  `error` or `timeout` here (`proxy_bootstrap.dart:9781-9784`).
- `latency_ms` is **derived** as `updated_at - created_at` (row lifetime), `0` for rows
  never updated — NOT a measured request latency (`proxy_bootstrap.dart:9786-9792`).
- **No actor identity** (person name / role / email), **no route, method, HTTP status
  code, model, or token counts** exist anywhere on the row.

The rich fields in the mockup (Who: Marco Lee (Manager); Took: 1.2 seconds;
Result: Failed/Timed out; Route POST /v1/advisor/qa → 200; Model; Tokens) come from
the **demo fixture** `kDebugConsoleDemoEntries`
(`lib/admin/services/debug_console_admin_gateway.dart:528-654`), which is fiction added
to make the demo walkthrough look populated. Designing against the demo would ship
phantom data in production, which the **Metric Honesty Doctrine** and the UX Adjustment
Framework ("no fake affordances", "do not show phantom data") forbid.

This does not kill the overhaul. Every clarity win still holds (plain words, no `{ }`
dump, no monospace, one compact filter row, collapsed technical block, shrunk live bar,
folded tabs). What changes is the **content of the detail view**: it must show only what
is real, with honest "not recorded" sentinels for the rest. See the decision fork below.

---

## 1. Decision stops (operator must pick before build)

**Fork — how rich should the detail view be?**

- **Option A — Honest redesign now (RECOMMENDED).** Ship the full visual/clarity
  overhaul against the data that actually exists. Show: request kind, when, coarse
  result (Worked / Not recorded), request reference, retry reference, operator + location,
  and the gated full-content reveal. Where a field is not recorded (actor, route, model,
  tokens, real latency), either omit it or show the honest `—` sentinel with a one-line
  "not recorded" note. No schema/proxy change. Delivers the operator's stated goal
  (simpler, no machine language, less clutter) with zero gated-surface risk.
- **Option B — Backend enrichment first, then the rich view.** Add real telemetry to
  `proxy_requests` (actor identity, measured latency, true status, route, tokens, model)
  so the rich mockup is honestly backed. This is a **schema migration + proxy hot-path
  change** (RLS-touching, proxy-touching) — gated work requiring explicit operator
  approval, far larger than a UX pass, and writes on every proxy request. Recommend
  scoping this as its own phase later if the rich view is wanted; not bundled with the
  UX overhaul.

The rest of this plan is written for **Option A** and notes where Option B would extend it.

---

## 2. Lens audit table (Feature Implementation Lens framework, deep pass)

| Lens | Checked | Finding | Required action |
|---|---|---|---|
| 1 Product/journey | screen + mockup | F&F support/super_admin reads recent proxy activity for a chosen business. States needed: loading, empty, error, forbidden (ff_support sees no full content), view-only. All exist today. | Keep all states; reword copy plain. |
| 2 IA/navigation | `admin_routes.dart:326-334`, `_buildDebugConsole:2479-2540` | Mounted inside `AdminSetupWorkspace` (left scope tree + right pane). Route id `debug`, nav label "Support logs". Header already on `OperatorWebScreenHeader` + `OperatorWebScreenFrame` (cleanliness wave H4 already landed). | No route/IA change. Keep route id/path/label. |
| 3 Data model/RLS | `202604250005_*:196-211`, `proxy_bootstrap.dart:9772-9895` | **Ledger, not telemetry.** 3-key meta; derived status/latency; no actor/route/model/tokens. RLS scoping intact (operator_id/location_id). | Design detail view to real fields only (Option A). Option B = migration + RLS index work (gated). |
| 4 Repo/service | `debug_console_admin_gateway.dart` | In-memory demo gateway + Http gateway. `request_meta` is a free-form map that already round-trips `summary`/`actor_*` if present. | No service change for Option A. Enrich demo fixtures only. |
| 5 Proxy/gateway | `admin_route_group_part.dart:165-352`, `advisor_proxy.dart:8229-8250` | Support-help endpoints = same `proxy_requests` filtered by `usage_class` set. Read gate: super_admin+ff_support; full-content gate: super_admin + per-op flag + payload. | Keep all gateway methods + routes unchanged → gateway/proxy tests untouched. |
| 6 Auth/roles/scope | `admin_routes.dart:2513-2526`, `proxy_bootstrap.dart:9799-9805` | `editingEnabled` = super_admin drives full-content reveal; ff_support is view-only ("Support view only" badge). Scope from hierarchy. | Preserve gating exactly. Keep the view-only badge + locked-content copy (reworded). |
| 7 Lifecycle/destructive | screen | Read-only surface. No create/edit/delete. | None. |
| 8 Deploy/health | n/a | No startup/worker/deploy impact. | None. |
| 9 UX state/a11y | screen body | Machine language + clutter (mono fonts, `{ }` dump, raw `advisor_qa` codes, duplicate type controls, full-width live bar, empty actor line in prod). | The core of this work. See §3. |
| 10 Performance | `_refresh/_pollTail:312-537` | Manual-first fetch, client re-filter, 5s opt-in tail with no stacked calls, list clamp to `kDebugConsoleListLimit`. Good. | Preserve the in-flight/clamp discipline. Don't auto-fetch on mount. |
| 11 Parity | agent sweep | No operator-web/mobile request-log twin. `RequestLogEntry` is admin-only (3 files). Use-case vocabulary shared with observability + pricing screens. | Keep use-case wording consistent with observability/pricing. |
| 12 Tests/evidence | `test/admin/debug_console_admin_screen_test.dart` (~95+ assertions) + gateway/proxy/shell tests | Heavy key + copy pins. See §5. | Update the screen test in lockstep; keep gateway/proxy tests untouched by not changing the data API. |
| 13 Observability/support | screen | This screen IS the support tool. Honest, copyable references matter most. | Keep request/retry references copyable; label `request_type` honestly (not "route"). |
| 14 Docs/tracker | this doc | UX pass, no tracker truth change until landed. | Update mockup to honest version; no tracker move pre-merge. |

---

## 3. The honest "After" specification (Option A)

Right pane only. Left scope tree + scope banner untouched.

**Header** — keep `OperatorWebScreenHeader` (icon `bug_report_outlined`, title "Support
logs", "Admin only" badge). Reword subtitle to plain English, e.g. "Recent activity for
the business you picked. Open a row for the details support can use." Replace the
monospace "Last checked: …" with a plain "Updated <relative>" line. Keep the
"Support view only" badge for ff_support (reworded plainly).

**Filter row (replaces the Filters panel + the "Request type key" box + the tip line)** —
one compact row: Search, Type, When, Result.
- Search keeps today's behavior (matches request id OR idempotency key) but the hint
  becomes plain: "Search by reference".
- **Type** dropdown folds the 3 tabs AND the request-type key into one control:
  All activity · Advisor answers · Coaching help · Workflow planning · Workflow
  scheduling · Relationship help · Account help (the support groups reuse the existing
  `listSupportHelpRequests` calls; specific AI types set `usageClass` on `listRequests`).
  This is front-end-only — no gateway/proxy change (confirmed: support endpoints are the
  same table filtered by `usage_class`, `admin_route_group_part.dart:306-352`).
- When = the existing `RequestLogTimeWindow` presets. Result = Any / Worked / Not recorded
  (NOT error/timeout, since production never emits those here — offering them would be a
  filter that always returns nothing).
- Keep the scope-driven Business/Location context as-is (it mirrors the left scope; not
  re-clutter). Do not add the standalone exact-ID filter chips back into the compact row;
  scope already fills them.

**Row (collapsed)** — status dot + plain title + secondary "<result> · <relative time>".
Body font, not monospace. Title = plain-English label of the request kind. Drop the
"summary"/route column and the "123 ms" latency from the collapsed row (latency is not a
real measurement; do not headline it).

**Row (expanded) — two zones:**
- "What happened" (plain `label: value` rows, body font): What (request kind), Result
  (Worked / Not recorded), When (human date). Show actor only if `request_meta` actually
  carries it (`—`/omit otherwise — honest). Do NOT show "Took" as a headline; if shown at
  all, label it honestly (e.g. "Recorded duration") and sentinel `—` when 0/absent.
- "Technical reference (for engineering)" — collapsed by default; contains the real
  identifiers only: request reference (`request_id`), retry reference (`idempotency_key`),
  request type (`request_type` / `usage_class`), operator id, location id. Monospace is
  acceptable HERE (copy accuracy), with copy buttons. Do NOT label `request_type` as
  "route" — it is a request-type label, not an HTTP route.
- Full-content block: keep the exact role+flag gating. Reword the locked copy plainly
  ("Full message text is hidden. This business hasn't turned on full-content sharing.")
  and the unlocked header ("Full message text").

**Live refresh** — shrink the full-width bar to a small "Live" chip/toggle beside Refresh
in the header. Keep the 5s opt-in polling + no-stacked-calls discipline exactly.

**Status / result wording** — add a NEW display-only helper for on-screen result wording
(Worked / Not recorded). Do NOT change `requestLogStatusLabel` — its output is a WIRE
value fed to the `status=` query param the proxy parses (`debug_console_admin_gateway.dart:333`;
test pins `'error'` at `debug_console_admin_gateway_test.dart:451`).

---

## 4. File-by-file change plan (Option A)

1. **`lib/admin/screens/debug_console_admin_screen.dart`** (primary). Rework `_Header`
   subtitle + last-checked; replace `_FilterBar` + `_RequestUseCaseKey` with one compact
   filter row + Type dropdown; collapse the 3 `TabBar` tabs into the single list driven by
   the Type filter (keep the gateway calls); rebuild `_RequestRow` collapsed + expanded
   (plain fonts, two-zone detail, collapsible technical block with copy buttons); delete
   `_formatMap` `{ }` dumps from human view; move live-tail to a header chip; replace mono
   text styles on human-facing parts with body styles; keep all `Key(...)` values that
   tests rely on where possible (see §5), rename only with matching test updates.
2. **`lib/admin/admin_human_labels.dart`** — add plain labels for the 9 support usage
   classes so titles stop title-casing to "Mfa Diagnostics" etc. (reuse the good labels
   already in `kRelationshipHelpUseCases`/`kAccountHelpUseCases`). Add a display-only
   result-wording helper (NOT touching `requestLogStatusLabel`). NOTE: `adminRequestUseCaseLabel`
   is shared by observability + pricing screens — keep the existing 4 labels' output
   stable to avoid breaking their tests; only ADD support-class entries.
3. **`lib/admin/services/debug_console_admin_gateway.dart`** — enrich
   `kDebugConsoleDemoEntries`: add `summary` + (optional) actor keys to the 5 main demo
   rows and add a few rows covering the currently-uncovered support usage classes, so the
   unified Type filter looks populated in kDemoMode. Display labels on `SupportHelpUseCase`
   may be reworded; do NOT change use-case `id`s (wire keys).
4. **`tool/ux_em_dash_lint.dart`** — if any operator-facing copy moves into
   `admin_human_labels.dart` (currently NOT in `kUxCopyRoots`), add that file to
   `kUxCopyRoots` so the new copy is lint-enforced. The screen file is already covered by
   the `lib/admin/screens` root.
5. **`test/admin/debug_console_admin_screen_test.dart`** — update in lockstep (see §5).
6. **`docs/_mockups/admin_support_logs_redesign.html`** — revise the "After" view to the
   honest version (remove/flag actor, route, method, model, tokens, "took"; keep the
   structure, plain copy, and technical-reference disclosure). So the operator approves the
   real thing.

NOT touched: `admin_routes.dart` (route/IA), the proxy (`tool/advisor_proxy/**`), any
migration, `debug_console_admin_models.dart` data contract, `admin_capability_gate.dart`.
This keeps the change off all gated surfaces (auth/RLS/schema/proxy).

---

## 5. Test impact (the "actually working" gate)

Only ONE test file is materially affected by a copy/structure/font redesign:
**`test/admin/debug_console_admin_screen_test.dart`** (~95+ assertions: ~70 `find.byKey`,
~18 `find.text`, a `Switch`-type assertion on the live-tail control, 2 overflow guards).
Plan to keep this green:

- **Preserve load-bearing keys** where the element survives: `admin_debug_console_screen`,
  `admin_debug_console_row_<id>` prefix, `admin_debug_console_search_field`,
  `admin_debug_console_full_content_<id>` / `_full_content_locked`,
  `admin_debug_console_scope_banner`, `admin_debug_console_request_log_body`,
  `admin_debug_console_view_only_indicator`, `admin_debug_console_refresh_button`.
- **Tabs → Type filter:** the tab keys (`admin_debug_console_tabs`,
  `..._tab_relationship_help`, `..._relationship_help_tab`, the relationship/account row
  prefixes) and the "Typed view of relationship/account" copy assertions WILL change. Update
  these tests to drive the Type dropdown instead. Net: the 3-tab tests become Type-filter
  tests with equivalent coverage.
- **Live-tail control:** test reads it as a `Switch` (lines ~124-125). If it becomes a chip,
  update to the new control + key (`admin_debug_console_live_tail_toggle` should be kept on
  the new control).
- **Copy pins to update:** "Last checked: …" → new "Updated …"; "Request type: any/Coaching
  help" (filter-chip label format) → new Type-dropdown assertions; keep `'Advisor answers'`
  (line 182) working — it comes from the shared label catalog we are NOT changing.
- **Overflow guards** (`takeException isNull` at the 800x600 and 1440x1024 viewports, and the
  shell embed at `admin_shell_widget_test.dart:433`) — the new row/detail layout must not
  reintroduce `RenderFlex` overflow. Verify at both viewports.
- **Do NOT change** the gateway data API (`SupportHelpSurface`, `listSupportHelpRequests`,
  filter axes) → `debug_console_admin_gateway_test.dart` and
  `admin_debug_console_routes_test.dart` stay green untouched.
- **Shared-label caveat:** if any change edits the 4 existing `adminRequestUseCases` labels,
  also update `test/admin_pricing_tier_screen_test.dart:184,421,425` and
  `test/admin/observability_admin_screen_test.dart:226`. Plan avoids this by only ADDING
  support-class labels.
- No golden/screenshot tests exist for this screen.

---

## 6. Verification plan

- `dart analyze` on touched lib + test paths (CI is dark until 2026-06-01, so local analyze
  is the gate per the CI-dark rule).
- Targeted tests: `flutter test test/admin/debug_console_admin_screen_test.dart` (after
  updates) plus `test/admin/debug_console_admin_gateway_test.dart` and
  `test/proxy/admin_debug_console_routes_test.dart` (should stay green untouched) and
  `test/admin_shell_widget_test.dart` (overflow guard).
- Em-dash lint: `dart run tool/ux_em_dash_lint.dart`.
- Browser QA per `runbooks/admin_console_browser_qa_runbook.md` (admin-web-static build,
  `ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true`, port 8186): open Support logs from a business
  scope, expand a row, open Technical reference, copy a reference, toggle live, switch the
  Type filter across AI + support types, and confirm ff_support (view-only) hides full
  content. Capture console errors.
- Honesty check: with the live (non-demo) gateway shape in mind, confirm the detail view
  shows `—`/omits the fields that production does not populate (no phantom actor/route/
  model/tokens).

---

## 7. Slice breakdown (agent-led, worktree → PR → STOP; orchestrator audits + merges)

Sized so no two slices edit the same file.
1. **S1 — Honest mockup revision** (`docs/_mockups/admin_support_logs_redesign.html`).
   Operator re-approves the real look. (Fast; gates the rest.)
2. **S2 — Labels + demo fixtures** (`admin_human_labels.dart`,
   `debug_console_admin_gateway.dart`, `tool/ux_em_dash_lint.dart`). Add support-class
   labels + display result helper; enrich demo rows; extend lint roots. Add/extend unit
   coverage for the new label fallbacks.
3. **S3 — Screen rebuild** (`debug_console_admin_screen.dart` +
   `test/admin/debug_console_admin_screen_test.dart`). The main UI work + test updates in
   one slice (same change surface; keeps tests honest with the code).
4. **S4 — Browser QA evidence + this doc's verification section filled in.**

Option B (if chosen) inserts a gated, operator-approved backend phase BEFORE S3:
migration adding telemetry columns + RLS index + proxy projection/write changes + proxy
tests. Not planned here in detail pending the decision.

---

## 8. Residual risks

- **Honesty regression (highest):** building against the demo's rich fixture would ship
  phantom fields. Mitigation: §3 honest spec + §6 honesty check; the demo enrichment is
  cosmetic-for-demo only and must not imply the fields are real in production.
- **Test churn:** the screen test is large and copy/key-coupled. Mitigation: keep keys where
  possible; update tab→Type tests deliberately; run at both viewports for overflow.
- **Shared label drift:** observability/pricing reuse `adminRequestUseCaseLabel`. Mitigation:
  only ADD labels; don't edit the 4 existing.
- **Scope-creep into gated surfaces:** must NOT touch proxy/schema/auth for Option A.
  Mitigation: file allow-list in §4.
- **Tab-fold UX:** folding 3 tabs into a Type filter is a small behavior change the operator
  flagged as a product call; the mockup shows it. Confirm acceptance, else keep 3 plainly
  named tabs (still front-end-only).

---

## 9. CHOSEN PATH: Option B — backend telemetry first (operator decision 2026-05-24)

The operator chose to back the rich view with real data. This section is the end-to-end
backend design. It is **triple-gated work (schema + proxy hot path + RLS)** and needs
explicit operator approval at each merge per CLAUDE.md.

### 9.1 Source inventory (what exists vs what's missing)

| Need | Reality | Cite |
|---|---|---|
| model, prompt/completion tokens, **measured latency**, cost, user_id, per AI turn | A purpose-built table **`advisor_conversation_log`** has ALL of this + tiered retention + a working repository `recordTurn(... userId ...)` — but it is **DORMANT: no production writer calls it**, and it has **no `request_id`/`idempotency_key`** to join to `proxy_requests`. | `db/migrations/202604280007_phase_9_0sigma_h_advisor_conversation_log.sql:102-285`; `lib/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart:131-257` |
| join existing rollup instead | `usage_logs` is a monthly **rollup** (per operator/location/usage_class/period); sums `token_count` (no in/out split), no per-request key → **not joinable** | `advisor_proxy.dart:6519-6578`; `202604250005:150-171` |
| the table the screen reads today | `proxy_requests` = 9-col idempotency ledger; status/latency are **synthetic** in the read projection; no actor/model/tokens/route; **no working retention** (48h is a comment, no pg_cron prunes it) | `202604250005:196-211,420`; `proxy_bootstrap.dart:9781-9792` |
| who made it (name + role) | **uid is known in memory** at write time (`OperatorContext.userId`) but **not persisted**. name + role are **already resolvable from uid** via `users`/`roles` (the members gateway does this). Doctrine: store uid in logs, **resolve name/role at render time, never store PII in logs**. | `advisor_proxy.dart:2203-2233,3648-3677`; `members_admin_gateway.dart:94-116`; `audit_attribution_contract.md` |
| measured latency + real status | **Computed in memory** at completion (`advisor_proxy.dart:10010-10064`) but dropped; folding into the existing completion UPDATE adds **zero extra round-trips**, but latency/status must be **measured and passed in** (proxy-logic change, not just schema). | `advisor_proxy.dart:6663-6670` |

### 9.2 Design choice (B1 recommended)

- **B1 — Activate the purpose-built `advisor_conversation_log` (RECOMMENDED).** Wire its
  `recordTurn` into the proxy completion path (data already in memory); add a correlation
  key (`request_id` or `(operator_id, location_id, idempotency_key)`) so the support-log
  projection can join it; capture measured latency + real status. Pros: the table was
  built for this, has model/tokens/latency/cost/user_id, real tiered retention, and
  encrypted-content handling. Cons: confirm it covers ALL LLM classes (advisor + coach +
  workflow), not advisor-only; add the join key.
- **B2 — Add telemetry columns to `proxy_requests`.** Cheap write (extend the existing
  completion UPDATE, no extra round-trip) and the screen already reads this table. Cons:
  pollutes an idempotency ledger with telemetry; **no working retention → unbounded growth**
  unless retention is wired first; still needs the actor column (doctrine prefers the
  conversation log) and measured latency/status. Not recommended.

### 9.3 Honesty nuance — not every row has every field

Rich AI telemetry (model, tokens, latency) only exists for **LLM requests** (advisor_qa,
coach_qa, wf_pl, wf_schedule). The **support-help classes** (account_help, auth_support,
mfa_diagnostics, session_support, notification_support, user_removal, relationship_review,
…) are **not LLM calls** and will honestly have no model/tokens. The detail view must show
the AI fields only where they exist and `—`/omit otherwise (Metric Honesty Doctrine).

### 9.4 Retention / history = a PRODUCT decision

`proxy_requests` is intended to be pruned at ~48h (and isn't pruned at all today). For a
support tool, ~2 days of history is likely too short. `advisor_conversation_log` supports a
tiered retention window. **How far back support logs should reach is an operator decision**
(see Decision stops). Whatever the window, retention must be made REAL (pg_cron / partition
drop) before fattening rows — currently a no-op.

### 9.5 Compliance steps any schema change must follow

- New migration timestamped after the current cutoff `202605240900_…`; bump the cutoff.
- `dart run tool/migration_drift_scanner.dart --fix --strict-docs` then
  `dart run tool/migration_cutoff_lint.dart`.
- Any new index leads with `operator_id`/`(operator_id, location_id)`
  (`tool/index_leading_column_lint.dart`); RLS policy bodies use the wrapper functions, no
  bare `current_setting()` (`tool/rls_policy_lint.dart`).
- Operator-scoped time-bearing rows: `TIMESTAMPTZ` (UTC); add `business_date DATE`
  write-once **only if** the UI buckets by business day.
- Gated merges: `tool/pre_merge_gate.sh` + `tool/verify_pr_landed.sh` (CI dark to 2026-06-01).

### 9.6 Phasing (each phase = its own gated approval + PR)

- **P1 — Persistence + write (gated: schema + proxy + RLS).** Add the join key +
  measured latency + real status capture; wire `recordTurn` (B1) on every LLM request path;
  make retention real. Proxy + repository + migration tests.
- **P2 — Read projection (gated: proxy).** Extend the debug-console projection to join the
  telemetry; return model/tokens/latency/status/actor-uid; resolve uid→name/role at render
  (reuse the members lookup). Proxy route tests.
- **P3 — UX overhaul (front-end).** The §3 redesign, now backed by real fields; folded
  Type filter; plain copy; screen test updates (§5).
- **P4 — Demo parity + browser QA + evidence.** Enrich demo fixtures to match the real
  shape; admin-console browser QA; fill §6 verification.

### 9.7 Added residual risks (Option B)

- **Coverage:** confirm `advisor_conversation_log` is written for coach/workflow LLM paths,
  not advisor-only; otherwise extend the write path (P1 design question).
- **Encrypted content boundary:** full message content is KMS-encrypted and MFA-gated
  (`admin.audit_privacy.read`); the support-log full-content reveal must respect that gate,
  not bypass it.
- **Retention window vs support need:** the chosen history window trades storage/cost vs
  support usefulness; settle before P1.
- **Scope reality:** this is no longer a UI pass; it is a multi-phase backend program on
  gated surfaces. Each phase needs operator sign-off to merge.

---

### 9.8 P1b-blocking finding — the chosen table is a CONTENT log, not a stats log

Surfaced 2026-05-24 while prepping P1b by reading the actual writer
(`lib/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart:131-258`):

- `recordTurn(...)` **requires** `contentEncrypted` / `contentIv` / `contentKeyRef` /
  `contentHash` (validated non-empty) plus `conversationId` / `turnIndex` / `role`. The
  repo "deliberately does NOT accept plaintext content — encryption happens upstream in the
  proxy using the KMS-managed CMK." So writing ANY row to `advisor_conversation_log` means
  KMS-encrypting and storing the **full prompt/response text** of every AI turn, with
  conversation threading.
- This was NOT visible when B1 was chosen. B1 was framed as "the table that holds model/
  tokens/timing/cost/user." It is really a full **encrypted conversation history** that also
  carries those stats. Using it for the Support-logs stats means either (a) also storing
  encrypted message content (KMS-on-hot-path + a real privacy/storage/retention commitment —
  effectively activating a whole conversation-history feature), or (b) relaxing the table/
  writer to allow content-free telemetry rows (small schema/code change).
- Note: the Support-logs "full content" reveal today already uses a SEPARATE store
  (`proxy_requests.response_payload`, gated by super_admin + opt-in flag). The conversation
  log's content is a different, MFA-gated (`admin.audit_privacy.read`) store. The support
  stats goal does NOT require the conversation log's content.

**Decision needed (privacy fork) before P1b:**
- **Stats-only (recommended for the stated goal):** record who / model / tokens / measured
  latency / result only; store NO message text. Minimal privacy + cost. Cleanest home is
  likely telemetry columns on the existing `proxy_requests` completion write (the B2 shape),
  reusing P1a's retention pattern; the P1a correlation column on `advisor_conversation_log`
  goes unused but the retention fix there stays valuable. (Alternatively keep B1 and make its
  content columns optional for telemetry-only rows.)
- **Full conversation logging:** activate `recordTurn` as built — encrypted 30-day copies of
  every AI question + answer, letting support read the actual messages behind the existing
  MFA gate. Bigger privacy/storage/cost footprint; its own feature decision; larger build
  (KMS encryption on the hot path).

P1b stays blocked until the operator picks. This may revise the §9.2 B1-vs-B2 choice with the
content fact now on the table.

## 10. Decision stops (updated for Option B)

1. **History window** — how far back should Support logs reach? (Drives retention design.)
2. **Architecture** — B1 (activate the purpose-built `advisor_conversation_log`,
   recommended) vs B2 (fatten `proxy_requests`).
3. **Proceed confirmation** — acknowledge this is multi-phase, schema/proxy/RLS-gated work
   (not a quick UI pass) before P1 prompts are generated.

### Resolutions (2026-05-24)

- **History window:** 30 days.
- **Architecture:** B1 — activate the purpose-built `advisor_conversation_log`.
- **Tabs:** fold the 3 tabs into one list + a Type filter.
- **Proceed:** yes, as a phased, gated program. Each schema/proxy/RLS phase builds in a
  worktree and STOPs at PR; the orchestrator audits; the operator approves every merge.

---

## 11. Execution slices (decomposed, agent-led; worktree → PR → STOP)

Sized so no two in-flight slices edit the same file. P1 phases are gated
(schema/proxy/RLS → explicit operator approval at merge). P3/P4 are front-end (audited,
not merge-gated by category).

### P1a — Schema groundwork (GATED: schema + RLS) — DISPATCHED
- Files: new `db/migrations/<ts>_advisor_conversation_log_request_correlation_and_retention.sql`;
  cutoff bump in `scripts/postgres_staging_setup.ps1`; a `test/db/migrations/*` test.
- Change: add `request_id uuid` (nullable) correlation column to `advisor_conversation_log`
  + operator-leading join index `(operator_id, location_id, request_id)`; make retention
  REAL at 30 days via a scheduled purge (pg_cron, respecting `legal_hold`/`retention_class`);
  keep RLS wrappers + TIMESTAMPTZ; no `business_date` (UI buckets by time/date, not business
  day).
- Acceptance: migration applies; `migration_drift_scanner --fix --strict-docs`,
  `migration_cutoff_lint`, `index_leading_column_lint`, `rls_policy_lint` all pass; migration
  test green.
- Open question the agent must confirm: whether `advisor_conversation_log` already has a
  scheduled purge vs only a function; exact current column set.

### P1b — Proxy write wiring (GATED: proxy)
- Files: `tool/advisor_proxy/advisor_proxy.dart` (completion path) + proxy tests; reuse
  `AdvisorConversationLogRepository.recordTurn`.
- Change: on every LLM-request completion (advisor_qa, coach_qa, wf_pl, wf_schedule —
  CONFIRM coverage; extend if currently advisor-only), call `recordTurn` with operator/
  location/user_id, provider/model, prompt+completion tokens, **measured** latency, **real**
  result/status, usage_class, and the new `request_id` correlation. Measure wall-clock
  latency + capture real status in the handler. Idempotent (no double-write on replay); fold
  into the existing completion step — no extra DB round-trip.
- Acceptance: proxy tests prove the row + correlation + idempotency; no write on replay;
  cost discipline preserved (no new round-trip).

### P2 — Read projection + identity resolve (GATED: proxy)
- Files: `tool/advisor_proxy/proxy_bootstrap.dart` (debug request projection),
  `admin_route_group_part.dart`, `lib/admin/services/debug_console_admin_gateway.dart`,
  `lib/admin/models/debug_console_admin_models.dart`.
- Change: LEFT JOIN `advisor_conversation_log` on `(operator_id, location_id, request_id)`;
  return model, tokens in/out, **real** latency + status, actor uid; replace synthetic
  status/latency with real where present, honest null otherwise; resolve uid → name/role at
  render (reuse the members lookup, no PII stored).
- Acceptance: proxy route tests prove joined fields + honest nulls for non-LLM rows; gateway/
  model parse new keys; existing gateway/proxy tests updated.

### P3 — UX overhaul (front-end)
- Files: `lib/admin/screens/debug_console_admin_screen.dart` + its test;
  `lib/admin/admin_human_labels.dart` (add the 9 support-class labels + a display-only result
  helper); `tool/ux_em_dash_lint.dart` (add `admin_human_labels.dart` to `kUxCopyRoots` if
  copy moves there).
- Change: the §3 honest redesign now backed by real fields — plain rows, two-zone detail
  with a collapsible "Technical reference" (real model/tokens/latency for LLM rows, honest
  `—` for support rows), one compact filter row with the folded Type menu, live chip, plain
  copy, no monospace on human-facing parts, no `{ }` dump. Preserve keys where possible;
  convert tab tests to Type-filter tests (§5).
- Acceptance: screen tests green at 800x600 and 1440x1024 (no overflow); em-dash lint clean;
  `dart analyze` clean.

### P4 — Demo parity + browser QA + evidence
- Files: `lib/admin/services/debug_console_admin_gateway.dart` (demo fixtures match the real
  shape: some rows with telemetry, support rows without); browser QA per
  `runbooks/admin_console_browser_qa_runbook.md`; fill §6.
- Acceptance: kDemoMode renders the new design populated honestly; super_admin full-content
  gating + ff_support view-only verified; console clean.

---

## 12. REVISED architecture — STATS-ONLY (operator decision 2026-05-24)

Operator chose **stats-only (no AI message content)**. This supersedes the B1 "activate
`advisor_conversation_log`" WRITE path, because that table mandates encrypted content
(§9.8).

**Store:** a NEW dedicated, lightweight, operator-scoped per-request telemetry table
(working name `proxy_request_stats`) — stats-only, NO content. Columns:
`operator_id`, `location_id`, `request_id` (correlation to `proxy_requests.request_id`),
`usage_class`, `actor_user_id` (uuid ONLY — name/role resolved at render, never stored, per
`audit_attribution_contract.md`), `provider`, `model_id`, `prompt_token_count`,
`completion_token_count`, `cost_usd`, `latency_ms` (MEASURED), `result_status` (real:
success/error/timeout), `created_at` (TIMESTAMPTZ). RLS-ready (operator-leading index +
wrapper-function policy). 30-day retention via the P1a pg_cron purge pattern.

**Why a new table, not columns on `proxy_requests`:** extending `proxy_requests` to 30-day
retention would also retain its `response_payload` (full AI response content) for 30 days,
silently extending CONTENT retention and contradicting the stats-only choice. Keep
`proxy_requests` short-lived (content short-lived); put 30-day stats (no content) in the
dedicated table. **No FK** on `request_id` → `proxy_requests` (a 48h proxy prune would
cascade-delete the 30-day stats); plain column, documented.

**Why not relax `advisor_conversation_log`:** it drags KMS encryption + `audit_privacy` MFA
gating + conversation threading for rows that would carry no conversation. Wrong fit.

**P1a status:** the correlation column it added to `advisor_conversation_log` is now UNUSED
(we are not writing that table). Its 30-day retention fix there stays as valuable hygiene
(real "grows-forever-if-populated" gap). Small sunk cost from the content-requirement
discovery landing after P1a; no rollback needed.

**Full-content reveal:** unchanged — keeps using the EXISTING `proxy_requests.response_payload`
gating (super_admin + opt-in). Not entangled with the stats table.

**Re-decomposed P1:**
- P1a — DONE/landed (correlation unused; retention kept).
- **P1a' — DONE/landed** (#1285, `e97b533`): `proxy_request_stats` table + 30-day retention +
  shape test (28/28). Built by orchestrator after the agent hit transient server errors; two
  latent test/migration bugs caught + fixed during verification.
- **P1b — DONE/landed** (#1291, `6358dfe`): populates `proxy_request_stats` on every LLM
  completion — measured latency, actor uid, model/tokens/cost, `request_id` correlation;
  folded into the completion transaction (no extra round-trip); idempotent (replay never
  reaches the write); one shared path covers advisor_qa/coach_qa/wf_pl/wf_schedule. Writes
  `result_status='success'` only (see P1b.2). Audit: `docs/_audits/admin_support_logs_redesign/pr_1291_p1b_proxy_stats_writer.md`.
- **P1b.2 — QUEUED follow-up (gated proxy): failure/timeout telemetry.** Record a
  `proxy_request_stats` row with `result_status='error'`/`'timeout'` on the provider-failure
  and timeout bail paths (the 503/504 early-returns before `completeRequest`). Operator
  decision 2026-05-24: do this as a separate slice after P1b. Until then, failed LLM requests
  appear in Support logs via the base `proxy_requests` row (derived `unknown` status, no rich
  stats).
- **P2 — DONE/landed** (#1301, `85fe5a1`): read projection LEFT JOINs `proxy_request_stats`
  by `(operator_id, location_id, request_id)`; returns model/tokens/cost/actor-uid + real
  `latency_ms`/`result_status` via `coalesce(real, derived)`; honest nulls (never phantom 0)
  for non-LLM / failed / pre-P1b rows; `actor_user_id` uuid only (name/role resolved in P3).
  Audit: `docs/_audits/admin_support_logs_redesign/pr_1301_p2_read_projection.md`.
- P3 (UX), P4 (demo+QA): unchanged.
