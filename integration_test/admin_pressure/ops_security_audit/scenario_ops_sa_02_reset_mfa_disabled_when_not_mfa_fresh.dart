// integration_test/admin_pressure/ops_security_audit/scenario_ops_sa_02_reset_mfa_disabled_when_not_mfa_fresh.dart
//
// Lane B — Ops/SA-02 (regression): in share-preview mode the
// Audit log surface mounts the audit log but the destructive
// support-action panel (reset MFA, etc.) is NOT exposed. A
// share-preview session is never "MFA-fresh" because there is no
// real auth; the destructive affordances must fail closed.
//
// Keys come from lib/admin/screens/audited_support_actions_admin_screen.dart:
//   - admin_audited_support_actions_screen (:624)
//   - admin_asa_audit_log_list             (:1051)
//   - admin_asa_body                        (:679)
//   - admin_asa_filters                     (:794)
//   - admin_asa_audit_log_forbidden         (:620, when role denied)
//   - admin_asa_audit_log_loading           (:1096)
//   - admin_asa_audit_log_error             (:1121)
//
// This scenario locks in the negative contract: NO support-action
// panel and NO reason dialog are rendered when the session is not
// MFA-fresh. The 2026-05-22 manual pressure test confirmed the
// admin shell hides the action panel on share-preview boot; this
// regression prevents a future flag from silently exposing reset-MFA
// without the freshness gate.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/SA-02: Audit log mounts but support-action panel + reason '
    'dialog stay hidden when the session is not MFA-fresh',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerBusinessScope(tester);
      await tapAdminClusterRoute(tester, kAdminAuditedSupportActionsRouteId);

      // The surface either renders the audit log (super-admin reach)
      // or the forbidden placeholder (role-denied). Both are valid
      // outcomes for a share-preview session; at least one must mount.
      final hasScreen = find
          .byKey(const Key('admin_audited_support_actions_screen'))
          .evaluate()
          .isNotEmpty;
      final hasForbidden = find
          .byKey(const Key('admin_asa_audit_log_forbidden'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasScreen || hasForbidden,
        isTrue,
        reason:
            'Audited support actions surface mounted neither the screen '
            'scaffold nor the forbidden placeholder — the route is broken.',
      );

      // When the screen is reachable, the audit log list (or its
      // loading/error sibling) must be the body. The body must NOT be
      // blank.
      if (hasScreen) {
        final hasList = find
            .byKey(const Key('admin_asa_audit_log_list'))
            .evaluate()
            .isNotEmpty;
        final hasLoading = find
            .byKey(const Key('admin_asa_audit_log_loading'))
            .evaluate()
            .isNotEmpty;
        final hasError = find
            .byKey(const Key('admin_asa_audit_log_error'))
            .evaluate()
            .isNotEmpty;
        final hasBody = find
            .byKey(const Key('admin_asa_body'))
            .evaluate()
            .isNotEmpty;
        expect(
          hasList || hasLoading || hasError || hasBody,
          isTrue,
          reason:
              'Audited support actions screen mounted with no audit-log '
              'list / loading / error state — the body is blank.',
        );
      }

      // Regression contract: the destructive support-action panel and
      // reason dialog MUST stay hidden. Share-preview is never
      // MFA-fresh; exposing reset-MFA here would silently bypass the
      // freshness gate.
      expect(
        find.byKey(const Key('admin_asa_actions_panel')),
        findsNothing,
        reason:
            'Support action panel (admin_asa_actions_panel) was visible '
            'in share-preview — destructive reset-MFA affordances are '
            'exposed without an MFA-fresh session.',
      );
      expect(
        find.byKey(const Key('admin_asa_reason_dialog')),
        findsNothing,
        reason:
            'Reason dialog (admin_asa_reason_dialog) was pre-mounted on '
            'first render — destructive flow surfaced without operator '
            'input.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Audited support actions overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
