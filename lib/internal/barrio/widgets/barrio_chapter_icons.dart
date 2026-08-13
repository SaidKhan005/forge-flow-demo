// Visual wayfinding icon maps (visual-first pass, recs 2+5).
//
// Every generated training chapter carries the generator's placeholder
// icon code point (0xe865), which the chapter rail's code-point lookup
// does not know, so before this file every generated chapter rendered
// the anonymous Icons.circle_outlined. These maps give list chrome a
// real, meaning-matched icon per chapter, with a per-manual identity
// icon as the fallback.
//
// CHROME ONLY. Nothing here touches manual body text (verbatim-locked)
// or the generated content files; the maps key off the stable ids the
// generator already emits ('<docId>_c<N>').
//
// Curation rules:
//   * Bundled Material `Icons.*` const references ONLY. Never construct
//     IconData from a stored int: that defeats icon tree-shaking.
//   * Icons are matched to chapter MEANING (thermometer for temperature,
//     local_bar for drinks, cleaning for sanitation, ...). Abstract
//     titles (covers, intros, conclusions, A-to-Z glossary ranges) are
//     deliberately left uncurated and fall back to the manual icon
//     rather than forcing a bad metaphor.
//   * [kBarrioManualIcons] mirrors the home shelf's per-destination
//     icons (barrio_home_destination_visuals.dart) so home and reader
//     always agree; test/barrio_chapter_icons_test.dart locks the sync.
//
// Hygiene (enforced by test/barrio_chapter_icons_test.dart): every
// routed doc id has a manual icon; every curated chapter key exists in
// the routed corpus; every routed chapter resolves to a non-circle
// icon.

import 'package:flutter/material.dart';

import '../content/training/training_docs.dart';

/// Per-manual identity icon, keyed by the `kBarrioTrainingDocs`
/// registry id. Values mirror the home shelf bubbles
/// (`barrio_home_destination_visuals.dart`) one for one.
const Map<String, IconData> kBarrioManualIcons = <String, IconData>{
  'company_handbook': Icons.menu_book_rounded,
  'interview_playbook': Icons.assignment_outlined,
  'jim_taylor_labor_model': Icons.show_chart_rounded,
  'training_strong_foundation': Icons.foundation,
  'training_table_manicuring': Icons.table_restaurant_outlined,
  'training_three_pillars': Icons.account_balance_outlined,
  'training_suggestive_selling': Icons.trending_up_rounded,
  'training_tequila': Icons.local_bar_rounded,
  'training_wine': Icons.liquor,
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
  'training_recipes': Icons.soup_kitchen,
};

/// Curated per-chapter icons, keyed by the chapter's stable id (the
/// generator emits globally unique `<docId>_c<N>` ids, so the doc id is
/// embedded in every key). Chapters intentionally absent here (covers,
/// intros, conclusions, glossary A-to-Z ranges) fall back to
/// [kBarrioManualIcons].
const Map<String, IconData> kBarrioChapterIcons = <String, IconData>{
  // -- Company Handbook (25 chapters, all curated) --------------------
  'company_handbook_c0': Icons.storefront, // OUR CONCEPT
  'company_handbook_c1': Icons.place_rounded, // 95 Water Street
  'company_handbook_c2': Icons.history_edu, // Raymonds Legacy
  'company_handbook_c3': Icons.public, // LATIN AMERICA
  'company_handbook_c4': Icons.map_rounded, // Map Of Latin America
  'company_handbook_c5': Icons.flag_rounded, // OUR MISSION
  'company_handbook_c6': Icons.favorite_rounded, // Core Values
  'company_handbook_c7': Icons.badge_rounded, // EMPLOYMENT BASICS
  'company_handbook_c8': Icons.schedule, // REPORTING TO WORK
  'company_handbook_c9': Icons.payments_rounded, // COMPENSATION AND BENEFITS
  'company_handbook_c10': Icons.policy, // WORKPLACE POLICIES
  'company_handbook_c11': Icons.handshake, // EMPLOYEE CONDUCT
  'company_handbook_c12': Icons.checkroom, // PERSONAL APPEARANCE
  'company_handbook_c13': Icons.security, // SECURITY & TECHNOLOGY
  'company_handbook_c14': Icons.trending_up, // PERFORMANCE MANAGEMENT
  'company_handbook_c15': Icons.health_and_safety, // HEALTH AND SAFETY
  'company_handbook_c16': Icons.gavel, // Basic Rights of Workers in Canada
  'company_handbook_c17': Icons.clean_hands, // Food Handler Practices
  'company_handbook_c18': Icons.event_busy, // LEAVE OF ABSENCE
  'company_handbook_c19': Icons.front_hand, // WORKPLACE HARASSMENT POLICY
  'company_handbook_c20': Icons.gpp_maybe, // WORKPLACE VIOLENCE POLICY
  'company_handbook_c21': Icons.volunteer_activism, // Respect
  'company_handbook_c22': Icons.science, // WHIMIS
  'company_handbook_c23': Icons.label_rounded, // WHMIS Labels
  'company_handbook_c24': Icons.warning_amber_rounded, // How Chemicals Enter

  // -- Interview Playbook (14 chapters; c0 Introduction uncurated) ----
  'interview_playbook_c1': Icons.groups, // Building Our Dream Team
  'interview_playbook_c2': Icons.checklist_rounded, // Interview Principles
  'interview_playbook_c3': Icons.search_rounded, // What To Look For
  'interview_playbook_c4': Icons.flag_rounded, // Green Flags V.S Red Flags
  'interview_playbook_c5': Icons.fact_check, // Prescreen Worksheet
  'interview_playbook_c6': Icons.help_outline, // General Interview Questions
  'interview_playbook_c7': Icons.emoji_people, // Host Interview Questions
  'interview_playbook_c8': Icons.room_service, // Server Assistant Questions
  'interview_playbook_c9': Icons.local_bar, // Bartender Interview Questions
  'interview_playbook_c10': Icons.restaurant, // Server Interview Questions
  'interview_playbook_c11': Icons.wash, // Dishwasher Interview Questions
  'interview_playbook_c12': Icons.soup_kitchen, // Line Cook Questions
  'interview_playbook_c13': Icons.lightbulb_outline, // Final Thought

  // -- Jim Taylor Labor Model (13 chapters, all curated) ---------------
  'jim_taylor_labor_model_c0': Icons.query_stats, // How the Metrics Work
  'jim_taylor_labor_model_c1': Icons.foundation, // The Foundation
  'jim_taylor_labor_model_c2': Icons.percent, // Labor % and Why It Lies
  'jim_taylor_labor_model_c3': Icons.input, // The 4 Inputs
  'jim_taylor_labor_model_c4': Icons.people_alt, // CPLH
  'jim_taylor_labor_model_c5': Icons.play_circle_outline, // CPLH In Action
  'jim_taylor_labor_model_c6': Icons.attach_money, // SPLH
  'jim_taylor_labor_model_c7': Icons.balance, // CPLH and SPLH Together
  'jim_taylor_labor_model_c8': Icons.functions, // Theoretical Labor
  'jim_taylor_labor_model_c9': Icons.calendar_today, // 60-Day Tracking
  'jim_taylor_labor_model_c10': Icons.compare_arrows, // Variance: The Gap
  'jim_taylor_labor_model_c11': Icons.speed, // Optimal Productivity Zone
  'jim_taylor_labor_model_c12': Icons.auto_stories, // Reading the Full Story

  // -- BOLD By Design (34 chapters; cover, intro, conclusion, back
  //    cover uncurated) ------------------------------------------------
  'training_bold_by_design_c2': Icons.visibility_off, // The Labor Illusion
  'training_bold_by_design_c3': Icons.tune, // Three Levers
  'training_bold_by_design_c4': Icons.merge_type, // Best Version vs. Conv.
  'training_bold_by_design_c5': Icons.money_off, // The Profit Gap
  'training_bold_by_design_c6': Icons.calculate, // Core Labor Equation
  'training_bold_by_design_c7': Icons.room_service, // Productivity (FOH)
  'training_bold_by_design_c8': Icons.soup_kitchen, // Productivity (BOH)
  'training_bold_by_design_c9': Icons.fitness_center, // Workload Factor
  'training_bold_by_design_c10': Icons.speed, // Optimal Productivity Zone
  'training_bold_by_design_c11': Icons.arrow_upward, // Productivity Too High
  'training_bold_by_design_c12': Icons.arrow_downward, // Productivity Too Low
  'training_bold_by_design_c13': Icons.balance, // Productivity Balance
  'training_bold_by_design_c14': Icons.fitness_center, // Workload Factor
  'training_bold_by_design_c15': Icons.speed, // Optimal Productivity Zone
  'training_bold_by_design_c16': Icons.upgrade, // Addressing Too Low
  'training_bold_by_design_c17': Icons.vertical_align_center, // Too High
  'training_bold_by_design_c18': Icons.sync_alt, // Cross-Department Balance
  'training_bold_by_design_c19': Icons.event_note, // Scheduling vs Volume
  'training_bold_by_design_c20': Icons.group_add, // Psych. of Overstaffing
  'training_bold_by_design_c21': Icons.group_remove, // Psych. of Understaffing
  'training_bold_by_design_c22': Icons.settings, // The Productivity System
  'training_bold_by_design_c23': Icons.rocket_launch, // To Execution
  'training_bold_by_design_c24': Icons.design_services, // For Consistency
  'training_bold_by_design_c25': Icons.auto_graph, // Optimization
  'training_bold_by_design_c26': Icons.loop, // Sustaining the System
  'training_bold_by_design_c27': Icons.manage_accounts, // Operator's Role
  'training_bold_by_design_c28': Icons.timeline, // Long-Term Impact
  'training_bold_by_design_c29': Icons.shield_outlined, // Protecting Culture
  'training_bold_by_design_c30': Icons.emoji_events, // Best Version
  'training_bold_by_design_c31': Icons.psychology, // Productivity Mindset

  // -- Cheers Responsibility (5 chapters; c0 title page uncurated) ------
  'training_cheers_responsibility_c1': Icons.account_balance, // Governing
  'training_cheers_responsibility_c2': Icons.corporate_fare, // NLLC
  'training_cheers_responsibility_c3': Icons.card_membership, // Licenses
  'training_cheers_responsibility_c4': Icons.note_add, // Secondary Licenses

  // -- Coffee (14 chapters; c0 What Is Coffee uncurated) ---------------
  'training_coffee_c1': Icons.local_fire_department, // Roasting
  'training_coffee_c2': Icons.warning_amber_rounded, // Enemies of Coffee
  'training_coffee_c3': Icons.inventory_2, // Proper Storage
  'training_coffee_c4': Icons.public, // Brazilian Coffee
  'training_coffee_c5': Icons.landscape, // Colombian Coffee
  'training_coffee_c6': Icons.coffee_maker, // Extracting Espresso
  'training_coffee_c7': Icons.water_drop, // Milk
  'training_coffee_c8': Icons.build, // Troubleshooting
  'training_coffee_c9': Icons.cleaning_services, // Cleaning & Maintenance
  'training_coffee_c10': Icons.emoji_food_beverage, // Drinks
  'training_coffee_c11': Icons.coffee, // Our Coffee
  'training_coffee_c12': Icons.free_breakfast, // Cup Types
  'training_coffee_c13': Icons.translate, // Words to Know

  // -- Food Safety (21 chapters; c0 What Is Food Safety uncurated) -----
  'training_food_safety_c1': Icons.gavel, // Governing Laws
  'training_food_safety_c2': Icons.clean_hands, // Personal Hygiene
  'training_food_safety_c3': Icons.sick, // Foodborne Illness
  'training_food_safety_c4': Icons.coronavirus, // Contamination
  'training_food_safety_c5': Icons.category, // Categories of Hazards
  'training_food_safety_c6': Icons.report_problem, // Hazards In Food
  'training_food_safety_c7': Icons.no_food, // Food Allergies
  'training_food_safety_c8': Icons.verified_user, // Keep Your Guests Safe
  'training_food_safety_c9': Icons.thermostat, // Temperature Danger Zone
  'training_food_safety_c10': Icons.table_chart, // TDZ Reference
  'training_food_safety_c11': Icons.ac_unit, // Cooling And Reheating
  'training_food_safety_c12': Icons.thermostat_auto, // Thermometer Calib.
  'training_food_safety_c13': Icons.science, // Ice Bath Calibration
  'training_food_safety_c14': Icons.kitchen, // Safe Storage
  'training_food_safety_c15': Icons.rotate_right, // FIFO
  'training_food_safety_c16': Icons.label, // Labelling
  'training_food_safety_c17': Icons.cleaning_services, // Sanitation
  'training_food_safety_c18': Icons.checklist, // HACCP
  'training_food_safety_c19': Icons.local_bar, // Bar Food Safety
  'training_food_safety_c20': Icons.room_service, // Food Servers Role

  // -- General Words: glossary A-to-Z ranges, all uncurated (manual
  //    icon Icons.translate_rounded reads correctly on every range) ----

  // -- Labour Cost (12 chapters; c0 title chapter uncurated) ------------
  'training_labour_cost_c1': Icons.percent, // Labour Percentage
  'training_labour_cost_c2': Icons.visibility_off, // What It Doesn't Tell
  'training_labour_cost_c3': Icons.functions, // True Labour % Formula
  'training_labour_cost_c4': Icons.payments, // Average Wage
  'training_labour_cost_c5': Icons.receipt_long, // Average Guest Check
  'training_labour_cost_c6': Icons.speed, // Productivity
  'training_labour_cost_c7': Icons.calendar_view_day, // Days and Day Parts
  'training_labour_cost_c8': Icons.account_tree, // Contributing Factors
  'training_labour_cost_c9': Icons.manage_accounts, // Operator Resp.
  'training_labour_cost_c10': Icons.warning_amber_rounded, // Signs of Inbal.
  'training_labour_cost_c11': Icons.balance, // Balancing the System

  // -- Latin Dishes / Latin Ingredients: glossary A-to-Z ranges, all
  //    uncurated (manual icons restaurant_rounded / eco_rounded) --------

  // -- Mastering The Metrics (8 chapters; c0 title uncurated) -----------
  'training_mastering_metrics_c1': Icons.receipt_long, // Average Guest Check
  'training_mastering_metrics_c2': Icons.people, // Covers
  'training_mastering_metrics_c3': Icons.people_alt, // CPLH
  'training_mastering_metrics_c4': Icons.emoji_objects, // Servers Knowing AGC
  'training_mastering_metrics_c5': Icons.trending_up, // Increasing AGC
  'training_mastering_metrics_c6': Icons.tune, // Factors That AGC
  'training_mastering_metrics_c7': Icons.track_changes, // Set Goals

  // -- MENU (routed training_menu_concept doc, 7 chapters, all curated) -
  'training_menu_concept_c0': Icons.menu_book, // Dinner Menu
  'training_menu_concept_c1': Icons.account_balance, // The Civilizations
  'training_menu_concept_c2': Icons.set_meal, // Ceviches: The Story
  'training_menu_concept_c3': Icons.tapas, // Shareables: The Story
  'training_menu_concept_c4': Icons.dinner_dining, // Mains: The Story
  'training_menu_concept_c5': Icons.rice_bowl, // Sides: The Story
  'training_menu_concept_c6': Icons.history_edu, // Legacy

  // -- Strong Foundation (7 chapters; c0 title uncurated) ---------------
  'training_strong_foundation_c1': Icons.handshake, // Trust and Loyalty
  'training_strong_foundation_c2': Icons.workspace_premium, // Brand Strength
  'training_strong_foundation_c3': Icons.construction, // Improve Operations
  'training_strong_foundation_c4': Icons.key, // Key Areas
  'training_strong_foundation_c5': Icons.trending_up, // Increase Profit.
  'training_strong_foundation_c6': Icons.rule, // Standards and Consistency

  // -- Suggestive Selling (6 chapters; c0 title uncurated) --------------
  'training_suggestive_selling_c1': Icons.sell, // Selling Strategies
  'training_suggestive_selling_c2': Icons.record_voice_over, // Sugg. Selling
  'training_suggestive_selling_c3': Icons.error_outline, // Improper Exec.
  'training_suggestive_selling_c4': Icons.handyman, // Tools
  'training_suggestive_selling_c5': Icons.track_changes, // Setting Goals

  // -- Table Manicuring (6 chapters; c0 Introduction uncurated) ---------
  'training_table_manicuring_c1': Icons.cleaning_services, // Maintenance
  'training_table_manicuring_c2': Icons.list_alt, // Maintenance Basics
  'training_table_manicuring_c3': Icons.auto_fix_high, // Table Manicuring
  'training_table_manicuring_c4': Icons.diamond, // Refined Principles
  'training_table_manicuring_c5': Icons.emoji_events, // High-Level Execution

  // -- Tequila (6 chapters; c0 title uncurated) --------------------------
  'training_tequila_c1': Icons.agriculture, // How Tequila Is Made
  'training_tequila_c2': Icons.category, // Classes of Tequila
  'training_tequila_c3': Icons.nightlife, // Popular Tequila Cocktails
  'training_tequila_c4': Icons.local_fire_department, // Mezcal
  'training_tequila_c5': Icons.room_service, // How to Serve Tequila

  // -- Three Pillars (5 chapters; c0 title uncurated: the manual's
  //    account_balance pillars icon IS the title metaphor) ---------------
  'training_three_pillars_c1': Icons.wb_sunny, // Atmosphere
  'training_three_pillars_c2': Icons.room_service, // Service
  'training_three_pillars_c3': Icons.restaurant, // Food
  'training_three_pillars_c4': Icons.balance, // Balancing
};

/// Matches the generator's `<docId>_c<N>` chapter id shape and captures
/// the doc id prefix.
final RegExp _kChapterIdPattern = RegExp(r'^(.+)_c\d+$');

/// The doc id embedded in a generated chapter id, or null when the id
/// does not follow the `<docId>_c<N>` shape (e.g. the curated Company
/// Handbook screen's own chapter ids, which resolve via their real
/// icon code points before ever reaching these maps).
String? barrioDocIdOfChapter(String chapterId) {
  return _kChapterIdPattern.firstMatch(chapterId)?.group(1);
}

/// Wayfinding icon for a chapter id: curated chapter icon, else the
/// owning manual's identity icon, else [Icons.circle_outlined].
IconData barrioChapterIconFor(String chapterId) {
  final curated = kBarrioChapterIcons[chapterId];
  if (curated != null) return curated;
  final docId = barrioDocIdOfChapter(chapterId);
  if (docId != null) {
    final manual = kBarrioManualIcons[docId];
    if (manual != null) return manual;
  }
  return Icons.circle_outlined;
}

/// Wayfinding icon for a chapter addressed by registry position
/// (docId + chapter index), the coordinate space search results and
/// bookmarks carry. Falls back to the manual icon, then
/// [Icons.circle_outlined].
IconData barrioChapterIconAt(String docId, int chapterIndex) {
  final doc = kBarrioTrainingDocs[docId];
  if (doc != null && chapterIndex >= 0 && chapterIndex < doc.chapters.length) {
    final curated = kBarrioChapterIcons[doc.chapters[chapterIndex].id];
    if (curated != null) return curated;
  }
  return kBarrioManualIcons[docId] ?? Icons.circle_outlined;
}

/// Manual identity icon for a routed doc id, or null for ids outside
/// the registry (callers decide their own honest fallback).
IconData? barrioManualIconOrNull(String docId) => kBarrioManualIcons[docId];

/// Chapter-or-manual icon, or null when neither resolves (e.g. test
/// fixture docs): callers render nothing rather than a bogus glyph.
IconData? barrioChapterIconOrManual(String docId, String chapterId) {
  return kBarrioChapterIcons[chapterId] ?? kBarrioManualIcons[docId];
}
