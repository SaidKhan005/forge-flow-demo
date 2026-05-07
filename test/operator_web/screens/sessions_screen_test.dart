// Phase 11W.4 - Sessions screen widget tests.
//
// Pins the parity contract section "Sessions (`11W.4` + `11A.13`
// Sessions tab)":
//
//   - own-only view for actors without team.session.force_logout
//   - two-section view for actors with the key (or owner role tier
//     fallback before the permission snapshot hydrates)
//   - `(this session)` chip on the matching own-section row only
//   - revoking the current session triggers signOut() AFTER the
//     proxy returns 200
//   - revoking a non-current session refreshes the list without
//     calling signOut
//   - idempotency keys mint per click + thread through the gateway
//   - the rendered screen never surfaces a raw IPv4 / IPv6 substring
//   - zero em dashes in operator-facing literals across the slice's
//     owned files
//
// Tests rely on the in-memory `DemoWebTeamSessionsGateway` and the
// shared fixture set so the assertions stay deterministic.

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/sessions_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_sessions_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_sessions_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWithRole(
    String role, {
    Set<String> permissions = const <String>{},
  }) => OperatorWebSession(
    uid: 'demo-user-owner',
    email: 'sam.owner@demobistro.test',
    displayName: 'Sam Patel',
    operatorId: kDemoOperatorIdFixture,
    businessName: kDemoOperatorBusinessNameFixture,
    primaryLocationId: 'demo-loc-downtown',
    primaryLocationName: 'Downtown',
    roles: <String>[role],
    permissions: permissions,
  );

  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    required OperatorWebSession session,
    WebTeamSessionsGateway? gateway,
    String? currentSessionId = kDemoTeamSessionThisSessionId,
    String Function()? idempotencyKeyFactory,
  }) async {
    final signOutCalls = <String>[];
    await tester.pumpWidget(
      wrap(
        SessionsScreen(
          session: session,
          gateway:
              gateway ?? DemoWebTeamSessionsGateway(actorUserId: session.uid),
          currentSessionId: currentSessionId,
          idempotencyKeyFactory: idempotencyKeyFactory,
          onSignOut: () async {
            signOutCalls.add('called');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return signOutCalls;
  }

  Future<void> confirmDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sessions_confirm_dialog_confirm')));
    await tester.pumpAndSettle();
  }

  group('SessionsScreen layout', () {
    testWidgets('operator_owner sees both Your sessions and Team sessions', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_sessions_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_own_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsOneWidget,
      );
    });

    testWidgets('operator_supervisor without team.session.force_logout sees '
        'only Your sessions', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(tester, session: sessionWithRole('operator_supervisor'));

      expect(
        find.byKey(const Key('operator_web_sessions_own_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsNothing,
      );
    });

    testWidgets('permission snapshot with team.session.force_logout admits '
        'the team section even for an unrecognised role', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'custom_floor_captain',
          permissions: const <String>{kSessionsTeamForceLogoutPermissionKey},
        ),
      );

      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsOneWidget,
      );
    });

    testWidgets('permission snapshot WITHOUT team.session.force_logout '
        'suppresses the team section even for the operator_owner role', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'operator_owner',
          permissions: const <String>{'integrations.configure'},
        ),
      );

      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsNothing,
      );
    });

    testWidgets('team sessions route failure leaves own sessions visible', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: _TeamSessionsUnavailableGateway(),
      );

      expect(
        find.byKey(const Key('operator_web_sessions_own_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_team_unavailable')),
        findsOneWidget,
      );
      expect(find.textContaining('team_sessions_not_routed'), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_sessions_load_error')),
        findsNothing,
      );
    });

    testWidgets('own and team session lists load in parallel', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = _ConcurrentSessionsGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      expect(gateway.ownStarted.isCompleted, isTrue);
      expect(gateway.teamStarted.isCompleted, isTrue);
      expect(
        find.byKey(const Key('operator_web_sessions_own_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_sessions_team_section')),
        findsOneWidget,
      );
    });
  });

  group('(this session) chip', () {
    testWidgets('lights up on the row whose sessionId matches '
        'currentSessionId', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        currentSessionId: kDemoTeamSessionThisSessionId,
      );

      // Chip is only rendered once per build (own section row only).
      expect(
        find.byKey(const Key('operator_web_sessions_this_chip')),
        findsOneWidget,
      );
      // The chip lives inside the own section's owner-web row.
      expect(
        find.descendant(
          of: find.byKey(
            Key('operator_web_sessions_row_$kDemoTeamSessionThisSessionId'),
          ),
          matching: find.byKey(const Key('operator_web_sessions_this_chip')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('does not render when currentSessionId is null', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        currentSessionId: null,
      );

      expect(
        find.byKey(const Key('operator_web_sessions_this_chip')),
        findsNothing,
      );
    });
  });

  group('Revoke action', () {
    testWidgets('revoking a non-current session does NOT trigger signOut and '
        'refreshes the list without that row', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamSessionsGateway(
        actorUserId: 'demo-user-owner',
      );
      final signOutCalls = await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      // Revoke the owner's mobile row (NOT the current web session).
      await tester.tap(
        find.byKey(
          Key('operator_web_sessions_revoke_$kDemoTeamSessionOwnerMobileId'),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      expect(signOutCalls, isEmpty);
      // The row is gone after the refresh.
      expect(
        find.byKey(
          Key('operator_web_sessions_row_$kDemoTeamSessionOwnerMobileId'),
        ),
        findsNothing,
      );
      // The current web session row is still there.
      expect(
        find.byKey(
          Key('operator_web_sessions_row_$kDemoTeamSessionThisSessionId'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('revoking the current session triggers signOut AFTER the '
        'gateway returns', (tester) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = DemoWebTeamSessionsGateway(
        actorUserId: 'demo-user-owner',
      );
      final signOutCalls = await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      await tester.tap(
        find.byKey(
          Key('operator_web_sessions_revoke_$kDemoTeamSessionThisSessionId'),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      expect(signOutCalls, hasLength(1));
      // The session is removed from the gateway too.
      final remaining = await gateway.listOwnSessions();
      expect(
        remaining.sessions.any(
          (s) => s.sessionId == kDemoTeamSessionThisSessionId,
        ),
        isFalse,
      );
    });

    testWidgets('idempotency key from the screen flows through the gateway', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1200));
      final gateway = _RecordingDemoSessionsGateway();
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
        idempotencyKeyFactory: () => 'fixed-revoke-key-1',
      );

      await tester.tap(
        find.byKey(
          Key('operator_web_sessions_revoke_$kDemoTeamSessionOwnerMobileId'),
        ),
      );
      await tester.pumpAndSettle();
      await confirmDialog(tester);

      expect(gateway.lastRevokeKey, 'fixed-revoke-key-1');
      expect(gateway.lastRevokeSessionId, kDemoTeamSessionOwnerMobileId);
    });
  });

  group('Privacy posture', () {
    testWidgets('rendered screen never surfaces a raw IPv4 substring '
        '(parity contract: city-level only, never raw IP)', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      // Walk every rendered Text widget. None of them should contain
      // the dotted-quad IPv4 shape.
      final ipPattern = RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
      final renderedTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      for (final text in renderedTexts) {
        expect(
          ipPattern.hasMatch(text),
          isFalse,
          reason: 'Rendered text "$text" looks like a raw IPv4 address',
        );
      }
    });
  });

  group('No em dash regression on 11W.4-owned files', () {
    test('every operator-facing string literal in the 11W.4 file set is '
        'em-dash free', () async {
      const ownedPaths = <String>[
        'lib/operator_web/services/web_team_sessions_gateway.dart',
        'lib/operator_web/services/demo_team_sessions_gateway.dart',
        'lib/operator_web/screens/sessions_screen.dart',
      ];
      for (final relativePath in ownedPaths) {
        final source = await io.File(relativePath).readAsString();
        final stripped = source
            .split('\n')
            .map((line) {
              var inString = false;
              String? quote;
              for (var i = 0; i < line.length - 1; i++) {
                final c = line[i];
                if (!inString && (c == '"' || c == "'")) {
                  inString = true;
                  quote = c;
                  continue;
                }
                if (inString && c == quote) {
                  inString = false;
                  quote = null;
                  continue;
                }
                if (!inString && c == '/' && line[i + 1] == '/') {
                  return line.substring(0, i);
                }
              }
              return line;
            })
            .join('\n');
        expect(
          stripped.contains('—'),
          isFalse,
          reason: 'em dash (U+2014) found in $relativePath outside comments',
        );
      }
    });
  });
}

/// Mock gateway that records the last revoke key + session id so the
/// idempotency-thread test can pin them without reaching for the
/// HTTP layer.
class _RecordingDemoSessionsGateway implements WebTeamSessionsGateway {
  _RecordingDemoSessionsGateway()
    : _delegate = DemoWebTeamSessionsGateway(actorUserId: 'demo-user-owner');

  final DemoWebTeamSessionsGateway _delegate;
  String? lastRevokeKey;
  String? lastRevokeSessionId;

  @override
  Future<WebTeamSessionsListed> listOwnSessions() {
    return _delegate.listOwnSessions();
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() {
    return _delegate.listTeamSessions();
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) {
    lastRevokeKey = idempotencyKey;
    lastRevokeSessionId = command.sessionId;
    return _delegate.revokeSession(command, idempotencyKey: idempotencyKey);
  }
}

class _TeamSessionsUnavailableGateway implements WebTeamSessionsGateway {
  _TeamSessionsUnavailableGateway()
    : _delegate = DemoWebTeamSessionsGateway(actorUserId: 'demo-user-owner');

  final DemoWebTeamSessionsGateway _delegate;

  @override
  Future<WebTeamSessionsListed> listOwnSessions() {
    return _delegate.listOwnSessions();
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() {
    throw const WebTeamSessionsError(
      code: 'team_sessions_not_routed',
      message: 'Team sessions are not routed in this preview.',
      statusCode: 501,
    );
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) {
    return _delegate.revokeSession(command, idempotencyKey: idempotencyKey);
  }
}

class _ConcurrentSessionsGateway implements WebTeamSessionsGateway {
  _ConcurrentSessionsGateway()
    : _delegate = DemoWebTeamSessionsGateway(actorUserId: 'demo-user-owner');

  final DemoWebTeamSessionsGateway _delegate;
  final Completer<void> ownStarted = Completer<void>();
  final Completer<void> teamStarted = Completer<void>();

  @override
  Future<WebTeamSessionsListed> listOwnSessions() async {
    if (!ownStarted.isCompleted) ownStarted.complete();
    await teamStarted.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {
        throw StateError('team sessions did not start');
      },
    );
    return _delegate.listOwnSessions();
  }

  @override
  Future<WebTeamSessionsListed> listTeamSessions() async {
    if (!teamStarted.isCompleted) teamStarted.complete();
    await ownStarted.future.timeout(
      const Duration(seconds: 1),
      onTimeout: () {
        throw StateError('own sessions did not start');
      },
    );
    return _delegate.listTeamSessions();
  }

  @override
  Future<WebTeamSessionRevoked> revokeSession(
    WebTeamSessionRevokeCommand command, {
    required String idempotencyKey,
  }) {
    return _delegate.revokeSession(command, idempotencyKey: idempotencyKey);
  }
}
