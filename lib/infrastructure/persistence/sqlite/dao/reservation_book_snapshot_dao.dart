import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../../../domain/models/reservation_book_snapshot.dart';

class ReservationBookSnapshotDao {
  final Database _db;
  const ReservationBookSnapshotDao(this._db);

  Future<ReservationBookSnapshot?> getForShift(
    String restaurantId,
    String businessDate,
    String daypart,
  ) async {
    final rows = await _db.query(
      'reservation_book_snapshots',
      where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
      whereArgs: [restaurantId, businessDate, daypart],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ReservationBookSnapshot.fromMap(rows.first);
  }

  Future<List<ReservationBookSnapshot>> getForDay(
    String restaurantId,
    String businessDate,
  ) async {
    final rows = await _db.query(
      'reservation_book_snapshots',
      where: 'restaurant_id = ? AND business_date = ?',
      whereArgs: [restaurantId, businessDate],
    );
    return rows.map(ReservationBookSnapshot.fromMap).toList();
  }

  Future<void> replaceReservationBookSnapshot(
      ReservationBookSnapshot snapshot) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'reservation_book_snapshots',
        where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
        whereArgs: [
          snapshot.restaurantId,
          snapshot.businessDate,
          snapshot.daypart,
        ],
      );
      await txn.insert('reservation_book_snapshots', snapshot.toMap());
    });
  }
}
