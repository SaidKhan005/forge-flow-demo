// integration_test/admin_pressure/setup_integrations/scenario_setup_int_01_provider_tiles_render.dart
//
// Lane D — Setup/Int-01: the Connected services route mounts the
// integrations screen and exposes provider tiles for the two seeded
// providers (anthropic, sendgrid), with the destructive rotate +
// reveal + confirm dialogs NOT pre-mounted.
//
// Keys come from lib/admin/screens/integration_admin_screen.dart:
//   - admin_integrations_screen                   (:214)
//   - admin_integrations_loading                  (:250)
//   - admin_integrations_load_error               (:263)
//   - admin_integrations_provider_<wireName>      (:390)
//   - admin_integrations_rotate_dialog            (:815)
//   - admin_integrations_reveal_dialog            (:933)
//   - admin_integrations_confirm_dialog           (:1016)
//
// This locks the destructive-flow guard: rotate / reveal / confirm
// dialogs surface only when the operator initiates them, never on
// first render of the screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'Setup/Int-01: Connected services renders provider tiles and the '
    'rotate / reveal / confirm dialogs are NOT pre-mounted',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminIntegrationsRouteId);

      // Screen mounted.
      expect(
        find.byKey(const Key('admin_integrations_screen')),
        findsOneWidget,
        reason: 'Connected services screen scaffold did not mount.',
      );

      // Body resolves to provider tiles or loading or error. Reject
      // blank surface.
      final hasAnthropicTile = find
          .byKey(const Key('admin_integrations_provider_anthropic'))
          .evaluate()
          .isNotEmpty;
      final hasSendgridTile = find
          .byKey(const Key('admin_integrations_provider_sendgrid'))
          .evaluate()
          .isNotEmpty;
      final hasLoading = find
          .byKey(const Key('admin_integrations_loading'))
          .evaluate()
          .isNotEmpty;
      final hasError = find
          .byKey(const Key('admin_integrations_load_error'))
          .evaluate()
          .isNotEmpty;
      expect(
        hasAnthropicTile || hasSendgridTile || hasLoading || hasError,
        isTrue,
        reason:
            'Connected services body did not resolve to a recognised '
            'state (provider tile / loading / error). The surface is '
            'blank.',
      );

      // If the tiles loaded, the two seeded providers should be there.
      if (hasAnthropicTile || hasSendgridTile) {
        expect(
          hasAnthropicTile && hasSendgridTile,
          isTrue,
          reason:
              'One of the seeded providers (anthropic, sendgrid) is '
              'missing — the integration_admin_screen seed regressed.',
        );
      }

      // Destructive dialogs MUST NOT be pre-mounted on first render.
      expect(
        find.byKey(const Key('admin_integrations_rotate_dialog')),
        findsNothing,
        reason:
            'Rotate dialog was pre-mounted on first render — a '
            'destructive key-rotation flow fired without operator input.',
      );
      expect(
        find.byKey(const Key('admin_integrations_reveal_dialog')),
        findsNothing,
        reason:
            'Reveal dialog was pre-mounted on first render — a key '
            'plaintext-reveal fired without operator input.',
      );
      expect(
        find.byKey(const Key('admin_integrations_confirm_dialog')),
        findsNothing,
        reason:
            'Generic confirm dialog was pre-mounted on first render — '
            'a destructive flow surfaced without operator input.',
      );

      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Connected services overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
