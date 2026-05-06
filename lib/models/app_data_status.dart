/// App data readiness status, evaluated from persisted state.
library;

enum AppDataStatusType {
  noData,
  firstSyncPending,
  backfillPending,
  historicalOnly,
  failedImport,
  stale,
  current,
  demo,
}

class AppDataStatus {
  final AppDataStatusType type;
  final String label;
  final String description;
  final String? latestImportStatus;
  final String? latestImportTimestamp;

  const AppDataStatus({
    required this.type,
    required this.label,
    required this.description,
    this.latestImportStatus,
    this.latestImportTimestamp,
  });

  static const noData = AppDataStatus(
    type: AppDataStatusType.noData,
    label: 'NO DATA',
    description: 'No live or historical data is available for this location.',
  );

  static AppDataStatus firstSyncPending({String? timestamp}) => AppDataStatus(
    type: AppDataStatusType.firstSyncPending,
    label: 'FIRST SYNC PENDING',
    description:
        'Initial sync has started and no live snapshot has landed yet.',
    latestImportTimestamp: timestamp,
  );

  static AppDataStatus backfillPending({String? timestamp}) => AppDataStatus(
    type: AppDataStatusType.backfillPending,
    label: 'BACKFILL PENDING',
    description:
        'First backfill is running; live snapshot truth is not ready yet.',
    latestImportTimestamp: timestamp,
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
  }) => AppDataStatus(
    type: AppDataStatusType.failedImport,
    label: 'IMPORT FAILED',
    description: errorSummary ?? 'Latest import run failed.',
    latestImportStatus: 'failed',
    latestImportTimestamp: timestamp,
  );

  static AppDataStatus stale({String? timestamp}) => AppDataStatus(
    type: AppDataStatusType.stale,
    label: 'STALE',
    description: 'Current-state data is older than the freshness threshold.',
    latestImportTimestamp: timestamp,
  );

  static AppDataStatus current({String? importStatus, String? timestamp}) =>
      AppDataStatus(
        type: AppDataStatusType.current,
        label: 'CURRENT',
        description: 'App data is up to date.',
        latestImportStatus: importStatus,
        latestImportTimestamp: timestamp,
      );

  static AppDataStatus demo({String? timestamp}) => AppDataStatus(
    type: AppDataStatusType.demo,
    label: 'DEMO',
    description: 'Demo data is active for this location.',
    latestImportTimestamp: timestamp,
  );
}
