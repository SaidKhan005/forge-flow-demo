// ─── DriverArrowChain tests (Variance Coaching V2, Lane D) ─────────────
// Pins the V2-3 arrow-chain derivation rule + V2-2 sign/sentiment
// convention from docs/contracts/phase_7_58_primary_driver_contract.md.
//
// The widget consumes the SAME signed per-axis map shape
// `LaborModel.attributeDollarImpactByAxis` produces (positive = adverse
// / loss, negative = favorable / profit). These tests pass that map
// directly as a fixture — they assert the chain DERIVATION (node
// selection + sign/sentiment), not any labor-model math, so the engine
// stays provably untouched.
//
// Cases:
//   - covers_up   : favorable headline, net profit → green +$, "gained"
//   - cplh_down   : unfavorable headline, net loss  → red −$, "lost"
//   - degraded    : lever == null  → NO chain (SizedBox.shrink),
//                   LeverCardNotYetAvailable path unaffected.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/variance/driver_arrow_chain.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

Text _textWidget(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

void main() {
  group('DriverArrowChain — favorable headline (covers_up)', () {
    // Net = sum of all contributions. covers favorable (−$686) wins
    // over the adverse cplh (+$462) + splh (+$200) → net −$24 = a
    // profit. Counter-axis = the dominant axis with sentiment OPPOSITE
    // the net (net is profit, so the adverse pusher): cplh at +$462.
    const map = <String, double>{
      'covers_up': -686.0,
      'cplh_down': 462.0,
      'splh_down': 200.0,
    };

    testWidgets('renders 3 nodes: COVERS → CPLH → RESULT profit',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.coversUp,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      // Node 1 — detected driver axis + direction.
      expect(find.text('COVERS'), findsOneWidget);
      expect(find.text('↑ over plan'), findsOneWidget);
      // Node 2 — dominant counter-axis (opposite sentiment to net).
      expect(find.text('CPLH'), findsOneWidget);
      // Node 3 — net signed result. net = -686+462+200 = -24 → profit.
      expect(find.text('RESULT'), findsOneWidget);
      expect(find.text('+\$24 gained'), findsOneWidget);
    });

    testWidgets('node 1 favorable → green; result profit → green',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.coversUp,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      // V2-2: color from the favorable flag, never the raw sign.
      expect(
        _textWidget(tester, '↑ over plan').style!.color,
        AppColors.positive,
      );
      expect(
        _textWidget(tester, '+\$24 gained').style!.color,
        AppColors.positive,
      );
    });
  });

  group('DriverArrowChain — unfavorable headline (cplh_down)', () {
    // cplh adverse (+$462) + splh adverse (+$406) outweigh the
    // favorable covers (−$215) → net +$653 = a loss. Counter-axis =
    // dominant axis with sentiment OPPOSITE the net (net is loss, so
    // the favorable pusher): covers at −$215.
    const map = <String, double>{
      'cplh_down': 462.0,
      'splh_down': 406.0,
      'covers_up': -215.0,
    };

    testWidgets('renders CPLH → COVERS → RESULT loss', (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.cplhDown,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      expect(find.text('CPLH'), findsOneWidget);
      expect(find.text('↓ soft'), findsOneWidget);
      // Counter-axis: covers pushed favorable while net is a loss.
      expect(find.text('COVERS'), findsOneWidget);
      expect(find.text('RESULT'), findsOneWidget);
      // net = 462 + 406 - 215 = 653 → loss.
      expect(find.text('−\$653 lost'), findsOneWidget);
    });

    testWidgets('node 1 unfavorable → red; result loss → red',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.cplhDown,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      expect(
        _textWidget(tester, '↓ soft').style!.color,
        AppColors.negative,
      );
      expect(
        _textWidget(tester, '−\$653 lost').style!.color,
        AppColors.negative,
      );
      // Loss glyph is the U+2212 minus, never ASCII hyphen.
      expect(find.text('-\$653 lost'), findsNothing);
    });
  });

  group('DriverArrowChain — degraded (suppressed)', () {
    testWidgets('lever == null → NO chain (SizedBox.shrink)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: null,
          dollarImpactByAxis: <String, double>{'covers_up': -100.0},
        ),
      ));
      await tester.pump();

      // No nodes at all — the LeverCardNotYetAvailable path the caller
      // chose is left entirely to render the degraded state.
      expect(find.text('RESULT'), findsNothing);
      expect(find.text('COVERS'), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    testWidgets('null attribution map → NO chain', (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.coversUp,
          dollarImpactByAxis: null,
        ),
      ));
      await tester.pump();

      expect(find.text('RESULT'), findsNothing);
      expect(find.text('COVERS'), findsNothing);
    });
  });
}
