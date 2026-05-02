// Phase 11A.4 — Integration management screen widget tests for the
// new `gemini` provider lane.
//
// Mirrors `admin_integration_admin_screen_test.dart`, substituting the
// `gemini` enum variant for `anthropic`. Verifies that the new
// `ProviderKeyKind.gemini` value flows automatically into:
//
//   * The provider-key tile (`admin_integrations_provider_gemini`).
//   * The masked credential text (`admin_integrations_masked_gemini`).
//   * The Rotate button (`admin_integrations_rotate_gemini`).
//   * The shared rotate flow (confirm → plaintext entry → reveal modal
//     → close → masked grid refresh) on the existing
//     `InMemoryIntegrationAdminGateway`, which accepts arbitrary
//     `ProviderKeyKind` values without per-kind branching.
//
// The screen iterates `ProviderKeyKind.values` and the gateway
// dispatches by `wireName`, so adding a new enum variant should be
// fully covered by these structural / click-path checks.
//
// This test does NOT modify `admin_integration_admin_screen_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/integration_admin_models.dart';
import 'package:forge_and_flow/admin/screens/integration_admin_screen.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: child,
      );

  group('Integration admin screen — Gemini key', () {
    testWidgets('renders gemini tile with display name + no-credential note '
        'when the gateway is empty', (tester) async {
      final gateway = InMemoryIntegrationAdminGateway();
      await tester.pumpWidget(
        wrap(IntegrationAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      // The lane tile and masked-display node both exist for gemini.
      expect(
        find.byKey(const Key('admin_integrations_provider_gemini')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_integrations_masked_gemini')),
        findsOneWidget,
      );

      // Display name comes from `ProviderKeyKind.gemini.displayName`.
      expect(find.text('Gemini API'), findsOneWidget);

      // No active credential → the empty-state copy is shown.
      expect(
        find.text('No active credential. Rotate to seed the lane.'),
        findsAtLeastNWidgets(1),
      );
    });

    testWidgets('rotate button is visible when editing is enabled',
        (tester) async {
      final gateway = InMemoryIntegrationAdminGateway();
      await tester.pumpWidget(
        wrap(IntegrationAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_integrations_rotate_gemini')),
        findsOneWidget,
      );
    });

    testWidgets('rotate button is hidden when editing is disabled',
        (tester) async {
      final gateway = InMemoryIntegrationAdminGateway();
      await tester.pumpWidget(
        wrap(
          IntegrationAdminScreen(
            gateway: gateway,
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_integrations_rotate_gemini')),
        findsNothing,
      );
    });

    testWidgets('rotate flow seeds a new gemini row on the gateway',
        (tester) async {
      final gateway = InMemoryIntegrationAdminGateway(
        actorUserId: 'demo-super-admin',
        kmsProvider: KmsStubProvider(idGenerator: () => 'fixed-uuid'),
      );
      await tester.pumpWidget(
        wrap(IntegrationAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      // Tap Rotate on Gemini.
      await tester.tap(
        find.byKey(const Key('admin_integrations_rotate_gemini')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('admin_integrations_confirm_dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('admin_integrations_confirm_ok')),
      );
      await tester.pumpAndSettle();

      // Plaintext entry dialog renders.
      expect(
        find.byKey(const Key('admin_integrations_rotate_dialog')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('admin_integrations_rotate_plaintext_field')),
        'AIzaSy-newGeminiPlaintextSecret9999',
      );
      await tester.tap(
        find.byKey(const Key('admin_integrations_rotate_submit_button')),
      );
      await tester.pumpAndSettle();

      // Reveal modal renders the plaintext exactly once.
      expect(
        find.byKey(const Key('admin_integrations_reveal_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_integrations_reveal_plaintext')),
        findsOneWidget,
      );
      expect(
        find.text('AIzaSy-newGeminiPlaintextSecret9999'),
        findsOneWidget,
      );

      // Close the reveal modal and confirm plaintext is gone.
      await tester.tap(
        find.byKey(const Key('admin_integrations_reveal_close_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_integrations_reveal_dialog')),
        findsNothing,
      );
      expect(
        find.text('AIzaSy-newGeminiPlaintextSecret9999'),
        findsNothing,
      );

      // Gateway now exposes a masked-only gemini row.
      final bundle = await gateway.list();
      final geminiRows = bundle.providerKeys
          .where((r) => r.keyKind == ProviderKeyKind.gemini)
          .toList(growable: false);
      expect(geminiRows, hasLength(1));
      final gemini = geminiRows.single;
      expect(gemini.maskedValue, isNotEmpty);
      expect(gemini.maskedValue, isNot(contains('AIzaSy-newGeminiPlaintext')));
      expect(gemini.kmsSecretName, equals('kms://stub/fixed-uuid'));
    });
  });
}
