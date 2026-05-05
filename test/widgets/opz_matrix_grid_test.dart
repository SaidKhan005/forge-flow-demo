// Phase 7.58 depth wave (slice 10.5.6) — _OpzMatrixGrid widget tests.
//
// Pins the 3x3 active-cell rendering for every (CPLH band, SPLH band)
// pair, the no-data state when SPLH is null (BOH not punched in), and
// an em-dash sweep across the new + modified literal sources.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/widgets/opz_matrix_grid.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required OpzCplhBand cplh,
    required OpzSplhBand? splh,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: OpzMatrixGrid(cplh: cplh, splh: splh),
          ),
        ),
      ),
    );
  }

  group('active cell rendering', () {
    final cases = <List<dynamic>>[
      [OpzCplhBand.aboveCeiling, OpzSplhBand.low,
          'aboveCeiling_low'],
      [OpzCplhBand.aboveCeiling, OpzSplhBand.onTarget,
          'aboveCeiling_onTarget'],
      [OpzCplhBand.aboveCeiling, OpzSplhBand.high,
          'aboveCeiling_high'],
      [OpzCplhBand.inOpz, OpzSplhBand.low, 'inOpz_low'],
      [OpzCplhBand.inOpz, OpzSplhBand.onTarget, 'inOpz_onTarget'],
      [OpzCplhBand.inOpz, OpzSplhBand.high, 'inOpz_high'],
      [OpzCplhBand.belowFloor, OpzSplhBand.low, 'belowFloor_low'],
      [OpzCplhBand.belowFloor, OpzSplhBand.onTarget,
          'belowFloor_onTarget'],
      [OpzCplhBand.belowFloor, OpzSplhBand.high, 'belowFloor_high'],
    ];

    for (final c in cases) {
      final cplh = c[0] as OpzCplhBand;
      final splh = c[1] as OpzSplhBand;
      final key = c[2] as String;
      testWidgets(
        'highlights $key',
        (tester) async {
          await pump(tester, cplh: cplh, splh: splh);
          expect(
            find.byKey(Key('opz_matrix_cell_${key}_active')),
            findsOneWidget,
          );
          // Exactly one active cell across the 9 cells.
          int activeCount = 0;
          for (final row in OpzCplhBand.values) {
            for (final col in OpzSplhBand.values) {
              if (find
                  .byKey(Key('opz_matrix_cell_${row.name}_${col.name}_active'))
                  .evaluate()
                  .isNotEmpty) {
                activeCount++;
              }
            }
          }
          expect(activeCount, 1);
        },
      );
    }
  });

  testWidgets('no-data state renders 9 dim cells when SPLH is null',
      (tester) async {
    await pump(tester, cplh: OpzCplhBand.inOpz, splh: null);
    int activeCount = 0;
    int dimCount = 0;
    for (final row in OpzCplhBand.values) {
      for (final col in OpzSplhBand.values) {
        if (find
            .byKey(Key('opz_matrix_cell_${row.name}_${col.name}_active'))
            .evaluate()
            .isNotEmpty) {
          activeCount++;
        }
        if (find
            .byKey(Key('opz_matrix_cell_${row.name}_${col.name}'))
            .evaluate()
            .isNotEmpty) {
          dimCount++;
        }
      }
    }
    expect(activeCount, 0);
    expect(dimCount, 9);
  });

  testWidgets('renders all 3 row labels and 3 column labels',
      (tester) async {
    await pump(tester,
        cplh: OpzCplhBand.inOpz, splh: OpzSplhBand.onTarget);
    for (final row in OpzCplhBand.values) {
      expect(find.byKey(Key('opz_matrix_row_${row.name}')), findsOneWidget);
    }
    for (final col in OpzSplhBand.values) {
      expect(find.byKey(Key('opz_matrix_col_${col.name}')), findsOneWidget);
    }
  });

  group('cross-axis sub-label resolver', () {
    final cases = <Map<String, dynamic>>[
      {
        'name': 'CPLH below + SPLH above -> volume problem sentence',
        'opzStatus': 'below',
        'splhState': 'above',
        'expect': 'Below OPZ floor. Team executed. Volume problem, not '
            'staffing. Fix the forecast.',
      },
      {
        'name': 'CPLH above + SPLH below -> ticket-time sentence',
        'opzStatus': 'above',
        'splhState': 'below',
        'expect': 'Above OPZ ceiling AND kitchen slowed. Pull ticket '
            'times before adding hours.',
      },
      {
        'name': 'CPLH on + SPLH below -> upselling sentence',
        'opzStatus': 'in',
        'splhState': 'below',
        'expect': 'In OPZ. PPA dropped. Watch upselling.',
      },
      {
        'name': 'CPLH on + SPLH above -> kitchen-strong sentence',
        'opzStatus': 'in',
        'splhState': 'above',
        'expect': 'In OPZ. Kitchen running strong. Document this shift.',
      },
      {
        'name': 'CPLH below + SPLH null -> single-axis below copy',
        'opzStatus': 'below',
        'splhState': null,
        'expect': 'Productivity is below the OPZ floor. Too many labor '
            'hours for the volume.',
      },
      {
        'name': 'CPLH above + SPLH null -> single-axis above copy',
        'opzStatus': 'above',
        'splhState': null,
        'expect': 'Productivity is above the OPZ ceiling. Service '
            'quality may suffer.',
      },
      {
        'name': 'CPLH on + SPLH null -> single-axis in copy',
        'opzStatus': 'in',
        'splhState': null,
        'expect': 'Team is producing. Watch covers.',
      },
    ];

    for (final c in cases) {
      test(c['name'] as String, () {
        final got = ShiftDashboardReadModel.computeOpzSubLabelForTest(
          c['opzStatus'] as String,
          c['splhState'] as String?,
        );
        expect(got, c['expect']);
      });
    }

    test('agreeing cells fall back to single-axis copy', () {
      // (above, on) and (above, above) and (below, on) and (below, below)
      // and (on, on) all fall back to the single-axis CPLH copy.
      expect(
        ShiftDashboardReadModel.computeOpzSubLabelForTest('above', 'on'),
        startsWith('Productivity is above the OPZ ceiling.'),
      );
      expect(
        ShiftDashboardReadModel.computeOpzSubLabelForTest('above', 'above'),
        startsWith('Productivity is above the OPZ ceiling.'),
      );
      expect(
        ShiftDashboardReadModel.computeOpzSubLabelForTest('below', 'on'),
        startsWith('Productivity is below the OPZ floor.'),
      );
      expect(
        ShiftDashboardReadModel.computeOpzSubLabelForTest('below', 'below'),
        startsWith('Productivity is below the OPZ floor.'),
      );
      expect(
        ShiftDashboardReadModel.computeOpzSubLabelForTest('in', 'on'),
        'Team is producing. Watch covers.',
      );
    });
  });

  test('zero em dashes in new widget source', () {
    // The new file is owned end-to-end by this slice; nothing in it
    // (comment or string) may carry an em dash.
    final src = File('lib/widgets/opz_matrix_grid.dart').readAsStringSync();
    final emDash = String.fromCharCode(0x2014);
    expect(src.contains(emDash), isFalse,
        reason: 'em dash leaked into opz_matrix_grid.dart');
  });

  group('SPLH state classifier', () {
    test('null when BOH not punched in', () {
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 0,
          actualSplh: 999,
          targetSplh: 180,
        ),
        isNull,
      );
    });

    test('null when target is zero (no honest divisor)', () {
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 200,
          targetSplh: 0,
        ),
        isNull,
      );
    });

    test('on-target when within +/- 5 percent of target', () {
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 180,
          targetSplh: 180,
        ),
        'on',
      );
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 180 * 1.04,
          targetSplh: 180,
        ),
        'on',
      );
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 180 * 0.96,
          targetSplh: 180,
        ),
        'on',
      );
    });

    test('above when 6 percent above target', () {
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 180 * 1.06,
          targetSplh: 180,
        ),
        'above',
      );
    });

    test('below when 6 percent below target', () {
      expect(
        ShiftDashboardReadModel.computeSplhStateForTest(
          actualBohHours: 8,
          actualSplh: 180 * 0.94,
          targetSplh: 180,
        ),
        'below',
      );
    });
  });

  test('zero em dashes in any sub-label sentence the resolver returns', () {
    // Sweeps the full 3x3 + null-SPLH input space (12 combinations) and
    // pins every sentence the operator can ever read against the em-dash
    // ban from the depth-wave hard gates.
    final emDash = String.fromCharCode(0x2014);
    for (final cplh in <String>['below', 'in', 'above']) {
      for (final splh in <String?>[null, 'below', 'on', 'above']) {
        final sentence =
            ShiftDashboardReadModel.computeOpzSubLabelForTest(cplh, splh);
        expect(sentence.contains(emDash), isFalse,
            reason: 'em dash in sub-label for ($cplh, $splh): $sentence');
      }
    }
  });
}
