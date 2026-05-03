# Proxy Rollback Runbook

Owner: Platform / On-call
Updated: 2026-05-03
Source: HARD-G observability-baseline contract

This runbook covers the advisor proxy on Cloud Run. It tells the
on-call what symptoms warrant a rollback, which knob to pull first,
and how far back the rollback can safely go.

## 1. When to rollback

Roll back when at least one of the following is sustained for ≥5 min:

- **HTTP 5xx rate ≥10%** on `/v1/...` requests (Cloud Run revision
  metrics or `proxy.unhandled_error` log volume).
- **Audit chain hash mismatch** — `tool/audit_anchor/verify` reports
  `chain_break: true` for the latest anchor (see §5).
- **Breaker open sustained** — `circuit_breaker_anthropic_state` or
  `circuit_breaker_voyage_state` stays open for two consecutive
  scrape windows AND the upstream is healthy elsewhere (other
  customers green).
- **Login lockout false positives** — sustained spike in
  `auth.login.locked` events for accounts that succeeded recently;
  cross-check with operator reports.
- **Startup misconfig signal** — a fresh revision emits
  `startup.kms_misconfigured` or `startup.config_invalid` and exits
  78. This blocks traffic before it ever reaches the new revision,
  so "rollback" here means routing 100% of traffic to the prior
  revision.

If only one signal trips and an upstream provider is degraded
(Anthropic / Voyage status page red), prefer the feature-flag knob
in §3 over a revision rollback.

## 2. Cloud Run revision rollback

The proxy keeps every revision; rollback flips traffic, it never
deletes.

```bash
# Confirm the service name and the prior revision id.
# Staging:     SERVICE=forge-flow-staging-proxy PROJECT=forge-flow-staging
# Production1: SERVICE=forge-flow-production1-proxy PROJECT=forge-flow-production1
REGION=northamerica-northeast2

gcloud run services describe "$SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(status.traffic[].revisionName)'

# 100% to the prior good revision.
gcloud run services update-traffic "$SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --to-revisions <PRIOR_REVISION>=100
```

Prereqs:

- `gcloud` authed against the prod project; you have
  `roles/run.admin` (or call out to whoever does).
- A "prior good revision" — the latest revision whose `Ready` is
  green and whose deploy predates the incident window.
- The prior revision is still inside Cloud Run's revision retention
  (default: indefinite for traffic-receiving revisions).

After traffic flips, watch the next 10 min of
`proxy.unhandled_error`, breaker state, and 5xx rate. If they
re-trip on the older revision, the failure is not in code — escalate
to upstream provider / database investigation instead of chasing
revisions further back.

## 3. Feature-flag rollback

Some symptoms are addressable without a revision flip. Toggle the
relevant kill-switch in `feature_flags` (admin UI or direct SQL via
`POSTGRES_ADMIN_URL`). Effect is immediate — no redeploy.

| Flag | Disable when | Effect |
|------|--------------|--------|
| `audit_logs_cutover_enabled` | audit-write storms | falls back to legacy single-table audit path |
| `kms_real_provider_<kind>_enabled` | Secret Manager errors on a specific lane | that lane returns to `KmsStubProvider` |
| `cache_telemetry_v2` | `corpus_invalidation_events` write spam | telemetry rows stop being written |
| `gemini_secondary_enabled` | Gemini secondary returning bad text | `AdvisorRequestPipeline` skips secondary, falls through to refusal |

```sql
-- Example: kill the Anthropic KMS rollout.
update feature_flags
   set is_enabled = false,
       updated_at = now()
 where flag_key = 'kms_real_provider_anthropic_enabled';
```

If the killed flag is the *only* remediation needed, do **not**
revision-rollback — the flag is the rollback. Document the flip in
the incident channel so the next deploy doesn't accidentally re-arm
it.

## 4. DB migration rollback boundaries

Migrations live in `db/migrations/` and apply forward-only via the
deploy pipeline. Some changes cannot be undone:

- **`audit_chain_anchors`** — append-only by design; rows are
  signed and chained. Never `DELETE`. A botched migration that
  *adds* anchors must be addressed by writing a forward-fix
  migration that flags them as `repudiated` plus an operational
  note in the next anchor's payload.
- **`pg_partman` retention** — the retention worker drops
  partitions older than the configured window. Once dropped, the
  rows are gone; they cannot be restored from a code rollback. The
  ~14-day rollback window applies only to data still inside that
  window.
- **DDL with `DROP COLUMN` / `DROP TABLE`** — irreversible without
  a Postgres point-in-time restore. Requires a forward-fix
  migration plus, if data was dropped, coordination with the
  backup operator before any DR action.

Rollback-safe migrations: additive column adds (`ADD COLUMN ...
NULL`), new tables, new indexes (CONCURRENTLY), new feature-flag
rows. These can be paired with a Cloud Run revision rollback that
ignores the new column / table cleanly.

If the failing change is *not* rollback-safe, do not undo the
migration — write the forward fix and ship a new revision.

## 5. Anchor verification

Run the verifier after any rollback that touches audit code or the
audit DB. The CLI lives in `tool/audit_anchor/main.dart`; it takes
`verify` as the mode and the operator id / chain date as `key=value`
flags (the parser does not accept space-separated forms):

```bash
dart run tool/audit_anchor/main.dart verify \
  --operator-id=<OPERATOR_UUID> \
  --chain-date=$(date -u +%Y-%m-%d)
```

A clean run prints `audit_anchor: ok <operator-id> / <chain-date>`
to stdout and exits 0. Any non-zero exit indicates a verification
failure — the CLI emits `result.outcome.name` (the camelCase
`VerifyOutcome` enum), so the actual stderr lines an operator
should grep for are:

- `audit_anchor: chainHashMismatch …`
- `audit_anchor: anchorMissing …`
- `audit_anchor: anchorTerminalMismatch …`
- `audit_anchor: blobEvidenceMismatch …`

Capture the offending `(operator_id, chain_date)` pair and escalate;
do not roll forward until the chain is either repaired or formally
repudiated.

The full verifier protocol — including chain repair guidance and
escalation contacts — lives at `runbooks/audit_chain_verify_runbook.md`.
If the verifier fails to start, inspect `audit_logs` for the last
hour and look for unexpected gaps in `created_at` — gaps suggest a
missing partition rather than a chain break.

## 6. Communication

- **Incident channel** — `#forge-flow-incidents` in Slack. Pin the
  Cloud Run revision id (old + new) and the timestamp of the
  rollback action.
- **Post-mortem** — open a Linear issue under the
  `INFRA / Incidents` project within 24 h. Link the relevant
  Cloud Logging query
  (`severity>=ERROR AND jsonPayload.event="proxy.unhandled_error"`)
  and the anchor verifier output.
- **Stakeholder ping** — if customer-visible symptoms lasted ≥10 min
  or any operator hit a hard error, notify Vanessa (product) and
  the on-call engineer for the next sprint owner. Use the standing
  template in `#forge-flow-incidents` pinned message.
- **Provider status** — when the proximate cause was an upstream
  provider, file the support ticket from the proxy's POV (request
  ids + correlation ids from `proxy.unhandled_error` logs); never
  share secrets in the ticket body.

End. Length cap: 200 lines. This runbook is referenced from
`docs/contracts/hardening_observability_baseline_contract.md` §
"Required — Rollback Runbook".
