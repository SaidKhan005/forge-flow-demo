import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../domain/constants/app_defaults.dart';
import '../utils/formatters.dart';
import 'money_sentiment.dart';

/// Renders the deep Primary Driver card. Pass a non-null [data] for one of
/// the 16 known levers; for the `on_model` sentinel or any unknown id,
/// render [LeverCardNotYetAvailable] instead. See
/// `docs/contracts/phase_7_58_primary_driver_contract.md` Finding F-1.
///
/// 7.58.UX.1: when [dollarImpactByAxis] is non-null, the card renders a
/// DOLLAR ATTRIBUTION section between WHAT HAPPENED and WHAT TO STUDY
/// that splits the dollar gap across the 16 lever axes (per
/// `LaborModel.attributeDollarImpactByAxis`). When null, the card
/// renders unchanged.
///
/// 7.58.UX.8: when the cplh / splh row's actual crosses the OPZ ceiling
/// for that axis, the row label is suffixed with ` : team was stretched`
/// so favorable dollars do not silently mask above-ceiling workload risk
/// (Bold by Design Ch. 10). The four optional `actualCPLH` /
/// `opzCeilingCPLH` / `actualSPLH` / `opzCeilingSPLH` params drive the
/// per-axis predicate; when null, the row renders unchanged.
class LeverCardWidget extends StatelessWidget {
  final LeverCardData data;
  final Map<String, double>? dollarImpactByAxis;
  final double? actualCPLH;
  final double? opzCeilingCPLH;
  final double? actualSPLH;
  final double? opzCeilingSPLH;

  const LeverCardWidget({
    super.key,
    required this.data,
    this.dollarImpactByAxis,
    this.actualCPLH,
    this.opzCeilingCPLH,
    this.actualSPLH,
    this.opzCeilingSPLH,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 2, color: AppColors.sunset.withValues(alpha: 0.60)),
          // Header row — badges
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                _Badge(
                  label: data.causeCategory,
                ),
              ],
            ),
          ),
          // Metric title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.metric,
              style: AppTextStyles.mono15(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // WHAT HAPPENED section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'WHAT HAPPENED',
              style: AppTextStyles.mono11(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.whatHappened,
              style: AppTextStyles.body15(color: AppColors.textPrimary),
            ),
          ),
          if (dollarImpactByAxis != null) ...[
            const SizedBox(height: 16),
            _DollarAttributionSection(
              dominantId: data.id,
              dollarImpactByAxis: dollarImpactByAxis!,
              actualCPLH: actualCPLH,
              opzCeilingCPLH: opzCeilingCPLH,
              actualSPLH: actualSPLH,
              opzCeilingSPLH: opzCeilingSPLH,
            ),
          ],
          const SizedBox(height: 16),
          // Divider
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 16),
          // WHAT TO STUDY section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'WHAT TO STUDY',
              style: AppTextStyles.mono11(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              data.teachingNote,
              style: AppTextStyles.body15(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 7.58.UX.1 — DOLLAR ATTRIBUTION section. Sums each lever-id pair into a
/// signed per-axis contribution, then renders:
///   - a primary sentence naming the dominant axis and its slice of the gap
///   - one row per axis whose absolute contribution is at least $1 (rounding
///     noise filtered)
///
/// Sign convention follows `DollarImpactCard`: positive value (over-model)
/// renders as `−$X` in negative color; negative value (under-model) renders
/// as `+$X` in positive color.
class _DollarAttributionSection extends StatelessWidget {
  final String dominantId;
  final Map<String, double> dollarImpactByAxis;
  final double? actualCPLH;
  final double? opzCeilingCPLH;
  final double? actualSPLH;
  final double? opzCeilingSPLH;

  const _DollarAttributionSection({
    required this.dominantId,
    required this.dollarImpactByAxis,
    this.actualCPLH,
    this.opzCeilingCPLH,
    this.actualSPLH,
    this.opzCeilingSPLH,
  });

  // 7.58.UX.8: per-axis "team was stretched" predicate.
  // Annotation fires only when the row's axis is cplh or splh AND the
  // actual exceeded the ceiling for that axis. When either input for
  // an axis is null (no active target profile / legacy week record),
  // the predicate is false and the row renders unchanged.
  bool _isStretched(String axisLabel) {
    if (axisLabel == 'cplh') {
      final actual = actualCPLH;
      final ceiling = opzCeilingCPLH;
      return actual != null && ceiling != null && actual > ceiling;
    }
    if (axisLabel == 'splh') {
      final actual = actualSPLH;
      final ceiling = opzCeilingSPLH;
      return actual != null && ceiling != null && actual > ceiling;
    }
    return false;
  }

  // Pair lever ids into signed axes. `attributeDollarImpactByAxis` only
  // populates one half of each pair, so summing is safe and gives the
  // signed per-axis contribution.
  static const List<_AxisDef> _axes = [
    _AxisDef('covers', 'covers_down', 'covers_up'),
    _AxisDef('ppa', 'ppa_down', 'ppa_up'),
    _AxisDef('cplh', 'cplh_down', 'cplh_up'),
    _AxisDef('splh', 'splh_down', 'splh_up'),
    _AxisDef('foh wage', 'foh_wage_down', 'foh_wage_up'),
    _AxisDef('boh wage', 'boh_wage_down', 'boh_wage_up'),
    _AxisDef('foh hours', 'foh_hours_under', 'foh_hours_over'),
    _AxisDef('boh hours', 'boh_hours_under', 'boh_hours_over'),
  ];

  static String _axisLabelForId(String id) {
    for (final a in _axes) {
      if (a.idA == id || a.idB == id) return a.label;
    }
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final perAxis = <_AxisRow>[];
    double total = 0;
    for (final a in _axes) {
      final aVal = dollarImpactByAxis[a.idA] ?? 0;
      final bVal = dollarImpactByAxis[a.idB] ?? 0;
      final v = aVal + bVal;
      total += v;
      if (v.abs() >= 1.0) {
        // Sentiment source: the model's own signed contribution.
        // `attributeDollarImpactByAxis` pre-encodes sentiment in the
        // sign (positive = adverse, negative = favorable - see
        // `LaborModel` "positive = adverse, negative = favorable").
        // We capture that ONE decision in a single MoneySentiment at
        // render time so the glyph and the color cannot be derived
        // independently; the renderer never re-evaluates `value > 0`.
        perAxis.add(_AxisRow(
          label: a.label,
          value: v,
          favorable: MoneySentiment.fromAxisImpact(v).favorable,
          stretched: _isStretched(a.label),
        ));
      }
    }
    perAxis.sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    final dominantValue = dollarImpactByAxis[dominantId] ?? 0;
    final dominantLabel = _axisLabelForId(dominantId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'DOLLAR ATTRIBUTION',
            style: AppTextStyles.mono11(),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '$dominantLabel explained \$${Fmt.dollars(dominantValue.abs())} '
            'of the \$${Fmt.dollars(total.abs())} gap.',
            style: AppTextStyles.body15(color: AppColors.textPrimary),
          ),
        ),
        if (perAxis.isNotEmpty) ...[
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final row in perAxis) _AttributionRow(row: row),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _AxisDef {
  final String label;
  // The two lever ids that share this axis. `attributeDollarImpactByAxis`
  // populates at most one of them, and pre-encodes sentiment in the SIGN
  // of the contribution (positive = adverse, negative = favorable - see
  // `LaborModel`, consistent with `isFavorableLever`).
  // NOTE: these are deliberately NOT named favorable/unfavorable - e.g.
  // for the covers axis `idA = covers_down` is the UNfavorable id, so a
  // positional/name assumption would mis-color; sentiment is taken from
  // the signed contribution via `MoneySentiment.fromAxisImpact`, never
  // from a positional assumption and never from a raw `value > 0`.
  final String idA;
  final String idB;
  const _AxisDef(this.label, this.idA, this.idB);
}

class _AxisRow {
  final String label;
  final double value;
  // V2-2 sentiment for this row, captured once from the model's signed
  // contribution (`attributeDollarImpactByAxis` encodes sentiment in
  // the sign: negative = favorable, positive = adverse). The renderer
  // reads color AND glyph off this single flag via [MoneySentiment] and
  // never re-evaluates `row.value > 0` independently - that twin
  // independent derivation is exactly the Subject 5b divergence.
  final bool favorable;
  // 7.58.UX.8: when true, the row label is rendered with the
  // ` : team was stretched` suffix (cplh / splh axis whose actual
  // crossed the OPZ ceiling).
  final bool stretched;
  const _AxisRow({
    required this.label,
    required this.value,
    required this.favorable,
    this.stretched = false,
  });
}

class _AttributionRow extends StatelessWidget {
  final _AxisRow row;
  const _AttributionRow({required this.row});

  @override
  Widget build(BuildContext context) {
    // V2-2: color + glyph from the row's sentiment flag (which lever id
    // carried the dollars), never from `row.value > 0`.
    final sentiment = MoneySentiment.fromFavorable(row.favorable);
    final color = sentiment.color;
    final sign = sentiment.sign;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$sign\$${Fmt.dollars(row.value.abs())}',
              style: AppTextStyles.mono12(color: color, weight: FontWeight.w600),
            ),
          ),
          Text(
            row.stretched ? '${row.label} : team was stretched' : row.label,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Degraded shape for Primary Driver surfaces when the row's lever id
/// is the `on_model` sentinel (open / projected snapshot) or any id
/// outside the 16 known levers. Surfaces "row is NOT yet on-model"
/// explicitly so the renderer never overclaims a real driver via the
/// pre-7.58.UX.5 silent fall-through to [LeverCards.coversDown].
class LeverCardNotYetAvailable extends StatelessWidget {
  const LeverCardNotYetAvailable({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 2, color: AppColors.textMuted.withValues(alpha: 0.40)),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: _Badge(label: 'PENDING'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              LeverCards.notYetOnModelLabel.toUpperCase(),
              style: AppTextStyles.mono15(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'No driver has been detected for this row yet. The card '
              'will populate once the shift posts actuals through the '
              'engine.',
              style: AppTextStyles.body15(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;

  const _Badge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.sunset.withValues(alpha: 0.35), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: AppColors.sunsetDark),
      ),
    );
  }
}
