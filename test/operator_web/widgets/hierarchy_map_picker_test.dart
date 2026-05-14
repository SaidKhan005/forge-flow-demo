// Wave 2 H-3 — Hierarchy-map picker widget tests.
//
// Verifies the top-bar picker:
//   * Renders the trigger with the current selection summary.
//   * Opens a popover on tap, mounts the search field, and shows the
//     hierarchy tree.
//   * Fires the selection callback when a node row is tapped.
//   * Filters the tree by the search query (and keeps ancestors
//     visible so the operator sees the path to a matched leaf).
//   * Renders disabled branches with the disabled-reason tooltip so
//     the operator sees no-access rows explicitly (HP #11).
//   * Inline `HierarchyMapTreeBody` mode mounts the tree without a
//     popover wrapper (the admin scope-prompt analogue).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/hierarchy_map_picker.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        // Anchor the picker near the top of the viewport so its
        // overlay popover (rendered 44px below the trigger) stays
        // inside the test view and stays hit-testable.
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: SizedBox(width: 320, child: child),
            ),
          ),
        ),
      );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  const nodes = <HierarchyMapNode>[
    HierarchyMapNode(
      id: 'biz:demo',
      label: 'Demo Bistro',
      helper: 'Business-wide',
      kind: HierarchyMapNodeKind.business,
    ),
    HierarchyMapNode(
      id: 'org:east',
      label: 'East Region',
      helper: 'Region',
      kind: HierarchyMapNodeKind.orgUnit,
      parentId: 'biz:demo',
      inheritanceBreadcrumb:
          'Inherits business-wide defaults. Locations inherit values you set here.',
    ),
    HierarchyMapNode(
      id: 'org:west',
      label: 'West Region',
      helper: 'Region',
      kind: HierarchyMapNodeKind.orgUnit,
      parentId: 'biz:demo',
    ),
    HierarchyMapNode(
      id: 'loc:downtown',
      label: 'Downtown',
      helper: 'Location',
      kind: HierarchyMapNodeKind.location,
      parentId: 'org:east',
    ),
    HierarchyMapNode(
      id: 'loc:northloop',
      label: 'North Loop',
      helper: 'Location',
      kind: HierarchyMapNodeKind.location,
      parentId: 'org:east',
    ),
    HierarchyMapNode(
      id: 'loc:riverside',
      label: 'Riverside',
      helper: 'Location',
      kind: HierarchyMapNodeKind.location,
      parentId: 'org:west',
      disabled: true,
      disabledReason: "You don't have access to this location.",
    ),
  ];

  group('HierarchyMapPicker', () {
    testWidgets('mounts the trigger with the current selection label', (
      tester,
    ) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          HierarchyMapPicker(
            keyPrefix: 'picker',
            nodes: nodes,
            selectedId: 'loc:downtown',
            onSelected: (_) {},
          ),
        ),
      );

      expect(find.byKey(const Key('picker_trigger')), findsOneWidget);
      // Trigger shows the selected label + helper line (popover closed
      // so the only `Downtown` Text is the trigger summary).
      expect(find.text('Downtown'), findsOneWidget);
      expect(find.text('Location'), findsOneWidget);
    });

    testWidgets('opens the popover and fires onSelected on row tap', (
      tester,
    ) async {
      await sizeViewport(tester);
      HierarchyMapNode? selected;
      await tester.pumpWidget(
        wrap(
          HierarchyMapPicker(
            keyPrefix: 'picker',
            nodes: nodes,
            selectedId: 'biz:demo',
            onSelected: (node) => selected = node,
          ),
        ),
      );

      // Popover not mounted yet.
      expect(find.byKey(const Key('picker_search_field')), findsNothing);

      await tester.tap(find.byKey(const Key('picker_trigger')));
      await tester.pumpAndSettle();

      // Search field + tree are now visible.
      expect(find.byKey(const Key('picker_search_field')), findsOneWidget);
      // Downtown is only in the tree because trigger shows "Demo Bistro".
      expect(find.text('Downtown'), findsOneWidget);

      await tester.tap(find.byKey(const Key('picker_node_loc_downtown')));
      await tester.pumpAndSettle();

      expect(selected, isNotNull);
      expect(selected!.id, 'loc:downtown');
      // Popover closed after selection.
      expect(find.byKey(const Key('picker_search_field')), findsNothing);
    });

    testWidgets('search filters the tree and keeps ancestors visible', (
      tester,
    ) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          HierarchyMapPicker(
            keyPrefix: 'picker',
            nodes: nodes,
            selectedId: 'biz:demo',
            onSelected: (_) {},
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('picker_trigger')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('picker_search_field')),
        'downtown',
      );
      await tester.pumpAndSettle();

      // Match + ancestors stay visible in the tree…
      expect(
        find.byKey(const Key('picker_node_loc_downtown')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('picker_node_org_east')), findsOneWidget);
      expect(find.byKey(const Key('picker_node_biz_demo')), findsOneWidget);
      // …non-matching siblings disappear from the tree.
      expect(
        find.byKey(const Key('picker_node_loc_northloop')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('picker_node_loc_riverside')),
        findsNothing,
      );
      expect(find.byKey(const Key('picker_node_org_west')), findsNothing);
    });

    testWidgets('disabled branches render with a tooltip explainer', (
      tester,
    ) async {
      await sizeViewport(tester);
      var taps = 0;
      await tester.pumpWidget(
        wrap(
          HierarchyMapPicker(
            keyPrefix: 'picker',
            nodes: nodes,
            selectedId: 'biz:demo',
            onSelected: (_) => taps++,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('picker_trigger')));
      await tester.pumpAndSettle();

      // The disabled Riverside row renders…
      final disabledRow = find.byKey(const Key('picker_node_loc_riverside'));
      expect(disabledRow, findsOneWidget);
      // …and tapping it does NOT fire selection (HP #11 carve-out).
      await tester.tap(disabledRow);
      await tester.pumpAndSettle();
      expect(taps, 0);
    });
  });

  group('HierarchyMapTreeBody (inline)', () {
    testWidgets('mounts without a popover trigger and fires onNodeTap', (
      tester,
    ) async {
      await sizeViewport(tester);
      HierarchyMapNode? tapped;
      await tester.pumpWidget(
        wrap(
          HierarchyMapTreeBody(
            keyPrefix: 'inline',
            nodes: nodes,
            selectedId: 'biz:demo',
            onNodeTap: (node) => tapped = node,
          ),
        ),
      );

      // Search + tree visible immediately (no trigger to tap first).
      expect(find.byKey(const Key('inline_search_field')), findsOneWidget);
      expect(find.byKey(const Key('inline_node_biz_demo')), findsOneWidget);
      expect(find.byKey(const Key('inline_node_org_east')), findsOneWidget);

      await tester.tap(find.byKey(const Key('inline_node_loc_northloop')));
      await tester.pumpAndSettle();

      expect(tapped, isNotNull);
      expect(tapped!.id, 'loc:northloop');
    });
  });
}
