// Phase 11W.7 / Wave A2 - Service period editor tests.
//
// Pin every binding rule from business_timing_live_plan.md:
//   1. 1-4 service periods (rejects 0; rejects 5).
//   2. Quarter-hour boundaries (rejects 5-min increments).
//   3. No overlap on same business date.
//   4. Max one period rolls past midnight.
//
// Validates both the pure validator (validateServicePeriods) and
// the widget surface (ServicePeriodEditor + ServicePeriodEditorController).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/service_period_editor.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  group('validateServicePeriods (pure validator)', () {
    test('empty list rejected with invalid_period_count', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[]);
      expect(result.isValid, isFalse);
      expect(result.errors.first.code, 'invalid_period_count');
    });

    test('5+ periods rejected with invalid_period_count', () {
      final result = validateServicePeriods(<ServicePeriodDraft>[
        for (var i = 0; i < 5; i++)
          ServicePeriodDraft(
            key: 'period_$i',
            label: 'Period $i',
            startLocal: '${(i * 4).toString().padLeft(2, '0')}:00',
            endLocal: '${((i * 4) + 2).toString().padLeft(2, '0')}:00',
          ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'invalid_period_count'),
        isTrue,
      );
    });

    test('5-minute boundary rejected with invalid_quarter_hour_boundary', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:05',
          endLocal: '15:00',
        ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'invalid_quarter_hour_boundary'),
        isTrue,
      );
    });

    test('overlap rejected with service_period_overlap', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
        ),
        ServicePeriodDraft(
          key: 'overlap',
          label: 'Overlap',
          startLocal: '14:00',
          endLocal: '16:00',
        ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'service_period_overlap'),
        isTrue,
      );
    });

    test('two past-midnight rejected with multiple_past_midnight_periods', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'late_one',
          label: 'Late one',
          startLocal: '22:00',
          endLocal: '01:00',
        ),
        ServicePeriodDraft(
          key: 'late_two',
          label: 'Late two',
          startLocal: '02:00',
          endLocal: '03:00',
        ),
        ServicePeriodDraft(
          key: 'late_three',
          label: 'Late three',
          startLocal: '20:00',
          endLocal: '02:00',
        ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'multiple_past_midnight_periods'),
        isTrue,
      );
    });

    test('1-4 quarter-hour periods accepted', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'breakfast',
          label: 'Breakfast',
          startLocal: '07:00',
          endLocal: '11:00',
        ),
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:15',
          endLocal: '15:00',
        ),
        ServicePeriodDraft(
          key: 'dinner',
          label: 'Dinner',
          startLocal: '17:00',
          endLocal: '22:00',
        ),
        ServicePeriodDraft(
          key: 'late',
          label: 'Late night',
          startLocal: '22:15',
          endLocal: '01:30',
        ),
      ]);
      expect(result.errors, isEmpty);
      expect(result.isValid, isTrue);
    });

    test('one past-midnight period accepted with informational warning', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'dinner',
          label: 'Dinner',
          startLocal: '17:00',
          endLocal: '22:00',
        ),
        ServicePeriodDraft(
          key: 'late',
          label: 'Late night',
          startLocal: '22:00',
          endLocal: '01:00',
        ),
      ]);
      expect(result.isValid, isTrue);
      expect(result.warnings, isNotEmpty);
    });

    test('duplicate key rejected with duplicate_service_period_key', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '13:00',
        ),
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Late lunch',
          startLocal: '13:30',
          endLocal: '15:00',
        ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'duplicate_service_period_key'),
        isTrue,
      );
    });

    test(
      'uppercase / camelCase key rejected with invalid_service_period_key',
      () {
        final result = validateServicePeriods(const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'LunchTime',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '13:00',
          ),
        ]);
        expect(result.isValid, isFalse);
        expect(
          result.errors.any((e) => e.code == 'invalid_service_period_key'),
          isTrue,
        );
      },
    );

    test(
      'day-start inside period rejected with business_day_start_inside_period',
      () {
        final result = validateServicePeriods(
          const <ServicePeriodDraft>[
            ServicePeriodDraft(
              key: 'lunch',
              label: 'Lunch',
              startLocal: '11:00',
              endLocal: '15:00',
            ),
          ],
          // Day starts at 12:00 which lands inside the lunch period.
          businessDayStartLocal: '12:00',
        );
        expect(result.isValid, isFalse);
        expect(
          result.errors.any(
            (e) => e.code == 'business_day_start_inside_period',
          ),
          isTrue,
        );
      },
    );

    test('day-start outside any period accepts the profile', () {
      final result = validateServicePeriods(
        const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'dinner',
            label: 'Dinner',
            startLocal: '17:00',
            endLocal: '22:00',
          ),
        ],
        // Day starts at 04:00, far outside dinner's 17:00 to 22:00.
        businessDayStartLocal: '04:00',
      );
      expect(result.errors, isEmpty);
      expect(result.isValid, isTrue);
    });

    test('day-start inside a past-midnight period also rejected', () {
      final result = validateServicePeriods(
        const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'late',
            label: 'Late night',
            startLocal: '22:00',
            endLocal: '02:00',
          ),
        ],
        // 01:00 is inside the rolling-past-midnight window 22:00 to 02:00.
        businessDayStartLocal: '01:00',
      );
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'business_day_start_inside_period'),
        isTrue,
      );
    });

    // Slice 2.5 / Gap 28 — `applicableDays` validation surface.
    test('empty applicableDays rejected with invalid_applicable_days', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
          applicableDays: <int>[],
        ),
      ]);
      expect(result.isValid, isFalse);
      expect(
        result.errors.any((e) => e.code == 'invalid_applicable_days'),
        isTrue,
      );
    });

    test(
      'out-of-range applicableDays rejected with invalid_applicable_days',
      () {
        final result = validateServicePeriods(const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
            applicableDays: <int>[0, 8],
          ),
        ]);
        expect(result.isValid, isFalse);
        expect(
          result.errors.any((e) => e.code == 'invalid_applicable_days'),
          isTrue,
        );
      },
    );

    test('weekend-only Sat/Sun applicableDays accepted', () {
      final result = validateServicePeriods(const <ServicePeriodDraft>[
        ServicePeriodDraft(
          key: 'brunch',
          label: 'Weekend Brunch',
          startLocal: '10:00',
          endLocal: '14:00',
          applicableDays: <int>[6, 7],
        ),
      ]);
      expect(result.isValid, isTrue);
    });
  });

  // Slice 2.5 / Gap 28 — pure value-object behavior on the new fields.
  group('ServicePeriodDraft (Slice 2.5 fields)', () {
    test(
      'default constructor seeds all 7 weekdays + empty short label + 1 sort',
      () {
        const draft = ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
        );
        expect(draft.applicableDays, <int>[1, 2, 3, 4, 5, 6, 7]);
        expect(draft.shortLabel, '');
        expect(draft.sortOrder, 1);
      },
    );

    test(
      'copyWith round-trips the three new fields without mutating others',
      () {
        const original = ServicePeriodDraft(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
        );
        final next = original.copyWith(
          applicableDays: const <int>[6, 7],
          shortLabel: 'L',
          sortOrder: 3,
        );
        expect(next.key, original.key);
        expect(next.label, original.label);
        expect(next.startLocal, original.startLocal);
        expect(next.endLocal, original.endLocal);
        expect(next.applicableDays, <int>[6, 7]);
        expect(next.shortLabel, 'L');
        expect(next.sortOrder, 3);
      },
    );

    test('copyWith leaving new fields null preserves the originals', () {
      const original = ServicePeriodDraft(
        key: 'brunch',
        label: 'Brunch',
        startLocal: '10:00',
        endLocal: '14:00',
        applicableDays: <int>[6, 7],
        shortLabel: 'B',
        sortOrder: 2,
      );
      final next = original.copyWith(label: 'Weekend Brunch');
      expect(next.label, 'Weekend Brunch');
      expect(next.applicableDays, <int>[6, 7]);
      expect(next.shortLabel, 'B');
      expect(next.sortOrder, 2);
    });
  });

  group('ServicePeriodEditorController (Slice 2.5 defaults)', () {
    test('addPeriod defaults applicableDays to all 7 weekdays', () {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      );
      controller.addPeriod();
      expect(controller.periods.last.applicableDays, <int>[
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      expect(controller.periods.last.shortLabel, '');
    });

    test('addPeriod defaults sortOrder to next slot number', () {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      );
      controller.addPeriod();
      expect(controller.periods.last.sortOrder, 2);
    });

    test('updateAt with copyWith propagates day-chip toggles', () {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'brunch',
            label: 'Brunch',
            startLocal: '10:00',
            endLocal: '14:00',
          ),
        ],
      );
      controller.updateAt(
        0,
        controller.periods[0].copyWith(applicableDays: const <int>[6, 7]),
      );
      expect(controller.periods[0].applicableDays, <int>[6, 7]);
    });
  });

  group('ServicePeriodEditor widget', () {
    Widget wrap(Widget child) => MaterialApp(
      theme: AppTheme.themeData,
      home: Scaffold(body: child),
    );

    testWidgets('renders one row per draft + the Add button', (tester) async {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(ServicePeriodEditor(controller: controller)),
      );
      expect(find.byKey(const Key('service_period_editor')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('service_period_editor_row_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('service_period_editor_add')),
        findsOneWidget,
      );
    });

    testWidgets('Add button disabled at four periods', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'a',
            label: 'A',
            startLocal: '00:00',
            endLocal: '05:00',
          ),
          ServicePeriodDraft(
            key: 'b',
            label: 'B',
            startLocal: '06:00',
            endLocal: '11:00',
          ),
          ServicePeriodDraft(
            key: 'c',
            label: 'C',
            startLocal: '12:00',
            endLocal: '17:00',
          ),
          ServicePeriodDraft(
            key: 'd',
            label: 'D',
            startLocal: '18:00',
            endLocal: '23:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: ServicePeriodEditor(controller: controller),
          ),
        ),
      );
      // ButtonStyleButton is the common ancestor for OutlinedButton + its
      // .icon variant. Disabled state is exposed via onPressed == null.
      final addButton = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('service_period_editor_add')),
      );
      expect(addButton.onPressed, isNull);
    });

    testWidgets('past-midnight period shows the badge', (tester) async {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'late',
            label: 'Late',
            startLocal: '22:00',
            endLocal: '01:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(ServicePeriodEditor(controller: controller)),
      );
      expect(
        find.byKey(const ValueKey('service_period_editor_past_midnight_0')),
        findsOneWidget,
      );
    });

    // Slice 2.5 / Gap 28 — day chip row renders + toggles work.
    testWidgets('renders 7 day chips per period', (tester) async {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(ServicePeriodEditor(controller: controller)),
      );
      for (var iso = 1; iso <= 7; iso++) {
        expect(
          find.byKey(ValueKey('service_period_editor_day_0_$iso')),
          findsOneWidget,
        );
      }
    });

    testWidgets('tapping a day chip toggles applicableDays', (tester) async {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'brunch',
            label: 'Brunch',
            startLocal: '10:00',
            endLocal: '14:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(ServicePeriodEditor(controller: controller)),
      );
      // Default is all 7 days. Tap Mon (ISO=1) to deselect it.
      await tester.tap(
        find.byKey(const ValueKey('service_period_editor_day_0_1')),
      );
      await tester.pumpAndSettle();
      expect(controller.periods[0].applicableDays.contains(1), isFalse);
      expect(controller.periods[0].applicableDays, <int>[2, 3, 4, 5, 6, 7]);
    });

    testWidgets('renders the short label and sort order text fields', (
      tester,
    ) async {
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(ServicePeriodEditor(controller: controller)),
      );
      expect(
        find.byKey(const ValueKey('service_period_editor_short_label_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('service_period_editor_sort_order_0')),
        findsOneWidget,
      );
    });

    testWidgets('overlap shows banner with the right code', (tester) async {
      // Slice 2.5: rows are taller now (extra chip row + short
      // label / sort order fields), so size the viewport tall enough
      // to fit two periods plus the validation banner without an
      // overflow assertion.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final controller = ServicePeriodEditorController(
        initial: const <ServicePeriodDraft>[
          ServicePeriodDraft(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
          ),
          ServicePeriodDraft(
            key: 'overlap',
            label: 'Overlap',
            startLocal: '14:00',
            endLocal: '16:00',
          ),
        ],
      );
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: ServicePeriodEditor(controller: controller),
          ),
        ),
      );
      expect(
        find.byKey(
          const ValueKey(
            'service_period_editor_error_1_service_period_overlap',
          ),
        ),
        findsOneWidget,
      );
    });
  });
}
