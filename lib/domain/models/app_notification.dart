// Phase 7.55p.4d — Persisted passive in-app notification.
// W2.A — extended with `readAt` to support push-delivered inbox entries
// and unread badge tracking.

class AppNotification {
  final String notificationId;
  final String restaurantId;
  final String type;
  final String eventKey;
  final String title;
  final String body;
  final String businessDate;
  final String createdAt;

  /// ISO UTC timestamp when the operator viewed/dismissed this notification,
  /// or `null` if still unread. Mirrors the `read_at` SQLite column.
  final String? readAt;

  const AppNotification({
    required this.notificationId,
    required this.restaurantId,
    required this.type,
    required this.eventKey,
    required this.title,
    required this.body,
    required this.businessDate,
    required this.createdAt,
    this.readAt,
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
        'read_at': readAt,
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
        readAt: m['read_at'] as String?,
      );
}
