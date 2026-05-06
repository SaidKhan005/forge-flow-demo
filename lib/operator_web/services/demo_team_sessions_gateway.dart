// Phase 11W.4 - Operator Web sessions demo gateway.
//
// In-memory implementation of [WebTeamSessionsGateway] that the
// operator-web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads
// the shared fixture set at [demo_team_fixtures.dart] so the
// `/sessions` walkthrough sees the same operator + members set the
// `/members` walkthrough does.
//
// Mutations made during a walkthrough (revoke a session) are stored
// on this instance only - page reload resets to the fixture defaults.
// Idempotency replays of the same key surface the original response,
// mirroring the proxy `proxy_requests` UNIQUE-key replay semantics.

import 'dart:async';

import 'demo_team_fixtures.dart';
import 'web_team_sessions_gateway.dart';

/// In-memory demo gateway. Constructs from the shared fixture set
/// declared in [demo_team_fixtures.dart].
class DemoWebTeamSessionsGateway implements WebTeamSessionsGateway {
  /// Defaults [actorUserId] to [kDemoTeamSessionOwnerActorUserId] so
  /// the demo flavor walkthrough surfaces the owner's two session
  /// rows in `Your sessions` without callers having to thread the
  /// fixture id through. Tests pass an explicit id so the assertion
  /// pins which fixture rows surface as the actor's own.
  DemoWebTeamSessionsGateway({String? actorUserId})
      : _actorUserId = actorUserId ?? kDemoTeamSessionOwnerActorUserId {
    for (final fixture in kDemoTeamSessionsFixture) {
      _sessions[fixture.sessionId] = _entryFromFixture(fixture);
    }
  }

  final String _actorUserId;

  final Map<String, WebTeamSessionEntry> _sessions =
      <String, WebTeamSessionEntry>{};

  /// Cached responses keyed by the screen-minted idempotency key, so
  /// a re-submission of the same revoke returns the original outcome
  /// rather than mutating again.
  final Map<String, WebTeamSessionRevoked> _idempotency =
      <String, WebTeamSessionRevoked>{};

  @override
  Future<WebTeamSessionsListed> listOwnSessions() async {
    final entries = _sessions.values
        .where((row) => row.targetUserId == _actorUserId)
        .map(_strippedTargetUser)
        .toList(growable: false);
    entries.sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
    return WebTeamSessionsListed(
      sessions: List<WebTeamSessionEntry>.unmodifiable(entries),
    );
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() async {
    final entries = _sessions.values.toList(growable: false);
    entries.sort((a, b) {
      final byUser = (a.targetUserDisplayName ?? '')
          .toLowerCase()
          .compareTo((b.targetUserDisplayName ?? '').toLowerCase());
      if (byUser != 0) return byUser;
      return b.lastActiveAt.compareTo(a.lastActiveAt);
    });
    return WebTeamSessionsListed(
      sessions: List<WebTeamSessionEntry>.unmodifiable(entries),
    );
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached != null) return cached;
    final removed = _sessions.remove(command.sessionId) != null;
    final result = WebTeamSessionRevoked(revoked: removed);
    _idempotency[idempotencyKey] = result;
    return result;
  }

  WebTeamSessionEntry _strippedTargetUser(WebTeamSessionEntry row) {
    return WebTeamSessionEntry(
      sessionId: row.sessionId,
      lastActiveAt: row.lastActiveAt,
      createdAt: row.createdAt,
      deviceLabel: row.deviceLabel,
      userAgent: row.userAgent,
      deviceFingerprint: row.deviceFingerprint,
      geoCity: row.geoCity,
      geoCountry: row.geoCountry,
    );
  }

  WebTeamSessionEntry _entryFromFixture(DemoTeamSessionFixture fixture) {
    return WebTeamSessionEntry(
      sessionId: fixture.sessionId,
      lastActiveAt: DateTime.parse(fixture.lastActiveAtIso).toUtc(),
      createdAt: DateTime.parse(fixture.createdAtIso).toUtc(),
      deviceLabel: fixture.deviceLabel,
      userAgent: fixture.userAgent,
      deviceFingerprint: fixture.deviceFingerprint,
      geoCity: fixture.geoCity,
      geoCountry: fixture.geoCountry,
      targetUserId: fixture.userId,
      targetUserDisplayName: fixture.userDisplayName,
      targetUserEmail: fixture.userEmail,
    );
  }
}
