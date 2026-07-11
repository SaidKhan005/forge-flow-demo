// Editorial Shelf home redesign (2026-07-11 Barrio Home Redesign V1).
// Plan: docs/phases/barrio_home_redesign_v1/barrio_home_redesign_v1_plan.md
//
// Per-destination visual identity helpers for the home shelf cards.
//
// Icons mirror the per-id `Icons` choices in `barrio_bubble_hub.dart`'s
// `_iconWidgetFor` switch (for `forge_and_flow` / `company_handbook`,
// which render `Image.asset` art in the hub, the shelf uses the hub's
// icon fallbacks). Accents come from `kBarrioTrainingAccents` for every
// training-registry id; non-training ids map to their matching
// `BarrioColors` constants.

import 'package:flutter/material.dart';

import '../../content/training/training_docs.dart';
import '../barrio_destination_scaffold.dart';

/// Forge & Flow logo blue: the hero card accent (mirrors the hub's
/// `_logoBlue`).
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
};

/// Non-training accent identities (the training ids resolve through
/// `kBarrioTrainingAccents` first, so these cover only the ids that are
/// absent from the verbatim training registry).
const Map<String, Color> _kBarrioHomeNonTrainingAccents = <String, Color>{
  'forge_and_flow': kBarrioHomeForgeAccent,
  'preston_lee_model': BarrioColors.accentPreston,
};

/// Icon for a destination card. Falls back to [Icons.circle_outlined]
/// for unknown ids (same fallback as the hub).
IconData barrioHomeIconFor(String id) {
  return _kBarrioHomeIcons[id] ?? Icons.circle_outlined;
}

/// Accent color for a destination card. Training-registry ids use
/// `kBarrioTrainingAccents`; non-training ids use their matching
/// `BarrioColors` constants; unknown ids fall back to the teal brand.
Color barrioHomeAccentFor(String id) {
  final trainingAccent = kBarrioTrainingAccents[id];
  if (trainingAccent != null) return trainingAccent;
  return _kBarrioHomeNonTrainingAccents[id] ?? BarrioColors.tealWarm;
}
