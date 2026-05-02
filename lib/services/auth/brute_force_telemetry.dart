// Phase 9.5 - Brute-force / risk telemetry.
//
// Records the auth-events the plan calls out for risk review:
//
//   * `auth.login_failed` — every failed credential attempt.
//   * `auth.recaptcha_challenged` — reCAPTCHA v3 fired after the
//     5-failures-in-1-hour threshold.
//   * `auth.suspicious_login` — impossible-travel or suspicious-IP.
//   * `auth.hibp_unavailable` — emitted from the password change
//     service when HIBP fails open.
//   * `auth.brute_force_soft_block` — Cloud Armor / app-side soft
//     block applied for a single account or IP.
//
// Production binds these to `auth_events_audit` (Phase 9.0 schema)
// via the proxy's tenant transaction wrapper. Tests use the
// in-memory recorder for assertions.

class BruteForceTelemetryEvent {
  const BruteForceTelemetryEvent({
    required this.eventType,
    required this.occurredAt,
    this.actorUserId,
    this.targetUserId,
    this.operatorId,
    this.locationId,
    this.ip,
    this.userAgent,
    this.geoCountry,
    this.requestId,
    this.payload = const <String, Object?>{},
  });

  final String eventType;
  final DateTime occurredAt;
  final String? actorUserId;
  final String? targetUserId;
  final String? operatorId;
  final String? locationId;
  final String? ip;
  final String? userAgent;
  final String? geoCountry;

  /// Optional X-Request-Id correlation token. Carried through to
  /// `auth_events_audit.request_id` so a single client request can
  /// be traced across multiple audit rows.
  final String? requestId;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'event_type': eventType,
    'occurred_at': occurredAt.toUtc().toIso8601String(),
    if (actorUserId != null) 'actor_user_id': actorUserId,
    if (targetUserId != null) 'target_user_id': targetUserId,
    if (operatorId != null) 'operator_id': operatorId,
    if (locationId != null) 'location_id': locationId,
    if (ip != null) 'ip': ip,
    if (userAgent != null) 'user_agent': userAgent,
    if (geoCountry != null) 'geo_country': geoCountry,
    if (requestId != null) 'request_id': requestId,
    'payload': payload,
  };
}

abstract class BruteForceTelemetrySink {
  /// Persists [event] to the audit log. Production binding writes
  /// into `auth_events_audit` inside an `OperatorScopedRepository`
  /// or admin BYPASSRLS transaction depending on context.
  Future<void> record(BruteForceTelemetryEvent event);
}

/// In-memory recorder for tests + dev. Holds events in order.
class InMemoryBruteForceTelemetrySink implements BruteForceTelemetrySink {
  final List<BruteForceTelemetryEvent> events = <BruteForceTelemetryEvent>[];

  @override
  Future<void> record(BruteForceTelemetryEvent event) async {
    events.add(event);
  }
}

/// Hard-fail-closed default. The proxy's audit pipeline must be
/// wired before any login traffic is served; failing here surfaces
/// that gap rather than dropping events silently.
class ScaffoldFailingBruteForceTelemetrySink
    implements BruteForceTelemetrySink {
  const ScaffoldFailingBruteForceTelemetrySink();

  @override
  Future<void> record(BruteForceTelemetryEvent event) async {
    throw StateError(
      '9.5 scaffold: real BruteForceTelemetrySink is not wired — bind '
      'the proxy `auth_events_audit` writer before serving login traffic.',
    );
  }
}
