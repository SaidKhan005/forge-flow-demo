import '../../../../domain/models/import_run.dart';
import '../../../../domain/models/raw_import_record.dart';
import '../../../../domain/models/sync_watermark.dart';
import '../../../../domain/repositories/import_tracking_repository.dart';
import '../dao/import_tracking_dao.dart';
import '../sqlite_database.dart';

class SqliteImportTrackingRepository implements ImportTrackingRepository {
  SqliteImportTrackingRepository._();
  static final SqliteImportTrackingRepository instance =
      SqliteImportTrackingRepository._();

  ImportTrackingDao? _dao;

  Future<ImportTrackingDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = ImportTrackingDao(db);
    return _dao!;
  }

  @override
  Future<void> createOrReplaceImportRun(ImportRun run) async {
    final dao = await _daoReady;
    return dao.createOrReplaceImportRun(run);
  }

  @override
  Future<void> insertRawImportRecords(List<RawImportRecord> records) async {
    final dao = await _daoReady;
    return dao.insertRawImportRecords(records);
  }

  @override
  Future<SyncWatermark?> getWatermark(
      String restaurantId, String sourceType, String watermarkType) async {
    final dao = await _daoReady;
    return dao.getWatermark(restaurantId, sourceType, watermarkType);
  }

  @override
  Future<void> upsertWatermark(SyncWatermark watermark) async {
    final dao = await _daoReady;
    return dao.upsertWatermark(watermark);
  }

  @override
  Future<ImportRun?> getLatestImportRun(String restaurantId) async {
    final dao = await _daoReady;
    return dao.getLatestImportRun(restaurantId);
  }
}
