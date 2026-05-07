/// Phase 8 W2.B - per-user notification preference value type.
///
/// Mirrors `public.notification_preferences`. Absence of a row means
/// the catalog default applies; presence with [enabled]=true is an
/// explicit opt-in, [enabled]=false is an explicit opt-out.
///
/// Authority:
///   * `db/migrations/202605070400_phase_8_notification_preferences.sql`
///     (table + UNIQUE NULLS NOT DISTINCT on the 6-tuple).
library;

/// Channel the preference targets. Wire encoding matches the SQL
/// CHECK constraint values verbatim.
enum NotificationChannel { push, email, inbox }

extension NotificationChannelWire on NotificationChannel {
  String get wire {
    switch (this) {
      case NotificationChannel.push:
        return 'push';
      case NotificationChannel.email:
        return 'email';
      case NotificationChannel.inbox:
        return 'inbox';
    }
  }

  static NotificationChannel fromWire(String value) {
    switch (value) {
      case 'push':
        return NotificationChannel.push;
      case 'email':
        return NotificationChannel.email;
      case 'inbox':
        return NotificationChannel.inbox;
      default:
        throw ArgumentError.value(
          value,
          'channel',
          'must be one of push / email / inbox',
        );
    }
  }
}

/// Scope the preference applies to. `operator` rows carry a NULL
/// `scopeId` (UNIQUE NULLS NOT DISTINCT collapses these to one row);
/// `location` rows carry the location UUID.
enum NotificationScopeKind { operator, location }

extension NotificationScopeKindWire on NotificationScopeKind {
  String get wire {
    switch (this) {
      case NotificationScopeKind.operator:
        return 'operator';
      case NotificationScopeKind.location:
        return 'location';
    }
  }

  static NotificationScopeKind fromWire(String value) {
    switch (value) {
      case 'operator':
        return NotificationScopeKind.operator;
      case 'location':
        return NotificationScopeKind.location;
      default:
        throw ArgumentError.value(
          value,
          'scope_kind',
          'must be one of operator / location',
        );
    }
  }
}

class NotificationPreference {
  const NotificationPreference({
    required this.id,
    required this.operatorId,
    required this.userId,
    required this.eventKey,
    required this.channel,
    required this.scopeKind,
    required this.scopeId,
    required this.enabled,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String operatorId;
  final String userId;
  final String eventKey;
  final NotificationChannel channel;
  final NotificationScopeKind scopeKind;

  /// NULL when [scopeKind] is operator-wide. Carries the location
  /// UUID when [scopeKind] is location-scoped.
  final String? scopeId;
  final bool enabled;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Project from a row produced by the PostgresExecutor (UUIDs cast
  /// to text in SELECT).
  factory NotificationPreference.fromRow(Map<String, Object?> row) {
    final id = row['id'];
    final operatorId = row['operator_id'];
    final userId = row['user_id'];
    final eventKey = row['event_key'];
    final channel = row['channel'];
    final scopeKind = row['scope_kind'];
    final scopeId = row['scope_id'];
    final enabled = row['enabled'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];

    if (id is! String ||
        operatorId is! String ||
        userId is! String ||
        eventKey is! String ||
        channel is! String ||
        scopeKind is! String ||
        enabled is! bool ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError(
        'notification_preferences row malformed: missing required fields',
      );
    }

    return NotificationPreference(
      id: id,
      operatorId: operatorId,
      userId: userId,
      eventKey: eventKey,
      channel: NotificationChannelWire.fromWire(channel),
      scopeKind: NotificationScopeKindWire.fromWire(scopeKind),
      scopeId: scopeId is String && scopeId.isNotEmpty ? scopeId : null,
      enabled: enabled,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// JSON shape for proxy responses. Wire keys mirror the table
  /// column names so the gateway round-trip is one-to-one.
  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'operator_id': operatorId,
        'user_id': userId,
        'event_key': eventKey,
        'channel': channel.wire,
        'scope_kind': scopeKind.wire,
        'scope_id': scopeId,
        'enabled': enabled,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}
