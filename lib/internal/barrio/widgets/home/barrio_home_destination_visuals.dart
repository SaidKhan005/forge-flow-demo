// Barrio home revision (2026-07-11, operator decision): one-scroll
// round-bubble layout. Original Editorial Shelf helpers (Barrio Home
// Redesign V1, plan:
// docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md)
// extended with the hub-faithful icon widget the round bubbles need.
//
// Per-destination visual identity helpers for the home surface.
//
// [barrioHomeIconWidgetFor] mirrors `barrio_bubble_hub.dart`'s
// `_iconWidgetFor` verbatim, including the two `Image.asset` cases
// (`forge_and_flow` and `company_handbook`) with icon errorBuilder
// fallbacks so widget tests (which load no real asset bytes) never
// throw. [barrioHomeAccentFor] mirrors the hub's `_destinationAccents`
// resolution: hub-exact overrides first, then `kBarrioTrainingAccents`,
// then the teal brand fallback.
//
// The retired shelf cards' [barrioHomeIconFor] IconData lookup stays in
// place because the parked card widgets still compile against it
// (hide-only doctrine: the cards are no longer composed, not deleted).

import 'package:flutter/material.dart';

import '../../content/training/training_docs.dart';
import '../barrio_destination_scaffold.dart';

/// Forge & Flow logo blue (mirrors the hub's `_logoBlue`).
const Color kBarrioHomeForgeAccent = Color(0xFF2E6EE0);

/// Per-id icon choices, mirroring `barrio_bubble_hub.dart`.
const Map<String, IconData> _kBarrioHomeIcons = <String, IconData>{
  'forge_and_flow': Icons.show_chart_rounded,
  'company_handbook': Icons.menu_book_rounded,
  'jim_taylor_labor_model': Icons.show_chart_rounded,
  'interview_playbook': Icons.assignment_outlined,
  'preston_lee_model': Icons.lightbulb_outline,
  'training_strong_foundation': Icons.foundation,
  'training_table_manicuring': Icons.table_restaurant_outlined,
  'training_three_pillars': Icons.account_balance_outlined,
  'training_suggestive_selling': Icons.trending_up_rounded,
  'training_tequila': Icons.local_bar_rounded,
  'training_coffee': Icons.local_cafe_rounded,
  'training_latin_dishes': Icons.restaurant_rounded,
  'training_latin_ingredients': Icons.eco_rounded,
  'training_labour_cost': Icons.insights_rounded,
  'training_menu_concept': Icons.restaurant_menu_rounded,
  'training_bold_by_design': Icons.auto_stories_rounded,
  'training_food_safety': Icons.health_and_safety_rounded,
  'training_cheers_responsibility': Icons.wine_bar_rounded,
  'training_mastering_metrics': Icons.query_stats_rounded,
  'training_general_words': Icons.translate_rounded,
  'training_clover_sop': Icons.point_of_sale,
  'training_push_sop': Icons.calendar_month,
  'training_host_manual': Icons.support_agent,
  'training_bar_manual': Icons.local_bar,
  'training_drink_specs': Icons.wine_bar,
};

/// Hub-exact accent overrides, mirroring `barrio_bubble_hub.dart`'s
/// `_destinationAccents` for the ids that are absent from (or differ
/// from) the verbatim training registry:
///   * `interview_playbook` uses the hub's forest green (0xFF1EA870),
///     which is more vivid than the registry's emerald identity.
///   * `forge_and_flow` / `preston_lee_model` / `supervisor_content`
///     have no training-registry entry at all.
const Map<String, Color> _kBarrioHomeHubAccentOverrides = <String, Color>{
  'forge_and_flow': kBarrioHomeForgeAccent,
  'interview_playbook': Color(0xFF1EA870), // forest green (hub value)
  'preston_lee_model': BarrioColors.accentPreston,
  'supervisor_content': Color(0xFF6080A8),
};

/// Icon for a destination card. Falls back to [Icons.circle_outlined]
/// for unknown ids (same fallback as the hub).
IconData barrioHomeIconFor(String id) {
  return _kBarrioHomeIcons[id] ?? Icons.circle_outlined;
}

/// Accent color for a destination bubble. Hub-exact overrides first,
/// then `kBarrioTrainingAccents` for training-registry ids, then the
/// teal brand fallback (same resolution as the hub).
Color barrioHomeAccentFor(String id) {
  final override = _kBarrioHomeHubAccentOverrides[id];
  if (override != null) return override;
  final trainingAccent = kBarrioTrainingAccents[id];
  if (trainingAccent != null) return trainingAccent;
  return BarrioColors.tealWarm;
}

/// The correct icon/image widget for a destination bubble, mirroring
/// the hub's `_iconWidgetFor` verbatim: `forge_and_flow` renders the
/// Forge & Flow logo asset at [size] and `company_handbook` renders the
/// decorative handbook leaf at `size * 2.4`; both carry errorBuilder
/// icon fallbacks so test environments (which don't load real asset
/// bytes) fall back to an icon rather than throwing. Every other id
/// resolves through the shared per-id icon map.
Widget barrioHomeIconWidgetFor(
  BuildContext context,
  String id,
  double size,
  Color accent,
  bool isDimmed,
) {
  final color = isDimmed
      ? BarrioColors.textMuted.withValues(alpha: 0.4)
      : accent;
  final dpr = MediaQuery.devicePixelRatioOf(context);

  int? cacheDimension(double logicalSize) {
    final px = (logicalSize * dpr).round();
    return px > 0 ? px : null;
  }

  switch (id) {
    case 'forge_and_flow':
      return Image.asset(
        'assets/images/forge_flow_new_icon.png',
        width: size,
        height: size,
        cacheWidth: cacheDimension(size),
        cacheHeight: cacheDimension(size),
        color: isDimmed ? color : null,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.show_chart_rounded, size: size, color: color),
      );
    case 'company_handbook':
      return Image.asset(
        'assets/internal/barrio/handbook_icon.png',
        width: size * 2.4,
        height: size * 2.4,
        cacheWidth: cacheDimension(size * 2.4),
        cacheHeight: cacheDimension(size * 2.4),
        color: isDimmed ? color : null,
        errorBuilder: (_, __, ___) =>
            Icon(Icons.menu_book_rounded, size: size, color: color),
      );
    default:
      return Icon(barrioHomeIconFor(id), size: size, color: color);
  }
}
