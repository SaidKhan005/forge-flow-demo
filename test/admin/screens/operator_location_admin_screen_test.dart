// Refactor Phase B2a preservation work: pre-split characterization test for
// `lib/admin/screens/operator_location_admin_screen.dart` (4,308 lines —
// the biggest god-screen in the codebase). The screen is targeted by the
// refactor plan A2(c) to be split into siblings; this file pins the
// externally-observable invariants the split must preserve so a post-split
// diff has something concrete to verify against.
//
// What this file pins (outside behavior only):
//   * Empty render: zero seeded operators renders the empty card without
//     throwing.
//   * Pre-selection render: with operators seeded but none picked, the
//     shared left scope tree exposes one row per business and the right
//     detail pane shows the "Select a business" empty prompt.
//   * Super-admin viewing an operator: tapping a scope-tree business row
//     reveals the detail pane with the operator profile card, owner email,
//     and the Edit + Suspend action buttons (the canonical happy path for
//     a NON-suspended account in editing-enabled mode).
//   * Super-admin viewing a location under that operator: the location
//     hierarchy panel renders the seeded location row + its name.
//   * Read-only viewer (editingEnabled: false): the read-only banner is
//     visible, the New-business onboarding button is gone, and the
//     mutation buttons (Edit/Suspend/Reactivate) are hidden from the
//     operator profile header.
//   * Suspended operator: the profile shows the "suspended" status pill
//     AND the Reactivate button instead of the Suspend button.
//
// Deliberately NOT pinned (internal structure that may move during B2a):
//   * Private widget class names (`_OperatorDetail`, `_OperatorProfileHeader`,
//     `_BusinessHierarchyPanel`, etc.). The split will rename these.
//   * State-machine internals, exact pixel positions, font weights.
//   * Behavior already covered by the lifecycle / list-and-search /
//     admin-and-hierarchy split files (those run the full mutation path).
//
// All pumps are bounded via `pumpEventually` / `pumpUntil` (no unbounded
// `pumpAndSettle()` — see test_baseline_2026_05_22.md re: PRs #1089-#1132
// migrating the suite away from never-settling flake). Fixtures and the
// `wrap` MaterialApp helper come from the shared
// `admin_operator_location_test_helpers.dart`.
//
// New file location follows the repo convention: every other admin
// `*_admin_screen.dart` widget test under `lib/admin/screens/` lives at
// `test/admin/screens/*_admin_screen_test.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_scope_tree_pane.dart';

import '../../_test_helpers/widget_pump_helpers.dart';
import '../../admin_operator_location_test_helpers.dart';

void main() {
  /// Wide viewport so the split layout (left scope tree + right detail
  /// pane) renders side-by-side instead of folding into the two-tab
  /// compact layout below 920px. Matches what the existing split files
  /// already use.
  void useWideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Taps a business row in the shared left scope tree, which routes the
  /// right detail pane to render that operator's profile + hierarchy.
  Future<void> selectBusiness(
    WidgetTester tester,
    String operatorId,
  ) async {
    final row = find.byKey(Key('admin_setup_scope_business_$operatorId'));
    await tester.ensureVisible(row);
    await pumpEventually(tester);
    await tester.tap(row);
    await pumpEventually(tester);
  }

  testWidgets(
    'renders the empty state when no operators are seeded',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway();
      await tester.pumpWidget(
        wrap(OperatorLocationAdminScreen(gateway: gateway)),
      );
      await pumpEventually(tester);

      // Shell + empty card render without throwing.
      expect(find.byKey(const Key('admin_operators_screen')), findsOneWidget);
      expect(find.byKey(const Key('admin_operators_empty')), findsOneWidget);
      expect(find.text('No business accounts yet'), findsOneWidget);

      // The "New business" affordance is surfaced directly in the empty
      // state when editing is enabled (the scope pane doesn't render
      // when there are zero operators).
      expect(
        find.byKey(const Key('admin_operators_new_button')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'super-admin pre-selection: scope tree shows businesses, detail pane '
    'shows empty prompt',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-alpha', businessName: 'Alpha Cafe'),
          seedBundle(operatorId: 'op-beta', businessName: 'Beta Bistro'),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      // The shared scope tree is mounted with one row per seeded
      // business. (The screen reuses `AdminScopeTreePane` instead of the
      // pre-2026-05-24 flat operator list.)
      expect(
        find.byKey(const Key('admin_setup_workspace_scope_pane')),
        findsOneWidget,
      );
      expect(find.byType(AdminScopeTreePane), findsOneWidget);
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-beta')),
        findsOneWidget,
      );

      // Right detail pane shows the "Select a business" prompt before any
      // node is picked. The profile card is absent at this stage.
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsNothing,
      );

      // Both business names are discoverable in the tree.
      expect(find.text('Alpha Cafe'), findsWidgets);
      expect(find.text('Beta Bistro'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'super-admin viewing an operator: detail pane shows profile + Edit + '
    'Suspend actions',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-alpha', businessName: 'Alpha Cafe'),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusiness(tester, 'op-alpha');

      // The detail pane is now keyed by the picked operator id, and the
      // empty prompt is gone.
      expect(
        find.byKey(const Key('admin_operators_detail_empty')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_detail_op-alpha')),
        findsOneWidget,
      );

      // Profile card surface + the wrapping detail surface render.
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_business_account_detail_surface')),
        findsOneWidget,
      );

      // Business name + owner email from the seed are visible in the
      // profile. (Owner email comes from `seedBundle`'s
      // `'owner@seed.test'` default.)
      expect(find.text('Alpha Cafe'), findsWidgets);
      expect(find.text('owner@seed.test'), findsWidgets);

      // Canonical happy-path actions for a non-suspended operator in
      // editing-enabled mode: Edit + Suspend buttons present, Reactivate
      // hidden.
      expect(
        find.byKey(const Key('admin_operator_edit_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_suspend_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_reactivate_button')),
        findsNothing,
      );

      // The hierarchy panel renders alongside the profile.
      expect(
        find.byKey(const Key('admin_business_hierarchy_panel')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'super-admin viewing a location: hierarchy panel renders the seeded '
    'location row',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(
            operatorId: 'op-alpha',
            businessName: 'Alpha Cafe',
            primaryLocationId: 'loc-hq',
          ),
        ],
      );
      // Wiring the hierarchy gateway exposes the full org-unit + location
      // tree in the right pane's hierarchy panel (the canonical
      // location-scope view).
      final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
        orgUnitsByOperator: <String, List<OrgUnitAdminNode>>{
          'op-alpha': const <OrgUnitAdminNode>[
            OrgUnitAdminNode(
              orgUnitId: 'org-root',
              name: 'Headquarters region',
              operatorId: 'op-alpha',
              unitType: 'region',
            ),
          ],
        },
        locationsByOperator: <String, List<HierarchyLocationLeaf>>{
          'op-alpha': const <HierarchyLocationLeaf>[
            HierarchyLocationLeaf(
              locationId: 'loc-hq',
              name: 'HQ',
              operatorId: 'op-alpha',
              orgUnitId: 'org-root',
            ),
          ],
        },
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            hierarchyGateway: hierarchyGateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusiness(tester, 'op-alpha');

      // Hierarchy panel mounts and shows the business scope row, the
      // seeded org-unit row, and the seeded location row.
      expect(
        find.byKey(const Key('admin_business_hierarchy_panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_business_scope_row')),
        findsOneWidget,
      );

      // The org-unit and location rows are keyed by their ids; their
      // names should be visible. (We don't assert on private connector
      // depth keys / icon glyphs — those are covered by the
      // admin-and-hierarchy split file and may move during B2a.)
      await pumpUntil(
        tester,
        () => find
            .byKey(const Key('admin_hierarchy_org_unit_org-root'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_org_unit_org-root')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_location_loc-hq')),
        findsOneWidget,
      );
      expect(find.text('Headquarters region'), findsWidgets);
      expect(find.text('HQ'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read-only viewer (editingEnabled: false): banner shows, mutation '
    'actions hidden',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(operatorId: 'op-alpha', businessName: 'Alpha Cafe'),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            editingEnabled: false,
            actorUserId: 'demo-ff-support',
          ),
        ),
      );
      await pumpEventually(tester);

      // The read-only banner is mounted above the workspace.
      expect(
        find.byKey(const Key('admin_operators_readonly_banner')),
        findsOneWidget,
      );

      // The "New business" affordance is gone (`_buildNewBusinessButton`
      // returns null in read-only mode).
      expect(
        find.byKey(const Key('admin_operators_new_button')),
        findsNothing,
      );

      // The scope tree still renders; the viewer can read the business
      // list and pick into it.
      expect(
        find.byKey(const Key('admin_setup_scope_business_op-alpha')),
        findsOneWidget,
      );
      await selectBusiness(tester, 'op-alpha');

      // Profile card renders for read-only viewing, but every mutation
      // button (Edit / Suspend / Reactivate) is gated off.
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_edit_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_suspend_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_reactivate_button')),
        findsNothing,
      );
      // The add-location action is also gone in read-only mode.
      expect(
        find.byKey(const Key('admin_operator_add_location_button')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'suspended operator: Reactivate button replaces Suspend + status pill '
    'is visible',
    (tester) async {
      useWideSurface(tester);
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          seedBundle(
            operatorId: 'op-suspended',
            businessName: 'Closed Diner',
            suspended: true,
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          OperatorLocationAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
          ),
        ),
      );
      await pumpEventually(tester);

      await selectBusiness(tester, 'op-suspended');

      // The profile is rendered for a suspended account.
      expect(
        find.byKey(const Key('admin_operator_profile_card')),
        findsOneWidget,
      );
      expect(find.text('Closed Diner'), findsWidgets);

      // Action gating flips for a suspended account: Reactivate is shown
      // instead of Suspend. Edit stays available.
      expect(
        find.byKey(const Key('admin_operator_edit_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_reactivate_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_suspend_button')),
        findsNothing,
      );

      // The "suspended" pill is visible in the profile header.
      expect(find.text('suspended'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
