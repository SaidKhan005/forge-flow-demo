import '../../models/shift_record.dart';

abstract class ShiftRecordRepository {
  Future<List<ShiftRecord>> getShiftsForWeek(
      String restaurantId, String weekId);
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
      String restaurantId, List<String> weekIds);
  Future<int> replaceShiftForSlot(ShiftRecord record);
}
