# Forge & Flow On-Call Rotation

Updated: 2026-05-07.
Owner: F&F engineering operations.
Applies from: `cutover.4` stability watch onward.

## Rotation Members

| Role | Name | Contact | Notes |
|------|------|---------|-------|
| Primary on-call | Vanessa | PagerDuty: `@vanessa` | First page target |
| Secondary on-call | TODO — assign before `cutover.4` | PagerDuty: `@tbd` | Pages if primary does not ack in 10 min |
| Executive escalation | Said Khan | saidumarkhan005@gmail.com | Pages if secondary does not ack in 20 min |

TODO: Replace `@tbd` above with the real secondary before `cutover.0` preflight.

## Coverage Policy

Coverage is 24/7 with no exceptions during the `cutover.4` 7-day stability watch.

- Primary on-call is responsible for acknowledging P1 alerts within 10 minutes.
- Secondary on-call is backup; they are expected to be available and responsive during
  their window, even if not actively working.
- Executive escalation is contacted only when neither primary nor secondary has acknowledged
  within the combined 20-minute window. Executive escalation does not replace technical triage;
  they are the authority to make resourcing or business-impact decisions.
- Off-hours pages are real; on-call members must have PagerDuty mobile app push notifications
  enabled with high-priority override enabled on iOS/Android.

## Escalation Policy

The PagerDuty escalation policy is named `forge-flow-v1-oncall` and follows this sequence:

```
Alert fires
  └─> T+0 min  → Page primary on-call (Vanessa) via PagerDuty
  └─> T+10 min → If no ack: Page secondary on-call (TBD)
  └─> T+20 min → If no ack: Page executive escalation (Said Khan — saidumarkhan005@gmail.com)
  └─> T+60 min → P1 unresolved: auto-create incident in PagerDuty with "critical — executive bridge" tag
```

### Severity Routing

| Severity | Definition | Who is paged first | Ack window |
|----------|------------|-------------------|------------|
| P1 | Production down, data loss risk, compliance gap, silent degrade | Primary | 10 min |
| P2 | Degraded (some operators affected, no data loss) | Primary | 30 min |
| P3 | Warning / informational; monitor and track | Primary (no overnight page) | Next business day |

P1 alerts that remain unresolved for more than 4 hours trigger an automatic status-page incident
post (once `status.forgeflow.app` is live; see `runbooks/status_page_setup.md`).

## Hand-Off Ritual

At the end of each on-call shift:

1. **Write a shift summary** (3–10 lines):
   - Alerts fired: list each with severity, time, root cause, resolution.
   - Open issues: anything still in flight or needing follow-up.
   - System health snapshot: pool saturation %, outbox depth, last anchor success.

2. **Post summary to `#eng-oncall`** Slack channel (or equivalent team channel) with the tag
   `[SHIFT HANDOFF]` so the incoming on-call can find it.

3. **Confirm the incoming on-call is PagerDuty-active** before dropping coverage. Do not
   hand off to someone whose PagerDuty override is not in effect.

4. **If any incident is open**: do a live 5-minute verbal/call handoff. Do not hand off an
   active P1 via async message only.

5. **Update the shift log** in `docs/ops/oncall_shift_log.md` (create the file if not present)
   with one line per shift:
   ```
   2026-05-07T00:00Z – 2026-05-08T00:00Z | Primary: Vanessa | Alerts: 0 P1, 1 P2 | Notes: outbox spike at 02:00 UTC, resolved by restart
   ```

## Runbook Index

Use these runbooks for active incidents. The cutover stabilization runbook covers all
`cutover.4`-era incident types in one place.

| Incident type | Runbook |
|---------------|---------|
| Any `cutover.4` incident | `runbooks/phase_production_cutover/cutover_4_stabilization_runbook.md` |
| Audit anchor failure | `runbooks/audit_chain_verify_runbook.md` |
| Postgres PITR | `runbooks/postgres_pitr_drill_runbook.md` |
| Pre-flight gate | `runbooks/cutover_0_preflight_runbook.md` |
| KMS pepper rotation | `runbooks/admin_provider_credentials_kms_rollout_runbook.md` |
| GDPR erasure | `runbooks/gdpr_erasure_runbook.md` |
| Mobile push failures | `runbooks/phase_production_cutover/cutover_4_stabilization_runbook.md#fcm-mass-revocation` |
| OAuth mass revocation | `runbooks/phase_production_cutover/cutover_4_stabilization_runbook.md#oauth-mass-revocation` |
| Status page | `runbooks/status_page_setup.md` |
