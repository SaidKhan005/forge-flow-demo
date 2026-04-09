/// Tracks the sync cursor position for a restaurant + source type.
library;

class SyncWatermark {
  final String restaurantId;
  final String sourceType;
  final String watermarkType;
  final String watermarkValue;
  final String updatedAt;

  const SyncWatermark({
    required this.restaurantId,
    required this.sourceType,
    required this.watermarkType,
    required this.watermarkValue,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
        'restaurant_id': restaurantId,
        'source_type': sourceType,
        'watermark_type': watermarkType,
        'watermark_value': watermarkValue,
        'updated_at': updatedAt,
      };

  factory SyncWatermark.fromMap(Map<String, dynamic> m) => SyncWatermark(
        restaurantId: m['restaurant_id'] as String,
        sourceType: m['source_type'] as String,
        watermarkType: m['watermark_type'] as String,
        watermarkValue: m['watermark_value'] as String,
        updatedAt: m['updated_at'] as String,
      );
}
