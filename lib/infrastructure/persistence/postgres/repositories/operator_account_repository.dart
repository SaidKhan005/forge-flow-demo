// Phase 11W.7 / Wave A2 - operator-account write repository.
//
// Adapter over public.operators that lets the operator-web Account
// settings page edit the editable identity fields:
//
//   business_name, logo_url, preferred_currency, locale_tag,
//   week_start_day, rollover_hour, contact_email, contact_phone
//
// Runs under TenantContext SET LOCAL so RLS confines reads/writes to
// the caller's operator. The proxy's repository pattern is the
// primary defense; RLS is the backup.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class OperatorAccountRepository extends OperatorScopedRepository {
  OperatorAccountRepository(super.tenantWrapper);

  /// Loads the editable account row for [operatorId]. Returns null
  /// when the row is missing (which would only happen on a torn-down
  /// operator and is treated by the proxy as 404 forbidden).
  ///
  /// [locationId] is required by [TenantContext] for SET LOCAL but is
  /// not used by the operators table itself - the caller passes any
  /// real location id under this operator (typically the primary
  /// location), or operatorId as a sentinel that satisfies the UUID
  /// validator without narrowing reads.
  Future<OperatorAccountRow?> load({
    required String operatorId,
    required String locationId,
    String? userId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OperatorAccountRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        '       business_name, '
        '       logo_url, '
        '       preferred_currency, '
        '       locale_tag, '
        '       week_start_day, '
        '       rollover_hour, '
        '       contact_email, '
        '       contact_phone, '
        '       updated_at '
        '  from public.operators '
        ' where operator_id = @operator_id::uuid '
        ' limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return OperatorAccountRow(
        operatorId: row['operator_id']! as String,
        businessName: row['business_name']! as String,
        logoUrl: row['logo_url'] as String?,
        currencyCode: (row['preferred_currency']! as String).trim(),
        localeTag: row['locale_tag']! as String,
        weekStartDay: row['week_start_day']! as String,
        rolloverHour: (row['rollover_hour']! as num).toInt(),
        contactEmail: row['contact_email'] as String?,
        contactPhone: row['contact_phone'] as String?,
        updatedAt: row['updated_at']! as DateTime,
      );
    });
  }

  /// Applies the validated patch in [columnFields] to the operator
  /// row. Returns the resolved row after the update; null when the
  /// row is missing. The caller (the proxy gateway) is responsible
  /// for translating the validated wire keys (camelCase) into column
  /// names (snake_case) before calling this method.
  Future<OperatorAccountRow?> patch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> columnFields,
    String? userId,
  }) {
    if (columnFields.isEmpty) {
      return load(
        operatorId: operatorId,
        locationId: locationId,
        userId: userId,
      );
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<OperatorAccountRow?>(ctx, (exec) async {
      final setClauses = <String>[];
      final params = <String, Object?>{'operator_id': operatorId};
      for (final entry in columnFields.entries) {
        final column = entry.key;
        final paramName = 'col_$column';
        setClauses.add('$column = @$paramName');
        params[paramName] = entry.value;
      }
      // updated_at maintained by cloud_foundation_set_updated_at
      // BEFORE-UPDATE trigger; do not touch from app code.
      final affected = await exec.execute(
        'update public.operators '
        '   set ${setClauses.join(', ')} '
        ' where operator_id = @operator_id::uuid',
        parameters: params,
      );
      if (affected == 0) return null;

      // Re-load through the same SET LOCAL so RLS verifies a second
      // time before the row escapes to the client.
      final rows = await exec.query(
        'select operator_id::text as operator_id, '
        '       business_name, '
        '       logo_url, '
        '       preferred_currency, '
        '       locale_tag, '
        '       week_start_day, '
        '       rollover_hour, '
        '       contact_email, '
        '       contact_phone, '
        '       updated_at '
        '  from public.operators '
        ' where operator_id = @operator_id::uuid '
        ' limit 1',
        parameters: <String, Object?>{'operator_id': operatorId},
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return OperatorAccountRow(
        operatorId: row['operator_id']! as String,
        businessName: row['business_name']! as String,
        logoUrl: row['logo_url'] as String?,
        currencyCode: (row['preferred_currency']! as String).trim(),
        localeTag: row['locale_tag']! as String,
        weekStartDay: row['week_start_day']! as String,
        rolloverHour: (row['rollover_hour']! as num).toInt(),
        contactEmail: row['contact_email'] as String?,
        contactPhone: row['contact_phone'] as String?,
        updatedAt: row['updated_at']! as DateTime,
      );
    });
  }
}

class OperatorAccountRow {
  const OperatorAccountRow({
    required this.operatorId,
    required this.businessName,
    required this.logoUrl,
    required this.currencyCode,
    required this.localeTag,
    required this.weekStartDay,
    required this.rolloverHour,
    required this.contactEmail,
    required this.contactPhone,
    required this.updatedAt,
  });

  final String operatorId;
  final String businessName;
  final String? logoUrl;
  final String currencyCode;
  final String localeTag;
  final String weekStartDay;
  final int rolloverHour;
  final String? contactEmail;
  final String? contactPhone;
  final DateTime updatedAt;
}
