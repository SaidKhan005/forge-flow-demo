// Wave 2 RP-10 — HierarchyTreePicker widget tests.
//
// Verifies the inline picker the invite + grant dialogs mount:
//   * Single-location hierarchies auto-select on first build and
//     render the confirmation row (no tree chrome).
//   * Multi-node hierarchies render the H-3 tree body inside a fixed-
//     height container so the dialog's submit row stays visible.
//   * Tapping a node fires `onSelected` with the matching
//     `HierarchyMapNode` so the parent dialog can apply the scope.
//   * The empty-state surface renders the plain-English "no locations
//     available" copy when callers pass an empty hierarchy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/hierarchy_map_picker.dart';
import 'package:forge_and_flow/operator_web/widgets/hierarchy_tree_picker.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(width: 360, child: child),
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

  group('HierarchyTreePicker', () {
    testWidgets('renders label and helper copy in plain English', (
      tester,
    ) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[
              HierarchyMapNode(
                id: 'biz:demo',
                label: 'Demo Bistro',
                helper: 'Whole business',
                kind: HierarchyMapNodeKind.business,
              ),
              HierarchyMapNode(
                id: 'org:east',
                label: 'East Region',
                helper: 'Region or group',
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
            ],
            selectedId: null,
            onSelected: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Choose where this person will work'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Pick the location, region, or whole business. Higher levels '
          'include everything beneath.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('single-location hierarchies auto-select and collapse', (
      tester,
    ) async {
      await sizeViewport(tester);
      final captured = <HierarchyMapNode>[];
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[
              HierarchyMapNode(
                id: 'loc:only',
                label: 'Only Location',
                helper: 'Location',
                kind: HierarchyMapNodeKind.location,
              ),
            ],
            selectedId: null,
            onSelected: captured.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Auto-select fires on the post-frame callback.
      expect(captured, hasLength(1));
      expect(captured.first.id, equals('loc:only'));

      // Render the confirmation row, not the interactive tree.
      expect(find.byKey(const Key('test_single')), findsOneWidget);
      expect(find.byKey(const Key('test_tree')), findsNothing);
      expect(find.text('Working at Only Location'), findsOneWidget);
    });

    testWidgets('multi-node hierarchies render the tree body', (tester) async {
      await sizeViewport(tester);
      final captured = <HierarchyMapNode>[];
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[
              HierarchyMapNode(
                id: 'biz:demo',
                label: 'Demo Bistro',
                helper: 'Whole business',
                kind: HierarchyMapNodeKind.business,
              ),
              HierarchyMapNode(
                id: 'loc:downtown',
                label: 'Downtown',
                helper: 'Location',
                kind: HierarchyMapNodeKind.location,
                parentId: 'biz:demo',
              ),
              HierarchyMapNode(
                id: 'loc:northloop',
                label: 'North Loop',
                helper: 'Location',
                kind: HierarchyMapNodeKind.location,
                parentId: 'biz:demo',
              ),
            ],
            selectedId: null,
            onSelected: captured.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tree mounted; the single-row confirmation surface stays
      // dormant because the hierarchy has more than one location.
      expect(find.byKey(const Key('test_tree')), findsOneWidget);
      expect(find.byKey(const Key('test_single')), findsNothing);

      // No auto-select runs because the dialog has a real choice to
      // make.
      expect(captured, isEmpty);

      // Tap the Downtown location and confirm the callback fires.
      await tester.tap(find.text('Downtown'));
      await tester.pumpAndSettle();
      expect(captured, hasLength(1));
      expect(captured.first.id, equals('loc:downtown'));
      expect(captured.first.kind, equals(HierarchyMapNodeKind.location));
    });

    testWidgets('tapping a region grants at the region scope', (tester) async {
      await sizeViewport(tester);
      final captured = <HierarchyMapNode>[];
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[
              HierarchyMapNode(
                id: 'biz:demo',
                label: 'Demo Bistro',
                helper: 'Whole business',
                kind: HierarchyMapNodeKind.business,
              ),
              HierarchyMapNode(
                id: 'org:east',
                label: 'East Region',
                helper: 'Region or group',
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
            ],
            selectedId: null,
            onSelected: captured.add,
            allowNonLocationSelection: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the region row.
      await tester.tap(find.text('East Region'));
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      expect(captured.first.id, equals('org:east'));
      expect(captured.first.kind, equals(HierarchyMapNodeKind.orgUnit));
    });

    testWidgets('empty hierarchies surface plain-English guidance', (
      tester,
    ) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[],
            selectedId: null,
            onSelected: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('test_empty')), findsOneWidget);
      expect(
        find.text('No locations available yet. Ask your admin to add one.'),
        findsOneWidget,
      );
    });

    testWidgets('errorText renders below the picker', (tester) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          HierarchyTreePicker(
            keyPrefix: 'test',
            nodes: const <HierarchyMapNode>[
              HierarchyMapNode(
                id: 'biz:demo',
                label: 'Demo Bistro',
                helper: 'Whole business',
                kind: HierarchyMapNodeKind.business,
              ),
              HierarchyMapNode(
                id: 'loc:downtown',
                label: 'Downtown',
                helper: 'Location',
                kind: HierarchyMapNodeKind.location,
                parentId: 'biz:demo',
              ),
              HierarchyMapNode(
                id: 'loc:northloop',
                label: 'North Loop',
                helper: 'Location',
                kind: HierarchyMapNodeKind.location,
                parentId: 'biz:demo',
              ),
            ],
            selectedId: null,
            onSelected: (_) {},
            errorText: 'Pick a location before sending the invite.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('test_error')), findsOneWidget);
      expect(
        find.text('Pick a location before sending the invite.'),
        findsOneWidget,
      );
    });
  });

  group('buildInviteHierarchyNodes', () {
    test('emits a business root followed by org units and locations', () {
      final nodes = buildInviteHierarchyNodes(
        businessId: 'operator-1',
        businessLabel: 'Demo Bistro',
        orgUnits: <({String orgUnitId, String name, String? parentOrgUnitId})>[
          (orgUnitId: 'east', name: 'East Region', parentOrgUnitId: null),
          (orgUnitId: 'west', name: 'West Region', parentOrgUnitId: null),
        ],
        locations: <({String locationId, String name, String? orgUnitId})>[
          (locationId: 'downtown', name: 'Downtown', orgUnitId: 'east'),
          (locationId: 'riverside', name: 'Riverside', orgUnitId: 'west'),
        ],
      );

      expect(nodes.first.id, equals('business:operator-1'));
      expect(nodes.first.kind, equals(HierarchyMapNodeKind.business));

      final east = nodes.firstWhere((n) => n.id == 'org_unit:east');
      expect(east.parentId, equals('business:operator-1'));
      expect(east.kind, equals(HierarchyMapNodeKind.orgUnit));

      final downtown = nodes.firstWhere((n) => n.id == 'location:downtown');
      expect(downtown.parentId, equals('org_unit:east'));
      expect(downtown.kind, equals(HierarchyMapNodeKind.location));
    });

    test('locations without an org-unit hang under the business root', () {
      final nodes = buildInviteHierarchyNodes(
        businessId: 'operator-1',
        businessLabel: 'Demo Bistro',
        orgUnits: const <({
          String orgUnitId,
          String name,
          String? parentOrgUnitId,
        })>[],
        locations: <({String locationId, String name, String? orgUnitId})>[
          (locationId: 'downtown', name: 'Downtown', orgUnitId: null),
        ],
      );

      final downtown = nodes.firstWhere((n) => n.id == 'location:downtown');
      expect(downtown.parentId, equals('business:operator-1'));
    });
  });
}
