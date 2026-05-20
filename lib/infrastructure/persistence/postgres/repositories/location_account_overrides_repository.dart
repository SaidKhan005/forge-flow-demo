// Wave 2 U-FU-hp11-account — LocationAccountOverridesRepository.
//
// Persistence layer for the per-(operator, location) override table
// added by `db/migrations/202605150200_phase_u_fu_hp11_account_per_location_overrides.sql`.
// Each override row carries optional overrides for the three
// AccountScreen settings cards (region + business-day + identity
// contact email + phone). NULL columns inherit the business default
// from `public.operators`.
//
// HP #4 per-(operator, location) isolation
// ----------------------------------------
// Every read and write goes through
// [OperatorScopedRepository.withTenant]; RLS on
// `public.location_account_overrides` is the backup defence. The
// composite PK + composite FK back to `public.locations` keeps
// cross-tenant misuse impossible at the database layer.
//
// HP #11 operator decision (2026-05-14) — per-location with business
// fallback. The proxy route reads + writes through this repository
// and computes the effective inheritance line server-side; the
// AccountScreen sees only effective values.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

/// Resolved override row keyed by `(operator_id, location_id)`. Every
/// field except the IDs is nullable — a NULL value means the location
/// inherits the business default for that column.
class LocationAccountOverridesRow {
  const LocationAccountOverridesRow({
    required this.operatorId,
    required this.locationId,
    required this.ianaTimezone,
    required this.localeCode,
    required this.currencyCode,
    required this.businessDayRolloverHour,
    required this.contactEmail,
    required this.contactPhone,
    required this.createdAt,
    required this.updatedAt,
    this.createdByUserId,
    this.updatedByUserId,
  });

  final String operatorId;
  final String locationId;
  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdByUserId;
  final String? updatedByUserId;

  /// True when every override column is NULL — the row exists but is
  /// "no override on file", which is functionally equivalent to a
  /// missing row from the inheritance resolver's perspective.
  bool get isEmpty =>
      ianaTimezone == null &&
      localeCode == null &&
      currencyCode == null &&
      businessDayRolloverHour == null &&
      contactEmail == null &&
      contactPhone == null;
}

/// Patch payload for [LocationAccountOverridesRepository.upsertOverrides].
/// Every field is optional; the upsert writes only the columns the
/// caller actually supplies. Use the `clear*` sentinels to explicitly
/// reset an override column back to NULL (i.e. "stop overriding;
/// inherit the business default").
class LocationAccountOverridesPatch {
  const LocationAccountOverridesPatch({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
    this.clearIanaTimezone = false,
    this.clearLocaleCode = false,
    this.clearCurrencyCode = false,
    this.clearBusinessDayRolloverHour = false,
    this.clearContactEmail = false,
    this.clearContactPhone = false,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;

  // Explicit clear flags so the caller can distinguish "leave alone"
  // (field omitted in the request body) from "reset to inherit" (field
  // present with a null value).
  final bool clearIanaTimezone;
  final bool clearLocaleCode;
  final bool clearCurrencyCode;
  final bool clearBusinessDayRolloverHour;
  final bool clearContactEmail;
  final bool clearContactPhone;

  /// True when the patch carries no field changes at all. The proxy
  /// route maps this to `400 no_fields_to_update`.
  bool get isEmpty =>
      ianaTimezone == null &&
      !clearIanaTimezone &&
      localeCode == null &&
      !clearLocaleCode &&
      currencyCode == null &&
      !clearCurrencyCode &&
      businessDayRolloverHour == null &&
      !clearBusinessDayRolloverHour &&
      contactEmail == null &&
      !clearContactEmail &&
      contactPhone == null &&
      !clearContactPhone;

  /// Wire field names this patch will write. Mirrors the request body
  /// keys; the audit row uses this list to capture exactly which
  /// fields the operator changed.
  List<String> get changedFieldNames {
    return <String>[
      if (ianaTimezone != null || clearIanaTimezone) 'ianaTimezone',
      if (localeCode != null || clearLocaleCode) 'localeCode',
      if (currencyCode != null || clearCurrencyCode) 'currencyCode',
      if (businessDayRolloverHour != null || clearBusinessDayRolloverHour)
        'businessDayRolloverHour',
      if (contactEmail != null || clearContactEmail) 'contactEmail',
      if (contactPhone != null || clearContactPhone) 'contactPhone',
    ];
  }
}

/// Repository over `public.location_account_overrides`. Every method
/// runs through `OperatorScopedRepository.withTenant` per HP #4.
class LocationAccountOverridesRepository extends OperatorScopedRepository {
  LocationAccountOverridesRepository(super.tenantWrapper);

  /// SELECT the override row for `(operatorId, locationId)`. Returns
  /// null when the row does not exist (the location inherits every
  /// business default).
  Future<LocationAccountOverridesRow?> getOverrides({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<LocationAccountOverridesRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectList '
        'from public.location_account_overrides '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      if (rows.isEmpty) return null;
      return _rowFromMap(rows.single);
    });
  }

  /// UPSERT the override row. Only the columns the [patch] carries are
  /// rewritten; columns NOT in the patch keep their existing value.
  /// `clear*` flags rewrite the column to NULL.
  ///
  /// Returns the resolved row after the upsert.
  Future<LocationAccountOverridesRow> upsertOverrides({
    required String operatorId,
    required String locationId,
    required LocationAccountOverridesPatch patch,
    String? actorUserId,
  }) {
    if (patch.isEmpty) {
      throw const LocationAccountOverridesInputError(
        field: 'patch',
        message: 'at least one field must be set or cleared',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<LocationAccountOverridesRow>(ctx, (exec) async {
      // INSERT ... ON CONFLICT DO UPDATE rewrites only the supplied
      // columns. EXCLUDED-namespace coalesce handles "patch omits the
      // key" semantics: when the column is absent in the patch, the
      // EXCLUDED value is the same as the existing value (because we
      // pass the prior value through @<field>_value in the parameters
      // map) so the column stays put. When the column is in the patch,
      // the new value wins.
      //
      // For "clear" semantics we pass NULL explicitly and use the
      // matching @<field>_clear boolean to force NULL through the
      // coalesce.
      final existing = await exec.query(
        'select $_selectList '
        'from public.location_account_overrides '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'for update',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      final priorRow = existing.isEmpty ? null : _rowFromMap(existing.single);
      // Compute the merged column values: patch wins, then existing
      // wins, then NULL.
      final mergedIanaTimezone = patch.clearIanaTimezone
          ? null
          : (patch.ianaTimezone ?? priorRow?.ianaTimezone);
      final mergedLocaleCode = patch.clearLocaleCode
          ? null
          : (patch.localeCode ?? priorRow?.localeCode);
      final mergedCurrencyCode = patch.clearCurrencyCode
          ? null
          : (patch.currencyCode ?? priorRow?.currencyCode);
      final mergedBusinessDayRolloverHour = patch.clearBusinessDayRolloverHour
          ? null
          : (patch.businessDayRolloverHour ??
                priorRow?.businessDayRolloverHour);
      final mergedContactEmail = patch.clearContactEmail
          ? null
          : (patch.contactEmail ?? priorRow?.contactEmail);
      final mergedContactPhone = patch.clearContactPhone
          ? null
          : (patch.contactPhone ?? priorRow?.contactPhone);

      final rows = await exec.query(
        'insert into public.location_account_overrides ('
        'operator_id, location_id, iana_timezone, locale_code, '
        'currency_code, business_day_rollover_hour, contact_email, '
        'contact_phone, created_by_user_id, updated_by_user_id'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@iana_timezone, @locale_code, @currency_code, '
        '@business_day_rollover_hour, @contact_email, @contact_phone, '
        '@actor_user_id::uuid, @actor_user_id::uuid'
        ') on conflict (operator_id, location_id) do update set '
        'iana_timezone = excluded.iana_timezone, '
        'locale_code = excluded.locale_code, '
        'currency_code = excluded.currency_code, '
        'business_day_rollover_hour = excluded.business_day_rollover_hour, '
        'contact_email = excluded.contact_email, '
        'contact_phone = excluded.contact_phone, '
        'updated_by_user_id = excluded.updated_by_user_id, '
        'updated_at = now() '
        'returning $_selectList',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'iana_timezone': mergedIanaTimezone,
          'locale_code': mergedLocaleCode,
          'currency_code': mergedCurrencyCode,
          'business_day_rollover_hour': mergedBusinessDayRolloverHour,
          'contact_email': mergedContactEmail,
          'contact_phone': mergedContactPhone,
          'actor_user_id': _uuidOrNull(actorUserId),
        },
      );
      if (rows.isEmpty) {
        throw StateError('location_account_overrides upsert returned no row');
      }
      final merged = _rowFromMap(rows.single);

      // If the patch wrote a business_day_rollover_hour override (or
      // cleared it), mirror the value into public.locations so
      // legacy readers and the existing business-timing resolver
      // stay coherent. The mirror is the canonical home for
      // runtime cycle logic; this override row is the AccountScreen-
      // level surface that drove the change. See the migration file
      // header for the full rationale.
      if (patch.businessDayRolloverHour != null ||
          patch.clearBusinessDayRolloverHour) {
        await exec.execute(
          'update public.locations '
          'set business_day_rollover_hour = '
          'coalesce(@business_day_rollover_hour, business_day_rollover_hour), '
          'updated_at = now() '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and deleted_at is null',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'business_day_rollover_hour': merged.businessDayRolloverHour,
          },
        );
      }
      return merged;
    });
  }

  /// DELETE the override row entirely. Equivalent to clearing every
  /// column at once: the location reverts to inheriting every business
  /// default. Returns true when a row was deleted, false when the row
  /// did not exist.
  Future<bool> deleteOverrides({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<bool>(ctx, (exec) async {
      final affected = await exec.execute(
        'delete from public.location_account_overrides '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return affected > 0;
    });
  }

  /// Resolve the effective + override + business-default triple in a
  /// single tenant-scoped read. The proxy route returns this shape so
  /// the AccountScreen can render the HP #11 inheritance line without
  /// a second round-trip.
  ///
  /// Returns null when the location row does not belong to [operatorId]
  /// (the proxy maps this to 400 `location_not_owned`) or has been
  /// soft-deleted. The boolean second element is true when the
  /// location row was found at all (false maps to 404 location_not_found).
  Future<LocationAccountOverridesResolved?> loadEffective({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<LocationAccountOverridesResolved?>(ctx, (exec) async {
      // Confirm the (operator_id, location_id) pair exists and is not
      // soft-deleted. Returns null when the row is absent / soft-
      // deleted entirely (locationFound = false on the wire envelope
      // maps to 404). Returns the row when it belongs to a different
      // operator — but tenant RLS already blocks cross-tenant reads,
      // so a "different operator owns this id" lookup never reaches
      // the repository.
      final locationRows = await exec.query(
        'select location_id::text as location_id, '
        'business_day_rollover_hour, timezone, deleted_at '
        'from public.locations '
        'where location_id = @location_id::uuid '
        'and operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      if (locationRows.isEmpty) {
        return LocationAccountOverridesResolved._notFound();
      }
      final locationRow = locationRows.single;
      if (locationRow['deleted_at'] != null) {
        return LocationAccountOverridesResolved._notFound();
      }
      final locationTimezone = locationRow['timezone'] as String?;
      final locationRollover = locationRow['business_day_rollover_hour'] is num
          ? (locationRow['business_day_rollover_hour']! as num).toInt()
          : null;
      // Read the business defaults from public.operators. RLS confines
      // the read to the caller's operator row.
      final operatorRows = await exec.query(
        'select preferred_currency, locale_tag, week_start_day, '
        'rollover_hour '
        'from public.operators '
        'where operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (operatorRows.isEmpty) {
        // Operator row missing while a location row exists is a torn-
        // down operator; surface as not-found so the proxy maps to 404.
        return LocationAccountOverridesResolved._notFound();
      }
      final operatorRow = operatorRows.single;
      final inheritedRows = await exec.query(
        'select '
        '  (select o.iana_timezone '
        '   from public.org_unit_account_overrides o '
        '   join public.org_units ou '
        '     on ou.operator_id = o.operator_id '
        '    and ou.id = o.org_unit_id '
        '   join public.locations loc '
        '     on loc.operator_id = o.operator_id '
        '    and loc.location_id = @location_id::uuid '
        '   where o.operator_id = @operator_id::uuid '
        '     and loc.deleted_at is null '
        '     and ou.deleted_at is null '
        '     and ou.path @> loc.org_unit_path '
        '     and o.iana_timezone is not null '
        '   order by nlevel(ou.path) desc '
        '   limit 1) as iana_timezone, '
        '  (select o.locale_code '
        '   from public.org_unit_account_overrides o '
        '   join public.org_units ou '
        '     on ou.operator_id = o.operator_id '
        '    and ou.id = o.org_unit_id '
        '   join public.locations loc '
        '     on loc.operator_id = o.operator_id '
        '    and loc.location_id = @location_id::uuid '
        '   where o.operator_id = @operator_id::uuid '
        '     and loc.deleted_at is null '
        '     and ou.deleted_at is null '
        '     and ou.path @> loc.org_unit_path '
        '     and o.locale_code is not null '
        '   order by nlevel(ou.path) desc '
        '   limit 1) as locale_code, '
        '  (select o.currency_code '
        '   from public.org_unit_account_overrides o '
        '   join public.org_units ou '
        '     on ou.operator_id = o.operator_id '
        '    and ou.id = o.org_unit_id '
        '   join public.locations loc '
        '     on loc.operator_id = o.operator_id '
        '    and loc.location_id = @location_id::uuid '
        '   where o.operator_id = @operator_id::uuid '
        '     and loc.deleted_at is null '
        '     and ou.deleted_at is null '
        '     and ou.path @> loc.org_unit_path '
        '     and o.currency_code is not null '
        '   order by nlevel(ou.path) desc '
        '   limit 1) as currency_code, '
        '  (select o.contact_email '
        '   from public.org_unit_account_overrides o '
        '   join public.org_units ou '
        '     on ou.operator_id = o.operator_id '
        '    and ou.id = o.org_unit_id '
        '   join public.locations loc '
        '     on loc.operator_id = o.operator_id '
        '    and loc.location_id = @location_id::uuid '
        '   where o.operator_id = @operator_id::uuid '
        '     and loc.deleted_at is null '
        '     and ou.deleted_at is null '
        '     and ou.path @> loc.org_unit_path '
        '     and o.contact_email is not null '
        '   order by nlevel(ou.path) desc '
        '   limit 1) as contact_email, '
        '  (select o.contact_phone '
        '   from public.org_unit_account_overrides o '
        '   join public.org_units ou '
        '     on ou.operator_id = o.operator_id '
        '    and ou.id = o.org_unit_id '
        '   join public.locations loc '
        '     on loc.operator_id = o.operator_id '
        '    and loc.location_id = @location_id::uuid '
        '   where o.operator_id = @operator_id::uuid '
        '     and loc.deleted_at is null '
        '     and ou.deleted_at is null '
        '     and ou.path @> loc.org_unit_path '
        '     and o.contact_phone is not null '
        '   order by nlevel(ou.path) desc '
        '   limit 1) as contact_phone',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      final inheritedRow = inheritedRows.isEmpty
          ? const <String, Object?>{}
          : inheritedRows.single;
      final businessDefault = LocationAccountOverridesDefaults(
        ianaTimezone:
            _optionalString(inheritedRow, 'iana_timezone') ?? locationTimezone,
        localeCode:
            _optionalString(inheritedRow, 'locale_code') ??
            operatorRow['locale_tag'] as String?,
        currencyCode:
            _optionalString(inheritedRow, 'currency_code') ??
            (operatorRow['preferred_currency'] as String?)?.trim(),
        businessDayRolloverHour: operatorRow['rollover_hour'] is num
            ? (operatorRow['rollover_hour']! as num).toInt()
            : null,
        contactEmail: _optionalString(inheritedRow, 'contact_email'),
        contactPhone: _optionalString(inheritedRow, 'contact_phone'),
      );
      // Override row (may be absent).
      final overrideRows = await exec.query(
        'select $_selectList '
        'from public.location_account_overrides '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      final overrideRow = overrideRows.isEmpty
          ? null
          : _rowFromMap(overrideRows.single);
      // If the override row doesn't carry a business_day_rollover_hour
      // but the legacy locations column does, expose the legacy value
      // as the "effective" (so historical per-location rollover settings
      // continue to surface even before an override row is written).
      // The override surface itself is null in that case.
      final effectiveRolloverHour =
          overrideRow?.businessDayRolloverHour ??
          locationRollover ??
          businessDefault.businessDayRolloverHour;
      final effective = LocationAccountOverridesDefaults(
        ianaTimezone: overrideRow?.ianaTimezone ?? businessDefault.ianaTimezone,
        localeCode: overrideRow?.localeCode ?? businessDefault.localeCode,
        currencyCode: overrideRow?.currencyCode ?? businessDefault.currencyCode,
        businessDayRolloverHour: effectiveRolloverHour,
        contactEmail: overrideRow?.contactEmail ?? businessDefault.contactEmail,
        contactPhone: overrideRow?.contactPhone ?? businessDefault.contactPhone,
      );
      return LocationAccountOverridesResolved._ok(
        operatorId: operatorId,
        locationId: locationId,
        effective: effective,
        override: LocationAccountOverridesDefaults(
          ianaTimezone: overrideRow?.ianaTimezone,
          localeCode: overrideRow?.localeCode,
          currencyCode: overrideRow?.currencyCode,
          businessDayRolloverHour: overrideRow?.businessDayRolloverHour,
          contactEmail: overrideRow?.contactEmail,
          contactPhone: overrideRow?.contactPhone,
        ),
        businessDefault: businessDefault,
        updatedAt: overrideRow?.updatedAt ?? DateTime.now().toUtc(),
      );
    });
  }

  static const String _selectList =
      'operator_id::text as operator_id, '
      'location_id::text as location_id, '
      'iana_timezone, locale_code, currency_code, '
      'business_day_rollover_hour, contact_email, contact_phone, '
      'created_at, updated_at, '
      'created_by_user_id::text as created_by_user_id, '
      'updated_by_user_id::text as updated_by_user_id';

  static LocationAccountOverridesRow _rowFromMap(PostgresRow row) {
    final rolloverRaw = row['business_day_rollover_hour'];
    final int? rolloverHour;
    if (rolloverRaw == null) {
      rolloverHour = null;
    } else if (rolloverRaw is int) {
      rolloverHour = rolloverRaw;
    } else if (rolloverRaw is num) {
      rolloverHour = rolloverRaw.toInt();
    } else if (rolloverRaw is String) {
      rolloverHour = int.tryParse(rolloverRaw);
    } else {
      rolloverHour = null;
    }
    return LocationAccountOverridesRow(
      operatorId: _requiredString(row, 'operator_id'),
      locationId: _requiredString(row, 'location_id'),
      ianaTimezone: _optionalString(row, 'iana_timezone'),
      localeCode: _optionalString(row, 'locale_code'),
      currencyCode: _optionalString(row, 'currency_code'),
      businessDayRolloverHour: rolloverHour,
      contactEmail: _optionalString(row, 'contact_email'),
      contactPhone: _optionalString(row, 'contact_phone'),
      createdAt: _requiredDate(row, 'created_at'),
      updatedAt: _requiredDate(row, 'updated_at'),
      createdByUserId: _optionalString(row, 'created_by_user_id'),
      updatedByUserId: _optionalString(row, 'updated_by_user_id'),
    );
  }

  static String _requiredString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    throw StateError('location_account_overrides row missing $key');
  }

  static String? _optionalString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static DateTime _requiredDate(PostgresRow row, String key) {
    final value = row[key];
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    throw StateError('location_account_overrides row missing timestamptz $key');
  }

  static String? _uuidOrNull(String? value) {
    if (value == null) return null;
    return _uuidPattern.hasMatch(value) ? value : null;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

/// Sub-record carried inside [LocationAccountOverridesResolved] — one
/// of `effective` / `override` / `businessDefault`. Every field is
/// nullable.
class LocationAccountOverridesDefaults {
  const LocationAccountOverridesDefaults({
    this.ianaTimezone,
    this.localeCode,
    this.currencyCode,
    this.businessDayRolloverHour,
    this.contactEmail,
    this.contactPhone,
  });

  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final int? businessDayRolloverHour;
  final String? contactEmail;
  final String? contactPhone;
}

/// Wire-shape envelope the proxy route serialises. Either carries the
/// resolved triple or signals that the location row was not found.
class LocationAccountOverridesResolved {
  const LocationAccountOverridesResolved._({
    required this.locationFound,
    required this.operatorId,
    required this.locationId,
    required this.effective,
    required this.override,
    required this.businessDefault,
    required this.updatedAt,
  });

  /// Convenience factory for "location not found / soft-deleted" —
  /// the proxy route turns this into a 404.
  factory LocationAccountOverridesResolved._notFound() {
    return LocationAccountOverridesResolved._(
      locationFound: false,
      operatorId: '',
      locationId: '',
      effective: const LocationAccountOverridesDefaults(),
      override: const LocationAccountOverridesDefaults(),
      businessDefault: const LocationAccountOverridesDefaults(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Convenience factory for the "ok" path.
  factory LocationAccountOverridesResolved._ok({
    required String operatorId,
    required String locationId,
    required LocationAccountOverridesDefaults effective,
    required LocationAccountOverridesDefaults override,
    required LocationAccountOverridesDefaults businessDefault,
    required DateTime updatedAt,
  }) {
    return LocationAccountOverridesResolved._(
      locationFound: true,
      operatorId: operatorId,
      locationId: locationId,
      effective: effective,
      override: override,
      businessDefault: businessDefault,
      updatedAt: updatedAt,
    );
  }

  final bool locationFound;
  final String operatorId;
  final String locationId;
  final LocationAccountOverridesDefaults effective;
  final LocationAccountOverridesDefaults override;
  final LocationAccountOverridesDefaults businessDefault;
  final DateTime updatedAt;
}

/// Validation failure thrown by the repository when its caller passes
/// a malformed patch. The proxy route turns this into a 400 body.
class LocationAccountOverridesInputError implements Exception {
  const LocationAccountOverridesInputError({
    required this.field,
    required this.message,
  });

  final String field;
  final String message;

  @override
  String toString() => 'LocationAccountOverridesInputError($field): $message';
}
