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
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart'
    show BenchmarkVerdict;
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

/// An empty range — the read service's empty-range branch
/// (`benchmark_tracker_read_service.dart` ~138-154) emits this shape:
/// `sampleSize == 0` with sentinel `0` numerics. The table must read
/// the `sampleSize` signal and render honest dashes, never the `0`s.
DaypartRange _emptyRange(String id, String label) => DaypartRange(
      id: id,
      label: label,
      sampleSize: 0,
      selectedCount: 0,
      avgCovers: 0,
      avgCPLH: 0,
      avgSPLH: 0,
      avgPPA: 0,
      minCPLH: 0,
      maxCPLH: 0,
      targetCPLH: 0,
      targetSPLH: 0,
      targetPPA: 0,
      targetCovers: 0,
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

// Whole-day pool with a per-period child row for `dinner` only —
// `lunch` and `late_night` hit the Gap 42 whole-day-pool fallback,
// `dinner` is a true per-period target. Proves the fallback marker
// distinguishes pooled stand-ins from real per-period rows.
const _dinnerOnlyProfile = ActiveTargetProfile(
  targetProfileId: 'p3',
  restaurantId: 'r',
  sourceType: 'cycle_recommended',
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
      servicePeriodId: 'dinner',
      daypartTargetCPLH: 4.77,
      daypartTargetSPLH: 188.0,
      daypartTargetPPA: 45.20,
      daypartOpzFloorCPLH: 4.50,
      daypartOpzCeilingCPLH: 5.10,
    ),
  ],
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
    testWidgets('OPZ floor + ceiling fold into one "floor – ceiling" caption',
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

      // One "OPZ" caption label per card (3 periods + Whole Day rollup
      // = 4), no separate Floor/Ceiling rows. (2026-05-16 UX redesign:
      // the OPZ row is now a bullet bar + a verbatim range caption; the
      // "Range" word moved to the section header.)
      expect(find.text('OPZ'), findsNWidgets(4));
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

    // The DaypartTable must NOT contain a horizontal scroll view — the
    // operator's binding finding (2026-05-16) is a simple table that just
    // fits. (The test harness wraps it in a *vertical* SingleChildScrollView;
    // that one is fine — we only forbid a horizontal-axis scroll inside the
    // table.)
    final horizontalScroll = find.byWidgetPredicate(
      (w) =>
          w is SingleChildScrollView &&
          w.scrollDirection == Axis.horizontal,
    );

    testWidgets('demo device width (1080) renders with no RenderFlex overflow',
        (tester) async {
      await pumpAt(tester, 1080);

      // A RenderFlex overflow surfaces as a captured FlutterError.
      expect(tester.takeException(), isNull);

      // No horizontal scroll — cards stack vertically.
      expect(horizontalScroll, findsNothing);

      // Card-per-daypart structure: 3 period cards + the Whole Day
      // rollup = 4 cards, each carrying the headline CPLH + OPZ caption
      // + SPLH/PPA footer + an "Avg covers" header label, all on screen
      // (not offstage). 2026-05-16 UX redesign: "Target" moved to the
      // section header, so the per-card labels are bare metric names.
      expect(find.text('CPLH'), findsNWidgets(4));
      expect(find.text('SPLH'), findsNWidgets(4));
      expect(find.text('PPA'), findsNWidgets(4));
      expect(find.text('OPZ'), findsNWidgets(4));
      expect(find.text('Avg covers'), findsNWidgets(4));
      expect(find.text('3.11'), findsOneWidget); // lunch CPLH target
      expect(find.text('2.90 – 3.40'), findsOneWidget); // lunch OPZ range
    });

    testWidgets(
        'narrow phone width (360) is a simple non-scrolling card stack — '
        'no overflow, no horizontal scroll, no clipped data', (tester) async {
      await pumpAt(tester, 360);

      // No overflow exception at the 360px phone floor.
      expect(tester.takeException(), isNull);

      // No horizontal scroll anywhere in the card subtree.
      expect(horizontalScroll, findsNothing);

      // Every card's metric rows + a sample value from each are on
      // screen at full size (skipOffstage stays default: nothing is
      // parked off-stage behind a scroll). No data is shrunk to fit.
      expect(find.text('CPLH'), findsNWidgets(4));
      expect(find.text('OPZ'), findsNWidgets(4));
      expect(find.text('150'), findsOneWidget); // lunch AVG COVERS
      expect(find.text('3.11'), findsOneWidget); // lunch CPLH target
      expect(find.text('\$161'), findsOneWidget); // lunch SPLH target
      expect(find.text('\$38.10'), findsOneWidget); // lunch PPA target
      expect(find.text('2.90 – 3.40'), findsOneWidget); // lunch OPZ range
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

  group('Phantom-zero fix — empty period honesty (Metric Honesty Doctrine)',
      () {
    // lunch has no historical evidence (sampleSize == 0); dinner +
    // late_night are populated. The per-period profile carries a child
    // row for every period, so the empty period would otherwise render
    // a real per-period target on top of a `0` AVG COVERS.
    final mixed = [
      _emptyRange('lunch', 'Lunch'),
      _range('dinner', 'Dinner', 220),
      _range('late_night', 'Late Night', 80),
    ];

    testWidgets(
        'empty period → AVG COVERS + target cells render "—", never a 0',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: mixed,
          profile: _perPeriodProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // No phantom zeros anywhere from the empty lunch row.
      expect(find.text('0'), findsNothing); // AVG COVERS sentinel
      expect(find.text('0.00'), findsNothing); // CPLH sentinel
      expect(find.text('\$0'), findsNothing); // SPLH sentinel
      expect(find.text('\$0.00'), findsNothing); // PPA sentinel
      expect(find.text('0.00 – 0.00'), findsNothing); // OPZ sentinel

      // Lunch's own per-period child target must NOT surface — the
      // empty period is dashed outright, not shown as a hard number.
      expect(find.text('3.11'), findsNothing); // lunch child CPLH
      expect(find.text('2.90 – 3.40'), findsNothing); // lunch child OPZ

      // The honest dash is present for the empty row's cells.
      expect(find.text('—'), findsWidgets);

      // Populated periods are untouched — real values still render.
      expect(find.text('220'), findsOneWidget); // dinner AVG COVERS
      expect(find.text('4.77'), findsOneWidget); // dinner CPLH target
      expect(find.text('5.66'), findsOneWidget); // late_night CPLH target

      // Whole Day rollup row unchanged: still the cover-weighted pool,
      // covers summed (empty period contributes 0 to a *sum*, correct).
      expect(find.text('Whole Day'), findsOneWidget);
      expect(find.text('300'), findsOneWidget); // 0 + 220 + 80
      expect(find.text('4.50'), findsOneWidget); // pool CPLH (rollup only)
    });
  });

  group('Phantom-zero fix — Gap 42 pool-fallback marker (Design Rule 1)', () {
    testWidgets(
        'pooled-stand-in rows carry the "whole-day est." marker; '
        'true per-period rows do not', (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges, // all populated (sampleSize > 0)
          profile: _dinnerOnlyProfile, // child row for dinner only
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // lunch + late_night fall back to the whole-day pool → marked.
      // dinner has its own child row → no marker. Rollup is the pool by
      // definition and is not a per-period stand-in → no marker.
      expect(find.text('whole-day est.'), findsNWidgets(2));

      // dinner renders its true per-period target, not the pool.
      expect(find.text('4.77'), findsOneWidget); // dinner child CPLH
      // lunch + late_night show the pooled CPLH (4.50) — 2 rows + the
      // rollup all read the pool.
      expect(find.text('4.50'), findsNWidgets(3));
    });

    testWidgets('no marker when every period has its own child row',
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

      expect(find.text('whole-day est.'), findsNothing);
    });

    testWidgets(
        'empty period that would pool does NOT get the marker — it is '
        'dashed instead (no misleading pooled stand-in)', (tester) async {
      // lunch empty + profile has no child rows → lunch would pool, but
      // because it has no evidence it must dash, not show a marked pool
      // stand-in. dinner/late_night (populated, no child row) DO pool.
      final mixed = [
        _emptyRange('lunch', 'Lunch'),
        _range('dinner', 'Dinner', 220),
        _range('late_night', 'Late Night', 80),
      ];
      await _pump(
        tester,
        DaypartTable(
          dayparts: mixed,
          profile: _emptyDaypartsProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // Only the 2 populated-but-pooled rows are marked; the empty
      // lunch row is dashed (not a marked pool stand-in).
      expect(find.text('whole-day est.'), findsNWidgets(2));
      expect(find.text('—'), findsWidgets); // lunch's dashed cells
    });
  });

  group('Phantom-zero fix — no overflow with empty + fallback rows', () {
    Future<void> pumpAt(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final mixed = [
        _emptyRange('lunch', 'Lunch'),
        _range('dinner', 'Dinner', 220),
        _range('late_night', 'Late Night', 80),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: DaypartTable(
                  dayparts: mixed,
                  profile: _dinnerOnlyProfile,
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

    testWidgets('no RenderFlex overflow at demo width (1080)',
        (tester) async {
      await pumpAt(tester, 1080);
      expect(tester.takeException(), isNull);
      expect(find.text('whole-day est.'), findsWidgets);
    });

    testWidgets(
        'narrow phone width (360): no overflow, no horizontal scroll, '
        'pooled fallback marker still renders (honest semantics)',
        (tester) async {
      await pumpAt(tester, 360);
      expect(tester.takeException(), isNull);

      // No horizontal scroll inside the table subtree.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is SingleChildScrollView &&
              w.scrollDirection == Axis.horizontal,
        ),
        findsNothing,
      );

      // Cards rendered: 3 period cards + Whole Day rollup, each with
      // its OPZ caption at full size.
      expect(find.text('OPZ'), findsNWidgets(4));
      // The honest Gap 42 "whole-day est." marker survives the re-spaced
      // narrow layout. With _dinnerOnlyProfile + mixed rows: lunch is
      // empty (dashed, no marker), dinner has its own child row (no
      // marker), late_night is populated with no child row → pooled →
      // exactly one marker.
      expect(find.text('whole-day est.'), findsOneWidget);
      // dinner's true per-period target still distinct from the pool.
      expect(find.text('4.77'), findsOneWidget);
    });
  });

  // ── SC: per-period verdict badges + honest `not set` ────────────────
  //
  // Source of truth = the persisted `ActiveTargetProfileDaypart.verdict`
  // (S0 field, populated by SB), read via `daypartFor`. No verdict is
  // re-derived in the widget. Badge labels are the verbatim §9 strings.
  group('SC — per-period verdict badges', () {
    // Each period carries a different verdict so one badged row per
    // servicePeriodDefinitions entry is asserted independently.
    const mixedVerdictProfile = ActiveTargetProfile(
      targetProfileId: 'pSC',
      restaurantId: 'r',
      sourceType: 'cycle_recommended',
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
        // teachable — real band, numbers shown.
        ActiveTargetProfileDaypart(
          servicePeriodId: 'lunch',
          daypartTargetCPLH: 3.11,
          daypartTargetSPLH: 161.0,
          daypartTargetPPA: 38.10,
          daypartOpzFloorCPLH: 2.90,
          daypartOpzCeilingCPLH: 3.40,
          verdict: BenchmarkVerdict.teachable,
        ),
        // building_flat — no band, structural 0s → must show `not set`.
        ActiveTargetProfileDaypart(
          servicePeriodId: 'dinner',
          daypartTargetCPLH: 0,
          daypartTargetSPLH: 0,
          daypartTargetPPA: 0,
          daypartOpzFloorCPLH: 0,
          daypartOpzCeilingCPLH: 0,
          verdict: BenchmarkVerdict.buildingFlat,
        ),
        // running_hot — real band, numbers shown, negative badge.
        ActiveTargetProfileDaypart(
          servicePeriodId: 'late_night',
          daypartTargetCPLH: 5.66,
          daypartTargetSPLH: 175.0,
          daypartTargetPPA: 36.40,
          daypartOpzFloorCPLH: 5.30,
          daypartOpzCeilingCPLH: 6.00,
          verdict: BenchmarkVerdict.runningHot,
        ),
      ],
    );

    testWidgets(
        'one badged row per servicePeriodDefinitions entry, verbatim copy',
        (tester) async {
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: mixedVerdictProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      // Verbatim §9 badge labels — one per period, no em-dash anywhere.
      expect(find.text('GOOD OPZ RANGE'), findsOneWidget); // lunch
      expect(find.text('RANGE BUILDING'), findsOneWidget); // dinner
      expect(find.text('OPERATION RUNNING HOT'),
          findsOneWidget); // late_night

      // teachable + running_hot keep their honest numbers.
      expect(find.text('3.11'), findsOneWidget);
      expect(find.text('5.66'), findsOneWidget);

      // building_flat: structural 0 target rendered as muted `not set`,
      // never `0` / `0.00` (Design Rule 2). CPLH + SPLH + PPA + OPZ.
      expect(find.text('not set'), findsNWidgets(4));
      expect(find.text('0.00'), findsNothing);
      expect(find.text('\$0'), findsNothing);
    });

    testWidgets('Gap 42 (daypartFor null) renders NO fabricated badge',
        (tester) async {
      // _emptyDaypartsProfile has zero per-period rows → every period
      // hits the whole-day-pool fallback. No per-period verdict exists,
      // so the table must not invent a badge (spec hazard 4).
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: _emptyDaypartsProfile,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );

      expect(find.text('GOOD OPZ RANGE'), findsNothing);
      expect(find.text('RANGE BUILDING'), findsNothing);
      expect(find.text('NOT ENOUGH SHIFTS YET'), findsNothing);
      expect(find.text('NOT ENOUGH STRONG SHIFTS'), findsNothing);
      expect(find.text('OPERATION RUNNING HOT'), findsNothing);
      // Honest whole-day pool stand-in still shown (the existing marker).
      expect(find.text('whole-day est.'), findsNWidgets(3));
      // Pool numbers (4.50) render — never a sentinel 0.
      expect(find.text('4.50'), findsWidgets);
      expect(find.text('0.00'), findsNothing);
    });

    testWidgets('building_few_strong + building_early verbatim labels',
        (tester) async {
      const p = ActiveTargetProfile(
        targetProfileId: 'pSC2',
        restaurantId: 'r',
        sourceType: 'cycle_recommended',
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
            daypartTargetCPLH: 0,
            daypartTargetSPLH: 0,
            daypartTargetPPA: 0,
            daypartOpzFloorCPLH: 0,
            daypartOpzCeilingCPLH: 0,
            verdict: BenchmarkVerdict.buildingEarly,
          ),
          ActiveTargetProfileDaypart(
            servicePeriodId: 'dinner',
            daypartTargetCPLH: 0,
            daypartTargetSPLH: 0,
            daypartTargetPPA: 0,
            daypartOpzFloorCPLH: 0,
            daypartOpzCeilingCPLH: 0,
            verdict: BenchmarkVerdict.buildingFewStrong,
          ),
          ActiveTargetProfileDaypart(
            servicePeriodId: 'late_night',
            daypartTargetCPLH: 5.66,
            daypartTargetSPLH: 175.0,
            daypartTargetPPA: 36.40,
            daypartOpzFloorCPLH: 5.30,
            daypartOpzCeilingCPLH: 6.00,
            verdict: BenchmarkVerdict.teachable,
          ),
        ],
      );
      await _pump(
        tester,
        DaypartTable(
          dayparts: _ranges,
          profile: p,
          servicePeriodDefinitions:
              ServicePeriodDefinitionResolver.demoDefinitions,
        ),
      );
      expect(find.text('NOT ENOUGH SHIFTS YET'), findsOneWidget);
      expect(find.text('NOT ENOUGH STRONG SHIFTS'), findsOneWidget);
      expect(find.text('GOOD OPZ RANGE'), findsOneWidget);
      // Two not-teachable periods → 2 rows × 4 muted fields each.
      expect(find.text('not set'), findsNWidgets(8));
    });
  });
}
