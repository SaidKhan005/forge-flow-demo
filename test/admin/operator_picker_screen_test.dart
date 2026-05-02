// Phase 11A.3a follow-up — Operator picker widget tests.
//
// Drives [OperatorPickerScreen] against an in-memory gateway and a
// failing-once stub gateway. Coverage:
//
//   * Both dropdowns populate from the gateway and confirm pops with
//     the resolved (operator, location) pair.
//   * Empty operator list renders the empty state (no confirm
//     affordance).
//   * Network error renders the error banner with a retry button
//     that succeeds on the second call.
//   * adminUid caches the resolved pair so subsequent picker opens
//     pre-select it (the "most-recently-touched" default).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_picker_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

class _FailOnceGateway implements OperatorLocationAdminGateway {
  _FailOnceGateway({this.failuresRemaining = 1});

  int failuresRemaining;

  @override
  Future<List<OperatorAdminBundle>> listOperators() async {
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw const OperatorLocationAdminGatewayError(
        statusCode: 503,
        errorCode: 'service_unavailable',
        message: 'admin proxy unreachable',
      );
    }
    return const <OperatorAdminBundle>[];
  }

  @override
  Future<OperatorAdminBundle> onboardOperator(
    OperatorOnboardCommand command,
  ) =>
      throw UnimplementedError();

  @override
  Future<OperatorAdminRecord> patchOperator(OperatorPatchCommand command) =>
      throw UnimplementedError();

  @override
  Future<OperatorAdminRecord> suspendOperator(String operatorId) =>
      throw UnimplementedError();

  @override
  Future<OperatorAdminRecord> reactivateOperator(String operatorId) =>
      throw UnimplementedError();

  @override
  Future<LocationAdminRecord> addLocation(LocationCreateCommand command) =>
      throw UnimplementedError();

  @override
  Future<LocationAdminRecord> patchLocation(LocationPatchCommand command) =>
      throw UnimplementedError();

  @override
  Future<void> removeLocation({
    required String operatorId,
    required String locationId,
  }) =>
      throw UnimplementedError();
}

void main() {
  setUp(() {
    OperatorPickerScreen.clearCacheForTesting();
  });

  OperatorAdminBundle bundle({
    required String operatorId,
    required String name,
    required String? primaryLocationId,
    required List<LocationAdminRecord> locations,
  }) {
    return OperatorAdminBundle(
      operator: OperatorAdminRecord(
        operatorId: operatorId,
        businessName: name,
        ownerEmail: 'owner@$operatorId.test',
        subscriptionTier: 'launch',
        preferredCurrency: 'CAD',
        primaryLocationId: primaryLocationId,
        suspendedAt: null,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      locations: locations,
    );
  }

  LocationAdminRecord loc({
    required String locationId,
    required String operatorId,
    required String name,
  }) =>
      LocationAdminRecord(
        locationId: locationId,
        operatorId: operatorId,
        name: name,
        address: '',
        timezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );

  // Mounts a host that pushes [child] when the user taps the host
  // button, and forwards the popped result back to the test.
  Widget pickerHost(
    OperatorPickerScreen child, {
    required void Function(OperatorPickerResult? result) onPopped,
  }) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open_picker_host_button'),
              onPressed: () async {
                final result = await Navigator.of(context)
                    .push<OperatorPickerResult?>(
                  MaterialPageRoute<OperatorPickerResult?>(
                    builder: (_) => child,
                  ),
                );
                onPopped(result);
              },
              child: const Text('Open picker'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'both dropdowns populate from the gateway and confirm pops the '
    'resolved (operator, location) pair',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          bundle(
            operatorId: 'op-diner',
            name: 'Demo Diner',
            primaryLocationId: 'loc-toronto',
            locations: <LocationAdminRecord>[
              loc(
                locationId: 'loc-toronto',
                operatorId: 'op-diner',
                name: 'Toronto Yorkville',
              ),
              loc(
                locationId: 'loc-montreal',
                operatorId: 'op-diner',
                name: 'Montreal Plateau',
              ),
            ],
          ),
          bundle(
            operatorId: 'op-cafe',
            name: 'Sunset Cafe',
            primaryLocationId: 'loc-nyc',
            locations: <LocationAdminRecord>[
              loc(
                locationId: 'loc-nyc',
                operatorId: 'op-cafe',
                name: 'NYC Williamsburg',
              ),
            ],
          ),
        ],
      );
      OperatorPickerResult? popped;
      var poppedCalls = 0;
      await tester.pumpWidget(
        pickerHost(
          OperatorPickerScreen(gateway: gateway),
          onPopped: (r) {
            popped = r;
            poppedCalls++;
          },
        ),
      );
      await tester.tap(find.byKey(const Key('open_picker_host_button')));
      await tester.pumpAndSettle();

      // Picker is mounted on a fresh route.
      expect(
        find.byKey(const Key('admin_operator_picker_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_operator_picker_operator_dropdown'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_operator_picker_location_dropdown'),
        ),
        findsOneWidget,
      );

      // Confirm starts disabled (no selection yet).
      final confirmFinder =
          find.byKey(const Key('admin_operator_picker_confirm'));
      expect(
        tester.widget<FilledButton>(confirmFinder).onPressed,
        isNull,
        reason: 'confirm must be disabled before any selection is made',
      );

      // Open the operator dropdown and pick "Sunset Cafe".
      await tester.tap(find.byKey(
        const Key('admin_operator_picker_operator_dropdown'),
      ));
      await tester.pumpAndSettle();
      // Both fixture operators are visible in the open menu.
      expect(find.text('Demo Diner'), findsWidgets);
      expect(find.text('Sunset Cafe'), findsWidgets);
      await tester.tap(find.text('Sunset Cafe').last);
      await tester.pumpAndSettle();

      // Location auto-selected to the operator's primary location
      // ("NYC Williamsburg") — the dropdown shows that label.
      expect(find.text('NYC Williamsburg'), findsWidgets);
      // Confirm enables once both dropdowns have values.
      expect(
        tester.widget<FilledButton>(confirmFinder).onPressed,
        isNotNull,
      );

      // Tap confirm.
      await tester.ensureVisible(confirmFinder);
      await tester.pumpAndSettle();
      await tester.tap(confirmFinder);
      await tester.pumpAndSettle();

      expect(poppedCalls, 1);
      expect(popped, isNotNull);
      expect(popped!.operatorId, equals('op-cafe'));
      expect(popped!.locationId, equals('loc-nyc'));
      expect(popped!.operatorBusinessName, equals('Sunset Cafe'));
      expect(popped!.locationName, equals('NYC Williamsburg'));
    },
  );

  testWidgets('empty operator list renders the empty state', (tester) async {
    final gateway = InMemoryOperatorLocationAdminGateway();
    OperatorPickerResult? popped;
    await tester.pumpWidget(
      pickerHost(
        OperatorPickerScreen(gateway: gateway),
        onPopped: (r) => popped = r,
      ),
    );
    await tester.tap(find.byKey(const Key('open_picker_host_button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_operator_picker_empty')),
      findsOneWidget,
    );
    // Confirm affordance is absent because there is nothing to pick.
    expect(
      find.byKey(const Key('admin_operator_picker_confirm')),
      findsNothing,
    );

    // Cancelling the empty state pops null.
    await tester.tap(find.byKey(
      const Key('admin_operator_picker_empty_cancel'),
    ));
    await tester.pumpAndSettle();
    expect(popped, isNull);
  });

  testWidgets(
    'network error renders the error banner with a retry that '
    'recovers on the next call',
    (tester) async {
      final gateway = _FailOnceGateway(failuresRemaining: 1);
      await tester.pumpWidget(
        pickerHost(
          OperatorPickerScreen(gateway: gateway),
          onPopped: (_) {},
        ),
      );
      await tester.tap(find.byKey(const Key('open_picker_host_button')));
      await tester.pumpAndSettle();

      // First load failed → banner renders with retry.
      expect(
        find.byKey(const Key('admin_operator_picker_error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_retry')),
        findsOneWidget,
      );

      // Tap retry — gateway now returns an empty list.
      await tester.tap(find.byKey(
        const Key('admin_operator_picker_retry'),
      ));
      await tester.pumpAndSettle();

      // Banner cleared, empty state renders instead.
      expect(
        find.byKey(const Key('admin_operator_picker_error')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_operator_picker_empty')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'adminUid cache pre-selects the most-recently-touched pair on '
    'subsequent opens',
    (tester) async {
      final gateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[
          bundle(
            operatorId: 'op-diner',
            name: 'Demo Diner',
            primaryLocationId: 'loc-toronto',
            locations: <LocationAdminRecord>[
              loc(
                locationId: 'loc-toronto',
                operatorId: 'op-diner',
                name: 'Toronto Yorkville',
              ),
            ],
          ),
        ],
      );

      // Seed the cache directly via a confirm round-trip on the
      // first push so the second push starts pre-selected.
      OperatorPickerResult? popped;
      await tester.pumpWidget(
        pickerHost(
          OperatorPickerScreen(
            gateway: gateway,
            adminUid: 'admin-uid-7',
          ),
          onPopped: (r) => popped = r,
        ),
      );
      await tester.tap(find.byKey(const Key('open_picker_host_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(
        const Key('admin_operator_picker_operator_dropdown'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Diner').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_operator_picker_confirm')),
      );
      await tester.pumpAndSettle();
      expect(popped, isNotNull);
      expect(
        OperatorPickerScreen.cachedFor('admin-uid-7')?.operatorId,
        equals('op-diner'),
      );

      // Push the picker again. The cached pair pre-selects so
      // confirm enables immediately, without re-touching either
      // dropdown.
      await tester.tap(find.byKey(const Key('open_picker_host_button')));
      await tester.pumpAndSettle();
      final confirmFinder =
          find.byKey(const Key('admin_operator_picker_confirm'));
      expect(
        tester.widget<FilledButton>(confirmFinder).onPressed,
        isNotNull,
        reason:
            'confirm must enable on second open because the cache hit '
            'pre-selected both dropdowns',
      );
    },
  );
}
