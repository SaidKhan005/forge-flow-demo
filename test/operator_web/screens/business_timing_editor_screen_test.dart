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
  final List<_ProfileUpdateCall> updates = <_ProfileUpdateCall>[];

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async =>
      const <BusinessTimingProfileWriteResult>[];

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async => BusinessTimingResolutionResult(
    operatorId: 'op-1',
    locationId: locationId,
    businessDate: businessDate ?? '2026-05-01',
    ianaTimezone: 'America/Toronto',
    candidates: const <BusinessTimingResolutionCandidate>[],
  );

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
              applicableDays: p.applicableDays,
              shortLabel: p.shortLabel,
              sortOrder: p.sortOrder,
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
  }) async {
    updates.add(_ProfileUpdateCall(profileId, patch));
    return BusinessTimingProfileWriteResult(
      profileId: profileId,
      versionId: profileId,
      scopeKind: patch.scopeKind ?? 'operator',
      scopeId: patch.scopeId ?? 'op-1',
      effectiveAtBusinessDate: patch.effectiveAtBusinessDate ?? '2026-05-01',
      ianaTimezone: patch.ianaTimezone ?? 'America/Toronto',
      weekStartDay: patch.weekStartDay ?? 'monday',
      businessDayStartLocal: patch.businessDayStartLocal ?? '04:00',
      servicePeriods: (patch.servicePeriods ?? const <ServicePeriodCreate>[])
          .map(
            (p) => ServicePeriod(
              key: p.key,
              label: p.label,
              startLocal: p.startLocal,
              endLocal: p.endLocal,
              rollsPastMidnight: false,
              applicableDays: p.applicableDays,
              shortLabel: p.shortLabel,
              sortOrder: p.sortOrder,
            ),
          )
          .toList(),
      createdAt: DateTime.utc(2026, 5, 6, 18),
      updatedAt: DateTime.utc(2026, 5, 6, 18),
    );
  }

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async => throw UnimplementedError('not used in these tests');

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async => throw UnimplementedError('not used in these tests');
}

class _ProfileUpdateCall {
  const _ProfileUpdateCall(this.profileId, this.patch);

  final String profileId;
  final BusinessTimingProfilePatch patch;
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
  primaryLocationTimezone: 'America/Vancouver',
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
  testWidgets(
    'org-unit scope save writes org_unit with the selected group id',
    (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeBusinessTimingGateway();
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(
          BusinessTimingEditorScreen(
            session: session,
            gateway: gateway,
            orgUnitId: 'org-east',
            orgUnitName: 'East Region',
            orgUnitHelper: 'Region',
            locationId: 'loc-1',
            locationName: 'Downtown',
            initialScopeKind: 'org_unit',
            hierarchyPath: const <BusinessTimingHierarchyPathEntry>[
              BusinessTimingHierarchyPathEntry(
                scopeKind: 'operator',
                scopeId: 'op-1',
                name: 'Brio Restaurants',
                helper: 'Business',
              ),
              BusinessTimingHierarchyPathEntry(
                scopeKind: 'org_unit',
                scopeId: 'brand-1',
                name: 'Harbour Brand',
                helper: 'Brand',
                unitType: 'brand',
              ),
              BusinessTimingHierarchyPathEntry(
                scopeKind: 'org_unit',
                scopeId: 'org-east',
                name: 'East Region',
                helper: 'Region',
                unitType: 'region',
              ),
              BusinessTimingHierarchyPathEntry(
                scopeKind: 'org_unit',
                scopeId: 'district-1',
                name: 'Metro District',
                helper: 'District',
                unitType: 'district',
              ),
              BusinessTimingHierarchyPathEntry(
                scopeKind: 'location',
                scopeId: 'loc-1',
                name: 'Downtown',
                helper: 'Location',
              ),
            ],
          ),
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
      expect(create.scopeKind, 'org_unit');
      expect(create.scopeId, 'org-east');
      expect(find.textContaining('Harbour Brand'), findsWidgets);
      expect(find.textContaining('East Region'), findsWidgets);
      expect(find.textContaining('Metro District'), findsWidgets);
      expect(find.textContaining('Downtown'), findsWidgets);
      expect(
        find.textContaining('Groups appear after the hierarchy loads'),
        findsNothing,
      );
      expect(
        find.textContaining('tree shows the business and the location'),
        findsNothing,
      );
      expect(find.textContaining('scope_kind'), findsNothing);
    },
  );

  testWidgets('selecting location scope still writes the location id', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final gateway = _FakeBusinessTimingGateway();
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(
        BusinessTimingEditorScreen(
          session: session,
          gateway: gateway,
          orgUnitId: 'org-east',
          orgUnitName: 'East Region',
          orgUnitHelper: 'Region',
          locationId: 'loc-1',
          locationName: 'Downtown',
        ),
      ),
    );

    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_editor_scope_kind')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Just Downtown').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.pumpAndSettle();

    expect(gateway.creates, hasLength(1));
    final create = gateway.creates.single;
    expect(create.scopeKind, 'location');
    expect(create.scopeId, 'loc-1');
  });

  testWidgets('updating an existing org-unit profile keeps org_unit scope', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final gateway = _FakeBusinessTimingGateway();
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(
        BusinessTimingEditorScreen(
          session: session,
          gateway: gateway,
          orgUnitId: 'org-east',
          orgUnitName: 'East Region',
          orgUnitHelper: 'Region',
          locationId: 'loc-1',
          locationName: 'Downtown',
          existingProfile: BusinessTimingProfileWriteResult(
            profileId: 'profile-east',
            versionId: 'profile-east',
            scopeKind: 'org_unit',
            scopeId: 'org-east',
            effectiveAtBusinessDate: '2026-05-10',
            ianaTimezone: 'America/Toronto',
            weekStartDay: 'monday',
            businessDayStartLocal: '04:00',
            servicePeriods: const <ServicePeriod>[
              ServicePeriod(
                key: 'lunch',
                label: 'Lunch',
                startLocal: '11:00',
                endLocal: '15:00',
                rollsPastMidnight: false,
                sortOrder: 1,
              ),
            ],
            createdAt: DateTime.utc(2026, 5, 6, 18),
            updatedAt: DateTime.utc(2026, 5, 6, 18),
          ),
        ),
      ),
    );
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.pumpAndSettle();

    expect(gateway.creates, isEmpty);
    expect(gateway.updates, hasLength(1));
    expect(gateway.updates.single.profileId, 'profile-east');
    expect(gateway.updates.single.patch.scopeKind, 'org_unit');
    expect(gateway.updates.single.patch.scopeId, 'org-east');
  });

  testWidgets('renders the editor + service-period editor', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(wrap(BusinessTimingEditorScreen(session: session)));
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
    expect(
      find.byKey(
        const Key('operator_web_business_timing_editor_timezone_readonly'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_iana')),
      findsNothing,
    );
    expect(find.text('America/Vancouver'), findsOneWidget);
    expect(
      find.textContaining('Business account for the selected scope'),
      findsOneWidget,
    );
  });

  testWidgets('schedule mode opens with a scheduled date and labels', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(
        BusinessTimingEditorScreen(
          session: session,
          gateway: _FakeBusinessTimingGateway(),
          scheduleMode: true,
          initialEffectiveAt: DateTime(2026, 5, 21),
        ),
      ),
    );

    expect(find.text('Schedule timing change'), findsNWidgets(2));
    expect(find.text('2026-05-21'), findsOneWidget);
  });

  testWidgets('Wave 2 H-2: hierarchy tree mounts and highlights default scope', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(wrap(BusinessTimingEditorScreen(session: session)));
    // Tree itself mounts.
    expect(
      find.byKey(
        const Key('operator_web_business_timing_editor_hierarchy_tree'),
      ),
      findsOneWidget,
    );
    // Default scope is operator (Across all locations), so the
    // Business node is the current scope and gets the highlight
    // badge.
    expect(
      find.byKey(
        const Key(
          'operator_web_business_timing_editor_hierarchy_tree_node_business_current_badge',
        ),
      ),
      findsOneWidget,
    );
    // The location row should show an "Inherits from here" target
    // (it inherits from the business above) — verified via the
    // header pill copy + plain-English subtitle.
    expect(find.textContaining('Editing Business'), findsOneWidget);
    // No engineering jargon: no scope_kind=… leak.
    expect(find.textContaining('scope_kind'), findsNothing);
    expect(find.textContaining('scope_id'), findsNothing);
  });

  testWidgets('Save disabled when no gateway', (tester) async {
    await _sizeViewport(tester);
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(wrap(BusinessTimingEditorScreen(session: session)));
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
      wrap(BusinessTimingEditorScreen(session: session, gateway: gateway)),
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
    expect(create.scopeId, 'op-1');
    expect(create.ianaTimezone, 'America/Vancouver');
    expect(create.weekStartDay, 'monday');
    expect(create.servicePeriods, isNotEmpty);
    expect(
      find.byKey(const Key('operator_web_business_timing_editor_success')),
      findsOneWidget,
    );
  });

  // Slice 2.5 / Gap 28 — seed + save round-trip the three new fields.

  BusinessTimingProfileWriteResult profileWith(List<ServicePeriod> periods) =>
      BusinessTimingProfileWriteResult(
        profileId: 'profile-existing',
        versionId: 'profile-existing',
        scopeKind: 'operator',
        scopeId: 'op-1',
        effectiveAtBusinessDate: '2026-05-10',
        ianaTimezone: 'America/Toronto',
        weekStartDay: 'monday',
        businessDayStartLocal: '04:00',
        servicePeriods: periods,
        createdAt: DateTime.utc(2026, 5, 6, 18),
        updatedAt: DateTime.utc(2026, 5, 6, 18),
      );

  testWidgets(
    'seeds editor from existing profile carrying day-restricted period',
    (tester) async {
      await _sizeViewport(tester);
      final session = sessionWithRole('operator_owner');
      final gateway = _FakeBusinessTimingGateway();
      // updateProfile is what the screen calls when there is an
      // existing profile; teach the fake to capture and return it.
      await tester.pumpWidget(
        wrap(
          BusinessTimingEditorScreen(
            session: session,
            gateway: gateway,
            existingProfile: profileWith(<ServicePeriod>[
              const ServicePeriod(
                key: 'brunch',
                label: 'Weekend Brunch',
                startLocal: '10:00',
                endLocal: '14:00',
                rollsPastMidnight: false,
                applicableDays: <int>[6, 7],
                shortLabel: 'B',
                sortOrder: 1,
              ),
            ]),
          ),
        ),
      );
      // The Sat (6) + Sun (7) chips should be present in the rendered
      // editor; the rest are still rendered but unselected.
      expect(
        find.byKey(const ValueKey('service_period_editor_day_0_6')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('service_period_editor_day_0_7')),
        findsOneWidget,
      );
      // Short label field exists and surfaces the seeded value.
      expect(
        find.byKey(const ValueKey('service_period_editor_short_label_0')),
        findsOneWidget,
      );
      expect(find.text('B'), findsOneWidget);
    },
  );

  testWidgets(
    'save sends applicableDays / shortLabel / sortOrder on the wire',
    (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeBusinessTimingGateway();
      final session = sessionWithRole('operator_owner');
      await tester.pumpWidget(
        wrap(BusinessTimingEditorScreen(session: session, gateway: gateway)),
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
      // Defaults: every period applies every weekday, blank short
      // label, and sortOrder reflects the seeded order. Verifies the
      // save path serializes the new fields, not just the UI.
      for (final p in create.servicePeriods) {
        expect(p.applicableDays, <int>[1, 2, 3, 4, 5, 6, 7]);
        expect(p.shortLabel, '');
      }
      // Encoded JSON must include the new keys with camelCase.
      final json = create.toJson();
      final periodsJson = json['servicePeriods'] as List<Object?>;
      final firstPeriod = periodsJson.first as Map<String, Object?>;
      expect(firstPeriod.containsKey('applicableDays'), isTrue);
      expect(firstPeriod.containsKey('shortLabel'), isTrue);
      expect(firstPeriod.containsKey('sortOrder'), isTrue);
      expect(firstPeriod['sortOrder'], 1);
    },
  );

  testWidgets('tapping day chips before save emits filtered applicableDays', (
    tester,
  ) async {
    await _sizeViewport(tester);
    final gateway = _FakeBusinessTimingGateway();
    final session = sessionWithRole('operator_owner');
    await tester.pumpWidget(
      wrap(BusinessTimingEditorScreen(session: session, gateway: gateway)),
    );
    // Default seed has two periods (Lunch, Dinner). Restrict the
    // first to weekends only by deselecting Mon..Fri (ISO 1..5).
    for (var iso = 1; iso <= 5; iso++) {
      await tester.ensureVisible(
        find.byKey(ValueKey('service_period_editor_day_0_$iso')),
      );
      await tester.tap(
        find.byKey(ValueKey('service_period_editor_day_0_$iso')),
      );
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_editor_save')),
    );
    await tester.pumpAndSettle();
    expect(gateway.creates, hasLength(1));
    final create = gateway.creates.single;
    expect(create.servicePeriods.first.applicableDays, <int>[6, 7]);
    // Other period was untouched and still defaults to all 7.
    expect(create.servicePeriods[1].applicableDays, <int>[1, 2, 3, 4, 5, 6, 7]);
  });
}
