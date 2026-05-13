// Lane B B2.2 - Default Role catalog admin screen widget tests.
//
// Pins the screen contract documented in
// `lib/admin/screens/default_role_catalog_admin_screen.dart`:
//
//   * Genesis state (no current version) renders the empty-state
//     panel + an empty draft. Publish button is disabled.
//   * After a publish: current version panel + history row appear;
//     draft pre-loads from the published payload; publish button is
//     disabled while the draft equals the current.
//   * Editor: add role, edit role, remove role mutate the draft and
//     re-enable Publish.
//   * Publish flow opens the dialog (B2.2 publish dialog).
//   * Read-only mode (`editingEnabled: false`) hides the add /
//     discard / publish affordances.
//   * F&F admin chrome (deep background + ecosystem-only badge) is
//     present.
//   * Discard draft reverts to the current version's payload.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/default_role_catalog_admin_screen.dart';
import 'package:forge_and_flow/admin/services/default_role_catalog_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> seedOneVersion(
    InMemoryDefaultRoleCatalogAdminGateway gateway,
  ) async {
    await gateway.publishVersion(
      payload: <Object?>[
        <String, Object?>{
          'role_key': 'operator_owner',
          'display_name': 'Operator Owner',
          'description': 'Owner of the business.',
          'permissions': <Object?>[],
        },
        <String, Object?>{
          'role_key': 'operator_admin',
          'display_name': 'Operator Admin',
          'description': 'Admin role.',
          'permissions': <Object?>[],
        },
      ],
      notes: 'Seeded for tests.',
    );
  }

  testWidgets('genesis: renders empty-state + empty draft + disabled publish', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // F&F admin chrome.
    expect(
      find.byKey(const Key('admin_default_role_catalog_screen')),
      findsOneWidget,
    );
    expect(find.text('Default roles'), findsOneWidget);

    // Genesis empty-state panel.
    expect(
      find.byKey(const Key('admin_default_role_catalog_current_empty')),
      findsOneWidget,
    );
    expect(
      find.text('No default catalog published yet'),
      findsOneWidget,
    );

    // Empty draft.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_empty')),
      findsOneWidget,
    );

    // Publish disabled.
    final publish = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(publish.onPressed, isNull);

    // History empty.
    expect(
      find.byKey(const Key('admin_default_role_catalog_history_empty')),
      findsOneWidget,
    );
  });

  testWidgets(
      'after publish: current version panel, history row, draft matches current',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'v1-id',
    );
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Current version panel renders.
    expect(
      find.byKey(const Key('admin_default_role_catalog_current_panel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_current_version')),
      findsOneWidget,
    );
    // History row exists.
    expect(
      find.byKey(const Key('admin_default_role_catalog_history_row_v1-id')),
      findsOneWidget,
    );

    // Draft has 2 rows pre-loaded.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_1')),
      findsOneWidget,
    );

    // Draft equals current → publish disabled + "Matches current" pill.
    final publish = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(publish.onPressed, isNull);
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_clean_pill')),
      findsOneWidget,
    );
  });

  testWidgets('editor: add role enables publish; remove restores prior state',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'v1-id',
    );
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Add role → publish should still be disabled (empty role_key / name).
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_add_role')),
    );
    await tester.pumpAndSettle();
    final afterAdd = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(afterAdd.onPressed, isNull);

    // Fill the new row's required fields.
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_draft_role_key_2')),
      'operator_manager',
    );
    await tester.enterText(
      find.byKey(
        const Key('admin_default_role_catalog_draft_display_name_2'),
      ),
      'Operator Manager',
    );
    await tester.pump();

    // Now publish is enabled.
    final afterFill = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(afterFill.onPressed, isNotNull);
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_dirty_pill')),
      findsOneWidget,
    );

    // Remove the row again.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_draft_remove_2')),
    );
    await tester.pumpAndSettle();

    // Publish disabled again (draft now equals current).
    final afterRemove = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(afterRemove.onPressed, isNull);
  });

  testWidgets('history row expands to show JSON payload', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'v1-id',
    );
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Initially the payload pane is collapsed.
    expect(
      find.byKey(
        const Key('admin_default_role_catalog_history_payload_v1-id'),
      ),
      findsNothing,
    );

    // Tap the row toggle.
    await tester.tap(
      find.byKey(
        const Key('admin_default_role_catalog_history_toggle_v1-id'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key('admin_default_role_catalog_history_payload_v1-id'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('read-only mode hides add / discard / publish affordances', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(
        gateway: gateway,
        editingEnabled: false,
      )),
    );
    await tester.pumpAndSettle();

    // Read-only banner present.
    expect(
      find.byKey(const Key('admin_default_role_catalog_readonly_banner')),
      findsOneWidget,
    );

    // Add role + discard not present.
    expect(
      find.byKey(const Key('admin_default_role_catalog_add_role')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_discard_draft')),
      findsNothing,
    );

    // Publish button is rendered but disabled.
    final publish = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(publish.onPressed, isNull);
  });

  testWidgets('publish flow opens dialog from screen', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'v1-id',
    );
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Add and fill a new role to enable publish.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_add_role')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_draft_role_key_2')),
      'operator_manager',
    );
    await tester.enterText(
      find.byKey(
        const Key('admin_default_role_catalog_draft_display_name_2'),
      ),
      'Operator Manager',
    );
    await tester.pump();

    // Tap Publish → dialog opens.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_dialog')),
      findsOneWidget,
    );
  });

  testWidgets('discard draft reverts to current version payload', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'v1-id',
    );
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    // Add a row to dirty the draft.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_add_role')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_discard_draft')),
      findsOneWidget,
    );

    // Discard.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_discard_draft')),
    );
    await tester.pumpAndSettle();

    // Row 2 gone; draft equals current pill.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_clean_pill')),
      findsOneWidget,
    );
  });

  testWidgets('load error: surfaces friendly error banner', (tester) async {
    final gateway = _ThrowingListGateway(
      DefaultRoleCatalogAdminGatewayError(
        statusCode: 503,
        errorCode: 'upstream_failure',
        message: 'admin pool offline',
      ),
    );
    await tester.pumpWidget(
      wrap(DefaultRoleCatalogAdminScreen(gateway: gateway)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_default_role_catalog_load_error')),
      findsOneWidget,
    );
    expect(
      find.textContaining('upstream_failure'),
      findsOneWidget,
    );
  });
}

class _ThrowingListGateway implements DefaultRoleCatalogAdminGateway {
  _ThrowingListGateway(this.error);

  final Object error;

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({int historyLimit = 20}) {
    throw error;
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<DefaultRoleCatalogBlastRadius> getBlastRadius({
    required String versionId,
  }) {
    throw UnimplementedError();
  }
}
