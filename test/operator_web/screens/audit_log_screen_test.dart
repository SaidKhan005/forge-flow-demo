// Phase 11W.5 - Audit Log screen widget tests.
//
// Pins the parity contract section "Audit Log (11W.5 + 11A.14 Audit
// log tab)":
//
//   - locked filter set wired (time window + action multi-select +
//     target_kind + target_id + actor)
//   - cursor pagination 200/page sorted by created_at DESC
//   - row renders humanized action, copyable target id, payload
//     toggle
//   - CSV export writes its own audit row (idempotency-keyed in the
//     gateway)
//   - permission gating: forbidden surface for actors without
//     team.audit_log.view; export button hidden for actors without
//     team.audit_log.export
//   - zero em dashes in operator-facing literals across the slice's
//     owned files
//
// Tests rely on the in-memory `DemoWebTeamAuditLogGateway` so the
// assertions stay deterministic. The fixture clock is pinned so the
// time-window filters always have a stable reference frame.

import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/audit_log_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/web_team_audit_log_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/operator_web_surface.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // Pin the clock to a moment where the latest fixture (2026-05-05
  // 14:00 UTC) is well within the last-7-days window so every test
  // sees a populated screen by default.
  final pinnedClock = DateTime.utc(2026, 5, 5, 18);

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  test('demo audit payloads use current v2 role ids', () {
    const retiredRoleFragments = <String>{
      'operator_admin',
      'operator_manager',
      'operator_supervisor',
      'operator_staff',
      'role-operator-manager',
      'role-operator-supervisor',
      'role-operator-staff',
    };

    for (final entry in kDemoAuditLogEntriesFixture) {
      final payloadText = entry.payload.toString();
      for (final retired in retiredRoleFragments) {
        expect(
          payloadText,
          isNot(contains(retired)),
          reason: '${entry.entryId} should not expose retired role $retired',
        );
      }
    }
  });

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

  Future<WebTeamAuditLogGateway> pumpScreen(
    WidgetTester tester, {
    required OperatorWebSession session,
    WebTeamAuditLogGateway? gateway,
    String Function()? idempotencyKeyFactory,
    Future<void> Function(String value)? copyToClipboard,
    Future<void> Function(WebAuditLogCsvExport export)? onCsvReady,
  }) async {
    final resolved = gateway ?? DemoWebTeamAuditLogGateway(clock: pinnedClock);
    await tester.pumpWidget(
      wrap(
        AuditLogScreen(
          session: session,
          gateway: resolved,
          idempotencyKeyFactory: idempotencyKeyFactory,
          copyToClipboard: copyToClipboard,
          onCsvReady: onCsvReady,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return resolved;
  }

  group('AuditLogScreen layout', () {
    testWidgets('operator_owner sees the screen with filters and rows', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_audit_log_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_filters')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_list')),
        findsOneWidget,
      );
      // Latest fixture row renders.
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-001')),
        findsOneWidget,
      );
    });

    testWidgets('operator_staff hits the forbidden surface', (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      await pumpScreen(tester, session: sessionWithRole('operator_staff'));

      expect(
        find.byKey(const Key('operator_web_audit_log_forbidden')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_screen')),
        findsNothing,
      );
    });

    testWidgets('export button is hidden for actors without '
        'team.audit_log.export (e.g. location_manager)', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('location_manager'));

      expect(
        find.byKey(const Key('operator_web_audit_log_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_export_button')),
        findsNothing,
      );
    });

    testWidgets('explicit team.audit_log.export permission lights up the '
        'export button even for an unrecognised role', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(
        tester,
        session: sessionWithRole(
          'custom_compliance_lead',
          permissions: const <String>{
            kAuditLogViewPermissionKey,
            kAuditLogExportPermissionKey,
          },
        ),
      );

      expect(
        find.byKey(const Key('operator_web_audit_log_export_button')),
        findsOneWidget,
      );
    });
  });

  group('Action filter', () {
    testWidgets('selecting team.users.invite narrows the list to invite rows', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(
          const Key('operator_web_audit_log_action_team_users_invite'),
        ),
      );
      await tester.pumpAndSettle();

      // demo-audit-002 is the most recent team.users.invite row in
      // the fixture set; demo-audit-001 (auth.user.signed_in) must
      // drop out.
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-002')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-001')),
        findsNothing,
      );
    });
  });

  group('Pagination', () {
    testWidgets('cursor pagination 200/page sorted by created_at DESC', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      // Tiny page size so the test exercises load-more without
      // scaling the fixture set.
      final gateway = _SmallPageGateway(pinnedClock: pinnedClock, pageSize: 5);
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
      );

      // First load returned the freshest 5 fixture rows; older rows
      // should not have rendered yet.
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-001')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-006')),
        findsNothing,
      );
      // Load next page; older rows surface.
      await tester.ensureVisible(
        find.byKey(const Key('operator_web_audit_log_load_more')),
      );
      await tester.tap(
        find.byKey(const Key('operator_web_audit_log_load_more')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('operator_web_audit_log_row_demo-audit-006')),
        findsOneWidget,
      );
    });
  });

  group('Row rendering', () {
    testWidgets('action label is humanized via WebAuditLogActionLabels', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      // demo-audit-002 is `team.users.invite`. It must render as the
      // verb-object form documented in the parity contract example.
      expect(find.text('Invited team member'), findsWidgets);
      // The raw event_type string must NOT appear as the row label.
      expect(find.text('team.users.invite'), findsNothing);
    });

    test('auth.* action labels match the operator-web canonical mapping '
        '(parity contract: rendered consistently across web surfaces)', () {
      // Snapshot of the operator-web canonical labels for auth.* audit
      // log actions. MO-5b normalized the two-factor surface to the V1
      // canonical phrase "Two-factor sign-in"; the operator-web mapping
      // is the V1 source of truth for these strings.
      const canonicalMappings = <String, String>{
        'auth.user.signed_in': 'Sign-in',
        'auth.signed_in': 'Sign-in',
        'auth.user.password_changed': 'Password changed',
        'auth.password_changed': 'Password changed',
        'auth.password_reset_requested': 'Password reset requested',
        'auth.password_reset_confirmed': 'Password reset completed',
        'auth.mfa_totp_enrolled': 'Two-factor sign-in enabled',
        'auth.mfa_totp_enroll_failed': 'Two-factor sign-in setup failed',
        'auth.user.mfa_factor_removed': 'Two-factor sign-in disabled',
        'auth.mfa_factor_removed': 'Two-factor sign-in disabled',
        'auth.role_grant_created': 'Role grant added',
        'auth.role_grant_revoked': 'Role grant revoked',
        'auth.session_revoked': 'Session revoked',
        'auth.all_sessions_revoked': 'Signed out of all devices',
        'auth.invite_created': 'Invite created',
        'auth.invite_revoked': 'Invite cancelled',
        'invite.cancel': 'Invite cancelled',
        'auth.invite_accepted': 'Invite accepted',
        'auth.user_suspended': 'User suspended',
        'auth.user_reactivated': 'User reactivated',
        'auth.user_soft_deleted': 'User soft-deleted',
      };
      for (final entry in canonicalMappings.entries) {
        expect(
          WebAuditLogActionLabels.labelFor(entry.key),
          entry.value,
          reason:
              'auth.* canonical label drift for ${entry.key}: web returned '
              '"${WebAuditLogActionLabels.labelFor(entry.key)}", canonical '
              'expects "${entry.value}".',
        );
      }
    });

    testWidgets('payload toggle expands and shows the JSON body', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      // Payload starts collapsed.
      expect(
        find.byKey(
          const Key('operator_web_audit_log_row_demo-audit-002_payload'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_audit_log_row_demo-audit-002_payload_toggle'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('operator_web_audit_log_row_demo-audit-002_payload'),
        ),
        findsOneWidget,
      );
    });
  });

  group('Time window filter', () {
    testWidgets('Custom range chip renders so the locked filter set is '
        'complete (parity contract: time_window includes custom range)', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(
        find.byKey(const Key('operator_web_audit_log_time_window_24h')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_time_window_7d')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_time_window_30d')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_time_window_90d')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_audit_log_time_window_custom')),
        findsOneWidget,
      );
    });

    testWidgets('custom range opens the compact Operator Web date popup', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      await tester.tap(
        find.byKey(const Key('operator_web_audit_log_time_window_custom')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OperatorWebDateRangeDialog), findsOneWidget);
      expect(find.text('Choose audit log dates'), findsOneWidget);
    });
  });

  group('Team member wording', () {
    testWidgets('uses Team member instead of Actor in visible filters', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 1600));
      await pumpScreen(tester, session: sessionWithRole('operator_owner'));

      expect(find.text('Team member'), findsOneWidget);
      expect(find.text('Actor'), findsNothing);
      expect(
        find.textContaining('specific action or team member'),
        findsOneWidget,
      );
    });
  });

  group('CSV export', () {
    testWidgets('export writes its own audit.export.requested row and threads '
        'the screen-supplied idempotency key into the gateway', (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final gateway = DemoWebTeamAuditLogGateway(clock: pinnedClock);
      final clipboardWrites = <String>[];
      final downloads = <WebAuditLogCsvExport>[];
      await pumpScreen(
        tester,
        session: sessionWithRole('operator_owner'),
        gateway: gateway,
        idempotencyKeyFactory: () => 'fixed-export-key-1',
        copyToClipboard: (value) async => clipboardWrites.add(value),
        onCsvReady: (export) async => downloads.add(export),
      );

      await tester.ensureVisible(
        find.byKey(const Key('operator_web_audit_log_export_button')),
      );
      await tester.tap(
        find.byKey(const Key('operator_web_audit_log_export_button')),
      );
      await tester.pumpAndSettle();

      // CSV body landed in the clipboard.
      expect(clipboardWrites, hasLength(1));
      expect(clipboardWrites.single, contains('action,actor_user_id'));
      expect(downloads, hasLength(1));
      expect(downloads.single.csv, clipboardWrites.single);
      expect(downloads.single.filename, endsWith('.csv'));
      expect(
        find.text('Downloaded audit log CSV and copied it to your clipboard.'),
        findsOneWidget,
      );

      // The export-itself-audited row exists in the gateway ledger
      // and is idempotency-keyed off the screen value.
      final exportRow = gateway.debugEntries.firstWhere(
        (row) => row.entryId == 'demo-audit-export-fixed-export-key-1',
      );
      expect(exportRow.action, WebAuditLogActions.auditExportRequested);
    });
  });

  group('No em dash regression on 11W.5-owned files', () {
    test('every operator-facing string literal in the 11W.5 file set is '
        'em-dash free', () async {
      const ownedPaths = <String>[
        'lib/operator_web/services/web_team_audit_log_gateway.dart',
        'lib/operator_web/services/demo_team_audit_log_gateway.dart',
        'lib/operator_web/widgets/audit_log_row.dart',
        'lib/operator_web/screens/audit_log_screen.dart',
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

/// Wraps the demo gateway with a forced page size so the pagination
/// test can exercise load-more without inflating the fixture set.
class _SmallPageGateway implements WebTeamAuditLogGateway {
  _SmallPageGateway({required DateTime pinnedClock, required this.pageSize})
    : _delegate = DemoWebTeamAuditLogGateway(clock: pinnedClock);

  final DemoWebTeamAuditLogGateway _delegate;
  final int pageSize;

  @override
  Future<WebAuditLogPage> listEntries(WebAuditLogQuery query) {
    return _delegate.listEntries(query.copyWith(limit: pageSize));
  }

  @override
  Future<WebAuditLogCsvExport> exportCsv(
    WebAuditLogQuery query, {
    required String idempotencyKey,
  }) {
    return _delegate.exportCsv(
      query.copyWith(limit: pageSize),
      idempotencyKey: idempotencyKey,
    );
  }
}
