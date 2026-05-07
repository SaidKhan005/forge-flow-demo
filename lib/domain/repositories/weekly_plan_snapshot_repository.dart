import '../models/weekly_plan_snapshot.dart';

/// Contract for WeeklyPlanSnapshot persistence.
///
/// Phase 7.55l.6a: contract only — SQLite implementation added in 7.55l.6b+.
abstract class WeeklyPlanSnapshotRepository {
  /// Returns the snapshot in force for [businessDate], or null if none exists.
  Future<WeeklyPlanSnapshot?> getSnapshotForBusinessDate(
    String restaurantId,
    String businessDate,
  );

  /// Returns the snapshot matching [weekKey], or null if none exists.
  Future<WeeklyPlanSnapshot?> getSnapshotForWeekKey(
    String restaurantId,
    String weekKey,
  );

  /// Inserts or replaces a snapshot.
  Future<void> upsertSnapshot(WeeklyPlanSnapshot snapshot);

  /// Removes cached snapshots outside the active restaurant scope.
  ///
  /// Mobile SQLite is only a cache of server-owned weekly plan truth. This
  /// hook supports shared-device scope switches without inventing a second
  /// tenant isolation mechanism for the existing table.
  Future<void> wipeForOtherScopes(String keepRestaurantId);
}
