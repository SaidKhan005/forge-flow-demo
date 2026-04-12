import '../../../../domain/models/benchmark_selection_summary.dart';
import '../../../../domain/repositories/benchmark_selection_summary_repository.dart';
import '../dao/benchmark_selection_summary_dao.dart';
import '../sqlite_database.dart';

class SqliteBenchmarkSelectionSummaryRepository
    implements BenchmarkSelectionSummaryRepository {
  SqliteBenchmarkSelectionSummaryRepository._();
  static final SqliteBenchmarkSelectionSummaryRepository instance =
      SqliteBenchmarkSelectionSummaryRepository._();

  BenchmarkSelectionSummaryDao? _dao;

  Future<BenchmarkSelectionSummaryDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = BenchmarkSelectionSummaryDao(db);
    return _dao!;
  }

  @override
  Future<BenchmarkSelectionSummary?> getByTargetCycleId(
      String targetCycleId) async {
    final dao = await _daoReady;
    return dao.getByTargetCycleId(targetCycleId);
  }

  @override
  Future<void> upsert(BenchmarkSelectionSummary summary) async {
    final dao = await _daoReady;
    return dao.upsert(summary);
  }
}
