// Shared admin copy helpers for translating backend grouping IDs into
// readable labels while keeping the exact IDs visible for filtering.

import '../domain/models/forge_flow_polling_tier_assignment.dart'
    show PollingTierKey;
import 'models/corpus_admin_models.dart' show ChunkPreview;
import 'models/debug_console_admin_models.dart' show RequestLogStatus;

const List<String> _adminMonthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class AdminRequestUseCaseCopy {
  const AdminRequestUseCaseCopy({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;
}

const List<AdminRequestUseCaseCopy> adminRequestUseCases =
    <AdminRequestUseCaseCopy>[
      AdminRequestUseCaseCopy(
        id: 'advisor_qa',
        label: 'Advisor answers',
        description: 'Questions answered by the AI advisor.',
      ),
      AdminRequestUseCaseCopy(
        id: 'coach_qa',
        label: 'Coaching help',
        description: 'Manager and staff coaching guidance.',
      ),
      AdminRequestUseCaseCopy(
        id: 'wf_pl',
        label: 'Workflow planning',
        description: 'Workflow planning before follow-up work is scheduled.',
      ),
      AdminRequestUseCaseCopy(
        id: 'wf_schedule',
        label: 'Workflow scheduling',
        description: 'Scheduled workflow follow-up and reminders.',
      ),
    ];

/// Plain-English labels for the support-help request classes that the
/// Support logs Type filter folds in alongside the four AI use cases
/// above. Kept SEPARATE from [adminRequestUseCases] so the four AI
/// labels stay byte-stable for the observability + pricing screens (and
/// their tests), while these support classes stop title-casing into
/// machine-ish strings like "Mfa Diagnostics". Mirrors the wording in
/// `debug_console_admin_gateway.dart`'s relationship/account use cases.
const List<AdminRequestUseCaseCopy> adminSupportRequestUseCases =
    <AdminRequestUseCaseCopy>[
      AdminRequestUseCaseCopy(
        id: 'relationship_review',
        label: 'Relationship review',
        description: 'Knowledge graph and relationship review support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'knowledge_relationship',
        label: 'Knowledge links',
        description: 'Knowledge-base relationship linking and review.',
      ),
      AdminRequestUseCaseCopy(
        id: 'corpus_relationship_review',
        label: 'Corpus review',
        description: 'Corpus relationship review and repair requests.',
      ),
      AdminRequestUseCaseCopy(
        id: 'account_help',
        label: 'Account help',
        description: 'General account assistance and operator access support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'auth_support',
        label: 'Sign-in help',
        description: 'Authentication and sign-in support requests.',
      ),
      AdminRequestUseCaseCopy(
        id: 'mfa_diagnostics',
        label: 'MFA help',
        description: 'Multi-factor setup and recovery diagnostics.',
      ),
      AdminRequestUseCaseCopy(
        id: 'session_support',
        label: 'Session help',
        description: 'Active session review and sign-out support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'notification_support',
        label: 'Notification help',
        description: 'Email, push, and notification delivery support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'user_removal',
        label: 'Removal requests',
        description: 'User deactivation, removal, and erasure support.',
      ),
    ];

String adminRequestUseCaseLabel(String id) {
  final known = _findRequestUseCase(id);
  if (known != null) return known.label;
  if (id.trim().isEmpty) return 'Unknown request group';
  return _titleCaseId(id);
}

String adminRequestUseCaseDescription(String id) {
  final known = _findRequestUseCase(id);
  if (known != null) return known.description;
  return 'Custom backend request group. Use the ID when filtering.';
}

/// Display-only, plain-English wording for a request's coarse result on
/// the Support logs screen. This is NOT a wire value: it never feeds the
/// `status=` query param (that stays [requestLogStatusLabel] in the
/// models layer). Honesty (Metric Honesty Doctrine): an `unknown`
/// status — a request with no recorded outcome — reads "Not recorded",
/// NOT a fabricated "Worked". `success` reads "Worked"; the failure
/// wordings cover the queued failure/timeout telemetry (P1b.2) so they
/// render correctly the moment real error/timeout rows arrive.
String adminRequestResultWording(RequestLogStatus status) {
  switch (status) {
    case RequestLogStatus.success:
      return 'Worked';
    case RequestLogStatus.error:
      return 'Failed';
    case RequestLogStatus.timeout:
      return 'Timed out';
    case RequestLogStatus.unknown:
      return 'Not recorded';
  }
}

String adminPollingTierLabel(PollingTierKey tier) {
  switch (tier) {
    case PollingTierKey.standard:
      return 'Regular';
    case PollingTierKey.premium:
      return 'Premium';
    case PollingTierKey.custom:
      return 'Custom';
  }
}

String adminRequestUseCaseLabelWithId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) return 'Unknown request group';
  return '${adminRequestUseCaseLabel(trimmed)} ($trimmed)';
}

/// Plain-English copy for the admin "Knowledge base" screen
/// (`corpus_admin_screen.dart`). The B-r1 redesign frames the screen
/// around what the advisor knows, so the operator-facing strings live
/// here (one place to read, one place to keep plain). Mirrors the
/// approved UX preview at
/// `docs/_mockups/knowledge_base_redesign_preview.html`.
///
/// No-em-dash law (CLAUDE.md "UX no-em-dash law"): none of these use a
/// U+2014 em dash. Label/value separators use a colon; clauses join
/// with a full stop or comma.
class AdminKnowledgeBaseCopy {
  const AdminKnowledgeBaseCopy._();

  /// Screen title: frames the page around the advisor's knowledge,
  /// not the storage mechanism. The nav label stays "Knowledge base".
  static const String title = 'What the advisor knows';

  /// One-line orientation copy under the title.
  static const String subtitle =
      'Add knowledge, see how topics connect, and keep a history you '
      'can roll back. Only F and F staff can see this.';

  /// Trailing header badge. The whole screen is internal-only.
  static const String staffOnlyBadge = 'Staff only';

  /// Screen-level toggle that reveals machine-flavored details (raw
  /// IDs, content hashes, confidence scores, version IDs). Off by
  /// default so the everyday view stays free of machine noise.
  static const String showTechnicalDetails = 'Show technical details';

  /// Tooltip on the toggle: says plainly what it does and that it
  /// starts off.
  static const String showTechnicalDetailsHint =
      'Reveals technical IDs and scores for power users. Off by default.';

  /// Read-only (ff_support) banner. Support staff can look but not
  /// change anything; full admin access is required to edit.
  static const String readOnlyBanner =
      'You are viewing only. Making changes needs full admin access.';

  // ── B-r2: "Topics the advisor knows" card ──
  //
  // The card lists the content pieces grouped by the document they came
  // from. Each piece carries a plain-English "kind" (Document, SOP,
  // Policy, ...). Rich kinds are extracted in a later slice (C3); until
  // then the kind is derived from the heading/source text and falls back
  // to "Document" when nothing better is known. None of this fabricates
  // data: it reads what the chunk already carries.

  /// Card title.
  static const String topicsTitle = 'Topics the advisor knows';

  /// One-line orientation copy under the title.
  static const String topicsLead =
      'As the knowledge grows, search or filter to find anything fast. '
      'Topics are grouped by the document they came from.';

  /// Placeholder for the topic search box.
  static const String topicSearchHint =
      'Search topics, e.g. FIFO, harassment, CPLH';

  /// Accessibility label for the kind filter dropdown.
  static const String kindFilterLabel = 'Filter by kind';

  /// Shown when a search or filter hides every topic.
  static const String topicsEmpty = 'No topics match your search.';

  /// "Showing X of Y" count above the topic list. Plain English, no
  /// em dash (the colon-free phrasing reads as a sentence fragment).
  static String topicsShowing(int shown, int total) =>
      'Showing $shown of $total';
}

/// B-r2: the plain-English content "kind" the Topics card shows for each
/// piece. Mirrors the approved preview's kinds (Document, SOP, Policy,
/// Concept, Metric, Formula, Risk, Role). Rich kinds are extracted by a
/// later slice (C3); [corpusTopicKindForChunk] derives a best-effort
/// kind from the text the chunk already carries and defaults to
/// [document] when nothing better is known. No kind is ever fabricated.
enum AdminCorpusTopicKind {
  /// The fallback. A plain document section with no clearer signal.
  document('all', 'Document', 'A document'),
  sop('sop', 'SOP', 'A step-by-step SOP'),
  policy('policy', 'Policy', 'A policy'),
  concept('concept', 'Concept', 'A concept'),
  metric('metric', 'Metric', 'A metric you track'),
  formula('formula', 'Formula', 'A formula'),
  risk('risk', 'Risk', 'A risk to watch for'),
  role('role', 'Role', 'A role');

  const AdminCorpusTopicKind(this.filterValue, this.pill, this.description);

  /// Stable value used by the kind-filter dropdown. [document] uses
  /// 'all' only as a sentinel for the enum's first entry; the dropdown
  /// builds its own "All kinds" option separately. Each non-document
  /// kind maps to one filter value.
  final String filterValue;

  /// Short pill label (Title Case noun): 'SOP', 'Policy', ...
  final String pill;

  /// One-line plain-English description shown under the topic name.
  final String description;
}

/// Plain-English label for the kind filter dropdown options. 'All kinds'
/// is the unfiltered default; each other entry pluralizes the kind.
String adminCorpusKindFilterOptionLabel(AdminCorpusTopicKind? kind) {
  if (kind == null) return 'All kinds';
  switch (kind) {
    case AdminCorpusTopicKind.document:
      return 'Documents';
    case AdminCorpusTopicKind.sop:
      return 'SOPs';
    case AdminCorpusTopicKind.policy:
      return 'Policies';
    case AdminCorpusTopicKind.concept:
      return 'Concepts';
    case AdminCorpusTopicKind.metric:
      return 'Metrics';
    case AdminCorpusTopicKind.formula:
      return 'Formulas';
    case AdminCorpusTopicKind.risk:
      return 'Risks';
    case AdminCorpusTopicKind.role:
      return 'Roles';
  }
}

/// B-r2: derives a best-effort [AdminCorpusTopicKind] for a content
/// piece from the signals it already carries. The launch corpus does
/// NOT yet tag chunks with a rich kind (that extraction is slice C3), so
/// this reads the chunk's heading text + source-file name for a small
/// set of unambiguous keywords and otherwise returns
/// [AdminCorpusTopicKind.document]. It never invents a kind: when the
/// text gives no clear signal the piece reads as a plain "Document".
///
/// Kept pure (no I/O, no BuildContext) so it is trivially unit-testable
/// and reusable. Matching is case-insensitive and word-boundary aware so
/// "policy" matches "Harassment Policy" but not "policyholder"-style
/// substrings inside unrelated words.
AdminCorpusTopicKind corpusTopicKindForChunk(ChunkPreview chunk) {
  final haystack = <String>[
    if (chunk.headingPath.isNotEmpty) chunk.headingPath.last,
    chunk.sourcePath,
  ].join(' ').toLowerCase();

  bool hasWord(String word) =>
      RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(haystack);

  // Order matters: the most specific signals win. A heading that names a
  // risk ("danger zone") should read as a Risk even if the document is a
  // manual. Each branch keys off vocabulary that is unambiguous in the
  // restaurant-operations domain this corpus covers.
  if (hasWord('sop') ||
      hasWord('procedure') ||
      hasWord('fifo') ||
      hasWord('haccp') ||
      hasWord('checklist')) {
    return AdminCorpusTopicKind.sop;
  }
  if (hasWord('policy') ||
      hasWord('policies') ||
      hasWord('whmis') ||
      hasWord('compliance') ||
      hasWord('rules')) {
    return AdminCorpusTopicKind.policy;
  }
  if (hasWord('risk') ||
      hasWord('danger') ||
      hasWord('hazard') ||
      hasWord('contamination')) {
    return AdminCorpusTopicKind.risk;
  }
  if (hasWord('formula') ||
      hasWord('equation') ||
      hasWord('calculation')) {
    return AdminCorpusTopicKind.formula;
  }
  if (hasWord('metric') ||
      hasWord('cplh') ||
      hasWord('splh') ||
      hasWord('ppa') ||
      hasWord('agc') ||
      hasWord('nps') ||
      hasWord('kpi')) {
    return AdminCorpusTopicKind.metric;
  }
  if (hasWord('role') ||
      hasWord('expo') ||
      hasWord('runner') ||
      hasWord('server') ||
      hasWord('manager')) {
    return AdminCorpusTopicKind.role;
  }
  if (hasWord('concept') ||
      hasWord('principle') ||
      hasWord('philosophy') ||
      hasWord('culture')) {
    return AdminCorpusTopicKind.concept;
  }
  return AdminCorpusTopicKind.document;
}

String adminHumanDateTime(DateTime when) {
  final local = when.toLocal();
  final month = _adminMonthNames[local.month - 1];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  final zone = local.timeZoneName.trim();
  final zoneSuffix = zone.isEmpty ? '' : ' $zone';
  return '$month ${local.day}, ${local.year} at $hour:$minute $period'
      '$zoneSuffix';
}

String adminRelativeUpdated(DateTime updatedAt, DateTime now) {
  final elapsed = now.toUtc().difference(updatedAt.toUtc());
  if (elapsed.isNegative || elapsed.inSeconds < 45) return 'just now';
  if (elapsed.inMinutes < 60) {
    final minutes = elapsed.inMinutes;
    return '$minutes minute${minutes == 1 ? '' : 's'} ago';
  }
  if (elapsed.inHours < 24) {
    final hours = elapsed.inHours;
    return '$hours hour${hours == 1 ? '' : 's'} ago';
  }
  final days = elapsed.inDays;
  return '$days day${days == 1 ? '' : 's'} ago';
}

AdminRequestUseCaseCopy? _findRequestUseCase(String id) {
  final normalized = id.trim().toLowerCase();
  for (final useCase in adminRequestUseCases) {
    if (useCase.id == normalized) return useCase;
  }
  for (final useCase in adminSupportRequestUseCases) {
    if (useCase.id == normalized) return useCase;
  }
  return null;
}

String _titleCaseId(String id) {
  final words = id
      .trim()
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty);
  if (words.isEmpty) return 'Unknown request group';
  return words
      .map((word) {
        if (word.length == 1) return word.toUpperCase();
        return word.substring(0, 1).toUpperCase() +
            word.substring(1).toLowerCase();
      })
      .join(' ');
}
