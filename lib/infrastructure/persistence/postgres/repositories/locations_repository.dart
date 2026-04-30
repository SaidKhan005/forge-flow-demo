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
        'operator_id::text as operator_id, name, address, timezone, '
        'business_day_rollover_hour, created_at, updated_at '
        'from locations '
        'where operator_id = @operator_id::uuid '
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
        'operator_id::text as operator_id, name, address, timezone, '
        'business_day_rollover_hour, created_at, updated_at '
        'from locations '
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
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) {
    return withSystem<LocationAdminRow>((exec) async {
      final rows = await exec.query(
        'insert into locations ('
        'operator_id, name, address, timezone, '
        'business_day_rollover_hour'
        ') values ('
        '@operator_id::uuid, @name, @address, '
        '@timezone, @business_day_rollover_hour'
        ') '
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, name, address, timezone, '
        'business_day_rollover_hour, created_at, updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
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
        'returning location_id::text as location_id, '
        'operator_id::text as operator_id, name, address, timezone, '
        'business_day_rollover_hour, created_at, updated_at',
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
      return exec.execute(
        'delete from locations '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid',
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

LocationAdminRow _locationAdminRowFromMap(PostgresRow row) {
  return LocationAdminRow(
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

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
