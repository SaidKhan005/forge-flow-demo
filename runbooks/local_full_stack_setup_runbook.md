# Local Full-Stack Postgres Setup Runbook

> **Status:** Active (bootstrapped 2026-05-13 from a fresh AGE PG16 image).
> **Supersedes:** `docker-compose.dev.yml` + `db/dev/Dockerfile` (Phase 11a.11c.5
> scaffold — predates the wave's `pg_partman`, `pg_cron`, `pg_stat_statements`,
> and `pg_diskann` requirements).

This runbook captures what's running on the dev machine after the
post-Codex wave closeout (2026-05-13). It's the operator's local
counterpart to
[`runbooks/phase_9_production1_migration_apply_runbook.md`](phase_9_production1_migration_apply_runbook.md) —
same migrations, same cutoff (`202605131900_c_2_d_vendor_sync_outage_state.sql`),
but applied against a Docker container on `localhost:5433` instead of
Azure DB Flexible Server.

The goal: a full-stack local Postgres that satisfies every wave-scope
migration so the operator-web + proxy + mobile demo flows run end-to-end
against a real Postgres (not just SQLite). Staging + Production1 stay
untouched.

## Why Docker (and not the `docker-compose.dev.yml` path)

The original `docker-compose.dev.yml` builds Apache AGE from source on
top of `pgvector/pgvector:pg16`. That predates the wave's adoption of
`pg_partman` (declarative partition maintenance), `pg_cron` (scheduled
jobs), `pg_stat_statements` (query telemetry), and `pg_diskann`
(DiskANN ANN index — Azure-only). Without all six extensions, ~25
migrations fail.

Building AGE from source on Windows is also notoriously fragile (MSYS2
toolchain version drift). The cleaner path is to start from the
official Apache AGE PG16 image (`apache/age:release_PG16_1.6.0`) — AGE
is pre-built — and apt-install the other Linux-packaged extensions on
top. `pg_diskann` is Azure-only; it gets stubbed with a no-op
extension control file so `CREATE EXTENSION IF NOT EXISTS pg_diskann`
succeeds (DiskANN is dormant until Vector Index Health triggers fire
per `docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`;
the local demo never triggers).

## Local state — current

```
Container:  forge-flow-pg16 (image: forge-flow-pg16:ready)
Port:       localhost:5433
Database:   forge_flow
Superuser:  postgres / forge_flow_local
Tables:     163 (public schema)
Extensions: age 1.6.0, pg_partman 5.4.3, pgcrypto 1.3, vector 0.8.2,
            pg_diskann 1.0 (stub), pg_cron + pg_stat_statements
            (cluster-level via shared_preload_libraries)
Roles:      forge_admin (BYPASSRLS), service_role, authenticated,
            audit_privacy, postgres
AGE graph:  forgeflow (bootstrapped by 202605021700_phase_11A_health_age_graph_bootstrap.sql)
Master tip
at apply:   6b7e7352 (post-#641 advisory-lock reconciliation merge)
```

Connection string for the proxy / Flutter app:

```
POSTGRES_URL=postgresql://postgres:forge_flow_local@localhost:5433/forge_flow
POSTGRES_ADMIN_URL=postgresql://postgres:forge_flow_local@localhost:5433/forge_flow
```

(Same string for both — `postgres` is the superuser locally; for staging
+ Production1 they differ.)

## Daily operations

### Start the container

```powershell
docker start forge-flow-pg16
```

The container is configured with the full `shared_preload_libraries`
list and `cron.database_name = 'forge_flow'`. First-boot wait is ~5s.

### Stop the container

```powershell
docker stop forge-flow-pg16
```

Data persists in the named volume `forge_flow_pg16_data`.

### Check status

```powershell
docker ps --filter "name=forge-flow-pg16" --format "table {{.Names}}`t{{.Status}}`t{{.Ports}}"
docker exec forge-flow-pg16 pg_isready -U postgres
```

### Connect

```bash
# From the host (any psql 16 client):
PGPASSWORD=forge_flow_local "/c/Program Files/PostgreSQL/16/bin/psql" \
  -h localhost -p 5433 -U postgres -d forge_flow

# From inside the container:
docker exec -it forge-flow-pg16 psql -U postgres -d forge_flow
```

### View the apply log

```bash
docker exec forge-flow-pg16 psql -U postgres -d forge_flow \
  -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
docker exec forge-flow-pg16 psql -U postgres -d forge_flow \
  -c "SELECT count(*) FROM pg_tables WHERE schemaname='public';"
```

## Bootstrap from scratch (when starting fresh or after `docker volume rm`)

Run these commands sequentially. They reproduce what landed on
2026-05-13.

### 1. Pull the Apache AGE PG16 image

```powershell
docker pull apache/age:release_PG16_1.6.0
```

### 2. Spin up a bootstrap container (AGE-only preload)

`shared_preload_libraries` cannot list extensions that aren't
installed yet, so we boot with AGE-only first, install the others, then
swap.

```powershell
docker run -d --name forge-flow-pg16-bootstrap `
  -e POSTGRES_PASSWORD=forge_flow_local `
  -e POSTGRES_DB=forge_flow `
  -p 5433:5432 `
  -v forge_flow_pg16_data:/var/lib/postgresql/data `
  apache/age:release_PG16_1.6.0
```

Wait for ready:

```powershell
docker exec forge-flow-pg16-bootstrap pg_isready -U postgres
```

### 3. Install `pg_partman` + `pg_cron` + `pgvector`

```powershell
docker exec forge-flow-pg16-bootstrap bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends postgresql-16-pgvector postgresql-16-partman postgresql-16-cron"
```

### 4. Install the `pg_diskann` no-op stub

`pg_diskann` is Azure-only. The wave installs it (`db/migrations/202604280009_phase_9_0sigma_j_diskann_install.sql`)
but never uses it (DiskANN dormant per Q20). Locally, a no-op stub lets
`CREATE EXTENSION` succeed.

```powershell
docker exec forge-flow-pg16-bootstrap bash -c "cat > /usr/share/postgresql/16/extension/pg_diskann.control << 'EOF'
comment = 'pg_diskann stub (local dev) — no-op'
default_version = '1.0'
relocatable = false
EOF
cat > /usr/share/postgresql/16/extension/pg_diskann--1.0.sql << 'EOF'
-- pg_diskann stub for local dev. No-op.
EOF"
```

### 5. Commit the bootstrap image + restart with full preload

```powershell
docker commit forge-flow-pg16-bootstrap forge-flow-pg16:ready
docker stop forge-flow-pg16-bootstrap
docker rm forge-flow-pg16-bootstrap

docker run -d --name forge-flow-pg16 `
  -e POSTGRES_PASSWORD=forge_flow_local `
  -e POSTGRES_DB=forge_flow `
  -p 5433:5432 `
  -v forge_flow_pg16_data:/var/lib/postgresql/data `
  forge-flow-pg16:ready `
  postgres -c "shared_preload_libraries=age,pg_cron,pg_stat_statements" -c "cron.database_name=forge_flow"
```

Wait for ready:

```powershell
docker exec forge-flow-pg16 pg_isready -U postgres
docker exec forge-flow-pg16 psql -U postgres -d forge_flow -c "SHOW shared_preload_libraries;"
```

Should print `age,pg_cron,pg_stat_statements`.

### 6. Create stubs for legacy fact tables

The wave has a real bug (tracked as **W-1** in
[`docs/POST_HARDENING_FOLLOWUPS.md`](../docs/POST_HARDENING_FOLLOWUPS.md)):
4 legacy SQLite-only fact tables (`shift_records`, `cover_facts`,
`labor_punches`, `reservation_facts`) are referenced by Phase 8
migrations but never created by any migration. The Phase 8 framework
writes those tables in SQLite per HP #1, not in Postgres — so the
ALTER TABLE migrations were premature.

For local apply, create minimal stubs so the ALTER TABLE + CREATE INDEX
statements succeed. Stubs stay empty (no writers); demo writes go to
SQLite as always.

```bash
PGPASSWORD=forge_flow_local "/c/Program Files/PostgreSQL/16/bin/psql" \
  -h localhost -p 5433 -U postgres -d forge_flow -v ON_ERROR_STOP=1 -c "
create extension if not exists pgcrypto;

create table if not exists public.shift_records (
  shift_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text,
  vendor_entity_id text,
  business_date date
);
create table if not exists public.cover_facts (
  cover_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text,
  vendor_entity_id text,
  business_date date
);
create table if not exists public.labor_punches (
  punch_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text,
  vendor_entity_id text,
  business_date date
);
create table if not exists public.reservation_facts (
  reservation_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,
  vendor_id text,
  vendor_entity_id text,
  business_date date
);
"
```

### 7. Apply migrations 1–80 (clean path)

```bash
export PGPASSWORD=forge_flow_local
PSQL="/c/Program Files/PostgreSQL/16/bin/psql"

for f in $(ls db/migrations/*.sql | sort); do
  name=$(basename "$f")
  "$PSQL" -h localhost -p 5433 -U postgres -d forge_flow -v ON_ERROR_STOP=1 -f "$f" || break
done
```

The loop will halt at
`202605061700_phase_8_timing_provenance_shift_records.sql` (the
fact-table gap is now stubbed in step 6, so this migration's ALTER
TABLE succeeds — re-run the loop from this point).

### 8. Apply the partman dollar-quote patch

The wave has a second real bug (tracked as **W-2** in
`POST_HARDENING_FOLLOWUPS.md`):
`db/migrations/202605081100_partman_maintenance_hourly_cron.sql` uses
unnamed `do $$ ... $$;` block delimiters AND its `raise notice` body
contains `$$select ... $$` inside a single-quoted string. PostgreSQL's
dollar-quote lexer sees the inner `$$` and terminates the outer block
early, producing `syntax error at or near "select"`. The fix is a
tagged dollar quote (`do $partman$ ... $partman$;`).

For local apply, patch into a temp file:

```bash
mkdir -p /tmp/forge_flow_local_migration_patches
sed -e 's/^do \$\$$/do $partman$/' \
    -e 's/^\$\$;$/$partman$;/' \
  db/migrations/202605081100_partman_maintenance_hourly_cron.sql \
  > /tmp/forge_flow_local_migration_patches/202605081100_partman_maintenance_hourly_cron.patched.sql

"$PSQL" -h localhost -p 5433 -U postgres -d forge_flow \
  -v ON_ERROR_STOP=1 \
  -f /tmp/forge_flow_local_migration_patches/202605081100_partman_maintenance_hourly_cron.patched.sql
```

Expect a `NOTICE: pg_cron metadata is not in this database` — that's the
migration's own guard for the case where `cron.database_name` differs
from the application DB, which is correct posture (cron metadata lives
in the `postgres` database).

### 9. Resume the apply loop

Re-run the loop in step 7. It will skip the migrations already applied
(idempotent guards on every CREATE) and continue through the cutoff
file `202605131900_c_2_d_vendor_sync_outage_state.sql`.

Expected final state: **125 migrations applied** (matches step 7 + 8
combined).

## Wave bug references

| Bug | Migration / file | Local workaround | Tracker |
|---|---|---|---|
| **W-1** | 4 legacy fact tables never CREATEd | Minimal stubs in step 6 | `docs/POST_HARDENING_FOLLOWUPS.md` "Wave bugs surfaced 2026-05-13 by local apply" |
| **W-2** | `202605081100_partman_maintenance_hourly_cron.sql` dollar-quote nesting | `sed` patch in step 8 | Same |

Both must be fixed in-migration before the Production1 apply queue
runs — they will fail on Production1 with the same errors.

## Resetting the DB (start from scratch)

```powershell
docker stop forge-flow-pg16
docker rm forge-flow-pg16
docker volume rm forge_flow_pg16_data
# Then re-run "Bootstrap from scratch" above.
```

The `forge-flow-pg16:ready` image stays; only the volume's data is
discarded. The image already has the apt-installed extensions + the
diskann stub baked in, so re-bootstrap is faster the second time.

## Wiring the proxy + Flutter against local PG

### Proxy (`tool/advisor_proxy/main.dart`)

Set `POSTGRES_URL` + `POSTGRES_ADMIN_URL` in your shell or in your
local `forge_flow.secrets.ps1` (or `~/.forge_flow/secrets/runtime/forge_flow.secrets.ps1`)
to the local connection string from "Local state — current" above.

Boot:

```powershell
dart run tool/advisor_proxy/main.dart
```

### Flutter Operator Web

```bash
flutter run -t lib/main_operator_web.dart -d chrome \
  --dart-define=OPERATOR_WEB_PROXY_BASE_URI=http://localhost:8080
```

### Flutter mobile (forgeflow / barrio)

```powershell
scripts\run_flutter_dev.ps1 -App forgeflow
```

The mobile launchers do NOT need `POSTGRES_URL` — they hit the proxy
via Cloud Run staging by default. To point them at the local proxy,
pass `-ProxyBaseUri http://localhost:8080`.

### adb (Android Debug Bridge) — for direct mobile UI testing

The connected Samsung A54 (`SM-A546W`, transport id `R5CW503HJHP`) is
controlled directly via adb for click-path verification + screencap
during agent walkthroughs. adb ships with the Android SDK but is NOT
on `PATH` by default. Full path:

```
C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe
```

Common commands an agent uses during a live UI check:

```powershell
# List connected devices (sanity)
& "C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe" devices -l

# Tap at screen coordinates (x=540, y=1200 etc.)
& "C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe" shell input tap 540 1200

# Type text (URL-encode spaces as %s)
& "C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe" shell input text "hello%sworld"

# Screen cap (binary PNG to local file for inspection / PR attachment)
& "C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe" exec-out screencap -p > screenshot.png

# Tail device logs (filtered)
& "C:\Users\saidu\AppData\Local\Android\Sdk\platform-tools\adb.exe" logcat -v threadtime --pid=$(adb shell pidof com.forgeflow.app)
```

To persist on `PATH` for a session, set `ANDROID_HOME`:

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
$env:PATH = "$env:ANDROID_HOME\platform-tools;$env:PATH"
adb devices -l   # now works bare
```

Operator's machine convention: prefer the full-path invocation in
agent scripts so they work even when invoked from contexts that don't
inherit the session PATH update.

## Differences from staging / Production1

| Aspect | Local | Staging / Production1 |
|---|---|---|
| Hostname | `localhost:5433` | Azure DB Flexible Server, `Canada Central`, PG 16 |
| Auth | `postgres / forge_flow_local` | Managed identity / scram-sha-256 |
| `pg_diskann` | No-op stub (Azure-only extension) | Real Microsoft DiskANN |
| `pg_cron` jobs | Configured on `cron.database_name = 'forge_flow'`; the partman migration emits `NOTICE: pg_cron metadata is not in this database` because cron metadata is per-cluster | Same; on Azure the cron DB is typically `postgres` |
| Legacy fact tables (`shift_records` etc.) | Minimal stubs created via step 6 | Will fail with `relation does not exist` until W-1 is fixed |
| TLS | Disabled (Docker container on loopback) | Required |
| Advisory locks | Active per `202605070200_audit_anchor_advisory_lock_infra.sql` + `202605080900_oauth_refresh_advisory_lock.sql` (J4 race fix); see `docs/POST_HARDENING_FOLLOWUPS.md` "Advisory-lock posture — reconciled 2026-05-13" | Same |

## Files NOT to commit

- The local `pgpass.conf` / `forge_flow.secrets.ps1` entries pointing at
  this Docker DB.
- The temp patch files under `/tmp/forge_flow_local_migration_patches/`
  (regenerate on demand from step 8).

## Authority anchors

- [`docs/POST_HARDENING_FOLLOWUPS.md`](../docs/POST_HARDENING_FOLLOWUPS.md)
  — wave bug ledger (W-1, W-2).
- [`docs/archive/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`](../docs/archive/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md)
  — the wave closeout that motivated full-stack local validation.
- [`runbooks/phase_9_production1_migration_apply_runbook.md`](phase_9_production1_migration_apply_runbook.md)
  — the production counterpart; SAME migrations, SAME cutoff, different
  target.
- [`docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`](../docs/phases/phase_9/phase_9_vector_index_switch_trigger.md)
  — DiskANN dormancy + cutover gating; basis for the local no-op stub.
- `lib/services/integration/oauth_refresh_cron.dart` — the "RESTORED per
  J4 race fix" comment justifying the advisory locks on the apply queue.
