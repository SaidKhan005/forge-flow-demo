/// Configuration for a vendor connector mapped to a restaurant.

class ConnectorConfig {
  final String connectorId;
  final String restaurantId;
  final String sourceType;
  final String externalLocationId;
  final String status;
  final String createdAt;
  final String updatedAt;

  const ConnectorConfig({
    required this.connectorId,
    required this.restaurantId,
    required this.sourceType,
    required this.externalLocationId,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'connector_id': connectorId,
        'restaurant_id': restaurantId,
        'source_type': sourceType,
        'external_location_id': externalLocationId,
        'status': status,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory ConnectorConfig.fromMap(Map<String, dynamic> m) => ConnectorConfig(
        connectorId: m['connector_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        sourceType: m['source_type'] as String,
        externalLocationId: m['external_location_id'] as String,
        status: m['status'] as String,
        createdAt: m['created_at'] as String,
        updatedAt: m['updated_at'] as String,
      );
}
