// Registry of all verbatim training documents added by the 2026-07-11
// training-drop slice: one entry per new home-hub bubble, keyed by the
// destination id shared with `barrio_destinations.dart` and
// `barrio_route_map.dart`.

import 'dart:ui';

import '../../widgets/barrio_destination_scaffold.dart';
import 'barrio_training_doc.dart';
import 'training_coffee_content.dart';
import 'training_labour_cost_content.dart';
import 'training_latin_dishes_content.dart';
import 'training_latin_ingredients_content.dart';
import 'training_menu_concept_content.dart';
import 'training_strong_foundation_content.dart';
import 'training_suggestive_selling_content.dart';
import 'training_table_manicuring_content.dart';
import 'training_tequila_content.dart';
import 'training_three_pillars_content.dart';

/// All verbatim training docs, keyed by destination id.
const Map<String, BarrioTrainingDoc> kBarrioTrainingDocs = {
  'training_strong_foundation': kTrainingStrongFoundation,
  'training_table_manicuring': kTrainingTableManicuring,
  'training_three_pillars': kTrainingThreePillars,
  'training_suggestive_selling': kTrainingSuggestiveSelling,
  'training_tequila': kTrainingTequila,
  'training_coffee': kTrainingCoffee,
  'training_latin_dishes': kTrainingLatinDishes,
  'training_latin_ingredients': kTrainingLatinIngredients,
  'training_labour_cost': kTrainingLabourCost,
  'training_menu_concept': kTrainingMenuConcept,
};

/// Per-destination accent bloom color (same convention as the
/// `BarrioColors.accent*` identities owned by the original bubbles).
const Map<String, Color> kBarrioTrainingAccents = {
  'training_strong_foundation': BarrioColors.accentPreston, // warm amber
  'training_table_manicuring': BarrioColors.accentSeafoam,
  'training_three_pillars': BarrioColors.accentPlum,
  'training_suggestive_selling': BarrioColors.accentPlaybook, // emerald
  'training_tequila': BarrioColors.gold,
  'training_coffee': BarrioColors.accentCoffee,
  'training_latin_dishes': BarrioColors.accentHandbook, // brick red
  'training_latin_ingredients': BarrioColors.accentHerb,
  'training_labour_cost': BarrioColors.accentJimTaylor, // royal blue
  'training_menu_concept': BarrioColors.tealWarm,
};
