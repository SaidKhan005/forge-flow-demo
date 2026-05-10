# Source

- URL (auth): https://docs.oracle.com/en/industries/food-beverage/simphony/omsstsg2api/authenticate.html
- URL (oauth_shape doc): docs/integrations/oracle_micros_simphony/oauth_shape.md
- URL (post-hardening note): docs/POST_HARDENING_FOLLOWUPS.md (Audit-additions
  section, 2026-05-08 confirmed-clean items — Simphony is OAuth)
- Retrieved: 2026-05-08
- API version: v2 (Simphony Transaction Services Gen 2 — STSGen2 Cloud API)

## Important — corrects the prompt's claim about Simphony auth

The prompt's wording "Simphony uses static API key + mTLS internally per
audit (no OAuth refresh closure)" is not what the doc pack and adapter
declare. Per `docs/integrations/oracle_micros_simphony/oauth_shape.md`
and `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart` line
180-191, Simphony's documented public Gen2 API uses OAuth 2.0
`client_credentials` grant, partner-issued `client_id` + `client_secret`,
short-lived bearer access token (~1h TTL). `pg_cron` refreshes any
`vendor_credentials` with `token_expires_at < now() + 24h`. There is no
refresh-token rotation — the adapter re-runs the token endpoint with the
durable client secret. mTLS is NOT mentioned in `api_consumed.md` /
`oauth_shape.md`; it may have been confused with ADP (which IS mTLS per
the audit).

This fixture therefore exercises the **standard OAuth near-expiry**
path. Phase 5 escalation note: confirm with ops/Codex whether the
prompt's mTLS claim came from a different audit thread; if Simphony
ever moves to mTLS in a future API revision, refresh this fixture.

- Adapter assertion at this fixture:
  - Token issued 2026-05-02T19:00:00Z, TTL 1h, expires 20:00:00Z. At
    poll time (`19:55Z`, 5 minutes until expiry), the adapter has two
    paths:
    1. The `pg_cron` job at 5 minutes past every hour scans
       `vendor_credentials` and refreshes anything within 24h; the
       refresh runs ahead of the poll and the poll uses the new token.
    2. If the token has actually expired by poll time, vendor returns
       401; adapter retries once after refreshing per
       `oauth_shape.md` "Reactive refresh on 401".
  - Either way the canonical fact at this fixture is written with the
    new token — the harness asserts a refresh row was written to
    `connector_sync_log` (kind `oauth_refresh`) AND the canonical
    fact for `chkNum = 412930` lands.
  - Three consecutive 401s (partner-portal revocation) flip
    `connector_connection.status = error`.
- Phase 5 escalation: partner-portal access needed to verify the token
  endpoint actually returns the documented `expires_in` and to confirm
  whether Simphony enforces minimum 1h granularity in production
  (sandbox is documented; prod numbers may vary).
