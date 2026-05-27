// integration_test/admin_pressure/setup_default_roles/scenario_setup_dr_01_versions_list_renders.dart
//
// Lane D — Setup/DR-01: the Default roles route mounts the screen
// scaffold and the three primary panels — current, draft, history —
// each in one of their recognised states.
//
// Keys come from lib/admin/screens/default_role_catalog_admin_screen.dart:
//   - admin_default_role_catalog_screen          (:377)
//   - admin_default_role_catalog_loading         (:404)
//   - admin_default_role_catalog_load_error      (:418)
//   - admin_default_role_catalog_current_panel   (:520)
//   - admin_default_role_catalog_current_empty   (:509)
//   - admin_default_role_catalog_draft_panel     (:635)
//   - admin_default_role_catalog_draft_empty     (:646)
//   - admin_default_role_catalog_history_panel   (:1511)
//   - admin_default_role_catalog_history_empty   (:1502)
//   - admin_default_role_catalog_publish_button  (:680)
//
// The publish flow is the destructive surface — locked by DR-02.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/DR-01: Default roles renders scaffold with current, draft, '
    'and history panels (or their empty/loading siblings)',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminDefaultRoleCatalogRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_default_role_catalog_screen')),
        findsOneWidget,
        reason: 'Default roles screen scaffold did not mount.',
      );

      // Screen must resolve to one of three top-level states: loading,
      // load-error, or the three-panel ready layout. Reject blank.
      final hasLoading = find
          .byKey(const Key('admin_default_role_catalog_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_default_role_catalog_load_error'))
          .evaluate()
          .isNotEmpty;
      final hasCurrentPanel = find
          .byKey(const Key('admin_default_role_catalog_current_panel'))
          .evaluate()
          .isNotEmpty;
      final hasCurrentEmpty = find
          .byKey(const Key('admin_default_role_catalog_current_empty'))
          .evaluate()
          .isNotEmpty;

      expect(
        hasLoading || hasError || hasCurrentPanel || hasCurrentEmpty,
        isTrue,
        reason:
            'Default roles did not resolve to a recognised state '
            '(loading / load-error / current-panel / current-empty). The '
            'surface is blank.',
      );

      // If the loaded layout is reachable, the draft + history panels
      // must each resolve to either their populated or empty state.
      if (hasCurrentPanel || hasCurrentEmpty) {
        final hasDraftPanel = find
            .byKey(const Key('admin_default_role_catalog_draft_panel'))
            .evaluate()
            .isNotEmpty;
        final hasDraftEmpty = find
            .byKey(const Key('admin_default_role_catalog_draft_empty'))
            .evaluate()
            .isNotEmpty;
        expect(
          hasDraftPanel || hasDraftEmpty,
          isTrue,
          reason:
              'Draft panel did not resolve to either its populated or '
              'empty state.',
        );

        final hasHistoryPanel = find
            .byKey(const Key('admin_default_role_catalog_history_panel'))
            .evaluate()
            .isNotEmpty;
        final hasHistoryEmpty = find
            .byKey(const Key('admin_default_role_catalog_history_empty'))
            .evaluate()
            .isNotEmpty;
        expect(
          hasHistoryPanel || hasHistoryEmpty,
          isTrue,
          reason:
              'History panel did not resolve to either its populated or '
              'empty state.',
        );

        // Publish button must be in the draft panel.
        expect(
          find.byKey(const Key('admin_default_role_catalog_publish_button')),
          findsAtLeast(1),
          reason: 'Publish button missing from the Default roles draft panel.',
        );
      }

      // The publish dialog must NOT be pre-mounted.
      expect(
        find.byKey(const Key('admin_default_role_catalog_publish_dialog')),
        findsNothing,
        reason:
            'Publish dialog was pre-mounted on first render — a '
            'destructive publish flow fired without operator input.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Default roles overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
