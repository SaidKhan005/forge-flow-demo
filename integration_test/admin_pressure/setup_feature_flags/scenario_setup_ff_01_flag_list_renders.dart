// integration_test/admin_pressure/setup_feature_flags/scenario_setup_ff_01_flag_list_renders.dart
//
// Lane D — Setup/FF-01: the Launch controls route mounts the screen
// scaffold and resolves to a recognised body state — list, loading,
// load-error, or empty.
//
// Keys come from lib/admin/screens/feature_flags_admin_screen.dart:
//   - admin_feature_flags_screen           (:192)
//   - admin_feature_flags_scroll           (:205 scroll surface)
//   - admin_feature_flags_loading          (:226)
//   - admin_feature_flags_load_error       (:240)
//   - admin_feature_flags_empty            (:247)
//   - admin_feature_flags_list             (:282)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/FF-01: Launch controls mounts scaffold and resolves to list, '
    'loading, error, or empty state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminFeatureFlagsRouteId);

      expect(
        find.byKey(const Key('admin_feature_flags_screen')),
        findsOneWidget,
        reason: 'Launch controls screen scaffold did not mount.',
      );

      // Body resolves to one of the recognised states.
      final hasList = find
          .byKey(const Key('admin_feature_flags_list'))
          .evaluate()
          .isNotEmpty;
      final hasLoading = find
          .byKey(const Key('admin_feature_flags_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_feature_flags_load_error'))
          .evaluate()
          .isNotEmpty;
      final hasEmpty = find
          .byKey(const Key('admin_feature_flags_empty'))
          .evaluate()
          .isNotEmpty;

      expect(
        hasList || hasLoading || hasError || hasEmpty,
        isTrue,
        reason:
            'Launch controls body did not resolve to list, loading, '
            'error, or empty state — the surface is blank.',
      );

      // The danger dialog must NOT be pre-mounted on first render —
      // destructive flag toggles must require operator input.
      expect(
        find.byKey(const Key('admin_feature_flag_danger_dialog')),
        findsNothing,
        reason:
            'Danger dialog was pre-mounted on first render — a '
            'destructive flag-toggle flow fired without operator input.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Launch controls overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
