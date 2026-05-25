// Phase 11A.14 - Admin Audit log tab parity tests.
//
// Ops/operator-web is the authority for the visible audit-log UX.
// These tests pin the admin tab to the same header, filters, row
// rendering, list states, and CSV export feedback. The left
// business/scope picker lives in the admin workspace shell and is the
// intentional exception.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/audited_support_actions_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/admin_audit_chain_anchors_gateway.dart';
import 'package:forge_and_flow/admin/services/audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_audited_support_actions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_members_admin_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_team_audit_log_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '../../_test_helpers/widget_pump_helpers.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  OperatorPickerResult demoPick() => const OperatorPickerResult(
    operatorId: kDemoDinerOperatorId,
    locationId: kDemoDinerLocationToronto,
    operatorBusinessName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  InMemoryAuditedSupportActionsAdminGateway buildDemoGateway({DateTime? at}) {
    return InMemoryAuditedSupportActionsAdminGateway(
      auditLogByOperator: kDemoAuditLogByOperator(at: at),
      membersByOperator: kDemoSupportActionsMembersByOperator(),
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    InMemoryAuditedSupportActionsAdminGateway? gateway,
    AdminAuditChainAnchorsGateway? anchorsGateway,
    bool canExportAuditLog = false,
    DateTime Function()? anchorBadgeClock,
    AdminHierarchyScopeIntent? hierarchyScope,
    Future<void> Function(WebAuditLogCsvExport export)? onCsvReady,
    Future<void> Function(String value)? copyToClipboard,
  }) async {
    await tester.pumpWidget(
      wrap(
        AuditedSupportActionsAdminScreen(
          gateway: gateway ?? buildDemoGateway(),
          anchorsGateway: anchorsGateway,
          actorUserId: 'demo-super-admin',
          pickedOperator: demoPick(),
          canExportAuditLog: canExportAuditLog,
          anchorBadgeClock: anchorBadgeClock,
          hierarchyScope: hierarchyScope,
          onCsvReady: onCsvReady,
          copyToClipboard: copyToClipboard,
        ),
      ),
    );
    await pumpEventually(tester);
  }

  group('ops parity surface', () {
    testWidgets('renders the ops-shaped audit tab and no old admin panels', (
      tester,
    ) async {
      wideViewport(tester);
      await pumpScreen(tester, canExportAuditLog: true);

      expect(
        find.byKey(const Key('admin_audited_support_actions_screen')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.fact_check_outlined), findsOneWidget);
      expect(find.text('Audit log'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_asa_audit_log_subtitle')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Every change someone made to your team, your roles',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_log_export_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_filters')), findsOneWidget);
      expect(find.byKey(const Key('admin_asa_audit_log_list')), findsOneWidget);

      expect(find.byKey(const Key('admin_asa_actions_panel')), findsNothing);
      expect(
        find.byKey(const Key('admin_security_sessions_panel')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_scope_picker')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_asa_scope_banner')), findsNothing);
      expect(find.textContaining('Cursor-paginated rows'), findsNothing);
    });

    testWidgets('lists seeded rows with ops row copy and actor chips', (
      tester,
    ) async {
      wideViewport(tester);
      await pumpScreen(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-1')),
        findsOneWidget,
      );
      expect(find.text('Invited team member'), findsWidgets);
      expect(
        find.text('Dana Owner \u2022 owner@demo-diner.test'),
        findsOneWidget,
      );
      expect(find.text('team'), findsWidgets);
      expect(find.text('F&F admin'), findsWidgets);
      expect(find.text('auth_session:'), findsOneWidget);
      expect(find.text('session-diner-owner-mobile'), findsOneWidget);
      expect(find.text('team.users.invite'), findsNothing);
      expect(find.textContaining('Target:'), findsNothing);
    });
  });

  group('filters', () {
    testWidgets('exposes ops chips only', (tester) async {
      wideViewport(tester);
      await pumpScreen(tester);

      for (final suffix in <String>['24h', '7d', '30d', '90d']) {
        expect(
          find.byKey(Key('admin_asa_audit_log_time_window_$suffix')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const Key('admin_asa_audit_log_time_window_custom')),
        findsOneWidget,
      );
      for (final action in WebAuditLogActions.catalog) {
        expect(
          find.byKey(
            Key('admin_asa_audit_log_action_${action.replaceAll('.', '_')}'),
          ),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(
          const Key('admin_asa_audit_log_actor_demo-user-diner-owner'),
        ),
        findsOneWidget,
      );
      expect(find.text('Team member'), findsOneWidget);

      expect(
        find.byKey(const Key('admin_asa_filter_target_kind')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_asa_filter_target_id')), findsNothing);
      expect(find.byKey(const Key('admin_asa_filter_apply')), findsNothing);
      expect(find.text('Actor kind'), findsNothing);
    });

    testWidgets('action chips apply immediately', (tester) async {
      wideViewport(tester);
      await pumpScreen(tester);

      await tester.tap(
        find.byKey(const Key('admin_asa_audit_log_action_team_users_invite')),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-2')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-3')),
        findsNothing,
      );
    });

    testWidgets('left workspace location scope feeds the audit query', (
      tester,
    ) async {
      wideViewport(tester);
      final ts = DateTime.utc(2026, 5, 5, 12);
      final gateway = _RecordingAuditGateway(
        auditLogByOperator: <String, List<AuditLogRow>>{
          kDemoDinerOperatorId: <AuditLogRow>[
            _auditRow(id: 'loc-a-row', occurredAt: ts, locationId: 'loc-a'),
            _auditRow(
              id: 'loc-b-row',
              occurredAt: ts.subtract(const Duration(minutes: 1)),
              locationId: 'loc-b',
            ),
          ],
        },
      );

      await pumpScreen(
        tester,
        gateway: gateway,
        hierarchyScope: const AdminHierarchyScopeIntent.location(
          operatorId: kDemoDinerOperatorId,
          locationId: 'loc-a',
        ),
      );

      expect(
        find.byKey(const Key('admin_asa_audit_row_loc-a-row')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_loc-b-row')),
        findsNothing,
      );
      expect(gateway.scopes.last?.scopeType, AuditLogScopeType.location);
      expect(gateway.scopes.last?.locationFilter, 'loc-a');
      expect(gateway.listMembersCalls, 0);
    });

    testWidgets('custom range chip opens the ops date dialog', (tester) async {
      wideViewport(tester);
      await pumpScreen(tester);

      await tester.tap(
        find.byKey(const Key('admin_asa_audit_log_time_window_custom')),
      );
      await pumpEventually(tester);

      expect(find.text('Choose audit log dates'), findsOneWidget);
    });
  });

  group('rows', () {
    testWidgets('target copy uses ops clipboard and snackbar copy', (
      tester,
    ) async {
      wideViewport(tester);
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final data = call.arguments as Map<Object?, Object?>;
              calls.add(data['text'] as String);
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpScreen(tester);
      await tester.ensureVisible(
        find.byKey(
          const Key('operator_web_audit_log_row_seed-diner-3_copy_target'),
        ),
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_audit_log_row_seed-diner-3_copy_target'),
        ),
      );
      await pumpEventually(tester);

      expect(calls, equals(<String>['session-diner-owner-mobile']));
      expect(
        find.text('Copied session-diner-owner-mobile to clipboard.'),
        findsOneWidget,
      );
    });

    testWidgets('payload toggle uses ops JSON formatting', (tester) async {
      wideViewport(tester);
      await pumpScreen(tester);

      expect(
        find.byKey(
          const Key('operator_web_audit_log_row_seed-diner-3_payload'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const Key('operator_web_audit_log_row_seed-diner-3_payload_toggle'),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(
          const Key('operator_web_audit_log_row_seed-diner-3_payload'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('"user_id": "demo-user-diner-owner"'),
        findsOneWidget,
      );
    });
  });

  group('pagination and export', () {
    testWidgets('Load more appends rows inside the ops-style list', (
      tester,
    ) async {
      wideViewport(tester);
      final ts = DateTime.utc(2026, 5, 5, 12);
      final manyRows = <AuditLogRow>[
        for (var i = 0; i < 250; i++)
          AuditLogRow(
            eventId: 'pg-${i.toString().padLeft(3, '0')}',
            action: WebAuditLogActions.authPasswordChanged,
            occurredAt: ts.subtract(Duration(minutes: i)),
            actorUserId: 'demo-user-diner-owner',
            actorDisplayName: 'Dana Owner',
            actorEmail: 'owner@demo-diner.test',
            actorKind: AuditActorKind.teamMember,
            operatorId: kDemoDinerOperatorId,
            targetKind: 'user',
            targetId: 'demo-user-diner-owner',
            payload: const <String, Object?>{},
            businessDate: DateTime.utc(ts.year, ts.month, ts.day),
          ),
      ];
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: <String, List<AuditLogRow>>{
          kDemoDinerOperatorId: manyRows,
        },
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      );

      await pumpScreen(tester, gateway: gateway);

      expect(
        find.byKey(const Key('admin_asa_audit_row_pg-199')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_audit_row_pg-200')), findsNothing);
      expect(find.byType(TextButton), findsWidgets);

      await tester.ensureVisible(
        find.byKey(const Key('admin_asa_audit_log_load_more')),
      );
      await tester.tap(find.byKey(const Key('admin_asa_audit_log_load_more')));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_pg-249')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_log_load_more')),
        findsNothing,
      );
    });

    testWidgets('CSV export uses the ops header flow and feedback', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      final calls = <String>[];
      final downloads = <WebAuditLogCsvExport>[];

      await pumpScreen(
        tester,
        gateway: gateway,
        canExportAuditLog: true,
        copyToClipboard: (value) async => calls.add(value),
        onCsvReady: (export) async => downloads.add(export),
      );
      await tester.tap(
        find.byKey(const Key('admin_asa_audit_log_export_button')),
      );
      await pumpEventually(tester);

      expect(calls.single, contains('event_id,occurred_at,action'));
      expect(downloads, hasLength(1));
      expect(
        find.byKey(const Key('admin_asa_audit_log_export_message')),
        findsOneWidget,
      );
      expect(
        find.text('Downloaded audit log CSV and copied it to your clipboard.'),
        findsOneWidget,
      );
      expect(find.textContaining('Audit log CSV ready'), findsOneWidget);
      expect(find.byKey(const Key('admin_asa_reason_dialog')), findsNothing);
      expect(
        gateway
            .capturedAuditLogFor(kDemoDinerOperatorId)
            .any(
              (row) =>
                  row.action == SupportActionsAuditAction.auditExportRequested,
            ),
        isTrue,
      );
    });
  });

  group('helpers and integrity badge', () {
    test('helpers mirror ops labels, timestamp, and JSON payload', () {
      expect(
        humanizeAuditAction(WebAuditLogActions.teamUsersDeactivate),
        equals('Suspended team member'),
      );
      expect(humanizeAuditAction('foo.bar.baz'), equals('Baz'));
      expect(
        formatAuditTimestamp(DateTime.utc(2026, 5, 6, 12, 30)),
        isNot(contains('UTC')),
      );
      expect(formatPayload(const <String, Object?>{}), equals('(no payload)'));
      expect(
        formatPayload(const <String, Object?>{
          'user_id': 'u1',
          'mfa_enrolled': <String, Object?>{'from': true, 'to': false},
        }),
        contains('"mfa_enrolled"'),
      );
    });

    test('formatGraceWindowRemaining keeps compact two-unit form', () {
      expect(
        formatGraceWindowRemaining(
          now: DateTime.utc(2026, 5, 8, 12),
          endsAt: DateTime.utc(2026, 5, 9, 14, 7),
        ),
        equals('26h 7m'),
      );
    });

    testWidgets('renders healthy and unknown integrity states', (tester) async {
      wideViewport(tester);
      await pumpScreen(
        tester,
        anchorsGateway: InMemoryAdminAuditChainAnchorsGateway(
          clock: () => DateTime.utc(2026, 5, 7, 6),
        ),
        anchorBadgeClock: () => DateTime.utc(2026, 5, 7, 6),
      );
      expect(
        find.byKey(const Key('admin_audit_log_integrity_badge_healthy_title')),
        findsOneWidget,
      );

      await pumpScreen(tester);
      expect(
        find.byKey(const Key('admin_audit_log_integrity_badge_unknown_title')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_audit_log_list')), findsOneWidget);
    });

    testWidgets('rendered audit tab copy has no em dash', (tester) async {
      wideViewport(tester);
      await pumpScreen(
        tester,
        anchorsGateway: InMemoryAdminAuditChainAnchorsGateway(
          clock: () => DateTime.utc(2026, 5, 7, 6),
        ),
        anchorBadgeClock: () => DateTime.utc(2026, 5, 7, 6),
      );

      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        final data = text.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });
  });
}

AuditLogRow _auditRow({
  required String id,
  required DateTime occurredAt,
  required String locationId,
}) {
  return AuditLogRow(
    eventId: id,
    action: WebAuditLogActions.teamUsersInvite,
    occurredAt: occurredAt,
    actorUserId: 'demo-user-diner-owner',
    actorDisplayName: 'Dana Owner',
    actorEmail: 'owner@demo-diner.test',
    actorKind: AuditActorKind.teamMember,
    operatorId: kDemoDinerOperatorId,
    targetKind: 'user',
    targetId: 'demo-user-diner-owner',
    payload: <String, Object?>{'location_id': locationId},
    businessDate: DateTime.utc(
      occurredAt.year,
      occurredAt.month,
      occurredAt.day,
    ),
  );
}

class _RecordingAuditGateway extends InMemoryAuditedSupportActionsAdminGateway {
  _RecordingAuditGateway({
    required Map<String, List<AuditLogRow>> auditLogByOperator,
  }) : super(
         auditLogByOperator: auditLogByOperator,
         membersByOperator: const <String, List<SupportActionsMember>>{},
       );

  final List<AuditLogScope?> scopes = <AuditLogScope?>[];
  int listMembersCalls = 0;

  @override
  Future<AuditLogPage> listAuditLog({
    required String operatorId,
    AuditLogFilters filters = AuditLogFilters.empty,
    String? cursor,
    AuditLogScope? scope,
  }) {
    scopes.add(scope);
    return super.listAuditLog(
      operatorId: operatorId,
      filters: filters,
      cursor: cursor,
      scope: scope,
    );
  }

  @override
  Future<List<SupportActionsMember>> listMembers({required String operatorId}) {
    listMembersCalls += 1;
    throw StateError('audit tab should not load members');
  }
}
