# 02 - Plumbing Audit Matrix (Lane A)

Lens-audit pass per
`docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`
across the A1-A11 scope. Each finding cites `file:line`. Findings
are clustered by lens, not by sub-lane, so consumers can map findings
back to slices in `03_execution_slices.md`.

All paths repo-relative under
`C:\Git Local Repos\forge_flow_demo\.claude\worktrees\nifty-clarke-d3ec25\`.
Line numbers verified at audit time.

## Coverage Summary

| Sub-lane | Lenses primarily hit |
|---|---|
| A1 proxy bug fix | 4 (repo), 5 (proxy), 6 (auth), 12 (tests), 13 (observability) |
| A2 scaffold removal | 1 (product), 7 (lifecycle), 9 (UI state), 14 (docs) |
| A3 monolith decoupling | 4 (repo), 5 (proxy), 8 (deploy), 13 (observability) |
| A4 performance | 10 (performance) primarily |
| A5 schema versioning | 3 (data model), 8 (deploy) |
| A6 proxy health UI | 8 (deploy), 9 (UI), 13 (observability) |
| A7 frameworks consolidation | 14 (docs) primarily |
| A8 automation | 3 (data), 5 (proxy), 8 (deploy), 12 (tests) |
| A9 SQLite cleanup | 3 (data) primarily |
| A10 test consolidation | 12 (tests) primarily |
| A11 soak harness | 10 (perf), 12 (tests), 13 (observability) |

## Findings By Lens

### Lens 1 - Product And User Journey

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 1 | `lib/admin/widgets/deferred_admin_screen_placeholder.dart:16-89` | "Arriving in your next update" widget exists, but `Grep` finds zero callers in `lib/admin/admin_routes.dart` or any admin screen. Either a dead-code drop site or pre-wired-for-deletion-of-routes. | A2 - confirm dead-code status; if dead, delete in same slice as the operator-web sibling at `lib/operator_web/widgets/deferred_screen_placeholder.dart`. |
| 1 | `lib/operator_web/widgets/deferred_screen_placeholder.dart:16-90` | Operator-web sibling of the above; same status (no callers grepped). Comment says "deferred 11W routes (Members, Roles, Hierarchy, Sessions, Audit, Security)" but the per-slice closures landed already. | A2 - delete with the admin sibling. |
| 1 | `lib/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart` | Barrio surface; Barrio is paused per `project_barrio_paused.md`. | A2 - leave alone (paused surface), but flag as "intentionally dormant pending Barrio unpause" in the inventory. Cross-references Lane B (no current owner). |
| 1 | `lib/widgets/metric_card_not_yet_available.dart` | Card surface used by metric pills to show "not yet available" honestly. | A2 - this is **honest scaffolding** (operator-facing surface that communicates true state per Metric Honesty Doctrine). Keep, document as not-scaffold in the inventory. |

### Lens 2 - Information Architecture And Navigation

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 2 | `tool/advisor_proxy/advisor_proxy.dart` 18,623 lines, 190 method+path branches | Single-file router has no formal section markers separating auth / hierarchy / integrations / audit / support clusters. Future split (per `docs/phases/proxy_split/proxy_split_plan.md`) needs the seam map. | A3 - produce a seam map (one-time audit doc) listing line ranges per logical cluster. Do not split in this lane; the proxy-split phase owns the move. |
| 2 | `docs/CODEX_PROMPT_GENERATION_STANDARD.md:33-38` | References both `docs/frameworks/PERFORMANCE_FRAMEWORK.md` AND `docs/PERFORMANCE_FRAMEWORK.md` (and likewise for UX, mobile-web frameworks). Only `docs/frameworks/` has the file. | A7 - delete the stale `docs/PERFORMANCE_FRAMEWORK.md` references; pick the `docs/frameworks/` path as canonical. |

### Lens 3 - Data Model, Migration, And RLS

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 3 | `db/migrations/` (116 files, flat) | No `post_deploy/` sub-directory exists; addendum A7 mandates it. | A5 - create `db/migrations/post_deploy/` directory + a README + the convention (which migrations belong there vs `db/migrations/`). |
| 3 | `tool/migration_drift_scanner.dart` (full file) | Drift scanner covers structural drift only - does not enforce `--require-expand-contract` per R2 §2. | A5 - add flag + docs + CI integration. |
| 3 | `tool/migration_cutoff_lint.dart:1-50` | Cutoff lint exists, but no `UPDATE audit_logs` allowlist lint exists anywhere. Addendum A7 mandates this for hash-chain integrity. | A8 - add new lint or extend existing; allowlist file at `tool/audit_logs_update_allowlist.txt`. |
| 3 | `lib/data/app_defaults.dart` (555 lines), `lib/data/cross_axis_pair_catalog.dart` (212 lines), `lib/data/mock_integration_replay_seed.dart` (654 lines) | `CLAUDE.md` says `lib/data/` is "frozen legacy, delete-only", but `lib/widgets/lever_card.dart:3` and `lib/widgets/week_history_tile.dart:7` still import `app_defaults.dart`. Contract drift. | A9 - either (a) rehome the live constants to `lib/domain/constants/` and delete `lib/data/`, or (b) document the carve-out in `CLAUDE.md`. Decision: pick (a) for clarity. |
| 3 | `db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql` (filename only confirmed; not opened) | Addendum A3 also calls for an `ltree` column + descendant-set cache on `org_units` / `locations`. Verify if landed. | A5 (informational) - audit a representative migration; if no `ltree` yet, flag for Lane B / C decision (cross-references Lane B - hierarchy product owners). |

### Lens 4 - Repository And Service Layer

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 4 | `tool/advisor_proxy/advisor_proxy.dart` (file size) | 18,623 lines. `docs/phases/proxy_split/proxy_split_plan.md` line `8-9` records it was 16,949 at 2026-05-08 (+2,449 since 2026-05-06). Repo measurement at 2026-05-12: 18,623 lines (+1,674 in 4 days). Growth is real. | A3 - the seam map exists; the next step is to *stop the bleed* (new routes go to new files, not into the monolith). Add a CI lint that fails if `advisor_proxy.dart` grows past N lines until the split lands. |
| 4 | `lib/services/email/email_template_renderer.dart:84-170` | `EmailTemplateIds.all` lists 12 IDs. The audit inventory at `docs/_audits/code_health/c_email_notification_scenario_inventory.md` records **14 "Template-only" scenarios** with no enqueuer. | A2 - wire OR delete the 14 template-only scenarios. Each template gets a per-scenario decision per addendum C3 + C4. |

### Lens 5 - Proxy, Route, And Gateway Contracts

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 5 | `tool/advisor_proxy/main.dart` (post-`c3f1ce0d`) | `runZonedGuarded` is now wrapping `main()` (B1 landed). Verify the wrap is still present and emits `proxy.root_zone_uncaught`. | A1 - verification probe only; spot-check after rebase. |
| 5 | `tool/advisor_proxy/advisor_proxy.dart` `requireOperatorContext` | Sign-in contract was aligned (B1). Test coverage in `test/advisor_proxy_test.dart` per commit message. | A1 - verification probe only. |
| 5 | `lib/services/auth/firebase_auth_login_service.dart` (B1 follow-up `e26e53af`) | Client parser aligned with proxy. | A1 - verification probe only. |
| 5 | 12 `Timer.periodic` sites (see A4 list) | Each polling site is a long-running async path. Confirm each is inside the supervised seam or a guarded zone. | A4 - audit each timer; ensure cancel-on-dispose + a typed catch around the body. The two realtime ones (`google_cloud_pubsub_subscriber.dart:250`, `outbox_tripwire_poller.dart:94`) are server-side; guarded zones via `runZonedGuarded` cover them transitively. The 10 client-side ones live in widget lifecycle; confirm `dispose` cancels. |

### Lens 6 - Auth, Roles, Permissions, And Scope

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 6 | `lib/auth/permission_keys.dart` | Frozen key catalog (per CLAUDE.md). Has `// TODO` markers (2 grep hits) - confirm none are gating production behavior. | A2 - spot check; if TODO is product-shaped, cross-reference Lane B. |
| 6 | `lib/services/auth/proxy_admin_permission_guard.dart` (3 TODO hits) | Admin permission guard with TODO markers. | A2 - inventory the TODOs; resolve or document. |

### Lens 7 - Lifecycle And Destructive Actions

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 7 | `lib/admin/widgets/deferred_admin_screen_placeholder.dart` + `lib/operator_web/widgets/deferred_screen_placeholder.dart` | "Arriving in your next update" is a soft lie if the slice has landed. Delete these widgets (the routes that needed them now have real screens). | A2 - delete in the scaffold-removal slice. |
| 7 | `lib/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart` | Barrio is paused; the screen is honestly named. | A2 - leave alone; document. |

### Lens 8 - Background Workers, Deploy, Startup, And Health

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 8 | `tool/advisor_proxy/health_producers/` (11 files) | Producer registry exists; `health_producer.dart` is the contract. Pool gauges + ring-buffer gauges landed in `c3f1ce0d`. | A6 - verify producers emit honest state; ensure operator-visible UI (`lib/admin/screens/health_admin_screen.dart`) renders the producer envelope, not a hard-coded green pill. |
| 8 | `db/migrations/post_deploy/` | Missing. Addendum A7. | A5 - same finding as Lens 3; first slice creates the directory + convention. |
| 8 | `tool/advisor_proxy/main.dart` startup path | Already wrapped in `runZonedGuarded` post-`c3f1ce0d`. Confirm health vs readiness split (`/health` deep, `/readyz` shallow) at the lens-3 level. | A6 - inspect `advisor_proxy.dart:8653-8659` to verify `healthPath` and `readinessPath` are different routes. |

### Lens 9 - UI State, UX, And Accessibility

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 9 | `lib/admin/screens/health_admin_screen.dart` | Admin health screen exists. Confirm it renders all producer states with plain-English remediation copy. | A6 - audit screen text; ensure no producer state is hidden behind a green pill when actual state is yellow/red. |

### Lens 10 - Performance And Data Loading

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 10 | `lib/screens/shift_dashboard.dart` 4 `Timer.periodic` sites at `:361, :784, :951, :1329` | Four periodic timers on a single screen. Confirm distinct purposes (data refresh, ticker chip, etc.) and confirm none duplicates work. | A4 - inspect; if duplication exists, coalesce. PERFORMANCE_FRAMEWORK before/after measurement required. |
| 10 | `lib/services/realtime/google_cloud_pubsub_subscriber.dart:250` Timer.periodic | Pulls at `_pullInterval` cadence. Audit context already covered in `a1_proxy_bug_root_cause.md` §S3 (ring buffer growth). Production gauge `pubsub_subscriber.ring_buffer_keys` shipped in B1. | A11 - verify the gauge is wired to the operator-visible health producer. |
| 10 | `lib/services/realtime/outbox_tripwire_poller.dart:94` Timer.periodic | Outbox tripwire polling - server-side worker. | A11 - already supervised by `runZonedGuarded` in `main()`. No action. |
| 10 | `lib/state/connectivity_notifier.dart:53` Timer.periodic | Client-side connectivity probe. | A4 - confirm cancel on dispose; if not, fix in one inline pass. |
| 10 | `tool/pressure/p3*.dart` and `p4_*.dart` | Pressure / soak harnesses landed. R3 §3 quick-win subset shipped in B2. `fd_watcher` and `heap_snapshot_to_GCS` deferred. | A11 - durable extension slice picks up the deferred items. |

### Lens 11 - Mobile, Operator Web, Admin, And API Parity

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 11 | Per-vendor `*_postgres_sink.dart` files (`tock_reservation_postgres_sink.dart`, `sevenrooms_reservation_postgres_sink.dart`, `opentable_reservation_postgres_sink.dart`, `libro_postgres_sink.dart`) | These are vendor-specific writer plumbing - not parity defects, but they show up in the placeholder-grep. Filter from the inventory. | A2 - excluded (Phase 8 vendor work, not scaffold). |

### Lens 12 - Tests, Builds, Browser Use, And Evidence

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 12 | `test/` 666 `*_test.dart` files; 27 sub-directories; `_helpers/` has only 1 helper file (`migration_lf.dart`) | Test helpers are scattered across sub-directories (`test/admin/_helpers`, `test/operator_web/_helpers`, etc., per typical pattern). | A10 - inventory the helper duplication; if 2+ subdirs ship the same fake/mock, consolidate. |
| 12 | `test/load/pressure/` (p3*) and `test/pressure/` (p4 predicate test) | Pressure tests split across two directories. | A10 - consolidate under `test/pressure/`. |
| 12 | `docs/KNOWN_FAILING_TESTS.md` (17 lines, 1 open entry at line 17) | 1 entry: `test/settings_permission_explainer_test.dart` from 2026-05-06; copy-vs-resolution drift. | A10 - either fix the test in the consolidation slice OR fold into Lane B (it is product-copy-shaped: cross-references Lane B). |

### Lens 13 - Observability, Audit, And Supportability

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 13 | `tool/advisor_proxy/advisor_proxy.dart` 16 bare `catch (_)` sites enumerated at `docs/phases/proxy_split/proxy_split_plan.md` (lines 1319, 1352, 1429, 1661, 1698, 1789, 1944, 1974, 1980, 1997, 2306, 2540, 2618, 5143, 5221, 5274 as of 2026-05-08; line numbers drift) | B1 hot-fix typed two of these. 14 sites remain. | A3 + A8 - drive the remainder to zero in chunks of 4-6, each in its own slice (line-drift risk). Same pattern as PR #420. |
| 13 | `tool/advisor_proxy/health_producers/health_producer.dart` (file existence confirmed) | Producer contract exists. | A6 - confirm every producer reports `state` + `provenance` per Metric Honesty Doctrine. |
| 13 | R3 §2 production gauge recommendation - `proxy.session_record.incomplete{route, missing_field}` | Predicate landed at `tool/pressure/p4_session_record_predicate.dart`; production gauge not yet wired per `c3f1ce0d` commit message ("Smoke runs ... to be executed during PR audit"). | A11 - wire predicate to a production gauge emitted from the proxy response handler. |

### Lens 14 - Docs, Tracker, And Prompt Hygiene

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|
| 14 | `docs/frameworks/README.md` | Index doc exists; confirm cross-references match. | A7 - audit and update. |
| 14 | `docs/CODEX_PROMPT_GENERATION_STANDARD.md:33-38` | Lists framework paths with `docs/frameworks/` AND `docs/PERFORMANCE_FRAMEWORK.md` (stale top-level reference). | A7 - de-duplicate path references; pick canonical `docs/frameworks/`. |
| 14 | `docs/phases/proxy_split/proxy_split_plan.md` (62 lines, "stub") | Plan exists at stub level only. As the monolith grows the cost of formal split increases. | A3 - this lane does not own the formal split; it owns the seam-map deliverable that the split phase will consume. |
| 14 | `docs/KNOWN_FAILING_TESTS.md:17` | 1 open entry, 1 week old. | A10 - close or accept; document decision in `06_closure_evidence_*.md` later. |

## Cross-Lane Flags (out of Lane A scope)

These findings surfaced during this audit but belong to other lanes.
Listed here so they do not get lost.

| Topic | Cross-references |
|---|---|
| Default Role catalog publish/sync (R2 Topic 6, Pull pattern) | Lane B - feature-design owners. Lane A does not author the pull-versioned catalog table or the pinning UI. |
| Permission dependency cascade (R2 Topic 7, Path A) | Lane B - belongs to the role editor surface. |
| `ltree` adoption on `org_units` / `locations` (addendum A3) | Lane B - hierarchy product owner. Lane A flags the missing-column condition only. |
| Vendor-applicability table (R2 Topic 5, one-table-discriminator) | Lane B - feature-design owners. |
| Redemption-code handoff with RFC 9470 (R2 Topic 3, addendum A1) | Lane B - auth surface design + the handoff UX. Lane A's proxy-side endpoint scope is a downstream slice. |
| `settings_permission_explainer_test.dart` failure | Lane B - copy/resolution drift sits in a screen owned by the settings hierarchy product. |

## Contract Gap (flagged, not amended)

`CLAUDE.md` service-layer split says `lib/data/` is **frozen, delete-only**.
Two production widgets still import `lib/data/app_defaults.dart`
(`lib/widgets/lever_card.dart:3`, `lib/widgets/week_history_tile.dart:7`).
The codebase drifted from the contract.

Lane A's posture: flag here, address in slice **A9-rehome**
(`03_execution_slices.md`). The contract amendment, if any is needed,
is operator-owned - do not amend `CLAUDE.md` from this lane.

## Audit Note

| Field | Value |
|---|---|
| Feature | Lane A code-health audit |
| Branch/worktree | `claude/nifty-clarke-d3ec25` |
| Source commit | inspected at 2026-05-12 |
| Lenses checked | 1-14 |
| Tests/builds | `dart analyze` and slice-scoped tests are deferred to per-slice execution. |
| Browser Use | N/A (no UI mutations in planning). |
| Performance JSON | N/A (planning only). |
| Residual risks | (1) `advisor_proxy.dart` still growing; (2) production session-record gauge not yet wired; (3) 14 bare catches remaining; (4) 14 template-only email scenarios. |
| Decision stops | None. Operator can dispatch slice prompts from `03_execution_slices.md` directly. |
