/// Phase 8 spine-bridge Lane .A — F&F-controlled polling tier
/// assignment per (operator, location).
///
/// Authority: docs/contracts/data_accuracy_settings_contract.md
/// "Polling tier assignment table" section. Mirrors the
/// `public.forge_flow_polling_tier_assignment` row.
///
/// REVERSED 2026-05-05: F&F controls polling cadence per (operator,
/// location) via tier assignment. Operators see tier names + tier
/// prices, NOT vendor per-call costs. F&F absorbs vendor API costs
/// into tier pricing.
///
/// One CURRENTLY-EFFECTIVE row per (operator, location) — identified
/// by `effectiveUntil == null`. History rows preserved with
/// `effectiveUntil` set to the close timestamp.
library;

/// Tier key. Matches the SQL CHECK constraint.
enum PollingTierKey {
  standard,
  premium,
  custom,
}

extension PollingTierKeyWire on PollingTierKey {
  String get wire {
    switch (this) {
      case PollingTierKey.standard:
        return 'standard';
      case PollingTierKey.premium:
        return 'premium';
      case PollingTierKey.custom:
        return 'custom';
    }
  }

  static PollingTierKey fromWire(String value) {
    switch (value) {
      case 'standard':
        return PollingTierKey.standard;
      case 'premium':
        return PollingTierKey.premium;
      case 'custom':
        return PollingTierKey.custom;
      default:
        throw ArgumentError.value(
          value,
          'tier_key',
          'must be one of standard / premium / custom',
        );
    }
  }
}

class ForgeFlowPollingTierAssignment {
  ForgeFlowPollingTierAssignment({
    required this.assignmentId,
    required this.operatorId,
    required this.locationId,
    required this.tierKey,
    required this.pollingCadencePerVendorSeconds,
    required this.effectiveAt,
    required this.createdAt,
    this.monthlyPriceCents,
    this.vendorApiCostEstimateCentsMonthly,
    this.effectiveUntil,
    this.assignedByAdminUserId,
  });

  final String assignmentId;
  final String operatorId;
  final String locationId;
  final PollingTierKey tierKey;

  /// Per-vendor cadence override in seconds. Keys are vendor_id
  /// strings (e.g. `oracle_micros_simphony`, `quickbooks_time`).
  /// Empty for `standard` / `premium` when defaults apply; populated
  /// for `custom` (and optionally for the other tiers when an admin
  /// pins a vendor cadence per-assignment).
  final Map<String, int> pollingCadencePerVendorSeconds;

  /// F&F's monthly price in cents. Null when bundled / comped /
  /// enterprise-contract.
  final int? monthlyPriceCents;

  /// F&F's internal vendor API cost basis in cents/month. Internal
  /// margin analysis only — never operator-facing.
  final int? vendorApiCostEstimateCentsMonthly;

  final DateTime effectiveAt;
  final DateTime? effectiveUntil;
  final String? assignedByAdminUserId;
  final DateTime createdAt;

  bool get isCurrent => effectiveUntil == null;

  /// Computed monthly margin in cents (price - cost). Null when either
  /// side is null.
  int? get netMarginCents {
    final price = monthlyPriceCents;
    final cost = vendorApiCostEstimateCentsMonthly;
    if (price == null || cost == null) return null;
    return price - cost;
  }

  factory ForgeFlowPollingTierAssignment.fromRow(Map<String, Object?> row) {
    final assignmentId = row['assignment_id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final tierKey = row['tier_key'];
    final cadenceRaw = row['polling_cadence_per_vendor_seconds'];
    final effectiveAt = row['effective_at'];
    final createdAt = row['created_at'];

    if (assignmentId is! String ||
        operatorId is! String ||
        locationId is! String ||
        tierKey is! String ||
        effectiveAt is! DateTime ||
        createdAt is! DateTime) {
      throw StateError(
        'forge_flow_polling_tier_assignment row malformed: '
        'missing required fields',
      );
    }

    final cadence = _parseCadence(cadenceRaw);
    final price = row['monthly_price_cents'];
    final cost = row['vendor_api_cost_estimate_cents_monthly'];
    final until = row['effective_until'];
    final adminUserId = row['assigned_by_admin_user_id'];

    return ForgeFlowPollingTierAssignment(
      assignmentId: assignmentId,
      operatorId: operatorId,
      locationId: locationId,
      tierKey: PollingTierKeyWire.fromWire(tierKey),
      pollingCadencePerVendorSeconds: cadence,
      monthlyPriceCents: price is int
          ? price
          : (price is num ? price.toInt() : null),
      vendorApiCostEstimateCentsMonthly: cost is int
          ? cost
          : (cost is num ? cost.toInt() : null),
      effectiveAt: effectiveAt,
      effectiveUntil: until is DateTime ? until : null,
      assignedByAdminUserId:
          adminUserId is String && adminUserId.isNotEmpty ? adminUserId : null,
      createdAt: createdAt,
    );
  }

  static Map<String, int> _parseCadence(Object? raw) {
    if (raw == null) return <String, int>{};
    if (raw is! Map) {
      throw StateError(
        'polling_cadence_per_vendor_seconds jsonb projected as '
        '${raw.runtimeType}, expected Map',
      );
    }
    final out = <String, int>{};
    raw.forEach((key, value) {
      if (key is! String) return;
      if (value is int) {
        out[key] = value;
      } else if (value is num) {
        out[key] = value.toInt();
      }
    });
    return out;
  }
}

/// Aggregated margin across the currently-effective tier assignments
/// for a filter set. Returned by
/// `ForgeFlowPollingTierRepository.summarizeMargin`.
class PollingTierMarginSummary {
  const PollingTierMarginSummary({
    required this.assignmentCount,
    required this.totalMonthlyPriceCents,
    required this.totalMonthlyVendorCostCents,
  });

  final int assignmentCount;
  final int totalMonthlyPriceCents;
  final int totalMonthlyVendorCostCents;

  int get totalMonthlyMarginCents =>
      totalMonthlyPriceCents - totalMonthlyVendorCostCents;

  /// Margin as a fraction (0.0..1.0) when revenue > 0; null otherwise.
  double? get marginFraction {
    if (totalMonthlyPriceCents <= 0) return null;
    return totalMonthlyMarginCents / totalMonthlyPriceCents;
  }
}
