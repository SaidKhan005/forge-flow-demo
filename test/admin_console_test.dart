// Phase 9.9 - Admin console kernel tests:
//   * AuditLogCsvExport (RFC 4180 encoding + mandatory audit event)
//   * RolePermissionMatrixController (toggle, diff, revert)
//   * MfaPolicyEditorState (per-operator overrides + edit policy)

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/mfa_policy.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/admin/audit_log_csv_export.dart';
import 'package:forge_and_flow/services/admin/mfa_policy_editor_controller.dart';
import 'package:forge_and_flow/services/admin/role_permission_matrix_controller.dart';

void main() {
  group('AuditLogCsvExport', () {
    test('emits a header row + one data row per input', () {
      final result = AuditLogCsvExport.export(
        rows: <AuditLogRow>[
          AuditLogRow(
            eventId: 'e-1',
            occurredAt: DateTime.utc(2026, 4, 26, 12),
            eventType: 'auth.login_success',
            actorUserId: 'u-1',
            operatorId: 'op-a',
            ip: '203.0.113.5',
            userAgent: 'curl/8.0',
          ),
          AuditLogRow(
            eventId: 'e-2',
            occurredAt: DateTime.utc(2026, 4, 26, 13),
            eventType: 'auth.login_failed',
            targetUserId: 'u-2',
            operatorId: 'op-a',
          ),
        ],
        actorUserId: 'admin-x',
        actorOperatorId: null,
        filters: const AuditLogExportFilters(operatorId: 'op-a'),
        now: DateTime.utc(2026, 4, 26, 14),
      );
      final lines = result.csvBody.split('\n');
      expect(lines.first, contains('event_id'));
      expect(lines.first, contains('occurred_at'));
      expect(lines.first, contains('payload'));
      expect(result.rowCount, equals(2));
    });

    test('quotes fields containing commas / quotes / newlines (RFC 4180)',
        () {
      final result = AuditLogCsvExport.export(
        rows: <AuditLogRow>[
          AuditLogRow(
            eventId: 'e,1',
            occurredAt: DateTime.utc(2026, 4, 26, 12),
            eventType: 'auth.login_success',
            userAgent: 'Mozilla "5.0"',
            payload: const <String, Object?>{
              'note': 'first\nsecond',
            },
          ),
        ],
        actorUserId: 'admin-x',
        actorOperatorId: null,
        filters: const AuditLogExportFilters(),
        now: DateTime.utc(2026, 4, 26, 14),
      );
      // event_id "e,1" must be quoted; user_agent must escape the
      // embedded double-quotes as "" per RFC 4180.
      expect(result.csvBody, contains('"e,1"'));
      expect(result.csvBody, contains('"Mozilla ""5.0"""'));
      // Payload JSON contains a newline + quotes -> quoted field with
      // every embedded double-quote doubled per RFC 4180.
      expect(
        result.csvBody.contains('"{""note"":""first\nsecond""}"'),
        isTrue,
      );
    });

    test('every export emits an admin.audit_log.export audit event '
        'capturing actor + filters + row count', () {
      final result = AuditLogCsvExport.export(
        rows: const <AuditLogRow>[],
        actorUserId: 'admin-x',
        actorOperatorId: 'op-y',
        filters: AuditLogExportFilters(
          operatorId: 'op-a',
          actorUserId: 'u-1',
          eventType: 'auth.login_success',
        ),
        now: DateTime.utc(2026, 4, 26, 14),
        requestId: 'req-42',
      );
      final ev = result.exportEvent;
      expect(ev.eventType, equals('admin.audit_log.export'));
      expect(ev.actorUserId, equals('admin-x'));
      expect(ev.operatorId, equals('op-y'));
      expect(ev.requestId, equals('req-42'));
      expect(ev.payload['row_count'], equals(0));
      final filters = ev.payload['filters']! as Map<String, Object?>;
      expect(filters['operator_id'], equals('op-a'));
      expect(filters['actor_user_id'], equals('u-1'));
      expect(filters['event_type'], equals('auth.login_success'));
    });

    test('payload JSON column is canonical (sorted keys, no whitespace)',
        () {
      final result = AuditLogCsvExport.export(
        rows: <AuditLogRow>[
          AuditLogRow(
            eventId: 'e-1',
            occurredAt: DateTime.utc(2026, 4, 26),
            eventType: 'admin.users.deactivate',
            payload: const <String, Object?>{
              'reason': 'soft-delete',
              'count': 1,
              'flags': <bool>[true, false],
            },
          ),
        ],
        actorUserId: 'admin-x',
        actorOperatorId: null,
        filters: const AuditLogExportFilters(),
        now: DateTime.utc(2026, 4, 26),
      );
      // Sorted keys: count, flags, reason. No whitespace inside the
      // brace. The CSV cell wraps the JSON in quotes (JSON contains
      // commas) and doubles the embedded double-quotes per RFC 4180.
      expect(
        result.csvBody,
        contains(
          '"{""count"":1,""flags"":[true,false],""reason"":""soft-delete""}"',
        ),
      );
    });
  });

  group('RolePermissionMatrixController', () {
    Map<String, Map<String, PermissionEffect>> baseline() {
      return <String, Map<String, PermissionEffect>>{
        'role-staff': <String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
        },
        'role-manager': <String, PermissionEffect>{
          'forgeflow.shift.view': PermissionEffect.allow,
          'forgeflow.shift.edit': PermissionEffect.allow,
        },
      };
    }

    test('initial state matches baseline (no diff)', () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      expect(ctrl.isDirty, isFalse);
      expect(ctrl.diff(), isEmpty);
      expect(
        ctrl.cell('role-staff', 'forgeflow.shift.view'),
        equals(MatrixCellState.allow),
      );
      expect(
        ctrl.cell('role-staff', 'forgeflow.shift.edit'),
        equals(MatrixCellState.inherit),
      );
    });

    test('toggleCell cycles inherit -> allow -> deny -> inherit', () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      const role = 'role-staff';
      const key = 'forgeflow.shift.edit';
      expect(ctrl.cell(role, key), equals(MatrixCellState.inherit));
      ctrl.toggleCell(roleId: role, permissionKey: key);
      expect(ctrl.cell(role, key), equals(MatrixCellState.allow));
      ctrl.toggleCell(roleId: role, permissionKey: key);
      expect(ctrl.cell(role, key), equals(MatrixCellState.deny));
      ctrl.toggleCell(roleId: role, permissionKey: key);
      expect(ctrl.cell(role, key), equals(MatrixCellState.inherit));
    });

    test('setCell upserts an explicit effect', () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      ctrl.setCell(
        roleId: 'role-staff',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.deny,
      );
      expect(
        ctrl.cell('role-staff', 'forgeflow.shift.edit'),
        equals(MatrixCellState.deny),
      );
    });

    test('diff captures every cell that changed and ignores unchanged ones',
        () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      ctrl.setCell(
        roleId: 'role-staff',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.allow,
      );
      ctrl.setCell(
        roleId: 'role-manager',
        permissionKey: 'forgeflow.shift.view',
        state: MatrixCellState.deny,
      );
      // Touch + revert one cell — must NOT appear in diff.
      ctrl.setCell(
        roleId: 'role-manager',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.deny,
      );
      ctrl.setCell(
        roleId: 'role-manager',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.allow,
      );
      final changes = ctrl.diff();
      expect(changes, hasLength(2));
      // Ordering: by roleId then permissionKey.
      expect(changes[0].roleId, equals('role-manager'));
      expect(changes[0].permissionKey, equals('forgeflow.shift.view'));
      expect(changes[0].from, equals(MatrixCellState.allow));
      expect(changes[0].to, equals(MatrixCellState.deny));
      expect(changes[1].roleId, equals('role-staff'));
      expect(changes[1].permissionKey, equals('forgeflow.shift.edit'));
      expect(changes[1].from, equals(MatrixCellState.inherit));
      expect(changes[1].to, equals(MatrixCellState.allow));
    });

    test('revertAll restores baseline + clears dirty flag', () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      ctrl.setCell(
        roleId: 'role-staff',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.deny,
      );
      expect(ctrl.isDirty, isTrue);
      ctrl.revertAll();
      expect(ctrl.isDirty, isFalse);
      expect(ctrl.diff(), isEmpty);
    });

    test('diffPayload shape matches role_audit_log.change_payload contract',
        () {
      final ctrl = RolePermissionMatrixController(baseline: baseline());
      ctrl.setCell(
        roleId: 'role-staff',
        permissionKey: 'forgeflow.shift.edit',
        state: MatrixCellState.deny,
      );
      final payload = ctrl.diffPayload();
      expect(payload['change_count'], equals(1));
      final entry = (payload['changes']! as List).first as Map<String, Object?>;
      expect(entry['role_id'], equals('role-staff'));
      expect(entry['permission_key'], equals('forgeflow.shift.edit'));
      expect(entry['from'], equals('inherit'));
      expect(entry['to'], equals('deny'));
    });
  });

  group('MfaPolicyEditorState', () {
    test('staff MFA defaults to false at every tier unless overridden', () {
      final state = MfaPolicyEditorState(
        staffOverrideByOperatorId: const <String, bool>{'op-a': false},
      );
      expect(
        state.effectiveStaffMfaRequired(
          operatorId: 'op-a',
          tier: OperatorSubscriptionTier.premium,
        ),
        isFalse,
      );
      expect(
        state.effectiveStaffMfaRequired(
          operatorId: 'op-a',
          tier: OperatorSubscriptionTier.enterprise,
        ),
        isFalse,
      );
    });

    test('override flips staff MFA to true for any tier', () {
      final state = MfaPolicyEditorState(
        staffOverrideByOperatorId: const <String, bool>{},
      );
      expect(
        state.effectiveStaffMfaRequired(
          operatorId: 'op-a',
          tier: OperatorSubscriptionTier.pilot,
        ),
        isFalse,
      );
      state.setStaffOverride(operatorId: 'op-a', requireStaffMfa: true);
      expect(
        state.effectiveStaffMfaRequired(
          operatorId: 'op-a',
          tier: OperatorSubscriptionTier.premium,
        ),
        isTrue,
      );
    });

    test('isDirty + diff capture only changed entries', () {
      final state = MfaPolicyEditorState(
        staffOverrideByOperatorId: const <String, bool>{'op-a': false},
      );
      expect(state.isDirty, isFalse);
      state.setStaffOverride(operatorId: 'op-a', requireStaffMfa: false);
      expect(state.isDirty, isFalse,
          reason: 'no-op set must not flip the dirty flag');
      state.setStaffOverride(operatorId: 'op-a', requireStaffMfa: true);
      expect(state.isDirty, isTrue);
      state.setStaffOverride(operatorId: 'op-b', requireStaffMfa: true);
      final payload = state.diffPayload();
      expect(payload['change_count'], equals(2));
      final ordered =
          (payload['changes']! as List).cast<Map<String, Object?>>();
      // op-a then op-b alphabetically.
      expect(ordered[0]['operator_id'], equals('op-a'));
      expect(ordered[0]['from'], equals(false));
      expect(ordered[0]['to'], equals(true));
      expect(ordered[1]['operator_id'], equals('op-b'));
    });

    test('clearStaffOverride removes the entry (back to default)', () {
      final state = MfaPolicyEditorState(
        staffOverrideByOperatorId: const <String, bool>{'op-a': true},
      );
      state.clearStaffOverride('op-a');
      expect(
        state.effectiveStaffMfaRequired(
          operatorId: 'op-a',
          tier: OperatorSubscriptionTier.starter,
        ),
        isFalse,
      );
      // Diff captures: from true to false.
      final diff = state.diff();
      expect(diff.containsKey('op-a'), isTrue);
    });
  });

  group('MfaPolicyEditorPolicy', () {
    test('super_admin allowed; everyone else denied', () {
      expect(
        MfaPolicyEditorPolicy.actorMayEdit(const <String>['super_admin']),
        isTrue,
      );
      expect(
        MfaPolicyEditorPolicy.actorMayEdit(const <String>['ff_support']),
        isFalse,
      );
      expect(
        MfaPolicyEditorPolicy.actorMayEdit(const <String>['operator_owner']),
        isFalse,
      );
      expect(
        MfaPolicyEditorPolicy.actorMayEdit(const <String>[]),
        isFalse,
      );
    });
  });
}
