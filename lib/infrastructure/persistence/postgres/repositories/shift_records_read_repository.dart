// Advisor Knowledge Activation — Slice A4.6 read repository.
//
// `ShiftRecordsReadRepository` is the READ-ONLY companion to
// `postgres_shift_record_writer.dart` (which is write-only). Phase 8
// shipped the writer but no read repo for `public.shift_records`; the
// agentic advisor (Slice A4.6) needs to pull a window of closed-shift
// actuals + the locked target snapshot so it can explain variance to
// the operator.
//
// Authority:
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     — every read goes through `OperatorScopedRepository.withTenant`
//     so `SET LOCAL app.operator_id / location_id / user_id` is issued
//     (RLS backup defense) and the repository pattern is the primary
//     defense. Mirrors `target_cycle_repository.dart`.
//   * docs/contracts/metric_card_honesty_contract.md — a metric value
//     that is NULL in the row is surfaced as an explicit `unavailable`
//     marker (value == null), NEVER coerced to 0.0. The
//     covers/labor-dollars provenance columns ride along so the advisor
//     never presents an estimate as a measurement.
//   * RLS-Ready Schema (CLAUDE.md) — the query leads with `operator_id`
//     (then `location_id`, `business_date`) so it folds into
//     `shift_records_operator_business_date_idx`
//     `(operator_id, location_id, business_date desc, daypart)`.
//
// HARD CONSTRAINTS (A4.6 is strictly read-only, HP #6):
//   * SELECT only. This class issues NO insert/update/delete/DDL.
//   * Variance (actual minus target) is computed in Dart from the
//     single co-located row (the writer stores actual + locked target
//     on the same row), never via a write-back.
//   * Restaurant scope: the caller passes `restaurantId` (TEXT). The
//     advisor tool layer resolves it from the JWT-derived
//     `OperatorContext` ONLY (never from tool input), so a hallucinated
//     operator/restaurant cannot reach this repo with foreign scope.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

/// Read-only access to `public.shift_records`. Extends
/// [OperatorScopedRepository] so every read runs through
/// [withTenant] (tenant SET LOCAL + transaction). No write path exists
/// on this class by construction (A4.6 HP #6).
class ShiftRecordsReadRepository extends OperatorScopedRepository {
  ShiftRecordsReadRepository(super.tenantWrapper);

  // Operator-leading column projection. `restaurant_id` is TEXT (mobile
  // model PK shape), not a uuid. Numeric columns come back as `num` /
  // `String`; `_toDoubleOrNull` keeps a genuinely-NULL measurement NULL
  // rather than coercing to 0.0 (metric honesty).
  /// Returns the DISTINCT `restaurant_id` values that exist under the
  /// caller's `(operator_id, location_id)` scope, drawn from the
  /// server's current target projection (`active_target_profiles`,
  /// unique per `(operator_id, location_id, restaurant_id)`). Used by
  /// the advisor tool layer to resolve `restaurant_id` from the verified
  /// [OperatorContext] WITHOUT trusting tool input (HP #4): the optional
  /// tool-supplied `restaurant_id` is only ever accepted when it appears
  /// in THIS list (the caller's own restaurants). A hallucinated /
  /// foreign id can never match.
  ///
  /// Read-only, operator-leading, RLS-folded (runs inside
  /// [withTenant] so `SET LOCAL app.operator_id / location_id` gates the
  /// read even if a caller passed a foreign scope). Ordered for a
  /// deterministic "needs selection" listing.
  Future<List<String>> loadScopedRestaurantIds({
    required String operatorId,
    required String locationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<String>>(ctx, (exec) async {
      final rows = await exec.query(
        'select distinct atp.restaurant_id as restaurant_id '
        'from public.active_target_profiles atp '
        'where atp.operator_id = @operator_id::uuid '
        '  and atp.location_id = @location_id::uuid '
        'order by atp.restaurant_id asc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return <String>[
        for (final row in rows)
          if (row['restaurant_id'] is String) row['restaurant_id']! as String,
      ];
    });
  }

  static const String _columns =
      'sr.operator_id::text as operator_id, '
      'sr.location_id::text as location_id, '
      'sr.restaurant_id, '
      'sr.business_date::text as business_date, '
      'sr.daypart, '
      'sr.status, '
      'sr.covers, '
      'sr.forecast_covers, '
      'sr.actual_sales, '
      'sr.ppa, '
      'sr.cplh, '
      'sr.splh, '
      'sr.foh_hours, '
      'sr.boh_hours, '
      'sr.foh_labor_dollar, '
      'sr.boh_labor_dollar, '
      'sr.theoretical_labor_pct, '
      'sr.primary_lever, '
      'sr.target_cplh, '
      'sr.target_splh, '
      'sr.target_ppa, '
      'sr.opz_floor_cplh, '
      'sr.opz_ceiling_cplh, '
      'sr.covers_provenance, '
      'sr.labor_dollars_provenance, '
      'sr.source_system, '
      'sr.updated_at';

  /// Loads every closed-shift row for `(operator_id, location_id,
  /// restaurant_id)` whose `business_date` falls inside the inclusive
  /// `[businessDateFrom, businessDateTo]` window, newest first.
  ///
  /// Each returned [ShiftVarianceRow] co-locates the ACTUAL metrics and
  /// the locked TARGET snapshot, plus the computed actual-minus-target
  /// variance and the covers / labor-dollars provenance. A metric that
  /// is NULL in the row stays NULL on the model (metric honesty); the
  /// caller surfaces it as `unavailable`, never 0.0.
  ///
  /// Scope comes from the arguments only; the advisor tool layer derives
  /// them from the verified [OperatorContext] (HP #4). The SQL filters on
  /// `operator_id` + `location_id` + `restaurant_id`, and the tenant
  /// SET LOCAL means RLS is a second gate even if a caller passed a
  /// foreign id.
  Future<List<ShiftVarianceRow>> loadShiftVarianceForWindow({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String businessDateFrom,
    required String businessDateTo,
    String? userId,
    int limit = 250,
  }) {
    _validateNonBlank(restaurantId, 'restaurantId');
    _validateNonBlank(businessDateFrom, 'businessDateFrom');
    _validateNonBlank(businessDateTo, 'businessDateTo');
    _validatePositiveLimit(limit);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<ShiftVarianceRow>>(ctx, (exec) async {
      final rows = await exec.query(
        // Operator-leading WHERE so the predicate folds into
        // shift_records_operator_business_date_idx. SELECT only.
        'select $_columns '
        'from public.shift_records sr '
        'where sr.operator_id = @operator_id::uuid '
        '  and sr.location_id = @location_id::uuid '
        '  and sr.restaurant_id = @restaurant_id '
        '  and sr.business_date >= @business_date_from::date '
        '  and sr.business_date <= @business_date_to::date '
        'order by sr.business_date desc, sr.daypart asc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'restaurant_id': restaurantId,
          'business_date_from': businessDateFrom,
          'business_date_to': businessDateTo,
          'limit': limit,
        },
      );
      return <ShiftVarianceRow>[
        for (final row in rows) _shiftVarianceRowFromMap(row),
      ];
    });
  }
}

/// One closed-shift row with ACTUAL metrics, the locked TARGET snapshot,
/// and the actual-minus-target variance. Pure data; metric honesty is
/// preserved by keeping genuinely-absent measurements `null`.
class ShiftVarianceRow {
  const ShiftVarianceRow({
    required this.operatorId,
    required this.locationId,
    required this.restaurantId,
    required this.businessDate,
    required this.daypart,
    required this.status,
    required this.actualCplh,
    required this.actualSplh,
    required this.actualPpa,
    required this.actualSales,
    required this.covers,
    required this.forecastCovers,
    required this.fohHours,
    required this.bohHours,
    required this.fohLaborDollar,
    required this.bohLaborDollar,
    required this.theoreticalLaborPct,
    required this.primaryLever,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.coversProvenance,
    required this.laborDollarsProvenance,
    required this.sourceSystem,
    required this.updatedAt,
  });

  final String operatorId;
  final String locationId;
  final String restaurantId;
  final String businessDate;
  final String daypart;
  final String status;

  // ACTUAL metrics. Null when the vendor has not yet supplied the input
  // (metric honesty: a null stays null, never 0.0).
  final double? actualCplh;
  final double? actualSplh;
  final double? actualPpa;
  final double? actualSales;
  final int? covers;
  final int? forecastCovers;
  final int? fohHours;
  final int? bohHours;
  final double? fohLaborDollar;
  final double? bohLaborDollar;
  final double? theoreticalLaborPct;
  final String? primaryLever;

  // Locked TARGET snapshot (co-located on the same row by the writer).
  final double? targetCplh;
  final double? targetSplh;
  final double? targetPpa;
  final double? opzFloorCplh;
  final double? opzCeilingCplh;

  // Provenance carried so the advisor never presents an estimate as a
  // measurement (metric honesty).
  final String? coversProvenance;
  final String? laborDollarsProvenance;
  final String? sourceSystem;

  final DateTime? updatedAt;

  /// CPLH variance (actual minus target). Null when either side is
  /// absent — a missing input is never treated as a zero.
  double? get cplhVariance => _diff(actualCplh, targetCplh);

  /// SPLH variance (actual minus target). Null when either side absent.
  double? get splhVariance => _diff(actualSplh, targetSplh);

  /// PPA variance (actual minus target). Null when either side absent.
  double? get ppaVariance => _diff(actualPpa, targetPpa);

  static double? _diff(double? actual, double? target) {
    if (actual == null || target == null) return null;
    return actual - target;
  }
}

ShiftVarianceRow _shiftVarianceRowFromMap(PostgresRow row) {
  return ShiftVarianceRow(
    operatorId: row['operator_id']! as String,
    locationId: row['location_id']! as String,
    restaurantId: row['restaurant_id']! as String,
    businessDate: _dateString(row['business_date'])!,
    daypart: row['daypart']! as String,
    status: row['status']! as String,
    actualCplh: _toDoubleOrNull(row['cplh']),
    actualSplh: _toDoubleOrNull(row['splh']),
    actualPpa: _toDoubleOrNull(row['ppa']),
    actualSales: _toDoubleOrNull(row['actual_sales']),
    covers: _toIntOrNull(row['covers']),
    forecastCovers: _toIntOrNull(row['forecast_covers']),
    fohHours: _toIntOrNull(row['foh_hours']),
    bohHours: _toIntOrNull(row['boh_hours']),
    fohLaborDollar: _toDoubleOrNull(row['foh_labor_dollar']),
    bohLaborDollar: _toDoubleOrNull(row['boh_labor_dollar']),
    theoreticalLaborPct: _toDoubleOrNull(row['theoretical_labor_pct']),
    primaryLever: row['primary_lever'] as String?,
    targetCplh: _toDoubleOrNull(row['target_cplh']),
    targetSplh: _toDoubleOrNull(row['target_splh']),
    targetPpa: _toDoubleOrNull(row['target_ppa']),
    opzFloorCplh: _toDoubleOrNull(row['opz_floor_cplh']),
    opzCeilingCplh: _toDoubleOrNull(row['opz_ceiling_cplh']),
    coversProvenance: row['covers_provenance'] as String?,
    laborDollarsProvenance: row['labor_dollars_provenance'] as String?,
    sourceSystem: row['source_system'] as String?,
    updatedAt: _toDateTime(row['updated_at']),
  );
}

void _validatePositiveLimit(int limit) {
  if (limit <= 0) {
    throw ArgumentError.value(limit, 'limit', 'must be positive');
  }
}

void _validateNonBlank(String value, String name) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-blank');
  }
}

/// Coerces a numeric DB value to double, preserving a genuine NULL as
/// null (metric honesty — never substitute 0.0 for an absent measure).
double? _toDoubleOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _toIntOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num && value.roundToDouble() == value.toDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value);
  return null;
}

String? _dateString(Object? value) {
  if (value == null) return null;
  if (value is DateTime) {
    return value.toUtc().toIso8601String().substring(0, 10);
  }
  if (value is String) {
    return value.isEmpty ? null : value.substring(0, 10);
  }
  return null;
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
