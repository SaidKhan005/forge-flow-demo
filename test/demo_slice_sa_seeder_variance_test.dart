// Demo-data Slice SA — realistic per-shift seeder variance proof.
//
// Authority: per_daypart_targets_v1 plan (Slice SA); CLAUDE.md HP #2
//            (demo writes the same tables as production — this only
//            changes the deterministic SHAPE of the seeded numbers).
//
// Guards the operator-visible defect Slice SA fixes: before SA the
// closed-shift generator pinned every NON-owned rate axis to the EXACT
// per-daypart target, so within a daypart all non-driver shifts had
// byte-identical CPLH (lunch/dinner ≈86%, late_night 100% identical).
// The demo cohort therefore had ~zero per-shift dispersion and the
// benchmark card read that degenerate SPIKE as "RANGE UNCERTAIN" — an
// OPZ is a *range*, not a point. SA layers a deterministic, seeded,
// correlated good/stretched/soft profile onto the non-owned rate axes
// so a true per-shift range exists.
//
// This test proves the NEW property (dispersion exists) AND the hard
// invariant SA must not break (determinism — no RNG). The lever /
// week-aggregate / 8-family invariants are pinned by
// `demo_slice_b_driver_variance_test` and
// `replay_week_driver_rotation_test` (both still green post-SA).

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';

double _stdev(List<double> xs) {
  final mean = xs.reduce((a, b) => a + b) / xs.length;
  final variance =
      xs.map((x) => (x - mean) * (x - mean)).reduce((a, b) => a + b) /
          xs.length;
  return math.sqrt(variance);
}

/// Largest single-value share within [xs] (the "modal" mass). Before SA
/// this was ≥0.86 per daypart (degenerate spike); SA must drop it well
/// below half so the cohort reads as a genuine range.
double _modalShare(List<double> xs) {
  final freq = <double, int>{};
  for (final x in xs) {
    freq[x] = (freq[x] ?? 0) + 1;
  }
  final modal = freq.values.reduce(math.max);
  return modal / xs.length;
}

void main() {
  group('Slice SA — per-daypart CPLH dispersion (the "spike" fix)', () {
    final closed = MockIntegrationReplaySeed.output.historicalClosedShifts;

    test('every daypart has real CPLH spread, NOT a degenerate spike', () {
      expect(closed, isNotEmpty);

      for (final daypart in MockIntegrationReplaySeed.demoServicePeriodIds) {
        final cplhs = closed
            .where((s) => s.daypart == daypart)
            .map((s) => s.cplh)
            .toList();
        expect(cplhs, isNotEmpty, reason: '$daypart should have shifts');

        // (1) Genuine dispersion — stdev strictly > 0 (was 0 / ~0 when
        // every non-driver shift sat on the exact per-period target).
        final sd = _stdev(cplhs);
        expect(sd, greaterThan(0.0),
            reason: '$daypart CPLH must vary (stdev=$sd)');

        // (2) The inverse of the old degeneracy: < 50% of the daypart's
        // shifts sit at the single modal CPLH (was ≈86–100%).
        final modal = _modalShare(cplhs);
        expect(modal, lessThan(0.50),
            reason: '$daypart modal CPLH share must be < 50% '
                '(was ≈0.86–1.0 pre-SA); got $modal');
      }
    });

    test('SPLH and PPA also disperse (correlated profile, not flat)', () {
      for (final daypart in MockIntegrationReplaySeed.demoServicePeriodIds) {
        final byPart = closed.where((s) => s.daypart == daypart).toList();
        expect(_stdev(byPart.map((s) => s.splh).toList()), greaterThan(0.0),
            reason: '$daypart SPLH must vary');
        expect(_stdev(byPart.map((s) => s.ppa).toList()), greaterThan(0.0),
            reason: '$daypart PPA must vary');
      }
    });
  });

  group('Slice SA — determinism (hard invariant: no RNG)', () {
    test(
        'generateForDate(defaultBusinessDate) is byte-identical across '
        'two calls (closed + current-week cohorts)', () {
      final a = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);
      final b = MockIntegrationReplaySeed.generateForDate(
          MockIntegrationReplaySeed.defaultBusinessDate);

      String key(ShiftRecord s) => s.toMap().toString();

      expect(a.historicalClosedShifts.length,
          b.historicalClosedShifts.length);
      for (var i = 0; i < a.historicalClosedShifts.length; i++) {
        expect(key(a.historicalClosedShifts[i]),
            key(b.historicalClosedShifts[i]),
            reason: 'closed shift #$i must be byte-identical across runs '
                '(no RNG — file-header invariant)');
      }
      expect(a.currentWeekShifts.length, b.currentWeekShifts.length);
      for (var i = 0; i < a.currentWeekShifts.length; i++) {
        expect(key(a.currentWeekShifts[i]), key(b.currentWeekShifts[i]),
            reason: 'current-week shift #$i must be byte-identical');
      }
      // Week records too — the per-shift realism must not destabilise
      // the derived week aggregate across runs.
      for (var i = 0; i < a.weekRecords.length; i++) {
        expect(a.weekRecords[i].toMap().toString(),
            b.weekRecords[i].toMap().toString(),
            reason: 'week record #$i must be byte-identical');
      }
    });
  });
}
