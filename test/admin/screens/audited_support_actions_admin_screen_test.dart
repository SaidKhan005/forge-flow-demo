// Phase 11A.14 - Audited support actions screen widget tests.
//
// Coverage focuses on the parity-contract surface: the audit log
// table renders after picking an operator, the Actions panel
// affordances are gated on the MFA-required claim flags, the
// admin_reason dialog blocks empty submissions, every write captures
// the F&F admin's UID + a non-empty admin_reason on both the
// audit_logs row AND the admin_action_log provenance row, and
// view-only mode hides every mutate affordance.

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
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
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

  InMemoryAuditedSupportActionsAdminGateway buildDemoGateway() {
    return InMemoryAuditedSupportActionsAdminGateway(
      auditLogByOperator: kDemoAuditLogByOperator(),
      membersByOperator: kDemoSupportActionsMembersByOperator(),
    );
  }

  group('audit log + actions panel render', () {
    testWidgets('renders Actions panel + Audit log card after operator pick', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      final sessionsGateway = InMemoryRolesHierarchySessionsAdminGateway(
        rolesByOperator: kDemoRolesByOperator(),
        orgUnitsByOperator: kDemoOrgUnitsByOperator(),
        locationsByOperator: kDemoHierarchyLocationsByOperator(),
        sessionsByOperator: kDemoSessionsByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            sessionsGateway: sessionsGateway,
            hierarchyScope: const AdminHierarchyScopeIntent.location(
              operatorId: kDemoDinerOperatorId,
              operatorName: 'Demo Diner Co.',
              locationId: kDemoDinerLocationToronto,
              locationName: 'Toronto Yorkville',
              valueState: AdminHierarchyScopeValueState.locationOnly,
              effectiveValueLabel: 'Toronto Yorkville',
              allowedActionsLabel: 'Security actions audit logged',
            ),
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canResetMfaFactors: true,
            canIssuePairedErasure: true,
            canExportAuditLog: true,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_audited_support_actions_screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_actions_panel')), findsOneWidget);
      expect(find.byKey(const Key('admin_asa_scope_banner')), findsOneWidget);
      expect(
        find.text('Location: Demo Diner Co. / Toronto Yorkville'),
        findsOneWidget,
      );
      expect(find.text('Location only'), findsOneWidget);
      expect(find.text('Effective: Toronto Yorkville'), findsOneWidget);
      expect(find.text('Security actions audit logged'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_security_sessions_panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_rhs_session_row_session-diner-owner-mobile'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_audit_log')), findsOneWidget);
      expect(
        find.byKey(const Key('admin_asa_action_group_recovery')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_action_group_data_protection')),
        findsOneWidget,
      );
      // Each Actions panel row carries a stable key + button.
      expect(
        find.byKey(const Key('admin_asa_action_reset_mfa')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_action_password_reset')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_asa_action_erasure')), findsOneWidget);
    });

    testWidgets('audit log card lists seeded rows', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-3')),
        findsOneWidget,
      );
    });

    testWidgets('audit rows show actor name, role, and email when present', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: <String, List<AuditLogRow>>{
          kDemoDinerOperatorId: <AuditLogRow>[
            AuditLogRow(
              eventId: 'actor-full',
              action: 'auth.password.change',
              occurredAt: DateTime.utc(2026, 5, 6, 12, 30),
              actorUserId: 'demo-user-diner-owner',
              actorDisplayName: 'Dana Owner',
              actorEmail: 'owner@demo-diner.test',
              actorKind: AuditActorKind.teamMember,
              actorRole: 'Owner',
              operatorId: kDemoDinerOperatorId,
              targetKind: 'user',
              targetId: 'demo-user-diner-owner',
              payload: const <String, Object?>{},
              businessDate: DateTime.utc(2026, 5, 6),
            ),
          ],
        },
        membersByOperator: kDemoSupportActionsMembersByOperator(),
      );
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      expect(find.text('Dana Owner • owner@demo-diner.test'), findsOneWidget);
    });
  });

  group('Actions panel gating', () {
    testWidgets('Reset MFA disabled when canResetMfaFactors is false', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('Reset MFA enabled when canResetMfaFactors is true', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canResetMfaFactors: true,
          ),
        ),
      );
      await pumpEventually(tester);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('Issue erasure disabled when canIssuePairedErasure is false', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_erasure_btn')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('view-only mode hides every mutate affordance', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-ff-support',
            pickedOperator: demoPick(),
            editingEnabled: false,
            canResetMfaFactors: true,
            canIssuePairedErasure: true,
            canExportAuditLog: true,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_readonly_banner')),
        findsOneWidget,
      );
      // CSV export is hidden because canExport is the AND of editing
      // + canExportAuditLog; editingEnabled=false collapses both.
      expect(find.byKey(const Key('admin_asa_audit_log_export')), findsNothing);
      // Action buttons render but are disabled (editing=false).
      final resetBtn = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
      );
      final passwordBtn = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_password_reset_btn')),
      );
      final erasureBtn = tester.widget<OutlinedButton>(
        find.byKey(const Key('admin_asa_action_erasure_btn')),
      );
      expect(resetBtn.onPressed, isNull);
      expect(passwordBtn.onPressed, isNull);
      expect(erasureBtn.onPressed, isNull);
    });

    testWidgets('password reset excludes pending invite-only users', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(),
        membersByOperator: const <String, List<SupportActionsMember>>{
          kDemoDinerOperatorId: <SupportActionsMember>[
            SupportActionsMember(
              userId: 'invite-only-user',
              email: 'invite-only@demo.test',
              displayName: 'Invite Only',
              mfaEnrolled: false,
              canReceivePasswordReset: false,
              passwordResetBlockedReason: 'Pending invite',
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      final passwordResetButton = find.byKey(
        const Key('admin_asa_action_password_reset_btn'),
      );
      await tester.ensureVisible(passwordResetButton);
      await pumpEventually(tester);
      await tester.tap(passwordResetButton);
      await pumpEventually(tester);

      expect(
        find.text(
          'No active member can receive a password reset yet. Pending invite-only users must accept their invite first.',
        ),
        findsOneWidget,
      );
      final submit = tester.widget<FilledButton>(
        find.byKey(const Key('admin_asa_member_picker_submit')),
      );
      expect(submit.onPressed, isNull);
    });
  });

  group('Reset MFA write path', () {
    testWidgets(
      'Reset MFA dialog flow writes audit_logs + admin_action_log with admin_reason',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              canResetMfaFactors: true,
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
        );
        await tester.tap(
          find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
        );
        await pumpEventually(tester);

        // Member picker opens.
        expect(
          find.byKey(const Key('admin_asa_member_picker_dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('admin_asa_member_picker_submit')),
        );
        await pumpEventually(tester);

        // Reason dialog opens; submit empty first to assert the guard.
        await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
        await pumpEventually(tester);
        expect(find.text('Add a reason before continuing.'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('admin_asa_reason_field')),
          'walkthrough verification',
        );
        await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
        await pumpEventually(tester);

        expect(gateway.capturedAdminActionLog, hasLength(1));
        final entry = gateway.capturedAdminActionLog.single;
        expect(entry.action, equals(SupportActionsAuditAction.resetMfaFactors));
        expect(entry.readerUserId, equals('demo-super-admin'));
        expect(entry.adminReason, equals('walkthrough verification'));
        // Audit log row also captured.
        final audits = gateway.capturedAuditLogFor(kDemoDinerOperatorId);
        final newRow = audits.firstWhere(
          (r) => r.action == SupportActionsAuditAction.resetMfaFactors,
        );
        expect(newRow.actorKind, equals(AuditActorKind.forgeAdmin));
        expect(newRow.adminReason, equals('walkthrough verification'));
      },
    );
  });

  group('Reset MFA reason dialog blocks empty submissions', () {
    testWidgets('cancelling the reason dialog writes no audit row', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canResetMfaFactors: true,
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.ensureVisible(
        find.byKey(const Key('admin_asa_action_reset_mfa_btn')),
      );
      await tester.tap(find.byKey(const Key('admin_asa_action_reset_mfa_btn')));
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_asa_member_picker_submit')));
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_asa_reason_cancel')));
      await pumpEventually(tester);

      expect(gateway.capturedAdminActionLog, isEmpty);
    });
  });

  group('parity contract filter set', () {
    testWidgets(
      'filter bar mirrors operator-web chips without admin-only target controls',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        expect(find.byKey(const Key('admin_asa_filter_actor')), findsOneWidget);
        expect(find.text('Team member'), findsOneWidget);
        expect(find.text('Actor'), findsNothing);
        expect(
          find.byKey(const Key('admin_asa_filter_actor_demo-user-diner-owner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_filter_time_window')),
          findsOneWidget,
        );
        for (final key in const <String>['24h', '7d', '30d', '90d']) {
          expect(
            find.byKey(Key('admin_asa_filter_time_window_$key')),
            findsOneWidget,
            reason: 'expected time-window chip for $key',
          );
        }
        expect(
          find.byKey(const Key('admin_asa_filter_time_window_custom')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_filter_target_kind')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('admin_asa_filter_target_id')),
          findsNothing,
        );
        expect(find.byKey(const Key('admin_asa_filter_apply')), findsNothing);
        for (final kind in AuditActorKind.values) {
          expect(
            find.byKey(Key('admin_asa_filter_actor_kind_${kind.wire}')),
            findsNothing,
          );
        }
        for (final action in kAuditLogFilterableActions) {
          expect(
            find.byKey(Key('admin_asa_filter_action_$action')),
            findsOneWidget,
            reason: 'expected action chip for $action',
          );
        }
      },
    );

    testWidgets('selecting an action chip immediately narrows the table', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.ensureVisible(
        find.byKey(const Key('admin_asa_filter_action_team.users.invite')),
      );
      await tester.tap(
        find.byKey(const Key('admin_asa_filter_action_team.users.invite')),
      );
      await pumpEventually(tester);

      // Only the team.users.invite fixture row remains.
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-3')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-2')),
        findsNothing,
      );
    });

    testWidgets('actor chips support multi-select and filter immediately', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(const Key('admin_asa_filter_actor_demo-user-diner-owner')),
      );
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(const Key('admin_asa_filter_actor_demo-user-diner-manager')),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_asa_audit_row_seed-diner-3')),
        findsNothing,
      );
    });

    testWidgets('selecting Custom range opens the shared date-range dialog', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(const Key('admin_asa_filter_time_window_custom')),
      );
      await pumpEventually(tester);

      expect(find.text('Choose audit log dates'), findsOneWidget);
    });
  });

  group('parity contract row rendering', () {
    testWidgets('export copies CSV to clipboard and refreshes export row', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
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

      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canExportAuditLog: true,
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.tap(find.byKey(const Key('admin_asa_audit_log_export')));
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_asa_reason_field')),
        'support export',
      );
      await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
      await pumpEventually(tester);

      expect(calls, hasLength(1));
      expect(calls.single, contains('event_id,occurred_at,action'));
      expect(
        find.text('Copied audit log CSV to your clipboard.'),
        findsOneWidget,
      );
      expect(find.text('Exported audit log'), findsWidgets);
    });

    testWidgets('target_id copy button copies to system clipboard', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      // Stub the clipboard channel so the test can observe writes
      // without depending on the host platform's clipboard.
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

      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      await tester.ensureVisible(
        find.byKey(const Key('admin_asa_audit_row_copy_target_seed-diner-3')),
      );
      await pumpEventually(tester);
      await tester.tap(
        find.byKey(const Key('admin_asa_audit_row_copy_target_seed-diner-3')),
      );
      await pumpEventually(tester);

      expect(calls, equals(<String>['session-diner-owner-mobile']));
    });

    testWidgets('View payload toggle reveals + hides the formatted payload', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
          ),
        ),
      );
      await pumpEventually(tester);

      // Default: payload hidden.
      expect(
        find.byKey(const Key('admin_asa_audit_row_payload_seed-diner-3')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(
          const Key('admin_asa_audit_row_payload_toggle_seed-diner-3'),
        ),
      );
      await tester.tap(
        find.byKey(
          const Key('admin_asa_audit_row_payload_toggle_seed-diner-3'),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_asa_audit_row_payload_seed-diner-3')),
        findsOneWidget,
      );
      // Payload contents render the canonical key.
      expect(find.textContaining('user_id'), findsWidgets);

      // Toggle off again.
      await tester.tap(
        find.byKey(
          const Key('admin_asa_audit_row_payload_toggle_seed-diner-3'),
        ),
      );
      await pumpEventually(tester);
      expect(
        find.byKey(const Key('admin_asa_audit_row_payload_seed-diner-3')),
        findsNothing,
      );
    });
  });

  group('cursor pagination', () {
    testWidgets(
      'Load more button appears when nextCursor is non-null and appends rows',
      (tester) async {
        wideViewport(tester);
        // 250 seeded rows triggers cursor pagination (page size = 200).
        final ts = DateTime.utc(2026, 5, 5, 12);
        final manyRows = <AuditLogRow>[
          for (var i = 0; i < 250; i++)
            AuditLogRow(
              eventId: 'pg-${i.toString().padLeft(3, '0')}',
              action: 'auth.password.change',
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

        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        // First page: 200 rows; Load more visible.
        expect(
          find.byKey(const Key('admin_asa_audit_row_pg-000')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_audit_row_pg-199')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_audit_row_pg-200')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('admin_asa_audit_log_load_more')),
          findsOneWidget,
        );

        await tester.ensureVisible(
          find.byKey(const Key('admin_asa_audit_log_load_more')),
        );
        await tester.tap(
          find.byKey(const Key('admin_asa_audit_log_load_more')),
        );
        await pumpEventually(tester);

        // After Load more: row 200+ visible, button is gone (no more rows).
        expect(
          find.byKey(const Key('admin_asa_audit_row_pg-200')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_audit_row_pg-249')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_audit_log_load_more')),
          findsNothing,
        );
      },
    );
  });

  group('humanizer + payload formatter helpers', () {
    test('humanizeAuditAction maps the contract example', () {
      expect(
        humanizeAuditAction('team.users.invite'),
        equals('Invited team member'),
      );
      // Falls through to the raw key for unknown actions so unknown
      // vocabulary stays readable like operator web.
      expect(humanizeAuditAction('foo.bar.baz'), equals('Baz'));
    });

    test('formatAuditTimestamp keeps the canonical UTC ISO suffix', () {
      final formatted = formatAuditTimestamp(DateTime.utc(2026, 5, 6, 12, 30));
      expect(formatted, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')));
    });

    test('formatPayload renders operator-web style JSON', () {
      final out = formatPayload(<String, Object?>{
        'user_id': 'u1',
        'mfa_enrolled': const <String, Object?>{'from': true, 'to': false},
      });
      expect(out, contains('"user_id": "u1"'));
      expect(out, contains('"mfa_enrolled": {'));
      expect(out, contains('"from": true'));
      expect(out, contains('"to": false'));
      expect(formatPayload(const <String, Object?>{}), equals('(no payload)'));
    });
  });

  group('CODE_OPS_DEBT carry-over #2 grace-window chip', () {
    testWidgets('reversible state shows countdown label and Reverse button', (
      tester,
    ) async {
      wideViewport(tester);
      final fixedNow = DateTime.utc(2026, 5, 8, 12, 0);
      final gateway = InMemoryAuditedSupportActionsAdminGateway(
        auditLogByOperator: kDemoAuditLogByOperator(at: fixedNow),
        membersByOperator: kDemoSupportActionsMembersByOperator(),
        clock: () => fixedNow,
      );
      // Screen-side clock matches the gateway's "now" so the chip
      // mounts inside the 24h grace window.
      final viewNow = fixedNow;

      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            canIssuePairedErasure: true,
            graceWindowClock: () => viewNow,
            // Use a far-future tick interval so `pumpAndSettle`
            // does not chase the periodic timer; the chip's
            // initial build is what we are asserting against.
            graceWindowTickInterval: const Duration(days: 30),
          ),
        ),
      );
      await pumpEventually(tester);

      // Chip is hidden before any erasure runs.
      expect(
        find.byKey(const Key('admin_asa_grace_window_chip')),
        findsNothing,
      );

      // Drive an erasure through the action panel.
      await tester.ensureVisible(
        find.byKey(const Key('admin_asa_action_erasure_btn')),
      );
      await tester.tap(find.byKey(const Key('admin_asa_action_erasure_btn')));
      await pumpEventually(tester);
      await tester.tap(find.byKey(const Key('admin_asa_member_picker_submit')));
      await pumpEventually(tester);
      await tester.enterText(
        find.byKey(const Key('admin_asa_reason_field')),
        'walkthrough verification',
      );
      await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
      await pumpEventually(tester);

      // Chip is mounted, label shows the countdown, and the
      // Reverse button is enabled while inside the window.
      expect(
        find.byKey(const Key('admin_asa_grace_window_chip')),
        findsOneWidget,
      );
      final label = tester.widget<Text>(
        find.byKey(const Key('admin_asa_grace_window_chip_label')),
      );
      expect(label.data, contains('Erasure reversible'));
      expect(label.data, contains('remaining'));
      expect(
        find.byKey(const Key('admin_asa_grace_window_chip_reverse')),
        findsOneWidget,
      );
    });

    testWidgets(
      'expired state hides Reverse button and shows "Erasure final"',
      (tester) async {
        wideViewport(tester);
        final fixedNow = DateTime.utc(2026, 5, 8, 12, 0);
        // Gateway computes `gracePeriodEndsAt = fixedNow + 24h`; the
        // screen-side clock starts 30h in the future so the chip is
        // mounted past the boundary on its very first build. This
        // avoids racing the periodic ticker (which would force
        // `pumpAndSettle` to chase a moving fake clock).
        final gateway = InMemoryAuditedSupportActionsAdminGateway(
          auditLogByOperator: kDemoAuditLogByOperator(at: fixedNow),
          membersByOperator: kDemoSupportActionsMembersByOperator(),
          clock: () => fixedNow,
        );
        final viewNow = fixedNow.add(const Duration(hours: 30));

        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              canIssuePairedErasure: true,
              graceWindowClock: () => viewNow,
              graceWindowTickInterval: const Duration(days: 30),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_asa_action_erasure_btn')),
        );
        await tester.tap(find.byKey(const Key('admin_asa_action_erasure_btn')));
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_asa_member_picker_submit')),
        );
        await pumpEventually(tester);
        await tester.enterText(
          find.byKey(const Key('admin_asa_reason_field')),
          'walkthrough verification',
        );
        await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
        await pumpEventually(tester);

        // Chip mounted past the 24h boundary - shows "Erasure final"
        // and offers no reverse affordance.
        final label = tester.widget<Text>(
          find.byKey(const Key('admin_asa_grace_window_chip_label')),
        );
        expect(label.data, equals('Erasure final'));
        expect(
          find.byKey(const Key('admin_asa_grace_window_chip_reverse')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'tapping Reverse erasure calls reversePiiErasure on the gateway',
      (tester) async {
        wideViewport(tester);
        final fixedNow = DateTime.utc(2026, 5, 8, 12, 0);
        final gateway = _RecordingErasureGateway(
          auditLogByOperator: kDemoAuditLogByOperator(at: fixedNow),
          membersByOperator: kDemoSupportActionsMembersByOperator(),
          clock: () => fixedNow,
        );
        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
              canIssuePairedErasure: true,
              graceWindowClock: () => fixedNow,
              // Use a far-future tick interval so `pumpAndSettle`
              // does not chase the periodic timer; the chip's
              // initial build is what we are asserting against.
              graceWindowTickInterval: const Duration(days: 30),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_asa_action_erasure_btn')),
        );
        await tester.tap(find.byKey(const Key('admin_asa_action_erasure_btn')));
        await pumpEventually(tester);
        await tester.tap(
          find.byKey(const Key('admin_asa_member_picker_submit')),
        );
        await pumpEventually(tester);
        await tester.enterText(
          find.byKey(const Key('admin_asa_reason_field')),
          'walkthrough verification',
        );
        await tester.tap(find.byKey(const Key('admin_asa_reason_submit')));
        await pumpEventually(tester);

        expect(gateway.reverseCallCount, equals(0));
        await tester.ensureVisible(
          find.byKey(const Key('admin_asa_grace_window_chip_reverse')),
        );
        await tester.tap(
          find.byKey(const Key('admin_asa_grace_window_chip_reverse')),
        );
        await pumpEventually(tester);

        expect(gateway.reverseCallCount, equals(1));
        // Chip clears once the reverse outcome lands.
        expect(
          find.byKey(const Key('admin_asa_grace_window_chip')),
          findsNothing,
        );
      },
    );

    test('formatGraceWindowRemaining truncates to compact two-unit form', () {
      final base = DateTime.utc(2026, 5, 8, 12);
      expect(
        formatGraceWindowRemaining(
          now: base,
          endsAt: base.add(const Duration(hours: 14, minutes: 23)),
        ),
        equals('14h 23m'),
      );
      expect(
        formatGraceWindowRemaining(
          now: base,
          endsAt: base.add(const Duration(minutes: 45, seconds: 12)),
        ),
        equals('45m 12s'),
      );
      expect(
        formatGraceWindowRemaining(
          now: base,
          endsAt: base.subtract(const Duration(minutes: 1)),
        ),
        equals('0m'),
      );
    });
  });

  group('audit-chain integrity badge', () {
    testWidgets('renders the healthy badge for a healthy snapshot', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      final now = DateTime.utc(2026, 5, 7, 6);
      final anchorsGateway = InMemoryAdminAuditChainAnchorsGateway(
        snapshot: AdminAuditChainAnchorSnapshot(
          status: AdminAuditChainAnchorStatus.healthy,
          anchoredAt: now.subtract(const Duration(hours: 4)),
          lastAnchorBlobAt: now.subtract(const Duration(hours: 4)),
          chainDate: DateTime.utc(2026, 5, 6),
        ),
      );
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            anchorsGateway: anchorsGateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            anchorBadgeClock: () => now,
          ),
        ),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_audit_log_integrity_badge')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_audit_log_integrity_badge_healthy_title')),
        findsOneWidget,
      );
      expect(find.text('Audit chain healthy'), findsOneWidget);
      expect(
        find.text('Anchored at 02:00 UTC. Last anchor 4 hours ago.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'null gateway renders the neutral unknown state; screen still renders',
      (tester) async {
        wideViewport(tester);
        final gateway = buildDemoGateway();
        await tester.pumpWidget(
          wrap(
            AuditedSupportActionsAdminScreen(
              gateway: gateway,
              // No anchorsGateway → null → neutral unknown, never crash.
              actorUserId: 'demo-super-admin',
              pickedOperator: demoPick(),
            ),
          ),
        );
        await pumpEventually(tester);

        // Badge renders the neutral unknown state.
        expect(
          find.byKey(const Key('admin_audit_log_integrity_badge')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('admin_audit_log_integrity_badge_unknown_title'),
          ),
          findsOneWidget,
        );
        expect(find.text('Audit chain status unknown'), findsOneWidget);
        // The rest of the screen still renders (no crash on null gateway).
        expect(
          find.byKey(const Key('admin_audited_support_actions_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_asa_actions_panel')),
          findsOneWidget,
        );
      },
    );
  });

  group('zero em dashes in operator-facing literals', () {
    testWidgets('rendered text never contains an em dash', (tester) async {
      wideViewport(tester);
      final gateway = buildDemoGateway();
      // Wire a healthy anchor gateway so the integrity badge's copy is
      // also swept for em dashes in this render.
      final anchorsGateway = InMemoryAdminAuditChainAnchorsGateway(
        clock: () => DateTime.utc(2026, 5, 7, 6),
      );
      await tester.pumpWidget(
        wrap(
          AuditedSupportActionsAdminScreen(
            gateway: gateway,
            anchorsGateway: anchorsGateway,
            actorUserId: 'demo-super-admin',
            pickedOperator: demoPick(),
            editingEnabled: false,
            anchorBadgeClock: () => DateTime.utc(2026, 5, 7, 6),
          ),
        ),
      );
      await pumpEventually(tester);

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final data = t.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });
  });
}

/// Test-only gateway: extends the in-memory demo gateway just to count
/// `reversePiiErasure` invocations so the chip-test can assert that
/// tapping the "Reverse erasure" affordance actually fires the
/// existing reversal seam.
class _RecordingErasureGateway
    extends InMemoryAuditedSupportActionsAdminGateway {
  _RecordingErasureGateway({
    super.auditLogByOperator,
    super.membersByOperator,
    super.clock,
  });

  int reverseCallCount = 0;

  @override
  Future<UserPiiErasureReverseSummary> reversePiiErasure({
    required String operatorId,
    required String targetUserId,
    required String erasureId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reversalReason,
  }) {
    reverseCallCount += 1;
    return super.reversePiiErasure(
      operatorId: operatorId,
      targetUserId: targetUserId,
      erasureId: erasureId,
      idempotencyKey: idempotencyKey,
      actorUserId: actorUserId,
      actorIsForgeAdmin: actorIsForgeAdmin,
      reversalReason: reversalReason,
    );
  }
}
