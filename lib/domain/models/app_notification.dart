// Phase 7.55p.4d — Persisted passive in-app notification.

class AppNotification {
  final String notificationId;
  final String restaurantId;
  final String type;
  final String eventKey;
  final String title;
  final String body;
  final String businessDate;
  final String createdAt;

  const AppNotification({
    required this.notificationId,
    required this.restaurantId,
    required this.type,
    required this.eventKey,
    required this.title,
    required this.body,
    required this.businessDate,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'notification_id': notificationId,
        'restaurant_id': restaurantId,
        'type': type,
        'event_key': eventKey,
        'title': title,
        'body': body,
        'business_date': businessDate,
        'created_at': createdAt,
      };

  factory AppNotification.fromMap(Map<String, dynamic> m) => AppNotification(
        notificationId: m['notification_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        type: m['type'] as String,
        eventKey: m['event_key'] as String,
        title: m['title'] as String,
        body: m['body'] as String,
        businessDate: m['business_date'] as String,
        createdAt: m['created_at'] as String,
      );
}
