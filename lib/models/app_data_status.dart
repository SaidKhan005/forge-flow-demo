/// App data readiness status, evaluated from persisted state.
library;

enum AppDataStatusType {
  noData,
  firstSyncPending,
  backfillPending,
  backfillFailed,
  historicalOnly,
  failedImport,
  stale,
  current,
  demo,
}

/// First-connection backfill lifecycle, surfaced alongside [AppDataStatus]
/// so the mobile UI can distinguish "no connections at all" vs
/// "connections exist but backfill not yet completed" vs "backfill done;
/// data is real" without relying on an exhaustive read of the proxy
/// snapshot.
///
/// Values mirror the proxy's `first_backfill_status.status` lexicon
/// (mapped through `_persistFirstBackfillStatus` on the sync side):
///   * proxy `pending|queued|started`            → [notStarted] when no
///     prior cycle exists; otherwise [inProgress] (we treat any active
///     row as in-progress).
///   * proxy `running|in_progress`               → [inProgress]
///   * proxy `succeeded|completed`               → [completed]
///   * proxy `failed`                            → [failed]
///   * proxy `dead_lettered`                     → [deadLettered]
///
/// `notStarted` covers two cases:
///   1. No first-backfill row exists yet (operator has not connected any
///      vendor — "no connections" path).
///   2. The proxy has not yet acknowledged the connect (transient).
enum FirstBackfillStatus {
  notStarted,
  inProgress,
  completed,
  failed,
  deadLettered,
}

class AppDataStatus {
  final AppDataStatusType type;
  final String label;
  final String description;
  final String? latestImportStatus;
  final String? latestImportTimestamp;

  /// Latest known first-connection backfill lifecycle state for the
  /// active restaurant. Defaults to [FirstBackfillStatus.notStarted]
  /// when no first-backfill row has landed yet (e.g. demo mode, or
  /// operator has not connected any vendor).
  final FirstBackfillStatus firstBackfillStatus;

  const AppDataStatus({
    required this.type,
    required this.label,
    required this.description,
    this.latestImportStatus,
    this.latestImportTimestamp,
    this.firstBackfillStatus = FirstBackfillStatus.notStarted,
  });

  static const noData = AppDataStatus(
    type: AppDataStatusType.noData,
    label: 'NO DATA',
    description: 'No live or historical data is available for this location.',
  );

  static AppDataStatus firstSyncPending({
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.notStarted,
  }) => AppDataStatus(
    type: AppDataStatusType.firstSyncPending,
    label: 'FIRST SYNC PENDING',
    description:
        'Initial sync has started and no live snapshot has landed yet.',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );

  static AppDataStatus backfillPending({
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.inProgress,
  }) => AppDataStatus(
    type: AppDataStatusType.backfillPending,
    label: 'BACKFILL PENDING',
    description:
        'First backfill is running; live snapshot truth is not ready yet.',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );

  static AppDataStatus backfillFailed({
    String? errorSummary,
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.failed,
  }) => AppDataStatus(
    type: AppDataStatusType.backfillFailed,
    label: firstBackfillStatus == FirstBackfillStatus.deadLettered
        ? 'BACKFILL DEAD-LETTERED'
        : 'BACKFILL FAILED',
    description: errorSummary ??
        (firstBackfillStatus == FirstBackfillStatus.deadLettered
            ? 'First backfill exhausted retries and was dead-lettered. '
                'Contact support, or disconnect and reconnect the vendor.'
            : 'First backfill failed.'),
    latestImportStatus: 'failed',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );

  static const historicalOnly = AppDataStatus(
    type: AppDataStatusType.historicalOnly,
    label: 'HISTORICAL ONLY',
    description:
        'Week history exists but no current-week open/projected state.',
  );

  static AppDataStatus failedImport({
    String? errorSummary,
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.notStarted,
  }) => AppDataStatus(
    type: AppDataStatusType.failedImport,
    label: 'IMPORT FAILED',
    description: errorSummary ?? 'Latest import run failed.',
    latestImportStatus: 'failed',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );

  static AppDataStatus stale({
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.notStarted,
  }) => AppDataStatus(
    type: AppDataStatusType.stale,
    label: 'STALE',
    description: 'Current-state data is older than the freshness threshold.',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );

  static AppDataStatus current({
    String? importStatus,
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.notStarted,
  }) =>
      AppDataStatus(
        type: AppDataStatusType.current,
        label: 'CURRENT',
        description: 'App data is up to date.',
        latestImportStatus: importStatus,
        latestImportTimestamp: timestamp,
        firstBackfillStatus: firstBackfillStatus,
      );

  static AppDataStatus demo({
    String? timestamp,
    FirstBackfillStatus firstBackfillStatus = FirstBackfillStatus.notStarted,
  }) => AppDataStatus(
    type: AppDataStatusType.demo,
    label: 'DEMO',
    description: 'Demo data is active for this location.',
    latestImportTimestamp: timestamp,
    firstBackfillStatus: firstBackfillStatus,
  );
}
