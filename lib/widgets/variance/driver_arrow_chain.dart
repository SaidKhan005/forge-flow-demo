import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../domain/constants/app_defaults.dart';
import '../../services/labor_model.dart';
import '../../utils/formatters.dart';
import '../money_sentiment.dart';

/// Variance Coaching V2 — the Primary Driver "arrow chain".
///
/// A derived three-node visual (`driver axis → dominant counter-axis →
/// net signed result`) that renders directly ABOVE the existing
/// `whatHappened` sentence on the This Week Primary Driver card so the
/// detected driver reads as cause → effect → net at a glance.
///
/// Authority: `docs/contracts/phase_7_58_primary_driver_contract.md`
/// V2-3 (arrow-chain derivation rule) + V2-2 (sign / sentiment
/// convention). Visual reference: `docs/f&f Coaching/
/// variance_tab_v2_mockup.html` `.chain` / `.cnode` row.
///
/// NO NEW MATH. The chain only consumes the
/// `LaborModel.attributeDollarImpactByAxis` map that the Primary Driver
/// card already computes (signed per-lever-id contributions; positive =
/// adverse / loss, negative = favorable / profit — the same polarity
/// `_DollarAttributionSection` already renders). It never calls the
/// labor model and never re-derives a dollar value.
///
/// GAP-5 (V2-2 colour binding): node 1 colour is the detected lever's
/// catalog `isFavorable`; node 2 colour is the COUNTER lever's catalog
/// sentiment via `LaborModel.isFavorableLever`; node 3 (RESULT/net) is
/// the same loss-vs-gain predicate the hero uses
/// (`MoneySentiment.fromDollarGap`). NONE of the three nodes colour by
/// the raw arithmetic sign of a dollar contribution — that value-sign
/// colouring is the V2-2-forbidden bug this widget no longer commits.
/// The direction token TEXT still derives from the lever id suffix
/// (raw metric movement); only the colour follows sentiment.
///
/// Degraded id (`on_model` / unknown / null lookup) is handled by the
/// caller passing a null [lever]; this widget then renders
/// `SizedBox.shrink()` (no chain at all) so the existing
/// `LeverCardNotYetAvailable` path is untouched. A null
/// [dollarImpactByAxis] (legacy widget tests with no active target
/// profile) also suppresses the chain — there is no attribution to
/// derive nodes 2 and 3 from.
class DriverArrowChain extends StatelessWidget {
  /// The detected primary lever (one of the 16 known ids), or null for
  /// the degraded `on_model` / unknown state. Null → render nothing.
  final LeverCardData? lever;

  /// The per-axis signed dollar map from
  /// `LaborModel.attributeDollarImpactByAxis`, exactly as the Primary
  /// Driver card already computes it. Null → render nothing.
  final Map<String, double>? dollarImpactByAxis;

  const DriverArrowChain({
    super.key,
    required this.lever,
    required this.dollarImpactByAxis,
  });

  // Axis pairs — mirrors `_DollarAttributionSection._axes` in
  // lever_card.dart. `attributeDollarImpactByAxis` only populates one
  // half of each pair, so summing the pair yields the signed per-axis
  // contribution. No new math: this is the same pairing/summation the
  // attribution section already performs.
  static const List<_Axis> _axes = [
    _Axis('COVERS', 'covers_down', 'covers_up'),
    _Axis('PPA', 'ppa_down', 'ppa_up'),
    _Axis('CPLH', 'cplh_down', 'cplh_up'),
    _Axis('SPLH', 'splh_down', 'splh_up'),
    _Axis('FOH WAGE', 'foh_wage_down', 'foh_wage_up'),
    _Axis('BOH WAGE', 'boh_wage_down', 'boh_wage_up'),
    _Axis('FOH HOURS', 'foh_hours_under', 'foh_hours_over'),
    _Axis('BOH HOURS', 'boh_hours_under', 'boh_hours_over'),
  ];

  // Priority order for deterministic tie-breaking (lower index wins),
  // verbatim from `LaborModel._priorityOrder`. Cited by V2-3 so the
  // dominant counter-axis pick is deterministic on ties.
  static const List<String> _priorityOrder = [
    'covers_down', 'covers_up',
    'ppa_down', 'ppa_up',
    'cplh_down', 'cplh_up',
    'splh_down', 'splh_up',
    'foh_wage_down', 'foh_wage_up',
    'boh_wage_down', 'boh_wage_up',
    'foh_hours_over', 'foh_hours_under',
    'boh_hours_over', 'boh_hours_under',
  ];

  static _Axis? _axisForId(String id) {
    for (final a in _axes) {
      if (a.favorableId == id || a.unfavorableId == id) return a;
    }
    return null;
  }

  // The natural counter-axis for a detected driver lever, used ONLY as
  // the last-resort node-2 source when the attribution map carries no
  // other meaningful contributor (so the mockup's THREE-node chain
  // `cause → counter-axis → result` always renders for a detected
  // lever — V2-3 "Three nodes, left to right"). This is a fixed
  // cause→effect pairing off the lever id, NOT new math: it never reads
  // or derives a dollar value. The mockup pairs COVERS↑ with CPLH (the
  // efficiency axis volume masks); each driver maps to the axis its own
  // movement most directly stresses, mirroring the catalog cross-axis
  // story.
  static String _naturalCounterId(String driverId) {
    switch (driverId) {
      // Volume masks / is masked by the efficiency axis (mockup pairing).
      case 'covers_up':
        return 'cplh_down';
      case 'covers_down':
        return 'cplh_up';
      // PPA (sales-mix) reads against CPLH (the staffing it needs to sell).
      case 'ppa_up':
        return 'cplh_down';
      case 'ppa_down':
        return 'cplh_up';
      // CPLH (FOH efficiency) reads against COVERS (the volume that set it).
      case 'cplh_up':
        return 'covers_down';
      case 'cplh_down':
        return 'covers_up';
      // SPLH (BOH throughput) reads against BOH HOURS (the hours behind it).
      case 'splh_up':
        return 'boh_hours_over';
      case 'splh_down':
        return 'boh_hours_under';
      // Wage axes read against their own hours axis (rate vs hours split).
      case 'foh_wage_up':
        return 'foh_hours_under';
      case 'foh_wage_down':
        return 'foh_hours_over';
      case 'boh_wage_up':
        return 'boh_hours_under';
      case 'boh_wage_down':
        return 'boh_hours_over';
      // Hours axes read against their own wage axis.
      case 'foh_hours_over':
        return 'foh_wage_down';
      case 'foh_hours_under':
        return 'foh_wage_up';
      case 'boh_hours_over':
        return 'boh_wage_down';
      case 'boh_hours_under':
        return 'boh_wage_up';
      default:
        return 'cplh_down';
    }
  }

  // Direction token for node 1 (mockup `↑ over plan` / `↓ soft`).
  // Derived from the catalog id suffix (raw metric movement) — NOT new
  // math, just a label off the lever id. Mirrors the mockup wording.
  static String _directionToken(String id) {
    switch (id) {
      case 'covers_up':
        return '↑ over plan';
      case 'covers_down':
        return '↓ under plan';
      case 'ppa_up':
        return '↑ above target';
      case 'ppa_down':
        return '↓ below target';
      case 'cplh_up':
        return '↑ above target';
      case 'cplh_down':
        return '↓ soft';
      case 'splh_up':
        return '↑ above target';
      case 'splh_down':
        return '↓ soft';
      case 'foh_wage_up':
      case 'boh_wage_up':
        return '↑ above model';
      case 'foh_wage_down':
      case 'boh_wage_down':
        return '↓ below model';
      case 'foh_hours_over':
      case 'boh_hours_over':
        return '↑ over model';
      case 'foh_hours_under':
      case 'boh_hours_under':
        return '↓ under model';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final lever = this.lever;
    final map = dollarImpactByAxis;
    // Degraded id / no attribution → render NOTHING. The existing
    // `LeverCardNotYetAvailable` path is untouched (the caller already
    // chose it); this widget simply contributes no chain.
    if (lever == null || map == null) {
      return const SizedBox.shrink();
    }

    // ── Net signed result (node 3) ──────────────────────────────────
    // Sum every per-axis contribution. This is the SAME total
    // `_DollarAttributionSection` computes (sum over signed pairs); the
    // chain consumes it, it does not recompute the gap. Positive total =
    // adverse (a loss); negative total = favorable (a profit).
    double net = 0;
    for (final a in _axes) {
      net += (map[a.unfavorableId] ?? 0) + (map[a.favorableId] ?? 0);
    }
    // V2-2 / GAP-5: node 3 (RESULT/net) sentiment is the SAME loss-vs-gain
    // predicate the hero uses (`MoneySentiment.fromDollarGap`), NOT the
    // value-sign `fromAxisImpact`. The chain net carries the same polarity
    // as the hero's `dollarGap` (positive = an over-best-possible amount
    // the operator LOST = unfavorable / red / "lost"; non-positive = at or
    // under best possible = favorable / green / "gained"). Driving node 3
    // from the same predicate as the hero keeps the chain's result node
    // and the hero number in lockstep. No new math: same `net` value.
    final netSentiment = MoneySentiment.fromDollarGap(net);
    final netIsLoss = !netSentiment.favorable;
    final netColor = netSentiment.color;
    final netGlyph = netSentiment.sign; // U+2212 minus / plus, from C
    final netWord = netIsLoss ? 'lost' : 'gained';
    final netText =
        '$netGlyph\$${Fmt.dollars(net.abs())} $netWord';

    // ── Node 1 — detected driver axis + direction ───────────────────
    final driverAxis = _axisForId(lever.id);
    final node1Label = driverAxis?.label ?? lever.shortLabel.toUpperCase();
    final node1Dir = _directionToken(lever.id);
    // V2-2: color from the lever's favorable flag, never raw sign.
    // Reuse Lane C `MoneySentiment.fromFavorable` — the catalog flag IS
    // the sentiment source.
    final node1Color = MoneySentiment.fromFavorable(lever.isFavorable).color;

    // ── Node 2 — dominant counter-axis (ALWAYS rendered) ────────────
    // V2-3 "Three nodes, left to right": the chain is ALWAYS a 3-node
    // `cause → counter-axis → result` row for a detected lever (the
    // mockup `.chain` is never a 2-node degenerate). The middle node is
    // resolved by a deterministic 3-tier search, no new math (pure
    // selection over the existing attribution map plus a fixed
    // cause→effect pairing off the lever id):
    //
    //   1. PRIMARY (contract V2-3): the axis with the largest absolute
    //      OPPOSING-sentiment contribution (opposite the net result).
    //   2. FALLBACK: if no opposing axis carries ≥ $1, the dominant
    //      non-driver axis by max(|contribution|) regardless of
    //      direction — it still tells the operator what else moved.
    //   3. LAST RESORT: if the map has no other meaningful contributor
    //      at all, the driver lever's natural counter-axis
    //      (`_naturalCounterId`) so a middle node still renders.
    //
    // Tiers 1 + 2 are pure selection over the existing map; ties resolve
    // by `_priorityOrder` (lower index wins) so the visual is
    // deterministic. The previously-shipped bug dropped node 2 whenever
    // tier 1 found nothing — the chain then collapsed to 2 nodes,
    // diverging from the mockup. Tiers 2 + 3 close that gap.
    _Axis? counterAxis;
    double counterValue = 0;
    // Tier 2 bookkeeping: dominant non-driver axis irrespective of
    // sentiment direction (only used if tier 1 finds nothing).
    _Axis? fallbackAxis;
    double fallbackValue = 0;
    for (final a in _axes) {
      if (a == driverAxis) continue; // node 2 is the OPPOSING axis, not self
      final v = (map[a.unfavorableId] ?? 0) + (map[a.favorableId] ?? 0);
      if (v.abs() < 1.0) continue; // ignore noise below $1 (matches UX.1)

      // Tier 2 candidate — dominant non-driver axis by |contribution|.
      {
        final cur = fallbackAxis;
        final bool better;
        if (cur == null) {
          better = true;
        } else if (v.abs() > fallbackValue.abs()) {
          better = true;
        } else if (v.abs() == fallbackValue.abs()) {
          better = _priorityOrder.indexOf(_signedId(a, v)) <
              _priorityOrder.indexOf(_signedId(cur, fallbackValue));
        } else {
          better = false;
        }
        if (better) {
          fallbackAxis = a;
          fallbackValue = v;
        }
      }

      // Tier 1 candidate — "opposite sentiment to the net": when the net
      // is a loss, the counter-axis is one that pushed favorable
      // (v < 0); when the net is a profit, one that pushed adverse
      // (v > 0).
      final isOpposite = netIsLoss ? v < 0 : v > 0;
      if (!isOpposite) continue;
      final current = counterAxis;
      final bool better;
      if (current == null) {
        better = true;
      } else if (v.abs() > counterValue.abs()) {
        better = true;
      } else if (v.abs() == counterValue.abs()) {
        // tie on |value| → lower `_priorityOrder` index wins
        better = _priorityOrder.indexOf(_signedId(a, v)) <
            _priorityOrder.indexOf(_signedId(current, counterValue));
      } else {
        better = false;
      }
      if (better) {
        counterAxis = a;
        counterValue = v;
      }
    }

    // Resolve the node-2 lever id from the 3-tier search. ALWAYS
    // non-null for a detected lever, so the chain is ALWAYS 3 nodes.
    final String counterId;
    if (counterAxis != null) {
      counterId = _signedId(counterAxis, counterValue); // tier 1
    } else if (fallbackAxis != null) {
      counterId = _signedId(fallbackAxis, fallbackValue); // tier 2
    } else {
      counterId = _naturalCounterId(lever.id); // tier 3
    }

    // GAP-5 / V2-2: node 2 color is the COUNTER LEVER'S CATALOG
    // SENTIMENT, never the arithmetic sign of its dollar contribution
    // (`fromAxisImpact` was the value-sign-coloring bug V2-2 forbids:
    // an axis whose contribution sign disagrees with its catalog
    // sentiment was mis-colored). Bind color via
    // `LaborModel.isFavorableLever` off the resolved 3-tier counter id.
    // The direction TOKEN TEXT (`↓ soft` / `↑ over`) still derives from
    // the lever id suffix (raw metric movement) — only the COLOR
    // binding changes. Node 2 is ALWAYS present (V2-3 3-node rule);
    // `_axisForId` resolves its label from the same axis table.
    final counterNodeAxis = _axisForId(counterId);
    final counterLabel =
        counterNodeAxis?.label ?? counterId.toUpperCase();
    final counterSentiment =
        MoneySentiment.fromFavorable(LaborModel.isFavorableLever(counterId));

    final List<Widget> nodes = [
      _ChainNode(
        title: node1Label,
        value: node1Dir,
        color: node1Color,
      ),
      const _ChainArrow(),
      _ChainNode(
        title: counterLabel,
        value: _directionToken(counterId),
        color: counterSentiment.color,
      ),
      const _ChainArrow(),
      _ChainNode(
        title: 'RESULT',
        value: netText,
        color: netColor,
      ),
    ];

    // The chain sits directly above the fused `whatHappened` sentence
    // (the caller renders the sentence immediately beneath with no
    // intervening section — V2-3 "no chart-then-paragraph split").
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      // IntrinsicHeight gives the nodes equal height (mockup
      // `.chain { align-items: stretch }`) without an unbounded
      // vertical constraint inside a scroll view.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: nodes,
        ),
      ),
    );
  }

  // Resolve the populated (signed) lever id for an axis given its
  // current signed value, so `_priorityOrder` lookups use the same id
  // space the labor model uses. No math: just id selection.
  static String _signedId(_Axis a, double v) =>
      v > 0 ? a.unfavorableId : a.favorableId;
}

class _Axis {
  final String label;
  final String favorableId;
  final String unfavorableId;
  const _Axis(this.label, this.favorableId, this.unfavorableId);
}

/// One node of the chain (mockup `.cnode`): mono caption + serif value.
class _ChainNode extends StatelessWidget {
  final String title;
  final String value;
  final Color color;

  const _ChainNode({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        constraints: const BoxConstraints(minWidth: 84),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.cardGlow,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              textAlign: TextAlign.center,
              style: AppTextStyles.mono12(
                color: color,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The connector between nodes (mockup `.carrow` "→").
class _ChainArrow extends StatelessWidget {
  const _ChainArrow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Center(
        child: Text(
          '→', // →
          style: AppTextStyles.mono12(color: AppColors.textMuted),
        ),
      ),
    );
  }
}
