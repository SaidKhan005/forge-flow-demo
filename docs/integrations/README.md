# Per-Vendor Doc Packs

This tree holds the 6-file doc pack for each Phase 8 / 8R / 8.S vendor
adapter. The contract is `docs/contracts/per_vendor_doc_pack_contract.md`.

## Folder per vendor

```
docs/integrations/
├── README.md                     ← you are here
├── _template/                    ← copy this folder when authoring a new adapter
│   ├── api_consumed.md
│   ├── field_mapping.md
│   ├── oauth_shape.md
│   ├── webhook_signature.md
│   ├── live_verification_checklist.md
│   └── partnership_status.md
├── lightspeed_lsk/               ← Wave B
├── square/
├── toast/
├── clover/
├── revel/
├── aloha_ncr_voyix/
├── oracle_micros_simphony/
├── libro/
├── opentable/
├── sevenrooms/
├── tock/
├── quickbooks_time/
├── seven_shifts/
├── adp/                          ← multi-module: WFN + WFM
├── humanity/
├── push_operations/
└── agendrix/
```

17 INTEGRATE vendor folders. ADP carries a single folder with both
Workforce Now and Workforce Manager modules disambiguated inside.

## Authoring a new adapter

1. Read `docs/contracts/vendor_adapter_slice_contract.md` (rules) and
   `docs/contracts/per_vendor_doc_pack_contract.md` (folder shape).
2. Copy `docs/integrations/_template/` to
   `docs/integrations/<vendor_id>/`.
3. Fill in every section. No placeholders survive the slice.
4. Cite source doc URL + retrieval date at the top of every file.
5. The engineering slice's PR includes the populated folder; Codex
   reviews the folder alongside the adapter code.

## Vendor lifecycle

Every vendor folder carries an implicit lifecycle, surfaced in
`VendorCapabilityProfile.lifecycle`:

- `documented` — engineering slice landed; folder populated; no live
  verification yet.
- `sandbox_verified` — `*.live.sandbox` slice ran;
  `live_verification_checklist.md` checkboxes filled for sandbox.
- `production_credentialed` — `*.live.prod` slice ran; partnership
  cleared; production keys issued; checklist re-verified.
- `live_with_operators` — first operator connected; activated
  automatically.

The Vendor Connections admin widget surfaces the lifecycle via
`docs/phases/phase_8/vendor_connections_admin_surface.md` chrome.
