# V1 Launch SLO Definitions

Status: ACTIVE — binds from `cutover.4` traffic flip onward.
Owner: F&F engineering.
Updated: 2026-05-07.
Alert implementations: `infrastructure/monitoring/alerts/`
On-call: `runbooks/on_call_rotation.md`
Stabilization: `runbooks/cutover_4_stabilization_runbook.md`

## Measurement Window

Unless stated otherwise, SLOs are measured over rolling 28-day windows.
Error budget is consumed daily; daily error budget = (1 − SLO target) × (minutes in day).

## SLO 1 — Operator Web Availability

**Target:** 99.5% availability (excluding planned maintenance windows).

**SLI definition:**
The fraction of 1-minute intervals in which the Operator Web Console (`app.forgeflow.app`)
returns HTTP 2xx or 3xx responses to synthetic health-check probes from at least 2 of 3
Cloud Monitoring uptime-check regions. A minute is counted as "available" if the probe
succeeds in ≥ 2 regions within that minute.

Planned maintenance is excluded: a maintenance window must be declared in advance in the
`#eng-oncall` channel with a minimum 30-minute notice. Maximum planned maintenance per
calendar month: 2 hours.

**Error budget per 28 days:**
```
(1 − 0.995) × 28 days × 24 h × 60 min = 201.6 minutes
```

**Alert threshold:** fires when rolling 7-day availability drops below 99.0% (burns > 50%
of the weekly budget). See `infrastructure/monitoring/alerts/` — availability alert is
backed by Cloud Monitoring uptime checks on `app.forgeflow.app`.

**Measurement:** Cloud Monitoring → Uptime Checks → `forge-flow-operator-web`.

---

## SLO 2 — Operator Web p95 Latency (Cached Views)

**Target:** p95 response latency < 1.5 seconds for cached Operator Web Console views,
measured at the Cloud Run load balancer.

**SLI definition:**
The 95th percentile of HTTP response latency for GET requests to Operator Web Console
routes that are expected to return cached or pre-computed data (dashboard tile endpoints,
shift list, cost summary). Routes excluded: initial full-page load (includes Flutter web
bootstrap), large CSV exports, AI advisor streaming responses.

Cached-view routes are identified by path prefix `/v1/operators/*/dashboard/*` and
`/v1/operators/*/shifts/*`.

**Error budget per 28 days:**
The latency SLO defines acceptable quality, not binary availability. Alert fires when p95
crosses 1.5s for any sustained 10-minute window.

**Alert threshold:** alert fires when measured p95 latency > 1.5s for 10 consecutive minutes.
Custom Cloud Monitoring metric: `custom/forgeflow/proxy/response_latency_ms` — p95 aggregation.

**Measurement:** Cloud Monitoring → Metrics Explorer → `custom/forgeflow/proxy/response_latency_ms`,
filtered to cached-view path prefixes, p95 over 10-minute alignment period.

---

## SLO 3 — Mobile Sync Freshness

**Target:** p95 sync lag < 5 minutes (time from a new vendor data event being available
to it being visible in the mobile app for the affected operator).

**SLI definition:**
For each vendor sync event that completes successfully, the sync_lag is:
```
sync_lag = mobile_client_ack_timestamp − vendor_event_created_at
```
The SLO measures the 95th percentile of `sync_lag` across all events in the measurement window.

Events excluded: initial backfill syncs, events from vendors whose polling tier is `low`
(> 15-minute poll interval) by operator choice, events during declared maintenance windows.

**Error budget per 28 days:**
p95 > 5 min means 5% of sync events are stale beyond the target. A sustained p95 of 10 min
for 7 days constitutes a budget exhaustion and triggers an SLO review.

**Alert threshold:** fires when rolling 1-hour p95 sync lag > 10 minutes.
Custom Cloud Monitoring metric: `custom/forgeflow/mobile_sync/lag_seconds`.

**Measurement:** Cloud Monitoring → `custom/forgeflow/mobile_sync/lag_seconds`, p95
aggregation over 1-hour windows, grouped by operator_id.

---

## SLO 4 — Audit Anchor Success (Compliance-Critical)

**Target:** 100% of closed operator-days are anchored before the next UTC day boundary.

This SLO is compliance-critical. A missed anchor for any operator-day is a gap in the
SOC 2 hash-chain evidence and must be treated as a P1 incident regardless of hour.

**SLI definition:**
For each `(operator_id, chain_date)` pair where `chain_date < current_utc_date`,
there must exist a row in `audit_chain_anchors` with `status = 'anchored'` and a valid
`blob_url` pointing to the immutable Azure Blob anchor. The SLI is the fraction of
eligible (operator_id, chain_date) pairs that are anchored before midnight UTC of the
day following `chain_date`.

**Error budget:** Zero. Any failure consumes 100% of the daily budget for the affected
operator-day and triggers a P1 alert within 26 hours (the `audit_anchor_lag` alert).

**Alert threshold:** 26 hours after the expected anchor window (23:55 UTC daily job run)
without a successful sweep. See `infrastructure/monitoring/alerts/audit_anchor_lag.yaml`.

**Measurement:** Direct query on `audit_chain_anchors` table. Automated by the
`audit_anchor_lag` log-based metric on the Cloud Run job completion log.

**Incident runbook:** `runbooks/audit_chain_verify_runbook.md`.

---

## SLO 5 — Vendor Adapter Success Rate

**Target:** > 95% sync success rate per active vendor per calendar day.

**SLI definition:**
For each active vendor adapter (i.e. `vendor_integration_health.status` is not
`disconnected` or `paused`), the daily success rate is:
```
daily_success_rate = successful_sync_calls / (successful_sync_calls + failed_sync_calls)
```
measured from 00:00 UTC to 23:59 UTC each calendar day.

A "successful sync call" is one that returns a valid payload and results in a write
(or a confirmed no-change response) to the appropriate Postgres tables.

Excluded from denominator: sync calls that fail due to declared vendor-side outages
(entered in `vendor_outage_declarations` table by on-call during the outage window).

**Error budget per 28 days:**
5% of calls may fail per vendor per day. Budget: 5% × 28 = 140 vendor-days of error capacity.
A sustained failure of one vendor for 7+ days consumes 25% of the monthly budget for that vendor.

**Alert threshold:** error rate > 5% over 10-minute window.
See `infrastructure/monitoring/alerts/vendor_adapter_error_rate.yaml`.

**Measurement:** Cloud Monitoring → `custom/forgeflow/vendor_adapter/request_count`,
grouped by `vendor_slug` and `status`, over 1-day aggregation windows.

---

## Error Budget Policy

| Budget consumed | Action |
|-----------------|--------|
| 0–25% | Business as usual. |
| 25–50% | Weekly review; investigate root causes; confirm no recurrence expected. |
| 50–75% | Engineering sprint item; P2 to fix by next sprint. |
| 75–100% | Feature freeze for the affected surface until budget recovered to < 50%. |
| 100% (exhausted) | P1 incident declared; executive escalation; root cause required before new features ship for that surface. |

Budget resets at the 28-day rolling window boundary (rolling, not calendar month).

## Review Cadence

SLOs are reviewed quarterly or after any incident that consumes > 25% of any budget in
a single day. Reviews may adjust targets up (tighter) but never down without executive approval.

First SLO review: 28 days after `cutover.4` traffic flip.
