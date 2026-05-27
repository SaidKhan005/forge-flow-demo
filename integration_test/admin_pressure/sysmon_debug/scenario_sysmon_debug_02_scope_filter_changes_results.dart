// integration_test/admin_pressure/sysmon_debug/scenario_sysmon_debug_02_scope_filter_changes_results.dart
//
// Lane D — Sysmon/Debug-02: the Support logs route exposes the scope
// banner + scope-pickable body, and the filter bar with search /
// type / time-window / status filters. The scope body is the
// per-business / per-location scope panel; the filter bar is the
// secondary control row.
//
// Keys come from lib/admin/screens/debug_console_admin_screen.dart:
//   - admin_debug_console_screen           (:730)
//   - admin_debug_console_scope_banner     (:1102)
//   - admin_debug_console_scope_body       (:1145)
//   - admin_debug_console_filter_bar       (:1210)
//   - admin_debug_console_search_field     (:1218)
//   - admin_debug_console_filter_type      (:1231)
//   - admin_debug_console_filter_window    (:1245)
//   - admin_debug_console_filter_status    (:1265)
//   - admin_debug_console_request_log_body (:993)
//
// This scenario asserts presence of the scope + filter surface. It
// does NOT type into the search field or change a filter — those
// flows are an async-debounced fetch that would need a deterministic
// gateway seed to assert behaviour against.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Sysmon/Debug-02: Support logs exposes scope banner + scope body + '
    'filter bar with search / type / time-window / status controls',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminDebugConsoleRouteId);

      expect(
        find.byKey(const Key('admin_debug_console_screen')),
        findsOneWidget,
        reason: 'Support logs screen scaffold did not mount.',
      );

      // Scope surface present. Either the banner or the body must be
      // in the tree (the banner collapses to body at narrow widths).
      final hasBanner = find
          .byKey(const Key('admin_debug_console_scope_banner'))
          .evaluate()
          .isNotEmpty;
      final hasScopeBody = find
          .byKey(const Key('admin_debug_console_scope_body'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasBanner || hasScopeBody,
        isTrue,
        reason:
            'Scope surface missing — neither the scope banner nor the '
            'scope body is in the tree.',
      );

      // Request-log body container is always present.
      expect(
        find.byKey(const Key('admin_debug_console_request_log_body')),
        findsOneWidget,
        reason: 'Request-log body container missing.',
      );

      // Filter bar with search field and at least one filter chip.
      // Filter bar key is at line 1210; if that's not in the tree, the
      // filter surface regressed.
      final hasFilterBar = find
          .byKey(const Key('admin_debug_console_filter_bar'))
          .evaluate()
          .isNotEmpty;
      final hasSearch = find
          .byKey(const Key('admin_debug_console_search_field'))
          .evaluate()
          .isNotEmpty;
      final hasTypeFilter = find
          .byKey(const Key('admin_debug_console_filter_type'))
          .evaluate()
          .isNotEmpty;
      final hasWindowFilter = find
          .byKey(const Key('admin_debug_console_filter_window'))
          .evaluate()
          .isNotEmpty;
      final hasStatusFilter = find
          .byKey(const Key('admin_debug_console_filter_status'))
          .evaluate()
          .isNotEmpty;

      expect(
        hasFilterBar || hasSearch,
        isTrue,
        reason:
            'Filter surface missing — neither the filter bar nor the '
            'search field is in the tree.',
      );
      // The filter controls layout collapses based on width but at
      // least one chip-style filter should be reachable.
      expect(
        hasTypeFilter || hasWindowFilter || hasStatusFilter,
        isTrue,
        reason:
            'No filter chips (type / window / status) are in the tree '
            '— the filter row regressed.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Support logs overflowed during scope+filter check: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
