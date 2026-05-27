// integration_test/admin_pressure/sysmon_debug/scenario_sysmon_debug_01_log_list_renders.dart
//
// Lane D — Sysmon/Debug-01: the Support logs route mounts the
// debug-console scaffold, surfaces the request-log body container,
// and either renders the request-log list, the loading indicator,
// the load-error placeholder, or the empty state.
//
// Keys come from lib/admin/screens/debug_console_admin_screen.dart:
//   - admin_debug_console_screen           (:730)
//   - admin_debug_console_request_log_body (:993)
//   - admin_debug_console_loading          (:1028)
//   - admin_debug_console_load_error       (:1021)
//   - admin_debug_console_empty_state      (:1977)
//   - admin_debug_console_refresh_button   (:827)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Sysmon/Debug-01: Support logs mounts scaffold + request-log body '
    'and resolves to list, loading, error, or empty-state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminDebugConsoleRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_debug_console_screen')),
        findsOneWidget,
        reason: 'Support logs screen scaffold did not mount.',
      );

      // Request-log body container mounted.
      expect(
        find.byKey(const Key('admin_debug_console_request_log_body')),
        findsOneWidget,
        reason:
            'Request-log body container missing — the surface mounted '
            'with no log area.',
      );

      // Refresh button reachable (so the operator can re-pull logs).
      expect(
        find.byKey(const Key('admin_debug_console_refresh_button')),
        findsAtLeast(1),
        reason:
            'Refresh button missing from Support logs header — operator '
            'cannot re-pull logs.',
      );

      // Body resolves to one of the recognised states. Reject blank.
      final hasLoading = find
          .byKey(const Key('admin_debug_console_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_debug_console_load_error'))
          .evaluate()
          .isNotEmpty;
      final hasEmpty = find
          .byKey(const Key('admin_debug_console_empty_state'))
          .evaluate()
          .isNotEmpty;
      // Any request-log row begins with 'admin_debug_console_row_'.
      final hasRow = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith(
                  'admin_debug_console_row_',
                ),
      ).evaluate().isNotEmpty;

      expect(
        hasLoading || hasError || hasEmpty || hasRow,
        isTrue,
        reason:
            'Support logs body did not resolve to loading, error, empty, '
            'or a request-log row — the surface is blank.',
      );

      // Header title is the human label.
      expect(
        find.text('Support logs'),
        findsAtLeast(1),
        reason: 'Support logs header label missing.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Support logs overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
