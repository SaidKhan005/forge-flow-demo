// Phase 11A.4 — Integration management screen widget tests.
//
// Drives the screen against an `InMemoryIntegrationAdminGateway` so
// the click path runs end-to-end without a backend or live KMS.
// Coverage:
//
//   * Initial render lists provider-key tiles, vendor-connector
//     status rows, and the FX-rate / email-provider status rows.
//   * Rotate flow: confirm → plaintext entry → reveal modal →
//     close → masked grid refresh. Plaintext is only present in the
//     reveal modal; subsequent reads show only the masked display.
//   * Read-only mode (`editingEnabled: false`) hides every Rotate
//     button and renders the read-only banner — exercised by the
//     `ff_support` walkthrough.
//   * Admin shell wired with an `ff_support` source lands on the
//     read-only branch end-to-end.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
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

  ProviderKeyRow seedRow({
    String credentialId = 'cred-anthropic',
    ProviderKeyKind kind = ProviderKeyKind.anthropic,
    String maskedValue = 'sk-a***Q9aB',
    String kmsSecretName = 'kms://stub/seed-anthropic',
  }) {
    return ProviderKeyRow(
      credentialId: credentialId,
      keyKind: kind,
      maskedValue: maskedValue,
      kmsSecretName: kmsSecretName,
      createdBy: 'demo-actor',
      updatedBy: 'demo-actor',
      rotatedAt: DateTime.utc(2026, 4, 1, 14),
    );
  }

  testWidgets('renders provider-key tiles and vendor-status rows',
      (tester) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_integrations_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_provider_anthropic')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_provider_voyage')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_provider_azure_db')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_status_fx_rate')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_status_email')),
      findsOneWidget,
    );
  });

  testWidgets('rotate flow: confirm → plaintext → reveal modal → close',
      (tester) async {
    final gateway = InMemoryIntegrationAdminGateway(
      actorUserId: 'demo-super-admin',
      kmsProvider: KmsStubProvider(idGenerator: () => 'fixed-uuid'),
    );
    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Tap Rotate on Anthropic.
    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
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

    // Rotate dialog renders.
    expect(
      find.byKey(const Key('admin_integrations_rotate_dialog')),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('admin_integrations_rotate_plaintext_field')),
      'sk-ant-newPlaintextSecret9999',
    );
    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_submit_button')),
    );
    await tester.pumpAndSettle();

    // Reveal modal renders the plaintext.
    expect(
      find.byKey(const Key('admin_integrations_reveal_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_reveal_plaintext')),
      findsOneWidget,
    );
    expect(find.text('sk-ant-newPlaintextSecret9999'), findsOneWidget);

    // Close the modal; masked grid refresh shows the new masked
    // display, NOT the plaintext.
    await tester.tap(
      find.byKey(const Key('admin_integrations_reveal_close_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_integrations_reveal_dialog')),
      findsNothing,
    );
    expect(find.text('sk-ant-newPlaintextSecret9999'), findsNothing);

    // The masked tile now shows the new masked display.
    final bundle = await gateway.list();
    final anthropic = bundle.providerKeys
        .firstWhere((r) => r.keyKind == ProviderKeyKind.anthropic);
    expect(anthropic.maskedValue, equals('sk-a***9999'));
    expect(anthropic.kmsSecretName, equals('kms://stub/fixed-uuid'));
  });

  testWidgets('editingEnabled: false hides rotate buttons + renders banner',
      (tester) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
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
      find.byKey(const Key('admin_integrations_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_voyage')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_azure_db')),
      findsNothing,
    );
  });

  testWidgets(
      'admin shell with ff_support source renders integrations in read-only mode',
      (tester) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    final source = DemoAdminAuthSource(
      initial: const AdminAuthAuthenticated(
        AdminAuthSession(
          uid: 'demo-ff-support',
          email: 'support@forgeflow.test',
          displayName: 'Demo F&F Support',
          roles: <String>['ff_support'],
        ),
      ),
    );
    addTearDown(source.dispose);
    await tester.pumpWidget(
      AdminConsoleServicesScope(
        integrationGateway: gateway,
        adminAuthSource: source,
        child: AdminConsoleApp(authSource: source),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_nav_item_integrations')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_integrations_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
      findsNothing,
    );
  });

  testWidgets(
      'admin shell with super_admin source renders integrations with rotate buttons',
      (tester) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    await tester.pumpWidget(
      AdminConsoleServicesScope(
        integrationGateway: gateway,
        adminAuthSource: source,
        child: AdminConsoleApp(authSource: source),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_nav_item_integrations')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_integrations_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_readonly_banner')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
      findsOneWidget,
    );
  });

  testWidgets('forced KMS failure renders the action error banner',
      (tester) async {
    final kms = KmsStubProvider(failNextWrite: true);
    final gateway = InMemoryIntegrationAdminGateway(kmsProvider: kms);
    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_azure_db')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_integrations_confirm_ok')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_integrations_rotate_plaintext_field')),
      'azure-superuser-Pa55word!',
    );
    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_submit_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_integrations_action_error')),
      findsOneWidget,
    );
    // No reveal modal on failure.
    expect(
      find.byKey(const Key('admin_integrations_reveal_dialog')),
      findsNothing,
    );
  });
}
