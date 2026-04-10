import '../../models/shift_record.dart';

abstract class ShiftRecordRepository {
  Future<List<ShiftRecord>> getShiftsForWeek(
      String restaurantId, String weekId);
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      String restaurantId, List<String> weekIds);
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
      String restaurantId, String startDate, String endDate);
  Future<String?> getLatestClosedBusinessDate(String restaurantId);
  Future<int> replaceShiftForSlot(ShiftRecord record);
}
