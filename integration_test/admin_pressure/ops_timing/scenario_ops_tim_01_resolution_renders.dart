// integration_test/admin_pressure/ops_timing/scenario_ops_tim_01_resolution_renders.dart
//
// Lane B — Ops/Tim-01: the Timing Setup route (per-business cluster)
// mounts the editor and exposes the scope/effective section, the
// service-period editor, the timezone control, and either the Save
// button or the read-only banner.
//
// Keys come from lib/admin/screens/admin_timing_setup_screen.dart:
//   - admin_timing_setup_screen           (:653)
//   - admin_timing_setup_screen_body      (:654 scrollKey)
//   - admin_timing_editor_periods         (:714)
//   - admin_timing_editor_effective_pick  (:917)
//   - admin_timing_editor_business_day_start (:944)
//   - admin_timing_editor_week_start      (:988)
//   - admin_timing_editor_timezone_dropdown  (:1046)
//   - admin_timing_editor_save            (:737)
//   - admin_timing_readonly_banner        (:813)
//   - admin_timing_editor_scope_card      (:903)
//
// The Service Periods editor is the canonical source of restaurant-
// local timing (see Time Guardrails in CLAUDE.md). This scenario locks
// in that the editor surface mounts and exposes the required controls;
// it does NOT exercise a save (which is a destructive op that wedges
// the gesture loop and is gated by the reason dialog).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Ops/Tim-01: Timing Setup route renders editor with scope card, '
    'service-period editor, timezone control, and a save-or-readonly state',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await selectDemoDinerTorontoLocationScope(tester);
      await tapAdminClusterRoute(tester, kAdminTimingSetupRouteId);

      // Screen scaffold mounted.
      expect(
        find.byKey(const Key('admin_timing_setup_screen')),
        findsOneWidget,
        reason: 'Timing Setup screen scaffold did not mount.',
      );
      expect(
        find.byKey(const Key('admin_timing_setup_screen_body')),
        findsOneWidget,
        reason: 'Timing Setup body scroll surface missing.',
      );

      // Scope + effective date card.
      expect(
        find.byKey(const Key('admin_timing_editor_scope_card')),
        findsOneWidget,
        reason:
            'Scope card missing from the Timing Setup editor — the '
            'effective-date picker has no anchor.',
      );

      // Service-period editor.
      expect(
        find.byKey(const Key('admin_timing_editor_periods')),
        findsOneWidget,
        reason:
            'Service-period editor missing — the canonical timing source '
            'is not rendered.',
      );

      // Timezone dropdown must be in the tree.
      expect(
        find.byKey(const Key('admin_timing_editor_timezone_dropdown')),
        findsOneWidget,
        reason: 'Timezone dropdown missing from the Timing Setup editor.',
      );

      // The editor must resolve to either the Save button (writeable
      // super-admin) or the read-only banner (lower role). Locks in
      // that the destructive surface fails closed.
      final hasSave = find
          .byKey(const Key('admin_timing_editor_save'))
          .evaluate()
          .isNotEmpty;
      final hasReadonly = find
          .byKey(const Key('admin_timing_readonly_banner'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasSave || hasReadonly,
        isTrue,
        reason:
            'Timing Setup editor resolved to neither a Save button nor a '
            'read-only banner — the destructive-affordance gating broke.',
      );

      // Reason dialog must NOT be pre-mounted on first render (would
      // be a destructive-action firing without operator input).
      expect(
        find.byKey(const Key('admin_timing_reason_dialog')),
        findsNothing,
        reason:
            'The timing reason dialog was pre-mounted on first render — '
            'a destructive flow surfaced without operator input.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Timing Setup overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
