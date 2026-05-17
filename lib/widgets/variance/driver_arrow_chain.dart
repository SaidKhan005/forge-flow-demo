import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import '../../domain/constants/app_defaults.dart';
import '../../utils/formatters.dart';

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
    // V2-2: a loss is unfavorable (red, −$, "lost"); a profit is
    // favorable (green, +$, "gained"). Sentiment drives sign + color
    // together — never the raw arithmetic sign in isolation.
    final netIsLoss = net > 0;
    final netColor = netIsLoss ? AppColors.negative : AppColors.positive;
    final netGlyph = netIsLoss ? '−' : '+'; // U+2212 minus / plus
    final netWord = netIsLoss ? 'lost' : 'gained';
    final netText =
        '$netGlyph\$${Fmt.dollars(net.abs())} $netWord';

    // ── Node 1 — detected driver axis + direction ───────────────────
    final driverAxis = _axisForId(lever.id);
    final node1Label = driverAxis?.label ?? lever.shortLabel.toUpperCase();
    final node1Dir = _directionToken(lever.id);
    // V2-2: color from the lever's favorable flag, never raw sign.
    final node1Color =
        lever.isFavorable ? AppColors.positive : AppColors.negative;

    // ── Node 2 — dominant counter-axis ──────────────────────────────
    // Every axis whose sentiment is OPPOSITE the net result; pick
    // max(|contribution|); ties resolve by `_priorityOrder`. Pure
    // selection over the existing map — no new math.
    _Axis? counterAxis;
    double counterValue = 0;
    for (final a in _axes) {
      if (a == driverAxis) continue; // node 2 is the OPPOSING axis, not self
      final v = (map[a.unfavorableId] ?? 0) + (map[a.favorableId] ?? 0);
      if (v.abs() < 1.0) continue; // ignore noise below $1 (matches UX.1)
      // "Opposite sentiment to the net": when the net is a loss, the
      // counter-axis is one that pushed favorable (v < 0); when the net
      // is a profit, the counter-axis is one that pushed adverse
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

    final List<Widget> nodes = [
      _ChainNode(
        title: node1Label,
        value: node1Dir,
        color: node1Color,
      ),
    ];

    if (counterAxis != null) {
      // counter contribution sign → its raw metric direction. A
      // favorable counter (v < 0) reads "↓ soft" (eased the gap); an
      // adverse counter (v > 0) reads "↑ over". Color follows
      // sentiment (favorable = green, adverse = red) per V2-2.
      final counterIsFavorable = counterValue < 0;
      final counterId = _signedId(counterAxis, counterValue);
      nodes
        ..add(const _ChainArrow())
        ..add(_ChainNode(
          title: counterAxis.label,
          value: _directionToken(counterId),
          color: counterIsFavorable
              ? AppColors.positive
              : AppColors.negative,
        ));
    }

    nodes
      ..add(const _ChainArrow())
      ..add(_ChainNode(
        title: 'RESULT',
        value: netText,
        color: netColor,
      ));

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
