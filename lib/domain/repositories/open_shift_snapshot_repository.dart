import '../models/open_shift_snapshot.dart';

abstract class OpenShiftSnapshotRepository {
  Future<List<OpenShiftSnapshot>> getOpenShiftsForWeek(
      String restaurantId, String weekId);
  Future<OpenShiftSnapshot?> getCurrentOpenShift(String restaurantId);
  Future<String?> getCurrentBusinessDate(String restaurantId);
  Future<List<OpenShiftSnapshot>> getSnapshotsForDay(
      String restaurantId, String businessDate);
  Future<String?> getMostRecentBusinessDate(String restaurantId);
  Future<String?> getMostRecentClosedBusinessDate(String restaurantId);
  Future<void> replaceOpenShiftSnapshot(OpenShiftSnapshot snapshot);
  Future<void> replaceOpenShiftSnapshotsForWeek(
      String restaurantId, String weekId, List<OpenShiftSnapshot> snapshots);
  Future<String?> getLatestOpenWeekId(String restaurantId);
}
