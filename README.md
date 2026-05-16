# Forge & Flow

Restaurant operations system that compares the locked plan against live service,
explains the gap, and teaches the operator what to do next. Built as a Flutter
client + Dart Cloud Run proxy + Postgres (CMK-encrypted) system of record, with
per-vendor adapters feeding canonical operational facts.

The product pipeline:

```
POS + Labor + Reservation
  -> Canonical Operational Facts (ShiftRecord / OpenShiftSnapshot / ReservationBookSnapshot)
  -> 60-Day Benchmark Snapshot
  -> TargetCycle (locks for 60 days) + DemandForecastContext
  -> SchedulePlan -> WeeklyPlanSnapshot (locks for one business week)
  -> Shift (live) -> Variance -> History -> Learn
```

Source: `docs/contracts/core_app_architecture.md` (Tier-2 contract; Layers 1-12
of Phase 7.55 are canonical).

---

## Surfaces (what runs where)

Forge & Flow ships **four** runtime surfaces, three of them web. Each compiles
from its own Dart entrypoint and ships as its own Cloud Run service:

| Surface | Entrypoint | Hostname (production) | Cloud Run service (staging) | Used by |
|---|---|---|---|---|
| Operator mobile app (ForgeFlow flavor) | [lib/main_forgeflow.dart](lib/main_forgeflow.dart) | (mobile app stores) | n/a | Operators on phone / tablet |
| Operator mobile app (Barrio flavor) | [lib/main_barrio.dart](lib/main_barrio.dart) | (paused) | n/a | Barrio private build (frozen — see `memory/project_barrio_paused.md`) |
| Operator Web Console | [lib/main_operator_web.dart](lib/main_operator_web.dart) | `app.forgeflow.app` | `forge-flow-operator-web` | Operator onboarding + own-operator web |
| F&F Operations Console (admin) | [lib/main_admin.dart](lib/main_admin.dart) | `admin.forgeflow.app` | `forge-flow-admin-console` | F&F super-admin + support (cross-operator) |
| Advisor proxy / backend | [lib/main.dart](lib/main.dart) (proxy entry) | `proxy.forgeflow.app` | `forge-flow-staging-proxy` | All clients (auth-gated REST) |

Two-console framing detail: `memory/project_two_console_framing.md`.

### Main product surfaces (inside the operator app)

- **This Week** — what matters first, right now.
- **Shift** — operational, in-shift teaching surface.
- **Schedule** — labor planning vs. forecast.
- **History** — recurring patterns across closed weeks.
- **Learn** — coaching focus drawn from closed evidence.
- **Baseline** — benchmark/star-shift selection and target-cycle context.

---

## Architecture (high level)

- **Flutter client** (mobile + web) speaks only to the proxy. Vendor payload
  shape never reaches the UI; canonical facts do.
- **Local SQLite** caches read models and demo-mode data. Same tables in demo
  and production; demo is a writer-side switch (Hard Promise #2 — see
  `docs/contracts/demo_mode_contract.md`).
- **Dart proxy on Cloud Run** brokers all auth, all writes (idempotent, keyed
  in `proxy_requests`), all LLM / embedding calls (no BYO-key), and all
  per-vendor integration adapters.
- **Azure Database for PostgreSQL Flexible Server** (Canada Central, PG 16,
  CMK-encrypted) is the operator-scoped system of record. Extensions: Apache
  AGE, pgvector, pg_diskann, pg_cron, pg_partman, pg_stat_statements,
  pgcrypto. `TIMESTAMPTZ` everywhere + denormalized `business_date`.
  `pgmq` is **not** available — use `FOR UPDATE SKIP LOCKED` or Cloud Tasks.
- **Firebase Auth** is identity. Custom claims (`is_super_admin`,
  `is_ff_support`) gate the admin console; operator hierarchy / per-location
  RLS gates everything else.
- **Per-operator RLS-ready schema** from day one. App code uses
  `OperatorScopedRepository<T>` (primary defense); Postgres RLS is backup.
  Every fact-table B-tree index leads with `operator_id`.
- **AI infra is general-purpose** — `LLMProvider`, `EmbeddingProvider`,
  `RerankProvider`, `DataSourceProvider`, `IntegrationProvider`. Advisor
  (Phase 11b) and future Workflow Platform (Phase 12) reuse the same plumbing.

Deeper guides:

- [docs/contracts/core_app_architecture.md](docs/contracts/core_app_architecture.md) — canonical Layer 1-12 contract.
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — plain-English + technical walkthrough.
- [docs/contracts/integration_spine_architecture_contract.md](docs/contracts/integration_spine_architecture_contract.md) — vendor adapter spine.
- [docs/contracts/hardening_rls_and_repository_pattern_contract.md](docs/contracts/hardening_rls_and_repository_pattern_contract.md) — RLS + repository discipline.
- [docs/contracts/phase_7_55_time_boundary_contract.md](docs/contracts/phase_7_55_time_boundary_contract.md) — timestamp + business-date rules.

---

## Environments

Forge & Flow has three runtime tiers. Each is fully isolated at the Cloud Run
service, Secret Manager namespace, and (for production) the database level.

| Tier | GCP project | Postgres | Secret Manager prefix | Purpose |
|---|---|---|---|---|
| **Preview** | `forge-flow-staging` | shared staging (default) or isolated preview DB | `forge-flow-staging-` (default) or `forge-flow-preview-` | Per-branch / per-PR end-to-end proof before shared staging |
| **Staging** | `forge-flow-staging` | shared staging Postgres | `forge-flow-staging-` | Release-candidate validation; shared across team |
| **Production1** | `forge-flow-production1` | `forge-flow-production1-pg-cmk` (CMK + UAMI) | `forge-flow-production-` | Live operator traffic, gated by `cutover.*` runbooks |

Region for everything: `northamerica-northeast2` (Toronto).

Preview is the safety net: it uses separate Cloud Run service names derived
from `-PreviewName`, so shared staging users are never routed onto branch
revisions. Detail: [runbooks/preview_environment_runbook.md](runbooks/preview_environment_runbook.md).

---

## Local development

### Prerequisites

- Flutter stable (Dart 3.x). `flutter doctor` clean.
- For Cloud Run / proxy work: `gcloud` CLI, Google Cloud SDK,
  `Cloud SDK` installed at `%LOCALAPPDATA%\Google\Cloud SDK`.
- For local Postgres dev: Docker Desktop (optional — `docker-compose.dev.yml`
  spins up PG 16 + AGE + pgvector at `localhost:5432`).
- A unified, **non-repo** secrets file at
  `$HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1`. The dev
  launchers source this; no provider keys live in the repo.

### Surfaces — 4-mode runner

All four runtime surfaces (operator mobile / Barrio mobile / Operator Web /
F&F Operations Console) share the same `-Mode demo|preview|staging|production`
contract via their PowerShell dev launchers. Demo bypasses the proxy entirely
(HP #2 writer-side switch); preview and staging hit Cloud Run; production is
fail-closed behind `-IUnderstand`.

| Mode | Auth source | Proxy target | Use case |
|---|---|---|---|
| `demo` | Fixture sign-in / `kDemoMode` writer | None (SQLite-only) | Local walkthroughs, recorded demos, the V1 plug-and-play onboarding storyboard. |
| `preview` | Live Firebase Auth | `forge-flow-preview-<slug>-proxy` on `forge-flow-staging` (resolved via `gcloud run services describe` when `-PreviewName <slug>` is set) | Per-branch / per-PR end-to-end proof before shared staging. |
| `staging` | Live Firebase Auth | Shared staging proxy (`forge-flow-staging-proxy-*-nn.a.run.app`) | Release-candidate validation; shared across the team. |
| `production` | Live Firebase Auth | `https://proxy.forgeflow.app` | Local dev session pointing at production. **Fail-closed behind `-IUnderstand`** — the launcher exits 1 with `BLOCKED: -Mode production targets…` until the operator opts in. |

HP #2: demo and prod read from the same code path; only the writer changes.
Adding a new `kDemoMode` reader branch or a parallel `demo_*` table is a
contract violation (`docs/contracts/demo_mode_contract.md`).

#### Surface × Mode matrix

Copy-paste commands per surface × mode. Long Cloud Run URLs are abbreviated
after the staging column; substitute the real `forge-flow-staging-proxy-*-nn.a.run.app`
host returned by `scripts\deploy_staging_proxy.ps1`.

| Surface | demo | preview | staging | production |
|---|---|---|---|---|
| [Operator Web Console](lib/main_operator_web.dart) | `scripts\run_operator_web_dev.ps1 -Mode demo` | `scripts\run_operator_web_dev.ps1 -Mode preview -PreviewName ux-nav` | `scripts\run_operator_web_dev.ps1 -Mode staging -ProxyBaseUri https://forge-flow-staging-proxy-XXXX-nn.a.run.app` | `scripts\run_operator_web_dev.ps1 -Mode production -IUnderstand` |
| [F&F Operations Console (admin)](lib/main_admin.dart) | `scripts\run_admin_console_dev.ps1 -Mode demo` | `scripts\run_admin_console_dev.ps1 -Mode preview -PreviewName ux-nav` | `scripts\run_admin_console_dev.ps1 -Mode staging -AdminProxyBaseUri https://…XXXX-nn.a.run.app` | `scripts\run_admin_console_dev.ps1 -Mode production -IUnderstand` |
| [Forge & Flow mobile](lib/main_forgeflow.dart) | `scripts\run_flutter_dev.ps1 -App forgeflow -Mode demo` | `scripts\run_flutter_dev.ps1 -App forgeflow -Mode preview -PreviewName ux-nav` | `scripts\run_flutter_dev.ps1 -App forgeflow -Mode staging -ProxyBaseUri https://…XXXX-nn.a.run.app` | `scripts\run_flutter_dev.ps1 -App forgeflow -Mode production -IUnderstand` |
| [Barrio mobile (paused)](lib/main_barrio.dart) | `scripts\run_flutter_dev.ps1 -App barrio -Mode demo` | `scripts\run_flutter_dev.ps1 -App barrio -Mode preview -PreviewName ux-nav` | `scripts\run_flutter_dev.ps1 -App barrio -Mode staging -ProxyBaseUri https://…XXXX-nn.a.run.app` | `scripts\run_flutter_dev.ps1 -App barrio -Mode production -IUnderstand` |

#### Per-surface notes

**Operator Web Console** (`lib/main_operator_web.dart`)

- Default web-server port `8181` (`-WebPort 8181`). Pair with the admin
  console on `8182` to run both locally without conflict.
- `scripts\run_operator_web_dev.ps1` performs the dev-CSP swap on
  `web/index.html` automatically (production CSP backed up to
  `web/index.prod.html.bak`, restored on exit). Reviewer-judgment detail:
  `scripts/apply_operator_web_dev_csp.sh`.
- Legacy `-LiveAuth` switch still works (maps to `-Mode staging`); same
  back-compat pattern the mobile launcher uses for `-UseFirebaseAuth`.

**F&F Operations Console** (`lib/main_admin.dart`)

- Defaults to `-Device chrome`. Pass `-Device edge` or `-Device web-server`
  for headless / port-scoped runs.
- Demo-mode fixtures: `super.admin@` / `support@` / `operator@` (Phase 11A.0
  walkthrough).
- `.claude/launch.json` integrates with the Claude_Preview MCP tool — invoke
  the matching launch entry to attach the in-IDE preview panel.

**Forge & Flow mobile** (`lib/main_forgeflow.dart`)

- Pass `-Device chrome` for an in-browser smoke or `-d <device-id>` to target
  a specific connected handset (`flutter devices` lists IDs). Verify with
  `flutter doctor` if devices fail to enumerate.
- Flavor must match the app (`--flavor forgeflow` for ForgeFlow,
  `--flavor barrio` for Barrio); the launcher sets this automatically.
- Demo mode on mobile emits both `--dart-define=kDemoMode=true` and
  `--dart-define=FORGE_FLOW_DEMO_MODE=true` — the writer-side switch and the
  flag name `lib/screens/auth/login_screen.dart` reads to surface the
  additive "Use demo operator" button.

**Barrio mobile** (`lib/main_barrio.dart`)

- **Paused.** See `CLAUDE.md` → "Paused" and `memory/project_barrio_paused.md`.
  The launcher prints a warning but still runs so dev can inspect the build.
  Do not target Barrio for merges unless the tracker explicitly says otherwise.

Plain Flutter without the launchers (mobile only):

```bash
flutter pub get
flutter run --flavor forgeflow -t lib/main_forgeflow.dart
flutter run --flavor barrio    -t lib/main_barrio.dart
flutter test
```

### Local Postgres (full stack)

For full-stack local demo / happy-state validation against a Postgres
that satisfies every wave-scope migration (AGE + pgvector + pg_partman +
pg_cron + pg_stat_statements + pg_diskann stub), follow:

→ [`runbooks/local_full_stack_setup_runbook.md`](runbooks/local_full_stack_setup_runbook.md)

The runbook covers the Docker bootstrap, all 125 migrations, the W-1 +
W-2 wave-bug workarounds, and connection wiring for the proxy + Flutter
operator-web + mobile flavors.

Current local state once bootstrapped:

```
Port:       localhost:5433
Database:   forge_flow
Superuser:  postgres / forge_flow_local
POSTGRES_URL=postgresql://postgres:forge_flow_local@localhost:5433/forge_flow
```

Legacy `docker-compose.dev.yml` (Phase 11a.11c.5 scaffold) predates
the wave's extension list and only ships AGE + pgvector; the runbook
supersedes it.

After editing migrations:

```bash
dart run tool/migration_drift_scanner.dart --fix --strict-docs
dart run tool/migration_cutoff_lint.dart
```

### Mobile build outputs

| Metric | Typical size |
|---|---|
| Local workspace (`build/` + `.dart_tool/`) | ~4-5 GB |
| Debug APK | ~150-160 MB |
| Release split APK (per ABI) | ~20-25 MB |

```bash
flutter build apk       --flavor forgeflow -t lib/main_forgeflow.dart --release
flutter build appbundle --flavor forgeflow -t lib/main_forgeflow.dart --release
flutter clean   # reclaim ~5 GB of build cache
```

APK output: `build/app/outputs/flutter-apk/`.

---

## Deploys

All deploy scripts are PowerShell. They source the same unified secrets file
the dev launchers use, sync Secret Manager, build the container via Cloud
Build, deploy to Cloud Run, then verify Ready revision + `/readyz` + CORS
preflight + Browser Use smoke (when applicable).

Authority on which target a script defaults to: read the script header — every
script defaults to staging and requires explicit `-Project` / `-SecretPrefix`
flags to target Production1.

### Preview (per branch / per PR)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\deploy_preview_stack.ps1 `
  -PreviewName ux-nav `
  -SkipApiEnable `
  -SkipSecretManagerSync
```

Creates `forge-flow-preview-ux-nav-admin` and `forge-flow-preview-ux-nav-proxy`
on `forge-flow-staging`. Uses `-MinInstances 0` (cheap when idle). Default
secret prefix is `forge-flow-staging-` (runtime-isolated; shared staging DB —
safe for read-only smoke only). Pass `-SecretPrefix forge-flow-preview-` for
a fully data-isolated preview after preview secrets are provisioned.

For saturated-DB previews, add `-DeferProxyStartupDatabase -ProxyMaxInstances 1`
so the proxy binds HTTP and passes `/readyz` without opening startup-only
Postgres connections. Detail: [runbooks/preview_environment_runbook.md](runbooks/preview_environment_runbook.md).

Cleanup when the PR closes:

```powershell
gcloud run services delete forge-flow-preview-ux-nav-admin `
  --project forge-flow-staging --region northamerica-northeast2
gcloud run services delete forge-flow-preview-ux-nav-proxy `
  --project forge-flow-staging --region northamerica-northeast2
```

### Staging

Promote only after preview passes. Rebase onto `origin/master`, run local
gates, then:

```powershell
# Shared staging proxy:
powershell -ExecutionPolicy Bypass -File scripts\deploy_staging_proxy.ps1

# F&F Operations Console (admin):
powershell -ExecutionPolicy Bypass -File scripts\deploy_admin_console.ps1 `
  -AdminProxyBaseUri https://forge-flow-staging-proxy-XXXXX-XX.a.run.app

# Operator Web Console:
powershell -ExecutionPolicy Bypass -File scripts\deploy_operator_web.ps1 `
  -ProxyBaseUri https://forge-flow-staging-proxy-XXXXX-XX.a.run.app
```

Then verify Cloud Run Ready + 100% traffic + `/readyz` + CORS + Browser Use
smoke + the performance probe:

```powershell
dart run tool\perf_gate\staging_console_probe.dart `
  --run `
  --admin-url=<admin-url> `
  --proxy-url=<proxy-url> `
  --admin-revision=<rev> --proxy-revision=<rev> `
  --label=<branch-or-pr> `
  --write-json=build\perf_gate\<label>.json `
  --enforce-budgets
```

### Production1

Production deploys are **gated** by the cutover runbooks, not date-driven, and
never originate from a preview branch. Required before any production deploy:

- PR merged to `master`.
- Production unfreeze explicitly approved.
- Production migration drift checked (lex-cutoff list in
  `runbooks/phase_9_production1_migration_apply_runbook.md`).
- Production secrets, service principals, and the static-egress allowlist
  confirmed.

The same deploy scripts accept production overrides — pass `-Project
forge-flow-production1`, `-SecretPrefix forge-flow-production-`,
`-ServiceAccount`, `-VpcConnector ff-prod1-proxy-egress`, and the production
Firebase google-services path. Authority:

- [docs/phases/phase_production_cutover/phase_production_cutover_plan.md](docs/phases/phase_production_cutover/phase_production_cutover_plan.md)
- [runbooks/cutover_0_preflight_runbook.md](runbooks/cutover_0_preflight_runbook.md)
- [runbooks/phase_9_production1_migration_apply_runbook.md](runbooks/phase_9_production1_migration_apply_runbook.md)
- [runbooks/proxy_redeploy_reset_confirm_account_info_runbook.md](runbooks/proxy_redeploy_reset_confirm_account_info_runbook.md)
- [runbooks/v1_operator_launch_punchlist_runbook.md](runbooks/v1_operator_launch_punchlist_runbook.md)

Background workers (separate Cloud Run jobs / services):

```
scripts\deploy_audit_anchor_job.ps1                # daily Azure Blob anchor of hash-chained audit log
scripts\deploy_first_connect_backfill_worker.ps1   # first-connect vendor backfill
scripts\deploy_integration_sync_worker.ps1         # ongoing vendor sync
scripts\deploy_oauth_refresh_worker.ps1            # OAuth token refresh
```

---

## Demo mode

`--dart-define=kDemoMode=true` flips the writer to `MockReplayDataSourceProvider`
and seeds the same SQLite tables production reads (`shift_records`,
`week_records`, `restaurant_locations`, `target_cycles`, etc.) under
`DemoScope.restaurantId = 'demo_restaurant_001'`. Reader paths, services,
widgets, and the UI never branch on `kDemoMode` — Hard Promise #2.

Three sanctioned reader-side carve-outs (do not remove without an explicit
replacement plan):

1. Login screen `_demoOperatorSignInEnabled` — adds an additive "Use demo
   operator" button below regular sign-in.
2. `app_data_status_service.dart` — renders `DEMO` instead of `CURRENT` on the
   data-status badge.
3. Settings screen `_kDemoMode` — gates two demo-only sections ("Data reset"
   and "Demo date"). Hidden in production.

Per-(operator, location, category) demo state lives in the Postgres
`demo_mode_state` table; `DemoModeFlipPolicy.evaluateFlip` flips `is_demo =
false` after the first vendor connection backfills ≥1 record. Detail:
[docs/contracts/demo_mode_contract.md](docs/contracts/demo_mode_contract.md).

---

## Vendor integrations

17 INTEGRATE adapters across POS / Labor / Reservation, all at lifecycle =
`documented`. Each `*.live.sandbox` / `*.live.prod` slice fires when vendor
credentials arrive — does **not** block V1 launch.

- POS: Lightspeed K-Series, Toast, Clover, Oracle Simphony, Aloha NCR Voyix,
  Square, Revel.
- Labor: ADP, 7shifts, QuickBooks Time, Humanity, Agendrix, Push Operations.
- Reservation: Libro, OpenTable, Tock, SevenRooms.

Per-vendor docs: [docs/integrations/](docs/integrations/README.md). Tracker:
`docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`. Wave 1 (needed
for launch UX) = Lightspeed K-Series + Libro + QuickBooks Time.

---

## Current status

Active work routes through [PROJECT_TRACKER.md](PROJECT_TRACKER.md). Snapshot
as of 2026-05-12:

**V1 launch path — three workstreams remaining:**

1. **Operator-blocked (no engineering):**
   - Firebase Auth action-domain switch (`auth.feflow.org` → production).
   - Apply 2 remaining Production1 migrations (first-connect-backfill jobs +
     11W.7 operator account fields). 18 of 20 already staging-verified.
   - Seed operator-authored T&C content into `tos_versions`.
   - Sandbox creds for Wave 1 trio (Lightspeed K-Series, Libro, QuickBooks Time).
2. **Cutover gates (sequence-gated, not date-gated):** `cutover.0` preflight →
   `cutover.1` corpus load → `cutover.0b` Tier-M perf gate → `cutover.2` first
   operator onboarding → `cutover.3` traffic switch → `cutover.4` 7-day
   stability watch → `cutover.5` post-launch hardening.
3. **Engineering still in scope:** `11A.8/.9/.10` (Support audit,
   cross-operator reads, operator impersonation), `9.8` inbound vendor T&Cs
   code lane, `business-timing-live` full hierarchy + settings lanes,
   connected-device E2E + push delivery proof.

**Paused** (do not touch unless tracker says otherwise):

- AI phases: `11b*`, `12.*`, `11A.3.x`, `11A.11`, `9.8` advisor portion, `10b`.
- Outward-vendor: `8.5`, `11W.9`.
- Barrio: `9.5.UX.*`, `9.75`, `lib/internal/barrio/**`, `lib/main_barrio.dart`.

**Recently shipped** (2026-05-06 → 2026-05-12; see
`docs/archive/trackers/PROJECT_TRACKER_ARCHIVE.md`):

- Production1 runtime live (Cloud Run + Firebase + Postgres-CMK + production
  DNS).
- Phase 8 plug-and-play V1 onboarding engineering-complete (PRs #280-#301).
- Admin hierarchy + settings overhaul closed (12 slices on master).
- Post-audit remediation wave (PRs #417-#426 merged 2026-05-08).

---

## Repo guide

- [PROJECT_TRACKER.md](PROJECT_TRACKER.md) — active routing; "only what is left."
- [docs/POST_HARDENING_FOLLOWUPS.md](docs/POST_HARDENING_FOLLOWUPS.md) — open P0-P3 items.
- [docs/DATA_ALIGNMENT_TRACKER.md](docs/DATA_ALIGNMENT_TRACKER.md) — current source-of-truth watchpoints.
- [docs/contracts/](docs/contracts/) — Tier-2 binding rules (`core_app_architecture.md`, `demo_mode_contract.md`, RLS contract, etc.).
- [docs/phases/](docs/phases/) — active phase plans.
- [docs/archive/](docs/archive/README.md) — closed phases + retired references.
- [runbooks/](runbooks/) — operator-facing runbooks (preview, cutover, audit anchor, GDPR erasure, PITR drill, on-call).
- [docs/CODEX_PROMPT_GENERATION_STANDARD.md](docs/CODEX_PROMPT_GENERATION_STANDARD.md) — Codex / Claude parallel-lane operating standard.
- [docs/integrations/](docs/integrations/README.md) — per-vendor adapter docs.

Authority order when sources conflict (lowest number wins):

1. The active prompt.
2. `docs/contracts/core_app_architecture.md`.
3. `docs/contracts/**` (other Tier-2 contracts).
4. `PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`, `docs/POST_HARDENING_FOLLOWUPS.md`.
5. The active phase doc named in the prompt.
6. `CLAUDE.md`.

`docs/archive/**` is history — ignore unless explicitly named.

---

## Testing

- `flutter test` runs the smallest set that proves the seam.
- `dart analyze` whenever the prompt requires verification.
- `docs/KNOWN_FAILING_TESTS.md` lists pre-existing failures — treat as expected,
  not regressions.
- Runtime acceptance (advisory pattern, reviewer judgment):
  [docs/contracts/slice_runtime_acceptance_contract.md](docs/contracts/slice_runtime_acceptance_contract.md).
- Browser-exposed slices use Codex-driven Browser Use evidence per
  [runbooks/browser_use_codex_acceptance_workflow.md](runbooks/browser_use_codex_acceptance_workflow.md).

---

## Asset containment (mobile flavors)

The repo has two asset directories:

- `assets/images/` — shared assets used by ForgeFlow and/or both flavors.
- `assets/internal/barrio/` — Barrio-private runtime assets.

Flutter does not support flavor-conditional asset bundling, so **ForgeFlow
APKs currently include Barrio-private runtime assets** (~1.1 MB). The
ForgeFlow Dart entrypoint never references them; they are dead payload.
Eliminating this requires extracting Barrio into a separate Flutter package
(out of scope for current optimization work).

Non-runtime reference material under `assets/internal/barrio/branding/` and
`/inspiration/` is on disk but **not** declared in `pubspec.yaml` and **not**
bundled into either flavor.

---

## Notes

- `kDemoMode` is a writer-side switch (HP #2). Same tables, same reads, same
  UI under demo or vendor-live.
- `BaselineData` remains as a temporary compatibility bridge for Baseline,
  Schedule, and Learn; persisted `ActiveTargetProfile` is the canonical
  authority.
- Service-layer split: `lib/data/` is frozen legacy (delete-only).
  `lib/services/` = runtime orchestration; `lib/domain/services/` = pure
  formulas (no I/O); `lib/state/` = state holders; `lib/dev/` = demo + dev
  only.
- Service principals (non-human actors) authenticate with `sp:`-prefixed
  JWTs; `audit_logs.actor_kind` is never NULL. Audit log is hash-chained
  (SHA-256 via `pgcrypto`), partitioned per-operator/day, anchored daily to
  Azure Blob.
- `$HOME\.forge_flow\secrets\runtime\forge_flow.secrets.ps1` is the canonical
  private env loader (lives outside the repo).
