// Typed source-material catalog for Barrio-private documents and assets.
//
// These references point to files that were relocated into the private
// Barrio boundary during 7.52c. They are metadata only -- the actual
// files live under `docs/internal/barrio/` and `assets/internal/barrio/`
// and are NOT registered in the public Flutter asset bundle.
//
// Future prompts (7.52g) will use this catalog to build structured
// in-app content surfaces. This file does NOT:
// - embed or display the raw documents
// - wire anything into the public Forge & Flow runtime
// - duplicate any shared product logic

/// The type of a Barrio source-material asset.
enum BarrioSourceType {
  /// A document used as source material for structured content.
  document,

  /// A branding or visual asset for the Barrio internal build.
  brandingAsset,
}

/// A single Barrio-private source-material reference.
class BarrioSourceMaterial {
  /// Stable identifier for this source item.
  final String id;

  /// Human-readable label.
  final String label;

  /// Repo-relative path to the source file.
  final String repoPath;

  /// What kind of source material this is.
  final BarrioSourceType type;

  /// Which Barrio destination(s) this material feeds into.
  /// References destination IDs from [barrioDestinations].
  final List<String> relatedDestinations;

  /// Free-form notes about what this source material contains
  /// or how it should be used in future structured content.
  final String notes;

  const BarrioSourceMaterial({
    required this.id,
    required this.label,
    required this.repoPath,
    required this.type,
    required this.relatedDestinations,
    this.notes = '',
  });
}

/// The canonical catalog of known Barrio-private source material.
///
/// These files were moved out of the repo root during 7.52c.
/// They are source material for future structured in-app experiences,
/// not the finished runtime UX.
const List<BarrioSourceMaterial> barrioSourceMaterials = [
  BarrioSourceMaterial(
    id: 'barrio_business_plan',
    label: 'Barrio Legado Business Plan',
    repoPath: 'docs/internal/barrio/barrio_legado_business_plan.pdf',
    type: BarrioSourceType.document,
    relatedDestinations: ['company_handbook'],
    notes: 'Source material for the Company Handbook structured content. '
        'Should be translated into navigable in-app sections, not displayed '
        'as a raw PDF.',
  ),
  BarrioSourceMaterial(
    id: 'company_handbook_pdf',
    label: 'Company Handbook',
    repoPath: 'docs/internal/barrio/company_handbook.pdf',
    type: BarrioSourceType.document,
    relatedDestinations: ['company_handbook'],
    notes: 'Primary handbook source document for the all-staff learning '
        'experience. This should become chapter-based native content rather '
        'than a raw PDF viewer.',
  ),
  BarrioSourceMaterial(
    id: 'interview_playbook_pdf',
    label: 'Interview Playbook',
    repoPath: 'docs/internal/barrio/interview_playbook.pdf',
    type: BarrioSourceType.document,
    relatedDestinations: ['interview_playbook'],
    notes: 'Primary source document for the supervisor and manager interview '
        'playbook. This should become guided interactive content rather than '
        'a raw PDF viewer.',
  ),
  BarrioSourceMaterial(
    id: 'jim_taylor_deep_dive',
    label: 'Jim Taylor Labor Model Deep Dive',
    repoPath: 'docs/internal/barrio/jim_taylor_labor_model_deep_dive.html',
    type: BarrioSourceType.document,
    relatedDestinations: ['jim_taylor_labor_model'],
    notes: 'Source material for the Jim Taylor Labor Model structured content. '
        'Should be translated into navigable in-app sections, not displayed '
        'as a raw HTML embed.',
  ),
  BarrioSourceMaterial(
    id: 'barrio_visual_blueprint',
    label: 'Barrio Visual Teaching System Blueprint',
    repoPath: 'docs/internal/barrio/barrio_visual_teaching_system_execution_blueprint.md',
    type: BarrioSourceType.document,
    relatedDestinations: [
      'forge_and_flow',
      'company_handbook',
      'interview_playbook',
      'jim_taylor_labor_model',
    ],
    notes: 'Authoritative shell, motion, atmosphere, and teaching-system '
        'blueprint for Barrio-native fulfillment. Guides shell hierarchy, '
        'bubble behavior, visual mood, and interactive teaching design.',
  ),
  BarrioSourceMaterial(
    id: 'barrio_logo',
    label: 'Barrio Branding Logo',
    repoPath: 'assets/internal/barrio/branding/logo.png',
    type: BarrioSourceType.brandingAsset,
    relatedDestinations: [],
    notes: 'Barrio internal branding logo. Will be used in the Barrio shell '
        'header/branding during 7.52f. Not registered in the public Flutter '
        'asset bundle.',
  ),
  BarrioSourceMaterial(
    id: 'barrio_inspiration_refs',
    label: 'Barrio Inspiration References',
    repoPath: 'assets/internal/barrio/inspiration/',
    type: BarrioSourceType.brandingAsset,
    relatedDestinations: [],
    notes: 'Private inspiration image set for shell mood, composition, '
        'material feel, and visual direction. Reference only, not runtime '
        'product assets.',
  ),
];
