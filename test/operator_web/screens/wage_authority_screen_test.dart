// Phase 8 W5.A.2 - Wage authority screen widget tests.
//
// Coverage:
//   * empty state for an operator with no rows
//   * rows render grouped by labor_bucket
//   * add-row form fires upsert through the gateway with a fresh idem key
//   * edit-row fires upsert with the same role_name (idempotent)
//   * delete fires delete after confirm
//   * delete failure rolls back the optimistic remove + surfaces error
//   * read-only mode for non-operator-write actors hides edit/delete

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/wage_role_row_record.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/wage_authority_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWithRoles(List<String> roles) =>
      OperatorWebSession(
        uid: 'demo-uid',
        email: 'alex@brio-restaurants.com',
        displayName: 'Alex Morrison',
        operatorId: 'demo-operator',
        businessName: 'Brio Restaurants',
        primaryLocationId: 'demo-location',
        primaryLocationName: 'Brio Main Street',
        roles: roles,
        mfaEnrolled: false,
      );

  WageRoleRowRecord recordFor({
    required String id,
    required String roleName,
    required String laborBucket,
    double hourlyRate = 18.50,
    double weightedHours = 32.0,
    String operatorId = 'demo-operator',
    String locationId = 'demo-location',
    String restaurantId = 'demo-location',
    String? vendorId,
    String? vendorRoleId,
    String? jobCode,
    bool isActive = true,
  }) {
    final now = DateTime.utc(2026, 5, 7, 12);
    return WageRoleRowRecord(
      wageRoleRowId: id,
      operatorId: operatorId,
      locationId: locationId,
      restaurantId: restaurantId,
      roleName: roleName,
      laborBucket: laborBucket,
      hourlyRate: hourlyRate,
      weightedHours: weightedHours,
      jobCode: jobCode,
      vendorId: vendorId,
      vendorRoleId: vendorRoleId,
      source: WageRoleRowSource.operatorManual,
      isActive: isActive,
      effectiveAt: now,
      metadata: const <String, Object?>{},
      createdAt: now,
      updatedAt: now,
    );
  }

  group('WageAuthorityScreen', () {
    testWidgets('renders empty state for an operator with no rows',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
      )));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('wage_authority_screen')),
        findsOneWidget,
      );
      // Each bucket renders an empty placeholder.
      expect(find.byKey(const Key('wage_authority_empty_foh')), findsOneWidget);
      expect(find.byKey(const Key('wage_authority_empty_boh')), findsOneWidget);
      expect(
        find.byKey(const Key('wage_authority_empty_manager')),
        findsOneWidget,
      );
    });

    testWidgets('renders rows grouped by labor_bucket', (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway()
        ..seed(<WageRoleRowRecord>[
          recordFor(id: 'row-foh', roleName: 'Server', laborBucket: 'foh'),
          recordFor(id: 'row-boh', roleName: 'Line cook', laborBucket: 'boh'),
          recordFor(
            id: 'row-mgr',
            roleName: 'GM',
            laborBucket: 'manager',
            hourlyRate: 32.50,
          ),
        ]);
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
      )));
      await tester.pumpAndSettle();
      // Each row id is rendered.
      expect(
        find.byKey(const Key('wage_authority_row_display_row-foh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('wage_authority_row_display_row-boh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('wage_authority_row_display_row-mgr')),
        findsOneWidget,
      );
      // FOH bucket section contains the FOH row.
      expect(
        find.descendant(
          of: find.byKey(const Key('wage_authority_bucket_foh')),
          matching: find.byKey(const Key('wage_authority_row_display_row-foh')),
        ),
        findsOneWidget,
      );
      // BOH bucket section contains the BOH row.
      expect(
        find.descendant(
          of: find.byKey(const Key('wage_authority_bucket_boh')),
          matching: find.byKey(const Key('wage_authority_row_display_row-boh')),
        ),
        findsOneWidget,
      );
      // Management bucket section contains the manager row.
      expect(
        find.descendant(
          of: find.byKey(const Key('wage_authority_bucket_manager')),
          matching: find.byKey(const Key('wage_authority_row_display_row-mgr')),
        ),
        findsOneWidget,
      );
    });

    testWidgets('add-row form fires upsert through the gateway with idem key',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final gateway = _FakeGateway();
      var idemSeq = 0;
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
        idempotencyKeyFactory: () {
          idemSeq += 1;
          return 'test-idem-$idemSeq';
        },
      )));
      await tester.pumpAndSettle();
      // Open add-row form for FOH.
      await tester.tap(find.byKey(const Key('wage_authority_add_button_foh')));
      await tester.pumpAndSettle();
      // Fill the form.
      await tester.enterText(
        find.byKey(const Key('wage_authority_form_role_name_add')),
        'Server',
      );
      await tester.enterText(
        find.byKey(const Key('wage_authority_form_hourly_rate_add')),
        '18.50',
      );
      await tester.enterText(
        find.byKey(const Key('wage_authority_form_weighted_hours_add')),
        '32',
      );
      await tester.tap(find.byKey(const Key('wage_authority_form_save_add')));
      await tester.pumpAndSettle();
      expect(gateway.upsertCalls, hasLength(1));
      final call = gateway.upsertCalls.single;
      expect(call.request.roleName, 'Server');
      expect(call.request.laborBucket, 'foh');
      expect(call.request.hourlyRate, 18.5);
      expect(call.request.weightedHours, 32);
      expect(call.idempotencyKey, 'test-idem-1');
      // Restaurant_id falls back to the location id when blank.
      expect(call.request.restaurantId, session.primaryLocationId);
    });

    testWidgets(
        'edit-row fires upsert with the same role_name (idempotent)',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final existing = recordFor(
        id: 'row-foh',
        roleName: 'Server',
        laborBucket: 'foh',
        hourlyRate: 18.50,
      );
      final gateway = _FakeGateway()..seed(<WageRoleRowRecord>[existing]);
      var idemSeq = 0;
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
        idempotencyKeyFactory: () {
          idemSeq += 1;
          return 'test-idem-$idemSeq';
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('wage_authority_row_edit_btn_row-foh')),
      );
      await tester.pumpAndSettle();
      // Update the rate from 18.50 → 19.50, role_name unchanged.
      await tester.enterText(
        find.byKey(
          const Key('wage_authority_form_hourly_rate_edit_row-foh'),
        ),
        '19.50',
      );
      await tester.tap(
        find.byKey(const Key('wage_authority_form_save_edit_row-foh')),
      );
      await tester.pumpAndSettle();
      expect(gateway.upsertCalls, hasLength(1));
      final call = gateway.upsertCalls.single;
      // Same natural-key fields → server-side idempotent.
      expect(call.request.roleName, 'Server');
      expect(call.request.restaurantId, existing.restaurantId);
      expect(call.request.laborBucket, 'foh');
      expect(call.request.hourlyRate, 19.5);
      expect(call.idempotencyKey, 'test-idem-1');
    });

    testWidgets('delete fires through the gateway after confirm',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final existing = recordFor(
        id: 'row-foh',
        roleName: 'Server',
        laborBucket: 'foh',
      );
      final gateway = _FakeGateway()..seed(<WageRoleRowRecord>[existing]);
      var idemSeq = 0;
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
        idempotencyKeyFactory: () {
          idemSeq += 1;
          return 'test-idem-del-$idemSeq';
        },
      )));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('wage_authority_row_delete_btn_row-foh')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('wage_authority_delete_confirm_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('wage_authority_delete_confirm')));
      await tester.pumpAndSettle();
      expect(gateway.deleteCalls, hasLength(1));
      final call = gateway.deleteCalls.single;
      expect(call.wageRoleRowId, 'row-foh');
      expect(call.idempotencyKey, 'test-idem-del-1');
      // Optimistic remove succeeded - row no longer rendered.
      expect(
        find.byKey(const Key('wage_authority_row_display_row-foh')),
        findsNothing,
      );
    });

    testWidgets('delete failure rolls back + shows error snackbar',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['operator_owner']);
      final existing = recordFor(
        id: 'row-foh',
        roleName: 'Server',
        laborBucket: 'foh',
      );
      final gateway = _FakeGateway()
        ..seed(<WageRoleRowRecord>[existing])
        ..deleteShouldThrow = true;
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
        idempotencyKeyFactory: () => 'test-idem-1',
      )));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('wage_authority_row_delete_btn_row-foh')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('wage_authority_delete_confirm')));
      await tester.pump(); // optimistic remove
      await tester.pumpAndSettle();
      // Row is back after rollback.
      expect(
        find.byKey(const Key('wage_authority_row_display_row-foh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('wage_authority_delete_error_snackbar')),
        findsOneWidget,
      );
    });

    testWidgets('non-operator-write actor sees the read-only banner',
        (tester) async {
      await sizeViewport(tester, const Size(1280, 900));
      final session = sessionWithRoles(<String>['location_manager']);
      final existing = recordFor(
        id: 'row-foh',
        roleName: 'Server',
        laborBucket: 'foh',
      );
      final gateway = _FakeGateway()..seed(<WageRoleRowRecord>[existing]);
      await tester.pumpWidget(wrap(WageAuthorityScreen(
        session: session,
        locationId: session.primaryLocationId,
        locationName: session.primaryLocationName,
        gateway: gateway,
      )));
      await tester.pumpAndSettle();
      // Banner shown.
      expect(
        find.byKey(const Key('wage_authority_readonly_banner')),
        findsOneWidget,
      );
      // No add-button; no edit/delete on the row.
      expect(
        find.byKey(const Key('wage_authority_add_button_foh')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('wage_authority_row_edit_btn_row-foh')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('wage_authority_row_delete_btn_row-foh')),
        findsNothing,
      );
      // Row itself still renders (read-only).
      expect(
        find.byKey(const Key('wage_authority_row_display_row-foh')),
        findsOneWidget,
      );
    });

    testWidgets(
      'renders HP #11 hierarchy scope notice (selected scope, inherited '
      'from, effective value) at the top of the screen',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 900));
        final session = sessionWithRoles(<String>['operator_owner']);
        final gateway = _FakeGateway()
          ..seed(<WageRoleRowRecord>[
            recordFor(id: 'row-foh', roleName: 'Server', laborBucket: 'foh'),
          ]);
        await tester.pumpWidget(wrap(WageAuthorityScreen(
          session: session,
          locationId: session.primaryLocationId,
          locationName: session.primaryLocationName,
          gateway: gateway,
        )));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('wage_authority_hierarchy_scope')),
          findsOneWidget,
        );
        // The triple is present.
        expect(
          find.byKey(
            const Key('wage_authority_hierarchy_scope_selected_row'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('wage_authority_hierarchy_scope_inherited_row'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('wage_authority_hierarchy_scope_effective_row'),
          ),
          findsOneWidget,
        );
        // Backend-only carve-out explainer renders for forward-looking
        // inheritance coverage.
        expect(
          find.byKey(
            const Key('wage_authority_hierarchy_scope_backend_only'),
          ),
          findsOneWidget,
        );
        // Plain-English copy (no engineering jargon like scope_id=…).
        expect(
          find.textContaining('Set here. Does not inherit'),
          findsOneWidget,
        );
        expect(find.text('Location'), findsOneWidget);
      },
    );
  });
}

class _UpsertCall {
  const _UpsertCall({required this.request, required this.idempotencyKey});

  final WageRoleRowUpsert request;
  final String idempotencyKey;
}

class _DeleteCall {
  const _DeleteCall({
    required this.wageRoleRowId,
    required this.idempotencyKey,
  });

  final String wageRoleRowId;
  final String idempotencyKey;
}

class _FakeGateway implements OperatorWebWageAuthorityGateway {
  final List<WageRoleRowRecord> _rows = <WageRoleRowRecord>[];
  final List<_UpsertCall> upsertCalls = <_UpsertCall>[];
  final List<_DeleteCall> deleteCalls = <_DeleteCall>[];
  bool upsertShouldThrow = false;
  bool deleteShouldThrow = false;

  void seed(Iterable<WageRoleRowRecord> rows) {
    _rows
      ..clear()
      ..addAll(rows);
  }

  @override
  Future<List<WageRoleRowRecord>> list({
    required String operatorId,
    required String locationId,
  }) async {
    return List<WageRoleRowRecord>.unmodifiable(
      _rows.where((r) =>
          r.operatorId == operatorId &&
          r.locationId == locationId &&
          r.isActive),
    );
  }

  @override
  Future<WageRoleRowRecord> upsert({
    required WageRoleRowUpsert request,
    required String idempotencyKey,
  }) async {
    upsertCalls.add(_UpsertCall(
      request: request,
      idempotencyKey: idempotencyKey,
    ));
    if (upsertShouldThrow) {
      throw const WageAuthorityGatewayException(
        code: 'simulated_failure',
        message: 'fake gateway failure',
      );
    }
    final now = DateTime.utc(2026, 5, 7, 13);
    final id = 'fake-${upsertCalls.length}';
    final record = WageRoleRowRecord(
      wageRoleRowId: id,
      operatorId: 'demo-operator',
      locationId: 'demo-location',
      restaurantId: request.restaurantId,
      roleName: request.roleName,
      laborBucket: request.laborBucket,
      hourlyRate: request.hourlyRate,
      weightedHours: request.weightedHours,
      jobCode: request.jobCode,
      vendorId: request.vendorId,
      vendorRoleId: request.vendorRoleId,
      source: request.source ?? WageRoleRowSource.operatorManual,
      isActive: true,
      effectiveAt: now,
      metadata: request.metadata,
      createdAt: now,
      updatedAt: now,
    );
    _rows.add(record);
    return record;
  }

  @override
  Future<bool> delete({
    required String wageRoleRowId,
    required String idempotencyKey,
  }) async {
    deleteCalls.add(_DeleteCall(
      wageRoleRowId: wageRoleRowId,
      idempotencyKey: idempotencyKey,
    ));
    if (deleteShouldThrow) {
      throw const WageAuthorityGatewayException(
        code: 'simulated_failure',
        message: 'fake gateway failure',
      );
    }
    _rows.removeWhere((r) => r.wageRoleRowId == wageRoleRowId);
    return true;
  }
}
