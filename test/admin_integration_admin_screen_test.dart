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
//   * Role-derived edit state keeps `ff_support` read-only while
//     `super_admin` can rotate keys.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/integration_admin_models.dart';
import 'package:forge_and_flow/admin/screens/integration_admin_screen.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
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

  testWidgets('renders provider-key tiles and vendor-status rows', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    await tester.pumpWidget(
      wrap(Scaffold(body: IntegrationAdminScreen(gateway: gateway))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_integrations_screen')), findsOneWidget);
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
    expect(
      find.byKey(const Key('admin_integrations_status_toast')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_status_quickbooks_time')),
      findsOneWidget,
    );
    expect(find.text('Vendor connector catalog'), findsOneWidget);
    expect(
      find.textContaining('Review global provider health and platform keys'),
      findsOneWidget,
    );
    expect(
      find.textContaining('model, embedding, database, and email providers'),
      findsOneWidget,
    );
    expect(find.textContaining('global vendor API health'), findsOneWidget);
    expect(
      find.textContaining('per-location vendor integrations'),
      findsOneWidget,
    );
    expect(
      find.textContaining('operator edits live on Operator Web'),
      findsWidgets,
    );
    expect(
      find.byKey(const Key('admin_integrations_vendor_group_pos')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_vendor_group_labor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_vendor_group_reservation')),
      findsOneWidget,
    );
    expect(find.text('POS'), findsOneWidget);
    expect(find.text('Labor'), findsOneWidget);
    expect(find.text('Reservation'), findsOneWidget);
    expect(find.text('API pending'), findsWidgets);
    expect(find.text('Documented'), findsNothing);
    expect(
      find.textContaining('Source: Gateway API reachability check'),
      findsWidgets,
    );
    expect(
      find.textContaining('Setup: Vendor setup waits for reachable API access'),
      findsWidgets,
    );
    expect(
      find.text('Stored securely. The full key is hidden after rotation.'),
      findsWidgets,
    );
    expect(find.textContaining('Secure storage ID:'), findsNothing);
    expect(find.textContaining('kms://'), findsNothing);
  });

  testWidgets('renders selected hierarchy context for vendor reachability', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway();
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: IntegrationAdminScreen(
            gateway: gateway,
            hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
              operatorId: 'op-a',
              orgUnitId: 'ou-1',
              operatorName: 'Demo Diner',
              orgUnitName: 'Downtown',
            ),
            scopeLocationIds: const <String>{'loc-a', 'loc-b'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Demo Diner / Downtown'), findsOneWidget);
    // The shared scope notice keeps the platform-key caveat inside its
    // "Section details" expander (collapsed by default). Expand it, then
    // assert the same caveat is present verbatim.
    await tester.tap(
      find.byKey(const Key('admin_integration_scope_notice_details_toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Platform service keys remain shared ecosystem keys'),
      findsOneWidget,
    );
  });

  testWidgets('groups vendor catalog rows using gateway category semantics', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      vendorConnectors: const <VendorConnectorStatus>[
        VendorConnectorStatus(
          id: 'future_labor_vendor',
          displayName: 'Future Labor Vendor',
          statusLabel: 'API reachable',
          detailMessage: 'Live API probe passed.',
          category: VendorCategory.labor,
          apiReachable: true,
          healthSourceLabel: 'Mocked gateway reachability seam',
          unlockLabel: 'Vendor setup unlocked',
        ),
        VendorConnectorStatus(
          id: 'future_reservation_vendor',
          displayName: 'Future Reservation Vendor',
          statusLabel: 'API pending',
          detailMessage: 'Waiting on production credentials.',
          category: VendorCategory.reservation,
          apiReachable: false,
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(Scaffold(body: IntegrationAdminScreen(gateway: gateway))),
    );
    await tester.pumpAndSettle();

    final laborGroup = find.byKey(
      const Key('admin_integrations_vendor_group_labor'),
    );
    final reservationGroup = find.byKey(
      const Key('admin_integrations_vendor_group_reservation'),
    );

    expect(laborGroup, findsOneWidget);
    expect(reservationGroup, findsOneWidget);
    expect(
      find.descendant(
        of: laborGroup,
        matching: find.text('Future Labor Vendor'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: reservationGroup,
        matching: find.text('Future Reservation Vendor'),
      ),
      findsOneWidget,
    );
    expect(find.text('API reachable'), findsOneWidget);
    expect(
      find.textContaining('Mocked gateway reachability seam'),
      findsOneWidget,
    );
    expect(find.textContaining('Vendor setup unlocked'), findsOneWidget);
  });

  testWidgets('rotate flow: confirm → plaintext → reveal modal → close', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      actorUserId: 'demo-super-admin',
      kmsProvider: KmsStubProvider(idGenerator: () => 'fixed-uuid'),
    );
    await tester.pumpWidget(wrap(IntegrationAdminScreen(gateway: gateway)));
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
    await tester.tap(find.byKey(const Key('admin_integrations_confirm_ok')));
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
    final anthropic = bundle.providerKeys.firstWhere(
      (r) => r.keyKind == ProviderKeyKind.anthropic,
    );
    expect(anthropic.maskedValue, equals('sk-a***9999'));
    expect(anthropic.kmsSecretName, equals('kms://stub/fixed-uuid'));
  });

  testWidgets('reveal copy failure is contained without marking copied', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard_denied');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final gateway = InMemoryIntegrationAdminGateway(
      actorUserId: 'demo-super-admin',
      kmsProvider: KmsStubProvider(idGenerator: () => 'fixed-uuid'),
    );
    await tester.pumpWidget(wrap(IntegrationAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_integrations_confirm_ok')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_integrations_rotate_plaintext_field')),
      'sk-ant-newPlaintextSecret9999',
    );
    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_submit_button')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_integrations_reveal_copy_button')),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('admin_integrations_reveal_dialog')),
      findsOneWidget,
    );
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('editingEnabled: false hides rotate buttons + renders banner', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway, editingEnabled: false)),
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

  testWidgets('ff_support source renders integrations in read-only mode', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    final source = DemoAdminAuthSource.signedInAsSupport();
    addTearDown(source.dispose);
    final session = (source.current as AdminAuthAuthenticated).session;
    final canEdit = session.roles.contains('super_admin');

    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway, editingEnabled: canEdit)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_integrations_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_integrations_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
      findsNothing,
    );
  });

  testWidgets('super_admin source renders integrations with rotate buttons', (
    tester,
  ) async {
    final gateway = InMemoryIntegrationAdminGateway(
      seed: <ProviderKeyRow>[seedRow()],
    );
    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);
    final session = (source.current as AdminAuthAuthenticated).session;
    final canEdit = session.roles.contains('super_admin');

    await tester.pumpWidget(
      wrap(IntegrationAdminScreen(gateway: gateway, editingEnabled: canEdit)),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_integrations_screen')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_integrations_readonly_banner')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_integrations_rotate_anthropic')),
      findsOneWidget,
    );
  });

  testWidgets('forced KMS failure renders the action error banner', (
    tester,
  ) async {
    final kms = KmsStubProvider(failNextWrite: true);
    final gateway = InMemoryIntegrationAdminGateway(kmsProvider: kms);
    await tester.pumpWidget(wrap(IntegrationAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_integrations_rotate_azure_db')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_integrations_confirm_ok')));
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
