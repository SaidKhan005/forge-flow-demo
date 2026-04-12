import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../../domain/models/benchmark_selection_summary.dart';

class BenchmarkSelectionSummaryDao {
  final Database _db;
  const BenchmarkSelectionSummaryDao(this._db);

  Future<BenchmarkSelectionSummary?> getByTargetCycleId(
      String targetCycleId) async {
    final rows = await _db.query(
      'benchmark_selection_summaries',
      where: 'target_cycle_id = ?',
      whereArgs: [targetCycleId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BenchmarkSelectionSummary.fromMap(rows.first);
  }

  Future<void> upsert(BenchmarkSelectionSummary summary) async {
    await _db.insert(
      'benchmark_selection_summaries',
      summary.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}
