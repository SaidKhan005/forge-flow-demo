# Per-Vendor Doc Pack Contract

Status: Active
Updated: 2026-05-03
Owner: Phase 8 / 8R / 8.S framework lane
Authority: Tier-2 contract (binds every Phase 8 / 8R / 8.S adapter slice)

This contract is the shape of the per-vendor folder every adapter
slice ships at `docs/integrations/<vendor_id>/`. The folder is the
**review contract** Codex grades the adapter code against — every
assumption the adapter makes about the vendor is documented here so
the `*.live` slice can diff documented vs observed.

The companion contract is `docs/contracts/vendor_adapter_slice_contract.md`
which specifies the framework rules and lifecycle.

The folder template lives at `docs/integrations/_template/`. Adapter
slices copy that folder, rename to `docs/integrations/<vendor_id>/`,
and fill in every section.

## Folder shape (binding)

```
docs/integrations/<vendor_id>/
├── api_consumed.md             — endpoints + auth + pagination + rate limits
├── field_mapping.md            — vendor field → canonical fact field
├── oauth_shape.md              — OAuth flow / token lifetime / refresh
├── webhook_signature.md        — algorithm + header + encoding + replay
├── live_verification_checklist.md   — what *.live verifies
└── partnership_status.md       — commercial lane status
```

`<vendor_id>` matches the stable vendor key in
`connector_connection.vendor_id` and `VendorCapabilityProfile.vendorId`
(e.g., `lightspeed_lsk`, `quickbooks_time`, `seven_shifts`).

## File-by-file requirements

### 1. `api_consumed.md`

Required sections:

- **Source documentation.** URL of the vendor's developer docs +
  retrieval date. CI lint warns if older than 180 days.
- **Auth method.** OAuth 2.0 / API key / legacy username+password /
  bearer token / mutual TLS. Cite the section in the source doc.
- **Endpoints consumed.** One row per endpoint:
  | Method | Path | Purpose | Rate limit | Pagination shape |
- **Sandbox / test environment.** Base URL, sign-up steps, known
  limitations (e.g., "Lightspeed sandbox does not emit webhooks for
  voided checks"). If no sandbox exists, document the workaround
  (e.g., "Toast sandbox requires Standard API tier sign-up").
- **Production environment.** Base URL, partnership requirements,
  rate-limit policy.
- **Versioning.** API version pinned by the adapter; vendor's
  deprecation policy.

Codex grades: every endpoint listed must be invoked by the adapter
code; every endpoint invoked by the adapter code must be listed. Diff
is automatable.

### 2. `field_mapping.md`

Required sections:

- **Source field → canonical field table.** One row per canonical
  field the adapter populates:
  | Vendor field path | Type / shape | Canonical field | Transform | Doc URL |
- **Covers source classification.** `direct` (vendor exposes covers)
  / `forecast_fallback` (no covers field) / `not_applicable` (labor /
  reservation). Cite vendor doc.
- **Timestamp shapes.** For each timestamp consumed, document:
  format (ISO 8601 / Unix epoch / vendor-specific), timezone (UTC /
  vendor-account-tz / location-local), policy doc reference
  (`vendor_timestamp_policy.dart` entry).
- **Ambiguity calls.** Per-field decisions where the doc was unclear
  and the adapter made a choice. The `*.live` slice will verify these
  first.
- **Forbidden fields.** Any vendor field the adapter intentionally
  ignores (e.g., guest names per privacy policy).

Codex grades: every canonical field the adapter writes must have a
row here; every row here must be referenced in the adapter source as
`documented_per_<vendor>_<api_version>_<doc_url>` constant.

### 3. `oauth_shape.md`

Only required for vendors with `authMode = oauth | oauthOrKeyPaste`.
For pure key-paste / legacy-auth vendors, write a one-line "N/A —
auth shape documented in `api_consumed.md`."

Required sections:

- **Flow type.** Authorization code / client credentials / hybrid.
- **Scopes.** Exact scope strings the adapter requests; what each
  unlocks; minimum-privilege subset chosen.
- **Token lifetime.** Access token TTL; refresh token TTL; rotation
  semantics (rotating vs sliding).
- **Refresh semantics.** When to refresh proactively (cron at
  `token_expires_at - 1h`); behavior on 401 (refresh once + retry);
  behavior on 3 consecutive failures (flip status to `error`).
- **Per-location vs operator-wide grant.** Match
  `VendorCapabilityProfile.grantScope`; explain how the vendor scopes
  a single grant.
- **Module disambiguation.** ADP / QuickBooks only — explain how the
  adapter detects module from the auth response.
- **Edge cases.** Refresh token expiry; revocation; account deletion;
  unknown errors. Each with the adapter's intended behavior.

Codex grades: scope list matches OAuth start route; refresh cron
behavior matches `oauth_refresh_cron.dart` documented intent; module
disambiguation matches `connect()` implementation.

### 4. `webhook_signature.md`

Only required for vendors with `webhookSupport = autoRegister | manualPaste`.
For pure `pollOnly` vendors, write "N/A — vendor does not support
webhooks per `api_consumed.md`."

Required sections:

- **Algorithm.** HMAC-SHA256 / HMAC-SHA1 / RSA-PSS / etc. Cite vendor
  doc.
- **Signed payload.** Raw body / body+timestamp / body+headers. Exact
  byte sequence the HMAC is computed over.
- **Encoding.** Base64 / hex / raw bytes. Case sensitivity.
- **Header name.** Exact header the signature arrives in
  (`Toast-Signature`, `X-Lightspeed-Signature`, etc.).
- **Timestamp header.** Header that carries the signing timestamp;
  format (Unix epoch / ISO 8601). The replay window enforces against
  this header.
- **Replay tolerance.** Adapter uses 24h tolerance per V1 lean cut 2;
  document if this vendor needs a tighter window for any reason.
- **Constant-time compare.** Confirm adapter uses
  `constantTimeBytesEquals`; cite the verifier file.
- **Auto-register endpoint** (for `autoRegister` vendors). The vendor
  API endpoint the adapter calls to register the webhook URL.
- **Manual paste instructions** (for `manualPaste` vendors). The
  operator-facing copy that explains where to paste the URL +
  signing secret in the vendor's portal.

Codex grades: the `VendorWebhookSignatureVerifier` implementation
matches every parameter documented here.

### 5. `live_verification_checklist.md`

Required sections — each row is a checkbox the `*.live.sandbox` and
`*.live.prod` slices toggle:

- [ ] **Auth round-trip.** OAuth start → callback → token issued.
- [ ] **Token refresh.** Refresh cron extends a near-expiry token.
- [ ] **Test connection.** Heavy sample-pull returns under 30s with
      `fieldMapping` populated.
- [ ] **Backfill 60-day window.** First-connect backfill writes
      ≥1 canonical fact row; watermark persists per batch.
- [ ] **Polling resume.** Worker restart resumes from persisted
      cursor (no rewind, no skip).
- [ ] **Webhook signature verification.** Live signature accepted;
      tampered signature rejected with 403.
- [ ] **Idempotency.** Same vendor event ID twice → single canonical
      write.
- [ ] **Sanity hook.** Future-dated event from live vendor →
      sanity_log row + drop.
- [ ] **Field-mapping diff.** Observed vendor response matches every
      `documented_per_<vendor>_*` constant in fixtures. List
      discrepancies as bounded fixes (not slice rebuilds).
- [ ] **Disconnect → reconnect.** Watermark preserved across cycle;
      no data gap on reconnect.
- [ ] **Permission gate.** `location_manager` 403; `operator_admin`
      200.
- [ ] **Demo-mode flip.** First connect + first backfill commit
      flips `demo_mode_state.is_demo` to `false`.
- [ ] **Operator dashboard chrome.** `MetricCardNotYetAvailable`
      flips to live number; top-left pill drops the corresponding
      degradation line.

The engineering slice ships this file with all checkboxes empty. The
`*.live.sandbox` slice fills them in for sandbox; `*.live.prod`
re-runs the checklist against production.

Codex grades: every row above must be present (no rows dropped); rows
checked must cite the test that proved them.

### 6. `partnership_status.md`

Owner: ops (not engineering). Engineering slices ship a stub; ops
updates as the commercial lane progresses.

Required sections:

- **Partnership program name.** Exact program name + tier
  (e.g., "Toast Partner — Standard Tier"; "ADP Marketplace Developer
  Participation Agreement").
- **Application status.** `not_started` / `applied` / `under_review` /
  `cleared` / `denied`. Cite date of last update.
- **Production credentials issued.** Y/N + date if Y.
- **Owner.** Person on ops side driving the application.
- **Estimated lead time remaining.** Realistic estimate; updated
  monthly.
- **Blockers.** Any commercial blocker (vendor-side review pending,
  pricing-tier negotiation, etc.).

Lifecycle promotion to `production_credentialed` requires this file
to show "Production credentials issued: Y" + date. The `*.live.prod`
slice's prompt MUST cite this file.

## Authoring contract

- Each file's top-of-file comment cites doc URL + retrieval date.
- Every claim cites a vendor doc URL.
- Tables use the column shapes above (no improvised shapes).
- The folder is filled in **as part of the engineering slice**, not
  as a follow-up. A slice missing the doc pack is `FOLLOW-UP NEEDED`.

## Versioning the doc pack

When the vendor changes API shape (new endpoint, removed field,
auth-shape change), the next adapter slice:

1. Updates the affected file(s) with new doc URL + retrieval date.
2. Diffs against the prior version in git history (the history is the
   audit trail; no separate changelog).
3. Bumps `documented_per_<vendor>_<api_version>` constants in the
   adapter fixtures.
4. Triggers a follow-up `*.live.sandbox` slice if the change affects
   field mapping or auth shape.

CI lint warns if any `api_consumed.md` retrieval date is older than
180 days without a `*.live.sandbox` re-verification in that window.

## Cross-references

- `docs/contracts/vendor_adapter_slice_contract.md` — framework rules
  the adapter code is graded against.
- `docs/integrations/_template/` — the template every adapter copies.
- `docs/phases/phase_8/vendor_master_list.md` — the 17 INTEGRATE
  vendors + Wave B / Wave D plan.
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md` — vendor adapter slice
  prompt template.
