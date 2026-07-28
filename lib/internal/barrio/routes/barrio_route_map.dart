import 'package:flutter/material.dart';
import 'barrio_destinations.dart';
import 'barrio_preview_role.dart';
import '../content/training/training_docs.dart';
import '../screens/barrio_home_screen.dart';
import '../screens/forge_and_flow_destination_screen.dart';
import '../screens/preston_lee_model_coming_soon_screen.dart';
import '../screens/supervisor_content_screen_placeholder.dart';
import '../screens/training_doc_screen.dart';
import '../widgets/barrio_destination_scaffold.dart';

/// Typed route map for the Barrio internal shell.
///
/// Every Barrio destination has exactly one route entry here.
/// The shell reads this map to navigate -- no stringly-typed
/// route switching is embedded in widgets.
///
/// This is a private internal route map. It is not registered
/// in the public Forge & Flow `MaterialApp` route table.
class BarrioRouteMap {
  BarrioRouteMap._();

  /// The home route -- the Barrio shell root.
  static const String home = '/barrio';

  /// Route path for each destination, keyed by destination id.
  static const Map<String, String> destinationPaths = {
    'forge_and_flow': '/barrio/forge-and-flow',
    'company_handbook': '/barrio/company-handbook',
    'interview_playbook': '/barrio/interview-playbook',
    'jim_taylor_labor_model': '/barrio/jim-taylor-labor-model',
    'preston_lee_model': '/barrio/preston-lee-model',
    'supervisor_content': '/barrio/supervisor-content',
    'training_strong_foundation': '/barrio/training/strong-foundation',
    'training_table_manicuring': '/barrio/training/table-manicuring',
    'training_three_pillars': '/barrio/training/three-pillars',
    'training_suggestive_selling': '/barrio/training/suggestive-selling',
    'training_tequila': '/barrio/training/tequila',
    'training_coffee': '/barrio/training/coffee',
    'training_latin_dishes': '/barrio/training/latin-dishes',
    'training_latin_ingredients': '/barrio/training/latin-ingredients',
    'training_labour_cost': '/barrio/training/labour-cost',
    'training_menu_concept': '/barrio/training/menu-concept',
    'training_bold_by_design': '/barrio/training/bold-by-design',
    'training_food_safety': '/barrio/training/food-safety',
    'training_cheers_responsibility': '/barrio/training/responsible-service',
    'training_mastering_metrics': '/barrio/training/mastering-metrics',
    'training_general_words': '/barrio/training/general-words',
    'training_clover_sop': '/barrio/training/clover-sop',
    'training_push_sop': '/barrio/training/push-schedule',
    'training_host_manual': '/barrio/training/host-manual',
    'training_bar_manual': '/barrio/training/bar-manual',
    'training_drink_specs': '/barrio/training/drink-specs',
  };

  /// Returns the route path for a [BarrioDestination] by its id.
  static String pathFor(BarrioDestination destination) {
    return destinationPaths[destination.id] ?? home;
  }

  /// Builds the destination screen widget for a given destination id.
  ///
  /// [previewRole] defaults to [BarrioPreviewRole.admin] so direct
  /// construction in tests remains safe.
  ///
  /// [initialChapterIndex] (Wave B training search) deep-links a
  /// training document to a specific section. It threads to
  /// [TrainingDocScreen] ONLY; every other destination ignores it.
  /// Null now means "no explicit deep link", which lets the training
  /// screen resume the locally saved reading position ("the app
  /// remembers you", 2026-07-22); any non-null value, including 0, is
  /// an explicit deep link and always wins over resume.
  static Widget screenFor(
    String destinationId, {
    BarrioPreviewRole previewRole = BarrioPreviewRole.admin,
    int? initialChapterIndex,
    int? initialUnitInChapter,
    String? highlightQuery,
  }) {
    switch (destinationId) {
      case 'forge_and_flow':
        return ForgeAndFlowDestinationScreen(previewRole: previewRole);
      // 2026-07-11 word-for-word directive: company_handbook,
      // interview_playbook, and jim_taylor_labor_model now resolve through
      // the verbatim training registry in the default branch below. Their
      // curated screens remain on disk; reversal = restoring their cases.
      case 'preston_lee_model':
        return PrestonLeeModelComingSoonScreen(previewRole: previewRole);
      case 'supervisor_content':
        return SupervisorContentScreenPlaceholder(previewRole: previewRole);
      default:
        final trainingDoc = kBarrioTrainingDocs[destinationId];
        if (trainingDoc != null) {
          return TrainingDocScreen(
            doc: trainingDoc,
            accent: kBarrioTrainingAccents[destinationId] ??
                BarrioColors.tealWarm,
            previewRole: previewRole,
            initialChapterIndex: initialChapterIndex,
            initialUnitInChapter: initialUnitInChapter,
            highlightQuery: highlightQuery,
          );
        }
        return const BarrioHomeScreen();
    }
  }

  /// Pushes the destination screen for [destination] onto the navigator.
  ///
  /// [initialChapterIndex] threads through [screenFor] to
  /// [TrainingDocScreen] only (see [screenFor]).
  static void navigateTo(
    BuildContext context,
    BarrioDestination destination, {
    BarrioPreviewRole previewRole = BarrioPreviewRole.admin,
    int? initialChapterIndex,
    int? initialUnitInChapter,
    String? highlightQuery,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => screenFor(
          destination.id,
          previewRole: previewRole,
          initialChapterIndex: initialChapterIndex,
          initialUnitInChapter: initialUnitInChapter,
          highlightQuery: highlightQuery,
        ),
      ),
    );
  }
}
