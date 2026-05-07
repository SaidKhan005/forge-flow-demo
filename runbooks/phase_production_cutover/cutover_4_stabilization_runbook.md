# Cutover.4 — 7-Day Stability Watch Runbook

Updated: 2026-05-07.
Owner: Vanessa (primary on-call) — see `runbooks/on_call_rotation.md`.
Applies to: the 7-day stability watch period beginning at `cutover.4` traffic flip.
Alert index: `infrastructure/monitoring/alerts/`

## Purpose

This runbook governs the `cutover.4` stability watch. `cutover.4` is the traffic-flip
gate: 100% of operator requests route to the production Cloud Run proxy. The 7-day
watch confirms that all P1 SLOs hold under real load before the cutover lane closes.

Nothing in this runbook requires code changes during the watch window. If a finding
requires a code change, open a hotfix lane; do not modify production files ad hoc.

---

## Daily Checks

Run each check once per UTC day (recommended: 09:00 UTC, before operator business hours).

### 1. Audit Anchor Success

```sql
-- Run on production Postgres.
-- Expected: one row per operator per prior UTC day, status = 'anchored'.
SELECT
  operator_id,
  chain_date,
  status,
  anchored_at
FROM audit_chain_anchors
WHERE chain_date = current_date - interval '1 day'
ORDER BY operator_id;
```

Pass: every active operator has a row with `status = 'anchored'`.
Fail: any operator missing → trigger `runbooks/audit_chain_verify_runbook.md` manual rerun.

### 2. Outbox Depth

```sql
SELECT status, count(*) AS cnt
FROM event_outbox
WHERE status != 'delivered'
GROUP BY status
ORDER BY cnt DESC;
```

Pass: pending row count < 500. Acceptable backlog for low-traffic hours.
Warn: 500–10,000 → monitor, investigate consumer lag.
Fail: > 10,000 → see [Vendor Adapter Wedged](#vendor-adapter-wedged) playbook.

### 3. Vendor Adapter Health

```sql
SELECT
  vendor_slug,
  status,
  count(*) AS cnt,
  max(last_error_at) AS last_error
FROM vendor_integration_health
GROUP BY vendor_slug, status
ORDER BY vendor_slug, status;
```

Pass: all active vendors `status = 'healthy'`.
Warn: any vendor in `status = 'degraded'` with error count < 10 in last 24h.
Fail: any vendor `status = 'failed'` or error count > 50 in last 24h.

### 4. Error Rate

Check Cloud Monitoring dashboard: `infrastructure/monitoring/dashboards/vendor_health_dashboard.yaml`.
Or query logs:

```
gcloud logging read '
  resource.type="cloud_run_revision"
  AND severity="ERROR"
  AND timestamp >= "2026-05-07T00:00:00Z"
' --limit=100 --format=json | jq '.[] | .jsonPayload.event' | sort | uniq -c | sort -rn
```

Pass: P1-triggering error events < 5 per day across all operators.
Fail: any event pattern appearing > 20 times → investigate immediately.

### 5. Cost Check

```sql
SELECT
  operator_id,
  cap_class,
  tokens_used_today,
  hard_cap_tokens,
  round(tokens_used_today::numeric / hard_cap_tokens * 100, 1) AS pct_used
FROM usage_caps
WHERE window_start = current_date
ORDER BY pct_used DESC
LIMIT 20;
```

Pass: no operator > 80% of their daily hard cap.
Warn: any operator 80–100% → proactively notify operator.
Fail: any operator hitting hard cap → investigate for runaway loop.

---

## Stability Timeline

### Hour 0 — Traffic Flip Complete

Expected state:
- Cloud Run proxy receives 100% of operator traffic.
- All vendor adapters reporting `status = connected` in `vendor_integration_health`.
- Zero P1 alerts firing.
- Outbox depth < 200 rows (cleared from pre-flip drain).
- Audit anchor for yesterday's date is confirmed anchored.

Action: confirm all daily checks pass; post status to `#eng-oncall`.

### Hour 24 — First Full Day

Expected state:
- At least one full audit_anchor sweep has completed successfully.
- No vendor has been in `status = failed` for more than 1 hour continuously.
- p95 API latency (Operator Web) < 1.5s on Cloud Monitoring latency percentile chart.
- FCM delivery success rate > 95%.
- Zero auth-related P1 alerts.

Action: run full daily checks. Review Cloud Monitoring latency dashboard. Confirm
per-vendor error rates from `vendor_health_dashboard` are all < 5%.

### Hour 72 — Mid-Watch

Expected state:
- Audit anchors: 3 consecutive days complete, all anchored, zero failures.
- OAuth refresh cycles: all vendor tokens refreshed at least once without error.
- Pool saturation never exceeded 60% during peak hours.
- Cost per operator tracking within expected range.
- Outbox depth p95 over the period < 1,000 rows.

Action: review Cloud Monitoring alerting history — were any P2 alerts auto-resolved
without operator action? If so, document the cause and confirm it is not recurring.

### Hour 168 — Watch End (Day 7)

Expected state:
- All P1 SLOs from `docs/contracts/v1_launch_slos.md` holding:
  - Operator Web availability >= 99.5%.
  - Mobile sync lag p95 < 5 min.
  - Audit anchor 100% per chain-day.
  - All vendor adapters > 95% success rate.
- No open P1 incidents.
- Shift log in `docs/ops/oncall_shift_log.md` completed for all 7 days.

Action: write the `cutover.4` close report. Post to `#eng-cutover`. The cutover lane is
now closed; handoff to normal production operations under `runbooks/on_call_rotation.md`.

---

## Incident Playbooks

### Vendor Adapter Wedged

Symptoms: outbox depth growing; `vendor_integration_health.status = 'failed'`; vendor
error rate alert firing.

Steps:
1. Identify the stuck vendor slug from the alert or outbox query above.
2. Check proxy logs:
   ```
   gcloud logging read 'jsonPayload.fields.vendor_slug="<slug>" AND severity>="ERROR"' --limit=50
   ```
3. If `401 Unauthorized`: the OAuth token has expired. Trigger a manual refresh:
   ```
   POST /v1/integrations/<integration_id>/oauth/refresh
   Authorization: Bearer <service_principal_jwt>
   ```
4. If `429 Too Many Requests`: the vendor is rate-limiting F&F. Reduce polling tier for
   affected operators via `UPDATE forge_flow_polling_tier_assignments SET tier = 'low' WHERE vendor_slug = '<slug>'`.
5. If `5xx` from vendor: check the vendor's status page. If vendor is down, mark the adapter
   as `degraded` in `vendor_integration_health` to stop retry spam:
   ```sql
   UPDATE vendor_integration_health
   SET status = 'degraded', last_error = 'vendor_outage', degraded_at = now()
   WHERE vendor_slug = '<slug>';
   ```
6. Once the root cause is fixed, trigger adapter reconnect:
   ```
   POST /v1/integrations/<integration_id>/reconnect
   ```
7. Monitor outbox consumer — confirm it drains within 15 minutes.

Escalate if outbox depth grows > 50,000 or if the adapter cannot be cleared within 1 hour.

---

### Postgres Connection Storm

Symptoms: `postgres_connection_pool_saturation` alert; latency spike; 502/504 errors from
proxy.

Steps:
1. Identify which service is consuming connections:
   ```sql
   SELECT application_name, state, count(*)
   FROM pg_stat_activity
   GROUP BY application_name, state
   ORDER BY count DESC;
   ```
2. If long-running idle transactions are holding connections:
   ```sql
   SELECT pid, query_start, state, query
   FROM pg_stat_activity
   WHERE state = 'idle in transaction'
     AND query_start < now() - interval '5 minutes';
   -- Terminate safely:
   SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE state = 'idle in transaction' AND query_start < now() - interval '5 minutes';
   ```
3. If Cloud Run instance count is at max-instances cap and connection pool is at limit:
   increase Cloud Run max-instances temporarily:
   ```
   gcloud run services update forge-flow-proxy --max-instances=20 --region=__REGION__
   ```
   Document the change and revert once traffic normalizes.
4. If a specific query is blocking many connections: use `pg_cancel_backend(pid)` for
   still-running queries or `pg_terminate_backend(pid)` for runaway ones.
5. Confirm pool saturation drops below 60% before closing the incident.

Escalate to PITR drill assessment if connection storm is caused by runaway write load that
may have caused data inconsistency — see `runbooks/postgres_pitr_drill_runbook.md`.

---

### Audit Anchor Crash

Symptoms: `audit_anchor_lag` alert; Cloud Run Job shows failed executions; `audit_chain_anchors`
missing rows for the prior UTC day.

Steps:
1. View failed executions:
   ```
   gcloud run jobs executions list \
     --job=forge-flow-audit-anchor \
     --region=__REGION__ \
     --limit=5
   ```
2. Read error logs for the failed execution:
   ```
   gcloud logging read \
     'resource.type="cloud_run_job" resource.labels.job_name="forge-flow-audit-anchor" severity>="ERROR"' \
     --limit=50
   ```
3. Common failure modes:
   - `azure_blob_write_failed`: Azure Blob container quota exceeded, or credentials expired.
     Check Azure portal → Storage Account → forge-flow-audit-anchor container.
   - `postgres_connection_failed`: DB is unreachable from the Cloud Run job VPC. Check firewall rules.
   - `chain_hash_mismatch`: a row in `audit_logs` was mutated after chain close. This is a
     SECURITY INCIDENT — escalate immediately, do not attempt auto-remediation.
4. Once root cause is fixed, trigger manual rerun:
   ```
   gcloud run jobs run forge-flow-audit-anchor --region=__REGION__
   ```
5. Confirm `audit_chain_anchors` has a new row for the missed date with `status = 'anchored'`.

If `chain_hash_mismatch` is detected: follow the break-glass procedure in
`runbooks/audit_chain_verify_runbook.md` and escalate to the executive on-call immediately.

---

### FCM Mass Revocation

Symptoms: `fcm_delivery_failure_spike` alert; FCM error codes predominantly `UNREGISTERED`
or `NOT_FOUND`.

Steps:
1. Confirm scale of the revocation:
   ```sql
   SELECT fcm_error_code, count(*)
   FROM fcm_delivery_log
   WHERE created_at > now() - interval '2 hours'
   GROUP BY fcm_error_code
   ORDER BY count DESC;
   ```
2. If `UNREGISTERED` > 50% of failures: this is a mass token revocation. Likely cause:
   many operators/employees reinstalled the app or cleared app data.
   - Purge stale tokens:
     ```sql
     DELETE FROM mobile_push_tokens
     WHERE last_fcm_error = 'UNREGISTERED'
       AND updated_at < now() - interval '1 hour';
     ```
   - This is self-healing: tokens re-register on next app launch.
3. If `INTERNAL` / `UNAVAILABLE` dominates: FCM service disruption. Check https://status.firebase.google.com/.
   - Temporarily reduce push notification send volume to avoid rate-limit accumulation.
   - Monitor FCM status page; resume normal sends when service recovers.
4. Confirm delivery success rate returns above 95% within 30 minutes of token purge.

---

### Operator Stuck in Demo Mode

Symptoms: an operator reports that their data is all demo data; real vendor data not showing.
Underlying cause: the operator's account has `kDemoMode = true` in the mobile/web client
state, or `demo_mode = true` on the `operators` row.

Steps:
1. Confirm demo mode flag:
   ```sql
   SELECT operator_id, name, demo_mode
   FROM operators
   WHERE operator_id = '<uuid>';
   ```
2. If `demo_mode = true` and should be live:
   ```sql
   UPDATE operators SET demo_mode = false WHERE operator_id = '<uuid>';
   ```
3. Confirm vendor adapter is connected (not still in sandbox/demo credentials).
   Check `vendor_integration_health` for the operator's integrations.
4. If vendor adapter is still in demo credentials: the operator must go through the
   integration re-authentication flow in the Operator Web Console to supply live credentials.
5. Ask the operator to hard-refresh the Operator Web Console and mobile app to clear
   cached demo state.

Note: demo mode is a writer-side switch (Hard Promise 2); the same SQLite tables and
Postgres reads serve both modes. Disabling demo mode does not change historical data —
it only changes whether new sync writes accept live payloads.

---

### Pepper Rotation Drill

Symptoms (planned): a pepper rotation is scheduled; this is not an incident but a
planned maintenance action. Follow `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.

If a pepper rotation is required as an emergency (e.g. a pepper has been compromised):
1. Immediately halt all auth operations: disable Cloud Run proxy by scaling to 0 replicas.
   ```
   gcloud run services update forge-flow-proxy --max-instances=0 --region=__REGION__
   ```
2. Follow `runbooks/admin_provider_credentials_kms_rollout_runbook.md` emergency section.
3. Rotate in Secret Manager, redeploy with new pepper, re-enable proxy.
4. Invalidate all active auth sessions to force re-authentication with the new pepper:
   ```sql
   UPDATE auth_sessions SET revoked_at = now(), revoke_reason = 'pepper_rotation'
   WHERE revoked_at IS NULL;
   ```
5. Notify all operators that they will need to re-log in.

---

### OAuth Mass Revocation

Symptoms: `oauth_refresh_failures` alert; `oauth.refresh.failed` events spanning multiple
operators for the same `vendor_slug`.

Steps:
1. Confirm the vendor and scope of revocation:
   ```
   gcloud logging read \
     'jsonPayload.event="oauth.refresh.failed"' \
     --format=json \
     --limit=50 | jq '.[] | .jsonPayload.fields | {vendor_slug, operator_id, error}'
   ```
2. If failures are across > 3 operators for the same vendor slug: this is a mass revocation.
   The vendor has likely rotated their OAuth app secret or revoked F&F's app registration.
3. Contact the vendor's developer support portal immediately to confirm the cause.
4. Pause polling for the affected vendor to stop retry storms:
   ```sql
   UPDATE forge_flow_polling_tier_assignments
   SET tier = 'paused', paused_reason = 'oauth_mass_revocation_investigation'
   WHERE vendor_slug = '<slug>';
   ```
5. Once the vendor confirms new credentials or app re-registration:
   - Update Secret Manager with the new client_secret.
   - Redeploy the proxy (or trigger a config reload if hot-reload is supported).
   - Resume polling:
     ```sql
     UPDATE forge_flow_polling_tier_assignments
     SET tier = 'standard', paused_reason = NULL
     WHERE vendor_slug = '<slug>';
     ```
6. Notify all affected operators that their integration was temporarily paused and is now restored.

---

## Escalation Path Matrix

| Condition | Escalation |
|-----------|-----------|
| P1 alert — ack'd within 10 min, resolved within 1h | Primary on-call handles solo |
| P1 alert — not ack'd within 10 min | Secondary on-call paged automatically |
| P1 alert — not ack'd within 20 min | Executive escalation (Said Khan) paged |
| P1 open > 4 hours | Status page incident post; executive bridge call |
| `chain_hash_mismatch` in audit logs | SECURITY INCIDENT — executive escalation immediate, do not wait |
| Pepper compromise | Emergency: halt proxy immediately; executive escalation; notify operators |
| Data loss suspected | Halt writes; start PITR assessment; executive escalation |
| Vendor outage > 2h with no ETA | Notify operators; post status page update; no code change needed |

---

## Cost Controls

AI usage cost spikes are handled by the `cost_spike_per_operator` alert. During the watch:

1. Monitor the Cloud Monitoring cost-spike dashboard daily.
2. If any operator hits 80% of their daily hard cap: proactively contact the operator.
3. If a runaway loop is detected (rapid repeated AI calls in < 1 min intervals):
   ```sql
   -- Immediately cap to zero:
   UPDATE usage_caps
   SET hard_cap_tokens = 0
   WHERE operator_id = '<uuid>' AND cap_class = 'advisor_default';
   ```
   Restore after investigation and root-cause fix.
4. Track AI cost per operator in the daily check to confirm the 7-day rolling average
   stays within the 75–95% margin target (Hard Promise 9).
