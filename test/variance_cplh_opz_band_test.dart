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
