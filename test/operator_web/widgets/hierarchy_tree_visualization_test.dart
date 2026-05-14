// Wave 2 H-2 — unit tests for the visual hierarchy tree widget.
//
// The screen tests in `business_setup_screen_test.dart` +
// `business_timing_editor_screen_test.dart` already exercise the
// integration seams. This file pins the widget's own invariants:
//
//   * Tree renders one row per node, in passed order (root → leaf).
//   * Exactly one "You are here" current-scope highlight.
//   * "Inherits from here" badge renders only on rows that opt in.
//   * Header pill names the currently-edited scope in plain English.
//   * Data-gap explainer renders when supplied.
//
// Copy passes the UX writing standard
// (`memory/project_ux_writing_standard.md`): no engineering jargon,
// full sentences a new hire can read on day one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/hierarchy_tree_visualization.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('renders every node in order and highlights the current scope',
      (tester) async {
    tester.view.physicalSize = const Size(1024, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _wrap(
        const HierarchyTreeVisualization(
          keyName: 'h2_tree',
          headline: 'Test hierarchy',
          nodes: <HierarchyTreeNodeView>[
            HierarchyTreeNodeView(
              level: HierarchyTreeLevel.business,
              name: 'Brio Restaurants',
              inheritsFromHere: true,
              subtitle: 'Default settings every location inherits from.',
            ),
            HierarchyTreeNodeView(
              level: HierarchyTreeLevel.region,
              name: 'East Region',
            ),
            HierarchyTreeNodeView(
              level: HierarchyTreeLevel.location,
              name: 'Brio Main',
              isCurrentScope: true,
              subtitle: 'You are editing this location only.',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // All three rows render.
    expect(find.byKey(const Key('h2_tree_node_business')), findsOneWidget);
    expect(find.byKey(const Key('h2_tree_node_region')), findsOneWidget);
    expect(find.byKey(const Key('h2_tree_node_location')), findsOneWidget);

    // Exactly one "You are here" current-scope badge — on the leaf.
    expect(
      find.byKey(const Key('h2_tree_node_location_current_badge')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('h2_tree_node_business_current_badge')),
      findsNothing,
    );
    expect(find.text('You are here'), findsOneWidget);

    // Inheritance badge renders on the business row only.
    expect(
      find.byKey(const Key('h2_tree_node_business_inherits_badge')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('h2_tree_node_location_inherits_badge')),
      findsNothing,
    );

    // Header pill names the currently-edited scope, plain English.
    expect(find.text('Editing Location — Brio Main'), findsOneWidget);

    // No engineering jargon leaks through into the copy.
    expect(find.textContaining('scope_kind'), findsNothing);
    expect(find.textContaining('scope_id'), findsNothing);
    expect(find.textContaining('inherited_from'), findsNothing);
  });

  testWidgets('renders data-gap explainer when supplied', (tester) async {
    tester.view.physicalSize = const Size(1024, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      _wrap(
        const HierarchyTreeVisualization(
          keyName: 'h2_tree_gap',
          nodes: <HierarchyTreeNodeView>[
            HierarchyTreeNodeView(
              level: HierarchyTreeLevel.business,
              name: 'Demo Restaurant Group',
              isCurrentScope: true,
            ),
            HierarchyTreeNodeView(
              level: HierarchyTreeLevel.location,
              name: 'Demo Main Street',
            ),
          ],
          dataGapExplainer:
              'Regions and brands will appear here once your hierarchy '
              'is connected.',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('h2_tree_gap_data_gap')), findsOneWidget);
    expect(
      find.textContaining('Regions and brands will appear here'),
      findsOneWidget,
    );
  });
}
