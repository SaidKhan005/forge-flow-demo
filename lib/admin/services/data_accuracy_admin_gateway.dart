// Phase 8 spine-bridge Lane .C - F&F Ops Console gateway for the
// per-location Data Accuracy admin surface (Tab 1) AND the
// Polling & Pricing surface (Tab 2).
//
// Lane .A repositories
// (`DataAccuracySettingsRepository`, `ForgeFlowPollingTierRepository`)
// own Postgres-side persistence. The admin Flutter web client cannot
// reach Postgres directly, so the .A repos are wrapped behind this
// gateway abstraction in production (HTTP gateway → admin proxy →
// repo) and short-circuited to an in-memory implementation for the
// `kDemoMode` walkthrough + widget tests. Per `Files to LEAVE ALONE`
// the lane does NOT modify the .A repository - the gateway is the
// only seam this slice introduces alongside the screen + widgets.
//
// Authority: `docs/contracts/data_accuracy_settings_contract.md`
// "Surface scope → F&F Ops Console - per-location admin surface".
//
// Hard rules from the contract honoured here:
//
//   * Every admin write inserts an `audit_logs` row with
//     `actor_kind = 'forge_admin'`, the diff payload, and the reason
//     note. The in-memory gateway exposes a captured-event list so
//     widget tests assert the audit row landed.
//   * forge_admin role is required for every write. The screen layer
//     hides the affordances when the signed-in admin is not super_admin
//     (mirrors the pricing tier admin pattern); the gateway is the
//     defence-in-depth - calls without `actorIsForgeAdmin: true`
//     throw [DataAccuracyAdminForbiddenException].

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import 'admin_http_timeout.dart';

typedef DataAccuracyAdminBearerTokenProvider = Future<String> Function();

/// Vendor IDs the polling-tier model knows about. Mirrors the five
/// poll-only vendors named in the contract; webhook vendors do not
/// appear because cadence does not apply to them.
const List<String> kPollOnlyVendorIds = <String>[
  'oracle_micros_simphony',
  'quickbooks_time',
  'humanity',
  'agendrix',
  'push_operations',
];

const Map<String, String> kPollOnlyVendorDisplayNames = <String, String>{
  'oracle_micros_simphony': 'Oracle MICROS Simphony',
  'quickbooks_time': 'QuickBooks Time',
  'humanity': 'Humanity',
  'agendrix': 'Agendrix',
  'push_operations': 'Push Operations',
};

/// Per-vendor minimum cadence in seconds. Picker (and resolver) clamp
/// any custom cadence to this floor. Oracle MICROS Simphony documents
/// a 5-minute minimum; the four subscription-bucket vendors accept
/// 60s. Source: `docs/contracts/data_accuracy_settings_contract.md`
/// "Vendor min/max clamping" + each vendor's `api_consumed.md`
/// "Production environment → Rate-limit policy" section.
const Map<String, int> kPollOnlyVendorMinCadenceSeconds = <String, int>{
  'oracle_micros_simphony': 300,
  'quickbooks_time': 60,
  'humanity': 60,
  'agendrix': 60,
  'push_operations': 60,
};

/// Framework cap on cadence overrides. Beyond 1 hour the dashboard
/// feels broken. Used by the editor + resolver for clamping.
const int kPollCadenceMaxSeconds = 3600;

/// Synthetic vendor ID used in the per-vendor cost breakdown when an
/// assignment carries cost basis but no vendor cadence map (custom
/// tier without per-vendor cadence set yet). The margin rollup card
/// renders this row with the display name below so the per-vendor
/// sum still equals the top-line `totalMonthlyVendorCostCents`.
const String kUnallocatedVendorId = '__unallocated__';
const String kUnallocatedVendorDisplayName = '(no vendor cadence set)';

/// One operator-location row visible to a F&F admin in cross-operator
/// mode. The admin gateway lists every operator-location pair so the
/// Tab 1 / Tab 2 tables can render across operators.
class OperatorLocationRef {
  const OperatorLocationRef({
    required this.operatorId,
    required this.businessName,
    required this.locationId,
    required this.locationName,
  });

  final String operatorId;
  final String businessName;
  final String locationId;
  final String locationName;
}

enum AdminDataAccuracyMutationScopeType {
  business,
  orgUnit,
  location;

  String get wire {
    switch (this) {
      case AdminDataAccuracyMutationScopeType.business:
        return 'business';
      case AdminDataAccuracyMutationScopeType.orgUnit:
        return 'org_unit';
      case AdminDataAccuracyMutationScopeType.location:
        return 'location';
    }
  }
}

extension AdminDataAccuracyMutationScopeTypeWire
    on AdminDataAccuracyMutationScopeType {
  static AdminDataAccuracyMutationScopeType fromWire(String value) {
    switch (value) {
      case 'business':
        return AdminDataAccuracyMutationScopeType.business;
      case 'org_unit':
        return AdminDataAccuracyMutationScopeType.orgUnit;
      case 'location':
        return AdminDataAccuracyMutationScopeType.location;
    }
    throw ArgumentError.value(value, 'scope_type', 'unknown hierarchy scope');
  }
}

class DataAccuracyScopeMutationResult {
  const DataAccuracyScopeMutationResult({
    required this.scopeType,
    required this.operatorId,
    required this.affectedLocationCount,
    required this.rows,
    this.orgUnitId,
    this.locationId,
  });

  final AdminDataAccuracyMutationScopeType scopeType;
  final String operatorId;
  final String? orgUnitId;
  final String? locationId;
  final int affectedLocationCount;
  final List<DataAccuracyAdminRow> rows;
}

class PollingTierScopeMutationResult {
  const PollingTierScopeMutationResult({
    required this.scopeType,
    required this.operatorId,
    required this.affectedLocationCount,
    required this.assignments,
    this.orgUnitId,
    this.locationId,
  });

  final AdminDataAccuracyMutationScopeType scopeType;
  final String operatorId;
  final String? orgUnitId;
  final String? locationId;
  final int affectedLocationCount;
  final List<TierAssignmentAdminRow> assignments;
}

/// Tab 1 row - the per-location data accuracy override view. Mirrors
/// the contract's "Tab 1: Data Accuracy" table columns.
class DataAccuracyAdminRow {
  const DataAccuracyAdminRow({
    required this.operatorRef,
    required this.settings,
  });

  final OperatorLocationRef operatorRef;
  final DataAccuracySettings settings;
}

/// Tab 2 → Card 1 - F&F-engineering tier preset.
class TierDefinition {
  TierDefinition({
    required this.tierKey,
    required this.descriptionMd,
    required this.pollingCadencePerVendorSeconds,
    required this.defaultMonthlyPriceCents,
    required this.vendorApiCostEstimateCentsMonthly,
    required this.lastEditedAt,
    this.lastEditedBy,
  });

  final PollingTierKey tierKey;
  final String descriptionMd;
  final Map<String, int> pollingCadencePerVendorSeconds;
  final int defaultMonthlyPriceCents;
  final int vendorApiCostEstimateCentsMonthly;
  final DateTime lastEditedAt;
  final String? lastEditedBy;

  int get defaultMarginCents =>
      defaultMonthlyPriceCents - vendorApiCostEstimateCentsMonthly;

  TierDefinition copyWith({
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    DateTime? lastEditedAt,
    String? lastEditedBy,
  }) {
    return TierDefinition(
      tierKey: tierKey,
      descriptionMd: descriptionMd ?? this.descriptionMd,
      pollingCadencePerVendorSeconds:
          pollingCadencePerVendorSeconds ?? this.pollingCadencePerVendorSeconds,
      defaultMonthlyPriceCents:
          defaultMonthlyPriceCents ?? this.defaultMonthlyPriceCents,
      vendorApiCostEstimateCentsMonthly:
          vendorApiCostEstimateCentsMonthly ??
          this.vendorApiCostEstimateCentsMonthly,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
      lastEditedBy: lastEditedBy ?? this.lastEditedBy,
    );
  }
}

/// Tab 2 → Card 4 - operator-submitted tier change request.
enum TierChangeRequestStatus { pending, approved, denied, negotiating }

extension TierChangeRequestStatusWire on TierChangeRequestStatus {
  String get wire {
    switch (this) {
      case TierChangeRequestStatus.pending:
        return 'pending';
      case TierChangeRequestStatus.approved:
        return 'approved';
      case TierChangeRequestStatus.denied:
        return 'denied';
      case TierChangeRequestStatus.negotiating:
        return 'negotiating';
    }
  }
}

class TierChangeRequest {
  TierChangeRequest({
    required this.requestId,
    required this.operatorRef,
    required this.currentTier,
    required this.requestedTier,
    required this.operatorNote,
    required this.submittedAt,
    required this.status,
  });

  final String requestId;
  final OperatorLocationRef operatorRef;
  final PollingTierKey currentTier;
  final PollingTierKey requestedTier;
  final String operatorNote;
  final DateTime submittedAt;
  final TierChangeRequestStatus status;

  TierChangeRequest copyWith({TierChangeRequestStatus? status}) {
    return TierChangeRequest(
      requestId: requestId,
      operatorRef: operatorRef,
      currentTier: currentTier,
      requestedTier: requestedTier,
      operatorNote: operatorNote,
      submittedAt: submittedAt,
      status: status ?? this.status,
    );
  }
}

/// Margin-rollup payload - Tab 2 Card 3.
class TierMarginRollup {
  const TierMarginRollup({
    required this.totalMonthlyPriceCents,
    required this.totalMonthlyVendorCostCents,
    required this.perTier,
    required this.perVendor,
  });

  final int totalMonthlyPriceCents;
  final int totalMonthlyVendorCostCents;
  final List<TierMarginPerTier> perTier;
  final List<TierMarginPerVendor> perVendor;

  int get totalMonthlyMarginCents =>
      totalMonthlyPriceCents - totalMonthlyVendorCostCents;

  double? get marginFraction {
    if (totalMonthlyPriceCents <= 0) return null;
    return totalMonthlyMarginCents / totalMonthlyPriceCents;
  }
}

class TierMarginPerTier {
  const TierMarginPerTier({
    required this.tierKey,
    required this.assignmentCount,
    required this.totalMonthlyPriceCents,
    required this.totalMonthlyVendorCostCents,
  });

  final PollingTierKey tierKey;
  final int assignmentCount;
  final int totalMonthlyPriceCents;
  final int totalMonthlyVendorCostCents;

  int get marginCents => totalMonthlyPriceCents - totalMonthlyVendorCostCents;
}

class TierMarginPerVendor {
  const TierMarginPerVendor({
    required this.vendorId,
    required this.totalMonthlyVendorCostCents,
  });

  final String vendorId;
  final int totalMonthlyVendorCostCents;
}

/// Audit-log diff event captured at every write. The proxy's
/// production audit-log writer accepts the same payload shape; the
/// in-memory gateway buffers them so widget tests + the Tab 1 audit
/// history panel can render the trail without a backend.
///
/// `actorKind` mirrors the Postgres `audit_logs.actor_kind` column -
/// every Lane .C write is by definition a `forge_admin` action because
/// the gateway throws [DataAccuracyAdminForbiddenException] on any
/// other actor; the field is explicit so downstream proxy / log
/// consumers do not have to infer it.
class DataAccuracyAdminAuditEvent {
  const DataAccuracyAdminAuditEvent({
    required this.eventId,
    required this.eventType,
    required this.occurredAt,
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.diff,
    this.reasonNote,
    this.actorKind = 'forge_admin',
    this.actorDisplayName,
    this.actorRole,
    this.actorEmail,
  });

  final String eventId;
  final String eventType;
  final DateTime occurredAt;
  final String actorUserId;
  final String actorKind;
  final String? actorDisplayName;
  final String? actorRole;
  final String? actorEmail;
  final String operatorId;
  final String? locationId;
  final Map<String, Object?> diff;
  final String? reasonNote;
}

/// Tier-assignment row paired with its operator/location ref so the
/// Tab 2 Card 2 table can render across operators in one query.
///
/// `assignment` is nullable: the contract requires the table to list
/// every operator-location, including those that haven't been assigned
/// a tier yet. The "Assign / Update" action button on each row reads
/// "Assign" when `assignment == null` and "Update" otherwise.
class TierAssignmentAdminRow {
  const TierAssignmentAdminRow({
    required this.operatorRef,
    required this.assignment,
    this.adminNotes,
  });

  final OperatorLocationRef operatorRef;
  final ForgeFlowPollingTierAssignment? assignment;
  final String? adminNotes;
}

/// Forbidden / 403 thrown when a non-`forge_admin` actor tries to
/// mutate via this gateway. The screen also hides the affordance via
/// `editingEnabled`; the gateway throw is defence-in-depth.
class DataAccuracyAdminForbiddenException implements Exception {
  const DataAccuracyAdminForbiddenException(this.message);

  final String message;

  @override
  String toString() => 'DataAccuracyAdminForbiddenException: $message';
}

class DataAccuracyAdminGatewayError implements Exception {
  const DataAccuracyAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'DataAccuracyAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class DataAccuracyAdminGateway {
  // ── Tab 1 reads ──────────────────────────────────────────────────────
  Future<List<DataAccuracyAdminRow>> listDataAccuracyRows();
  Future<List<DataAccuracyAdminAuditEvent>> listAuditHistory({
    String? operatorId,
    String? locationId,
  });

  // ── Tab 1 writes ─────────────────────────────────────────────────────
  Future<DataAccuracyAdminRow> overrideDataAccuracy({
    required String operatorId,
    required String locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  Future<DataAccuracyScopeMutationResult> overrideDataAccuracyScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  /// Doc 1 keyed-data-accuracy-write — service-period override.
  ///
  /// Mirrors the operator-web keyed write surface but routes through
  /// the admin proxy with `actor_kind = 'forge_admin'` and a required
  /// reason note. Returns the upserted row so the screen can refresh
  /// its keyed-row table without an additional read.
  ///
  /// Throws [DataAccuracyAdminForbiddenException] when the caller is
  /// not a forge_admin (defence-in-depth alongside the screen-level
  /// `editingEnabled` gate).
  Future<DataAccuracyServicePeriodSetting> overrideDataAccuracyServicePeriod({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String reasonNote,
  });

  /// List the keyed service-period rows F&F support sees alongside the
  /// per-location override table. Mirrors the operator-web read shape
  /// but is admin-scoped (admin proxy gateway handles cross-operator
  /// visibility).
  Future<List<DataAccuracyServicePeriodSetting>>
  listDataAccuracyServicePeriodRows({
    required String operatorId,
    required String locationId,
  });

  // ── Tab 2 reads ──────────────────────────────────────────────────────
  Future<List<TierDefinition>> listTierDefinitions();
  Future<List<TierAssignmentAdminRow>> listTierAssignments();
  Future<TierMarginRollup> summarizeMargin({PollingTierKey? tierFilter});
  Future<List<TierChangeRequest>> listTierChangeRequests();

  // ── Tab 2 writes ─────────────────────────────────────────────────────
  Future<TierDefinition> updateTierDefinition({
    required PollingTierKey tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  Future<TierAssignmentAdminRow> assignTier({
    required String operatorId,
    required String locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  Future<PollingTierScopeMutationResult> assignTierScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  Future<TierChangeRequest> resolveTierChangeRequest({
    required String requestId,
    required TierChangeRequestStatus newStatus,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  /// Tab 2 Card 3 export - CSV of the margin rollup. forge_admin only.
  /// Mirrors the audit-log CSV pattern: every export emits an audit
  /// event of its own.
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required bool actorIsForgeAdmin,
  });
}

class HttpDataAccuracyAdminGateway implements DataAccuracyAdminGateway {
  HttpDataAccuracyAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final DataAccuracyAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String dataRowsPath = '/v1/admin/data-accuracy/rows';
  static const String dataSettingsPrefix = '/v1/admin/data-accuracy/settings/';
  static const String dataScopedSettingsPath =
      '/v1/admin/data-accuracy/scoped-settings';
  static const String dataServicePeriodSettingsPrefix =
      '/v1/admin/data-accuracy/service-period-settings/';
  static const String auditHistoryPath =
      '/v1/admin/data-accuracy/audit-history';
  static const String tierDefinitionsPath =
      '/v1/admin/polling-pricing/tier-definitions';
  static const String tierDefinitionsPrefix =
      '/v1/admin/polling-pricing/tier-definitions/';
  static const String tierAssignmentsPath =
      '/v1/admin/polling-pricing/assignments';
  static const String tierAssignmentsPrefix =
      '/v1/admin/polling-pricing/assignments/';
  static const String tierScopedAssignmentsPath =
      '/v1/admin/polling-pricing/scoped-assignments';
  static const String marginPath = '/v1/admin/polling-pricing/margin';
  static const String marginExportPath =
      '/v1/admin/polling-pricing/margin/export-csv';
  static const String changeRequestsPath =
      '/v1/admin/polling-pricing/change-requests';
  static const String changeRequestsPrefix =
      '/v1/admin/polling-pricing/change-requests/';

  @override
  Future<List<DataAccuracyAdminRow>> listDataAccuracyRows() async {
    final body = await _send(method: 'GET', path: dataRowsPath);
    final rows = (body['rows'] as List?) ?? const [];
    return <DataAccuracyAdminRow>[
      for (final row in rows)
        _dataAccuracyRowFromJson((row as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<DataAccuracyAdminAuditEvent>> listAuditHistory({
    String? operatorId,
    String? locationId,
  }) async {
    final body = await _send(
      method: 'GET',
      path: auditHistoryPath,
      queryParameters: <String, String>{
        if (operatorId != null && operatorId.isNotEmpty)
          'operator_id': operatorId,
        if (locationId != null && locationId.isNotEmpty)
          'location_id': locationId,
      },
    );
    final events = (body['events'] as List?) ?? const [];
    return <DataAccuracyAdminAuditEvent>[
      for (final event in events)
        _auditEventFromJson((event as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<DataAccuracyAdminRow> overrideDataAccuracy({
    required String operatorId,
    required String locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'overrideDataAccuracy');
    final body = await _send(
      method: 'PATCH',
      path:
          '$dataSettingsPrefix${Uri.encodeComponent(operatorId)}/'
          '${Uri.encodeComponent(locationId)}',
      idempotencyKey: _newIdempotencyKey('data-accuracy-override'),
      jsonBody: <String, Object?>{
        if (coversSourceLunch != null)
          'covers_source_lunch': coversSourceLunch.wire,
        if (coversSourceDinner != null)
          'covers_source_dinner': coversSourceDinner.wire,
        if (coversSourceLateNight != null)
          'covers_source_late_night': coversSourceLateNight.wire,
        if (wageSource != null) 'wage_source': wageSource.wire,
        if (walkInHandlingMode != null)
          'walk_in_handling_mode': walkInHandlingMode.wire,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _dataAccuracyRowFromJson(_asMap(body['row']));
  }

  @override
  Future<DataAccuracyScopeMutationResult> overrideDataAccuracyScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'overrideDataAccuracyScope');
    final body = await _send(
      method: 'PUT',
      path: dataScopedSettingsPath,
      idempotencyKey: _newIdempotencyKey('data-accuracy-scope'),
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'scope_type': scopeType.wire,
        if (orgUnitId != null && orgUnitId.isNotEmpty) 'org_unit_id': orgUnitId,
        if (locationId != null && locationId.isNotEmpty)
          'location_id': locationId,
        if (coversSourceLunch != null)
          'covers_source_lunch': coversSourceLunch.wire,
        if (coversSourceDinner != null)
          'covers_source_dinner': coversSourceDinner.wire,
        if (coversSourceLateNight != null)
          'covers_source_late_night': coversSourceLateNight.wire,
        if (wageSource != null) 'wage_source': wageSource.wire,
        if (walkInHandlingMode != null)
          'walk_in_handling_mode': walkInHandlingMode.wire,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _dataAccuracyScopeResultFromJson(body);
  }

  @override
  Future<DataAccuracyServicePeriodSetting> overrideDataAccuracyServicePeriod({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'overrideDataAccuracyServicePeriod');
    if (reasonNote.trim().isEmpty) {
      throw const DataAccuracyAdminGatewayError(
        statusCode: 400,
        errorCode: 'reason_note_required',
        message:
            'overrideDataAccuracyServicePeriod requires a reason note for '
            'the audit log',
      );
    }
    final body = await _send(
      method: 'PATCH',
      path:
          '$dataServicePeriodSettingsPrefix${Uri.encodeComponent(operatorId)}/'
          '${Uri.encodeComponent(locationId)}',
      idempotencyKey: _newIdempotencyKey('data-accuracy-service-period'),
      jsonBody: <String, Object?>{
        'service_period_key': servicePeriodKey,
        'covers_source': coversSource.wire,
        'wage_source': wageSource.wire,
        'effective_at_business_date': effectiveAtBusinessDateIso,
        'reason_note': reasonNote.trim(),
      },
    );
    return _servicePeriodSettingFromJson(_asMap(body['data'] ?? body['row']));
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  listDataAccuracyServicePeriodRows({
    required String operatorId,
    required String locationId,
  }) async {
    final body = await _send(
      method: 'GET',
      path:
          '$dataServicePeriodSettingsPrefix${Uri.encodeComponent(operatorId)}/'
          '${Uri.encodeComponent(locationId)}',
    );
    final rows =
        (body['data_accuracy_service_period_settings'] as List?) ??
        (body['rows'] as List?) ??
        const [];
    return <DataAccuracyServicePeriodSetting>[
      for (final row in rows)
        _servicePeriodSettingFromJson((row as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<TierDefinition>> listTierDefinitions() async {
    final body = await _send(method: 'GET', path: tierDefinitionsPath);
    final definitions = (body['definitions'] as List?) ?? const [];
    return <TierDefinition>[
      for (final definition in definitions)
        _tierDefinitionFromJson((definition as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<List<TierAssignmentAdminRow>> listTierAssignments() async {
    final body = await _send(method: 'GET', path: tierAssignmentsPath);
    final assignments = (body['assignments'] as List?) ?? const [];
    return <TierAssignmentAdminRow>[
      for (final assignment in assignments)
        _tierAssignmentRowFromJson((assignment as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<TierMarginRollup> summarizeMargin({PollingTierKey? tierFilter}) async {
    final body = await _send(
      method: 'GET',
      path: marginPath,
      queryParameters: <String, String>{
        if (tierFilter != null) 'tier_key': tierFilter.wire,
      },
    );
    return _marginRollupFromJson(_asMap(body['rollup']));
  }

  @override
  Future<List<TierChangeRequest>> listTierChangeRequests() async {
    final body = await _send(method: 'GET', path: changeRequestsPath);
    final requests = (body['requests'] as List?) ?? const [];
    return <TierChangeRequest>[
      for (final request in requests)
        _tierChangeRequestFromJson((request as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<TierDefinition> updateTierDefinition({
    required PollingTierKey tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'updateTierDefinition');
    final body = await _send(
      method: 'PATCH',
      path: '$tierDefinitionsPrefix${tierKey.wire}',
      idempotencyKey: _newIdempotencyKey('tier-definition'),
      jsonBody: <String, Object?>{
        if (descriptionMd != null) 'description_md': descriptionMd,
        if (pollingCadencePerVendorSeconds != null)
          'polling_cadence_per_vendor_seconds': pollingCadencePerVendorSeconds,
        if (defaultMonthlyPriceCents != null)
          'default_monthly_price_cents': defaultMonthlyPriceCents,
        if (vendorApiCostEstimateCentsMonthly != null)
          'vendor_api_cost_estimate_cents_monthly':
              vendorApiCostEstimateCentsMonthly,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _tierDefinitionFromJson(_asMap(body['definition']));
  }

  @override
  Future<TierAssignmentAdminRow> assignTier({
    required String operatorId,
    required String locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'assignTier');
    final body = await _send(
      method: 'PUT',
      path:
          '$tierAssignmentsPrefix${Uri.encodeComponent(operatorId)}/'
          '${Uri.encodeComponent(locationId)}',
      idempotencyKey: _newIdempotencyKey('tier-assignment'),
      jsonBody: <String, Object?>{
        'tier_key': tierKey.wire,
        if (customCadencePerVendorSeconds != null)
          'custom_cadence_per_vendor_seconds': customCadencePerVendorSeconds,
        if (monthlyPriceCentsOverride != null)
          'monthly_price_cents_override': monthlyPriceCentsOverride,
        if (vendorApiCostEstimateCentsMonthlyOverride != null)
          'vendor_api_cost_estimate_cents_monthly_override':
              vendorApiCostEstimateCentsMonthlyOverride,
        if (adminNotes != null) 'admin_notes': adminNotes,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _tierAssignmentRowFromJson(_asMap(body['assignment']));
  }

  @override
  Future<PollingTierScopeMutationResult> assignTierScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'assignTierScope');
    final body = await _send(
      method: 'PUT',
      path: tierScopedAssignmentsPath,
      idempotencyKey: _newIdempotencyKey('tier-scope-assignment'),
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'scope_type': scopeType.wire,
        if (orgUnitId != null && orgUnitId.isNotEmpty) 'org_unit_id': orgUnitId,
        if (locationId != null && locationId.isNotEmpty)
          'location_id': locationId,
        'tier_key': tierKey.wire,
        if (customCadencePerVendorSeconds != null)
          'custom_cadence_per_vendor_seconds': customCadencePerVendorSeconds,
        if (monthlyPriceCentsOverride != null)
          'monthly_price_cents_override': monthlyPriceCentsOverride,
        if (vendorApiCostEstimateCentsMonthlyOverride != null)
          'vendor_api_cost_estimate_cents_monthly_override':
              vendorApiCostEstimateCentsMonthlyOverride,
        if (adminNotes != null) 'admin_notes': adminNotes,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _pollingTierScopeResultFromJson(body);
  }

  @override
  Future<TierChangeRequest> resolveTierChangeRequest({
    required String requestId,
    required TierChangeRequestStatus newStatus,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'resolveTierChangeRequest');
    final body = await _send(
      method: 'PATCH',
      path: '$changeRequestsPrefix${Uri.encodeComponent(requestId)}',
      idempotencyKey: _newIdempotencyKey('tier-change-request'),
      jsonBody: <String, Object?>{
        'status': newStatus.wire,
        if (reasonNote != null && reasonNote.trim().isNotEmpty)
          'reason_note': reasonNote.trim(),
      },
    );
    return _tierChangeRequestFromJson(_asMap(body['request']));
  }

  @override
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required bool actorIsForgeAdmin,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'exportMarginRollupCsv');
    final body = await _send(
      method: 'POST',
      path: marginExportPath,
      idempotencyKey: _newIdempotencyKey('margin-rollup-csv'),
    );
    final csv = body['csv'];
    return csv is String ? csv : '';
  }

  void _requireEditable(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw DataAccuracyAdminForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String> queryParameters = const <String, String>{},
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    var uri = baseUri.resolve(path);
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw DataAccuracyAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin data accuracy proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    final message =
        (parsed['message'] as String?) ??
        'admin data accuracy proxy returned an error';
    if (response.statusCode == 403) {
      throw DataAccuracyAdminForbiddenException(message);
    }
    throw DataAccuracyAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
    );
  }

  static String _newIdempotencyKey(String prefix) =>
      '$prefix-${DateTime.now().toUtc().microsecondsSinceEpoch}';
}

DataAccuracyAdminRow _dataAccuracyRowFromJson(Map<String, Object?> json) {
  return DataAccuracyAdminRow(
    operatorRef: _operatorRefFromJson(_asMap(json['operator_ref'])),
    settings: _settingsFromJson(_asMap(json['settings'])),
  );
}

DataAccuracyScopeMutationResult _dataAccuracyScopeResultFromJson(
  Map<String, Object?> json,
) {
  final rows = (json['rows'] as List?) ?? const [];
  return DataAccuracyScopeMutationResult(
    scopeType: AdminDataAccuracyMutationScopeTypeWire.fromWire(
      _stringField(json, 'scope_type'),
    ),
    operatorId: _stringField(json, 'operator_id'),
    orgUnitId: _optionalString(json['org_unit_id']),
    locationId: _optionalString(json['location_id']),
    affectedLocationCount: _intField(json, 'affected_location_count'),
    rows: <DataAccuracyAdminRow>[
      for (final row in rows)
        _dataAccuracyRowFromJson((row as Map).cast<String, Object?>()),
    ],
  );
}

OperatorLocationRef _operatorRefFromJson(Map<String, Object?> json) {
  return OperatorLocationRef(
    operatorId: _stringField(json, 'operator_id'),
    businessName: _stringField(json, 'business_name'),
    locationId: _stringField(json, 'location_id'),
    locationName: _stringField(json, 'location_name'),
  );
}

DataAccuracySettings _settingsFromJson(Map<String, Object?> json) {
  return DataAccuracySettings.fromRow(<String, Object?>{
    ...json,
    'created_at': _dateTimeField(json, 'created_at'),
    'updated_at': _dateTimeField(json, 'updated_at'),
  });
}

DataAccuracyServicePeriodSetting _servicePeriodSettingFromJson(
  Map<String, Object?> json,
) {
  return DataAccuracyServicePeriodSetting.fromRow(<String, Object?>{
    ...json,
    'created_at': _dateTimeField(json, 'created_at'),
    'updated_at': _dateTimeField(json, 'updated_at'),
  });
}

DataAccuracyAdminAuditEvent _auditEventFromJson(Map<String, Object?> json) {
  return DataAccuracyAdminAuditEvent(
    eventId: _stringField(json, 'event_id'),
    eventType: _stringField(json, 'event_type'),
    occurredAt: _dateTimeField(json, 'occurred_at'),
    actorUserId: _optionalString(json['actor_user_id']) ?? '',
    actorKind: _optionalString(json['actor_kind']) ?? 'forge_admin',
    actorDisplayName: _optionalString(json['actor_display_name']),
    actorRole: _optionalString(json['actor_role']),
    actorEmail: _optionalString(json['actor_email']),
    operatorId: _optionalString(json['operator_id']) ?? '',
    locationId: _optionalString(json['location_id']),
    diff: _asMap(json['diff']),
    reasonNote: _optionalString(json['reason_note']),
  );
}

TierDefinition _tierDefinitionFromJson(Map<String, Object?> json) {
  return TierDefinition(
    tierKey: PollingTierKeyWire.fromWire(_stringField(json, 'tier_key')),
    descriptionMd: _stringField(json, 'description_md'),
    pollingCadencePerVendorSeconds: _intMap(
      _asMap(json['polling_cadence_per_vendor_seconds']),
    ),
    defaultMonthlyPriceCents: _intField(json, 'default_monthly_price_cents'),
    vendorApiCostEstimateCentsMonthly: _intField(
      json,
      'vendor_api_cost_estimate_cents_monthly',
    ),
    lastEditedAt: _dateTimeField(json, 'last_edited_at'),
    lastEditedBy: _optionalString(json['last_edited_by']),
  );
}

TierAssignmentAdminRow _tierAssignmentRowFromJson(Map<String, Object?> json) {
  final assignmentRaw = json['assignment'];
  return TierAssignmentAdminRow(
    operatorRef: _operatorRefFromJson(_asMap(json['operator_ref'])),
    assignment: assignmentRaw is Map
        ? _assignmentFromJson(assignmentRaw.cast<String, Object?>())
        : null,
    adminNotes: _optionalString(json['admin_notes']),
  );
}

PollingTierScopeMutationResult _pollingTierScopeResultFromJson(
  Map<String, Object?> json,
) {
  final assignments = (json['assignments'] as List?) ?? const [];
  return PollingTierScopeMutationResult(
    scopeType: AdminDataAccuracyMutationScopeTypeWire.fromWire(
      _stringField(json, 'scope_type'),
    ),
    operatorId: _stringField(json, 'operator_id'),
    orgUnitId: _optionalString(json['org_unit_id']),
    locationId: _optionalString(json['location_id']),
    affectedLocationCount: _intField(json, 'affected_location_count'),
    assignments: <TierAssignmentAdminRow>[
      for (final assignment in assignments)
        _tierAssignmentRowFromJson((assignment as Map).cast<String, Object?>()),
    ],
  );
}

ForgeFlowPollingTierAssignment _assignmentFromJson(Map<String, Object?> json) {
  return ForgeFlowPollingTierAssignment.fromRow(<String, Object?>{
    ...json,
    'effective_at': _dateTimeField(json, 'effective_at'),
    'effective_until': _optionalDateTime(json['effective_until']),
    'created_at': _dateTimeField(json, 'created_at'),
  });
}

TierMarginRollup _marginRollupFromJson(Map<String, Object?> json) {
  final perTier = (json['per_tier'] as List?) ?? const [];
  final perVendor = (json['per_vendor'] as List?) ?? const [];
  return TierMarginRollup(
    totalMonthlyPriceCents: _intField(json, 'total_monthly_price_cents'),
    totalMonthlyVendorCostCents: _intField(
      json,
      'total_monthly_vendor_cost_cents',
    ),
    perTier: <TierMarginPerTier>[
      for (final entry in perTier)
        _marginPerTierFromJson((entry as Map).cast<String, Object?>()),
    ],
    perVendor: <TierMarginPerVendor>[
      for (final entry in perVendor)
        _marginPerVendorFromJson((entry as Map).cast<String, Object?>()),
    ],
  );
}

TierMarginPerTier _marginPerTierFromJson(Map<String, Object?> json) {
  return TierMarginPerTier(
    tierKey: PollingTierKeyWire.fromWire(_stringField(json, 'tier_key')),
    assignmentCount: _intField(json, 'assignment_count'),
    totalMonthlyPriceCents: _intField(json, 'total_monthly_price_cents'),
    totalMonthlyVendorCostCents: _intField(
      json,
      'total_monthly_vendor_cost_cents',
    ),
  );
}

TierMarginPerVendor _marginPerVendorFromJson(Map<String, Object?> json) {
  return TierMarginPerVendor(
    vendorId: _stringField(json, 'vendor_id'),
    totalMonthlyVendorCostCents: _intField(
      json,
      'total_monthly_vendor_cost_cents',
    ),
  );
}

TierChangeRequest _tierChangeRequestFromJson(Map<String, Object?> json) {
  return TierChangeRequest(
    requestId: _stringField(json, 'request_id'),
    operatorRef: _operatorRefFromJson(_asMap(json['operator_ref'])),
    currentTier: PollingTierKeyWire.fromWire(
      _stringField(json, 'current_tier'),
    ),
    requestedTier: PollingTierKeyWire.fromWire(
      _stringField(json, 'requested_tier'),
    ),
    operatorNote: _stringField(json, 'operator_note'),
    submittedAt: _dateTimeField(json, 'submitted_at'),
    status: _tierChangeStatusFromWire(_stringField(json, 'status')),
  );
}

TierChangeRequestStatus _tierChangeStatusFromWire(String value) {
  for (final status in TierChangeRequestStatus.values) {
    if (status.wire == value) return status;
  }
  throw ArgumentError.value(value, 'status', 'unknown tier change status');
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return const <String, Object?>{};
}

Map<String, int> _intMap(Map<String, Object?> json) {
  return <String, int>{
    for (final entry in json.entries) entry.key: _asInt(entry.value),
  };
}

String _stringField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError('missing string field $key');
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _intField(Map<String, Object?> json, String key) => _asInt(json[key]);

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.parse(value);
  throw StateError('missing int field');
}

DateTime _dateTimeField(Map<String, Object?> json, String key) {
  final value = _optionalDateTime(json[key]);
  if (value == null) throw StateError('missing datetime field $key');
  return value;
}

DateTime? _optionalDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return null;
}

/// In-memory gateway powering kDemoMode + widget tests. Mirrors the
/// shape of the production HTTP gateway: every write goes through a
/// single `_record` helper that buffers an audit event and updates
/// internal state in lockstep, so the Tab 1 audit panel and tests
/// always see the same trail.
class InMemoryDataAccuracyAdminGateway implements DataAccuracyAdminGateway {
  InMemoryDataAccuracyAdminGateway({
    required List<OperatorLocationRef> operatorLocations,
    Map<String, DataAccuracySettings>? initialSettings,
    Map<PollingTierKey, TierDefinition>? initialTierDefinitions,
    Map<String, ForgeFlowPollingTierAssignment>? initialAssignments,
    Map<String, String>? initialAdminNotes,
    List<TierChangeRequest>? initialChangeRequests,
    List<DataAccuracyAdminAuditEvent>? initialAuditLog,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _operatorLocations = List<OperatorLocationRef>.unmodifiable(
         operatorLocations,
       ),
       _settings = <String, DataAccuracySettings>{...?initialSettings},
       _tierDefinitions = <PollingTierKey, TierDefinition>{
         ...?initialTierDefinitions,
       },
       _assignments = <String, ForgeFlowPollingTierAssignment>{
         ...?initialAssignments,
       },
       _adminNotes = <String, String>{...?initialAdminNotes},
       _changeRequests = <TierChangeRequest>[...?initialChangeRequests],
       _auditLog = <DataAccuracyAdminAuditEvent>[...?initialAuditLog];

  final DateTime Function() _clock;
  final List<OperatorLocationRef> _operatorLocations;
  final Map<String, DataAccuracySettings> _settings;
  // Keyed (operator/location/service_period_key/effective_at_business_date)
  // service-period rows. Mirrors the operator-web load shape and the
  // schema of `public.data_accuracy_service_period_settings`. Demo +
  // widget tests get the same diff/audit-event mechanics as the legacy
  // override path.
  final Map<String, List<DataAccuracyServicePeriodSetting>>
  _servicePeriodSettings = <String, List<DataAccuracyServicePeriodSetting>>{};
  int _servicePeriodIdCounter = 0;
  final Map<PollingTierKey, TierDefinition> _tierDefinitions;
  final Map<String, ForgeFlowPollingTierAssignment> _assignments;
  final List<ForgeFlowPollingTierAssignment> _assignmentHistory =
      <ForgeFlowPollingTierAssignment>[];
  final Map<String, String> _adminNotes;
  final List<TierChangeRequest> _changeRequests;
  final List<DataAccuracyAdminAuditEvent> _auditLog;

  /// Closed-out assignment history rows (tests + future Tab 2 Card 5
  /// can assert on this to verify the prior row was stamped with
  /// `effectiveUntil`). Mirrors the production Postgres path where
  /// `forge_flow_polling_tier_assignment` rows preserve history with
  /// `effective_until` set to the close timestamp.
  List<ForgeFlowPollingTierAssignment> get assignmentHistoryForTesting =>
      List<ForgeFlowPollingTierAssignment>.unmodifiable(_assignmentHistory);

  /// Public read-only view of audit events. Tests assert against this;
  /// the Tab 1 audit history panel reads it via [listAuditHistory].
  List<DataAccuracyAdminAuditEvent> get capturedAuditEvents =>
      List<DataAccuracyAdminAuditEvent>.unmodifiable(_auditLog);

  static String _key(String operatorId, String locationId) =>
      '$operatorId/$locationId';

  void _ensureForgeAdmin(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw DataAccuracyAdminForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  /// Defensive guard: reject the synthetic `__unallocated__` vendor ID
  /// from any cadence map written through this gateway. The synthetic
  /// key is reserved for the per-vendor cost rollup's "no vendor
  /// cadence" bucket; allowing it as a real cadence-vendor key would
  /// silently merge real vendor cost into that bucket on display.
  void _rejectUnallocatedKey(Map<String, int>? cadence, String operation) {
    if (cadence == null) return;
    if (cadence.containsKey(kUnallocatedVendorId)) {
      throw ArgumentError.value(
        kUnallocatedVendorId,
        'pollingCadencePerVendorSeconds',
        '$operation: "$kUnallocatedVendorId" is reserved as the '
            'rollup bucket for assignments without a vendor cadence; '
            'cannot be used as a real vendor key',
      );
    }
  }

  void _record({
    required String eventType,
    required String actorUserId,
    required String operatorId,
    String? locationId,
    required Map<String, Object?> diff,
    String? reasonNote,
  }) {
    _auditLog.add(
      DataAccuracyAdminAuditEvent(
        eventId: 'audit-${_auditLog.length + 1}',
        eventType: eventType,
        occurredAt: _clock(),
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        diff: Map<String, Object?>.unmodifiable(diff),
        reasonNote: reasonNote,
        actorDisplayName: actorUserId,
        actorRole: 'Forge & Flow admin',
        actorEmail: actorUserId.contains('@')
            ? actorUserId
            : '$actorUserId@forgeflow.internal',
      ),
    );
  }

  DataAccuracySettings _readSettings(String operatorId, String locationId) {
    final key = _key(operatorId, locationId);
    return _settings.putIfAbsent(
      key,
      () => DataAccuracySettings(
        settingId: 'demo-setting-$key',
        operatorId: operatorId,
        locationId: locationId,
        // Per-Daypart V1 Slice R5 (Gap 27/36): covers source is keyed
        // by service period. This admin in-memory double still speaks
        // the legacy 3-daypart vocabulary on its proxy wire (the
        // hierarchy/proxy migration is a scoped follow-up), but the
        // model it builds uses the keyed map. An empty map resolves
        // every period to the vendor default via coversSourceFor.
        coversSourcePerServicePeriod: const <String, CoversSource>{},
        coversManualEntries: const <String, Map<String, int>>{},
        wageSource: WageSource.vendor,
        createdAt: _clock(),
        updatedAt: _clock(),
      ),
    );
  }

  List<OperatorLocationRef> _operatorRefsForScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? locationId,
  }) {
    switch (scopeType) {
      case AdminDataAccuracyMutationScopeType.business:
      case AdminDataAccuracyMutationScopeType.orgUnit:
        return _operatorLocations
            .where((ref) => ref.operatorId == operatorId)
            .toList(growable: false);
      case AdminDataAccuracyMutationScopeType.location:
        final scopedLocationId = locationId;
        if (scopedLocationId == null || scopedLocationId.isEmpty) {
          throw StateError('location scope requires locationId');
        }
        return _operatorLocations
            .where(
              (ref) =>
                  ref.operatorId == operatorId &&
                  ref.locationId == scopedLocationId,
            )
            .toList(growable: false);
    }
  }

  @override
  Future<List<DataAccuracyAdminRow>> listDataAccuracyRows() async {
    return <DataAccuracyAdminRow>[
      for (final ref in _operatorLocations)
        DataAccuracyAdminRow(
          operatorRef: ref,
          settings: _readSettings(ref.operatorId, ref.locationId),
        ),
    ];
  }

  @override
  Future<List<DataAccuracyAdminAuditEvent>> listAuditHistory({
    String? operatorId,
    String? locationId,
  }) async {
    return _auditLog
        .where(
          (event) =>
              (operatorId == null || event.operatorId == operatorId) &&
              (locationId == null || event.locationId == locationId),
        )
        .toList(growable: false);
  }

  @override
  Future<DataAccuracyAdminRow> overrideDataAccuracy({
    required String operatorId,
    required String locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'overrideDataAccuracy');
    final ref = _operatorLocations.firstWhere(
      (r) => r.operatorId == operatorId && r.locationId == locationId,
      orElse: () => throw StateError(
        'overrideDataAccuracy: unknown operator/location $operatorId/$locationId',
      ),
    );
    final prev = _readSettings(operatorId, locationId);
    // Per-Daypart V1 Slice R5 (Gap 27/36): merge the legacy 3-daypart
    // admin override onto the keyed per-period map. The admin wire
    // vocabulary stays 3-daypart (hierarchy/proxy migration deferred);
    // only the in-memory model shape changed.
    final prevLunch = prev.coversSourceFor('lunch');
    final prevDinner = prev.coversSourceFor('dinner');
    final prevLateNight = prev.coversSourceFor('late_night');
    final nextPerPeriod = <String, CoversSource>{
      ...prev.coversSourcePerServicePeriod,
      'lunch': coversSourceLunch ?? prevLunch,
      'dinner': coversSourceDinner ?? prevDinner,
      'late_night': coversSourceLateNight ?? prevLateNight,
    };
    final next = DataAccuracySettings(
      settingId: prev.settingId,
      operatorId: prev.operatorId,
      locationId: prev.locationId,
      coversSourcePerServicePeriod: nextPerPeriod,
      coversManualEntries: prev.coversManualEntries,
      wageSource: wageSource ?? prev.wageSource,
      walkInHandlingMode: walkInHandlingMode ?? prev.walkInHandlingMode,
      walkInManualEntries: prev.walkInManualEntries,
      createdAt: prev.createdAt,
      updatedAt: _clock(),
      updatedBy: actorUserId,
    );
    _settings[_key(operatorId, locationId)] = next;
    final diff = <String, Object?>{};
    if (coversSourceLunch != null && coversSourceLunch != prevLunch) {
      diff['covers_source_lunch'] = <String, String>{
        'from': prevLunch.wire,
        'to': coversSourceLunch.wire,
      };
    }
    if (coversSourceDinner != null && coversSourceDinner != prevDinner) {
      diff['covers_source_dinner'] = <String, String>{
        'from': prevDinner.wire,
        'to': coversSourceDinner.wire,
      };
    }
    if (coversSourceLateNight != null &&
        coversSourceLateNight != prevLateNight) {
      diff['covers_source_late_night'] = <String, String>{
        'from': prevLateNight.wire,
        'to': coversSourceLateNight.wire,
      };
    }
    if (wageSource != null && wageSource != prev.wageSource) {
      diff['wage_source'] = <String, String>{
        'from': prev.wageSource.wire,
        'to': wageSource.wire,
      };
    }
    if (walkInHandlingMode != null &&
        walkInHandlingMode != prev.walkInHandlingMode) {
      diff['walk_in_handling_mode'] = <String, String>{
        'from': prev.walkInHandlingMode.wire,
        'to': walkInHandlingMode.wire,
      };
    }
    // Skip the audit insert when the override was a no-op - every
    // write to `audit_logs` is meant to capture a real diff. A
    // forge_admin opening the dialog and submitting without changes
    // would otherwise produce empty audit rows that dilute the trail.
    if (diff.isNotEmpty) {
      _record(
        eventType: 'admin.data_accuracy.override',
        actorUserId: actorUserId,
        operatorId: operatorId,
        locationId: locationId,
        diff: diff,
        reasonNote: reasonNote,
      );
    }
    return DataAccuracyAdminRow(operatorRef: ref, settings: next);
  }

  @override
  Future<DataAccuracyScopeMutationResult> overrideDataAccuracyScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    CoversSource? coversSourceLunch,
    CoversSource? coversSourceDinner,
    CoversSource? coversSourceLateNight,
    WageSource? wageSource,
    DataAccuracyWalkInHandlingMode? walkInHandlingMode,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'overrideDataAccuracyScope');
    final refs = _operatorRefsForScope(
      operatorId: operatorId,
      scopeType: scopeType,
      locationId: locationId,
    );
    if (refs.isEmpty) {
      throw StateError('overrideDataAccuracyScope: no locations in scope');
    }
    final auditStart = _auditLog.length;
    final rows = <DataAccuracyAdminRow>[];
    for (final ref in refs) {
      rows.add(
        await overrideDataAccuracy(
          operatorId: ref.operatorId,
          locationId: ref.locationId,
          coversSourceLunch: coversSourceLunch,
          coversSourceDinner: coversSourceDinner,
          coversSourceLateNight: coversSourceLateNight,
          wageSource: wageSource,
          walkInHandlingMode: walkInHandlingMode,
          actorUserId: actorUserId,
          actorIsForgeAdmin: actorIsForgeAdmin,
          reasonNote: reasonNote,
        ),
      );
    }
    if (_auditLog.length > auditStart) {
      _auditLog.removeRange(auditStart, _auditLog.length);
    }
    _record(
      eventType: 'admin.data_accuracy.scope_override',
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: scopeType == AdminDataAccuracyMutationScopeType.location
          ? locationId
          : null,
      diff: <String, Object?>{
        'scope_type': scopeType.wire,
        if (orgUnitId != null) 'org_unit_id': orgUnitId,
        if (locationId != null) 'location_id': locationId,
        'affected_location_count': refs.length,
        if (coversSourceLunch != null)
          'covers_source_lunch': coversSourceLunch.wire,
        if (coversSourceDinner != null)
          'covers_source_dinner': coversSourceDinner.wire,
        if (coversSourceLateNight != null)
          'covers_source_late_night': coversSourceLateNight.wire,
        if (wageSource != null) 'wage_source': wageSource.wire,
        if (walkInHandlingMode != null)
          'walk_in_handling_mode': walkInHandlingMode.wire,
      },
      reasonNote: reasonNote,
    );
    return DataAccuracyScopeMutationResult(
      scopeType: scopeType,
      operatorId: operatorId,
      orgUnitId: orgUnitId,
      locationId: locationId,
      affectedLocationCount: refs.length,
      rows: List<DataAccuracyAdminRow>.unmodifiable(rows),
    );
  }

  @override
  Future<DataAccuracyServicePeriodSetting> overrideDataAccuracyServicePeriod({
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required ServicePeriodCoversSource coversSource,
    required ServicePeriodWageSource wageSource,
    required String effectiveAtBusinessDateIso,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'overrideDataAccuracyServicePeriod');
    if (reasonNote.trim().isEmpty) {
      // Defence-in-depth: live HTTP path also requires a reason note.
      // Audit rows without a reason note dilute the trail; reject them
      // here so widget tests + demo walkthroughs match the production
      // shape.
      throw const DataAccuracyAdminGatewayError(
        statusCode: 400,
        errorCode: 'reason_note_required',
        message:
            'overrideDataAccuracyServicePeriod requires a reason note for '
            'the audit log',
      );
    }
    final keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
    if (!keyPattern.hasMatch(servicePeriodKey)) {
      throw const DataAccuracyAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_service_period_key',
        message:
            'service_period_key must start with a lowercase letter and '
            'contain only lowercase letters, numbers, or underscores',
      );
    }
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(effectiveAtBusinessDateIso)) {
      throw const DataAccuracyAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_effective_at_business_date',
        message:
            'effective_at_business_date must be a YYYY-MM-DD business date',
      );
    }
    final key = _key(operatorId, locationId);
    final list = _servicePeriodSettings.putIfAbsent(
      key,
      () => <DataAccuracyServicePeriodSetting>[],
    );
    DataAccuracyServicePeriodSetting? prev;
    final priorIdx = list.indexWhere(
      (r) =>
          r.servicePeriodKey == servicePeriodKey &&
          r.effectiveAtBusinessDate == effectiveAtBusinessDateIso,
    );
    if (priorIdx >= 0) {
      prev = list[priorIdx];
    }
    _servicePeriodIdCounter += 1;
    final next = DataAccuracyServicePeriodSetting(
      id: prev?.id ?? 'period-setting-$_servicePeriodIdCounter',
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      effectiveAtBusinessDate: effectiveAtBusinessDateIso,
      createdAt: prev?.createdAt ?? _clock(),
      updatedAt: _clock(),
      updatedBy: actorUserId,
    );
    if (priorIdx >= 0) {
      list[priorIdx] = next;
    } else {
      list.add(next);
      list.sort((a, b) {
        final byKey = a.servicePeriodKey.compareTo(b.servicePeriodKey);
        if (byKey != 0) return byKey;
        // Effective date desc — most recent first.
        return b.effectiveAtBusinessDate.compareTo(a.effectiveAtBusinessDate);
      });
    }
    final diff = <String, Object?>{
      'service_period_key': servicePeriodKey,
      'effective_at_business_date': effectiveAtBusinessDateIso,
    };
    if (prev == null || prev.coversSource != coversSource) {
      diff['covers_source'] = <String, String>{
        if (prev != null) 'from': prev.coversSource.wire,
        'to': coversSource.wire,
      };
    }
    if (prev == null || prev.wageSource != wageSource) {
      diff['wage_source'] = <String, String>{
        if (prev != null) 'from': prev.wageSource.wire,
        'to': wageSource.wire,
      };
    }
    _record(
      eventType: 'admin.data_accuracy.service_period_override',
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      diff: diff,
      reasonNote: reasonNote.trim(),
    );
    return next;
  }

  @override
  Future<List<DataAccuracyServicePeriodSetting>>
  listDataAccuracyServicePeriodRows({
    required String operatorId,
    required String locationId,
  }) async {
    final list = _servicePeriodSettings[_key(operatorId, locationId)];
    if (list == null) return const <DataAccuracyServicePeriodSetting>[];
    return List<DataAccuracyServicePeriodSetting>.unmodifiable(list);
  }

  @override
  Future<List<TierDefinition>> listTierDefinitions() async {
    return PollingTierKey.values
        .map((tier) => _tierDefinitions[tier])
        .whereType<TierDefinition>()
        .toList(growable: false);
  }

  @override
  Future<TierDefinition> updateTierDefinition({
    required PollingTierKey tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'updateTierDefinition');
    _rejectUnallocatedKey(
      pollingCadencePerVendorSeconds,
      'updateTierDefinition',
    );
    final prev = _tierDefinitions[tierKey];
    if (prev == null) {
      throw StateError('updateTierDefinition: unknown tier ${tierKey.wire}');
    }
    final next = prev.copyWith(
      descriptionMd: descriptionMd,
      pollingCadencePerVendorSeconds: pollingCadencePerVendorSeconds,
      defaultMonthlyPriceCents: defaultMonthlyPriceCents,
      vendorApiCostEstimateCentsMonthly: vendorApiCostEstimateCentsMonthly,
      lastEditedAt: _clock(),
      lastEditedBy: actorUserId,
    );
    _tierDefinitions[tierKey] = next;
    final diff = <String, Object?>{};
    if (descriptionMd != null && descriptionMd != prev.descriptionMd) {
      diff['description_md'] = <String, String>{
        'from': prev.descriptionMd,
        'to': descriptionMd,
      };
    }
    if (pollingCadencePerVendorSeconds != null) {
      diff['polling_cadence_per_vendor_seconds'] = <String, Object?>{
        'from': prev.pollingCadencePerVendorSeconds,
        'to': pollingCadencePerVendorSeconds,
      };
    }
    if (defaultMonthlyPriceCents != null &&
        defaultMonthlyPriceCents != prev.defaultMonthlyPriceCents) {
      diff['default_monthly_price_cents'] = <String, int>{
        'from': prev.defaultMonthlyPriceCents,
        'to': defaultMonthlyPriceCents,
      };
    }
    if (vendorApiCostEstimateCentsMonthly != null &&
        vendorApiCostEstimateCentsMonthly !=
            prev.vendorApiCostEstimateCentsMonthly) {
      diff['vendor_api_cost_estimate_cents_monthly'] = <String, int>{
        'from': prev.vendorApiCostEstimateCentsMonthly,
        'to': vendorApiCostEstimateCentsMonthly,
      };
    }
    // Skip the audit insert when the only change was the tier_key
    // pointer (i.e., admin opened the dialog, typed a reason note,
    // hit save without altering anything). Symmetric with
    // overrideDataAccuracy's empty-diff skip - keeps the audit trail
    // clean of no-op writes.
    if (diff.isNotEmpty) {
      _record(
        eventType: 'admin.polling_tier_definition.update',
        actorUserId: actorUserId,
        operatorId: '*',
        diff: <String, Object?>{'tier_key': tierKey.wire, ...diff},
        reasonNote: reasonNote,
      );
    }
    return next;
  }

  @override
  Future<List<TierAssignmentAdminRow>> listTierAssignments() async {
    // Contract: "Admin browses every operator-location and sees /
    // edits assignments." Return one row per operator-location even
    // when no assignment exists yet - the row's `assignment` field is
    // null and the table renders an "Assign" affordance instead of
    // "Update". Without this, the very first assignment would be
    // un-creatable from the table because the row wouldn't exist.
    return <TierAssignmentAdminRow>[
      for (final ref in _operatorLocations)
        TierAssignmentAdminRow(
          operatorRef: ref,
          assignment: _assignments[_key(ref.operatorId, ref.locationId)],
          adminNotes: _adminNotes[_key(ref.operatorId, ref.locationId)],
        ),
    ];
  }

  @override
  Future<TierAssignmentAdminRow> assignTier({
    required String operatorId,
    required String locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'assignTier');
    _rejectUnallocatedKey(customCadencePerVendorSeconds, 'assignTier');
    final ref = _operatorLocations.firstWhere(
      (r) => r.operatorId == operatorId && r.locationId == locationId,
      orElse: () => throw StateError(
        'assignTier: unknown operator/location $operatorId/$locationId',
      ),
    );
    final tierDefaults = _tierDefinitions[tierKey];
    final cadence =
        customCadencePerVendorSeconds ??
        tierDefaults?.pollingCadencePerVendorSeconds ??
        const <String, int>{};
    final price =
        monthlyPriceCentsOverride ?? tierDefaults?.defaultMonthlyPriceCents;
    final cost =
        vendorApiCostEstimateCentsMonthlyOverride ??
        tierDefaults?.vendorApiCostEstimateCentsMonthly;
    final key = _key(operatorId, locationId);
    final prev = _assignments[key];
    final now = _clock();
    // Mirror production Postgres: close the prior row by stamping
    // `effectiveUntil`, archive it into the history list, then insert
    // the new currently-effective row. Demo gateway preserves history
    // so Tab 2 Card 5 (audit history) and tests asserting on history
    // shape match the production path.
    if (prev != null) {
      _assignmentHistory.add(
        ForgeFlowPollingTierAssignment(
          assignmentId: prev.assignmentId,
          operatorId: prev.operatorId,
          locationId: prev.locationId,
          tierKey: prev.tierKey,
          pollingCadencePerVendorSeconds: prev.pollingCadencePerVendorSeconds,
          monthlyPriceCents: prev.monthlyPriceCents,
          vendorApiCostEstimateCentsMonthly:
              prev.vendorApiCostEstimateCentsMonthly,
          effectiveAt: prev.effectiveAt,
          effectiveUntil: now,
          assignedByAdminUserId: prev.assignedByAdminUserId,
          createdAt: prev.createdAt,
        ),
      );
    }
    final next = ForgeFlowPollingTierAssignment(
      assignmentId:
          'assignment-${_assignments.length + _assignmentHistory.length + 1}',
      operatorId: operatorId,
      locationId: locationId,
      tierKey: tierKey,
      pollingCadencePerVendorSeconds: cadence,
      monthlyPriceCents: price,
      vendorApiCostEstimateCentsMonthly: cost,
      effectiveAt: now,
      effectiveUntil: null,
      assignedByAdminUserId: actorUserId,
      createdAt: now,
    );
    _assignments[key] = next;
    if (adminNotes != null) {
      _adminNotes[key] = adminNotes;
    }
    _record(
      eventType: 'admin.polling_tier_assignment.assign',
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      diff: <String, Object?>{
        'tier_key': <String, String?>{
          'from': prev?.tierKey.wire,
          'to': tierKey.wire,
        },
        'monthly_price_cents': <String, int?>{
          'from': prev?.monthlyPriceCents,
          'to': price,
        },
        'vendor_api_cost_estimate_cents_monthly': <String, int?>{
          'from': prev?.vendorApiCostEstimateCentsMonthly,
          'to': cost,
        },
        'polling_cadence_per_vendor_seconds': <String, Object?>{
          'from': prev?.pollingCadencePerVendorSeconds,
          'to': cadence,
        },
        if (adminNotes != null) 'admin_notes': adminNotes,
      },
      reasonNote: reasonNote,
    );
    return TierAssignmentAdminRow(
      operatorRef: ref,
      assignment: next,
      adminNotes: _adminNotes[key],
    );
  }

  @override
  Future<PollingTierScopeMutationResult> assignTierScope({
    required String operatorId,
    required AdminDataAccuracyMutationScopeType scopeType,
    String? orgUnitId,
    String? locationId,
    required PollingTierKey tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'assignTierScope');
    final refs = _operatorRefsForScope(
      operatorId: operatorId,
      scopeType: scopeType,
      locationId: locationId,
    );
    if (refs.isEmpty) {
      throw StateError('assignTierScope: no locations in scope');
    }
    final auditStart = _auditLog.length;
    final rows = <TierAssignmentAdminRow>[];
    for (final ref in refs) {
      rows.add(
        await assignTier(
          operatorId: ref.operatorId,
          locationId: ref.locationId,
          tierKey: tierKey,
          customCadencePerVendorSeconds: customCadencePerVendorSeconds,
          monthlyPriceCentsOverride: monthlyPriceCentsOverride,
          vendorApiCostEstimateCentsMonthlyOverride:
              vendorApiCostEstimateCentsMonthlyOverride,
          adminNotes: adminNotes,
          actorUserId: actorUserId,
          actorIsForgeAdmin: actorIsForgeAdmin,
          reasonNote: reasonNote,
        ),
      );
    }
    if (_auditLog.length > auditStart) {
      _auditLog.removeRange(auditStart, _auditLog.length);
    }
    _record(
      eventType: 'admin.polling_tier_assignment.scope_assign',
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: scopeType == AdminDataAccuracyMutationScopeType.location
          ? locationId
          : null,
      diff: <String, Object?>{
        'scope_type': scopeType.wire,
        if (orgUnitId != null) 'org_unit_id': orgUnitId,
        if (locationId != null) 'location_id': locationId,
        'affected_location_count': refs.length,
        'tier_key': tierKey.wire,
        if (customCadencePerVendorSeconds != null)
          'polling_cadence_per_vendor_seconds': customCadencePerVendorSeconds,
        if (monthlyPriceCentsOverride != null)
          'monthly_price_cents': monthlyPriceCentsOverride,
        if (vendorApiCostEstimateCentsMonthlyOverride != null)
          'vendor_api_cost_estimate_cents_monthly':
              vendorApiCostEstimateCentsMonthlyOverride,
        if (adminNotes != null) 'admin_notes': adminNotes,
      },
      reasonNote: reasonNote,
    );
    return PollingTierScopeMutationResult(
      scopeType: scopeType,
      operatorId: operatorId,
      orgUnitId: orgUnitId,
      locationId: locationId,
      affectedLocationCount: refs.length,
      assignments: List<TierAssignmentAdminRow>.unmodifiable(rows),
    );
  }

  @override
  Future<TierMarginRollup> summarizeMargin({PollingTierKey? tierFilter}) async {
    var totalPrice = 0;
    var totalCost = 0;
    final perTierAcc = <PollingTierKey, _PerTierAccumulator>{
      for (final tier in PollingTierKey.values) tier: _PerTierAccumulator(tier),
    };
    final perVendorAcc = <String, int>{};
    for (final entry in _assignments.values) {
      if (tierFilter != null && entry.tierKey != tierFilter) continue;
      final price = entry.monthlyPriceCents ?? 0;
      final cost = entry.vendorApiCostEstimateCentsMonthly ?? 0;
      totalPrice += price;
      totalCost += cost;
      final acc = perTierAcc[entry.tierKey]!;
      acc.assignmentCount += 1;
      acc.totalPriceCents += price;
      acc.totalCostCents += cost;
      // Spread vendor cost evenly across the cadence-named vendors.
      // Use floor + carry-the-remainder so the per-vendor sum exactly
      // equals `cost` (no rounding skew between the top-line total and
      // the per-vendor breakdown). Sort vendor IDs so allocation is
      // deterministic across runs. When an assignment has no vendor
      // cadence (custom tier with empty map), the cost is bucketed
      // under the synthetic `__unallocated__` key so the per-vendor
      // sum still equals `totalCost`. The display shows it as
      // "(no vendor cadence set)" - see [kUnallocatedVendorId].
      final vendorIds = entry.pollingCadencePerVendorSeconds.keys.toList()
        ..sort();
      if (vendorIds.isEmpty) {
        if (cost > 0) {
          perVendorAcc[kUnallocatedVendorId] =
              (perVendorAcc[kUnallocatedVendorId] ?? 0) + cost;
        }
        continue;
      }
      final base = cost ~/ vendorIds.length;
      var remainder = cost - base * vendorIds.length;
      for (final v in vendorIds) {
        final share = base + (remainder > 0 ? 1 : 0);
        if (remainder > 0) remainder -= 1;
        perVendorAcc[v] = (perVendorAcc[v] ?? 0) + share;
      }
    }
    return TierMarginRollup(
      totalMonthlyPriceCents: totalPrice,
      totalMonthlyVendorCostCents: totalCost,
      perTier: perTierAcc.values
          .where((a) => a.assignmentCount > 0)
          .map(
            (a) => TierMarginPerTier(
              tierKey: a.tierKey,
              assignmentCount: a.assignmentCount,
              totalMonthlyPriceCents: a.totalPriceCents,
              totalMonthlyVendorCostCents: a.totalCostCents,
            ),
          )
          .toList(growable: false),
      perVendor: perVendorAcc.entries
          .map(
            (e) => TierMarginPerVendor(
              vendorId: e.key,
              totalMonthlyVendorCostCents: e.value,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<List<TierChangeRequest>> listTierChangeRequests() async {
    return List<TierChangeRequest>.unmodifiable(_changeRequests);
  }

  @override
  Future<TierChangeRequest> resolveTierChangeRequest({
    required String requestId,
    required TierChangeRequestStatus newStatus,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'resolveTierChangeRequest');
    final idx = _changeRequests.indexWhere((r) => r.requestId == requestId);
    if (idx < 0) {
      throw StateError('resolveTierChangeRequest: unknown request $requestId');
    }
    final prev = _changeRequests[idx];
    final next = prev.copyWith(status: newStatus);
    _changeRequests[idx] = next;
    _record(
      eventType: 'admin.polling_tier_change_request.resolve',
      actorUserId: actorUserId,
      operatorId: prev.operatorRef.operatorId,
      locationId: prev.operatorRef.locationId,
      diff: <String, Object?>{
        'request_id': requestId,
        'status': <String, String>{
          'from': prev.status.wire,
          'to': newStatus.wire,
        },
      },
      reasonNote: reasonNote,
    );
    return next;
  }

  @override
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required bool actorIsForgeAdmin,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'exportMarginRollupCsv');
    final rollup = await summarizeMargin();
    final buf = StringBuffer();
    buf.writeln('section,key,assignments,price_cents,cost_cents,margin_cents');
    buf.writeln(
      'totals,all,${_assignments.length},'
      '${rollup.totalMonthlyPriceCents},'
      '${rollup.totalMonthlyVendorCostCents},'
      '${rollup.totalMonthlyMarginCents}',
    );
    for (final perTier in rollup.perTier) {
      buf.writeln(
        'per_tier,${perTier.tierKey.wire},'
        '${perTier.assignmentCount},'
        '${perTier.totalMonthlyPriceCents},'
        '${perTier.totalMonthlyVendorCostCents},'
        '${perTier.marginCents}',
      );
    }
    for (final perVendor in rollup.perVendor) {
      buf.writeln(
        'per_vendor,${perVendor.vendorId},,'
        ',${perVendor.totalMonthlyVendorCostCents},',
      );
    }
    _record(
      eventType: 'admin.margin_rollup.export_csv',
      actorUserId: actorUserId,
      operatorId: '*',
      diff: <String, Object?>{
        'rows': _assignments.length,
        'tier_count': rollup.perTier.length,
      },
    );
    return buf.toString();
  }
}

class _PerTierAccumulator {
  _PerTierAccumulator(this.tierKey);

  final PollingTierKey tierKey;
  int assignmentCount = 0;
  int totalPriceCents = 0;
  int totalCostCents = 0;
}

/// Default tier presets used by the `kDemoMode` walkthrough + widget
/// tests. The contract names "Three reference tiers" - `standard`,
/// `premium`, `custom`. The demo numbers are illustrative; F&F billing
/// will lock real numbers separately. Vendor cadences match the
/// "Polling cadence per vendor (poll-only vendors only)" table in
/// the contract: standard = vendor minimum (300s for Oracle; 300s for
/// the four subscription vendors per the contract default), premium
/// = 60s where allowed, custom = empty (admin sets per assignment).
TierDefinition kDemoStandardTierDefinition({DateTime? at}) => TierDefinition(
  tierKey: PollingTierKey.standard,
  descriptionMd:
      'Regular tier - webhook vendors update in real time; '
      'poll-only vendors update at the vendor minimum cadence.',
  pollingCadencePerVendorSeconds: const <String, int>{
    'oracle_micros_simphony': 300,
    'quickbooks_time': 300,
    'humanity': 300,
    'agendrix': 300,
    'push_operations': 300,
  },
  defaultMonthlyPriceCents: 9900,
  vendorApiCostEstimateCentsMonthly: 1200,
  lastEditedAt: at ?? DateTime.utc(2026, 5, 1),
  lastEditedBy: 'demo-super-admin',
);

TierDefinition kDemoPremiumTierDefinition({DateTime? at}) => TierDefinition(
  tierKey: PollingTierKey.premium,
  descriptionMd:
      'Premium tier - webhook vendors update in real time; '
      'poll-only vendors poll every 60 seconds where the vendor '
      'allows it (Oracle MICROS Simphony stays at the 5-minute '
      'vendor minimum).',
  pollingCadencePerVendorSeconds: const <String, int>{
    'oracle_micros_simphony': 300,
    'quickbooks_time': 60,
    'humanity': 60,
    'agendrix': 60,
    'push_operations': 60,
  },
  defaultMonthlyPriceCents: 19900,
  vendorApiCostEstimateCentsMonthly: 4800,
  lastEditedAt: at ?? DateTime.utc(2026, 5, 1),
  lastEditedBy: 'demo-super-admin',
);

TierDefinition kDemoCustomTierDefinition({DateTime? at}) => TierDefinition(
  tierKey: PollingTierKey.custom,
  descriptionMd:
      'Custom tier - F&F admin sets cadence per vendor for this '
      '(operator, location). Negotiated; uncommon.',
  pollingCadencePerVendorSeconds: const <String, int>{},
  defaultMonthlyPriceCents: 0,
  vendorApiCostEstimateCentsMonthly: 0,
  lastEditedAt: at ?? DateTime.utc(2026, 5, 1),
  lastEditedBy: 'demo-super-admin',
);

/// Helper used by the screen + tests to format cents as `$X.XX`.
String formatCents(int cents) {
  final dollars = cents / 100;
  return '\$${dollars.toStringAsFixed(2)}';
}

/// Helper that converts a raw cadence map into a stable JSON encoding
/// (sorted by key) so admin diff output is deterministic regardless of
/// JSONB iteration order.
String stableEncodeCadence(Map<String, int> cadence) {
  final keys = cadence.keys.toList()..sort();
  return jsonEncode(<String, int>{for (final k in keys) k: cadence[k]!});
}

/// Returned by the CSV-export action; widget tests assert on the
/// header line + at least one totals row.
typedef MarginCsvExportResult = String;

/// Internal helper exposed for tests so they can synthesize an
/// assignment-only fixture without going through `assignTier`.
@visibleForTesting
extension InMemoryDataAccuracyAdminGatewayTesting
    on InMemoryDataAccuracyAdminGateway {
  void seedAssignmentForTest({
    required String operatorId,
    required String locationId,
    required ForgeFlowPollingTierAssignment assignment,
    String? adminNotes,
  }) {
    final key = '$operatorId/$locationId';
    _assignments[key] = assignment;
    if (adminNotes != null) {
      _adminNotes[key] = adminNotes;
    }
  }
}
