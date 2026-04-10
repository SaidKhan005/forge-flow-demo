import '../models/reservation_book_snapshot.dart';

abstract class ReservationBookSnapshotRepository {
  Future<ReservationBookSnapshot?> getForShift(
    String restaurantId,
    String businessDate,
    String daypart,
  );

  Future<List<ReservationBookSnapshot>> getForDay(
    String restaurantId,
    String businessDate,
  );

  Future<void> replaceReservationBookSnapshot(
      ReservationBookSnapshot snapshot);
}
