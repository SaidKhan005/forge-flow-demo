# 01 - Engineering Rule And Ownership Map (Lane A)

Lane A is code health, not product. This document is the plain-English
engineering rule and the seam-by-seam ownership map. Every other doc in
this lane (`02_*`, `03_*`, `04_*`, `05_*`) is anchored here. Hierarchy
product rules belong to Lane B; cross-surface parity belongs to Lane C.

Authority order this lane respects (top wins on conflict):

1. The active prompt.
2. `docs/contracts/core_app_architecture.md` (Layers 1-12).
3. `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`
   (Block A / B / C, supersedes the original 8-decision lock where
   they conflict).
4. `docs/_decisions/post_codex_wave_decisions_2026-05-12.md`.
5. `docs/contracts/**` and `docs/frameworks/**`.
6. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`,
   `docs/POST_HARDENING_FOLLOWUPS.md`.
7. `CLAUDE.md`.

## Plain-English Engineering Rule

A code health pass is finished when:

- Every operator-facing affordance is wired end-to-end, or deleted.
  There is no "coming soon" surface in the production build that is
  not gated behind a permission key + plain-English disabled copy.
- Every silent failure path has a typed catch + one structured log
  line. `catch (_) {}` is a code-review block, not a forward debt.
- Every long-running async path runs inside `runZonedGuarded` (or
  inside an equivalent supervised seam).
- Every migration that mutates schema after a deploy ships in
  `db/migrations/post_deploy/`. Destructive migrations follow the
  expand-contract sequence GitLab documented. CI rejects any
  `UPDATE audit_logs` outside the explicit allowlist.
- Every fact-table B-tree index leads with `operator_id` (or
  `(operator_id, location_id)`); CI lint already enforces this.
  Bare `current_setting()` reads are forbidden in policies (wrappers
  only).
- Every proxy health producer reports real state; no placeholder
  green pills. The operator-visible proxy-health UI is the readiness
  surface, not `/health`.
- Every soak harness assertion is shared with the production
  observability metric. The same predicate that catches a regression
  in CI is the predicate that fires the production gauge.

Doctrine references that bind this rule (durable, see MEMORY.md):

- **Build Toward Production** - default to production end-state;
  no scaffold deferrals.
- **Metric Honesty** - every metric carries `state` + `provenance`;
  no phantom zeroes.
- **Audit First, Then Commit + PR + Merge** - audit local diff
  before push.
- **Orchestrator Fixes, Doesn't Send Back** - fixes happen inline
  with an authority-doc citation.

## What Lane A Does Not Decide

Lane A is code-shaped. It does not decide:

- Default Role catalog membership (Lane B / Wave B2).
- Vendor-applicability JSONB schema details (Lane B / addendum A6).
- Mobile to web handoff UX wording (Lane B / addendum A1).
- Per-operator product copy variants (Lane B / Lane C).
- AGE traversal phasing (Phase 11b / Phase 12 - paused).

When a Lane A slice surfaces a question that is product-shaped, the
finding lands in `02_plumbing_audit_matrix.md` with a
`cross-references Lane B/C` note and stops there.

## Ownership Map (which seam owns which decision)

The Lane A scope (A1-A11) maps to these owning files / directories.
Every execution slice references this map when listing
`Files touched`. Path roots are repo-relative.

### A1 - Proxy bug root-cause fixes

Status: **landed** on master via PR #476 (`fix(proxy):
runZonedGuarded + sign-in contract + soak harness (B1+B2)`,
commit `c3f1ce0d`, 2026-05-12). Follow-up `e26e53af`
aligned the client parser. Lane A retains this entry only as a
verification probe: confirm the change is on master, that the test
proves the contract, and that the production gauges are emitting.

Owning files (verify, do not re-implement):

- `tool/advisor_proxy/main.dart` (runZonedGuarded around `main()`).
- `tool/advisor_proxy/advisor_proxy.dart`
  (`requireOperatorContext` scope-less branch for `ff_support` /
  `super_admin`).
- `lib/services/auth/firebase_auth_login_service.dart` (client
  parser alignment).
- `lib/services/auth/proxy_auth_session_ledger_writer.dart` (echo
  contract).
- `tool/advisor_proxy/health_producers/` (pool + ring-buffer
  gauges).

### A2 - Scaffold removal mandate (addendum C4)

Owning seam: every dormant operator-facing affordance in
`lib/`, `lib/admin/`, `lib/operator_web/`, and the corresponding
proxy routes / templates.

First-pass inventory targets (filled out in 02):

- `lib/admin/widgets/deferred_admin_screen_placeholder.dart` +
  `lib/operator_web/widgets/deferred_screen_placeholder.dart`
  ("Arriving in your next update" widgets).
- `lib/widgets/metric_card_not_yet_available.dart`.
- `lib/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart`.
- Email template scaffolds locked in
  `lib/services/email/email_template_renderer.dart` (`EmailTemplateIds`)
  that have no enqueuer (see audit
  `docs/_audits/code_health/c_email_notification_scenario_inventory.md`,
  14 `Template-only` entries).
- `lib/infrastructure/kms/kms_stub_provider.dart` (still wired as a
  fallback per the rollout flag table - decision: keep with explicit
  flag, document as not-scaffold).

Wire-or-delete is per surface; the inventory is the deliverable.

### A3 - Monolith decoupling (`advisor_proxy.dart`)

Owning seam: `tool/advisor_proxy/advisor_proxy.dart` (**18,623
lines** as of this audit). 190 method+path branches; 143 themed
branches. Pre-split cleanup plan: `docs/phases/proxy_split/proxy_split_plan.md`.

Natural extraction seams (proposed - Lane A produces seam map, not
the extraction):

- Auth + session + MFA routes (already partly carved into
  `admin_email_routes.dart`, `notification_preferences_routes.dart`).
- Ledger + idempotency layer.
- Hierarchy + org-unit routes.
- Integrations + vendor lifecycle routes (already partly carved into
  `admin_integrations_routes.dart`, `integration_oauth_routes.dart`).
- Audit chain + anchors (already partly carved into
  `audit_chain_anchors_routes.dart`).
- Support workspace + debug-console routes.
- Health + readiness producers (already carved into
  `health_producers/`).
- Realtime + tripwire (already carved into `realtime_*.dart`).

### A4 - Performance audit

Owning seam: code that holds polling timers, periodic streams, and
cache state.

Found `Timer.periodic` sites (12 in `lib/`):

- `lib/screens/shift_dashboard.dart:361, 784, 951, 1329` (four).
- `lib/state/connectivity_notifier.dart:53`.
- `lib/admin/screens/audited_support_actions_admin_screen.dart:194`.
- `lib/admin/screens/debug_console_admin_screen.dart:493`.
- `lib/services/current_state_boundary_monitor.dart:186`.
- `lib/services/realtime/google_cloud_pubsub_subscriber.dart:250`.
- `lib/services/realtime/outbox_tripwire_poller.dart:94`.
- `lib/services/system_info_service.dart:78`.

Performance Framework lives at
`docs/frameworks/PERFORMANCE_FRAMEWORK.md` (Active, 2026-05-03).
Lane A measures + flags; UI behavior changes belong to Lane B / C.

### A5 - Schema versioning + expand-contract

Owning seam: `db/migrations/` and the lints in `tool/`.

State today:

- `db/migrations/post_deploy/` directory **does not exist**
  (addendum A7 requires it).
- 116 migration files in flat `db/migrations/`.
- `tool/migration_drift_scanner.dart` and
  `tool/migration_cutoff_lint.dart` exist; neither yet enforces a
  `--require-expand-contract` mode (R2 §2 recommendation).
- No `UPDATE audit_logs` allowlist lint yet.

### A6 - Proxy health UI

Owning seam: `lib/admin/screens/health_admin_screen.dart` (and any
operator-web equivalent if needed). Health producer registry:
`tool/advisor_proxy/health_producers/`.

Operator-visible affordance scope: a readable surface in the admin
console that shows producer state (`/health` envelope) with
plain-English remediation. Lane A's responsibility is to ensure the
producers are honest (no placeholder green) and that the screen
renders the same envelope `/health` returns.

### A7 - Frameworks consolidation

Owning seam: `docs/frameworks/`.

Today's contents:

- `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`.
- `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md`.
- `PERFORMANCE_FRAMEWORK.md`.
- `UX_ADJUSTMENT_FRAMEWORK.md`.
- `deployFramework.md`.
- `README.md`.

Cross-reference question: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
references the framework files with two paths
(`docs/frameworks/PERFORMANCE_FRAMEWORK.md` and
`docs/PERFORMANCE_FRAMEWORK.md`). Lane A picks one path and updates
references.

### A8 - Automation (CI gates + lints)

Owning seam: `tool/*_lint.dart` + `.github/workflows/`.

Existing lints:

- `tool/actions_pinning_lint.dart`.
- `tool/csp_header_lint.dart`.
- `tool/index_leading_column_lint.dart` (leading `operator_id`).
- `tool/migration_cutoff_lint.dart`.
- `tool/migration_drift_scanner.dart`.
- `tool/permission_key_lint.dart`.
- `tool/postgres_import_lint.dart`.
- `tool/release_build_demo_flag_lint.dart`.
- `tool/release_dart_defines_lint.dart`.
- `tool/rls_policy_lint.dart` + `rls_policy_lint_allowlist.txt`.
- `tool/vendor_completeness_lint.dart`.

Gaps (mandated by addendum A7):

- `UPDATE audit_logs` allowlist lint.
- `--require-expand-contract` flag on migration drift scanner.

### A9 - SQLite cleanup

Owning seam: `lib/data/` (frozen, delete-only per CLAUDE.md
service-layer split) and SQLite seeders.

State today:

- `lib/data/` has 3 files (1,421 LOC total): `app_defaults.dart`
  (still actively imported by `lib/widgets/lever_card.dart:3` and
  `lib/widgets/week_history_tile.dart:7`),
  `cross_axis_pair_catalog.dart`, and `mock_integration_replay_seed.dart`.
- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart`
  holds the demo seeding (HP #2 - demo persists post-launch).

Lane A's call: `app_defaults.dart` is not deletable as-is - it is
still feature plumbing. Action: rename / re-home if Lane A surfaces
a cleaner address (e.g., `lib/domain/constants/`), or document the
exception in `CLAUDE.md`. The rest of `lib/data/` is genuinely
delete-only when no consumer remains.

### A10 - Test consolidation

Owning seam: `test/`.

State today:

- 666 `*_test.dart` files; 710 total `*.dart` under `test/`.
- 1 entry in `docs/KNOWN_FAILING_TESTS.md`
  (`test/settings_permission_explainer_test.dart`, 2026-05-06).
- 27 sub-directories under `test/` (admin, auth, proxy, screens,
  services, etc.).
- Pressure / soak split between `test/load/pressure/` (p3* runners)
  and `test/pressure/` (p4 predicate test).

Lane A's call: consolidate the two pressure-test homes, audit the
helper-duplication risk (each big sub-tree tends to grow its own
fixture builders), and prune `KNOWN_FAILING_TESTS.md` to zero or
mark each entry with a current-wave decision.

### A11 - Soak harness durable kit

Status: **B2 quick-win already landed** on master via the same PR
that landed B1 (`c3f1ce0d`). The shipped harness:

- `tool/pressure/p4_session_soak.dart`.
- `tool/pressure/p4_operator_day_soak.dart`.
- `tool/pressure/p4_session_record_predicate.dart` (shared
  predicate).
- `test/pressure/p4_session_record_predicate_test.dart`.

Lane A's remaining work:

- Promote the predicate to a production gauge (R3 §2 stretch -
  proxy emits `proxy.session_record.incomplete{route, missing_field}`).
- Wire fd watcher (R3 §3 quick-win, deferred from B2).
- Wire heap-snapshot-to-GCS trigger (R3 §3 durable, ~2 days).
- Extend pressure storm with TTL distribution / vendor mix / jitter
  sweeps (R3 §4 quick-win, ~1.5 days).

## Hand-off Posture

This lane lands planning files first. Execution slices follow per
`03_execution_slices.md`. The orchestrator commits + opens the PR
bundle; agents implement individual slices and stop at PR per
`CLAUDE.md` "Agent-Led Slices".
