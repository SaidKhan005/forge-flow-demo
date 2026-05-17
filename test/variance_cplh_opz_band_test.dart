// ─── CPLH-vs-OPZ 60-day band tests (Variance V2 Lane HIST) ──────────────────
//
// Covers the mockup `#hist` "CPLH vs your OPZ · 60-day" card:
//   - geometry sourced only from the per-week CPLH series + the active
//     target profile's CPLH OPZ floor/ceiling (no new math),
//   - honest degraded state when OPZ bounds or the CPLH series are
//     unavailable (Metric Honesty Doctrine — no fabricated zone),
//   - the "below it N of last M weeks" emphasis applied at render via
//     the V2-4 `[[bad:…]]` token + InlineEmphasisMarkup verbatim
//     fallback (markup is NOT stored).
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/widgets/variance/cplh_opz_band_card.dart';
import 'package:forge_and_flow/widgets/variance/inline_emphasis_text.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: child),
    );

void main() {
  group('CplhOpzBandData.fromInputs — honest preconditions', () {
    test('no OPZ bounds → cannot render band', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5, 4.6, 4.7],
        opzFloor: null,
        opzCeiling: null,
        nowCplh: 4.5,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('empty CPLH series → cannot render band', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: null,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('ceiling not above floor → cannot render band', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5],
        opzFloor: 5.00,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('non-positive CPLH observations are filtered out as noise', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [0, -1, 4.59],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      expect(d.weekCount, 1);
      expect(d.livedMin, 4.59);
      expect(d.livedMax, 4.59);
    });
  });

  group('CplhOpzBandData.fromInputs — geometry (no new math)', () {
    test('scale contains lived range, OPZ box, and now marker', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [3.9, 4.2, 4.59, 5.3],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      expect(d.livedMin, 3.9);
      expect(d.livedMax, 5.3);
      // Every drawn value normalises inside [0, 1].
      for (final v in [
        d.livedMin,
        d.livedMax,
        d.opzFloor,
        d.opzCeiling,
        d.now,
      ]) {
        final f = d.fractionFor(v);
        expect(f, inInclusiveRange(0.0, 1.0));
      }
      // Floor sits left of ceiling on the scale.
      expect(d.fractionFor(d.opzFloor),
          lessThan(d.fractionFor(d.opzCeiling)));
    });

    test('weeksBelowFloor counts only weeks under the OPZ floor', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.1, 4.2, 4.3, 4.4, 4.5, 5.1],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      // 5 of 6 weeks below 4.70 (matches the mockup example shape).
      expect(d.weekCount, 6);
      expect(d.weeksBelowFloor, 5);
    });
  });

  group('OpzScaleGeometry — deterministic render geometry', () {
    // The historical bug: the band mapped positions on `[livedMin,
    // livedMax]`, so when the OPZ range was WIDER than the lived range
    // the green box overflowed and clamped to the full rail. These
    // assert via the pure geometry helper (no eyeballing the widget).

    test('Case A — mockup-like, lived widest: box strictly interior', () {
      // livedMin < opzFloor < opzCeiling < livedMax.
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [3.9, 4.2, 4.59, 5.3],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      // OPZ box is a strict interior sub-segment.
      expect(g.opzLeftPct, greaterThan(0.0));
      expect(g.opzRightPct, greaterThan(0.0));
      expect(g.opzWidthPct, lessThan(1.0));
      expect(g.opzLeftPct, lessThan(g.opzCeilingPct));

      // Lived is the widest input: ticks land at ~0% / ~100% (the
      // small symmetric domain pad keeps them just off the very edge,
      // exactly like the mockup's left:0 / right:0 ends).
      expect(g.livedMinPct, lessThan(0.10));
      expect(g.livedMaxPct, greaterThan(0.90));
      expect(g.livedMinPct, greaterThanOrEqualTo(0.0));
      expect(g.livedMaxPct, lessThanOrEqualTo(1.0));
    });

    test('Case B — real-data failing case: OPZ WIDER than lived; box is '
        'a proper sub-segment, NOT full-width', () {
      // The exact shape the operator hit: lived ~4.3-4.8, OPZ
      // 4.01-4.93, now 4.57. OPZ span (0.92) > lived span (0.5).
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.3, 4.45, 4.57, 4.8],
        opzFloor: 4.01,
        opzCeiling: 4.93,
        nowCplh: 4.57,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      // The regression assertion: the box is a proper sub-segment, NOT
      // the full rail. Both insets strictly positive, width < 1.
      expect(g.opzLeftPct, greaterThan(0.0),
          reason: 'OPZ box must not start at the rail left edge');
      expect(g.opzRightPct, greaterThan(0.0),
          reason: 'OPZ box must not reach the rail right edge');
      expect(g.opzWidthPct, lessThan(1.0),
          reason: 'OPZ box must NOT be full-width (the original bug)');
      expect(g.opzWidthPct, greaterThan(0.0));

      // OPZ is the widest input here, so the lived ticks are INSET
      // (strictly inside the rail), not pinned to the ends.
      expect(g.livedMinPct, greaterThan(0.0));
      expect(g.livedMinPct, lessThan(1.0));
      expect(g.livedMaxPct, greaterThan(g.livedMinPct));
      expect(g.livedMaxPct, lessThan(1.0));

      // Now (4.57) is strictly inside the OPZ box.
      expect(g.nowPct, greaterThan(g.opzLeftPct));
      expect(g.nowPct, lessThan(g.opzCeilingPct));
    });

    test('Case C — now below opzFloor: now dot left of the OPZ box', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [3.6, 3.8, 3.9, 4.1],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 3.7,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      expect(g.nowPct, lessThan(g.opzLeftPct),
          reason: 'now below the floor must sit left of the green box');
      expect(g.nowPct, greaterThanOrEqualTo(0.0));
      // Box still a proper sub-segment.
      expect(g.opzWidthPct, lessThan(1.0));
      expect(g.opzWidthPct, greaterThan(0.0));
    });

    test('Case D — honest degraded: missing bounds, no band, no geometry',
        () {
      final missingBounds = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.4, 4.5, 4.6],
        opzFloor: null,
        opzCeiling: null,
        nowCplh: 4.5,
      );
      expect(missingBounds.canRenderBand, isFalse);

      final missingSeries = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: null,
      );
      expect(missingSeries.canRenderBand, isFalse);
      // Degraded data carries no scale span, so fractionFor is a safe 0
      // (no fabricated geometry, no divide-by-zero).
      expect(missingSeries.fractionFor(4.7), 0.0);
    });
  });

  group('CplhOpzBandCard — render', () {
    testWidgets('populated state renders OPZ + now labels', (tester) async {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.1, 4.2, 4.3, 4.4, 4.5, 5.1],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      expect(find.text('OPZ 4.70'), findsOneWidget);
      expect(find.text('5.00'), findsOneWidget);
      expect(find.text('now 4.59'), findsOneWidget);
      expect(
        find.textContaining('What the zone is telling you.'),
        findsOneWidget,
      );
    });

    testWidgets('degraded state shows the honest message, no zone',
        (tester) async {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5],
        opzFloor: null,
        opzCeiling: null,
        nowCplh: 4.5,
      );
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      expect(find.text('CPLH ZONE'), findsOneWidget);
      expect(
        find.textContaining('needs your locked OPZ targets'),
        findsOneWidget,
      );
      // No fabricated OPZ floor label or "now" marker when bounds
      // are missing (the degraded copy may mention "OPZ targets",
      // but never a numeric zone like "OPZ 4.70" / "now 4.50").
      expect(find.textContaining(RegExp(r'OPZ \d')), findsNothing);
      expect(find.textContaining(RegExp(r'now \d')), findsNothing);
    });
  });

  group('V2-4 markup is render-only — verbatim fallback', () {
    test('the emphasis token strips to the verbatim sentence', () {
      // The exact span the card wraps for the "all weeks below" case.
      const marked = 'You have sat [[bad:below it 6 of the last 6 weeks]]. '
          'The volume keeps showing up.';
      const verbatim = 'You have sat below it 6 of the last 6 weeks. '
          'The volume keeps showing up.';
      expect(InlineEmphasisMarkup.stripMarkup(marked), verbatim);
      // No token leakage and no em dash introduced.
      expect(InlineEmphasisMarkup.stripMarkup(marked).contains('[['), isFalse);
      expect(
          InlineEmphasisMarkup.stripMarkup(marked).contains('—'), isFalse);
    });
  });
}
