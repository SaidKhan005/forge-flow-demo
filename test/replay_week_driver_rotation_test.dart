// Per-week dominant driver rotation — Variance → History honesty pin.
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md
//            (Single Source of Truth — the seed must persist what
//            `LaborModel.determineLever` returns for the week's real
//            aggregate, never a hand-coded lever); CLAUDE.md HP #2.
//
// Guards the operator-visible defect this change fixes: the Variance →
// History tab showed the SAME washed-out driver for all 12 historical
// weeks because the per-(day,period) slot intents diluted to <~1% at
// the week aggregate so every week fell to the empty-candidate
// `covers_down` fallback. The per-week dominant driver layer
// (`_weekDriverIntent` / `_weekDriverMag` in
// `lib/dev/mock_integration_replay_seed.dart`) adds a small uniform
// week-wide tilt on one assigned axis per week so each week's REAL
// aggregate genuinely crosses that axis's `determineLever` threshold
// and the History tab demonstrates all 12 rate/volume lever badges.
//
// Honesty is structural: `_deriveWeekRecord` still re-derives every
// `primaryLeverId` from the constituent shifts via
// `LaborModel.determineLever` (no hardcoding — proven by
// `fixture_lever_roundtrip_test.dart`). This test asserts the *result*:
// 12 week records, each carrying a distinct real catalog lever id,
// covering the full set of 12 rate/volume families exactly once.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';

void main() {
  group('Per-week dominant driver rotation', () {
    final out = MockIntegrationReplaySeed.output;

    test('exactly 12 historical week records', () {
      expect(out.weekRecords.length, MockIntegrationReplaySeed.historicalWeekCount);
      expect(out.weekRecords.length, 12);
    });

    test(
        'the 12 week levers cover all 12 rate/volume families exactly once',
        () {
      const expectedIds = {
        'covers_up', 'covers_down',
        'ppa_up', 'ppa_down',
        'cplh_up', 'cplh_down',
        'splh_up', 'splh_down',
        'foh_wage_up', 'foh_wage_down',
        'boh_wage_up', 'boh_wage_down',
      };

      final actual = out.weekRecords.map((w) => w.primaryLeverId).toList();

      // Each id appears exactly once (no duplicates, no washed-out
      // `covers_down` fallback collapse).
      expect(
        actual.toSet().length,
        actual.length,
        reason: 'every week must carry a DISTINCT driver — got $actual',
      );
      expect(
        actual.toSet(),
        equals(expectedIds),
        reason: 'the History tab must demonstrate all 12 rate/volume '
            'lever badges exactly once — got ${actual.toSet()}',
      );
    });

    test('every week lever is a real catalog id (no synthetic sentinel)',
        () {
      for (final w in out.weekRecords) {
        expect(
          LeverCards.lookup(w.primaryLeverId),
          isNotNull,
          reason: '${w.weekId} carries "${w.primaryLeverId}" which is not '
              'a real LeverCards catalog id',
        );
      }
    });
  });
}
