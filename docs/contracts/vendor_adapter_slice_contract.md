# Vendor Adapter Slice Contract

Status: Active
Updated: 2026-05-03
Owner: Phase 8 / 8R / 8.S framework lane
Authority: Tier-2 contract (binds every Phase 8 / 8R / 8.S adapter slice)

This contract is the rule set every Phase 8 / 8R / 8.S vendor adapter
slice is graded against. Codex review uses this doc to gate ACCEPT.
The companion contract is `docs/contracts/per_vendor_doc_pack_contract.md`
which specifies the per-vendor folder Codex compares the adapter code
to.

The doctrine is: **engineer all 17 INTEGRATE vendors against documented
APIs in one push, lock each adapter at lifecycle = `documented`, then
fire `*.live` slices when sandbox / production credentials arrive.**
Locked 2026-05-03 (`memory/project_phase_8_engineer_all_17_doctrine.md`).

## The 3-step per-slice doctrine

Every vendor adapter slice ships in a **single PR** that performs all
three steps. None is optional; missing any one returns `FOLLOW-UP NEEDED`
or `REJECT` per Codex review:

1. **Online API check** — verify the vendor's developer documentation
   is current. Capture the doc URL + retrieval date in the per-vendor
   `api_consumed.md`. If the doc is older than 180 days or the vendor
   has changed shape since the prior `*.live` verification, flag it
   in the slice's execution report.
2. **Framework engineering** — implement the adapter against the
   documented API shape; bind to the framework seams below; ship
   fixture-based tests that prove every framework call.
3. **Docs synthesis** — populate `docs/integrations/<vendor_id>/`
   with the 6-file doc pack per `per_vendor_doc_pack_contract.md`.
   Every assumption the adapter makes about vendor shape is captured
   here so the `*.live` slice can diff documented vs observed.

A slice that ships steps 1 + 2 but skips step 3 is incomplete; the
doc pack is the contract the `*.live` slice grades against.

## The 4-state lifecycle (binding)

Every adapter lives in one of these states at any point in time. The
state is canonical truth and surfaces in the Vendor Connections admin
widget (`docs/phases/phase_8/vendor_connections_admin_surface.md`):

| State | Engineering | Partnership | Vendor picker chrome (operator + admin) |
|---|---|---|---|
| `documented` | adapter shipped, fixture-tested, doc pack populated | not yet started OR in progress | "Coming soon" pill, no Connect button |
| `sandbox_verified` | `*.live.sandbox` slice has run against vendor sandbox; field mapping confirmed | parallel commercial lane open | "Coming soon — sandbox verified" pill, no Connect button |
| `production_credentialed` | `*.live.prod` slice has run against production credentials issued by partnership | partnership cleared, prod keys issued | Connect button live |
| `live_with_operators` | unchanged from `production_credentialed`; activated when first operator connects | unchanged | Connect button live + connected-operator chip in F&F Ops Console |

The engineering slice (step 1-3 above) ships the adapter at lifecycle
= `documented`. The `*.live.sandbox` slice promotes to `sandbox_verified`.
The `*.live.prod` slice promotes to `production_credentialed`. First
operator connect promotes to `live_with_operators` automatically (no
slice required).

The lifecycle field lives on `VendorCapabilityProfile` (slice
`8.0.lifecycle` extends the existing boolean `partnershipGated` to a
`lifecycle: VendorLifecycle` enum and is the first item in Wave B).

## Mandatory framework calls (REJECT if missing)

These are the framework seams every adapter MUST honor. Codex tests
each one against the adapter's tests; missing any one is an automatic
REJECT.

### 1. Sanity hook on polling + backfill

```dart
// Every canonical fact write in pollIncremental + backfill MUST be
// gated by command.sanityHook. Webhook handler enforces sanity inline
// (step 4 of the dispatch sequence) — adapters MUST NOT re-call
// sanityHook in handleWebhook.

if (!await command.sanityHook(
  vendorEventId: row['vendor_id'],
  payload: row,
  isDeliberateBackfill: <true for backfill, false for poll>,
)) {
  // Framework already wrote sanity_log + connector_sync_log;
  // skip the canonical fact write.
  continue;
}
await repo.writeCanonicalFact(...);
```

Codex checks: fixture test that injects a fake `sanityHook`, verifies
`sanityHook.calls == records.length`, and verifies that returning
`false` from the hook skips the corresponding canonical write. See
`lib/services/integration/integration_adapter_common.dart` for the
`VendorSanityHook` typedef.

### 2. Idempotency UNIQUE on canonical fact upsert

Every canonical fact write upserts on
`(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`.
The same fact arriving via webhook AND polling is a no-op on the
second arrival. Out-of-order delivery is handled by last-write-wins
on `vendor_modified_at`.

Codex checks: fixture test that runs the same payload through the
adapter twice and asserts `repository.writes == 1` (or upsert log
shows 1 INSERT + 1 conflict-do-nothing).

### 3. Watermark per batch commit

`connector_sync_watermark.cursor_token` and `last_modified_seen` are
updated **after each successful batch insert**, NOT after the entire
backfill completes. On Cloud Run Job restart, the worker resumes from
the last persisted cursor.

Codex checks: fixture test that simulates a mid-backfill crash (e.g.,
adapter throws after batch 3 of 5) and asserts that the watermark
recorded before the crash matches batch 3's cursor.

### 4. Webhook signature verification (constant-time HMAC compare)

For vendors that sign webhooks, the adapter ships a
`VendorWebhookSignatureVerifier` that uses
`constantTimeBytesEquals` to avoid timing oracles. Replay defense is
24h tolerance (NOT 5-min strict — V1 lean cut 2 deleted the strict
window).

Codex checks: fixture test that submits a tampered signature and
asserts 403 + audit row + no canonical-fact write.

### 5. OperatorScopedRepository.withTenant for every fact write

Adapters MUST write canonical facts inside a tenant-scoped transaction
created by `OperatorScopedRepository.withTenant(operatorId, locationId, ...)`.
Adapters MUST NOT open their own database connections or bypass the
repository pattern. Plaintext credentials NEVER reach the adapter —
use `VendorCredentialHandle` (issued by `vendor_credentials_repository.dart`).

Codex checks: source review for `package:postgres` import (BANNED
outside `lib/infrastructure/persistence/postgres/`) + grep for
`vendor_credentials.*plaintext` (BANNED).

### 6. Capability profile declares everything

The adapter's `VendorCapabilityProfile` MUST declare:
- `vendorId` (stable string matching `connector_connection.vendor_id`)
- `displayName` (operator-facing, exact string from vendor brand)
- `category` (pos / labor / reservation)
- `authMode` (oauth / keyPaste / oauthOrKeyPaste)
- `grantScope` (perLocation / operatorWide)
- `webhookSupport` (autoRegister / manualPaste / pollOnly)
- `coversFieldExposed` (true / false — false triggers forecast fallback)
- `lifecycle` (documented at slice ship; promoted by `*.live.*` slices)
- `modules` (non-empty for ADP / QuickBooks; empty otherwise)
- `timestampPolicyDocId` (per-vendor timestamp policy doc reference)

Codex checks: source-level assertion that every field is non-default
and matches the vendor's documented behavior.

## Banned items (V1 lean cut 2 — REJECT if present)

Per `memory/project_v1_lean_cut_2_2026_05_03.md`:

| Banned | Why deleted | If present in adapter |
|---|---|---|
| KMS code path / production-key rotation logic | env-var keys are V1; KMS is post-launch hardening | REJECT |
| Webhook key rotation UI | operators won't use it at V1 | REJECT |
| `parse_warnings` JSONB column / `parse_partial` flag | malformed payloads drop with one log row | REJECT |
| 5-minute strict replay window | vendor retries commonly exceed 5min | REJECT (must be 24h) |
| OAuth advisory locks (`pg_try_advisory_lock`) | low-cadence cron has no contention at V1 scale | REJECT |
| Custom SIGTERM graceful drain handler | watermark-per-batch makes restart resilient | REJECT |
| Inbound webhook DLQ tile widget / mount | log rows + admin SQL is enough | REJECT |
| Raw-payload sibling partitioned tables / pg_partman raw partitions | single JSONB column on canonical fact is enough | REJECT |
| 5-second test-connection SLA | vendor sandboxes can't honor it; ~30s timeout is fine | REJECT (must allow ≥30s) |
| 3-strike auto-disable email wiring | path can exist, email wiring is deferred to 9.8.email follow-up | FOLLOW-UP NEEDED |

## Mandatory test discipline

Each adapter slice ships these tests at minimum:

1. **Sanity hook call count** — fake hook + assert calls == records.
2. **Sanity hook reject path** — fake hook returning `false` + assert
   no canonical write.
3. **Idempotency replay** — same payload twice + assert single write.
4. **Watermark mid-batch resume** — simulated crash + assert resume
   cursor matches last successful batch.
5. **Signature reject** — tampered HMAC + assert 403 + no write.
6. **Connect → backfill → poll → disconnect → reconnect** smoke —
   assert watermark preserved across disconnect / reconnect cycle.
7. **Module disambiguation** (ADP / QuickBooks only) — assert correct
   module accepted, incorrect refused.
8. **Test-connection** — fixture sample populates `fieldMapping`
   with covers + opened_at + closed_at (POS) / shift_start +
   shift_end + role_name (labor) / reservation_at + party_size +
   status (reservation). Completes in <30s on the offline path.

All tests are fixture-based. Live HTTP is the `*.live.sandbox` slice's
job, not this slice's. Fixtures cite the source doc URL + retrieval
date at the top of each fixture file.

## Mandatory walkthrough

Every adapter slice ships a click-path walkthrough at
`docs/_walkthroughs/<slice-id>.md` matching the bar set by
`docs/_walkthroughs/7.58.UX.5.md`:

- Numbered steps (1, 2, 3...).
- Each step names the user action ("tap X", "long-press Y").
- Each step names the expected visual state ("card flips green",
  "badge reads 'live'", "MetricCardNotYetAvailable widget renders").
- Named widget references (`Key('vendor_picker_lightspeed_lsk')`)
  when behavior depends on a specific widget.
- Named value expectations (`covers: 3`, `opened_at: 2026-05-02 18:45`)
  when behavior depends on a specific number.
- Demo-mode start condition (`kDemoMode=true`, business date,
  pre-existing connections).
- Anchor scenarios per the phase 8 plan (forged signature, malformed
  payload, future-dated event, OAuth near-expiry).

## Lifecycle promotion contract

The engineering slice promotes the vendor to lifecycle = `documented`.
The `*.live.sandbox` slice promotes to `sandbox_verified`. The
`*.live.prod` slice promotes to `production_credentialed`.

Each `*.live.*` slice is small (~200 LOC + walkthrough). It:

1. Reads the per-vendor doc pack at `docs/integrations/<vendor_id>/`.
2. Runs the actual HTTP requests (or webhook ingestion) against the
   live target (sandbox or prod) using the capabilities documented in
   `api_consumed.md`.
3. Diffs observed responses against the documented field-mapping
   constants captured in the engineering slice's fixtures.
4. Updates `live_verification_checklist.md` to mark each verification
   as ✅ or ❌. ❌ items become bounded fixes (not slice rebuilds).
5. Promotes the lifecycle on `VendorCapabilityProfile`.
6. Walkthrough at `docs/_walkthroughs/<vendor_id>.live.sandbox.md` (or
   `.live.prod.md`) shows operator-facing chrome change in the picker.

## Acceptance verdicts

- **ACCEPT** — all 6 mandatory framework calls present and tested;
  zero banned items; doc pack populated; walkthrough at click-path
  bar; lifecycle = `documented` set on capability profile.
- **FOLLOW-UP NEEDED** — bounded miss (e.g., one banned item present;
  one mandatory test absent; doc pack missing one of 6 files).
- **REJECT** — sanity hook not called; idempotency not enforced;
  plaintext credentials reach adapter; business logic in adapter;
  watermark not per-batch.

## Cross-references

- `docs/contracts/per_vendor_doc_pack_contract.md` — the 6-file
  folder shape Codex compares the adapter against.
- `docs/contracts/metric_card_honesty_contract.md` — operator-facing
  metric chrome rules (one top-left pill + `MetricCardNotYetAvailable`
  empty state; no per-card chrome).
- `docs/contracts/phase_7_55_time_boundary_contract.md` — UTC
  source-truth instant + denormalized business_date storage rule.
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` —
  RLS + `OperatorScopedRepository.withTenant` pattern.
- `docs/contracts/auth_permission_key_catalog.md` — `integrations.configure`
  permission key.
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — prompt shape;
  walkthrough specificity bar; vendor adapter slice template.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — POS
  framework + adapters.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` —
  Reservations.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` —
  Scheduling.
- `docs/phases/phase_8/vendor_master_list.md` — 17 vendor classification +
  Wave B engineering plan + `*.live` rolling rollout.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — operator
  + admin chrome that surfaces the lifecycle.
- `memory/project_phase_8_engineer_all_17_doctrine.md` — durable
  decision lock for engineer-all-17 + per-vendor folder shape.
- `memory/project_v1_lean_cut_2_2026_05_03.md` — banned items list.
- `memory/project_metric_honesty_doctrine.md` — operator-trust outcome
  anchor every adapter slice serves.
