# Phase 8.5 — External Integrations Lane

Updated: 2026-04-26
Status: Planned (opens between `8R` and Phase 12)
Owner: Future external integrations lane

This plan describes the **outbound** integration lane: F&F's proxy backend
calls operator's external systems (accounting, invoicing, banking) on the
operator's behalf. This is distinct from Phase 8 / 8R, which cover **inbound
ingestion** transport for POS / labor / reservation systems.

Architecture rationale, `IntegrationProvider<T>` abstraction, and Phase 12
consumption pattern: `phase_11a/phase_11a_decision_register.md`.

## Why Phase 8.5 exists

Phase 12's flagship Weekly P&L workflow needs accounting + invoicing data
that Phase 8 / 8R don't cover. Each new external integration is 2-4 weeks
of engineering work and follows a common pattern, so they live in their own
lane between the existing connector phases (which target POS / labor /
reservation transport-swaps) and Phase 12 (which consumes integrations from
all phases).

## Goal

Build the `IntegrationProvider<T>` abstraction and ship the four launch
integrations needed for Phase 12.0-12.5 flagship workflows.

## Non-Negotiables

- All outbound integration calls go through `IntegrationProvider<T>`. Direct
  `package:http` to vendor APIs is forbidden outside
  `lib/infrastructure/integrations/` — CI lint enforces (mirror of the
  repository-pattern enforcement for Postgres).
- Per-operator vendor credentials live in the cloud Postgres
  `vendor_credentials` table with encrypted columns
  (`pgcrypto` envelope OR Cloud KMS). Tokens never logged in plaintext.
- All vendor responses cached at the proxy where the vendor permits, with
  TTL aligned to data freshness expectations (e.g., POS sales 5-15 min;
  accounting GL 24h).
- Webhook subscription preferred over polling where the vendor supports it.
- Per-operator integration enable / disable controlled via `feature_flags`.
- Each integration provides a "test connection" diagnostic exposed in
  `11A.4` Integration management.
- Per-task wallclock + cost caps on integration-heavy workflows enforced by
  Phase 12 runtime.

## Scope

Phase 8.5 owns:

- **`IntegrationProvider<T>` abstraction** in `lib/services/` mirroring the
  `LLMProvider` / `EmbeddingProvider` shape
- **`vendor_credentials` schema + repository** with encrypted at-rest storage
- **Per-operator OAuth flow handler** (Cloud Run admin endpoints under
  `/v1/admin/integrations/*`) for vendors that use OAuth (QBO, Xero,
  Bill.com, Plaid all use OAuth 2.0)
- **Token refresh worker** in Cloud Run jobs sibling service; `pg_cron`
  schedules refresh checks
- **Webhook ingestion endpoints** under `/v1/webhooks/*` with signature
  verification per vendor
- **Vendor-specific adapter modules** (one per vendor):
  - QuickBooks Online (QBO)
  - Xero (alternative accounting)
  - Bill.com (or MarginEdge — vendor TBD per operator demand)
  - Plaid (banking feed; optional)

Phase 8.5 does NOT own:

- Inbound ingestion transport for POS / labor / reservation (Phase 8 / 8R)
- Workflow execution runtime (Phase 12.0)
- Accounting / invoicing UI (Phase 12.x catalog workflows consume the data)
- Payment processing (out of scope; if needed, separate phase)

## Sub-Slice Sequence

### `8.5.0` IntegrationProvider Abstraction + Schema (~1-2 weeks)

- `IntegrationProvider<T>` interface in `lib/services/integration_provider.dart`
- `vendor_credentials` table (schema in cloud Postgres):
  ```sql
  vendor_credentials(
    credential_id UUID PRIMARY KEY,
    operator_id UUID NOT NULL,
    location_id UUID,                  -- nullable for operator-wide creds
    vendor_id TEXT NOT NULL,            -- 'qbo', 'xero', 'bill_com', 'plaid'
    auth_type TEXT NOT NULL,            -- 'oauth2', 'api_key'
    encrypted_access_token BYTEA,
    encrypted_refresh_token BYTEA,
    token_expires_at TIMESTAMPTZ,
    metadata JSONB,                     -- vendor-specific fields
    is_active BOOL DEFAULT true,
    created_at, updated_at, created_by, updated_by
  )
  ```
- `OperatorScopedRepository<VendorCredential>` for safe access
- Encryption envelope using `pgcrypto` at MVP; promote to Cloud KMS at scale
- RLS policies extend existing operator/location pattern
- CI lint rule: `package:http` and `package:dio` raw imports forbidden
  outside `lib/infrastructure/integrations/`

### `8.5.1` OAuth Flow Handler + Token Refresh (~1-2 weeks)

- Proxy endpoints `/v1/admin/integrations/oauth/{vendor}/start` and
  `/v1/admin/integrations/oauth/{vendor}/callback`
- Per-vendor OAuth client credential in Cloud Run env / KMS
- **Token refresh `pg_cron` job (Lock 10 in
  `phase_11a_decision_register.md` Production Hardening Locks)**:

  ```sql
  SELECT cron.schedule(
    'vendor_token_refresh',
    '5 * * * *',  -- 5 minutes past every hour
    $$SELECT proxy.refresh_expiring_vendor_tokens()$$
  );
  ```

  `proxy.refresh_expiring_vendor_tokens()` body:

  ```
  For each row in vendor_credentials WHERE
    is_active = true AND token_expires_at < now() + interval '24 hours':
    - Call IntegrationProvider.refresh(vendor_id, refresh_token) via
      proxy
    - On success: update access_token + refresh_token + expires_at,
      append vendor_credential_audit row
    - On failure: increment retry_count; if retry_count >= 3, mark
      is_active = false; emit cap-event-style notification to F&F admin
      via 11A.4 Integration Management
  ```

  This prevents silent token expiry → workflow failure mid-execution.
  Stale credentials surface visibly in 11A.4 instead of breaking
  workflows at run time.

- `11A.4` Integration management surfaces:
  - "Connect QBO" / "Connect Xero" / etc. buttons
  - Connection status (active / token expiring / disconnected /
    refresh failed)
  - "Test connection" diagnostic
  - "Disconnect" tearing down the credential row
  - Notifications when a connection's token refresh fails 3× in a row

### `8.5.2` QuickBooks Online Adapter (~2-3 weeks)

The flagship integration. Phase 12.4 Weekly P&L workflow blocks on this.

`IntegrationProvider<QboClient>` exposes:
- `fetchTransactions(operator, location, dateRange)` — GL transactions for
  P&L computation
- `fetchInvoices(operator, location, dateRange)` — AR invoices
- `fetchBills(operator, location, dateRange)` — AP bills
- `fetchAccounts(operator)` — chart of accounts
- `fetchCustomers(operator)` — customers (for payment categorization)
- `fetchVendors(operator)` — vendors (for AP categorization)

Webhook subscription for new transactions where QBO supports it (reduces
polling). Otherwise daily sync via Cloud Run job.

### `8.5.3` Xero Adapter (~2 weeks)

Same shape as QBO. Operator picks one; not both. Faster to ship after QBO
adapter establishes the pattern.

### `8.5.4` Bill.com or MarginEdge Adapter (~3 weeks)

Vendor selection driven by operator demand. Bill.com has stronger AP
automation; MarginEdge is restaurant-specific (recipe costing, menu
engineering).

### `8.5.5` Plaid Banking Feed (~2 weeks; optional)

For cash reconciliation. Lights up only if Phase 12 workflow demand
justifies. Lower priority than accounting integrations.

## Acceptance

Per sub-slice:
- Integration adapter passes contract tests against vendor sandbox
- OAuth flow round-trips successfully
- Token refresh proven on a near-expiry token
- `11A.4` Integration management shows connection status accurately
- "Test connection" diagnostic returns within 5s
- Phase 12 workflow consuming this integration succeeds end-to-end on
  staging

## Dependencies

- `11a.11c-e` complete (Azure DB live; vendor_credentials schema applies
  cleanly)
- `11A.0-6` complete (Integration management UI lives in 11A.4)
- Phase 9 RLS active (per-operator credential isolation)
- Phase 9.8 in-flight (T&Cs covering operator's authorization for F&F to
  call their accounting/banking systems on their behalf)
- Vendor sandbox / developer accounts provisioned (QBO, Xero, Bill.com,
  Plaid all have free dev tiers)

## Source Material

- `phase_11a/phase_11a_decision_register.md` — `IntegrationProvider`
  abstraction, vendor credentials posture
- Phase 8 / 8R plans — inbound transport pattern this lane mirrors
- Phase 12 workflow platform plan — consumer of this lane
- QuickBooks Online API docs
- Xero API docs
- Bill.com API docs
- Plaid Link / Transactions API docs
