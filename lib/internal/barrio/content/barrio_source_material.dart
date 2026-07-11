// Typed source-material catalog for Barrio-private documents and assets.
//
// These references are metadata only. Document sources were converted to
// founder-authored Markdown during 7.57/11a (April 2026) and now live
// under `docs/Knowledge_graph_docs/`, governed by that folder's
// `corpus_manifest.yaml` (the ingestion authority: Markdown only; a file
// not listed in the manifest is not ingested). The former
// `docs/internal/barrio/` folder is retired. Branding assets live under
// `assets/internal/barrio/` and are NOT registered in the public Flutter
// asset bundle. Entries whose source is no longer in the repo say so in
// their notes; their historical paths are kept for provenance.
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
/// Document sources live as founder-authored Markdown under
/// `docs/Knowledge_graph_docs/` (see the header comment above for the
/// manifest rules). They are source material for future structured
/// in-app experiences, not the finished runtime UX.
const List<BarrioSourceMaterial> barrioSourceMaterials = [
  BarrioSourceMaterial(
    id: 'barrio_business_plan',
    label: 'Barrio Legado Business Plan',
    repoPath: 'docs/internal/barrio/barrio_legado_business_plan.pdf',
    type: BarrioSourceType.document,
    relatedDestinations: ['company_handbook'],
    notes: 'NOT IN THE REPO: gitignored as a large binary and the '
        'docs/internal/barrio/ folder was retired (April 2026); historical '
        'path kept for provenance. If re-added, drop as Markdown in '
        'docs/Knowledge_graph_docs/ and register it in corpus_manifest.yaml. '
        'Source material for the Company Handbook structured content.',
  ),
  BarrioSourceMaterial(
    id: 'company_handbook_pdf',
    label: 'Company Handbook',
    repoPath: 'docs/Knowledge_graph_docs/Barrio_company_handbook.md',
    type: BarrioSourceType.document,
    relatedDestinations: ['company_handbook'],
    notes: 'Primary handbook source document for the all-staff learning '
        'experience (converted from the original PDF to founder-authored '
        'Markdown; ingestion governed by corpus_manifest.yaml). The in-app '
        'chapter content lives in company_handbook_content.dart.',
  ),
  BarrioSourceMaterial(
    id: 'interview_playbook_pdf',
    label: 'Interview Playbook',
    repoPath: 'docs/Knowledge_graph_docs/Barrio_interview_playbook.md',
    type: BarrioSourceType.document,
    relatedDestinations: ['interview_playbook'],
    notes: 'Primary source document for the supervisor and manager interview '
        'playbook (converted from the original PDF to founder-authored '
        'Markdown; ingestion governed by corpus_manifest.yaml). The in-app '
        'guided content lives in interview_playbook_content.dart.',
  ),
  BarrioSourceMaterial(
    id: 'jim_taylor_deep_dive',
    label: 'Jim Taylor Labor Model Deep Dive',
    repoPath: 'docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md',
    type: BarrioSourceType.document,
    relatedDestinations: ['jim_taylor_labor_model'],
    notes: 'Source material for the Jim Taylor Labor Model structured content '
        '(converted from the original HTML to founder-authored Markdown; '
        'ingestion governed by corpus_manifest.yaml). The in-app sections '
        'live in jim_taylor_model_content.dart.',
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
    notes: 'NOT IN THE REPO: removed with the docs/internal/barrio/ folder '
        '(April 2026); historical path kept for provenance. Was the '
        'authoritative shell, motion, atmosphere, and teaching-system '
        'blueprint for Barrio-native fulfillment (shell hierarchy, bubble '
        'behavior, visual mood, interactive teaching design).',
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
    notes: 'NOT IN THE REPO: the inspiration set was removed from git '
        '(April 2026); historical path kept for provenance. Was a private '
        'inspiration image set for shell mood, composition, material feel, '
        'and visual direction. Reference only, not runtime product assets.',
  ),
];
