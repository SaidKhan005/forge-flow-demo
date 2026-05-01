// Phase 9.UX.6 — SettingsAuditLogSection widget tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:forge_and_flow/screens/settings/settings_audit_log_section.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  const actor = AuditLogActor(
    actorUserId: 'user-1',
    operatorId: 'op-1',
    locationId: 'loc-1',
  );

  group('SettingsAuditLogSection', () {
    testWidgets('renders friendly labels and relative timestamps', (
      tester,
    ) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now.subtract(const Duration(hours: 3)),
              ip: '203.0.113.10',
            ),
            AuthEventListEntry(
              eventId: 'audit-2',
              eventKind: AuthEventKind.password,
              eventType: 'auth.password_changed',
              friendlyLabel: 'Password changed',
              occurredAt: now.subtract(const Duration(days: 1)),
            ),
          ],
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(gateway.listCalls.single.actorUserId, equals('user-1'));
      expect(gateway.listCalls.single.eventKind, isNull);
      expect(find.byKey(const Key('audit_log_row_audit-1')), findsOneWidget);
      expect(find.byKey(const Key('audit_log_row_audit-2')), findsOneWidget);
      expect(find.text('Sign-in'), findsOneWidget);
      expect(find.text('Password changed'), findsOneWidget);
      expect(find.text('3 hours ago'), findsOneWidget);
    });

    testWidgets('row tap reveals expandable detail with IP / device meta', (
      tester,
    ) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now.subtract(const Duration(minutes: 30)),
              ip: '203.0.113.10',
              userAgent: 'Forge&Flow/1.0',
              geoCountry: 'CA',
            ),
          ],
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('audit_log_row_audit-1_details')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('audit_log_row_audit-1')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('audit_log_row_audit-1_details')),
        findsOneWidget,
      );
      expect(find.text('203.0.113.10'), findsOneWidget);
      expect(find.text('Forge&Flow/1.0'), findsOneWidget);
      expect(find.text('CA'), findsOneWidget);
    });

    testWidgets('Sign-ins filter chip re-fetches with the kind filter', (
      tester,
    ) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now.subtract(const Duration(minutes: 5)),
            ),
            AuthEventListEntry(
              eventId: 'audit-2',
              eventKind: AuthEventKind.password,
              eventType: 'auth.password_changed',
              friendlyLabel: 'Password changed',
              occurredAt: now.subtract(const Duration(hours: 5)),
            ),
          ],
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now.subtract(const Duration(minutes: 5)),
            ),
          ],
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('audit_log_filter_sign_in')));
      await tester.pumpAndSettle();

      expect(gateway.listCalls, hasLength(2));
      expect(gateway.listCalls.last.eventKind, equals(AuthEventKind.signIn));
      expect(find.byKey(const Key('audit_log_row_audit-2')), findsNothing);
      expect(find.byKey(const Key('audit_log_row_audit-1')), findsOneWidget);
    });

    testWidgets('Load more appends the next page without erasing prior rows', (
      tester,
    ) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now.subtract(const Duration(hours: 1)),
            ),
          ],
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-2',
              eventKind: AuthEventKind.session,
              eventType: 'auth.session_revoked',
              friendlyLabel: 'Session revoked',
              occurredAt: now.subtract(const Duration(hours: 2)),
            ),
          ],
        ],
        // The first page reports more rows available; the second page
        // is the last.
        hasMoreSequence: <bool>[true, false],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(
              gateway: gateway,
              actor: actor,
              pageSize: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audit_log_load_more')), findsOneWidget);

      await tester.tap(find.byKey(const Key('audit_log_load_more')));
      await tester.pumpAndSettle();

      expect(gateway.listCalls, hasLength(2));
      expect(gateway.listCalls.last.offset, equals(1));
      // Both rows render — the first page was not erased.
      expect(find.byKey(const Key('audit_log_row_audit-1')), findsOneWidget);
      expect(find.byKey(const Key('audit_log_row_audit-2')), findsOneWidget);
      // hasMore = false on the second page hides the Load more button.
      expect(find.byKey(const Key('audit_log_load_more')), findsNothing);
    });

    testWidgets('empty gateway response renders the no-events copy', (
      tester,
    ) async {
      final gateway = _RecordingAuthOperationsGateway(
        pages: const <List<AuthEventListEntry>>[<AuthEventListEntry>[]],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audit_log_empty')), findsOneWidget);
      expect(find.text('No audit events yet.'), findsOneWidget);
    });

    testWidgets('list error renders retry affordance', (tester) async {
      final gateway = _RecordingAuthOperationsGateway(
        pages: const <List<AuthEventListEntry>>[],
        listError: const ProxyAuthOperationsError(
          code: 'transport_error',
          message: 'proxy auth operation failed before reaching the proxy',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(gateway: gateway, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('audit_log_error')), findsOneWidget);
      expect(find.byKey(const Key('audit_log_retry')), findsOneWidget);
      expect(
        find.text('Could not reach the proxy. Check connection and retry.'),
        findsOneWidget,
      );
    });

    testWidgets('demo fallback gateway renders the seeded ledger', (
      tester,
    ) async {
      const noActorOrGateway = AuditLogActor(
        actorUserId: 'demo-actor',
        operatorId: 'demo-op',
        locationId: 'demo-loc',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(
              actor: noActorOrGateway,
              allowDemoGatewayFallback: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The demo seed has at least 5 rows (per slice acceptance).
      expect(
        find.byKey(const Key('audit_log_row_demo-audit-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('audit_log_row_demo-audit-5')),
        findsOneWidget,
      );
    });

    testWidgets(
      'date range picker pushes from/to into listAuthEventsForActor and '
      'clearing it removes the bounds',
      (tester) async {
        final now = DateTime.now().toUtc();
        final gateway = _RecordingAuthOperationsGateway(
          pages: <List<AuthEventListEntry>>[
            <AuthEventListEntry>[
              AuthEventListEntry(
                eventId: 'audit-1',
                eventKind: AuthEventKind.signIn,
                eventType: 'auth.user.signed_in',
                friendlyLabel: 'Sign-in',
                occurredAt: now.subtract(const Duration(hours: 1)),
              ),
            ],
          ],
          repeatLastPage: true,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SettingsAuditLogSection(gateway: gateway, actor: actor),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // First call: no date range.
        expect(gateway.listCalls, hasLength(1));
        expect(gateway.listCalls.last.from, isNull);
        expect(gateway.listCalls.last.to, isNull);

        // Open the date range picker. Material's picker uses Save /
        // Cancel; tap Save to accept the default (today–today) range.
        await tester.tap(find.byKey(const Key('audit_log_date_range_picker')));
        await tester.pumpAndSettle();
        // showDateRangePicker exposes a Save button on completion.
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // Picker close triggers a re-fetch with from/to set.
        expect(gateway.listCalls.length, greaterThanOrEqualTo(2));
        expect(gateway.listCalls.last.from, isNotNull);
        expect(gateway.listCalls.last.to, isNotNull);

        // Clear control restores the unbounded query.
        await tester.tap(find.byKey(const Key('audit_log_date_range_clear')));
        await tester.pumpAndSettle();
        expect(gateway.listCalls.last.from, isNull);
        expect(gateway.listCalls.last.to, isNull);
      },
    );

    test(
      'DemoAuditLogGateway honors from/to bounds before paginating',
      () async {
        final gateway = DemoAuditLogGateway(
          seed: <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'recent',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: DateTime.utc(2026, 4, 30, 12),
            ),
            AuthEventListEntry(
              eventId: 'middle',
              eventKind: AuthEventKind.password,
              eventType: 'auth.password_changed',
              friendlyLabel: 'Password changed',
              occurredAt: DateTime.utc(2026, 4, 25, 12),
            ),
            AuthEventListEntry(
              eventId: 'old',
              eventKind: AuthEventKind.role,
              eventType: 'auth.role_grant_created',
              friendlyLabel: 'Role grant added',
              occurredAt: DateTime.utc(2026, 4, 1, 12),
            ),
          ],
        );
        // Window covers Apr 20–Apr 30; the "old" Apr 1 row must drop.
        final listed = await gateway.listAuthEventsForActor(
          AuthEventListCommand(
            actorUserId: 'demo-actor',
            operatorId: 'demo-op',
            locationId: 'demo-loc',
            limit: 50,
            offset: 0,
            from: DateTime.utc(2026, 4, 20),
            to: DateTime.utc(2026, 4, 30, 23, 59, 59, 999),
          ),
        );
        final ids = listed.entries.map((e) => e.eventId).toList();
        expect(ids, equals(<String>['recent', 'middle']));
        expect(ids.contains('old'), isFalse);
      },
    );

    test(
      'DemoAuditLogFixtures still surface six rows when no bounds are set',
      () async {
        final gateway = DemoAuditLogGateway();
        final listed = await gateway.listAuthEventsForActor(
          const AuthEventListCommand(
            actorUserId: 'demo',
            operatorId: 'demo-op',
            locationId: 'demo-loc',
            limit: 50,
            offset: 0,
          ),
        );
        expect(listed.entries.length, greaterThanOrEqualTo(6));
      },
    );

    testWidgets('refreshGeneration reloads the audit log list', (tester) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now,
            ),
          ],
        ],
        repeatLastPage: true,
      );

      Widget build(int generation) {
        return MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(
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

    testWidgets('equal actor rebuild does not reload the list', (tester) async {
      final now = DateTime.now().toUtc();
      final gateway = _RecordingAuthOperationsGateway(
        pages: <List<AuthEventListEntry>>[
          <AuthEventListEntry>[
            AuthEventListEntry(
              eventId: 'audit-1',
              eventKind: AuthEventKind.signIn,
              eventType: 'auth.user.signed_in',
              friendlyLabel: 'Sign-in',
              occurredAt: now,
            ),
          ],
        ],
        repeatLastPage: true,
      );

      Widget build() {
        return MaterialApp(
          home: Scaffold(
            body: SettingsAuditLogSection(
              gateway: gateway,
              actor: const AuditLogActor(
                actorUserId: 'user-1',
                operatorId: 'op-1',
                locationId: 'loc-1',
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(gateway.listCalls, hasLength(1));

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(gateway.listCalls, hasLength(1));
    });
  });
}

class _RecordingAuthOperationsGateway
    extends ScaffoldFailingAuthOperationsGateway {
  _RecordingAuthOperationsGateway({
    required List<List<AuthEventListEntry>> pages,
    List<bool>? hasMoreSequence,
    this.listError,
    this.repeatLastPage = false,
  }) : _pages = List<List<AuthEventListEntry>>.of(pages),
       _hasMoreSequence = hasMoreSequence == null
           ? null
           : List<bool>.of(hasMoreSequence);

  final List<List<AuthEventListEntry>> _pages;
  final List<bool>? _hasMoreSequence;
  final Object? listError;
  final bool repeatLastPage;

  final List<AuthEventListCommand> listCalls = <AuthEventListCommand>[];

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    listCalls.add(command);
    final error = listError;
    if (error != null) throw error;
    final List<AuthEventListEntry> entries;
    if (_pages.isEmpty) {
      entries = const <AuthEventListEntry>[];
    } else if (listCalls.length <= _pages.length) {
      entries = _pages[listCalls.length - 1];
    } else if (repeatLastPage) {
      entries = _pages.last;
    } else {
      entries = const <AuthEventListEntry>[];
    }
    final hasSequence = _hasMoreSequence;
    final hasMore = hasSequence == null
        ? false
        : (listCalls.length <= hasSequence.length
              ? hasSequence[listCalls.length - 1]
              : false);
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(entries),
      hasMore: hasMore,
    );
  }
}
