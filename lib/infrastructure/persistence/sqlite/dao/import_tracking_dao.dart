import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/import_run.dart';
import '../../../../domain/models/raw_import_record.dart';
import '../../../../domain/models/sync_watermark.dart';

class ImportTrackingDao {
  final Database _db;
  const ImportTrackingDao(this._db);

  Future<void> createOrReplaceImportRun(ImportRun run) async {
    await _db.insert(
      'import_runs',
      run.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertRawImportRecords(List<RawImportRecord> records) async {
    final batch = _db.batch();
    for (final r in records) {
      batch.insert('raw_import_records', r.toMap());
    }
    await batch.commit(noResult: true);
  }

  Future<SyncWatermark?> getWatermark(
      String restaurantId, String sourceType, String watermarkType) async {
    final rows = await _db.query(
      'sync_watermarks',
      where:
          'restaurant_id = ? AND source_type = ? AND watermark_type = ?',
      whereArgs: [restaurantId, sourceType, watermarkType],
    );
    if (rows.isEmpty) return null;
    return SyncWatermark.fromMap(rows.first);
  }

  Future<void> upsertWatermark(SyncWatermark watermark) async {
    await _db.insert(
      'sync_watermarks',
      watermark.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<ImportRun?> getLatestImportRun(String restaurantId) async {
    final rows = await _db.query(
      'import_runs',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'started_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ImportRun.fromMap(rows.first);
  }

  Future<List<ImportRun>> getImportRunsForRestaurant(
      String restaurantId) async {
    final rows = await _db.query(
      'import_runs',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
    );
    return rows.map(ImportRun.fromMap).toList();
  }

  Future<List<RawImportRecord>> getRawImportRecordsForRun(
      String importRunId) async {
    final rows = await _db.query(
      'raw_import_records',
      where: 'import_run_id = ?',
      whereArgs: [importRunId],
    );
    return rows.map(RawImportRecord.fromMap).toList();
  }
}
