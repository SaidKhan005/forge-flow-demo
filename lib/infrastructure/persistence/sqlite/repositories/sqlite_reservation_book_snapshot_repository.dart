import '../../../../domain/models/reservation_book_snapshot.dart';
import '../../../../domain/repositories/reservation_book_snapshot_repository.dart';
import '../dao/reservation_book_snapshot_dao.dart';
import '../sqlite_database.dart';

class SqliteReservationBookSnapshotRepository
    implements ReservationBookSnapshotRepository {
  SqliteReservationBookSnapshotRepository._();
  static final SqliteReservationBookSnapshotRepository instance =
      SqliteReservationBookSnapshotRepository._();

  ReservationBookSnapshotDao? _dao;

  Future<ReservationBookSnapshotDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = ReservationBookSnapshotDao(db);
    return _dao!;
  }

  @override
  Future<ReservationBookSnapshot?> getForShift(
    String restaurantId,
    String businessDate,
    String daypart,
  ) async {
    final dao = await _daoReady;
    return dao.getForShift(restaurantId, businessDate, daypart);
  }

  @override
  Future<List<ReservationBookSnapshot>> getForDay(
    String restaurantId,
    String businessDate,
  ) async {
    final dao = await _daoReady;
    return dao.getForDay(restaurantId, businessDate);
  }

  @override
  Future<void> replaceReservationBookSnapshot(
      ReservationBookSnapshot snapshot) async {
    final dao = await _daoReady;
    return dao.replaceReservationBookSnapshot(snapshot);
  }
}
