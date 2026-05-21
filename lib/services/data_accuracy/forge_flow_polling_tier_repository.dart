// Phase 8 spine-bridge Lane .A — ForgeFlowPollingTierRepository.
//
// Persistence layer for `public.forge_flow_polling_tier_assignment`.
// F&F admin controls; operator never reads directly. Every read /
// write goes through `OperatorScopedRepository.withTenant` so the
// per-tenant RLS policy admits the row.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Polling cadence — F&F-controlled tier model" + "Polling tier
// assignment table" sections.
//
// Consumed by Lane .0a (sync worker reads cadence per
// (operator, location, vendor) at poll-tick time) and Lane .C
// (F&F Ops Console Polling & Pricing tab).

import 'dart:convert';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';

class ForgeFlowPollingTierRepository extends OperatorScopedRepository {
  ForgeFlowPollingTierRepository(super.tenantWrapper);

  /// Read the currently-effective tier assignment for a (operator,
  /// location). Returns null when no tier has been assigned yet.
  Future<ForgeFlowPollingTierAssignment?> readCurrentAssignment({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<ForgeFlowPollingTierAssignment?>(ctx, (exec) async {
      return _readCurrent(exec, operatorId, locationId);
    });
  }

  /// Write a new tier assignment. Closes the prior currently-effective
  /// row by setting `effective_until = now()`, then inserts a fresh
  /// row in the same transaction so the unique-current index never
  /// sees two NULL `effective_until` rows for the same (operator,
  /// location).
  ///
  /// `reasonNote` is accepted for downstream audit-log emission (the
  /// actor that wired this repo into the F&F Ops Console writes the
  /// audit row separately — the tier table itself has no `reason_note`
  /// column per `data_accuracy_settings_contract.md` schema).
  Future<ForgeFlowPollingTierAssignment> assignTier({
    required String operatorId,
    required String locationId,
    required PollingTierKey tierKey,
    required Map<String, int> pollingCadencePerVendorSeconds,
    int? monthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    String? adminUserId,
    // reasonNote is accepted for downstream audit-log emission by the
    // F&F Ops Console caller; the tier table itself has no reason_note
    // column per data_accuracy_settings_contract.md.
    // ignore: unused_element
    String? reasonNote,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: adminUserId,
    );
    return withTenant<ForgeFlowPollingTierAssignment>(ctx, (exec) async {
      // Close the prior current row (if any).
      await exec.execute(
        'update forge_flow_polling_tier_assignment '
        'set effective_until = now() '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and effective_until is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      // Insert the new current row.
      final rows = await exec.query(
        'insert into forge_flow_polling_tier_assignment ('
        'operator_id, location_id, tier_key, '
        'polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'assigned_by_admin_user_id) '
        'values ('
        '@operator_id::uuid, @location_id::uuid, @tier_key, '
        '@cadence::jsonb, '
        '@monthly_price_cents, @vendor_api_cost_estimate_cents_monthly, '
        '@admin_user_id) '
        'returning '
        'assignment_id::text as assignment_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'tier_key, polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'effective_at, effective_until, '
        'assigned_by_admin_user_id, created_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'tier_key': tierKey.wire,
          'cadence': jsonEncode(pollingCadencePerVendorSeconds),
          'monthly_price_cents': monthlyPriceCents,
          'vendor_api_cost_estimate_cents_monthly':
              vendorApiCostEstimateCentsMonthly,
          'admin_user_id': adminUserId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'forge_flow_polling_tier_assignment INSERT returned no row — '
          'RLS policy likely rejected the write for this tenant',
        );
      }
      return ForgeFlowPollingTierAssignment.fromRow(rows.single);
    });
  }

  /// Full assignment history for a (operator, location), most recent
  /// first. The currently-effective row (if any) is the first element.
  Future<List<ForgeFlowPollingTierAssignment>> listAssignmentHistory({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<List<ForgeFlowPollingTierAssignment>>(ctx, (exec) async {
      final rows = await exec.query(
        'select '
        'assignment_id::text as assignment_id, '
        'operator_id::text as operator_id, '
        'location_id::text as location_id, '
        'tier_key, polling_cadence_per_vendor_seconds, '
        'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
        'effective_at, effective_until, '
        'assigned_by_admin_user_id, created_at '
        'from forge_flow_polling_tier_assignment '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'order by effective_at desc',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return rows
          .map(ForgeFlowPollingTierAssignment.fromRow)
          .toList(growable: false);
    });
  }

  /// Aggregate margin (sum of price - sum of cost) across the
  /// currently-effective assignments visible to the tenant context.
  /// Used by the F&F Ops Console margin-rollup card. `tierKey` filter
  /// is optional — null means all tiers.
  Future<PollingTierMarginSummary> summarizeMargin({
    required String operatorId,
    required String locationId,
    String? actorUserId,
    PollingTierKey? tierKey,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<PollingTierMarginSummary>(ctx, (exec) async {
      final params = <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      };
      var sql =
          'select '
          'count(*)::int as assignment_count, '
          'coalesce(sum(monthly_price_cents), 0)::int as total_price_cents, '
          'coalesce(sum(vendor_api_cost_estimate_cents_monthly), 0)::int '
          'as total_cost_cents '
          'from effective_forge_flow_polling_tier_assignment_v '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and effective_until is null';
      if (tierKey != null) {
        sql = '$sql and tier_key = @tier_key';
        params['tier_key'] = tierKey.wire;
      }
      final rows = await exec.query(sql, parameters: params);
      if (rows.isEmpty) {
        return const PollingTierMarginSummary(
          assignmentCount: 0,
          totalMonthlyPriceCents: 0,
          totalMonthlyVendorCostCents: 0,
        );
      }
      final row = rows.single;
      final count = row['assignment_count'];
      final price = row['total_price_cents'];
      final cost = row['total_cost_cents'];
      return PollingTierMarginSummary(
        assignmentCount: _asInt(count),
        totalMonthlyPriceCents: _asInt(price),
        totalMonthlyVendorCostCents: _asInt(cost),
      );
    });
  }

  Future<ForgeFlowPollingTierAssignment?> _readCurrent(
    PostgresExecutor exec,
    String operatorId,
    String locationId,
  ) async {
    final rows = await exec.query(
      'select '
      'assignment_id::text as assignment_id, '
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'tier_key, polling_cadence_per_vendor_seconds, '
      'monthly_price_cents, vendor_api_cost_estimate_cents_monthly, '
      'effective_at, effective_until, '
      'assigned_by_admin_user_id, created_at '
      'from effective_forge_flow_polling_tier_assignment_v '
      'where operator_id = @operator_id::uuid '
      'and location_id = @location_id::uuid '
      'and effective_until is null',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    return ForgeFlowPollingTierAssignment.fromRow(rows.single);
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }
}
