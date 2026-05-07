// Phase 8 Wave B `8.spine-bridge.3` mobile sync proxy client (interface only).
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) Stage 11 of the canonical chain. Mobile pulls aggregated
// `ShiftRecord` rows from server-side Postgres via the proxy. The proxy
// enforces RLS through `OperatorScopedRepository.withTenant`; mobile
// SQLite never speaks to vendors and never speaks to Postgres directly
// (CLAUDE.md Hard Promise #4).
//
// This file declares the abstract surface only. The production
// implementation backs onto the proxy `/v1/operators/<op>/locations/<loc>`
// endpoints; tests inject a fake. No live HTTP runs in mobile-side
// code, and the raw Postgres driver is not importable here per the
// lean-cut ledger.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//   * HP #1 (pure transport swap): the spine just reads aggregated
//     ShiftRecord rows that the server-side aggregator already produced.
//     No formula change.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)`; the proxy enforces RLS.
//   * HP #2 (demo mode persists post-launch): [fetchDemoModeStates]
//     surfaces the per-(operator, location, category) flag so the mobile
//     banner clears without a redeploy once the first vendor backfill
//     commits server-side.

import '../../domain/models/open_shift_snapshot.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/wage_role_row.dart';
import '../../models/shift_record.dart';
import '../integration/demo_mode_state.dart';

/// One bounded page of `ShiftRecord` rows pulled from the server.
///
/// The cursor is opaque to the client (modeled server-side as a
/// `modified_since` high-water mark per the spine contract). When
/// [nextCursor] is non-null, the orchestrator persists it as the
/// resumable watermark and calls [SyncProxyClient.fetchShiftRecords]
/// again with that cursor. When [nextCursor] is null, the sweep ends
/// and the last-persisted watermark stays as-is.
class ShiftRecordPage {
  const ShiftRecordPage({required this.records, required this.nextCursor});

  /// Rows in this page. May be empty (no new records since the input
  /// cursor); the orchestrator tolerates an empty list and emits no
  /// invalidation signals when so.
  final List<ShiftRecord> records;

  /// Cursor to pass back on the next call to advance the high-water
  /// mark. `null` means "no more pages in this sweep" — the loop
  /// terminates.
  final String? nextCursor;
}

/// One bounded page of server-produced live/open shift snapshots.
///
/// These rows are provisional current-state read models, not closed
/// historical truth. The phone persists them to local SQLite so Shift
/// can render instantly, but the proxy/server remains the source of
/// truth and closed `ShiftRecord` rows keep their existing path.
class OpenShiftSnapshotPage {
  const OpenShiftSnapshotPage({
    required this.snapshots,
    required this.nextCursor,
  });

  final List<OpenShiftSnapshot> snapshots;
  final String? nextCursor;
}

/// In-memory snapshot of one (operator, location)
/// `data_accuracy_settings` row pulled from server-side Postgres.
///
/// SQLite vendor-column parity for accuracy settings is deferred per
/// the spine-bridge.3 prompt; the orchestrator holds the latest
/// snapshot in process so downstream consumers can read it without a
/// schema migration. When Lane `.A` lands the canonical model, the
/// snapshot type can be reshaped or replaced; the wire payload from
/// the proxy stays the same shape.
class DataAccuracySettingsSnapshot {
  const DataAccuracySettingsSnapshot({
    required this.operatorId,
    required this.locationId,
    required this.coversSourceLunch,
    required this.coversSourceDinner,
    required this.coversSourceLateNight,
    required this.coversManualEntries,
    required this.wageSource,
    required this.updatedAt,
    this.walkInHandlingMode = 'reservations_only',
    this.walkInManualEntries = const <String, int>{},
  });

  final String operatorId;
  final String locationId;

  /// One of `'vendor'` (default), `'forecast'`, `'manual'`. Mirrors
  /// the `covers_source_<daypart>` column on
  /// `public.data_accuracy_settings`.
  final String coversSourceLunch;
  final String coversSourceDinner;
  final String coversSourceLateNight;

  /// Sparse map keyed by ISO `business_date`; each value is an
  /// inner map `{ "lunch": int, "dinner": int, "late_night": int }`.
  /// Missing date + manual setting means the aggregator returns null
  /// for that daypart per the spine contract.
  final Map<String, Map<String, int>> coversManualEntries;

  /// `'vendor'` (use labor vendor dollars when exposed) or
  /// `'manual_mix'` (always use wage_role_rows mix).
  final String wageSource;

  /// `'reservations_only'`, `'walk_ins_added_to_reservations'`, or
  /// `'walk_ins_tracked_separately'`.
  final String walkInHandlingMode;

  /// Sparse map keyed by ISO `business_date`; each value is the
  /// operator-entered walk-in count for that day.
  final Map<String, int> walkInManualEntries;

  final DateTime updatedAt;
}

/// In-memory snapshot of one (operator, location)
/// `forge_flow_polling_tier_assignment` row.
///
/// F&F-controlled per the 2026-05-05 reversal: operators see tier
/// names + tier prices; F&F sets per-vendor cadence directly. The
/// mobile app reads this snapshot to render the cost-info chrome on
/// the operator-web data accuracy tab without depending on a SQLite
/// table the spine-bridge.3 lane chose not to add.
class ForgeFlowPollingTierAssignmentSnapshot {
  const ForgeFlowPollingTierAssignmentSnapshot({
    required this.operatorId,
    required this.locationId,
    required this.tierKey,
    required this.pollingCadencePerVendorSeconds,
    required this.monthlyPriceCents,
    required this.effectiveAt,
  });

  final String operatorId;
  final String locationId;

  /// `'standard'` | `'premium'` | `'custom'`.
  final String tierKey;

  /// `{ "<vendor_id>": <seconds> }`. F&F admin sets directly for
  /// `'custom'`; resolver reads from F&F-maintained tier defaults
  /// otherwise.
  final Map<String, int> pollingCadencePerVendorSeconds;

  /// F&F monthly price in cents; null when bundled (grandfathered,
  /// comped, enterprise).
  final int? monthlyPriceCents;

  final DateTime effectiveAt;
}

/// Latest server-side first-connection backfill job status for this
/// operator/location.
///
/// Mobile treats this as status metadata only. It persists the row into
/// the existing `import_runs` cache so app readiness can explain setup
/// state without adding a new mobile table or speaking directly to
/// Postgres/vendors.
class FirstBackfillStatusSnapshot {
  const FirstBackfillStatusSnapshot({
    required this.jobId,
    required this.operatorId,
    required this.locationId,
    required this.status,
    required this.startedAt,
    required this.updatedAt,
    this.connectionId,
    this.vendorId,
    this.category,
    this.windowStart,
    this.windowEnd,
    this.completedAt,
    this.lastError,
  });

  final String jobId;
  final String operatorId;
  final String locationId;
  final String status;
  final DateTime startedAt;
  final DateTime updatedAt;
  final String? connectionId;
  final String? vendorId;
  final String? category;
  final DateTime? windowStart;
  final DateTime? windowEnd;
  final DateTime? completedAt;
  final String? lastError;

  bool get isPending =>
      status == 'queued' || status == 'pending' || status == 'started';
  bool get isRunning => status == 'running' || status == 'in_progress';
  bool get isFailed => status == 'failed';
  bool get isSucceeded => status == 'succeeded' || status == 'completed';
}

/// Vendor-agnostic mobile sync surface.
///
/// The production implementation talks to the proxy
/// `/v1/operators/<op>/locations/<loc>/...` endpoints. Tests inject a
/// fake; no live HTTP runs in tests per the lean-cut ledger.
///
/// All methods are bounded: `fetchShiftRecords` and
/// `fetchOpenShiftSnapshots` take an explicit page size; the aux
/// fetches mirror small server-owned settings sets scoped to one
/// operator/location. Whole-table sweeps are not part of the surface.
abstract class SyncProxyClient {
  /// Pull one bounded page of `ShiftRecord` rows modified since
  /// [cursor]. The proxy enforces operator / location isolation via
  /// `OperatorScopedRepository.withTenant`.
  ///
  /// `cursor == null` means "first sync ever for this (operator,
  /// location)" — server returns rows from the start of retention.
  /// `pageSize` is honored as an upper bound; the server may return
  /// fewer rows on the final page.
  Future<ShiftRecordPage> fetchShiftRecords({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  /// Pull one bounded page of live/open `OpenShiftSnapshot` rows
  /// modified since [cursor]. The proxy enforces operator / location
  /// isolation. Rows are provisional and keyed on the current
  /// business date + service period.
  Future<OpenShiftSnapshotPage> fetchOpenShiftSnapshots({
    required String operatorId,
    required String locationId,
    required String? cursor,
    required int pageSize,
  });

  /// Pull the server-resolved effective timing config for this
  /// location, or null when the operator has not configured timing
  /// yet and mobile should keep its current local/default row.
  ///
  /// This is the resolved shape, not the inheritance graph. Mobile
  /// stores it in `restaurant_timing_configs` for fast rendering.
  Future<RestaurantTimingConfig?> fetchResolvedTimingConfig({
    required String operatorId,
    required String locationId,
    required String restaurantId,
  });

  /// Pull every `demo_mode_state` row for this (operator, location).
  /// Bounded — schema guarantees at most one row per
  /// (operator, location, category), so the full set is small.
  Future<List<DemoModeRecord>> fetchDemoModeStates({
    required String operatorId,
    required String locationId,
  });

  /// Pull the current `data_accuracy_settings` row, or null when the
  /// operator has not yet customized accuracy settings (server-side
  /// defaults apply).
  Future<DataAccuracySettingsSnapshot?> fetchDataAccuracySettings({
    required String operatorId,
    required String locationId,
  });

  /// Pull current keyed service-period data accuracy settings for this
  /// location. These rows are server-owned; mobile mirrors them for
  /// display/explanation only and must not write them.
  Future<List<DataAccuracyServicePeriodSetting>>
  fetchDataAccuracyServicePeriodSettings({
    required String operatorId,
    required String locationId,
  });

  /// Pull the server-owned wage role mix rows for this location. Mobile
  /// persists these as a read-only cache in `wage_role_rows`; the
  /// proxy/server remains the source of truth for role/rate mapping.
  Future<List<WageRoleRow>> fetchWageRoleRows({
    required String operatorId,
    required String locationId,
  });

  /// Pull the currently-effective `forge_flow_polling_tier_assignment`
  /// row, or null when no tier is assigned (admin has not provisioned
  /// the operator yet — operator sees "Standard tier — provisioning"
  /// chrome on the web console).
  Future<ForgeFlowPollingTierAssignmentSnapshot?>
  fetchForgeFlowPollingTierAssignment({
    required String operatorId,
    required String locationId,
  });

  /// Pull the latest first-connection backfill status, or null when
  /// the proxy/server has no status row yet. Legacy/no-status proxy
  /// deployments must remain compatible with the mobile runtime.
  Future<FirstBackfillStatusSnapshot?> fetchFirstBackfillStatus({
    required String operatorId,
    required String locationId,
  });
}
