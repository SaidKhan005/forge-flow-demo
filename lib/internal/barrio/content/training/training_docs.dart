// Registry of all verbatim training documents added by the 2026-07-11
// training-drop slice: one entry per new home-hub bubble, keyed by the
// destination id shared with `barrio_destinations.dart` and
// `barrio_route_map.dart`.

import 'dart:ui';

import '../../widgets/barrio_destination_scaffold.dart';
import 'barrio_training_doc.dart';
import 'company_handbook_verbatim_content.dart';
import 'interview_playbook_verbatim_content.dart';
import 'jim_taylor_verbatim_content.dart';
import 'training_bar_manual_content.dart';
import 'training_bold_by_design_content.dart';
import 'training_cheers_responsibility_content.dart';
import 'training_clover_sop_content.dart';
import 'training_coffee_content.dart';
import 'training_drink_specs_content.dart';
import 'training_food_safety_content.dart';
import 'training_general_words_content.dart';
import 'training_host_manual_content.dart';
import 'training_labour_cost_content.dart';
import 'training_latin_dishes_content.dart';
import 'training_latin_ingredients_content.dart';
import 'training_mastering_metrics_content.dart';
import 'training_menu_content.dart';
import 'training_push_sop_content.dart';
import 'training_recipes_content.dart';
import 'training_strong_foundation_content.dart';
import 'training_suggestive_selling_content.dart';
import 'training_table_manicuring_content.dart';
import 'training_tequila_content.dart';
import 'training_three_pillars_content.dart';
import 'training_wine_content.dart';

/// All verbatim training docs, keyed by destination id.
///
/// Includes the verbatim rebuilds of the three original learning bubbles
/// (operator directive 2026-07-11: everything word-for-word). Their curated
/// interactive content files remain on disk; reversal = restoring the
/// screen cases in `barrio_route_map.dart`.
// Not const: the two SOP manuals carry an operator-facing display title
// (via copyWith) that differs from their verbatim source H1, so the map
// is built at load time rather than as a compile-time constant.
final Map<String, BarrioTrainingDoc> kBarrioTrainingDocs = {
  'company_handbook': kTrainingCompanyHandbook,
  'interview_playbook': kTrainingInterviewPlaybook,
  'jim_taylor_labor_model': kTrainingJimTaylor,
  'training_strong_foundation': kTrainingStrongFoundation,
  'training_table_manicuring': kTrainingTableManicuring,
  'training_three_pillars': kTrainingThreePillars,
  'training_suggestive_selling': kTrainingSuggestiveSelling,
  'training_tequila': kTrainingTequila,
  // Manual-drop slice (2026-08-06): the wine manual sits with Tequila.
  'training_wine': kTrainingWine,
  'training_coffee': kTrainingCoffee,
  'training_latin_dishes': kTrainingLatinDishes,
  'training_latin_ingredients': kTrainingLatinIngredients,
  'training_labour_cost': kTrainingLabourCost,
  // Operator curation 2026-07-11: MENU (dinner menu + history) replaces
  // the full deck; kTrainingMenuConcept stays on disk, parked unrouted.
  'training_menu_concept': kTrainingMenu,
  // Corpus-complete slice (2026-07-11): the remaining 5 knowledge-graph docs.
  'training_bold_by_design': kTrainingBoldByDesign,
  'training_food_safety': kTrainingFoodSafety,
  'training_cheers_responsibility': kTrainingCheersResponsibility,
  'training_mastering_metrics': kTrainingMasteringMetrics,
  'training_general_words': kTrainingGeneralWords,
  // SOP training manuals (Scribe-format point-of-sale + scheduling docs).
  // Operator curation 2026-07-29: presented as '<system> Training' on the
  // home hub and reader header. The source content constants keep their
  // verbatim H1 ('Clover POS' / 'Push Schedule'), so the verbatim guard is
  // unaffected; only the display title is overridden here.
  'training_clover_sop': kTrainingCloverSop.copyWith(title: 'Clover Training'),
  'training_push_sop': kTrainingPushSop.copyWith(title: 'Push Training'),
  // Manual-drop slice (2026-07-28): host, bar, and drink-spec manuals.
  'training_host_manual': kTrainingHostManual,
  'training_bar_manual': kTrainingBarManual,
  'training_drink_specs': kTrainingDrinkSpecs,
  // Manual-drop slice (2026-08-13): the kitchen recipes sit with Drink
  // Specs, so the food recipes read next to the cocktail recipes.
  'training_recipes': kTrainingRecipes,
};

/// Per-destination accent bloom color (same convention as the
/// `BarrioColors.accent*` identities owned by the original bubbles).
const Map<String, Color> kBarrioTrainingAccents = {
  'company_handbook': BarrioColors.accentHandbook, // brick red identity
  'interview_playbook': BarrioColors.accentPlaybook, // emerald identity
  'jim_taylor_labor_model': BarrioColors.accentJimTaylor, // royal blue
  'training_strong_foundation': BarrioColors.accentPreston, // warm amber
  'training_table_manicuring': BarrioColors.accentSeafoam,
  'training_three_pillars': BarrioColors.accentPlum,
  'training_suggestive_selling': BarrioColors.accentPlaybook, // emerald
  'training_tequila': BarrioColors.gold,
  // Manual-drop slice (2026-08-06): plum reads as wine and is unused by any
  // other Food & Drink bubble (Tequila gold, Coffee roasted brown, Drink
  // Specs herb green, Latin Dishes brick red, Menu warm teal).
  'training_wine': BarrioColors.accentPlum, // plum
  'training_coffee': BarrioColors.accentCoffee,
  'training_latin_dishes': BarrioColors.accentHandbook, // brick red
  'training_latin_ingredients': BarrioColors.accentHerb,
  'training_labour_cost': BarrioColors.tealWarm, // cyan: distinct in the Deeper Dive row
  'training_menu_concept': BarrioColors.tealWarm,
  // Corpus-complete slice (2026-07-11): the remaining 5 knowledge-graph docs.
  'training_bold_by_design': BarrioColors.accentSteel, // steel blue
  'training_food_safety': BarrioColors.accentFresh, // fresh green
  'training_cheers_responsibility': BarrioColors.gold,
  'training_mastering_metrics': BarrioColors.accentPlum, // plum: distinct in the Deeper Dive row
  'training_general_words': BarrioColors.tealWarm,
  // SOP training manuals (Scribe-format point-of-sale + scheduling docs).
  'training_clover_sop': BarrioColors.accentSteel, // steel blue
  'training_push_sop': BarrioColors.accentSeafoam,
  // Manual-drop slice (2026-07-28): host, bar, and drink-spec manuals.
  'training_host_manual': BarrioColors.accentPlum, // plum
  'training_bar_manual': BarrioColors.gold, // gold
  'training_drink_specs': BarrioColors.accentHerb, // herb green
  // Manual-drop slice (2026-08-13): steel blue for the stainless steel the
  // recipes themselves call for, and the only cool colour in Food & Drink,
  // so it cannot be confused with its neighbours (MENU warm teal, Drink
  // Specs herb green, Tequila gold, Wine plum, Coffee roasted brown, Latin
  // Dishes brick red, Latin Ingredients herb green).
  'training_recipes': BarrioColors.accentSteel, // steel blue
};
