// Per-Daypart Targets V1 / Slice 2 — DaypartTable redesign tests.
//
// Covers the three Slice 2 reader/render contracts:
//   1. Per-period read-back: each period row reads its own
//      `ActiveTargetProfileDaypart` via `daypartFor(periodId)`
//      (Design Rule 1 — `daypart*` accessors), never the whole-day
//      pool when a child row exists.
//   2. OPZ single-column render: the old OPZ Floor + OPZ Ceiling pair
//      folds into one "OPZ RANGE" cell rendered as "floor – ceiling".
//   3. Empty-`dayparts` fallback (Gap 42): when the profile carries no
//      per-period child rows, every period row + the Whole Day rollup
//      fall back to the whole-day pool fields. Missing profile renders
//      an honest dash, never a sentinel 0 (Design Rule 2).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';
import 'package:forge_and_flow/widgets/daypart_table.dart';

DaypartRange _range(String id, String label, int avgCovers) => DaypartRange(
      id: id,
      label: label,
      sampleSize: 10,
      selectedCount: 5,
      avgCovers: avgCovers,
      avgCPLH: 4.0,
      avgSPLH: 170,
      avgPPA: 40,
      minCPLH: 3.5,
      maxCPLH: 5.0,
      // These candidate-derived target fields must NOT surface — Slice 2
      // reads targets from the ActiveTargetProfile, not the candidate
      // average. Set to sentinel-ish values distinct from the profile.
      targetCPLH: 9.99,
      targetSPLH: 999,
      targetPPA: 99.99,
      targetCovers: 999,
    );

final _ranges = [
  _range('lunch', 'Lunch', 150),
  _range('dinner', 'Dinner', 220),
  _range('late_night', 'Late Night', 80),
];

const _perPeriodProfile = ActiveTargetProfile(
  targetProfileId: 'p',
  restaurantId: 'r',
  sourceType: 'cycle_recommended',
  // Whole-day pool — deliberately distinct from every per-period row so
  // a per-period read-back failure (reading the pool instead) is caught.
  targetCPLH: 4.50,
  targetSPLH: 180.0,
  targetPPA: 42.00,
  fohWage: 17.0,
  bohWage: 22.0,
  opzFloorCPLH: 4.00,
  opzCeilingCPLH: 5.00,
  theoreticalFohLaborPct: 9.0,
  theoreticalBohLaborPct: 12.0,
  theoreticalLaborPct: 21.0,
  builtAt: '2026-05-15T00:00:00Z',
  dayparts: [
    ActiveTargetProfileDaypart(
      servicePeriodId: 'lunch',
      daypartTargetCPLH: 3.11,
      daypartTargetSPLH: 161.0,
      daypartTargetPPA: 38.10,
      daypartOpzFloorCPLH: 2.90,
      daypartOpzCeilingCPLH: 3.40,
    ),
    ActiveTargetProfileDaypart(
      servicePeriodId: 'dinner',
      daypartTargetCPLH: 4.77,
      daypartTargetSPLH: 188.0,
      daypartTargetPPA: 45.20,
      daypartOpzFloorCPLH: 4.50,
      daypartOpzCeilingCPLH: 5.10,
    ),
    ActiveTargetProfileDaypart(
      servicePeriodId: 'late_night',
      daypartTargetCPLH: 5.66,
      daypartTargetSPLH: 175.0,
      daypartTargetPPA: 36.40,
      daypartOpzFloorCPLH: 5.30,
      daypartOpzCeilingCPLH: 6.00,
    ),
  ],
);

// Same whole-day pool, but no per-period child rows (Gap 42
// insufficient-recommendation fallback).
const _emptyDaypartsProfile = ActiveTargetProfile(
  targetProfileId: 'p2',
  restaurantId: 'r',
  sourceType: 'cycle_recommended_insufficient',
  targetCPLH: 4.50,
  targetSPLH: 180.0,
  targetPPA: 42.00,
  fohWage: 17.0,
  bohWage: 22.0,
  opzFloorCPLH: 4.00,
  opzCeilingCPLH: 5.00,
  theoreticalFohLaborPct: 9.0,
  theoreticalBohLaborPct: 12.0,
  theoreticalLaborPct: 21.0,
  builtAt: '2026-05-15T00:00:00Z',
  // dayparts defaults to const [] — the Gap 42 path.
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
  );
  await tester.pump();
}

void main() {
  group('Slice 2 — per-period read-back (Design Rule 1)', () {
    testWidgets(
        'each period row renders its own daypart* target, not the pool',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: _perPeriodProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // Per-period CPLH targets (from the child rows).
      expect(find.text('3.11'), findsOneWidget); // lunch
      expect(find.text('4.77'), findsOneWidget); // dinner
      expect(find.text('5.66'), findsOneWidget); // late_night

      // Per-period SPLH / PPA targets.
      expect(find.text('\$161'), findsOneWidget); // lunch SPLH
      expect(find.text('\$45.20'), findsOneWidget); // dinner PPA

      // The candidate-average sentinel targets must NOT leak through —
      // proves the table reads the profile, not the DaypartRange.
      expect(find.text('9.99'), findsNothing);
      expect(find.text('\$99.99'), findsNothing);

      // AVG COVERS column is preserved (demand context).
      expect(find.text('150'), findsOneWidget);
      expect(find.text('220'), findsOneWidget);
      expect(find.text('80'), findsOneWidget);
    });
  });

  group('Slice 2 — OPZ single-column render', () {
    testWidgets('OPZ floor + ceiling fold into one "OPZ RANGE" cell',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: _perPeriodProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // Single header cell, no separate Floor/Ceiling headers.
      expect(find.text('OPZ RANGE'), findsOneWidget);
      expect(find.text('OPZ FLOOR'), findsNothing);
      expect(find.text('OPZ CEILING'), findsNothing);

      // Per-period combined range strings (en dash separator).
      expect(find.text('2.90 – 3.40'), findsOneWidget); // lunch
      expect(find.text('4.50 – 5.10'), findsOneWidget); // dinner
      expect(find.text('5.30 – 6.00'), findsOneWidget); // late_night

      // Whole Day rollup row shows the cover-weighted pool's OPZ range.
      expect(find.text('Whole Day'), findsOneWidget);
      expect(find.text('4.00 – 5.00'), findsOneWidget); // pool floor/ceil
    });
  });

  group('Benchmark UX cleanup — no overflow at any device width', () {
    Future<void> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: DaypartTable(
                  dayparts: _ranges,
                  profile: _perPeriodProfile,
                  servicePeriodDefinitions:
                      ServicePeriodDefinitionResolver.demoDefinitions,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('demo device width (1080) renders with no RenderFlex overflow',
        (tester) async {
      await pumpAt(tester, 1080);

      // A RenderFlex overflow surfaces as a captured FlutterError.
      expect(tester.takeException(), isNull);

      // All six columns + a sample per-period value still render.
      expect(find.text('DAYPART'), findsOneWidget);
      expect(find.text('AVG COVERS'), findsOneWidget);
      expect(find.text('OPZ RANGE'), findsOneWidget);
      expect(find.text('3.11'), findsOneWidget); // lunch CPLH target
      expect(find.text('2.90 – 3.40'), findsOneWidget); // lunch OPZ range
    });

    testWidgets('narrow phone width (360) scrolls instead of overflowing',
        (tester) async {
      await pumpAt(tester, 360);

      // No overflow exception even at a cramped phone width — the table
      // scrolls horizontally rather than clipping or throwing.
      expect(tester.takeException(), isNull);

      // The label column stays on screen; off-stage numeric columns are
      // reachable (the table is laid out, just horizontally scrollable).
      expect(find.text('DAYPART'), findsOneWidget);
      expect(find.text('3.11', skipOffstage: false), findsOneWidget);
    });
  });

  group('Slice 2 — empty dayparts fallback (Gap 42 / Design Rule 2)', () {
    testWidgets(
        'no child rows → every period row + rollup read the whole-day pool',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: _emptyDaypartsProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // 3 period rows + 1 Whole Day rollup all show the pool CPLH 4.50.
      expect(find.text('4.50'), findsNWidgets(4));
      // Pool OPZ range repeated across the 3 rows + rollup.
      expect(find.text('4.00 – 5.00'), findsNWidgets(4));
      // No sentinel zeros anywhere (Design Rule 2).
      expect(find.text('0.00'), findsNothing);
      expect(find.text('0.00 – 0.00'), findsNothing);
    });

    testWidgets('no profile at all → honest dash, never a sentinel 0',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: null,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // Target/OPZ columns render an em dash for every period row and
      // the rollup; AVG COVERS still renders honestly.
      expect(find.text('—'), findsWidgets);
      expect(find.text('0.00'), findsNothing);
      expect(find.text('\$0'), findsNothing);
      expect(find.text('150'), findsOneWidget);
    });

    testWidgets('period labels come from the resolved definitions',
        (tester) async {
      // Use a custom definition set with a relabeled period to prove
      // labels are resolver-driven, not hardcoded in the widget.
      const defs = [
        ServicePeriodDefinition(
          id: 'lunch',
          label: 'Midday',
          shortLabel: 'M',
          sortOrder: 1,
          startLocalTime: '11:00',
          endLocalTime: '15:00',
          rollsPastMidnight: false,
          applicableDays: [1, 2, 3, 4, 5],
        ),
        ServicePeriodDefinition(
          id: 'dinner',
          label: 'Supper',
          shortLabel: 'S',
          sortOrder: 2,
          startLocalTime: '17:00',
          endLocalTime: '23:00',
          rollsPastMidnight: false,
          applicableDays: [1, 2, 3, 4, 5, 6, 7],
        ),
        ServicePeriodDefinition(
          id: 'late_night',
          label: 'After Hours',
          shortLabel: 'AH',
          sortOrder: 3,
          startLocalTime: '23:00',
          endLocalTime: '02:00',
          rollsPastMidnight: true,
          applicableDays: [5, 6],
        ),
      ];
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: _emptyDaypartsProfile,
          servicePeriodDefinitions: defs,
        ),
      );

      expect(find.text('Midday'), findsOneWidget);
      expect(find.text('Supper'), findsOneWidget);
      expect(find.text('After Hours'), findsOneWidget);
      // Hardcoded English labels must not appear.
      expect(find.text('Lunch'), findsNothing);
      expect(find.text('Dinner'), findsNothing);
    });
  });
}
