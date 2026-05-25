// Lane B B2.2 - Default Role catalog admin screen widget tests.
//
// Pins the screen contract documented in
// `lib/admin/screens/default_role_catalog_admin_screen.dart`:
//
//   * Genesis state (no current version) renders the empty-state
//     panel + a prefilled built-in starter draft. Publish is enabled.
//   * After a publish: current version panel + history row appear;
//     draft pre-loads from the published payload; publish button is
//     disabled while the draft equals the current.
//   * Editor: the page renders a compact role list; tapping a role
//     opens the full editor dialog. Add role opens a matching create
//     dialog before the role is added to the draft.
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
          'role_key': 'operator_general_manager',
          'display_name': 'General Manager',
          'description': 'General manager role.',
          'permissions': <Object?>[],
        },
      ],
      notes: 'Seeded for tests.',
    );
  }

  Future<void> addDefaultRole(
    WidgetTester tester, {
    String displayName = 'Location Manager',
  }) async {
    final addRole = find.byKey(
      const Key('admin_default_role_catalog_add_role'),
    );
    await tester.ensureVisible(addRole);
    await tester.pumpAndSettle();
    await tester.tap(addRole);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_add_role_display_name')),
      displayName,
    );
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_add_role_description')),
      '$displayName role.',
    );
    final permission = find.byKey(
      const Key(
        'admin_default_role_catalog_add_role_picker_perm_team.users.view_checkbox',
      ),
    );
    await tester.ensureVisible(permission);
    await tester.pumpAndSettle();
    await tester.tap(permission);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_add_role_submit')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('genesis: renders empty-state + starter seeded role draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 6000);
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
    expect(find.text('Using built-in starter roles'), findsOneWidget);

    // Built-in starter draft, editable before first publish.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_empty')),
      findsNothing,
    );
    const expectedRoleNames = <String>[
      'Owner',
      'General Manager',
      'Location Manager',
      'Supervisor',
      'Finance Analyst',
      'Auditor / Compliance',
      'Training Lead',
      'Team Admin',
    ];
    for (var i = 0; i < expectedRoleNames.length; i++) {
      expect(
        find.byKey(Key('admin_default_role_catalog_draft_row_$i')),
        findsOneWidget,
      );
      expect(find.text(expectedRoleNames[i]), findsOneWidget);
    }

    // The full role editor is one tap away instead of mounted inline.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_draft_row_0')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_default_role_catalog_role_dialog_0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_role_key_0')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_display_name_0')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_role_dialog_done_0')),
    );
    await tester.pumpAndSettle();

    // Genesis starter draft can be published as version 1.
    final publish = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(publish.onPressed, isNotNull);
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_dirty_pill')),
      findsOneWidget,
    );

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
    },
  );

  testWidgets('editor: add role enables publish; remove restores prior state', (
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

    // Wave 2 S-3 (RP-14) — each draft row now embeds the picker,
    // which makes the panel tall enough that affordances at the
    // bottom need an ensureVisible scroll before tapping.
    final addRoleFinder = find.byKey(
      const Key('admin_default_role_catalog_add_role'),
    );
    await tester.ensureVisible(addRoleFinder);
    await tester.pumpAndSettle();
    // Cancel leaves the role list unchanged.
    await tester.tap(addRoleFinder);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_default_role_catalog_add_role_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_add_role_cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
      findsNothing,
    );

    await addDefaultRole(tester);
    final afterFill = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(afterFill.onPressed, isNotNull);
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_dirty_pill')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
    );
    await tester.pumpAndSettle();
    final removeFinder = find.byKey(
      const Key('admin_default_role_catalog_draft_remove_2'),
    );
    await tester.ensureVisible(removeFinder);
    await tester.pumpAndSettle();
    await tester.tap(removeFinder);
    await tester.pumpAndSettle();

    // Publish disabled again (draft now equals current).
    final afterRemove = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_button')),
    );
    expect(afterRemove.onPressed, isNull);
  });

  testWidgets('history row expands to show plain-English role summary', (
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

    // Initially the payload pane is collapsed.
    expect(
      find.byKey(const Key('admin_default_role_catalog_history_payload_v1-id')),
      findsNothing,
    );

    // Tap the row toggle. The picker per draft row pushes the
    // history panel below the visible area so scroll first.
    final historyToggle = find.byKey(
      const Key('admin_default_role_catalog_history_toggle_v1-id'),
    );
    await tester.ensureVisible(historyToggle);
    await tester.pumpAndSettle();
    await tester.tap(historyToggle);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_default_role_catalog_history_payload_v1-id')),
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
      wrap(
        DefaultRoleCatalogAdminScreen(gateway: gateway, editingEnabled: false),
      ),
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

    await addDefaultRole(tester);

    final publishButton = find.byKey(
      const Key('admin_default_role_catalog_publish_button'),
    );
    await tester.ensureVisible(publishButton);
    await tester.pumpAndSettle();
    await tester.tap(publishButton);
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

    await addDefaultRole(tester);
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_row_2')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_discard_draft')),
      findsOneWidget,
    );

    // Discard.
    final discard = find.byKey(
      const Key('admin_default_role_catalog_discard_draft'),
    );
    await tester.ensureVisible(discard);
    await tester.pumpAndSettle();
    await tester.tap(discard);
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

  testWidgets('Wave 2 S-3 (RP-14): each draft row renders the product/category '
      'permission picker', (tester) async {
    tester.view.physicalSize = const Size(1280, 4000);
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

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_draft_row_0')),
    );
    await tester.pumpAndSettle();

    // Picker mounts inside the role editor dialog.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_permissions_0')),
      findsOneWidget,
    );
    // Picker exposes the Forge & Flow product section keyed with
    // the per-row prefix.
    expect(
      find.byKey(
        const Key(
          'admin_default_role_catalog_draft_picker_0_product_forgeflow',
        ),
      ),
      findsOneWidget,
    );
    // Search box rendered per row.
    expect(
      find.byKey(const Key('admin_default_role_catalog_draft_picker_0_search')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Wave 2 S-3 (RP-14): admin picker is business-scoped (no scope notice)',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 4000);
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

      // Default-catalog roles are business-scoped — the scope-conflict
      // notice does not render in the admin surface.
      await tester.tap(
        find.byKey(const Key('admin_default_role_catalog_draft_row_0')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('admin_default_role_catalog_draft_picker_0_scope_notice'),
        ),
        findsNothing,
      );
    },
  );

  // Wave 2 RP-9 (2026-05-14) — granular permission gate. The screen
  // file exposes role-tier sets that mirror the seeded grants for
  // `team.roles.default_catalog.view` / `team.roles.default_catalog.edit`.
  // The helper `defaultRoleCatalogScreenCanEdit` is the defense-in-depth
  // mapping the admin route uses until a wired `PermissionResolver`
  // lands. These tests pin the role-tier <-> permission-key mapping so
  // a future widening to operator-tier roles is caught at CI.
  group('Wave 2 RP-9 default catalog admin permission gate', () {
    test('view role tier set is super_admin + ff_support only', () {
      expect(
        kDefaultRoleCatalogScreenViewRoles,
        equals(<String>{'super_admin', 'ff_support'}),
      );
    });

    test('edit role tier set is super_admin only', () {
      expect(
        kDefaultRoleCatalogScreenEditRoles,
        equals(<String>{'super_admin'}),
      );
    });

    test('defaultRoleCatalogScreenCanEdit grants super_admin', () {
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['super_admin'],
        ),
        isTrue,
      );
    });

    test('defaultRoleCatalogScreenCanEdit denies ff_support', () {
      // ff_support holds the view key (read-only branch) but not edit.
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['ff_support'],
        ),
        isFalse,
      );
    });

    test('defaultRoleCatalogScreenCanEdit denies operator_owner', () {
      // F&F-internal scope — operator-tier roles never receive the
      // edit grant. Widening here without a code-change to
      // kDefaultRoleCatalogScreenEditRoles + the migration seed would
      // be a launch-blocker.
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['operator_owner'],
        ),
        isFalse,
      );
    });

    test('defaultRoleCatalogScreenCanEdit denies an empty role set', () {
      expect(
        defaultRoleCatalogScreenCanEdit(actorRoles: const <String>[]),
        isFalse,
      );
    });

    test('defaultRoleCatalogScreenCanEdit honours role-tier check when the '
        'resolver hint disagrees (defense-in-depth)', () {
      // The role-tier check is authoritative until the admin console
      // threads a PermissionResolver. A future resolver verdict that
      // disagrees with the role-tier check MUST NOT silently widen
      // the gate.
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['operator_owner'],
          actorHasEditKeyHint: true,
        ),
        isFalse,
      );
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['super_admin'],
          actorHasEditKeyHint: false,
        ),
        isTrue,
      );
    });
  });

  testWidgets('Wave 2 RP-9: edit affordances render when editingEnabled=true '
      '(super_admin tier)', (tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    await seedOneVersion(gateway);

    await tester.pumpWidget(
      wrap(
        DefaultRoleCatalogAdminScreen(
          gateway: gateway,
          // Mirrors the admin route's resolved verdict when an actor
          // carries the `team.roles.default_catalog.edit` permission
          // key (super_admin role tier).
          editingEnabled: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Read-only banner absent; add-role affordance present.
    expect(
      find.byKey(const Key('admin_default_role_catalog_readonly_banner')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_default_role_catalog_add_role')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Wave 2 RP-9: ff_support read branch lands when editingEnabled=false',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final gateway = InMemoryDefaultRoleCatalogAdminGateway();
      await seedOneVersion(gateway);

      await tester.pumpWidget(
        wrap(
          DefaultRoleCatalogAdminScreen(
            gateway: gateway,
            // Mirrors the admin route's resolved verdict when an actor
            // holds only the `team.roles.default_catalog.view` key
            // (ff_support tier).
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Read-only banner present; add-role gone.
      expect(
        find.byKey(const Key('admin_default_role_catalog_readonly_banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_default_role_catalog_add_role')),
        findsNothing,
      );
      // Publish button still rendered but disabled.
      final publish = tester.widget<FilledButton>(
        find.byKey(const Key('admin_default_role_catalog_publish_button')),
      );
      expect(publish.onPressed, isNull);
    },
  );

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
    expect(find.textContaining('upstream_failure'), findsOneWidget);
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
