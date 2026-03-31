import '../models/import_run.dart';
import '../models/raw_import_record.dart';
import '../models/sync_watermark.dart';

abstract class ImportTrackingRepository {
  Future<void> createOrReplaceImportRun(ImportRun run);
  Future<void> insertRawImportRecords(List<RawImportRecord> records);
  Future<SyncWatermark?> getWatermark(
      String restaurantId, String sourceType, String watermarkType);
  Future<void> upsertWatermark(SyncWatermark watermark);
  Future<ImportRun?> getLatestImportRun(String restaurantId);
}
