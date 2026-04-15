/// Per-surface current-state freshness truth.
///
/// Represents the freshness of a single current-state surface (e.g. Shift,
/// Variance) relative to its persisted data source timestamp.
///
/// This is NOT the same as [AppDataStatus], which is an app-level readiness
/// check (noData / historicalOnly / failedImport / stale / current). Both
/// can coexist on the same notifier.
///
/// Freshness is nullable on consumers: null means "no current-state data
/// exists" (the surface has no data to evaluate freshness for).
library;

/// The resolved freshness state for a current-state surface.
enum FreshnessState {
  /// Data was refreshed within the accepted live window.
  /// The app can present it as current truth.
  live,

  /// Data is usable but not confirmed live. The UI should show age text
  /// such as "Updated 3 min ago".
  updated,

  /// Data is older than the accepted freshness window or could not be
  /// revalidated. The UI should not present it as current truth.
  stale,

  /// The app is actively revalidating current-state data. May coexist
  /// with showing the last known state.
  refreshing,
}

/// Immutable freshness snapshot for a current-state surface.
///
/// [updatedAt] is the persisted source timestamp (e.g.
/// `OpenShiftSnapshot.updatedAt`). [evaluatedAt] is the wall clock at
/// evaluation time (injectable for deterministic tests).
///
/// [age] is derived: `evaluatedAt - updatedAt`. Null when [updatedAt]
/// is null (refreshing with no prior data, or stale with unknown source).
class CurrentStateFreshness {
  final FreshnessState state;

  /// The persisted data-source timestamp. Null when no source timestamp
  /// is available (e.g. refreshing before first load).
  final DateTime? updatedAt;

  /// The wall clock when freshness was evaluated.
  final DateTime evaluatedAt;

  /// Derived age: how old the source data is relative to evaluation time.
  Duration? get age =>
      updatedAt != null ? evaluatedAt.difference(updatedAt!) : null;

  const CurrentStateFreshness({
    required this.state,
    this.updatedAt,
    required this.evaluatedAt,
  });

  /// Creates a [refreshing] state that preserves the prior source timestamp
  /// so the UI can continue showing "Updated x min ago" during in-flight
  /// revalidation.
  factory CurrentStateFreshness.refreshing({
    DateTime? priorUpdatedAt,
    required DateTime evaluatedAt,
  }) =>
      CurrentStateFreshness(
        state: FreshnessState.refreshing,
        updatedAt: priorUpdatedAt,
        evaluatedAt: evaluatedAt,
      );
}
