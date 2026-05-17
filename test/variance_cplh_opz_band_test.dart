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

  group('OpzScaleGeometry — Option 1 (rail = real lived range)', () {
    // Operator-approved Option 1: domain = [livedMin, livedMax];
    // pct(v) = clamp01((v-livedMin)/(livedMax-livedMin)). Lived ticks
    // ARE the rail ends. OPZ box clamps to the rail; an extends-beyond
    // cap signals the zone continues past the observed range. Honest
    // labels: the box edge clamps but the OPZ label text stays the TRUE
    // floor/ceiling. All asserted via the pure helper + a focused
    // widget pump for the label-truth check (no eyeballing).

    test('Case MOCKUP — OPZ inside lived: strictly interior, no caps, '
        'true OPZ labels', () {
      // livedMin(3.9) < opzFloor(4.70) < opzCeiling(5.00) < livedMax(5.3)
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [3.9, 4.2, 4.59, 5.3],
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      // Box is a strict interior sub-segment.
      expect(g.opzLeftPct, greaterThan(0.0));
      expect(g.opzRightPct, greaterThan(0.0));
      expect(g.opzWidthPct, lessThan(1.0));
      expect(g.opzLeftPct, lessThan(g.opzCeilingPct));

      // The domain IS the lived range, so the ticks are exactly the
      // rail ends (mockup `left:0` / `right:0`).
      expect(g.livedMinPct, closeTo(0.0, 1e-9));
      expect(g.livedMaxPct, closeTo(1.0, 1e-9));

      // pct(opzFloor) = (4.70-3.9)/(5.3-3.9) = 0.8/1.4 ≈ 0.5714.
      // pct(opzCeiling)=(5.00-3.9)/1.4 = 1.1/1.4 ≈ 0.7857.
      expect(g.opzLeftPct, closeTo(0.5714, 1e-3));
      expect(g.opzCeilingPct, closeTo(0.7857, 1e-3));

      // No extends-beyond caps when the zone fits inside.
      expect(g.leftCap, isFalse);
      expect(g.rightCap, isFalse);

      // OPZ labels are the TRUE floor/ceiling, not clamped positions.
      expect(d.opzFloor, 4.70);
      expect(d.opzCeiling, 5.00);
    });

    testWidgets('Case REAL-DATA — OPZ wider both sides: box fills rail, '
        'BOTH caps, ticks at ends, labels stay TRUE', (tester) async {
      // The exact shape the operator hit: lived 4.3-4.8, OPZ
      // 4.01-4.93, now 4.57. opzFloor < livedMin AND opzCeiling >
      // livedMax.
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.3, 4.45, 4.57, 4.8],
        opzFloor: 4.01,
        opzCeiling: 4.93,
        nowCplh: 4.57,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      // The box clamps to BOTH rail edges (fills the rail).
      expect(g.opzLeftPct, closeTo(0.0, 1e-9),
          reason: 'opzFloor below livedMin clamps box to left edge');
      expect(g.opzRightPct, closeTo(0.0, 1e-9),
          reason: 'opzCeiling above livedMax clamps box to right edge');
      expect(g.opzWidthPct, closeTo(1.0, 1e-9));

      // BOTH extends-beyond caps present.
      expect(g.leftCap, isTrue);
      expect(g.rightCap, isTrue);

      // Lived ticks sit at the very rail ends (domain == lived range).
      expect(g.livedMinPct, closeTo(0.0, 1e-9));
      expect(g.livedMaxPct, closeTo(1.0, 1e-9));

      // now(4.57) interior: pct = (4.57-4.3)/(4.8-4.3) = 0.27/0.5 = 0.54.
      expect(g.nowPct, closeTo(0.54, 1e-9));
      expect(g.nowPct, greaterThan(0.0));
      expect(g.nowPct, lessThan(1.0));

      // HONEST LABELS even when the box clamps: the rendered .opzlab
      // text is the TRUE OPZ floor/ceiling (4.01 / 4.93), NOT the
      // clamped edge values (which would be the lived bounds 4.3/4.8).
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      expect(find.text('OPZ 4.01'), findsOneWidget,
          reason: 'floor label tells the truth though the box is clamped');
      expect(find.text('4.93'), findsOneWidget,
          reason: 'ceiling label tells the truth though the box is clamped');
      expect(find.text('now 4.57'), findsOneWidget);
      // The clamped-position numbers must NOT appear as OPZ labels.
      expect(find.text('OPZ 4.30'), findsNothing);
      expect(find.text('4.80'), findsNothing);
    });

    test('Case ONE-SIDE — only opzCeiling > livedMax: right cap only, '
        'box left inset', () {
      // livedMin(4.2) < opzFloor(4.40); opzCeiling(5.10) > livedMax(4.9).
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.2, 4.5, 4.7, 4.9],
        opzFloor: 4.40,
        opzCeiling: 5.10,
        nowCplh: 4.6,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      // Right cap present, left cap absent.
      expect(g.rightCap, isTrue);
      expect(g.leftCap, isFalse);

      // Box left edge is strictly inset (floor inside the lived range):
      // pct(4.40) = (4.40-4.2)/(4.9-4.2) = 0.2/0.7 ≈ 0.2857.
      expect(g.opzLeftPct, greaterThan(0.0));
      expect(g.opzLeftPct, closeTo(0.2857, 1e-3));
      // Right clamps to the rail edge.
      expect(g.opzRightPct, closeTo(0.0, 1e-9));
      expect(g.opzCeilingPct, closeTo(1.0, 1e-9));
      expect(g.opzWidthPct, lessThan(1.0));
      expect(g.opzWidthPct, greaterThan(0.0));
    });

    test('Case DEGRADED — missing bounds/series: no band, no geometry',
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
