/// Aggregate reservation book state for one shift slot.
///
/// Stores the count of unseated reservation covers and parties
/// for a restaurant + business date + daypart combination.
/// Phase 7.56 demo data; Phase 8R will populate from live vendor sync.
library;

class ReservationBookSnapshot {
  final String restaurantId;
  final String businessDate;
  final String daypart;
  final int unseatedCovers;
  final int unseatedPartyCount;
  final String? sourceSystem;
  final String? sourceServiceId;
  final String? lastEventAt;
  final String updatedAt;

  const ReservationBookSnapshot({
    required this.restaurantId,
    required this.businessDate,
    required this.daypart,
    required this.unseatedCovers,
    required this.unseatedPartyCount,
    this.sourceSystem,
    this.sourceServiceId,
    this.lastEventAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'restaurant_id': restaurantId,
        'business_date': businessDate,
        'daypart': daypart,
        'unseated_covers': unseatedCovers,
        'unseated_party_count': unseatedPartyCount,
        'source_system': sourceSystem,
        'source_service_id': sourceServiceId,
        'last_event_at': lastEventAt,
        'updated_at': updatedAt,
      };

  factory ReservationBookSnapshot.fromMap(Map<String, dynamic> m) =>
      ReservationBookSnapshot(
        restaurantId: m['restaurant_id'] as String,
        businessDate: m['business_date'] as String,
        daypart: m['daypart'] as String,
        unseatedCovers: m['unseated_covers'] as int,
        unseatedPartyCount: m['unseated_party_count'] as int,
        sourceSystem: m['source_system'] as String?,
        sourceServiceId: m['source_service_id'] as String?,
        lastEventAt: m['last_event_at'] as String?,
        updatedAt: m['updated_at'] as String,
      );
}
