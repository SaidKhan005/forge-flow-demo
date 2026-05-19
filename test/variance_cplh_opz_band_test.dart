// ─── CPLH-vs-OPZ 60-day band tests (Variance V2 Lane HIST) ──────────────────
//
// Covers the mockup `#hist` "CPLH vs your OPZ · 60-day" card AFTER the
// operator-approved re-model: the band REUSES the proven baseline_tracker
// "CPLH RANGE & TARGET" range model + data source. The outer rail domain
// is `[sixtyDayLow, sixtyDayHigh]` (the lowest / highest CPLH over the
// last 60 days, sourced from `BaselineData.historicalContextRecords` —
// the SAME list `rangeGraphModel` reads for its `histMin`/`histMax`).
// `pct(v) = clamp01((v - scaleMin) / (scaleMax - scaleMin))` mirrors the
// proven band's normalization exactly
// (lib/services/baseline_authority_service.dart:672-680).
//
// Because the rail is the WIDEST real observed bound, the OPZ range sits
// strictly interior in every realistic scenario — the previous bespoke
// clamp + extends-beyond-cap path is gone. The DEGENERATE case (every
// 60-day CPLH identical) mirrors the proven band's `target ± 1.0` guard
// (baseline_authority_service.dart:666-669) using the OPZ midpoint as the
// centring value.
//
// Authority: docs/contracts/phase_7_58_primary_driver_contract.md.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart'
    show BaselineData;
import 'package:forge_and_flow/theme/app_theme.dart' show AppColors;
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
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: null,
        opzCeiling: null,
        nowCplh: 4.5,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('missing 60-day rail bounds → cannot render band', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5, 4.6],
        sixtyDayLowCplh: null,
        sixtyDayHighCplh: null,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('ceiling not above floor → cannot render band', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 5.00,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      expect(d.canRenderBand, isFalse);
    });

    test('weekly series no longer defines the rail; rail is the 60-day '
        'low/high (proven source)', () {
      // The per-week series spans 4.59..4.59 but the rail is the proven
      // 60-day low/high (3.7..5.43), so livedMin/Max no longer drive the
      // rail. The series only feeds weeksBelowFloor/weekCount.
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [0, -1, 4.59],
        sixtyDayLowCplh: 3.7,
        sixtyDayHighCplh: 5.43,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      expect(d.weekCount, 1, reason: 'non-positive obs filtered as noise');
      expect(d.sixtyDayLow, 3.7);
      expect(d.sixtyDayHigh, 5.43);
      // The proven-source rail IS the normalization domain.
      expect(d.scaleMin, 3.7);
      expect(d.scaleMax, 5.43);
    });
  });

  group('CplhOpzBandData.fromInputs — proven-source rail', () {
    test('rail domain == [sixtyDayLow, sixtyDayHigh], all drawn values '
        'normalise inside [0,1]', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.59, 4.62, 4.71],
        sixtyDayLowCplh: 3.67,
        sixtyDayHighCplh: 5.43,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      expect(d.scaleMin, 3.67);
      expect(d.scaleMax, 5.43);
      for (final v in [
        d.sixtyDayLow,
        d.sixtyDayHigh,
        d.opzFloor,
        d.opzCeiling,
        d.now,
      ]) {
        final f = d.fractionFor(v);
        expect(f, inInclusiveRange(0.0, 1.0));
      }
      expect(d.fractionFor(d.opzFloor),
          lessThan(d.fractionFor(d.opzCeiling)));
    });

    test('weeksBelowFloor counts only weeks under the OPZ floor', () {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.1, 4.2, 4.3, 4.4, 4.5, 5.1],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      expect(d.weekCount, 6);
      expect(d.weeksBelowFloor, 5);
    });
  });

  group('OpzScaleGeometry — reused proven model (rail = 60-day low/high)',
      () {
    test('Case TYPICAL (profile A) — OPZ strictly interior, ticks at '
        'rail ends, now interior, true OPZ labels', () {
      // 60-day rail 3.9..5.3; OPZ 4.70..5.00 sits inside it (the
      // universal case: rail is the widest observed bound).
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.59, 4.62, 4.71],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
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

      // The domain IS the 60-day rail, so the ticks are the rail ends
      // (mockup `left:0` / `right:0`).
      expect(g.railLowPct, closeTo(0.0, 1e-9));
      expect(g.railHighPct, closeTo(1.0, 1e-9));

      // pct(opzFloor) = (4.70-3.9)/(5.3-3.9) = 0.8/1.4 ≈ 0.5714.
      // pct(opzCeiling)=(5.00-3.9)/1.4 = 1.1/1.4 ≈ 0.7857.
      expect(g.opzLeftPct, closeTo(0.5714, 1e-3));
      expect(g.opzCeilingPct, closeTo(0.7857, 1e-3));

      // now(4.59) interior: pct = (4.59-3.9)/1.4 ≈ 0.4929.
      expect(g.nowPct, closeTo(0.4929, 1e-3));
      expect(g.nowPct, greaterThan(0.0));
      expect(g.nowPct, lessThan(1.0));

      // OPZ labels are the TRUE floor/ceiling.
      expect(d.opzFloor, 4.70);
      expect(d.opzCeiling, 5.00);
    });

    testWidgets('Case TYPICAL (profile B) — different OPZ still strictly '
        'interior; .opzlab text is the TRUE floor/ceiling', (tester) async {
      // A second representative profile against a wider rail. OPZ
      // 4.25..4.85 strictly inside the 60-day rail 3.67..5.43.
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.40, 4.55, 4.62, 4.71],
        sixtyDayLowCplh: 3.67,
        sixtyDayHighCplh: 5.43,
        opzFloor: 4.25,
        opzCeiling: 4.85,
        nowCplh: 4.62,
      );
      expect(d.canRenderBand, isTrue);
      final g = OpzScaleGeometry.fromData(d);

      expect(g.opzLeftPct, greaterThan(0.0));
      expect(g.opzRightPct, greaterThan(0.0));
      expect(g.opzWidthPct, lessThan(1.0));
      expect(g.railLowPct, closeTo(0.0, 1e-9));
      expect(g.railHighPct, closeTo(1.0, 1e-9));

      // pct(opzFloor)=(4.25-3.67)/(5.43-3.67)=0.58/1.76 ≈ 0.3295.
      // pct(opzCeiling)=(4.85-3.67)/1.76=1.18/1.76 ≈ 0.6705.
      expect(g.opzLeftPct, closeTo(0.3295, 1e-3));
      expect(g.opzCeilingPct, closeTo(0.6705, 1e-3));

      // .opzlab text is the TRUE floor/ceiling, asserted on the widget.
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      expect(find.text('OPZ 4.25'), findsOneWidget);
      expect(find.text('4.85'), findsOneWidget);
      expect(find.text('now 4.62'), findsOneWidget);
    });

    test('Case NOW-AT-EDGE — now == 60-day low/high lands at ~0% / ~100%',
        () {
      final atLow = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [3.9, 4.5],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 3.9, // exactly the 60-day low
      );
      expect(atLow.canRenderBand, isTrue);
      final gLow = OpzScaleGeometry.fromData(atLow);
      expect(gLow.nowPct, closeTo(0.0, 1e-9));
      // Geometry still consistent: OPZ interior, ticks at ends.
      expect(gLow.railLowPct, closeTo(0.0, 1e-9));
      expect(gLow.railHighPct, closeTo(1.0, 1e-9));
      expect(gLow.opzLeftPct, greaterThan(0.0));

      final atHigh = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [5.3, 4.5],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 5.3, // exactly the 60-day high
      );
      final gHigh = OpzScaleGeometry.fromData(atHigh);
      expect(gHigh.nowPct, closeTo(1.0, 1e-9));
      expect(gHigh.opzRightPct, greaterThan(0.0));
    });

    test('Case DEGENERATE (every 60-day CPLH identical) — mirrors the '
        'proven band\'s target±1.0 guard, OPZ ⊆ rail invariant holds, '
        'no bespoke clamp path taken', () {
      // sixtyDayHigh <= sixtyDayLow is the proven band's degenerate
      // trigger (baseline_authority_service.dart:666). The proven band
      // widens to [max(0, target-1), target+1]; here the analogous
      // centring value is the OPZ midpoint (the band has no single
      // "target"). OPZ midpoint = (4.70+5.00)/2 = 4.85, so the widened
      // scale is [3.85, 5.85].
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.85, 4.85],
        sixtyDayLowCplh: 4.85,
        sixtyDayHighCplh: 4.85, // collapsed: high == low
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.85,
      );
      expect(d.canRenderBand, isTrue);
      // The proven-band degenerate widening: [max(0,c-1), c+1], c=4.85.
      expect(d.scaleMin, closeTo(3.85, 1e-9));
      expect(d.scaleMax, closeTo(5.85, 1e-9));

      final g = OpzScaleGeometry.fromData(d);
      // INVARIANT: OPZ ⊆ rail by construction — no value is actually
      // clamped (no bespoke clamp/cap path; only the proven band's own
      // float-safe clamp exists, and it is a no-op here).
      // pct(opzFloor)=(4.70-3.85)/2.0 = 0.425 (strictly interior).
      // pct(opzCeiling)=(5.00-3.85)/2.0 = 0.575 (strictly interior).
      expect(g.opzLeftPct, closeTo(0.425, 1e-9));
      expect(g.opzCeilingPct, closeTo(0.575, 1e-9));
      expect(g.opzLeftPct, greaterThan(0.0));
      expect(g.opzCeilingPct, lessThan(1.0));
      expect(g.opzWidthPct, closeTo(0.15, 1e-9));
    });

    test('Case DEGRADED — missing bounds/series: no band, no geometry',
        () {
      final missingOpz = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.4, 4.5, 4.6],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: null,
        opzCeiling: null,
        nowCplh: 4.5,
      );
      expect(missingOpz.canRenderBand, isFalse);

      final missingRail = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.4, 4.5],
        sixtyDayLowCplh: null,
        sixtyDayHighCplh: null,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.5,
      );
      expect(missingRail.canRenderBand, isFalse);
      // Degraded data carries no scale span, so fractionFor is a safe 0
      // (no fabricated geometry, no divide-by-zero).
      expect(missingRail.fractionFor(4.7), 0.0);
    });
  });

  group('BaselineData proven-source accessors (reused outer rail)', () {
    test('cplhSixtyDayLow/High equal the historicalContextRecords '
        'min/max CPLH — the SAME quantities rangeGraphModel reads', () {
      // These are the exact accessors the History tab passes as the
      // band rail. Assert they match the proven source the
      // baseline_tracker band draws as LOWEST/HIGHEST CPLH LAST 60 DAYS.
      final recs = BaselineData.historicalContextRecords;
      expect(recs, isNotEmpty,
          reason: 'seed 60-day context is always present');
      final cplh = recs.map((r) => r.cplh).toList();
      final expectedLow =
          cplh.reduce((a, b) => a < b ? a : b);
      final expectedHigh =
          cplh.reduce((a, b) => a > b ? a : b);
      expect(BaselineData.cplhSixtyDayLow, expectedLow);
      expect(BaselineData.cplhSixtyDayHigh, expectedHigh);
      // And the rail is wider than (or equal to) any plausible OPZ, so
      // the proven model's "OPZ always interior by construction" holds.
      expect(BaselineData.cplhSixtyDayHigh,
          greaterThan(BaselineData.cplhSixtyDayLow!));
    });
  });

  group('CplhOpzBandCard — render', () {
    testWidgets('populated state renders OPZ + now labels + teaching',
        (tester) async {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.1, 4.2, 4.3, 4.4, 4.5, 5.1],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      expect(find.text('OPZ 4.70'), findsOneWidget);
      expect(find.text('5.00'), findsOneWidget);
      expect(find.text('now 4.59'), findsOneWidget);
      // 60-day low/high tick labels (1 decimal, like the mockup).
      expect(find.text('3.9'), findsOneWidget);
      expect(find.text('5.3'), findsOneWidget);
      expect(
        find.textContaining('What the zone is telling you.'),
        findsOneWidget,
      );
    });

    testWidgets('degraded state shows the honest message, no zone',
        (tester) async {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.5],
        sixtyDayLowCplh: null,
        sixtyDayHighCplh: null,
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
      // are missing.
      expect(find.textContaining(RegExp(r'OPZ \d')), findsNothing);
      expect(find.textContaining(RegExp(r'now \d')), findsNothing);
    });
  });

  group('V2-4 markup is render-only — verbatim fallback', () {
    test('the emphasis token strips to the verbatim sentence', () {
      const marked = 'You have sat [[bad:below it 6 of the last 6 weeks]]. '
          'The volume keeps showing up.';
      const verbatim = 'You have sat below it 6 of the last 6 weeks. '
          'The volume keeps showing up.';
      expect(InlineEmphasisMarkup.stripMarkup(marked), verbatim);
      expect(InlineEmphasisMarkup.stripMarkup(marked).contains('[['), isFalse);
      expect(
          InlineEmphasisMarkup.stripMarkup(marked).contains('—'), isFalse);
    });
  });

  // ─── Teaching copy: bold lead-in + per-variant colour emphasis ────────
  //
  // Mockup parity (docs/f&f Coaching/variance_tab_v2_mockup.html `#hist`
  // `.teach`): the lead-in `What the zone is telling you.` is BOLD on
  // EVERY variant; the unfavourable (below-zone) variant carries a red
  // `[[bad:…]]` span and the favourable (in/above-zone) variant a green
  // `[[good:…]]` span. Numbers must be the REAL computed values, never the
  // mockup literals (no "5 of 6"). The honest no-history variant gets the
  // bold lead but NO colour span (no real stat to grade).
  group('CplhOpzBandCard teaching — bold lead + colour emphasis', () {
    // The card builds the marked-up string privately; we assert on the
    // rendered widget tree (the bold lead-in TextSpan + the sentiment
    // colour of the emphasised stat span) plus an InlineEmphasisMarkup
    // round-trip on the exact real-number sentence the card would emit.

    /// Text runs of ONLY the teaching paragraph (the single RichText whose
    /// first run is the bold lead-in). Scoped this way so the OPZ scale's
    /// own coloured `.opzlab` labels (which legitimately use
    /// AppColors.positive) never bleed into the teaching-copy assertions.
    List<(String, TextStyle?)> runs0(WidgetTester tester) {
      final richTexts = tester.widgetList<RichText>(find.byType(RichText));
      for (final rt in richTexts) {
        final local = <(String, TextStyle?)>[];
        rt.text.visitChildren((span) {
          if (span is TextSpan && span.text != null) {
            local.add((span.text!, span.style));
          }
          return true;
        });
        if (local.isNotEmpty &&
            local.first.$1.startsWith('What the zone is telling you.')) {
          return local;
        }
      }
      return const [];
    }

    bool isBold(TextStyle? s) =>
        s != null && (s.fontWeight?.index ?? 0) >= FontWeight.w700.index;

    // Regression guard for the all-same-weight paragraph defect (prior
    // PRs #961/#964): a plain body run must render at REGULAR weight
    // (strictly below w700). The card now resolves weight at
    // font-creation: plain runs use AppTextStyles.body15 (w400) and
    // bold lead/colour runs use AppTextStyles.body15Bold (w700), instead
    // of a post-hoc `.copyWith(fontWeight: ...)` that google_fonts ignores
    // on a runtime-resolved style.
    bool isRegular(TextStyle? s) =>
        s != null &&
        s.fontWeight != FontWeight.w700 &&
        (s.fontWeight?.index ?? FontWeight.w700.index) <
            FontWeight.w700.index;

    Future<List<(String, TextStyle?)>> pump(
      WidgetTester tester,
      CplhOpzBandData d,
    ) async {
      await tester.pumpWidget(_wrap(CplhOpzBandCard(data: d)));
      await tester.pump();
      return runs0(tester);
    }

    testWidgets('unfavourable (below-zone) variant: bold lead + RED span, '
        'real numbers', (tester) async {
      // 5 of the last 6 weeks below the 4.70 floor (real computed, NOT
      // the mockup literal — these come from the series, not a constant).
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.1, 4.2, 4.3, 4.4, 4.5, 5.1],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.weekCount, 6);
      expect(d.weeksBelowFloor, 5);

      final runs = await pump(tester, d);

      // (a) bold lead-in present, bold weight, default ink (not a
      // sentiment colour).
      final lead = runs.firstWhere(
        (r) => r.$1.startsWith('What the zone is telling you.'),
        orElse: () => ('', null),
      );
      expect(lead.$1, 'What the zone is telling you. ');
      expect(isBold(lead.$2), isTrue, reason: 'lead-in must be bold');
      expect(lead.$2?.color, isNot(AppColors.negative));
      expect(lead.$2?.color, isNot(AppColors.positive));

      // (a2) a PLAIN body run renders at REGULAR weight (not w700) — the
      // whole-paragraph-bold defect would fail this. The intro run "The
      // green band is where ..." is always plain.
      final plain = runs.firstWhere(
        (r) => r.$1.contains('The green band is where'),
        orElse: () => ('', null),
      );
      expect(plain.$1, isNotEmpty, reason: 'plain intro run must exist');
      expect(isBold(plain.$2), isFalse,
          reason: 'plain body must NOT be bold');
      expect(isRegular(plain.$2), isTrue,
          reason: 'plain body must be regular weight (w400)');

      // (b) the key stat span is red (unfavourable) and carries the REAL
      // numbers (5 / 6), not the mockup "5 of 6" literal by coincidence —
      // assert the run text is built from data.weeksBelowFloor/weekCount.
      final badRun = runs.firstWhere(
        (r) => r.$2?.color == AppColors.negative,
        orElse: () => ('', null),
      );
      expect(
        badRun.$1,
        'below it ${d.weeksBelowFloor} of the last ${d.weekCount} weeks',
      );
      // (c) the coloured emphasis span is BOTH red AND bold (mockup
      // `.em-bad {color:red; font-weight:700}`).
      expect(badRun.$2?.color, AppColors.negative);
      expect(isBold(badRun.$2), isTrue,
          reason: 'red emphasis stat must be bold+coloured');
      // No green span in an unfavourable message.
      expect(
        runs.any((r) => r.$2?.color == AppColors.positive),
        isFalse,
      );

      // Verbatim fallback round-trips to the real-number plain sentence.
      const marked = 'You have sat [[bad:below it 5 of the last 6 weeks]]. '
          'The volume keeps showing up. The hours are not tightening to '
          'meet it.';
      expect(
        InlineEmphasisMarkup.stripMarkup(marked),
        'You have sat below it 5 of the last 6 weeks. The volume keeps '
        'showing up. The hours are not tightening to meet it.',
      );
    });

    testWidgets('unfavourable ALL weeks below (n == m): bold lead + RED '
        'span, real numbers', (tester) async {
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.0, 4.1, 4.2, 4.3],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.2,
      );
      expect(d.weekCount, 4);
      expect(d.weeksBelowFloor, 4);

      final runs = await pump(tester, d);

      final lead = runs.firstWhere(
        (r) => r.$1.startsWith('What the zone is telling you.'),
        orElse: () => ('', null),
      );
      expect(lead.$1, 'What the zone is telling you. ');
      expect(isBold(lead.$2), isTrue);

      final badRun = runs.firstWhere(
        (r) => r.$2?.color == AppColors.negative,
        orElse: () => ('', null),
      );
      expect(
        badRun.$1,
        'below it ${d.weeksBelowFloor} of the last ${d.weekCount} weeks',
      );
      expect(
        runs.any((r) => r.$2?.color == AppColors.positive),
        isFalse,
      );
    });

    testWidgets('favourable (in/above zone, n == 0): bold lead + GREEN '
        'span, real numbers', (tester) async {
      // Every one of the last 5 weeks at or above the 4.70 floor → the
      // favourable variant. The green span clause must carry the REAL
      // weekCount (5), not a mockup literal.
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [4.8, 4.9, 5.0, 4.75, 4.72],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.8,
      );
      expect(d.weekCount, 5);
      expect(d.weeksBelowFloor, 0);

      final runs = await pump(tester, d);

      final lead = runs.firstWhere(
        (r) => r.$1.startsWith('What the zone is telling you.'),
        orElse: () => ('', null),
      );
      expect(lead.$1, 'What the zone is telling you. ');
      expect(isBold(lead.$2), isTrue, reason: 'lead-in must be bold');
      expect(lead.$2?.color, isNot(AppColors.positive));
      expect(lead.$2?.color, isNot(AppColors.negative));

      // (a2) a PLAIN body run renders at REGULAR weight (not w700). The
      // "Hold the line: ..." tail is always plain in the favourable copy.
      final plain = runs.firstWhere(
        (r) => r.$1.contains('Hold the line'),
        orElse: () => ('', null),
      );
      expect(plain.$1, isNotEmpty, reason: 'plain tail run must exist');
      expect(isBold(plain.$2), isFalse,
          reason: 'plain body must NOT be bold');
      expect(isRegular(plain.$2), isTrue,
          reason: 'plain body must be regular weight (w400)');

      // (b) the positive stat clause is GREEN and carries the REAL count.
      final goodRun = runs.firstWhere(
        (r) => r.$2?.color == AppColors.positive,
        orElse: () => ('', null),
      );
      expect(
        goodRun.$1,
        'stayed in or above it every one of the last ${d.weekCount} weeks',
      );
      // (c) the coloured emphasis span is BOTH green AND bold (mockup
      // `.em-good {color:green; font-weight:700}`).
      expect(goodRun.$2?.color, AppColors.positive);
      expect(isBold(goodRun.$2), isTrue,
          reason: 'green emphasis stat must be bold+coloured');
      // No red span in a favourable message.
      expect(
        runs.any((r) => r.$2?.color == AppColors.negative),
        isFalse,
      );

      // Verbatim fallback round-trips to the real-number plain sentence.
      const marked =
          'You have [[good:stayed in or above it every one of the last 5 '
          'weeks]]. Hold the line: this is the hours matching the volume.';
      expect(
        InlineEmphasisMarkup.stripMarkup(marked),
        'You have stayed in or above it every one of the last 5 weeks. '
        'Hold the line: this is the hours matching the volume.',
      );
      expect(InlineEmphasisMarkup.stripMarkup(marked).contains('[['),
          isFalse);
    });

    testWidgets('honest no-history variant (m == 0): bold lead, NO colour '
        'span (no real stat to grade)', (tester) async {
      // canRenderBand needs a usable rail + OPZ; series has no positive
      // closed weeks so weekCount == 0 → the honest degraded copy. It
      // still gets the bold lead but NO sentiment span (Metric Honesty:
      // never fabricate a highlight where there is no real stat).
      final d = CplhOpzBandData.fromInputs(
        weeklyCplhSeries: const [0, -1],
        sixtyDayLowCplh: 3.9,
        sixtyDayHighCplh: 5.3,
        opzFloor: 4.70,
        opzCeiling: 5.00,
        nowCplh: 4.59,
      );
      expect(d.canRenderBand, isTrue);
      expect(d.weekCount, 0);

      final runs = await pump(tester, d);

      final lead = runs.firstWhere(
        (r) => r.$1.startsWith('What the zone is telling you.'),
        orElse: () => ('', null),
      );
      expect(lead.$1, 'What the zone is telling you. ');
      expect(isBold(lead.$2), isTrue, reason: 'lead-in must be bold');

      // No fabricated colour emphasis when there is no real stat.
      expect(
        runs.any((r) =>
            r.$2?.color == AppColors.positive ||
            r.$2?.color == AppColors.negative),
        isFalse,
      );
      // The honest wording is preserved.
      expect(
        find.textContaining('Once your weeks close'),
        findsOneWidget,
      );
    });
  });
}
