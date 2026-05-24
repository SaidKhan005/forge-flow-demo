// UX-parity Slice B — admin top-bar scope picker + demo banner tests.
//
// Coverage:
//   * The collapsed trigger opens the search-first overlay.
//   * Typing in the search field filters the business list.
//   * Picking a business + location updates the displayed "Managing:"
//     label AND invokes the scope-select callback with an
//     [AdminHierarchyScopeIntent] carrying the chosen operator/location.
//   * The demo banner renders under `sharePreviewMode: true` and is
//     absent (`SizedBox.shrink`) when false.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/admin_demo_banner.dart';
import 'package:forge_and_flow/admin/widgets/admin_scope_picker.dart';

void main() {
  LocationAdminRecord loc({
    required String locationId,
    required String operatorId,
    required String name,
  }) {
    return LocationAdminRecord(
      locationId: locationId,
      operatorId: operatorId,
      name: name,
      address: '',
      timezone: 'America/Toronto',
      businessDayRolloverHour: 4,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }

  OperatorAdminBundle bundle({
    required String operatorId,
    required String name,
    required List<LocationAdminRecord> locations,
  }) {
    return OperatorAdminBundle(
      operator: OperatorAdminRecord(
        operatorId: operatorId,
        businessName: name,
        ownerEmail: 'owner@$operatorId.test',
        subscriptionTier: 'launch',
        preferredCurrency: 'CAD',
        primaryLocationId: locations.isEmpty ? null : locations.first.locationId,
        suspendedAt: null,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      locations: locations,
    );
  }

  InMemoryOperatorLocationAdminGateway seededGateway() {
    return InMemoryOperatorLocationAdminGateway(
      seed: <OperatorAdminBundle>[
        bundle(
          operatorId: 'op-diner',
          name: 'Demo Diner Co.',
          locations: <LocationAdminRecord>[
            loc(
              locationId: 'loc-tor',
              operatorId: 'op-diner',
              name: 'Toronto Yorkville',
            ),
            loc(
              locationId: 'loc-van',
              operatorId: 'op-diner',
              name: 'Vancouver Robson',
            ),
          ],
        ),
        bundle(
          operatorId: 'op-sunset',
          name: 'Sunset Cafe Group',
          locations: <LocationAdminRecord>[
            loc(
              locationId: 'loc-bk',
              operatorId: 'op-sunset',
              name: 'Brooklyn Williamsburg',
            ),
          ],
        ),
      ],
    );
  }

  // Stateful host mirroring the shell: holds the chosen scope, rebuilds
  // the picker with the new selection, and records the callback value.
  Widget pickerHost(
    OperatorLocationAdminGateway gateway, {
    required void Function(AdminHierarchyScopeIntent scope) onSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: _ScopePickerHost(gateway: gateway, onSelected: onSelected),
      ),
    );
  }

  testWidgets('trigger opens overlay; search filters the business list', (
    tester,
  ) async {
    await tester.pumpWidget(pickerHost(seededGateway(), onSelected: (_) {}));
    await tester.pumpAndSettle();

    // Resting state.
    expect(
      find.byKey(const Key('admin_scope_picker_trigger_label')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
    await tester.pumpAndSettle();

    // Both businesses present before filtering.
    expect(
      find.byKey(const Key('admin_scope_picker_business_op-diner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_scope_picker_business_op-sunset')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_scope_picker_search_field')),
      'sunset',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_scope_picker_business_op-sunset')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_scope_picker_business_op-diner')),
      findsNothing,
    );
  });

  testWidgets(
    'picking business + location updates label and fires scope callback',
    (tester) async {
      final captured = <AdminHierarchyScopeIntent>[];
      await tester.pumpWidget(
        pickerHost(seededGateway(), onSelected: captured.add),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
      await tester.pumpAndSettle();

      // Expand the diner to reveal its locations.
      await tester.tap(
        find.byKey(const Key('admin_scope_picker_expander_op-diner')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_scope_picker_location_loc-van')),
      );
      await tester.pumpAndSettle();

      // Callback fired with a location-scoped intent carrying the
      // chosen operator + location.
      expect(captured, hasLength(1));
      final scope = captured.single;
      expect(scope.isLocationScope, isTrue);
      expect(scope.operatorId, 'op-diner');
      expect(scope.locationId, 'loc-van');
      expect(scope.operatorName, 'Demo Diner Co.');
      expect(scope.locationName, 'Vancouver Robson');

      // Trigger now reflects the selection across its two label lines
      // (business on the primary line, location on the helper line),
      // matching operator-web's large-trigger layout.
      expect(find.text('Demo Diner Co.'), findsOneWidget);
      expect(find.text('Vancouver Robson'), findsOneWidget);
    },
  );

  testWidgets('picking a business-wide row fires a business-scoped intent', (
    tester,
  ) async {
    final captured = <AdminHierarchyScopeIntent>[];
    await tester.pumpWidget(
      pickerHost(seededGateway(), onSelected: captured.add),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_scope_picker_business_op-sunset')),
    );
    await tester.pumpAndSettle();

    expect(captured, hasLength(1));
    expect(captured.single.isBusinessScope, isTrue);
    expect(captured.single.operatorId, 'op-sunset');
    expect(find.text('Sunset Cafe Group'), findsOneWidget);
    expect(find.text('All locations'), findsOneWidget);
  });

  testWidgets(
    'overlay business + location rows render canonical scope-entity icons',
    (tester) async {
      // Wide enough that the overlay (title + search + businesses) lays out
      // without a viewport-only overflow on the default test surface.
      tester.view.physicalSize = const Size(1024, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(pickerHost(seededGateway(), onSelected: (_) {}));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
      await tester.pumpAndSettle();

      // Business rows use the canonical business glyph (apartment), not the
      // legacy admin business_outlined.
      expect(
        find.descendant(
          of: find.byKey(const Key('admin_scope_picker_business_op-diner')),
          matching: find.byIcon(Icons.apartment_outlined),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.business_outlined), findsNothing);

      // Expand the diner to reveal its locations; each location row uses the
      // canonical location glyph (place).
      await tester.tap(
        find.byKey(const Key('admin_scope_picker_expander_op-diner')),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('admin_scope_picker_location_loc-van')),
          matching: find.byIcon(Icons.place_outlined),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('demo banner renders only under sharePreviewMode: true', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdminDemoBanner(sharePreviewMode: true)),
      ),
    );
    expect(find.byKey(const Key('admin_demo_banner')), findsOneWidget);
    expect(
      find.textContaining('Demo data. This is a sample walkthrough'),
      findsOneWidget,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AdminDemoBanner(sharePreviewMode: false)),
      ),
    );
    expect(find.byKey(const Key('admin_demo_banner')), findsNothing);
    // Collapses to a zero-size box when off.
    final renderBox = tester.renderObject<RenderBox>(
      find.byType(AdminDemoBanner),
    );
    expect(renderBox.size, Size.zero);
  });

  testWidgets('Recent section shows at most two rows', (tester) async {
    // The "Choose business" dialog (title + search + businesses + the
    // Recent section) is taller than the 800x600 default test surface,
    // which is shorter than any real admin browser window. Give it a
    // realistic window so the dialog lays out without a viewport-only
    // overflow.
    tester.view.physicalSize = const Size(1024, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(pickerHost(seededGateway(), onSelected: (_) {}));
    await tester.pumpAndSettle();

    Future<void> openOverlay() async {
      await tester.tap(find.byKey(const Key('admin_scope_picker_trigger')));
      await tester.pumpAndSettle();
    }

    // Pick three DISTINCT scopes in sequence. Each pick closes the
    // overlay and pushes onto the session-scoped recents list.
    await openOverlay();
    await tester.tap(
      find.byKey(const Key('admin_scope_picker_business_op-sunset')),
    );
    await tester.pumpAndSettle();

    await openOverlay();
    await tester.tap(
      find.byKey(const Key('admin_scope_picker_expander_op-diner')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_scope_picker_location_loc-van')),
    );
    await tester.pumpAndSettle();

    await openOverlay();
    await tester.tap(
      find.byKey(const Key('admin_scope_picker_business_op-diner')),
    );
    await tester.pumpAndSettle();

    // Re-open: the Recent section is present but capped to the two most
    // recent distinct scopes even though three were just picked.
    await openOverlay();
    expect(find.text('Recent'), findsOneWidget);
    final recentRows = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'admin_scope_picker_recent_',
          ),
    );
    expect(recentRows, findsNWidgets(2));
  });
}

class _ScopePickerHost extends StatefulWidget {
  const _ScopePickerHost({required this.gateway, required this.onSelected});

  final OperatorLocationAdminGateway gateway;
  final void Function(AdminHierarchyScopeIntent scope) onSelected;

  @override
  State<_ScopePickerHost> createState() => _ScopePickerHostState();
}

class _ScopePickerHostState extends State<_ScopePickerHost> {
  AdminHierarchyScopeIntent? _scope;

  @override
  Widget build(BuildContext context) {
    return AdminScopePicker(
      gateway: widget.gateway,
      selectedScope: _scope,
      onSelectScope: (scope) {
        setState(() => _scope = scope);
        widget.onSelected(scope);
      },
    );
  }
}
