# `tool/cutover/` — production cutover utilities

This directory hosts read-only, operator-callable harnesses that
codify the manual checklists in
`docs/phases/phase_production_cutover/phase_production_cutover_plan.md`.

## `preflight_smoke.dart` — `cutover.0` pre-flight

Pre-flight smoke harness for the moment Production1 setup completes.
Runs read-only schema, RLS-isolation, firewall, secret-manager,
DNS, AGE Cypher MATCH, pgvector cosine, proxy `/health`, and
`pg_partman` + `pg_cron` checks against a target Postgres + the
surrounding Cloud Run / Secret Manager / DNS setup, then emits a
JSON go/no-go report.

The harness pairs with
`runbooks/cutover_0_preflight_runbook.md`, which explains *when* to
run it, *how to interpret* the report, and *which runbook section*
each red verdict escalates to.

### Install

The harness is a Dart tool inside this repository; no separate
install step. It depends on `lib/infrastructure/persistence/postgres/`
the same way `tool/advisor_proxy/` and `tool/audit_anchor/` do.

### Plan-only invocation

The default mode prints the planned check list and exits 0. This
prevents an accidental invocation against Production1 from happening
just because someone forgot a flag.

```powershell
dart run tool/cutover/preflight_smoke.dart
```

### Full invocation

```powershell
dart run tool/cutover/preflight_smoke.dart `
  --run `
  --connection-string="postgres://forgeflow_app:****@forge-flow-production1-pg-cmk.postgres.database.azure.com:5432/forgeflow?sslmode=require" `
  --report-out=build/cutover/preflight_smoke.json `
  --include-rls-isolation `
  --rls-operator-a=11111111-1111-1111-1111-111111111111 `
  --rls-operator-b=22222222-2222-2222-2222-222222222222 `
  --rls-location-a=33333333-3333-3333-3333-333333333333 `
  --rls-location-b=44444444-4444-4444-4444-444444444444 `
  --include-firewall-probe `
  --dns-hostname=app.forgeflow.app `
  --dns-hostname=admin.forgeflow.app `
  --skip-secrets
```

### Flags

| Flag | Purpose |
|---|---|
| `--run` | Required to execute. Default is plan-only. |
| `--connection-string=<dsn>` | Required with `--run`. Full Postgres DSN. Never echoed to stdout / logs / report. |
| `--report-out=<path>` | Write a JSON report to disk. Parent dirs are created. |
| `--label=<tag>` | Free-form label echoed into the report (e.g. `production1_first_preflight`). |
| `--json` | Emit JSON only on stdout (suppress the human table). |
| `--require-all` | Treat yellow as red. Default: yellow is non-blocking informational. |
| `--include-rls-isolation` | Run RLS isolation check. Requires four UUID flags below. |
| `--rls-operator-a=<uuid>` | Operator A UUID for the fixture write. |
| `--rls-operator-b=<uuid>` | Operator B UUID for the cross-tenant read. |
| `--rls-location-a=<uuid>` | Location A UUID. |
| `--rls-location-b=<uuid>` | Location B UUID. |
| `--rls-fixture-table=<name>` | Override the fixture table. Default: `event_outbox`. |
| `--include-firewall-probe` | Run the TCP `select 1` probe. |
| `--skip-firewall` | Skip the probe; report yellow. |
| `--skip-secrets` | Skip the GCP Secret Manager probe; report yellow. |
| `--skip-health-endpoint` | Omit the `/health` probe (workstation runs without Cloud Run egress). |
| `--expect-table=<name>` | Add a name to the expected-table set. May repeat. |
| `--required-secret=<name>` | Override the default required-secret list. May repeat. |
| `--dns-hostname=<host>` | Add a hostname to the DNS resolution check. May repeat. |
| `--allowlisted-subnet-cidr=<cidr>` | Echo the operator-stated allowlist CIDR into the report. |
| `--age-graph-name=<name>` | Override the AGE graph name probed by `age_cypher_match`. Default: `forge_graph`. |
| `--proxy-base-uri=<uri>` | Base URI for the production proxy. `/health` is appended. Falls back to `PROXY_BASE_URI`. |
| `--gcp-project-id=<id>` | GCP project for the live Secret Manager read. Falls back to `GOOGLE_CLOUD_PROJECT` / `GCP_PROJECT`. |
| `--help`, `-h` | Print usage and exit 0. |

### Required env vars

| Env Var | Used By | Notes |
|---|---|---|
| `PROXY_BASE_URI` | `health_endpoint` smoke | Falls back to this when `--proxy-base-uri` is omitted. |
| `GOOGLE_CLOUD_PROJECT` (or `GCP_PROJECT`) | `secret_manager_reachability` smoke | Falls back to this when `--gcp-project-id` is omitted. |
| `GOOGLE_APPLICATION_CREDENTIALS` (workstation only) | `secret_manager_reachability` smoke | Path to a service-account key file when not running on Cloud Run / GCE metadata. |

### Smoke list

| Smoke | What it proves | Red token |
|---|---|---|
| `schema_presence` | Required tables, RLS posture, tenant-leading indexes are in place. | `cutover_preflight_red_schema_presence` |
| `rls_isolation` | Cross-tenant SELECT under tenant B sees zero of tenant A's rows. | `cutover_preflight_red_rls_isolation` |
| `age_cypher_match` | `age` extension installed; named graph reachable; trivial `MATCH` returns without error. | `cutover_preflight_red_age_cypher_match` |
| `pgvector_cosine` | `vector` extension installed; `<=>` operator resolves to a numeric in `[0, 2]`. | `cutover_preflight_red_pgvector_cosine` |
| `partman_cron_active` | `pg_partman` + `pg_cron` installed; `cron.job` has at least one scheduled job. | `cutover_preflight_red_partman_cron_active` |
| `firewall_reachability` | TCP `select 1` to the Postgres host succeeds. | `cutover_preflight_red_firewall_reachability` |
| `health_endpoint` | Cloud Run proxy `/health` returns HTTP 200 + the expected body marker. | `cutover_preflight_red_health_endpoint` |
| `secret_manager_reachability` | Every required production secret is readable via Secret Manager + ADC. | `cutover_preflight_red_secret_manager_reachability` |
| `dns_resolution` | Every named hostname resolves to at least one A/AAAA. | `cutover_preflight_red_dns_resolution` |

### Exit codes

- **0** — overall green (or `--run` not set / `--help`).
- **1** — overall red. At least one check failed; the human stdout
  carries a `cutover_preflight_red_<reason>` token per failure.
- **2** — usage error (missing flag, malformed value).

### Green-path JSON shape

```json
{
  "schema_version": "1",
  "tested_at": "2026-05-06T17:30:00.000Z",
  "label": "production1_first_preflight",
  "require_all": false,
  "overall_status": "green",
  "overall_green": true,
  "checks": [
    {
      "name": "schema_presence",
      "status": "green",
      "message": "all 21 expected tables present, RLS posture matches expected, tenant-leading indexes ok",
      "elapsed_ms": 124.3,
      "details": {
        "expected_table_count": 21,
        "present_table_count": 86,
        "expected_rls_table_count": 8
      }
    },
    {
      "name": "rls_isolation",
      "status": "green",
      "message": "rls_isolation: tenant B saw zero rows for tenant A under event_outbox",
      "elapsed_ms": 18.2,
      "details": { "fixture_table": "event_outbox", "leak_count": 0 }
    },
    {
      "name": "firewall_reachability",
      "status": "green",
      "message": "firewall_reachability: TCP probe to Postgres succeeded; verify 127.0.0.1 / non-allowlist origins are blocked via Azure portal firewall rule list (see runbook)",
      "elapsed_ms": 41.0
    },
    {
      "name": "secret_manager_reachability",
      "status": "yellow",
      "message": "secret_manager_reachability: skipped (workstation_run)",
      "elapsed_ms": 0.0,
      "details": { "skipped": true, "required_secret_count": 4 }
    },
    {
      "name": "dns_resolution",
      "status": "green",
      "message": "dns_resolution: all 2 hostname(s) resolved",
      "elapsed_ms": 8.4,
      "details": {
        "resolved_hostname_count": 2,
        "address_count_by_hostname": {
          "app.forgeflow.app": 1,
          "admin.forgeflow.app": 1
        }
      }
    }
  ]
}
```

### Red-path JSON shape

A red verdict on, e.g., the schema presence check looks like:

```json
{
  "name": "schema_presence",
  "status": "red",
  "message": "cutover_preflight_red_schema_presence: 3 table(s) missing",
  "elapsed_ms": 110.2,
  "details": {
    "missing_tables": ["admin_request_idempotency", "graph_edges", "graph_nodes"]
  }
}
```

The report's `overall_status` flips to `red` and `overall_green`
flips to `false`. The CLI prints the missing-table list at the top
of stdout and exits 1.

### Escalation

A red verdict on any check stops `cutover.0`. Open
`runbooks/cutover_0_preflight_runbook.md`, find the row for the
named `cutover_preflight_red_<reason>` token, and follow the
escalation steps. **Do not advance to `cutover.1` until the gate
runs green.**
