import '../../models/week_record.dart';

abstract class WeekRecordRepository {
  Future<List<WeekRecord>> getWeekHistory(String restaurantId);
  Future<int> upsertWeekRecord(WeekRecord record);
}
