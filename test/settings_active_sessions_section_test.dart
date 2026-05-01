// Phase 9.UX.5 — SettingsActiveSessionsSection widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:forge_and_flow/screens/settings/settings_active_sessions_section.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const actor = ActiveSessionsActor(
    actorUserId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
    currentSessionId: _currentSessionId,
  );

  group('SettingsActiveSessionsSection', () {
    testWidgets(
      'renders sessions, tags the current device, hides revoke for it',
      (tester) async {
        final gateway = _RecordingAuthOperationsGateway(
          sessions: <AuthSessionSummary>[
            _summary(
              id: _currentSessionId,
              label: 'Forge & Flow app · iOS',
              lastSeen: DateTime.now().toUtc().subtract(
                const Duration(minutes: 1),
              ),
            ),
            _summary(
              id: 'session-tablet',
              label: 'Safari · iPad',
              lastSeen: DateTime.now().toUtc().subtract(
                const Duration(hours: 5),
              ),
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsActiveSessionsSection(
                gateway: gateway,
                actor: actor,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(gateway.listCalls.single.actorUserId, equals('user-1'));
        expect(
          find.byKey(Key('active_sessions_row_$_currentSessionId')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('active_sessions_row_session-tablet')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('active_sessions_current_badge')),
          findsOneWidget,
        );
        // Current session has no Revoke button — only the tablet does.
        expect(
          find.byKey(Key('active_sessions_revoke_$_currentSessionId')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('active_sessions_revoke_session-tablet')),
          findsOneWidget,
        );
      },
    );

    testWidgets('revoke removes the row and forwards the gateway call', (
      tester,
    ) async {
      final gateway = _RecordingAuthOperationsGateway(
        sessions: <AuthSessionSummary>[
          _summary(
            id: _currentSessionId,
            label: 'Forge & Flow app · iOS',
            lastSeen: DateTime.now().toUtc(),
          ),
          _summary(
            id: 'session-tablet',
            label: 'Safari · iPad',
            lastSeen: DateTime.now().toUtc().subtract(const Duration(hours: 5)),
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsActiveSessionsSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('active_sessions_revoke_session-tablet')),
      );
      await tester.pumpAndSettle();

      expect(gateway.revokeCalls.single.sessionId, equals('session-tablet'));
      expect(gateway.revokeCalls.single.actorUserId, equals('user-1'));
      expect(
        find.byKey(const Key('active_sessions_row_session-tablet')),
        findsNothing,
      );
      expect(
        find.byKey(Key('active_sessions_row_$_currentSessionId')),
        findsOneWidget,
      );
    });

    testWidgets(
      'sign out of all devices confirms then calls signOutAll + the local '
      'sign-out callback',
      (tester) async {
        final gateway = _RecordingAuthOperationsGateway(
          sessions: <AuthSessionSummary>[
            _summary(
              id: _currentSessionId,
              label: 'Forge & Flow app · iOS',
              lastSeen: DateTime.now().toUtc(),
            ),
            _summary(
              id: 'session-tablet',
              label: 'Safari · iPad',
              lastSeen: DateTime.now().toUtc(),
            ),
          ],
        );
        var localSignOutCalls = 0;

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsActiveSessionsSection(
                gateway: gateway,
                actor: actor,
                onSignOutAllDevices: () async {
                  localSignOutCalls += 1;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('active_sessions_sign_out_everywhere')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Sign out everywhere').last);
        await tester.pumpAndSettle();

        expect(gateway.signOutAllCalls.single.actorUserId, equals('user-1'));
        // The local notifier callback runs so the Flutter side
        // transitions out of the signed-in state.
        expect(localSignOutCalls, equals(1));
      },
    );

    testWidgets(
      'demo fallback gateway lets the walkthrough render without a backend',
      (tester) async {
        const noActorOrGateway = ActiveSessionsActor(
          actorUserId: 'demo-actor',
          operatorId: 'demo-op',
          locationId: 'demo-loc',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsActiveSessionsSection(
                actor: noActorOrGateway,
                allowDemoGatewayFallback: true,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            Key(
              'active_sessions_row_'
              '${DemoAuthSessionsFixtures.currentSessionId}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            Key(
              'active_sessions_row_'
              '${DemoAuthSessionsFixtures.tabletSessionId}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            Key(
              'active_sessions_row_'
              '${DemoAuthSessionsFixtures.backOfHouseSessionId}',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('list error renders retry affordance', (tester) async {
      final gateway = _RecordingAuthOperationsGateway(
        sessions: const <AuthSessionSummary>[],
        listError: StateError('boom'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsActiveSessionsSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('active_sessions_error')), findsOneWidget);
      expect(find.byKey(const Key('active_sessions_retry')), findsOneWidget);
    });

    testWidgets('transport errors show proxy reachability copy', (
      tester,
    ) async {
      final gateway = _RecordingAuthOperationsGateway(
        sessions: const <AuthSessionSummary>[],
        listError: const ProxyAuthOperationsError(
          code: 'transport_error',
          message: 'proxy auth operation failed before reaching the proxy',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsActiveSessionsSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Could not reach the proxy. Check connection and retry.'),
        findsOneWidget,
      );
    });

    testWidgets('refreshGeneration reloads the active sessions list', (
      tester,
    ) async {
      final gateway = _RecordingAuthOperationsGateway(
        sessions: <AuthSessionSummary>[
          _summary(
            id: _currentSessionId,
            label: 'Forge & Flow app',
            lastSeen: DateTime.now().toUtc(),
          ),
        ],
      );

      Widget build(int generation) {
        return MaterialApp(
          home: Scaffold(
            body: SettingsActiveSessionsSection(
              gateway: gateway,
              actor: actor,
              refreshGeneration: generation,
            ),
          ),
        );
      }

      await tester.pumpWidget(build(0));
      await tester.pumpAndSettle();
      expect(gateway.listCalls, hasLength(1));

      await tester.pumpWidget(build(1));
      await tester.pumpAndSettle();
      expect(gateway.listCalls, hasLength(2));
    });
  });
}

const String _currentSessionId = 'session-current';

AuthSessionSummary _summary({
  required String id,
  required String label,
  required DateTime lastSeen,
}) {
  return AuthSessionSummary(
    sessionId: id,
    deviceLabel: label,
    userAgent: label,
    ip: '203.0.113.10',
    geoCountry: 'CA',
    createdAt: lastSeen.subtract(const Duration(hours: 6)),
    lastSeenAt: lastSeen,
  );
}

class _RecordingAuthOperationsGateway
    extends ScaffoldFailingAuthOperationsGateway {
  _RecordingAuthOperationsGateway({
    required List<AuthSessionSummary> sessions,
    this.listError,
  }) : _sessions = List<AuthSessionSummary>.of(sessions);

  final List<AuthSessionSummary> _sessions;
  final Object? listError;

  final List<AuthActiveSessionsListCommand> listCalls =
      <AuthActiveSessionsListCommand>[];
  final List<AuthSessionRevokeCommand> revokeCalls =
      <AuthSessionRevokeCommand>[];
  final List<AuthAllSessionsRevokeCommand> signOutAllCalls =
      <AuthAllSessionsRevokeCommand>[];

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    listCalls.add(command);
    final error = listError;
    if (error != null) throw error;
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(_sessions),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    revokeCalls.add(command);
    final before = _sessions.length;
    _sessions.removeWhere((s) => s.sessionId == command.sessionId);
    return AuthSessionRevoked(revoked: _sessions.length < before);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    signOutAllCalls.add(command);
    final count = _sessions.length;
    _sessions.clear();
    return AuthAllSessionsRevoked(revokedCount: count);
  }
}
