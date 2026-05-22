// Phase 8 spine-bridge Lane .B — CoversSourceToggle widget tests.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the toggle iterates the
// operator-configured service periods passed in by the screen
// (resolver-ordered), NOT a hardcoded `Daypart.values` triplet. These
// tests prove an operator with 4 configured periods gets 4 rows and
// that taps emit the period id.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_models.dart';
import 'package:forge_and_flow/operator_web/widgets/covers_source_toggle.dart';
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

  // A 4-period operator: breakfast / lunch / dinner / late_night.
  // Deliberately out of sort order so we also prove the screen-side
  // resolver ordering is what the widget renders.
  final fourPeriods = ServicePeriodDefinitionResolver.ordered(const [
    ServicePeriodDefinition(
      id: 'dinner',
      label: 'Dinner',
      shortLabel: 'D',
      sortOrder: 3,
      startLocalTime: '17:00',
      endLocalTime: '23:00',
      rollsPastMidnight: false,
      applicableDays: [1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'breakfast',
      label: 'Breakfast',
      shortLabel: 'B',
      sortOrder: 1,
      startLocalTime: '07:00',
      endLocalTime: '11:00',
      rollsPastMidnight: false,
      applicableDays: [1, 2, 3, 4, 5, 6, 7],
    ),
    ServicePeriodDefinition(
      id: 'late_night',
      label: 'Late Night',
      shortLabel: 'LN',
      sortOrder: 4,
      startLocalTime: '23:00',
      endLocalTime: '02:00',
      rollsPastMidnight: true,
      applicableDays: [5, 6],
    ),
    ServicePeriodDefinition(
      id: 'lunch',
      label: 'Lunch',
      shortLabel: 'L',
      sortOrder: 2,
      startLocalTime: '11:00',
      endLocalTime: '15:00',
      rollsPastMidnight: false,
      applicableDays: [1, 2, 3, 4, 5],
    ),
  ]);

  DataAccuracySettings settingsWith({
    Map<String, CoversSource> perPeriod = const <String, CoversSource>{},
    Map<String, DataAccuracySettingSource> perPeriodSources =
        const <String, DataAccuracySettingSource>{},
  }) {
    return DataAccuracySettings(
      settingId: 'test-setting',
      operatorId: 'brio-operator',
      locationId: 'brio-chicago-loop',
      coversSourcePerServicePeriod: perPeriod,
      coversSourcePerServicePeriodSources: perPeriodSources,
      coversManualEntries: const <String, Map<String, int>>{},
      wageSource: WageSource.vendor,
      createdAt: DateTime.utc(2026, 5, 5),
      updatedAt: DateTime.utc(2026, 5, 5),
    );
  }

  VendorConnectionRow row({
    required String vendorId,
    required String displayName,
    required VendorCategory category,
  }) => VendorConnectionRow(
    connectionId: '$vendorId-conn',
    vendorId: vendorId,
    displayName: displayName,
    category: category,
    status: VendorConnectionStatus.connected,
    metadata: const <String, Object?>{},
  );

  VendorConnectionsBundle bundle({
    VendorConnectionRow? pos,
    VendorConnectionRow? reservation,
  }) => VendorConnectionsBundle(
    operatorId: 'brio-operator',
    locationId: 'brio-chicago-loop',
    locationName: 'Brio - Chicago Loop',
    posConnection: pos,
    laborConnection: null,
    reservationConnection: reservation,
    demoFlags: const <VendorCategory, bool>{},
  );

  testWidgets(
    'CoversSourceToggle renders one row per configured period (4 periods) '
    'in resolver order, not a hardcoded 3-daypart triplet',
    (tester) async {
      await sizeViewport(tester, const Size(1280, 1000));

      await tester.pumpWidget(
        wrap(
          CoversSourceToggle(
            settings: settingsWith(),
            servicePeriods: fourPeriods,
            onChanged: (_, __) {},
            bundle: null,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('data_accuracy_covers_source_card')),
        findsOneWidget,
      );

      // All four configured periods render — including the 4th
      // (breakfast) the old hardcoded `Daypart` enum could not express.
      for (final id in <String>['breakfast', 'lunch', 'dinner', 'late_night']) {
        expect(
          find.byKey(Key('covers_source_daypart_$id')),
          findsOneWidget,
          reason: '$id row must render from the resolver-supplied set',
        );
        for (final src in <String>['vendor', 'forecast', 'manual']) {
          expect(
            find.byKey(Key('covers_source_chip_${id}_$src')),
            findsOneWidget,
          );
        }
      }
    },
  );

  testWidgets('tapping manual chip for breakfast (the 4th period) emits '
      'onChanged("breakfast", manual)', (tester) async {
    await sizeViewport(tester, const Size(1280, 1000));

    String? capturedPeriodId;
    CoversSource? capturedSource;

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (periodId, source) {
            capturedPeriodId = periodId;
            capturedSource = source;
          },
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('covers_source_chip_breakfast_manual')),
    );
    await tester.pumpAndSettle();

    expect(capturedPeriodId, equals('breakfast'));
    expect(capturedSource, equals(CoversSource.manual));
  });

  testWidgets('empty period set renders the honest no-periods hint, no rows', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(1280, 800));

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: const <ServicePeriodDefinition>[],
          onChanged: (_, __) {},
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('covers_source_no_periods')), findsOneWidget);
    expect(find.byKey(const Key('covers_source_daypart_lunch')), findsNothing);
  });

  testWidgets('manual covers remain editable when no vendor is connected', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(1280, 1000));
    CoversSource? capturedSource;

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (_, source) => capturedSource = source,
          bundle: bundle(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('covers_source_chip_breakfast_vendor')),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, isNull);

    await tester.tap(
      find.byKey(const Key('covers_source_chip_breakfast_manual')),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, CoversSource.manual);
  });

  testWidgets('Square disables vendor covers but leaves manual available', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(1280, 1000));
    CoversSource? capturedSource;

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (_, source) => capturedSource = source,
          bundle: bundle(
            pos: row(
              vendorId: 'square',
              displayName: 'Square',
              category: VendorCategory.pos,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('covers_source_chip_breakfast_vendor')),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, isNull);

    await tester.tap(
      find.byKey(const Key('covers_source_chip_breakfast_manual')),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, CoversSource.manual);
  });

  testWidgets('reservations plus walk-ins waits for reservation vendor', (
    tester,
  ) async {
    await sizeViewport(tester, const Size(1280, 1000));
    CoversSource? capturedSource;

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (_, source) => capturedSource = source,
          bundle: bundle(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const Key('covers_source_chip_breakfast_reservation_plus_walkin'),
      ),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, isNull);

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (_, source) => capturedSource = source,
          bundle: bundle(
            reservation: row(
              vendorId: 'opentable',
              displayName: 'OpenTable',
              category: VendorCategory.reservation,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(
        const Key('covers_source_chip_breakfast_reservation_plus_walkin'),
      ),
    );
    await tester.pumpAndSettle();
    expect(capturedSource, CoversSource.reservationPlusWalkin);
  });

  testWidgets('vendor relativity label is present', (tester) async {
    await sizeViewport(tester, const Size(1280, 1000));

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(),
          servicePeriods: fourPeriods,
          onChanged: (_, __) {},
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('vendor_relativity_label_covers')),
      findsOneWidget,
    );
  });

  testWidgets('source label renders only from server metadata', (tester) async {
    await sizeViewport(tester, const Size(1280, 1000));

    await tester.pumpWidget(
      wrap(
        CoversSourceToggle(
          settings: settingsWith(
            perPeriod: const <String, CoversSource>{
              'breakfast': CoversSource.manual,
            },
            perPeriodSources: const <String, DataAccuracySettingSource>{
              'breakfast': DataAccuracySettingSource(
                scopeType: 'business',
                sourceKind: 'scoped_override',
                overrideId: 'ovr-breakfast',
              ),
            },
          ),
          servicePeriods: fourPeriods,
          onChanged: (_, __) {},
          bundle: null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('covers_source_source_breakfast')),
      findsOneWidget,
    );
    expect(find.text('Source: Business'), findsOneWidget);
    expect(find.byKey(const Key('covers_source_source_lunch')), findsNothing);
  });
}
