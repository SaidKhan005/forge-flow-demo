// Phase 11A.1 — LocationsRepository.
//
// Persistence layer for the cloud-foundation `locations` table from
// `db/migrations/202604250005_advisor_cloud_foundation.sql`. The
// admin console reads/writes locations across all operators (e.g.
// during onboarding, before the new operator owns any tenant
// session), so every statement runs through `withSystem` with a
// non-blank [adminReason] string the audit marker carries via
// `app.bypass_rls_audit = 'system:<reason>'`.
//
// All writes carry the operator's UUID so the cloud-foundation
// composite-FK chain keeps cross-tenant misuse impossible at the
// database layer.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';

class LocationsRepository extends OperatorScopedRepository {
  LocationsRepository(super.tenantWrapper);

  /// SELECT every location for one operator. Returns an empty list
  /// when the operator has no locations yet.
  Future<List<LocationAdminRow>> listForOperator({
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<List<LocationAdminRow>>((exec) async {
      final rows = await exec.query(
        'select location_id::text as location_id, '
        'operator_id::text as operator_id, '
        'parent_org_unit_id::text as parent_org_unit_id, '
        'name, address, timezone, '
        'business_day_rollover_hour, suspended_at, deleted_at, '
        'created_at, updated_at '
        'from locations '
        'where operator_id = @operator_id::uuid '
        'and deleted_at is null '
        'order by created_at asc',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      return <LocationAdminRow>[
        for (final row in rows) _locationAdminRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// SELECT every location across every operator. The admin
  /// console's operators-list view groups by operator after this
  /// returns; loading them in one shot avoids N+1 fan-out.
  Future<List<LocationAdminRow>> listAllLocations({
    required String adminReason,
  }) {
    return withSystem<List<LocationAdminRow>>((exec) async {
      final rows = await exec.query(
        'select location_id::text as location_id, '
        'operator_id::text as operator_id, '
        'parent_org_unit_id::text as parent_org_unit_id, '
        'name, address, timezone, '
        'business_day_rollover_hour, suspended_at, deleted_at, '
        'created_at, updated_at '
        'from locations '
        'where deleted_at is null '
        'order by operator_id asc, created_at asc',
      );
      return <LocationAdminRow>[
        for (final row in rows) _locationAdminRowFromMap(row),
      ];
    }, reason: adminReason);
  }

  /// INSERT a new location for [operatorId]. The `location_id` is
  /// generated server-side by `default gen_random_uuid()` and
  /// returned via `RETURNING`. The onboarding path uses
  /// [OperatorsRepository.onboardOperatorAtomically] instead so
  /// the operator + primary-location pair lands in one transaction.
  Future<LocationAdminRow> insertLocation({
    required String operatorId,
    required String parentOrgUnitId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) {
    return withSystem<LocationAdminRow>((exec) async {
      final rows = await exec.query(
        'insert into locations ('
        'operator_id, parent_org_unit_id, name, address, timezone, '
        'business_day_rollover_hour'
        ') values ('
        '@operator_id::uuid, @parent_org_unit_id::uuid, @name, @address, '
        '@timezone, @business_day_rollover_hour'
        ') '
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, '
        'parent_org_unit_id::text as parent_org_unit_id, '
        'name, address, timezone, '
        'business_day_rollover_hour, suspended_at, deleted_at, '
        'created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'parent_org_unit_id': parentOrgUnitId,
          'name': name,
          'address': address,
          'timezone': timezone,
          'business_day_rollover_hour': businessDayRolloverHour,
        },
      );
      if (rows.isEmpty) {
        throw StateError('locations insert returned no rows');
      }
      return _locationAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// UPDATE editable location columns. Each field is optional;
  /// `coalesce` rewrites only the supplied columns. Returns the
  /// updated row, or `null` when the location does not exist.
  Future<LocationAdminRow?> updateLocation({
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  }) {
    return withSystem<LocationAdminRow?>((exec) async {
      final rows = await exec.query(
        'update locations set '
        'name = coalesce(@name, name), '
        'address = coalesce(@address, address), '
        'timezone = coalesce(@timezone, timezone), '
        'business_day_rollover_hour = coalesce(@business_day_rollover_hour, business_day_rollover_hour), '
        'updated_at = now() '
        'where location_id = @location_id::uuid '
        'and deleted_at is null '
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, '
        'parent_org_unit_id::text as parent_org_unit_id, '
        'name, address, timezone, '
        'business_day_rollover_hour, suspended_at, deleted_at, '
        'created_at, updated_at',
        parameters: <String, Object?>{
          'location_id': locationId,
          'name': name,
          'address': address,
          'timezone': timezone,
          'business_day_rollover_hour': businessDayRolloverHour,
        },
      );
      if (rows.isEmpty) return null;
      return _locationAdminRowFromMap(rows.single);
    }, reason: adminReason);
  }

  /// Wave 2 W-6 backend — resolve the operator's primary location and
  /// rewrite its `locations.timezone` column to [ianaTimezone].
  ///
  /// Returns:
  ///   * `null` — operator row missing or has no `primary_location_id`
  ///     set yet (proxy maps to 400 `no_primary_location`).
  ///   * [LocationTimezoneUpdateRow] with `locationFound = false` —
  ///     primary-location pointer is dangling (row missing or soft-
  ///     deleted). Proxy maps to 404 `location_not_found`.
  ///   * [LocationTimezoneUpdateRow] with `locationFound = true` —
  ///     the UPDATE landed; carries the before + after IANA strings.
  ///
  /// HP #4 — the UPDATE's WHERE clause carries
  /// `(operator_id, location_id)` so a stale primary-location
  /// pointer cannot reach across tenants even if RLS were disabled.
  /// RLS on `public.locations` is the backup defence.
  ///
  /// The single-statement `WITH old AS (...) UPDATE ... RETURNING
  /// old.timezone, new` CTE pattern captures the BEFORE value with
  /// a `FOR UPDATE` row lock so a concurrent writer serialises
  /// against it and the audit row's previous_tz/new_tz pair stays
  /// correct under contention.
  Future<LocationTimezoneUpdateRow?> updateLocationTimezone({
    required String operatorId,
    required String ianaTimezone,
    required String adminReason,
  }) {
    return withSystem<LocationTimezoneUpdateRow?>((exec) async {
      final pointerRows = await exec.query(
        'select primary_location_id::text as primary_location_id '
        'from operators '
        'where operator_id = @operator_id::uuid',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (pointerRows.isEmpty) return null;
      final primaryLocationId =
          pointerRows.single['primary_location_id'] as String?;
      if (primaryLocationId == null) return null;
      // CTE captures the row BEFORE the update with a FOR UPDATE
      // lock so a concurrent writer serialises against it. The
      // UPDATE then writes the new timezone and the RETURNING list
      // emits both the previous (from `old`) and new (from the post-
      // UPDATE `locations` projection) values.
      final updated = await exec.query(
        'with old as ('
        '  select location_id, timezone as previous_timezone '
        '  from locations '
        '  where location_id = @location_id::uuid '
        '  and operator_id = @operator_id::uuid '
        '  and deleted_at is null '
        '  for update'
        ') '
        'update locations '
        'set timezone = @timezone, updated_at = now() '
        'from old '
        'where locations.location_id = old.location_id '
        'returning locations.location_id::text as location_id, '
        'locations.operator_id::text as operator_id, '
        'old.previous_timezone as previous_timezone, '
        'locations.timezone as new_timezone, '
        'locations.updated_at',
        parameters: <String, Object?>{
          'location_id': primaryLocationId,
          'operator_id': operatorId,
          'timezone': ianaTimezone,
        },
      );
      if (updated.isEmpty) {
        return LocationTimezoneUpdateRow(
          locationId: primaryLocationId,
          operatorId: operatorId,
          previousIanaTimezone: '',
          ianaTimezone: ianaTimezone,
          updatedAt: DateTime.now().toUtc(),
          locationFound: false,
        );
      }
      final row = updated.single;
      return LocationTimezoneUpdateRow(
        locationId: row['location_id']! as String,
        operatorId: row['operator_id']! as String,
        previousIanaTimezone:
            (row['previous_timezone'] as String?) ?? '',
        ianaTimezone: row['new_timezone']! as String,
        updatedAt: _toDateTime(row['updated_at'])!,
        locationFound: true,
      );
    }, reason: adminReason);
  }

  /// DELETE a location. Returns the affected-row count (0 when the
  /// row was already gone — proxy translates that into a 404).
  /// Caller must ensure the location is not the operator's
  /// `primary_location_id` before deletion; the foundation schema
  /// declares that FK as `ON DELETE SET NULL (primary_location_id)`,
  /// so deleting a primary location would silently null the pointer
  /// and the proxy refuses the call up-front instead.
  Future<int> deleteLocation({
    required String locationId,
    required String operatorId,
    required String adminReason,
  }) {
    return withSystem<int>((exec) async {
      final activeTargets = await exec.query(
        'select source from ('
        "select 'user_roles' as source "
        'from user_roles '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        "and scope_type = 'location' "
        'and revoked_at is null '
        'and valid_from <= now() '
        'and (valid_until is null or valid_until > now()) '
        'union all '
        "select 'auth_invites' as source "
        'from auth_invites '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        "and scope_type = 'location' "
        'and accepted_at is null '
        'and revoked_at is null '
        'and expires_at > now()'
        ') active_targets '
        'limit 1',
        parameters: <String, Object?>{
          'location_id': locationId,
          'operator_id': operatorId,
        },
      );
      if (activeTargets.isNotEmpty) {
        throw StateError(
          'locations soft-delete refused: location $locationId still '
          'has active user_roles/auth_invites targets; revoke or '
          'reassign them before deleting',
        );
      }
      return exec.execute(
        'update locations '
        'set deleted_at = now(), updated_at = now() '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid '
        'and deleted_at is null',
        parameters: <String, Object?>{
          'location_id': locationId,
          'operator_id': operatorId,
        },
      );
    }, reason: adminReason);
  }
}

class LocationAdminRow {
  const LocationAdminRow({
    required this.locationId,
    required this.operatorId,
    required this.parentOrgUnitId,
    required this.name,
    required this.address,
    required this.timezone,
    required this.businessDayRolloverHour,
    this.suspendedAt,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String locationId;
  final String operatorId;
  final String parentOrgUnitId;
  final String name;
  final String address;
  final String timezone;
  final int? businessDayRolloverHour;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'location_id': locationId,
    'operator_id': operatorId,
    'parent_org_unit_id': parentOrgUnitId,
    'name': name,
    'address': address,
    'timezone': timezone,
    'business_day_rollover_hour': businessDayRolloverHour,
    'suspended_at': suspendedAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

LocationAdminRow _locationAdminRowFromMap(PostgresRow row) {
  return LocationAdminRow(
    locationId: row['location_id']! as String,
    operatorId: row['operator_id']! as String,
    parentOrgUnitId: row['parent_org_unit_id']! as String,
    name: row['name']! as String,
    address: (row['address'] as String?) ?? '',
    timezone: row['timezone']! as String,
    businessDayRolloverHour: row['business_day_rollover_hour'] as int?,
    suspendedAt: _toDateTime(row['suspended_at']),
    deletedAt: _toDateTime(row['deleted_at']),
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

/// Wave 2 W-6 backend — return shape for
/// [LocationsRepository.updateLocationTimezone]. Carries the before
/// and after IANA tz strings so the proxy can emit a
/// `operator_location_timezone_updated` audit row with `previous_tz`
/// + `new_tz`.
class LocationTimezoneUpdateRow {
  const LocationTimezoneUpdateRow({
    required this.locationId,
    required this.operatorId,
    required this.previousIanaTimezone,
    required this.ianaTimezone,
    required this.updatedAt,
    required this.locationFound,
  });

  final String locationId;
  final String operatorId;

  /// IANA tz the location carried BEFORE this update. Empty string
  /// when [locationFound] is false (the proxy maps that case to a
  /// 404 and does not emit an audit row).
  final String previousIanaTimezone;

  /// IANA tz the location now carries after the update.
  final String ianaTimezone;

  /// `locations.updated_at` post-UPDATE.
  final DateTime updatedAt;

  /// False when the primary-location pointer was dangling (row
  /// missing or soft-deleted). The proxy maps this to a 404
  /// `location_not_found`.
  final bool locationFound;
}
