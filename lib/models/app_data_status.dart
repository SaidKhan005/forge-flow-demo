/// App data readiness status, evaluated from persisted state.
library;

enum AppDataStatusType {
  noData,
  historicalOnly,
  failedImport,
  stale,
  current,
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
    description: 'No shifts or history found. Load demo data or connect a source.',
  );

  static const historicalOnly = AppDataStatus(
    type: AppDataStatusType.historicalOnly,
    label: 'HISTORICAL ONLY',
    description: 'Week history exists but no current-week open/projected state.',
  );

  static AppDataStatus failedImport({
    String? errorSummary,
    String? timestamp,
  }) =>
      AppDataStatus(
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

  static AppDataStatus current({
    String? importStatus,
    String? timestamp,
  }) =>
      AppDataStatus(
        type: AppDataStatusType.current,
        label: 'CURRENT',
        description: 'App data is up to date.',
        latestImportStatus: importStatus,
        latestImportTimestamp: timestamp,
      );
}
