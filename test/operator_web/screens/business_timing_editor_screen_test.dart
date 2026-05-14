// Phase 11W.7 / Wave A2 - BusinessTimingEditorScreen tests.
//
// Cover the round-trip from screen state to gateway calls + the
// validation surface (Save disabled while invalid). The deeper
// validation rules live in service_period_editor_test.dart and the
// gateway contract lives in web_business_timing_gateway_test.dart;
// this file only exercises the screen-to-gateway seam.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/business_timing_editor_screen.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

class _FakeBusinessTimingGateway implements WebBusinessTimingGateway {
  final List<BusinessTimingProfileCreate> creates =
      <BusinessTimingProfileCreate>[];

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async =>
      const <BusinessTimingProfileWriteResult>[];

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    creates.add(request);
    return BusinessTimingProfileWriteResult(
      profileId: 'profile-new',
      versionId: 'profile-new',
      scopeKind: request.scopeKind,
      scopeId: request.scopeId,
      effectiveAtBusinessDate: request.effectiveAtBusinessDate,
      ianaTimezone: request.ianaTimezone,
      weekStartDay: request.weekStartDay,
      businessDayStartLocal: request.businessDayStartLocal,
      servicePeriods: request.servicePeriods
          .map(
            (p) => ServicePeriod(
              key: p.key,
              label: p.label,
              startLocal: p.startLocal,
              endLocal: p.endLocal,
              rollsPastMidnight: false,
            ),
          )
          .toList(),
      createdAt: DateTime.utc(2026, 5, 6, 18),
      updatedAt: DateTime.utc(2026, 5, 6, 18),
    );
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async =>
      throw UnimplementedError('not used in these tests');

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async =>
      throw UnimplementedError('not used in these tests');

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async =>
      throw UnimplementedError('not used in these tests');
}

OperatorWebSession sessionWithRole(String role) => OperatorWebSession(
      uid: 'uid-$role',
      email: 'alex@brio-restaurants.com',
      displayName: 'Alex Morrison',
      operatorId: 'op-1',
      businessName: 'Brio Restaurants',
      primaryLocationId: 'loc-1',
      primaryLocationName: 'Brio Main',
      roles: <String>[role],
      weekStartDay: 'monday',
      rolloverHour: 4,
    );

Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.themeData,
      home: Scaffold(body: child),
    );

Future<void> _sizeViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

void main() {
  testWidgets('renders the editor + service-period editor', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(BusinessTimingEditorScreen(session: session)),
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_periods')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
      findsOneWidget,
    );
  });

  testWidgets('Wave 2 H-2: hierarchy tree mounts and highlights default scope',
      (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(BusinessTimingEditorScreen(session: session)),
    );
    // Tree itself mounts.
    expect(
      find.byKey(const Key(
        'operator_web_business_timing_editor_hierarchy_tree',
      )),
      findsOneWidget,
    );
    // Default scope is operator (Across all locations), so the
    // Business node is the current scope and gets the highlight
    // badge.
    expect(
      find.byKey(const Key(
        'operator_web_business_timing_editor_hierarchy_tree_node_business_current_badge',
      )),
      findsOneWidget,
    );
    // The location row should show an "Inherits from here" target
    // (it inherits from the business above) — verified via the
    // header pill copy + plain-English subtitle.
    expect(
      find.textContaining('Editing Business'),
      findsOneWidget,
    );
    // No engineering jargon: no scope_kind=… leak.
    expect(find.textContaining('scope_kind'), findsNothing);
    expect(find.textContaining('scope_id'), findsNothing);
  });

  testWidgets('Save disabled when no gateway', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(BusinessTimingEditorScreen(session: session)),
    );
    final save = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('Save disabled when no edit permission', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('location_manager');
    await tester.pumpWidget(
      wrap(
        BusinessTimingEditorScreen(
          session: session,
          gateway: _FakeBusinessTimingGateway(),
        ),
      ),
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_readonly')),
      findsOneWidget,
    );
    final save = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    expect(save.onPressed, isNull);
  });

  testWidgets('happy-path save POSTs profile to gateway', (tester) async {
    await _sizeViewport(tester);
    final gateway = _FakeBusinessTimingGateway();
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(
        BusinessTimingEditorScreen(session: session, gateway: gateway),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.pumpAndSettle();
    expect(gateway.creates, hasLength(1));
    final create = gateway.creates.single;
    expect(create.scopeKind, 'operator');
    expect(create.weekStartDay, 'monday');
    expect(create.servicePeriods, isNotEmpty);
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_success')),
      findsOneWidget,
    );
  });
}
