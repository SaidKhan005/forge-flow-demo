// Wave 2 S-1 — unit tests for the blended-wage calculator.
//
// Pure-Dart formula tests. Anchored to debug.md:198-235 (OW-13a /
// OW-13b) — the worked example in the slice doc resolves to
// $282.00 / 16 hrs = $17.625/hr. The calculator should produce the
// same number, plus per-bucket subtotals.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/screens/wage_authority/blended_wage_calculator.dart';

void main() {
  const bucketOrder = <String>['foh', 'boh', 'manager'];

  group('computeBlendedWageSummary', () {
    test('empty input → zero totals + null blended rate', () {
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[],
        bucketOrder: bucketOrder,
      );
      expect(summary.totalWeightedHours, 0);
      expect(summary.totalWeightedDollars, 0);
      expect(summary.blendedHourlyRate, isNull);
      expect(summary.hasAnyHours, isFalse);
      expect(summary.rowCount, 0);
      // perBucket still carries the requested order so the widget can
      // render stable layout when the operator clears all rows.
      expect(
        summary.perBucket.map((b) => b.laborBucket).toList(),
        bucketOrder,
      );
      for (final b in summary.perBucket) {
        expect(b.hasRows, isFalse);
        expect(b.blendedHourlyRate, isNull);
      }
    });

    test('worked example from debug.md resolves to \$17.625/hr', () {
      // FOH: 4 servers, 2 runners, 1 host, 1 bartender — all @ \$16/hr.
      // BOH: 3 line cooks @ \$20, 2 prep cooks @ \$17.50,
      //      2 dishwashers @ \$16.50.
      // Mgmt: 1 manager @ \$26.
      // Each role assumed to work 1 hour (the doc's "hourly cost"
      // framing). Expected total dollars: \$282 / 16 hours = \$17.625.
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 4,
          ),
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 2,
          ),
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 1,
          ),
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 1,
          ),
          BlendedWageInputRow(
            laborBucket: 'boh',
            hourlyRate: 20.0,
            weightedHours: 3,
          ),
          BlendedWageInputRow(
            laborBucket: 'boh',
            hourlyRate: 17.50,
            weightedHours: 2,
          ),
          BlendedWageInputRow(
            laborBucket: 'boh',
            hourlyRate: 16.50,
            weightedHours: 2,
          ),
          BlendedWageInputRow(
            laborBucket: 'manager',
            hourlyRate: 26.0,
            weightedHours: 1,
          ),
        ],
        bucketOrder: bucketOrder,
      );
      expect(summary.totalWeightedHours, 16);
      expect(summary.totalWeightedDollars, closeTo(282.0, 1e-9));
      expect(summary.blendedHourlyRate, closeTo(17.625, 1e-9));
      expect(summary.rowCount, 8);
      expect(summary.hasAnyHours, isTrue);
    });

    test('per-bucket subtotals stay isolated', () {
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 8,
          ),
          BlendedWageInputRow(
            laborBucket: 'boh',
            hourlyRate: 20.0,
            weightedHours: 4,
          ),
          BlendedWageInputRow(
            laborBucket: 'manager',
            hourlyRate: 30.0,
            weightedHours: 4,
          ),
        ],
        bucketOrder: bucketOrder,
      );
      final foh = summary.perBucket.firstWhere((b) => b.laborBucket == 'foh');
      final boh = summary.perBucket.firstWhere((b) => b.laborBucket == 'boh');
      final mgr =
          summary.perBucket.firstWhere((b) => b.laborBucket == 'manager');
      expect(foh.blendedHourlyRate, 16.0);
      expect(foh.totalWeightedHours, 8);
      expect(foh.totalWeightedDollars, 128.0);
      expect(boh.blendedHourlyRate, 20.0);
      expect(boh.totalWeightedDollars, 80.0);
      expect(mgr.blendedHourlyRate, 30.0);
      expect(mgr.totalWeightedDollars, 120.0);
      // Whole-screen blended = (128 + 80 + 120) / 16 = 328/16 = 20.5.
      expect(summary.blendedHourlyRate, closeTo(20.5, 1e-9));
    });

    test('zero/negative weighted hours rows are skipped, not counted', () {
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 0,
          ),
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: -5,
          ),
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 4,
          ),
        ],
        bucketOrder: bucketOrder,
      );
      expect(summary.rowCount, 1);
      expect(summary.totalWeightedHours, 4);
      expect(summary.blendedHourlyRate, 16.0);
    });

    test('zero-rate rows are still included (the operator may want a '
        '\$0 placeholder for a salaried or volunteer role)', () {
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 0.0,
            weightedHours: 5,
          ),
          BlendedWageInputRow(
            laborBucket: 'boh',
            hourlyRate: 20.0,
            weightedHours: 5,
          ),
        ],
        bucketOrder: bucketOrder,
      );
      expect(summary.rowCount, 2);
      expect(summary.totalWeightedHours, 10);
      expect(summary.totalWeightedDollars, 100.0);
      expect(summary.blendedHourlyRate, 10.0);
    });

    test('unknown bucket wire still surfaces in perBucket (so the '
        'widget never silently drops it)', () {
      final summary = computeBlendedWageSummary(
        rows: const <BlendedWageInputRow>[
          BlendedWageInputRow(
            laborBucket: 'foh',
            hourlyRate: 16.0,
            weightedHours: 4,
          ),
          // A legacy seed row with a non-canonical bucket name.
          BlendedWageInputRow(
            laborBucket: 'salaried_legacy',
            hourlyRate: 30.0,
            weightedHours: 2,
          ),
        ],
        bucketOrder: bucketOrder,
      );
      final wires = summary.perBucket.map((b) => b.laborBucket).toList();
      expect(wires.first, 'foh');
      expect(wires.contains('salaried_legacy'), isTrue);
    });
  });
}
