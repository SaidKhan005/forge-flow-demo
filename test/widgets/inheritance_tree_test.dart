// Slice L_A1 — Inheritance Tree widget tests.
//
// Pins the shared visualization contract: render hierarchy, expose
// caller-supplied annotation slot, optional tap handler, empty state,
// expand/collapse toggle, deep nesting.
//
// Notably does NOT pin selector behavior: the widget is a pure
// visualization. Consumer-specific concerns (effective values, scope
// filters, mutate affordances) live in the caller's wrapper, not in
// this widget.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/inheritance_tree_node.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/inheritance_tree.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  const businessRoot = InheritanceTreeNode(
    scopeKind: InheritanceTreeScopeKind.business,
    scopeId: 'ou-root',
    displayName: 'Demo Bistro',
    depth: 0,
    children: <InheritanceTreeNode>[
      InheritanceTreeNode(
        scopeKind: InheritanceTreeScopeKind.orgUnit,
        scopeId: 'ou-north',
        displayName: 'North Region',
        parentScopeId: 'ou-root',
        depth: 1,
        metadata: <String, Object?>{'unit_type': 'region'},
        children: <InheritanceTreeNode>[
          InheritanceTreeNode(
            scopeKind: InheritanceTreeScopeKind.location,
            scopeId: 'loc-alpha',
            displayName: 'Alpha Cafe',
            parentScopeId: 'ou-north',
            depth: 2,
          ),
          InheritanceTreeNode(
            scopeKind: InheritanceTreeScopeKind.location,
            scopeId: 'loc-zeta',
            displayName: 'Zeta Cafe',
            parentScopeId: 'ou-north',
            depth: 2,
          ),
        ],
      ),
    ],
  );

  testWidgets('renders Business, Org Unit, and Location rows', (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    expect(find.byKey(const Key('inheritance_tree')), findsOneWidget);
    expect(find.text('Demo Bistro'), findsOneWidget);
    expect(find.text('Business'), findsOneWidget);
    expect(find.text('North Region'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Alpha Cafe'), findsOneWidget);
    expect(find.text('Zeta Cafe'), findsOneWidget);
    expect(find.text('Location'), findsNWidgets(2));
  });

  testWidgets('annotationBuilder injects caller-supplied widget per node',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    final calledScopeIds = <String>[];
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (context, node) {
            calledScopeIds.add(node.scopeId);
            return Text(
              'ann:${node.scopeId}',
              key: Key('ann_for_${node.scopeId}'),
            );
          },
        ),
      ),
    );
    // Builder called for every visible node — root + 1 region + 2 leaves.
    expect(calledScopeIds, containsAll(<String>[
      'ou-root',
      'ou-north',
      'loc-alpha',
      'loc-zeta',
    ]));
    // The annotation widget is mounted inside the slot keyed by scopeId.
    expect(
      find.byKey(const Key('inheritance_tree_annotation_ou-root')),
      findsOneWidget,
    );
    expect(find.text('ann:ou-root'), findsOneWidget);
    expect(find.text('ann:loc-alpha'), findsOneWidget);
  });

  testWidgets('onNodeTap fires with the tapped node', (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    final tapped = <InheritanceTreeNode>[];
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
          onNodeTap: tapped.add,
        ),
      ),
    );
    await tester.tap(
      find.byKey(const Key('inheritance_tree_tap_loc-alpha')),
    );
    await tester.pump();
    expect(tapped, hasLength(1));
    expect(tapped.single.scopeId, equals('loc-alpha'));
    expect(tapped.single.scopeKind, equals(InheritanceTreeScopeKind.location));
  });

  testWidgets('no tap handler renders read-only (no InkWell)', (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    // The tappable wrapper has key inheritance_tree_tap_<scopeId>; it
    // must be absent when onNodeTap is null.
    expect(
      find.byKey(const Key('inheritance_tree_tap_loc-alpha')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('inheritance_tree_tap_ou-root')),
      findsNothing,
    );
  });

  testWidgets('expand/collapse toggle hides + reveals descendants',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    // Initially expanded — both leaves visible.
    expect(find.text('Alpha Cafe'), findsOneWidget);
    expect(find.text('Zeta Cafe'), findsOneWidget);
    // Collapse the North Region node.
    await tester.tap(
      find.byKey(const Key('inheritance_tree_toggle_ou-north')),
    );
    await tester.pump();
    expect(find.text('Alpha Cafe'), findsNothing);
    expect(find.text('Zeta Cafe'), findsNothing);
    // North Region label itself remains visible.
    expect(find.text('North Region'), findsOneWidget);
    // Expand again.
    await tester.tap(
      find.byKey(const Key('inheritance_tree_toggle_ou-north')),
    );
    await tester.pump();
    expect(find.text('Alpha Cafe'), findsOneWidget);
    expect(find.text('Zeta Cafe'), findsOneWidget);
  });

  testWidgets('initiallyCollapsedScopeIds starts the node collapsed',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
          initiallyCollapsedScopeIds: const <String>{'ou-north'},
        ),
      ),
    );
    // North Region label visible; leaves hidden because the node
    // mounted collapsed.
    expect(find.text('North Region'), findsOneWidget);
    expect(find.text('Alpha Cafe'), findsNothing);
    expect(find.text('Zeta Cafe'), findsNothing);
  });

  testWidgets('empty business (no children) renders the empty state notice',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    const emptyRoot = InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: 'ou-root',
      displayName: 'Brand New Business',
      depth: 0,
    );
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: emptyRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    expect(find.byKey(const Key('inheritance_tree_empty')), findsOneWidget);
    expect(find.byKey(const Key('inheritance_tree')), findsNothing);
    expect(
      find.textContaining('No org units or locations yet'),
      findsOneWidget,
    );
  });

  testWidgets('custom empty message overrides the default copy', (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    const emptyRoot = InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: 'ou-root',
      displayName: 'Brand New Business',
    );
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: emptyRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
          emptyMessage: 'Custom-tailored empty copy.',
        ),
      ),
    );
    expect(find.text('Custom-tailored empty copy.'), findsOneWidget);
  });

  testWidgets('deep nesting (business → region → district → location)',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    const deepRoot = InheritanceTreeNode(
      scopeKind: InheritanceTreeScopeKind.business,
      scopeId: 'ou-root',
      displayName: 'Demo Bistro',
      depth: 0,
      children: <InheritanceTreeNode>[
        InheritanceTreeNode(
          scopeKind: InheritanceTreeScopeKind.orgUnit,
          scopeId: 'ou-east',
          displayName: 'East Region',
          parentScopeId: 'ou-root',
          depth: 1,
          metadata: <String, Object?>{'unit_type': 'region'},
          children: <InheritanceTreeNode>[
            InheritanceTreeNode(
              scopeKind: InheritanceTreeScopeKind.orgUnit,
              scopeId: 'ou-downtown',
              displayName: 'Downtown District',
              parentScopeId: 'ou-east',
              depth: 2,
              metadata: <String, Object?>{'unit_type': 'district'},
              children: <InheritanceTreeNode>[
                InheritanceTreeNode(
                  scopeKind: InheritanceTreeScopeKind.location,
                  scopeId: 'loc-flagship',
                  displayName: 'Flagship Store',
                  parentScopeId: 'ou-downtown',
                  depth: 3,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: deepRoot,
          annotationBuilder: (_, _) => const SizedBox.shrink(),
        ),
      ),
    );
    expect(find.text('Demo Bistro'), findsOneWidget);
    expect(find.text('East Region'), findsOneWidget);
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('Downtown District'), findsOneWidget);
    expect(find.text('District'), findsOneWidget);
    expect(find.text('Flagship Store'), findsOneWidget);
    // Leaf node should NOT have an expand/collapse toggle button.
    expect(
      find.byKey(const Key('inheritance_tree_toggle_loc-flagship')),
      findsNothing,
    );
    // Branch nodes do have toggles.
    expect(
      find.byKey(const Key('inheritance_tree_toggle_ou-east')),
      findsOneWidget,
    );
  });

  testWidgets('annotation slot can dispatch on scopeKind (B6/B8 pattern)',
      (tester) async {
    await sizeViewport(tester, const Size(900, 700));
    await tester.pumpWidget(
      wrap(
        InheritanceTree(
          rootNode: businessRoot,
          annotationBuilder: (context, node) {
            // Simulate a consumer (B6 benchmark inheritance) that
            // attaches "Inherited" only on leaf nodes.
            if (node.scopeKind != InheritanceTreeScopeKind.location) {
              return const SizedBox.shrink();
            }
            return Text('Inherited (${node.scopeId})');
          },
        ),
      ),
    );
    expect(find.text('Inherited (loc-alpha)'), findsOneWidget);
    expect(find.text('Inherited (loc-zeta)'), findsOneWidget);
    expect(find.text('Inherited (ou-root)'), findsNothing);
    expect(find.text('Inherited (ou-north)'), findsNothing);
  });
}
