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

  // ── B-r3: "Add knowledge" card ──
  //
  // The operator drops in a document; the advisor learns from it. After a
  // file is staged the proxy returns a plain-English "what this update
  // changes" diff. None of this fabricates data: the added/modified lines
  // describe the chunks the proxy actually returned.

  /// Card title.
  static const String addTitle = 'Add knowledge';

  /// One-line orientation copy under the title.
  static const String addLead =
      'Drop in a document and the advisor learns from it. No special '
      'formatting needed.';

  /// Primary prompt inside the dropzone.
  static const String addDropPrompt = 'Choose a file or drag it here';

  /// Secondary line inside the dropzone: accepted kinds + the size cap.
  static const String addDropHint =
      'A Word, text, or markdown document, up to 1 MB';

  /// Label on the click-to-pick button.
  static const String addChooseFile = 'Choose a file';

  /// Label on the demo-only "use a sample file" button (kDemoMode only).
  static const String addUseSample = 'Use a sample file';

  /// Shown while the proxy stages the upload and computes the diff.
  static const String addChecking = 'Reading the document...';

  /// Heading on the "what this update changes" preview.
  static const String addChangeTitle = 'What this update changes';

  /// Reassurance line under the change preview when there is nothing to
  /// change (the uploaded document matches what the advisor already knows).
  static const String addNoChanges =
      'This document matches what the advisor already knows. There is '
      'nothing new to save.';

  /// Primary commit button on the change preview.
  static const String addSaveUpdate = 'Save this update';

  /// Cancel button on the change preview: discards the staged upload.
  static const String addCancel = 'Cancel';

  /// Snackbar shown after a successful save.
  static const String addSavedToast = 'Saved. The advisor is learning from it.';

  /// Plain-English line for one ADDED piece, keyed by its derived kind.
  /// "New metric the advisor will learn", "New SOP the advisor will
  /// learn", and so on. Mirrors the approved preview's added-row copy.
  static String addAddedLine(AdminCorpusTopicKind kind) =>
      'New ${_kindNoun(kind)} the advisor will learn';

  /// Plain-English line for one MODIFIED piece. The preview reads
  /// "Reworded, a bit clearer than before"; we keep that voice.
  static const String addModifiedLine = 'Reworded, a bit clearer than before';

  /// Lowercase noun for a kind, used inside the added-row sentence.
  static String _kindNoun(AdminCorpusTopicKind kind) {
    switch (kind) {
      case AdminCorpusTopicKind.document:
        return 'document section';
      case AdminCorpusTopicKind.sop:
        return 'SOP';
      case AdminCorpusTopicKind.policy:
        return 'policy';
      case AdminCorpusTopicKind.concept:
        return 'concept';
      case AdminCorpusTopicKind.metric:
        return 'metric';
      case AdminCorpusTopicKind.formula:
        return 'formula';
      case AdminCorpusTopicKind.risk:
        return 'risk to watch for';
      case AdminCorpusTopicKind.role:
        return 'role';
    }
  }

  // ── B-r3: "Update history" card ──
  //
  // A timeline of every saved version, current-first. Rollback writes a
  // NEW version (the ledger is append-only) and never deletes history, so
  // the copy says that honestly.

  /// Card title.
  static const String historyTitle = 'Update history';

  /// One-line orientation copy under the title.
  static const String historyLead =
      'Every change is saved. You can always go back to an earlier version.';

  /// Badge on the current version row.
  static const String historyInUseNow = 'In use now';

  /// Attribution line. The corpus is staff-managed, so every version
  /// reads "by F and F staff" unless a specific author is recorded.
  static const String historyByStaff = 'by F and F staff';

  /// Note shown on a row that was itself created by a rollback.
  static const String historyRestoredNote = 'Went back to an earlier version';

  /// Button on a prior version: makes it current again.
  static const String historyGoBack = 'Go back to this version';

  /// Honest empty state when only the current version exists.
  static const String historyNoPrior = 'No earlier versions yet.';

  /// Confirm-dialog title for "go back to this version".
  static const String historyGoBackTitle = 'Go back to this version?';

  /// Confirm-dialog body. States plainly that this writes a NEW version
  /// and deletes nothing, so past advisor recommendations stay traceable.
  static const String historyGoBackBody =
      'This saves a new version that matches the one you picked. Nothing is '
      'deleted: the current version stays in history, so past advisor '
      'recommendations can still be traced.';

  /// Confirm-dialog primary button.
  static const String historyGoBackConfirm = 'Go back to it';

  /// Snackbar after a successful rollback.
  static const String historyWentBackToast =
      'Done. A new version now matches the one you picked.';

  /// "N pieces of knowledge" summary line for a version row.
  static String historyPieceCount(int count) =>
      '$count piece${count == 1 ? '' : 's'} of knowledge';

  // ── C2: "Connections" tab ──
  //
  // The advisor's knowledge is connected: documents include SOPs, concepts
  // reduce risks, and so on. This tab lets F and F staff confirm those
  // connections in plain English. Clarity (clear / worth checking / not
  // sure) is DERIVED honestly from each connection's confidence score
  // (see CorpusConnectionsView's bucketing helper); nothing here is
  // fabricated. The verb in each sentence is a plain-English reading of
  // the relationship type, falling back to "is related to" when unknown.

  /// Read-only (ff_support) banner on the Connections tab. Support staff
  /// can look but not approve; full admin access is required to decide.
  static const String connectionsReadOnlyBanner =
      'You are viewing only. Approving connections needs full admin access.';

  /// "N connections found" headline on the summary card.
  static String connectionsFound(int count) =>
      '$count connection${count == 1 ? '' : 's'} found';

  /// Clarity chip on the summary card: "N clear".
  static String connectionsClearChip(int count) => '$count clear';

  /// Clarity chip on the summary card: "N worth checking".
  static String connectionsCheckChip(int count) => '$count worth checking';

  /// Clarity chip on the summary card: "N not sure".
  static String connectionsUnsureChip(int count) => '$count not sure';

  /// Placeholder for the connection search box.
  static const String connectionsSearchHint = 'Search connections by topic';

  /// Accessibility label for the "Show" dropdown.
  static const String connectionsShowLabel = 'Show';

  /// "Show" dropdown option: only the connections that still need a
  /// decision (worth checking + not sure).
  static String connectionsShowAttention(int count) =>
      'Needs my attention ($count)';

  /// "Show" dropdown option: every connection.
  static String connectionsShowEverything(int count) => 'Everything ($count)';

  /// "Show" dropdown option: clear connections only.
  static String connectionsShowClearOnly(int count) => 'Clear only ($count)';

  /// Clear-group heading.
  static const String connectionsGroupClear = 'Looks clear to me';

  /// Worth-checking-group heading.
  static const String connectionsGroupCheck = 'Please double-check';

  /// Not-sure-group heading.
  static const String connectionsGroupUnsure = "I'm not sure about these";

  /// Per-row clarity chip: clear.
  static const String connectionsClarityClear = 'Clear match';

  /// Per-row clarity chip: worth checking.
  static const String connectionsClarityCheck = 'Worth checking';

  /// Per-row clarity chip: not sure.
  static const String connectionsClarityUnsure = 'Not sure';

  /// Approve action on a connection row.
  static const String connectionsLooksRight = 'Looks right';

  /// Reject action on a connection row.
  static const String connectionsNotRight = 'Not right';

  /// Edit action on a clear / worth-checking connection row.
  static const String connectionsChange = 'Change';

  /// Primary edit action on a not-sure row (the connection is unclear, so
  /// the operator sets how the two topics connect rather than approving).
  static const String connectionsSetHow = 'Set how they connect';

  /// "Mark all N correct" bulk action on the clear group.
  static String connectionsMarkAllCorrect(int count) =>
      'Mark all $count correct';

  /// "Show N more ..." pager label per group.
  static String connectionsShowMoreClear(int count) =>
      'Show $count more clear connection${count == 1 ? '' : 's'}';
  static String connectionsShowMoreCheck(int count) =>
      'Show $count more to check';
  static String connectionsShowMoreUnsure(int count) =>
      'Show $count more unclear one${count == 1 ? '' : 's'}';

  /// "Save my choices (N)" footer button.
  static String connectionsSaveChoices(int count) =>
      'Save my choices ($count)';

  /// "Start over" footer button: clears every pending choice.
  static const String connectionsStartOver = 'Start over';

  /// Honest hint shown by the disabled "Save my choices" button when no
  /// commit target is configured. Points the operator at the Scope pane
  /// (the redesign dropped the in-tab operator picker), so a decision is
  /// never written against the wrong business or location.
  static const String connectionsNoTargetHint =
      'Select a business and location in the Scope pane to apply your '
      'decisions.';

  /// Snackbar after a successful save: "N approved, M removed".
  static String connectionsSavedToast(int approved, int rejected) =>
      '$approved approved, $rejected removed';

  /// Honest empty state when there are no connections to review.
  static const String connectionsEmpty = 'No connections to review yet.';

  /// Shown when the search or filter hides every connection.
  static const String connectionsFilteredEmpty =
      'No connections match your search.';

  /// Per-row technical-details disclosure title.
  static const String connectionsTechTitle = 'Technical details';

  /// Change modal: title.
  static const String connectionsChangeTitle = 'How are these connected?';

  /// Change modal: sub-line prompting the operator to pick a sentence.
  static const String connectionsChangeSub = 'Pick the sentence that is true.';

  /// Change modal: optional-note field label.
  static const String connectionsChangeNoteLabel = 'Add a note (optional)';

  /// Change modal: optional-note field hint.
  static const String connectionsChangeNoteHint =
      'Anything you want to remember about this change.';

  /// Change modal: cancel button.
  static const String connectionsChangeCancel = 'Cancel';

  /// Change modal: save button.
  static const String connectionsChangeSave = 'Save this connection';

  /// The Map card title. The focusable node-link diagram (C2-map) draws
  /// the real connection candidates centred on a chosen topic.
  static const String connectionsMapTitle = 'Map';

  /// "Focus on:" label beside the Map's topic dropdown.
  static const String connectionsMapFocusLabel = 'Focus on:';

  /// Honest empty state when there is no graph data to map at all (no
  /// edge candidates in the diff). We never draw a fabricated diagram.
  static const String connectionsMapEmpty = 'No connections to map yet.';

  /// Caption under the Map: how many of the total connections the diagram
  /// shows, and which topic it is centred on. Plain English, no em dash.
  static String connectionsMapCaption(int shown, int total, String topic) =>
      'Showing $shown of $total connection${total == 1 ? '' : 's'}, '
      'centred on $topic. Pick another topic to explore its links.';

  /// Honest note drawn beside a focused topic that has no links yet.
  static String connectionsMapNoLinks(String topic) =>
      '$topic has no connections to other topics yet.';
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
