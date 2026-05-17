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

  group('DriverArrowChain — GAP-5 node 2 colour regression', () {
    // The prior code coloured node 2 from
    // `MoneySentiment.fromAxisImpact(counterValue)` — the raw arithmetic
    // sign of the counter axis's dollar contribution. V2-2 forbids
    // value-sign colouring: node 2 colour MUST be the counter LEVER'S
    // catalog sentiment (`LaborModel.isFavorableLever`).
    //
    // This fixture is deliberately chosen so the two derivations
    // DISAGREE (the existing cplh_down/covers_up cases above mask the
    // bug by choosing agreement):
    //
    //   driver  = cplh_down (unfavorable headline)
    //   net     = 500 + (-200) = +$300 → a loss (fromDollarGap)
    //   counter = COVERS axis, v = map['covers_down'] = -200 (opposite
    //             sentiment to the loss net → selected as node 2)
    //   counterId = _signedId(COVERS, -200) → 'covers_down'
    //
    //   OLD (buggy): fromAxisImpact(-200) → -200 <= 0 → favorable →
    //                GREEN.  Wrong: covers_down is catalog-UNFAVORABLE.
    //   NEW (fixed): isFavorableLever('covers_down') == false →
    //                RED (AppColors.negative). Correct.
    const map = <String, double>{
      'cplh_down': 500.0,
      'covers_down': -200.0,
    };

    testWidgets('node 2 colours by counter lever catalog sentiment, '
        'not the contribution arithmetic sign', (tester) async {
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.cplhDown,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      // Node 2 is the COVERS counter-axis, direction token from the
      // resolved 'covers_down' id suffix (raw metric movement).
      expect(find.text('COVERS'), findsOneWidget);
      expect(find.text('↓ under plan'), findsOneWidget);

      // The colour binding is the regression assertion: covers_down is
      // catalog-unfavorable, so node 2 MUST be red. The pre-GAP-5
      // value-sign path (fromAxisImpact on −$200) would have made it
      // green — this asserts that bug is gone.
      expect(
        _textWidget(tester, '↓ under plan').style!.color,
        AppColors.negative,
      );
      expect(
        _textWidget(tester, '↓ under plan').style!.color,
        isNot(AppColors.positive),
      );

      // Net +$300 → loss → red, glyph U+2212 minus (sanity on node 3).
      expect(find.text('−\$300 lost'), findsOneWidget);
      expect(
        _textWidget(tester, '−\$300 lost').style!.color,
        AppColors.negative,
      );
    });
  });

  group('DriverArrowChain — 3-node guarantee (drift fix B)', () {
    // The previously-shipped bug DROPPED the middle counter-axis node
    // whenever no axis carried an OPPOSING-sentiment contribution — the
    // chain then collapsed to a 2-node `cause → result`, diverging from
    // the mockup `.chain` which is ALWAYS 3 nodes
    // (cause → counter-axis → result). These fixtures reproduce the
    // exact 2-node-collapse conditions and assert the middle node now
    // ALWAYS renders (2 arrows ⇒ 3 nodes).

    testWidgets(
        'no opposite-sentiment axis → middle node still renders '
        '(tier-2 dominant non-driver axis)', (tester) async {
      // driver = cplh_down (unfavorable). net = +500 (a loss). The only
      // other axis (splh_down +200) is ALSO adverse — SAME sentiment as
      // the loss net, so the old tier-1-only rule found NO counter-axis
      // and dropped node 2. Tier 2 now picks the dominant non-driver
      // axis (splh) so the chain stays 3 nodes.
      const map = <String, double>{
        'cplh_down': 500.0,
        'splh_down': 200.0,
      };
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.cplhDown,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      // 3 nodes ⇒ exactly 2 connector arrows.
      expect(find.text('→'), findsNWidgets(2));
      expect(find.text('CPLH'), findsOneWidget); // node 1 (driver)
      expect(find.text('SPLH'), findsOneWidget); // node 2 (counter-axis)
      expect(find.text('RESULT'), findsOneWidget); // node 3 (net)
      // net = 500 + 200 = 700 → loss.
      expect(find.text('−\$700 lost'), findsOneWidget);
    });

    testWidgets(
        'single-axis map (no other contributor) → middle node still '
        'renders (tier-3 natural counter-axis)', (tester) async {
      // driver = covers_up (favorable), the ONLY populated axis. No
      // other axis carries ≥ $1, so tiers 1 + 2 find nothing; tier 3
      // falls back to the lever's natural counter-axis so the chain is
      // STILL 3 nodes (mockup `COVERS → CPLH → RESULT`).
      const map = <String, double>{'covers_up': -300.0};
      await tester.pumpWidget(_wrap(
        const DriverArrowChain(
          lever: LeverCards.coversUp,
          dollarImpactByAxis: map,
        ),
      ));
      await tester.pump();

      expect(find.text('→'), findsNWidgets(2)); // 2 arrows ⇒ 3 nodes
      expect(find.text('COVERS'), findsOneWidget); // node 1
      // covers_up's natural counter-axis is CPLH (mockup pairing).
      expect(find.text('CPLH'), findsOneWidget); // node 2
      expect(find.text('RESULT'), findsOneWidget); // node 3
      // net = -300 → a profit (gained).
      expect(find.text('+\$300 gained'), findsOneWidget);
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
