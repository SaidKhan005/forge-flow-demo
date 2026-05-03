# Proxy /health Contract

Updated: 2026-05-03
Owner: B42 proxy `/health` expansion
Status: Active authority

## Why This Exists

B42 defines the health envelope that the Phase 11A operations console reads.
It is intentionally a foundation contract: the proxy owns the response shape,
while B44, B45, B47, and adjacent operational slices fill metric values over
time. As of 2026-05-03, B44 graph, B45 rollup, and B47 vector producer wiring
is code-delivered and `11A.5` Debug Console is accepted. Remaining health
work is the `11A.6` UX/observability surface, live data evidence, and
operational recovery posture.

This contract is the handoff between:

- `tool/advisor_proxy/advisor_proxy.dart` - route and JSON envelope.
- `docs/phases/phase_9/phase_9_execution_backlog.md` - B42/B44/B45/B47
  sequencing.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  - the admin health and observability consumers.
- `docs/contracts/event_outbox_contract.md` - event bridge lag thresholds.
- `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql` -
  `public.graph_health_metrics()` and graph edge tripwires.
- `docs/phases/phase_9/phase_9_rollups_rebuild_runbook.md` - rollup rebuild
  and freshness behavior.

When this document and code disagree, the proxy route and focused proxy tests
win for wire shape; this document explains intent and ownership.

## Endpoint Split

`GET /healthz`

- Public unauthenticated liveness check.
- Returns only `{"status":"ok"}`.
- Used for local compatibility and simple process liveness.

`GET /readyz`

- Public unauthenticated readiness check.
- Returns only `{"status":"ok"}`.
- Used by Cloud Run and edge checks. It must stay cheap and must not touch
  Postgres or providers.

`GET /health`

- Public unauthenticated deep health envelope.
- Returns dependency checks plus a stable metric envelope.
- Must never return secrets, DSNs, tokens, recovery codes, raw prompt content,
  raw vendor payloads, user identifiers, tenant identifiers, device
  identifiers, or per-customer free text.
- May expose coarse platform/operator-safe counts and lag values required by
  the F&F internal operations console.

## Top-Level Semantics

The response has these stable top-level fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `status` | string | `ok`, `degraded`, or `unavailable`. |
| `severity` | string | `green`, `yellow`, `red`, or `unknown`. Mirrors the F&F health standard. |
| `contract` | string | Currently `proxy_health.v1`. |
| `schema_version` | integer | Currently `1`. |
| `checked_at` | RFC3339 UTC string | Time the proxy assembled the response. |
| `dependencies` | object | Required proxy dependency checks. |
| `surfaces` | object | Named health surfaces for the operations console. |
| `metrics` | object | Flat metric dictionary; every metric uses the same envelope. |

HTTP status is tied only to required proxy dependencies:

- `200` with `status: ok` when dependencies pass and no populated metric is
  yellow/red.
- `200` with `status: degraded` when dependencies pass but one or more
  populated non-blocking metrics/surfaces is yellow or red.
- `503` with `status: unavailable` when a required dependency check fails or
  the health store throws.

Reserved metrics with `status: unknown` do not make the response degraded.
They are placeholders that let UI and later producers bind to stable keys.

## Compatibility Fields

The first `/health` implementation exposed these top-level fields:

- `postgres_select_1`
- `age_cypher_match`
- `pgvector_similarity`

B42 keeps them as compatibility aliases. New consumers should read
`dependencies` instead.

## Dependency Envelope

Required dependency checks are reported under `dependencies`:

```json
{
  "dependencies": {
    "postgres": {
      "status": "green",
      "check": "select_1",
      "legacy_key": "postgres_select_1"
    },
    "age": {
      "status": "green",
      "check": "cypher_match",
      "legacy_key": "age_cypher_match"
    },
    "pgvector": {
      "status": "green",
      "check": "similarity",
      "legacy_key": "pgvector_similarity"
    }
  }
}
```

Dependency `status` is `green` or `red`. A red dependency makes the whole
response `unavailable` and returns HTTP `503`.

## Metric Envelope

Every metric under `metrics` uses this shape:

```json
{
  "status": "unknown",
  "value": null,
  "unit": "seconds",
  "description": "Human-readable operational meaning.",
  "source": "optional SQL function, table, worker, or benchmark",
  "owner": "B-item or phase that fills the metric",
  "observed_at": "2026-04-29T00:00:00.000Z",
  "thresholds": {
    "yellow": 60,
    "red": 300
  },
  "metadata": {
    "optional": "small sanitized context"
  }
}
```

Rules:

- `status` is always one of `green`, `yellow`, `red`, `unknown`.
- `value` may be a number, string, boolean, array, object, or null.
- `unit` is a short machine-readable noun such as `seconds`, `milliseconds`,
  `count`, or `ratio`.
- `owner` identifies the slice expected to populate the metric.
- `observed_at` is the time the metric value was measured, not necessarily the
  time `/health` was requested.
- `metadata` must stay small and sanitized. It is for stable labels such as
  corpus IDs or grain names only when those labels are approved for this public
  health surface.

## Reserved Metrics

B42 reserves these keys. Later slices fill values and statuses without
renaming the keys.

| Metric | Owner | Unit | Notes |
| --- | --- | --- | --- |
| `audit_chain_lag_seconds` | B37/B43 | seconds | Lag between current audit chain head and latest durable audit anchor. |
| `event_outbox_undelivered_count` | Phase 10a | count | Yellow at 10,000; red at 100,000 per event outbox contract. |
| `event_outbox_lag_seconds` | Phase 10a | seconds | Yellow at 60; red at 300 per event outbox contract. |
| `usage_caps_breach_count` | B33 | count | Requests refused because usage caps were reached. |
| `graph_node_count` | B44 | count | From `public.graph_health_metrics()`. |
| `graph_edge_count` | B44 | count | Yellow at 3,000,000; red at 4,000,000 active edges. |
| `graph_traversal_latency_ms` | B44 | milliseconds | Populated by graph benchmark/tripwire work. |
| `vector_index_size_per_corpus` | B47 | count | Per-corpus vector index size. |
| `vector_query_latency_ms` | B47 | milliseconds | Filtered vector search latency summary. |
| `vector_recall` | B47 | ratio | Filtered-search benchmark recall. |
| `rollup_freshness_per_grain` | B45 | seconds | Freshness lag grouped by rollup grain. |

## Surface Envelope

`surfaces` groups related metrics for the operations console:

```json
{
  "surfaces": {
    "graph": {
      "status": "unknown",
      "metrics": [
        "graph_node_count",
        "graph_edge_count",
        "graph_traversal_latency_ms"
      ],
      "owner": "B44"
    }
  }
}
```

Reserved surfaces:

| Surface | Metrics | Owner |
| --- | --- | --- |
| `audit_chain` | `audit_chain_lag_seconds` | B37/B43 |
| `event_outbox` | `event_outbox_undelivered_count`, `event_outbox_lag_seconds` | Phase 10a |
| `usage_caps` | `usage_caps_breach_count` | B33 |
| `graph` | `graph_node_count`, `graph_edge_count`, `graph_traversal_latency_ms` | B44 |
| `vector` | `vector_index_size_per_corpus`, `vector_query_latency_ms`, `vector_recall` | B47 |
| `rollups` | `rollup_freshness_per_grain` | B45 |

## Foundation vs. Producer Boundary

B42 lands:

- The contract document.
- The proxy JSON envelope.
- Compatibility aliases for the original dependency fields.
- Focused tests proving the reserved metric and surface keys.

B42 did not land these producer families; they are tracked under their owner
slices and are now partly or fully delivered as noted:

- Graph projection rebuild tooling or traversal benchmarks. That is B44
  (producer wiring delivered).
- Rollup freshness UI integration or worker telemetry filling. That is B45
  (producer wiring delivered; UX/live evidence remains with 11A).
- Vector health collection or filtered-search benchmark execution. That is B47
  (producer wiring delivered; live benchmark evidence remains with 11A).
- Event bridge worker metrics. Those land with Phase 10a.
- Audit anchor deployment. That is B43.

The later slices should add metric producers behind `ProxyHealthCheckStore`
without changing this envelope.
