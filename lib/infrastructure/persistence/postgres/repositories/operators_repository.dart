// Phase 11A.1 — OperatorsRepository.
//
// Persistence layer for the cloud-foundation `operators` table from
// `db/migrations/202604250005_advisor_cloud_foundation.sql`. The
// admin console walks operators across tenants (cross-operator
// listing, onboarding, primary-location reassignment), so every
// statement here runs through `withSystem` — the `forge_admin`
// Postgres role's `BYPASSRLS` privilege is the only path that can
// scan / write across operators. Each call passes a non-blank
// [adminReason] string the audit marker carries via
// `app.bypass_rls_audit = 'system:<reason>'` so the bypass is
// attributable.
//
// `suspended_at` is read-and-written as a nullable `timestamptz`
// column so the admin can pause an operator without dropping rows.
// The 11A.1 slice does not assert it lives in the foundation
// migration; the repository's UPDATE statements treat `suspended_at`
// as additive — production deploys add the column via a forward-
// only migration before this repository is bound. Tests inject a
// fake executor and assert the SQL shape directly.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import 'business_timing_starter_repository.dart';

class OperatorsRepository extends OperatorScopedRepository {
  OperatorsRepository(super.tenantWrapper);

  /// SELECT every operator row plus its locations + admin grants.
  /// Returns a list of [OperatorAdminRow] sorted by `business_name`
  /// for stable admin-console rendering.
  Future<List<OperatorAdminRow>> listOperators({required String adminReason}) {
    return withSystem<List<OperatorAdminRow>>((exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at '
        'from operators '
        'order by business_name asc',
      );
      return <OperatorAdminRow>[
        for (final row in rows) _operatorAdminRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// SELECT a single operator row by ID. Returns `null` when the
  /// operator does not exist (admin console renders a 404 surface).
  Future<OperatorAdminRow?> findById({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminRow?>((exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at '
        'from operators '
        'where operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      return _operatorAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// INSERT a fresh operator row. The `operator_id` is generated
  /// server-side by `default gen_random_uuid()` and returned via
  /// `RETURNING`. Returns the newly-inserted row.
  ///
  /// Onboarding paths that need the operator + primary location
  /// inserted together should call [onboardOperatorAtomically]
  /// instead, which keeps both inserts inside one transaction so
  /// the cloud-foundation composite-FK chain stays consistent.
  Future<OperatorAdminRow> insertOperator({
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminRow>((exec) async {
      final rows = await exec.query(
        'insert into operators ('
        'business_name, owner_email, subscription_tier, '
        'preferred_currency'
        ') values ('
        '@business_name, @owner_email, '
        '@subscription_tier, @preferred_currency'
        ') '
        'returning operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at',
        parameters: <String, Object?>{
          'business_name': businessName,
          'owner_email': ownerEmail,
          'subscription_tier': subscriptionTier,
          'preferred_currency': preferredCurrency,
        },
      );
      if (rows.isEmpty) {
        throw StateError('operators insert returned no rows');
      }
      return _operatorAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// UPDATE editable operator columns. Each field is optional; only
  /// the provided columns are rewritten via `coalesce`. Returns the
  /// updated row, or `null` when the operator does not exist.
  Future<OperatorAdminRow?> updateOperator({
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminRow?>((exec) async {
      final rows = await exec.query(
        'update operators set '
        'business_name = coalesce(@business_name, business_name), '
        'owner_email = coalesce(@owner_email, owner_email), '
        'subscription_tier = coalesce(@subscription_tier, subscription_tier), '
        'preferred_currency = coalesce(@preferred_currency, preferred_currency), '
        'primary_location_id = coalesce(@primary_location_id::uuid, primary_location_id), '
        'updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'returning operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'business_name': businessName,
          'owner_email': ownerEmail,
          'subscription_tier': subscriptionTier,
          'preferred_currency': preferredCurrency,
          'primary_location_id': primaryLocationId,
        },
      );
      if (rows.isEmpty) return null;
      return _operatorAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// SET `suspended_at = now()` if not already set. Idempotent —
  /// re-suspending returns the row with its existing suspended_at.
  Future<OperatorAdminRow?> suspendOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminRow?>((exec) async {
      final rows = await exec.query(
        'update operators set '
        'suspended_at = coalesce(suspended_at, now()), '
        'updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'returning operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      return _operatorAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// SET `suspended_at = null`. Idempotent — re-activating returns
  /// the row with `suspended_at` already null.
  Future<OperatorAdminRow?> reactivateOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<OperatorAdminRow?>((exec) async {
      final rows = await exec.query(
        'update operators set '
        'suspended_at = null, '
        'updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'returning operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      return _operatorAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// Atomic operator + primary-location onboarding. Inserts the operator,
  /// root org-unit, and primary location inside a single `withSystem`
  /// transaction so a failure on any step rolls back the prior inserts.
  /// Phase 9 identity creation (Firebase user, `users`, `user_roles`,
  /// invite, and audit) is orchestrated by `RepositoryAuthOperationsGateway`
  /// after this returns; this repository must not fabricate a partial `users`
  /// row.
  ///
  /// All identifiers are generated server-side by Postgres
  /// (`default gen_random_uuid()` on each table's primary key) and
  /// returned via `RETURNING`. The cloud-foundation schema makes
  /// ordering load-bearing: `operators.primary_location_id`
  /// composite-FKs to `locations(operator_id, location_id)`, so
  /// the location must exist before the operator's primary-location
  /// pointer can be set. The post-hierarchy schema also requires every
  /// location to attach to an `org_units` parent, so onboarding creates the
  /// operator root before inserting the primary location. Sequence: insert
  /// operator (no primary_location_id) -> insert root org_unit -> insert
  /// location -> seed operator-scope Business Timing -> UPDATE operator with
  /// primary_location_id. The returning row is the final operator state with
  /// its primary_location_id set.
  Future<OperatorOnboardingResult> onboardOperatorAtomically({
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String locationName,
    required String locationAddress,
    required String locationTimezone,
    required int locationRolloverHour,
    required String adminReason,
  }) {
    return withSystem<OperatorOnboardingResult>((exec) async {
      final operatorInsertRows = await exec.query(
        'insert into operators ('
        'business_name, owner_email, subscription_tier, '
        'preferred_currency'
        ') values ('
        '@business_name, @owner_email, '
        '@subscription_tier, @preferred_currency'
        ') '
        'returning operator_id::text as operator_id',
        parameters: <String, Object?>{
          'business_name': businessName,
          'owner_email': ownerEmail,
          'subscription_tier': subscriptionTier,
          'preferred_currency': preferredCurrency,
        },
      );
      if (operatorInsertRows.isEmpty) {
        throw StateError('operators insert returned no rows');
      }
      final operatorId = operatorInsertRows.single['operator_id']! as String;

      final orgUnitRows = await exec.query(
        'insert into org_units ('
        'operator_id, parent_id, unit_type, path, name'
        ') values ('
        '@operator_id::uuid, null, '
        "'corp', "
        "coalesce(nullif(lower(regexp_replace(@business_name, "
        "'[^A-Za-z0-9_]', '', 'g')), ''), 'root')::ltree, "
        '@business_name'
        ') '
        'returning id::text as id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'business_name': businessName,
        },
      );
      if (orgUnitRows.isEmpty) {
        throw StateError('org_units root insert returned no rows');
      }
      final rootOrgUnitId = orgUnitRows.single['id']! as String;

      final locationRows = await exec.query(
        'insert into locations ('
        'operator_id, parent_org_unit_id, name, address, timezone, '
        'business_day_rollover_hour'
        ') values ('
        '@operator_id::uuid, @parent_org_unit_id::uuid, @name, @address, '
        '@timezone, @business_day_rollover_hour'
        ') '
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, name, address, timezone, '
        'business_day_rollover_hour, created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'parent_org_unit_id': rootOrgUnitId,
          'name': locationName,
          'address': locationAddress,
          'timezone': locationTimezone,
          'business_day_rollover_hour': locationRolloverHour,
        },
      );
      if (locationRows.isEmpty) {
        throw StateError('locations insert during onboarding returned no rows');
      }
      final locationId = locationRows.single['location_id']! as String;

      await _insertStarterBusinessTimingProfile(
        exec,
        operatorId: operatorId,
        businessTimezone: locationTimezone,
        businessDayStartLocal: _businessDayStartLocalFromHour(
          locationRolloverHour,
        ),
        adminReason: adminReason,
      );

      final operatorRows = await exec.query(
        'update operators set '
        'primary_location_id = @location_id::uuid, '
        'updated_at = now() '
        'where operator_id = @operator_id::uuid '
        'returning operator_id::text as operator_id, business_name, '
        'owner_email, subscription_tier, preferred_currency, '
        'primary_location_id::text as primary_location_id, '
        'suspended_at, created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      if (operatorRows.isEmpty) {
        throw StateError(
          'operators primary-location update during onboarding returned no rows',
        );
      }

      return OperatorOnboardingResult(
        operator: _operatorAdminRowFromMap(operatorRows.single),
        location: _locationRowFromInsert(locationRows.single),
      );
    }, reason: adminReason);
  }
}

String _businessDayStartLocalFromHour(int hour) =>
    '${hour.toString().padLeft(2, '0')}:00';

/// Compact bundle returned by [OperatorsRepository.onboardOperatorAtomically].
/// Carries only the rows the proxy handler needs to JSON-encode for
/// the admin client — the caller is responsible for projecting these
/// into the wire-format response.
class OperatorOnboardingResult {
  const OperatorOnboardingResult({
    required this.operator,
    required this.location,
  });

  final OperatorAdminRow operator;
  final OnboardingLocationRow location;
}

/// Slim location row shape used by [OperatorOnboardingResult]. Avoids
/// importing the full `LocationAdminRow` type from
/// `locations_repository.dart` so the operator-onboarding return
/// shape stays self-contained.
class OnboardingLocationRow {
  const OnboardingLocationRow({
    required this.locationId,
    required this.operatorId,
    required this.name,
    required this.address,
    required this.timezone,
    required this.businessDayRolloverHour,
    required this.createdAt,
    required this.updatedAt,
  });

  final String locationId;
  final String operatorId;
  final String name;
  final String address;
  final String timezone;
  final int? businessDayRolloverHour;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'location_id': locationId,
    'operator_id': operatorId,
    'name': name,
    'address': address,
    'timezone': timezone,
    'business_day_rollover_hour': businessDayRolloverHour,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

OnboardingLocationRow _locationRowFromInsert(PostgresRow row) {
  return OnboardingLocationRow(
    locationId: row['location_id']! as String,
    operatorId: row['operator_id']! as String,
    name: row['name']! as String,
    address: (row['address'] as String?) ?? '',
    timezone: row['timezone']! as String,
    businessDayRolloverHour: row['business_day_rollover_hour'] as int?,
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

/// Row shape returned by [OperatorsRepository]. Mirrors the
/// `operators` table verbatim so the proxy route handler can wrap it
/// in JSON without intermediate translation.
class OperatorAdminRow {
  const OperatorAdminRow({
    required this.operatorId,
    required this.businessName,
    required this.ownerEmail,
    required this.subscriptionTier,
    required this.preferredCurrency,
    required this.primaryLocationId,
    required this.suspendedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String operatorId;
  final String businessName;
  final String ownerEmail;
  final String subscriptionTier;
  final String preferredCurrency;
  final String? primaryLocationId;
  final DateTime? suspendedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'business_name': businessName,
    'owner_email': ownerEmail,
    'subscription_tier': subscriptionTier,
    'preferred_currency': preferredCurrency,
    'primary_location_id': primaryLocationId,
    'suspended_at': suspendedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

OperatorAdminRow _operatorAdminRowFromMap(PostgresRow row) {
  return OperatorAdminRow(
    operatorId: row['operator_id']! as String,
    businessName: row['business_name']! as String,
    ownerEmail: row['owner_email']! as String,
    subscriptionTier: row['subscription_tier']! as String,
    preferredCurrency: row['preferred_currency']! as String,
    primaryLocationId: row['primary_location_id'] as String?,
    suspendedAt: _toDateTime(row['suspended_at']),
    createdAt: _toDateTime(row['created_at'])!,
    updatedAt: _toDateTime(row['updated_at'])!,
  );
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
