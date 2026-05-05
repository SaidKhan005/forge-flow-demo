// Phase 8 Wave B `8.spine-bridge.0a` polling tier presets.
//
// F&F-engineering-controlled cadence-per-vendor defaults the resolver
// reads when a tier-assignment row carries `tier_key=standard` or
// `premium` and does NOT specify a per-vendor JSONB override.
//
// Authority:
//   * docs/contracts/data_accuracy_settings_contract.md "Three
//     reference tiers" — binding cadence-per-tier shape.
//   * docs/phases/phase_8/phase_8_spine_bridge_plan.md "F&F-controlled
//     polling cadence (REVERSED 2026-05-05)".
//
// Per the contract:
//   * `standard` — webhook vendors run real-time (irrelevant);
//     poll-only vendors run at vendor minimum (Oracle 5min;
//     QBT/Humanity/Agendrix/Push 5min).
//   * `premium` — webhook vendors run real-time (irrelevant);
//     poll-only vendors run 60s where vendor allows, vendor minimum
//     where not (Oracle stays 5min because vendor minimum is 5min;
//     QBT/Humanity/Agendrix/Push run 60s).
//   * `custom` — F&F admin sets per-vendor cadence directly on the
//     assignment row's JSONB; presets are not consulted.
//
// Vendor IDs intentionally string-literal: the presets are a
// cross-cutting policy table that the per-vendor adapter files hold
// the same canonical strings for. Pulling each `k<Vendor>VendorId`
// constant would couple this policy file to every adapter file's
// import order; the per-vendor sanity grep in
// `polling_tier_presets_test.dart` (test F) pins the literals.
//
// Tier-key wire format lives on `PollingTierKey.wire` per
// `lib/domain/models/forge_flow_polling_tier_assignment.dart` (Lane
// `.A`); this file does not redeclare it.

/// Framework maximum cadence in seconds. Beyond this, the dashboard
/// feels broken (per contract section "Vendor min/max clamping").
const int kFrameworkMaximumCadenceSeconds = 3600;

/// `standard` tier cadence-per-vendor presets.
///
/// All five poll-only vendors run at 300s (5 minutes), the vendor
/// minimum for each. Webhook vendors are absent because polling
/// cadence does not apply to them — the dispatcher would never call
/// the resolver for an `autoRegister` / `manualPaste` vendor.
const Map<String, int> kStandardTierPresets = <String, int>{
  'oracle_micros_simphony': 300,
  'quickbooks_time': 300,
  'humanity': 300,
  'agendrix': 300,
  'push_operations': 300,
};

/// `premium` tier cadence-per-vendor presets.
///
/// Oracle MICROS Simphony stays at 300s because that is the vendor's
/// own minimum (per
/// `docs/integrations/oracle_micros_simphony/api_consumed.md`). The
/// other four vendors run at 60s — the contract's "60s where vendor
/// allows, vendor minimum where not" rule.
const Map<String, int> kPremiumTierPresets = <String, int>{
  'oracle_micros_simphony': 300,
  'quickbooks_time': 60,
  'humanity': 60,
  'agendrix': 60,
  'push_operations': 60,
};
