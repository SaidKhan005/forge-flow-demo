// Typed destination manifest for the Barrio internal shell.
//
// These destinations are defined in `docs/phase_7_52_execution_plan.md`
// and drive the Barrio home hub, route map, and destination screens.
//
// This file is the single source of truth for what the shell displays.
// Real permission enforcement belongs to Phase 9.

/// The audience tier a destination is intended for.
///
/// During 7.52 this is informational structure only.
/// Real enforcement belongs to Phase 9 auth.
enum BarrioAudience {
  allStaff,
  supervisor,
  manager,
  admin,
}

/// Visual prominence tier for the home hub layout.
///
/// Controls bubble size, glow intensity, and position weight
/// in the animated destination hub.
enum BarrioProminence {
  /// The single dominant node -- largest bubble, center position.
  /// Only `Forge & Flow` should use this tier.
  primary,

  /// Major secondary nodes -- visible and clearly accessible.
  secondary,

  /// Tertiary or reserved nodes -- present but visually quieter.
  tertiary,
}

/// A single destination inside the Barrio internal shell.
class BarrioDestination {
  /// Stable identifier used for route matching and metadata lookups.
  final String id;

  /// Display label shown in the shell UI.
  final String label;

  /// Short description shown in destination detail or legend.
  final String description;

  /// Future audience tiers for this destination.
  /// Displayed as preview labels only -- no enforcement in 7.52.
  final Set<BarrioAudience> audiences;

  /// If true, the destination is not yet available and renders
  /// as "Coming Soon" in the shell UI.
  final bool comingSoon;

  /// Visual prominence tier for the home hub layout.
  final BarrioProminence prominence;

  /// Whether this destination should appear on the home hub.
  final bool showOnHomeHub;

  /// Icon data for the destination bubble/card.
  final int iconCodePoint;

  const BarrioDestination({
    required this.id,
    required this.label,
    required this.description,
    required this.audiences,
    this.comingSoon = false,
    this.prominence = BarrioProminence.secondary,
    this.showOnHomeHub = true,
    this.iconCodePoint = 0xe5f9, // Icons.circle fallback
  });

  /// Audience labels as display strings for shell preview tags.
  List<String> get audienceLabels => audiences.map((a) {
        switch (a) {
          case BarrioAudience.allStaff:
            return 'All Staff';
          case BarrioAudience.supervisor:
            return 'Supervisor';
          case BarrioAudience.manager:
            return 'Manager';
          case BarrioAudience.admin:
            return 'Admin';
        }
      }).toList();
}

/// The canonical list of planned Barrio destinations.
///
/// Source: `docs/phase_7_52_execution_plan.md` -- "Planned Barrio Destinations".
const List<BarrioDestination> barrioDestinations = [
  BarrioDestination(
    id: 'forge_and_flow',
    label: 'Forge & Flow',
    description:
        'Shared product entry point -- the core labor productivity dashboard.',
    audiences: {
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.primary,
    showOnHomeHub: true,
    iconCodePoint: 0xe6e1, // Icons.show_chart
  ),
  BarrioDestination(
    id: 'company_handbook',
    label: 'Company Handbook',
    description: 'Internal company handbook available to all staff.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
    iconCodePoint: 0xe865, // Icons.menu_book
  ),
  BarrioDestination(
    id: 'interview_playbook',
    label: 'Interview Playbook',
    description: 'Structured interview guidance for managers and admins only.',
    audiences: {
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
    iconCodePoint: 0xef65, // Icons.people_outline
  ),
  BarrioDestination(
    id: 'jim_taylor_labor_model',
    label: 'Jim Taylor Labor Model',
    description: 'Deep-dive labor model content for managers and admins.',
    audiences: {
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
    iconCodePoint: 0xe263, // Icons.insights
  ),
  BarrioDestination(
    id: 'preston_lee_model',
    label: 'Preston Lee Model',
    description: 'Future destination -- not yet available.',
    audiences: {
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    comingSoon: true,
    prominence: BarrioProminence.tertiary,
    showOnHomeHub: true,
    iconCodePoint: 0xe80e, // Icons.lightbulb_outline
  ),
  BarrioDestination(
    id: 'supervisor_content',
    label: 'Supervisor Content',
    description: 'Reserved area for supervisor-specific material.',
    audiences: {
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.tertiary,
    showOnHomeHub: false,
    iconCodePoint: 0xef52, // Icons.supervisor_account
  ),

  // -- Verbatim training bubbles (2026-07-11 training-drop slice) ----------
  // One bubble per converted knowledge-graph training document. Content is
  // word-for-word source text rendered by TrainingDocScreen.
  BarrioDestination(
    id: 'training_strong_foundation',
    label: 'Strong Foundation',
    description:
        'Building A Strong Foundation: consistency and standards training.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_table_manicuring',
    label: 'Table Manicuring',
    description:
        'Elevate Your Table Maintenance To Table Manicuring: service training.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_three_pillars',
    label: 'Three Pillars',
    description:
        'The Three Pillars Of Hospitality: food, service, and atmosphere.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_suggestive_selling',
    label: 'Suggestive Selling',
    description:
        'Leveraging Suggestive Selling Techniques: upselling and cross-selling.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_tequila',
    label: 'Tequila',
    description: 'Tequila Training: production, classes, cocktails, mezcal.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_coffee',
    label: 'Coffee',
    description:
        'Coffee Training: beans, espresso, drinks, equipment, glossary.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_latin_dishes',
    label: 'Latin Dishes',
    description: 'Latin American Words To Know: dishes glossary.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_latin_ingredients',
    label: 'Latin Ingredients',
    description: 'Latin American Words To Know: ingredients glossary.',
    audiences: {
      BarrioAudience.allStaff,
      BarrioAudience.supervisor,
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_labour_cost',
    label: 'Labour Cost',
    description:
        'Understanding Labour Cost & Operational Balance: the three levers.',
    audiences: {
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
  BarrioDestination(
    id: 'training_menu_concept',
    label: 'Menu Concept',
    description:
        'Barrio Legado Menu Concept Slides: working draft, decisions in flux.',
    audiences: {
      BarrioAudience.manager,
      BarrioAudience.admin,
    },
    prominence: BarrioProminence.secondary,
    showOnHomeHub: true,
  ),
];
