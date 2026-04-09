/// A restaurant or location scope record.
///
/// Every operational record in the app is scoped to one restaurant.
/// This is the canonical identity for that scope boundary.
library;

class RestaurantLocation {
  final String restaurantId;
  final String displayName;
  final String businessTimezone;
  final String createdAt;
  final String updatedAt;

  const RestaurantLocation({
    required this.restaurantId,
    required this.displayName,
    required this.businessTimezone,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'restaurant_id': restaurantId,
        'display_name': displayName,
        'business_timezone': businessTimezone,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory RestaurantLocation.fromMap(Map<String, dynamic> m) =>
      RestaurantLocation(
        restaurantId: m['restaurant_id'] as String,
        displayName: m['display_name'] as String,
        businessTimezone: m['business_timezone'] as String,
        createdAt: m['created_at'] as String,
        updatedAt: m['updated_at'] as String,
      );
}
