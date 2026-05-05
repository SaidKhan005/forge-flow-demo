// Phase 8 spine-bridge Lane .C — F&F Ops Console gateway for the
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
// the lane does NOT modify the .A repository — the gateway is the
// only seam this slice introduces alongside the screen + widgets.
//
// Authority: `docs/contracts/data_accuracy_settings_contract.md`
// "Surface scope → F&F Ops Console — per-location admin surface".
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
//     defence-in-depth — calls without `actorIsForgeAdmin: true`
//     throw [DataAccuracyAdminForbiddenException].

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/forge_flow_polling_tier_assignment.dart';

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

/// Tab 1 row — the per-location data accuracy override view. Mirrors
/// the contract's "Tab 1: Data Accuracy" table columns.
class DataAccuracyAdminRow {
  const DataAccuracyAdminRow({
    required this.operatorRef,
    required this.settings,
  });

  final OperatorLocationRef operatorRef;
  final DataAccuracySettings settings;
}

/// Tab 2 → Card 1 — F&F-engineering tier preset.
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
      vendorApiCostEstimateCentsMonthly: vendorApiCostEstimateCentsMonthly ??
          this.vendorApiCostEstimateCentsMonthly,
      lastEditedAt: lastEditedAt ?? this.lastEditedAt,
      lastEditedBy: lastEditedBy ?? this.lastEditedBy,
    );
  }
}

/// Tab 2 → Card 4 — operator-submitted tier change request.
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

/// Margin-rollup payload — Tab 2 Card 3.
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

  int get marginCents =>
      totalMonthlyPriceCents - totalMonthlyVendorCostCents;
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
/// `actorKind` mirrors the Postgres `audit_logs.actor_kind` column —
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
  });

  final String eventId;
  final String eventType;
  final DateTime occurredAt;
  final String actorUserId;
  final String actorKind;
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
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
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

  Future<TierChangeRequest> resolveTierChangeRequest({
    required String requestId,
    required TierChangeRequestStatus newStatus,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reasonNote,
  });

  /// Tab 2 Card 3 export — CSV of the margin rollup. forge_admin only.
  /// Mirrors the audit-log CSV pattern: every export emits an audit
  /// event of its own.
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required bool actorIsForgeAdmin,
  });
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
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _operatorLocations = List<OperatorLocationRef>.unmodifiable(
          operatorLocations,
        ),
        _settings = <String, DataAccuracySettings>{
          ...?initialSettings,
        },
        _tierDefinitions = <PollingTierKey, TierDefinition>{
          ...?initialTierDefinitions,
        },
        _assignments = <String, ForgeFlowPollingTierAssignment>{
          ...?initialAssignments,
        },
        _adminNotes = <String, String>{...?initialAdminNotes},
        _changeRequests = <TierChangeRequest>[
          ...?initialChangeRequests,
        ];

  final DateTime Function() _clock;
  final List<OperatorLocationRef> _operatorLocations;
  final Map<String, DataAccuracySettings> _settings;
  final Map<PollingTierKey, TierDefinition> _tierDefinitions;
  final Map<String, ForgeFlowPollingTierAssignment> _assignments;
  final List<ForgeFlowPollingTierAssignment> _assignmentHistory =
      <ForgeFlowPollingTierAssignment>[];
  final Map<String, String> _adminNotes;
  final List<TierChangeRequest> _changeRequests;
  final List<DataAccuracyAdminAuditEvent> _auditLog =
      <DataAccuracyAdminAuditEvent>[];

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
  void _rejectUnallocatedKey(
    Map<String, int>? cadence,
    String operation,
  ) {
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
        coversSourceLunch: CoversSource.vendor,
        coversSourceDinner: CoversSource.vendor,
        coversSourceLateNight: CoversSource.vendor,
        coversManualEntries: const <String, Map<String, int>>{},
        wageSource: WageSource.vendor,
        createdAt: _clock(),
        updatedAt: _clock(),
      ),
    );
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
    final next = DataAccuracySettings(
      settingId: prev.settingId,
      operatorId: prev.operatorId,
      locationId: prev.locationId,
      coversSourceLunch: coversSourceLunch ?? prev.coversSourceLunch,
      coversSourceDinner: coversSourceDinner ?? prev.coversSourceDinner,
      coversSourceLateNight:
          coversSourceLateNight ?? prev.coversSourceLateNight,
      coversManualEntries: prev.coversManualEntries,
      wageSource: wageSource ?? prev.wageSource,
      createdAt: prev.createdAt,
      updatedAt: _clock(),
      updatedBy: actorUserId,
    );
    _settings[_key(operatorId, locationId)] = next;
    final diff = <String, Object?>{};
    if (coversSourceLunch != null &&
        coversSourceLunch != prev.coversSourceLunch) {
      diff['covers_source_lunch'] = <String, String>{
        'from': prev.coversSourceLunch.wire,
        'to': coversSourceLunch.wire,
      };
    }
    if (coversSourceDinner != null &&
        coversSourceDinner != prev.coversSourceDinner) {
      diff['covers_source_dinner'] = <String, String>{
        'from': prev.coversSourceDinner.wire,
        'to': coversSourceDinner.wire,
      };
    }
    if (coversSourceLateNight != null &&
        coversSourceLateNight != prev.coversSourceLateNight) {
      diff['covers_source_late_night'] = <String, String>{
        'from': prev.coversSourceLateNight.wire,
        'to': coversSourceLateNight.wire,
      };
    }
    if (wageSource != null && wageSource != prev.wageSource) {
      diff['wage_source'] = <String, String>{
        'from': prev.wageSource.wire,
        'to': wageSource.wire,
      };
    }
    // Skip the audit insert when the override was a no-op — every
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
    // overrideDataAccuracy's empty-diff skip — keeps the audit trail
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
    // when no assignment exists yet — the row's `assignment` field is
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
    final price = monthlyPriceCentsOverride ??
        tierDefaults?.defaultMonthlyPriceCents;
    final cost = vendorApiCostEstimateCentsMonthlyOverride ??
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
  Future<TierMarginRollup> summarizeMargin({
    PollingTierKey? tierFilter,
  }) async {
    var totalPrice = 0;
    var totalCost = 0;
    final perTierAcc = <PollingTierKey, _PerTierAccumulator>{
      for (final tier in PollingTierKey.values)
        tier: _PerTierAccumulator(tier),
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
      // "(no vendor cadence set)" — see [kUnallocatedVendorId].
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
      throw StateError(
        'resolveTierChangeRequest: unknown request $requestId',
      );
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
/// tests. The contract names "Three reference tiers" — `standard`,
/// `premium`, `custom`. The demo numbers are illustrative; F&F billing
/// will lock real numbers separately. Vendor cadences match the
/// "Polling cadence per vendor (poll-only vendors only)" table in
/// the contract: standard = vendor minimum (300s for Oracle; 300s for
/// the four subscription vendors per the contract default), premium
/// = 60s where allowed, custom = empty (admin sets per assignment).
TierDefinition kDemoStandardTierDefinition({DateTime? at}) => TierDefinition(
      tierKey: PollingTierKey.standard,
      descriptionMd:
          'Standard tier — webhook vendors update in real time; '
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
          'Premium tier — webhook vendors update in real time; '
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
          'Custom tier — F&F admin sets cadence per vendor for this '
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
  return jsonEncode(<String, int>{
    for (final k in keys) k: cadence[k]!,
  });
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
