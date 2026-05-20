// Brand/account scope: OrgUnitAccountOverridesRepository.
//
// Stores account-setting overrides for org_units rows. The selected org unit
// gets its own override row; missing columns inherit from the nearest ancestor
// row, then the Business default in public.operators. Location-specific
// overrides remain in LocationAccountOverridesRepository.

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';
import 'location_account_overrides_repository.dart'
    show
        LocationAccountOverridesDefaults,
        LocationAccountOverridesPatch,
        LocationAccountOverridesSource,
        LocationAccountOverridesSources;

class OrgUnitAccountOverridesRow {
  const OrgUnitAccountOverridesRow({
    required this.operatorId,
    required this.orgUnitId,
    required this.ianaTimezone,
    required this.localeCode,
    required this.currencyCode,
    required this.contactEmail,
    required this.contactPhone,
    required this.createdAt,
    required this.updatedAt,
    this.createdByUserId,
    this.updatedByUserId,
  });

  final String operatorId;
  final String orgUnitId;
  final String? ianaTimezone;
  final String? localeCode;
  final String? currencyCode;
  final String? contactEmail;
  final String? contactPhone;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdByUserId;
  final String? updatedByUserId;
}

class OrgUnitAccountOverridesRepository extends OperatorScopedRepository {
  OrgUnitAccountOverridesRepository(super.tenantWrapper);

  Future<OrgUnitAccountOverridesResolved?> loadEffective({
    required String operatorId,
    required String orgUnitId,
    String? actorUserId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      // Org-unit scoped reads need a UUID for SET LOCAL location context even
      // when the row is not location-bound. Existing operator-wide repositories
      // use operatorId as the sentinel for this shape.
      locationId: operatorId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<OrgUnitAccountOverridesResolved?>(ctx, (exec) async {
      final rows = await exec.query(
        'with selected_scope as ('
        '  select id, path, name, unit_type '
        '  from public.org_units '
        '  where operator_id = @operator_id::uuid '
        '    and id = @org_unit_id::uuid '
        "    and unit_type <> 'corp' "
        '    and deleted_at is null '
        '  limit 1'
        '), selected_override as ('
        '  select o.* '
        '  from public.org_unit_account_overrides o '
        '  join selected_scope s on s.id = o.org_unit_id '
        '  where o.operator_id = @operator_id::uuid'
        '), ancestor_overrides as ('
        '  select ou.id::text as source_id, ou.unit_type as source_type, '
        '         ou.name as source_label, o.iana_timezone, o.locale_code, '
        '         o.currency_code, o.contact_email, o.contact_phone '
        '  from public.org_unit_account_overrides o '
        '  join public.org_units ou '
        '    on ou.operator_id = o.operator_id '
        '   and ou.id = o.org_unit_id '
        '  join selected_scope s on ou.path @> s.path '
        '  where o.operator_id = @operator_id::uuid '
        '    and ou.id <> s.id '
        '    and ou.deleted_at is null '
        '  order by nlevel(ou.path) desc '
        '), parent_defaults as ('
        '  select '
        '    (select iana_timezone from ancestor_overrides '
        '     where iana_timezone is not null limit 1) as iana_timezone, '
        '    (select source_id from ancestor_overrides '
        '     where iana_timezone is not null limit 1) '
        '     as iana_timezone_source_id, '
        '    (select source_type from ancestor_overrides '
        '     where iana_timezone is not null limit 1) '
        '     as iana_timezone_source_type, '
        '    (select source_label from ancestor_overrides '
        '     where iana_timezone is not null limit 1) '
        '     as iana_timezone_source_label, '
        '    (select locale_code from ancestor_overrides '
        '     where locale_code is not null limit 1) as locale_code, '
        '    (select source_id from ancestor_overrides '
        '     where locale_code is not null limit 1) as locale_code_source_id, '
        '    (select source_type from ancestor_overrides '
        '     where locale_code is not null limit 1) '
        '     as locale_code_source_type, '
        '    (select source_label from ancestor_overrides '
        '     where locale_code is not null limit 1) '
        '     as locale_code_source_label, '
        '    (select currency_code from ancestor_overrides '
        '     where currency_code is not null limit 1) as currency_code, '
        '    (select source_id from ancestor_overrides '
        '     where currency_code is not null limit 1) '
        '     as currency_code_source_id, '
        '    (select source_type from ancestor_overrides '
        '     where currency_code is not null limit 1) '
        '     as currency_code_source_type, '
        '    (select source_label from ancestor_overrides '
        '     where currency_code is not null limit 1) '
        '     as currency_code_source_label, '
        '    (select contact_email from ancestor_overrides '
        '     where contact_email is not null limit 1) as contact_email, '
        '    (select source_id from ancestor_overrides '
        '     where contact_email is not null limit 1) '
        '     as contact_email_source_id, '
        '    (select source_type from ancestor_overrides '
        '     where contact_email is not null limit 1) '
        '     as contact_email_source_type, '
        '    (select source_label from ancestor_overrides '
        '     where contact_email is not null limit 1) '
        '     as contact_email_source_label, '
        '    (select contact_phone from ancestor_overrides '
        '     where contact_phone is not null limit 1) as contact_phone, '
        '    (select source_id from ancestor_overrides '
        '     where contact_phone is not null limit 1) '
        '     as contact_phone_source_id, '
        '    (select source_type from ancestor_overrides '
        '     where contact_phone is not null limit 1) '
        '     as contact_phone_source_type, '
        '    (select source_label from ancestor_overrides '
        '     where contact_phone is not null limit 1) '
        '     as contact_phone_source_label'
        ') '
        'select '
        '  s.id::text as org_unit_id, '
        '  s.name as selected_scope_name, '
        '  s.unit_type as selected_scope_unit_type, '
        '  so.operator_id::text as override_operator_id, '
        '  so.org_unit_id::text as override_org_unit_id, '
        '  so.iana_timezone as override_iana_timezone, '
        '  so.locale_code as override_locale_code, '
        '  so.currency_code as override_currency_code, '
        '  so.contact_email as override_contact_email, '
        '  so.contact_phone as override_contact_phone, '
        '  so.created_at as override_created_at, '
        '  so.updated_at as override_updated_at, '
        '  so.created_by_user_id::text as override_created_by_user_id, '
        '  so.updated_by_user_id::text as override_updated_by_user_id, '
        '  parent.iana_timezone as parent_iana_timezone, '
        '  parent.locale_code as parent_locale_code, '
        '  parent.currency_code as parent_currency_code, '
        '  parent.contact_email as parent_contact_email, '
        '  parent.contact_phone as parent_contact_phone, '
        '  parent.iana_timezone_source_id, '
        '  parent.iana_timezone_source_type, '
        '  parent.iana_timezone_source_label, '
        '  parent.locale_code_source_id, '
        '  parent.locale_code_source_type, '
        '  parent.locale_code_source_label, '
        '  parent.currency_code_source_id, '
        '  parent.currency_code_source_type, '
        '  parent.currency_code_source_label, '
        '  parent.contact_email_source_id, '
        '  parent.contact_email_source_type, '
        '  parent.contact_email_source_label, '
        '  parent.contact_phone_source_id, '
        '  parent.contact_phone_source_type, '
        '  parent.contact_phone_source_label, '
        '  op.business_name as operator_business_name, '
        '  op.locale_tag as operator_locale_code, '
        '  op.preferred_currency as operator_currency_code, '
        '  primary_loc.location_id::text as operator_timezone_location_id, '
        '  primary_loc.name as operator_timezone_location_name, '
        '  primary_loc.timezone as operator_iana_timezone, '
        '  op.updated_at as operator_updated_at '
        'from selected_scope s '
        'cross join public.operators op '
        'cross join parent_defaults parent '
        'left join selected_override so on true '
        'left join public.locations primary_loc '
        '  on primary_loc.operator_id = op.operator_id '
        ' and primary_loc.location_id = op.primary_location_id '
        ' and primary_loc.deleted_at is null '
        'where op.operator_id = @operator_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
        },
      );
      if (rows.isEmpty) {
        return OrgUnitAccountOverridesResolved._notFound();
      }
      final row = rows.single;
      final override = _overrideFromMap(row, operatorId, orgUnitId);
      final inherited = LocationAccountOverridesDefaults(
        ianaTimezone:
            _optionalString(row, 'parent_iana_timezone') ??
            _optionalString(row, 'operator_iana_timezone'),
        localeCode:
            _optionalString(row, 'parent_locale_code') ??
            _optionalString(row, 'operator_locale_code'),
        currencyCode:
            _optionalString(row, 'parent_currency_code') ??
            _optionalString(row, 'operator_currency_code'),
        contactEmail: _optionalString(row, 'parent_contact_email'),
        contactPhone: _optionalString(row, 'parent_contact_phone'),
      );
      final effective = LocationAccountOverridesDefaults(
        ianaTimezone: override?.ianaTimezone ?? inherited.ianaTimezone,
        localeCode: override?.localeCode ?? inherited.localeCode,
        currencyCode: override?.currencyCode ?? inherited.currencyCode,
        contactEmail: override?.contactEmail ?? inherited.contactEmail,
        contactPhone: override?.contactPhone ?? inherited.contactPhone,
      );
      final selectedScopeName =
          _optionalString(row, 'selected_scope_name') ?? orgUnitId;
      final selectedSource = LocationAccountOverridesSource(
        scopeType: _sourceScopeType(
          _optionalString(row, 'selected_scope_unit_type'),
        ),
        scopeId: orgUnitId,
        scopeLabel: selectedScopeName,
        setHere: true,
      );
      final businessSource = LocationAccountOverridesSource(
        scopeType: 'business',
        scopeId: operatorId,
        scopeLabel:
            _optionalString(row, 'operator_business_name') ?? 'Business',
        setHere: false,
      );
      final sources = LocationAccountOverridesSources(
        ianaTimezone: override?.ianaTimezone != null
            ? selectedSource
            : (_sourceFromRow(row, 'iana_timezone') ??
                  (_optionalString(row, 'operator_iana_timezone') == null
                      ? null
                      : businessSource)),
        localeCode: override?.localeCode != null
            ? selectedSource
            : (_sourceFromRow(row, 'locale_code') ??
                  (_optionalString(row, 'operator_locale_code') == null
                      ? null
                      : businessSource)),
        currencyCode: override?.currencyCode != null
            ? selectedSource
            : (_sourceFromRow(row, 'currency_code') ??
                  (_optionalString(row, 'operator_currency_code') == null
                      ? null
                      : businessSource)),
        contactEmail: override?.contactEmail != null
            ? selectedSource
            : _sourceFromRow(row, 'contact_email'),
        contactPhone: override?.contactPhone != null
            ? selectedSource
            : _sourceFromRow(row, 'contact_phone'),
      );
      return OrgUnitAccountOverridesResolved._ok(
        operatorId: operatorId,
        orgUnitId: orgUnitId,
        effective: effective,
        override: LocationAccountOverridesDefaults(
          ianaTimezone: override?.ianaTimezone,
          localeCode: override?.localeCode,
          currencyCode: override?.currencyCode,
          contactEmail: override?.contactEmail,
          contactPhone: override?.contactPhone,
        ),
        businessDefault: inherited,
        sources: sources,
        updatedAt:
            override?.updatedAt ?? _dateOrNow(row['operator_updated_at']),
      );
    });
  }

  Future<OrgUnitAccountOverridesRow> upsertOverrides({
    required String operatorId,
    required String orgUnitId,
    required LocationAccountOverridesPatch patch,
    String? actorUserId,
  }) {
    if (_orgUnitPatchIsEmpty(patch)) {
      throw const OrgUnitAccountOverridesInputError(
        field: 'patch',
        message: 'at least one org-unit account field must be set or cleared',
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: operatorId,
      userId: _uuidOrNull(actorUserId),
    );
    return withTenant<OrgUnitAccountOverridesRow>(ctx, (exec) async {
      final selectedRows = await exec.query(
        'select id::text as id '
        'from public.org_units '
        'where operator_id = @operator_id::uuid '
        'and id = @org_unit_id::uuid '
        "and unit_type <> 'corp' "
        'and deleted_at is null '
        'limit 1 '
        'for update',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
        },
      );
      if (selectedRows.isEmpty) {
        throw const OrgUnitAccountOverridesInputError(
          field: 'orgUnitId',
          message: 'org unit was not found for this operator',
        );
      }

      final existing = await exec.query(
        'select $_selectList '
        'from public.org_unit_account_overrides '
        'where operator_id = @operator_id::uuid '
        'and org_unit_id = @org_unit_id::uuid '
        'for update',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
        },
      );
      final prior = existing.isEmpty ? null : _rowFromMap(existing.single);
      final mergedIanaTimezone = patch.clearIanaTimezone
          ? null
          : (patch.ianaTimezone ?? prior?.ianaTimezone);
      final mergedLocaleCode = patch.clearLocaleCode
          ? null
          : (patch.localeCode ?? prior?.localeCode);
      final mergedCurrencyCode = patch.clearCurrencyCode
          ? null
          : (patch.currencyCode ?? prior?.currencyCode);
      final mergedContactEmail = patch.clearContactEmail
          ? null
          : (patch.contactEmail ?? prior?.contactEmail);
      final mergedContactPhone = patch.clearContactPhone
          ? null
          : (patch.contactPhone ?? prior?.contactPhone);

      final rows = await exec.query(
        'insert into public.org_unit_account_overrides ('
        'operator_id, org_unit_id, iana_timezone, locale_code, '
        'currency_code, contact_email, contact_phone, '
        'created_by_user_id, updated_by_user_id'
        ') values ('
        '@operator_id::uuid, @org_unit_id::uuid, @iana_timezone, '
        '@locale_code, @currency_code, @contact_email, @contact_phone, '
        '@actor_user_id::uuid, @actor_user_id::uuid'
        ') on conflict (operator_id, org_unit_id) do update set '
        'iana_timezone = excluded.iana_timezone, '
        'locale_code = excluded.locale_code, '
        'currency_code = excluded.currency_code, '
        'contact_email = excluded.contact_email, '
        'contact_phone = excluded.contact_phone, '
        'updated_by_user_id = excluded.updated_by_user_id, '
        'updated_at = now() '
        'returning $_selectList',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'org_unit_id': orgUnitId,
          'iana_timezone': mergedIanaTimezone,
          'locale_code': mergedLocaleCode,
          'currency_code': mergedCurrencyCode,
          'contact_email': mergedContactEmail,
          'contact_phone': mergedContactPhone,
          'actor_user_id': _uuidOrNull(actorUserId),
        },
      );
      if (rows.isEmpty) {
        throw StateError('org_unit_account_overrides upsert returned no row');
      }
      return _rowFromMap(rows.single);
    });
  }

  static const String _selectList =
      'operator_id::text as operator_id, '
      'org_unit_id::text as org_unit_id, '
      'iana_timezone, locale_code, currency_code, '
      'contact_email, contact_phone, '
      'created_at, updated_at, '
      'created_by_user_id::text as created_by_user_id, '
      'updated_by_user_id::text as updated_by_user_id';

  static bool _orgUnitPatchIsEmpty(LocationAccountOverridesPatch patch) {
    return patch.ianaTimezone == null &&
        !patch.clearIanaTimezone &&
        patch.localeCode == null &&
        !patch.clearLocaleCode &&
        patch.currencyCode == null &&
        !patch.clearCurrencyCode &&
        patch.contactEmail == null &&
        !patch.clearContactEmail &&
        patch.contactPhone == null &&
        !patch.clearContactPhone;
  }

  static OrgUnitAccountOverridesRow? _overrideFromMap(
    PostgresRow row,
    String operatorId,
    String orgUnitId,
  ) {
    final overrideId = _optionalString(row, 'override_org_unit_id');
    if (overrideId == null) return null;
    return OrgUnitAccountOverridesRow(
      operatorId: _optionalString(row, 'override_operator_id') ?? operatorId,
      orgUnitId: overrideId,
      ianaTimezone: _optionalString(row, 'override_iana_timezone'),
      localeCode: _optionalString(row, 'override_locale_code'),
      currencyCode: _optionalString(row, 'override_currency_code'),
      contactEmail: _optionalString(row, 'override_contact_email'),
      contactPhone: _optionalString(row, 'override_contact_phone'),
      createdAt: _dateOrNow(row['override_created_at']),
      updatedAt: _dateOrNow(row['override_updated_at']),
      createdByUserId: _optionalString(row, 'override_created_by_user_id'),
      updatedByUserId: _optionalString(row, 'override_updated_by_user_id'),
    );
  }

  static OrgUnitAccountOverridesRow _rowFromMap(PostgresRow row) {
    return OrgUnitAccountOverridesRow(
      operatorId: _requiredString(row, 'operator_id'),
      orgUnitId: _requiredString(row, 'org_unit_id'),
      ianaTimezone: _optionalString(row, 'iana_timezone'),
      localeCode: _optionalString(row, 'locale_code'),
      currencyCode: _optionalString(row, 'currency_code'),
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
    throw StateError('org_unit_account_overrides row missing $key');
  }

  static String? _optionalString(PostgresRow row, String key) {
    final value = row[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    return null;
  }

  static DateTime _requiredDate(PostgresRow row, String key) {
    final value = row[key];
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    throw StateError('org_unit_account_overrides row missing timestamptz $key');
  }

  static DateTime _dateOrNow(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) return DateTime.parse(value).toUtc();
    return DateTime.now().toUtc();
  }

  static LocationAccountOverridesSource? _sourceFromRow(
    PostgresRow row,
    String prefix,
  ) {
    final sourceId = _optionalString(row, '${prefix}_source_id');
    final sourceLabel = _optionalString(row, '${prefix}_source_label');
    if (sourceId == null || sourceLabel == null) return null;
    return LocationAccountOverridesSource(
      scopeType: _sourceScopeType(
        _optionalString(row, '${prefix}_source_type'),
      ),
      scopeId: sourceId,
      scopeLabel: sourceLabel,
      setHere: false,
    );
  }

  static String _sourceScopeType(String? unitType) {
    switch (unitType) {
      case 'brand':
      case 'region':
      case 'district':
      case 'location_group':
        return unitType!;
      default:
        return 'org_unit';
    }
  }

  static String? _uuidOrNull(String? value) {
    if (value == null) return null;
    return _uuidPattern.hasMatch(value) ? value : null;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
}

class OrgUnitAccountOverridesResolved {
  const OrgUnitAccountOverridesResolved._({
    required this.scopeFound,
    required this.operatorId,
    required this.orgUnitId,
    required this.effective,
    required this.override,
    required this.businessDefault,
    required this.sources,
    required this.updatedAt,
  });

  factory OrgUnitAccountOverridesResolved._notFound() {
    return OrgUnitAccountOverridesResolved._(
      scopeFound: false,
      operatorId: '',
      orgUnitId: '',
      effective: const LocationAccountOverridesDefaults(),
      override: const LocationAccountOverridesDefaults(),
      businessDefault: const LocationAccountOverridesDefaults(),
      sources: const LocationAccountOverridesSources(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  factory OrgUnitAccountOverridesResolved._ok({
    required String operatorId,
    required String orgUnitId,
    required LocationAccountOverridesDefaults effective,
    required LocationAccountOverridesDefaults override,
    required LocationAccountOverridesDefaults businessDefault,
    required LocationAccountOverridesSources sources,
    required DateTime updatedAt,
  }) {
    return OrgUnitAccountOverridesResolved._(
      scopeFound: true,
      operatorId: operatorId,
      orgUnitId: orgUnitId,
      effective: effective,
      override: override,
      businessDefault: businessDefault,
      sources: sources,
      updatedAt: updatedAt,
    );
  }

  final bool scopeFound;
  final String operatorId;
  final String orgUnitId;
  final LocationAccountOverridesDefaults effective;
  final LocationAccountOverridesDefaults override;
  final LocationAccountOverridesDefaults businessDefault;
  final LocationAccountOverridesSources sources;
  final DateTime updatedAt;
}

class OrgUnitAccountOverridesInputError implements Exception {
  const OrgUnitAccountOverridesInputError({
    required this.field,
    required this.message,
  });

  final String field;
  final String message;

  @override
  String toString() => 'OrgUnitAccountOverridesInputError($field): $message';
}
