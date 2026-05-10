// Phase 2A pressure harness — vendor registry.
//
// Maps each of the 17 vendors to:
//   - canonical vendor_id (matches `connector_connection.vendor_id`)
//   - integration category (pos / labor / reservation)
//   - the canonical fact type the adapter emits
//   - the actual `authMode` declared on `capabilityProfile` (used to
//     validate audit-prompt corrections, e.g. Oracle Simphony /
//     Agendrix being OAuth, not mTLS / static key)
//   - whether the adapter exposes a public DTO `tryFromMap`-shaped
//     parse entry (so the harness can drive it directly)
//
// The registry is the single source of truth for what the harness
// can vs. cannot probe directly. When the harness has no public
// parse entry it records an `adapter_not_found` finding with detail
// `parse_helper_private` rather than crashing.

import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

class VendorRegistryEntry {
  const VendorRegistryEntry({
    required this.vendorId,
    required this.fixtureDir,
    required this.category,
    required this.canonicalFactType,
    required this.authMode,
    required this.hasPublicDtoParser,
  });

  /// `connector_connection.vendor_id` — also the
  /// `test/fixtures/vendor_payloads/<dir>/` directory name.
  final String vendorId;

  /// The directory under `test/fixtures/vendor_payloads/`. Equal to
  /// [vendorId] except where audit notes flag the dir name as the
  /// authoritative key.
  final String fixtureDir;

  final IntegrationCategory category;

  /// The canonical fact class name the adapter emits on success.
  /// Used to assert `expectedFactType` matches.
  final String canonicalFactType;

  /// The `authMode` declared on the adapter's
  /// `VendorCapabilityProfile`. Used to validate the audit
  /// corrections (Oracle Simphony / Agendrix should be `oauth`).
  final VendorAuthMode authMode;

  /// True when the adapter exposes a public DTO with a
  /// `tryFromMap` / `fromMap` entry the harness can drive directly.
  /// False when the parse helper is private (`_canonicalize`,
  /// `_orderToCanonicalFact`, etc.) — in that case the harness
  /// performs structural assertions instead.
  final bool hasPublicDtoParser;
}

/// All 17 vendors covered by the Phase 2A harness. Source-of-truth
/// captured 2026-05-08:
///
///   POS (7):
///     square, toast, clover, lightspeed_lsk, oracle_micros_simphony,
///     aloha_ncr_voyix, revel
///   Labor (6):
///     adp, agendrix, humanity, push_operations, quickbooks_time,
///     seven_shifts
///   Reservation (4):
///     libro, opentable, sevenrooms, tock
const List<VendorRegistryEntry> kP2aVendorRegistry = <VendorRegistryEntry>[
  // ─── POS ──────────────────────────────────────────────────────────
  VendorRegistryEntry(
    vendorId: 'square',
    fixtureDir: 'square',
    category: IntegrationCategory.pos,
    canonicalFactType: 'SquareCanonicalFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'toast',
    fixtureDir: 'toast',
    category: IntegrationCategory.pos,
    canonicalFactType: 'ToastCanonicalSalesFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'clover',
    fixtureDir: 'clover',
    category: IntegrationCategory.pos,
    canonicalFactType: 'CloverCanonicalSalesFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'lightspeed_lsk',
    fixtureDir: 'lightspeed_lsk',
    category: IntegrationCategory.pos,
    canonicalFactType: 'LightspeedLskCanonicalSalesFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'oracle_micros_simphony',
    fixtureDir: 'oracle_micros_simphony',
    category: IntegrationCategory.pos,
    canonicalFactType: 'OracleMicrosSimphonyCanonicalSalesFact',
    // Audit-prompt correction: profile declares OAuth, NOT mTLS.
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'aloha_ncr_voyix',
    fixtureDir: 'aloha_ncr_voyix',
    category: IntegrationCategory.pos,
    canonicalFactType: 'AlohaNcrVoyixCanonicalCheckFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'revel',
    fixtureDir: 'revel',
    category: IntegrationCategory.pos,
    canonicalFactType: 'RevelCanonicalOrderFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),

  // ─── Labor ────────────────────────────────────────────────────────
  VendorRegistryEntry(
    vendorId: 'adp',
    fixtureDir: 'adp',
    category: IntegrationCategory.labor,
    canonicalFactType: 'AdpCanonicalTimePunchFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'agendrix',
    fixtureDir: 'agendrix',
    category: IntegrationCategory.labor,
    canonicalFactType: 'AgendrixCanonicalLaborFact',
    // Audit-prompt correction: profile declares OAuth, NOT static
    // API key.
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'humanity',
    fixtureDir: 'humanity',
    category: IntegrationCategory.labor,
    canonicalFactType: 'HumanityCanonicalShiftFact',
    authMode: VendorAuthMode.keyPaste,
    // Humanity exposes `HumanityShiftDto.tryFromMap` publicly — the
    // harness drives it directly to exercise the time-off-as-24h-shift
    // bug.
    hasPublicDtoParser: true,
  ),
  VendorRegistryEntry(
    vendorId: 'push_operations',
    fixtureDir: 'push_operations',
    category: IntegrationCategory.labor,
    canonicalFactType: 'PushOperationsCanonicalLaborFact',
    authMode: VendorAuthMode.keyPaste,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'quickbooks_time',
    fixtureDir: 'quickbooks_time',
    category: IntegrationCategory.labor,
    canonicalFactType: 'QuickBooksTimeCanonicalPunchFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'seven_shifts',
    fixtureDir: 'seven_shifts',
    category: IntegrationCategory.labor,
    canonicalFactType: 'SevenShiftsCanonicalTimePunchFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),

  // ─── Reservation ──────────────────────────────────────────────────
  VendorRegistryEntry(
    vendorId: 'libro',
    fixtureDir: 'libro',
    category: IntegrationCategory.reservation,
    canonicalFactType: 'CanonicalReservationFact',
    authMode: VendorAuthMode.oauth,
    // Libro exposes `LibroReservationDto.fromMap` publicly.
    hasPublicDtoParser: true,
  ),
  VendorRegistryEntry(
    vendorId: 'opentable',
    fixtureDir: 'opentable',
    category: IntegrationCategory.reservation,
    canonicalFactType: 'OpenTableCanonicalReservationFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'sevenrooms',
    fixtureDir: 'sevenrooms',
    category: IntegrationCategory.reservation,
    canonicalFactType: 'SevenRoomsCanonicalReservationFact',
    authMode: VendorAuthMode.oauth,
    hasPublicDtoParser: false,
  ),
  VendorRegistryEntry(
    vendorId: 'tock',
    fixtureDir: 'tock',
    category: IntegrationCategory.reservation,
    canonicalFactType: 'TockCanonicalReservationFact',
    authMode: VendorAuthMode.keyPaste,
    hasPublicDtoParser: false,
  ),
];

/// Cross-vendor scenario_f pairs. Each tuple is (vendor_a, vendor_b)
/// where the two adapters' scenario_f fixtures share an entity id but
/// the canonical UNIQUE on `(vendor_id, ...)` keeps them disjoint.
///
/// Pair sources:
///   - libro × opentable — reservation namespace
///   - seven_shifts × quickbooks_time — labor punch namespace
///   - adp × seven_shifts — labor punch namespace
///   - humanity × seven_shifts — labor shift namespace
const List<List<String>> kP2aCrossVendorPairs = <List<String>>[
  <String>['libro', 'opentable'],
  <String>['seven_shifts', 'quickbooks_time'],
  <String>['adp', 'seven_shifts'],
  <String>['humanity', 'seven_shifts'],
];
