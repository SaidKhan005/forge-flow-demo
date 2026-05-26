// C2 — Connections tab for the corpus admin screen.
//
// Redesigns the "Connections" tab (formerly the EXTRACTED / INFERRED /
// AMBIGUOUS label buckets) into the approved preview's clarity-grouped
// review: a summary card, three clarity-grouped lists (clear / worth
// checking / not sure), per-connection plain-English sentences, and a
// "Save my choices" / "Start over" footer. Mirrors the approved UX
// preview at `docs/_mockups/knowledge_base_redesign_preview.html`
// lines 338-495.
//
// Extracted into its own import-based library (sibling to
// `corpus_admin_chunk_view.dart`) so the parent screen stays under the
// operator_web_size_lint frozen ceiling and so this view never reaches
// into the screen's private widgets. The view takes plain params: the
// connections data, `editingEnabled`, `showTechDetails`, the staged
// decision state, and action callbacks. The SCREEN owns every gateway
// call + idempotency key and computes `showTechDetails` from its
// existing tech-details scope.
//
// Honesty (Metric Honesty Doctrine): the clarity bucket for each
// connection is DERIVED from the candidate's confidence score (see
// [corpusConnectionClarity]); nothing is fabricated. The plain-English
// verb is a readable mapping of the relationship type, falling back to
// "is related to" when the type is unknown.
//
// C2-map: the focusable node-link Map (preview lines 360-399) now ships
// in a sibling library, [CorpusConnectionsMap] in
// `corpus_admin_connections_map.dart`. This view imports it and feeds it
// the same [GraphCandidateDiff] the clarity lists use; the map adds no
// new gateway/proxy/data.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import '../widgets/admin_action_controls.dart';
import 'corpus_admin_chunk_view.dart' show TopicKindIcon;
import 'corpus_admin_connections_map.dart' show CorpusConnectionsMap;

/// C2: a connection's plain-English clarity, DERIVED from its confidence
/// score. This is the honest bucketing the three Connections lists group
/// by; it never fabricates a signal.
///
/// Cutoffs (documented per the slice contract):
///   * [clear]  — score >= [_clearCutoff] (0.85): high-confidence, reads
///                "Clear match".
///   * [check]  — [_unsureCutoff] (0.7) <= score < [_clearCutoff]: above
///                the low-confidence line but not obviously right, reads
///                "Worth checking".
///   * [unsure] — score < [_unsureCutoff] (0.7) OR no score OR the
///                producer flagged the candidate AMBIGUOUS: reads
///                "Not sure".
///
/// The 0.7 "not sure" cutoff REUSES the exact low-confidence threshold
/// the existing confidence chip uses
/// ([kGraphCandidateConfidenceWarningThreshold]) so the two surfaces stay
/// consistent. The 0.85 clear/mid split is a sensible high-confidence
/// line for the clarity grouping.
enum CorpusConnectionClarity { clear, check, unsure }

/// Clear/mid split. At or above this a connection reads "Clear match".
const double _clearCutoff = 0.85;

/// Mid/not-sure split. Below this a connection reads "Not sure". Pinned
/// to the existing low-confidence warning threshold so the clarity bucket
/// and the confidence chip never disagree.
const double _unsureCutoff = kGraphCandidateConfidenceWarningThreshold;

/// Derives the honest clarity bucket for [candidate] from its confidence
/// score. AMBIGUOUS candidates always read "not sure" regardless of
/// score: the producer could not pin the relationship, so the operator
/// must set how the two topics connect (it is never auto-approvable, per
/// the proxy/model contract).
CorpusConnectionClarity corpusConnectionClarity(GraphCandidate candidate) {
  if (candidate.label == GraphCandidateLabel.ambiguous) {
    return CorpusConnectionClarity.unsure;
  }
  final score = candidate.confidenceScore;
  if (score == null) return CorpusConnectionClarity.unsure;
  if (score >= _clearCutoff) return CorpusConnectionClarity.clear;
  if (score >= _unsureCutoff) return CorpusConnectionClarity.check;
  return CorpusConnectionClarity.unsure;
}

/// C2: plain-English reading of a relationship type. Honest mapping over
/// the F and F relationship vocabulary; an unknown type falls back to
/// "is related to" (it never invents a specific verb). Matching is
/// case-insensitive on the normalized type.
String corpusRelationshipVerb(String relationshipType) {
  switch (relationshipType.trim().toUpperCase()) {
    case 'CONTAINS':
      return 'includes';
    case 'INFORMS':
      return 'informs';
    case 'TEACHES':
      return 'teaches';
    case 'DEFINES':
      return 'defines';
    case 'MEASURES':
      return 'measures';
    case 'CALCULATES':
      return 'is used to calculate';
    case 'REDUCES_RISK_OF':
    case 'MITIGATES':
      return 'reduces the risk of';
    case 'CAUSES':
      return 'can cause';
    case 'REQUIRES':
      return 'requires';
    case 'PART_OF':
      return 'is part of';
    case 'RELATES_TO':
    case 'NEAR':
    case 'RELATED':
      return 'is related to';
    default:
      return 'is related to';
  }
}

/// C2: best-effort topic kind for one end of a connection, so the flow
/// row can show a kind icon + kind label per node. Derives the kind from
/// the node's `candidate_type` (Document / SOP / Policy / Concept /
/// Metric / Formula / Risk / Role); anything else reads as a Document. It
/// never invents a kind. Pure + case-insensitive so it is unit-testable.
AdminCorpusTopicKind corpusConnectionNodeKind(String? nodeType) {
  switch ((nodeType ?? '').trim().toUpperCase()) {
    case 'SOP':
    case 'PROCEDURE':
      return AdminCorpusTopicKind.sop;
    case 'POLICY':
      return AdminCorpusTopicKind.policy;
    case 'CONCEPT':
      return AdminCorpusTopicKind.concept;
    case 'METRIC':
      return AdminCorpusTopicKind.metric;
    case 'FORMULA':
      return AdminCorpusTopicKind.formula;
    case 'RISK':
      return AdminCorpusTopicKind.risk;
    case 'ROLE':
    case 'PERSON':
      return AdminCorpusTopicKind.role;
    case 'DOCUMENT':
    case 'MANUAL':
    default:
      return AdminCorpusTopicKind.document;
  }
}

/// Human-friendly short name for a graphify node key or label. Strips the
/// `graphify:` prefix and turns snake_case into spaced words; an explicit
/// payload `label` (when present) wins. Pure so it is testable.
String corpusConnectionNodeName(String? rawKeyOrLabel) {
  final raw = (rawKeyOrLabel ?? '').trim();
  if (raw.isEmpty) return 'this topic';
  var name = raw;
  final colon = name.lastIndexOf(':');
  if (colon >= 0 && colon < name.length - 1) {
    name = name.substring(colon + 1);
  }
  name = name.replaceAll('_', ' ').trim();
  return name.isEmpty ? 'this topic' : name;
}

/// Builds the plain-English sentence for a connection, e.g.
/// "The Food Safety Manual includes FIFO." For a not-sure connection the
/// sentence is honest about the uncertainty and asks the operator to set
/// the link. Pure so it is testable.
String corpusConnectionSentence(GraphCandidate candidate) {
  final from = corpusConnectionNodeName(candidate.fromNodeKey);
  final to = corpusConnectionNodeName(candidate.toNodeKey);
  final clarity = corpusConnectionClarity(candidate);
  if (clarity == CorpusConnectionClarity.unsure) {
    return '$from seems related to $to, but it is not clear how. '
        'Set how they connect, or remove it.';
  }
  final verb = corpusRelationshipVerb(candidate.candidateType);
  return '$from $verb $to.';
}

/// Plain-English clarity chip label.
String _clarityChipLabel(CorpusConnectionClarity clarity) {
  switch (clarity) {
    case CorpusConnectionClarity.clear:
      return AdminKnowledgeBaseCopy.connectionsClarityClear;
    case CorpusConnectionClarity.check:
      return AdminKnowledgeBaseCopy.connectionsClarityCheck;
    case CorpusConnectionClarity.unsure:
      return AdminKnowledgeBaseCopy.connectionsClarityUnsure;
  }
}

/// Clarity accent color (clear = positive, check = warning, not sure =
/// muted), matching the preview's dot + chip palette.
Color _clarityColor(CorpusConnectionClarity clarity) {
  switch (clarity) {
    case CorpusConnectionClarity.clear:
      return AppColors.positive;
    case CorpusConnectionClarity.check:
      return AppColors.warning;
    case CorpusConnectionClarity.unsure:
      return AppColors.textMuted;
  }
}

/// C2: a single edge candidate is "approvable as written" only when it is
/// not flagged AMBIGUOUS. Not-sure rows therefore expose "Set how they
/// connect" (edit) + "Not right" (reject) but no bare approve, matching
/// both the preview and the model/proxy contract (AMBIGUOUS is debug-only
/// until edited). Node candidates are always approvable.
bool _canApprove(GraphCandidate candidate) =>
    candidate.label != GraphCandidateLabel.ambiguous;

/// How many rows each group shows before the "Show N more" pager.
const int _kInitialPageSize = 4;

/// The redesigned Connections tab body. Stateless over the queue: the
/// parent screen owns the approve/reject/edit queues + the gateway calls
/// and feeds them down through [queuedDecisionFor] + [pendingCount].
///
/// Search + "Show" filter + per-group paging are local UI state owned by
/// this view (they never touch the gateway).
class CorpusConnectionsView extends StatefulWidget {
  const CorpusConnectionsView({
    super.key,
    required this.diff,
    required this.editingEnabled,
    required this.showTechDetails,
    required this.pendingCount,
    required this.queuedDecisionFor,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    required this.onBulkApprove,
    required this.onSave,
    required this.onStartOver,
    this.busy = false,
    this.canSave = true,
  });

  /// The connections to review. The view re-buckets every candidate by
  /// clarity (it ignores the producer's EXTRACTED/INFERRED/AMBIGUOUS
  /// split for grouping, except that AMBIGUOUS forces "not sure").
  final GraphCandidateDiff diff;

  /// false = ff_support read-only walkthrough: every decide/save/bulk
  /// affordance is hidden; the connections still render.
  final bool editingEnabled;

  /// Screen-level "Show technical details" state. When false the per-row
  /// technical disclosure (relationship type, confidence, machine IDs) is
  /// hidden entirely; machine IDs never render when this is off.
  final bool showTechDetails;

  /// Number of pending decisions (approve + reject + edit) the screen has
  /// staged. Drives the "Save my choices (N)" count + enabled state.
  final int pendingCount;

  /// Returns the staged decision kind for [candidateId], or null when the
  /// row has no pending decision. Used to render the per-row staged chip.
  final GraphDecisionKind? Function(String candidateId) queuedDecisionFor;

  /// Stage / unstage an approve for one connection.
  final void Function(GraphCandidate candidate) onApprove;

  /// Stage / unstage a reject for one connection.
  final void Function(GraphCandidate candidate) onReject;

  /// Open the Change modal for one connection. Resolves to a staged edit.
  final void Function(GraphCandidate candidate) onEdit;

  /// Approve every clear connection in one batch ("Mark all N correct").
  final void Function(List<GraphCandidate> clearCandidates) onBulkApprove;

  /// Commit the staged batch ("Save my choices").
  final VoidCallback onSave;

  /// Clear every pending decision ("Start over").
  final VoidCallback onStartOver;

  /// A commit / load is in flight: disable every action.
  final bool busy;

  /// Whether saving is allowed. The screen sets this false when no commit
  /// target operator/location is configured (the live path before the
  /// standard scope picker has a business + location), so a decision
  /// cannot be written against the wrong tenant (HP #4). Defaults true for
  /// the demo/test path which always supplies a target.
  final bool canSave;

  @override
  State<CorpusConnectionsView> createState() => _CorpusConnectionsViewState();
}

/// The "Show" filter options.
enum _ConnectionsShow { attention, everything, clear }

class _CorpusConnectionsViewState extends State<CorpusConnectionsView> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  _ConnectionsShow _show = _ConnectionsShow.attention;

  // Per-group "show N more" expansion. Each starts collapsed at
  // [_kInitialPageSize] and grows when the pager is tapped.
  int _shownClear = _kInitialPageSize;
  int _shownCheck = _kInitialPageSize;
  int _shownUnsure = _kInitialPageSize;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Every candidate across the producer's three buckets, flattened.
  List<GraphCandidate> get _all => <GraphCandidate>[
    ...widget.diff.extracted,
    ...widget.diff.inferred,
    ...widget.diff.ambiguous,
  ];

  bool _matchesQuery(GraphCandidate c) {
    if (_query.isEmpty) return true;
    final haystack = <String>[
      corpusConnectionNodeName(c.fromNodeKey),
      corpusConnectionNodeName(c.toNodeKey),
      c.displayLabel,
      corpusRelationshipVerb(c.candidateType),
    ].join(' ').toLowerCase();
    return haystack.contains(_query);
  }

  List<GraphCandidate> _bucket(CorpusConnectionClarity clarity) => _all
      .where((c) => corpusConnectionClarity(c) == clarity && _matchesQuery(c))
      .toList(growable: false);

  /// Which clarity groups the active "Show" filter reveals.
  bool _groupVisible(CorpusConnectionClarity clarity) {
    switch (_show) {
      case _ConnectionsShow.everything:
        return true;
      case _ConnectionsShow.clear:
        return clarity == CorpusConnectionClarity.clear;
      case _ConnectionsShow.attention:
        return clarity != CorpusConnectionClarity.clear;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _all.length;
    final clear = _bucket(CorpusConnectionClarity.clear);
    final check = _bucket(CorpusConnectionClarity.check);
    final unsure = _bucket(CorpusConnectionClarity.unsure);

    // Honest counts over the whole set (not the search-filtered subset)
    // so the summary headline + dropdown read the true totals.
    final clearTotal = _all
        .where((c) => corpusConnectionClarity(c) == CorpusConnectionClarity.clear)
        .length;
    final checkTotal = _all
        .where((c) => corpusConnectionClarity(c) == CorpusConnectionClarity.check)
        .length;
    final unsureTotal = _all
        .where(
          (c) => corpusConnectionClarity(c) == CorpusConnectionClarity.unsure,
        )
        .length;
    final attentionTotal = checkTotal + unsureTotal;

    final hasActiveFilter =
        _query.isNotEmpty || _show != _ConnectionsShow.everything;
    final anyVisible =
        (_groupVisible(CorpusConnectionClarity.clear) && clear.isNotEmpty) ||
        (_groupVisible(CorpusConnectionClarity.check) && check.isNotEmpty) ||
        (_groupVisible(CorpusConnectionClarity.unsure) && unsure.isNotEmpty);

    return SingleChildScrollView(
      key: const Key('admin_corpus_connections_body'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (!widget.editingEnabled)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: OperatorWebBanner(
                key: Key('admin_corpus_connections_readonly_banner'),
                icon: Icons.lock_outline,
                message: AdminKnowledgeBaseCopy.connectionsReadOnlyBanner,
              ),
            ),

          // Scope control: names exactly where approvals land. Edit-only
          // (read-only ff_support cannot approve, so it never needs to
          // pick a target). The knowledge documents are global, so this
          // control lives ONLY on the Connections tab.
          if (widget.editingEnabled) ...<Widget>[
            _ConnectionsScopeControl(
              hasTarget: widget.canSave,
              scopeLabel: widget.scopeLabel,
              onChangeScope: widget.busy ? null : widget.onChangeScope,
            ),
            const SizedBox(height: 16),
          ],

          // Empty corpus: nothing to review.
          if (total == 0)
            const OperatorWebPanel(
              key: Key('admin_corpus_connections_empty'),
              title: AdminKnowledgeBaseCopy.connectionsMapTitle,
              child: Text(AdminKnowledgeBaseCopy.connectionsEmpty),
            )
          else ...<Widget>[
            _ConnectionsSummaryCard(
              total: total,
              clearCount: clearTotal,
              checkCount: checkTotal,
              unsureCount: unsureTotal,
              attentionCount: attentionTotal,
              searchController: _searchController,
              query: _query,
              show: _show,
              onShowChanged: (value) =>
                  setState(() => _show = value ?? _show),
              onClearSearch: () => _searchController.clear(),
            ),
            const SizedBox(height: 18),

            // C2-map: the focusable node-link Map, reading the SAME diff
            // the lists below render. No new gateway/proxy/data.
            CorpusConnectionsMap(diff: widget.diff),
            const SizedBox(height: 18),

            if (!anyVisible)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  hasActiveFilter
                      ? AdminKnowledgeBaseCopy.connectionsFilteredEmpty
                      : AdminKnowledgeBaseCopy.connectionsEmpty,
                  key: const Key('admin_corpus_connections_filtered_empty'),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),

            if (_groupVisible(CorpusConnectionClarity.clear) && clear.isNotEmpty)
              _ConnectionsGroup(
                groupKey: const Key('admin_corpus_connections_group_clear'),
                clarity: CorpusConnectionClarity.clear,
                heading: AdminKnowledgeBaseCopy.connectionsGroupClear,
                candidates: clear,
                shown: _shownClear,
                onShowMore: (more) => setState(() => _shownClear += more),
                showMoreLabel: AdminKnowledgeBaseCopy.connectionsShowMoreClear,
                editingEnabled: widget.editingEnabled,
                showTechDetails: widget.showTechDetails,
                busy: widget.busy,
                queuedDecisionFor: widget.queuedDecisionFor,
                onApprove: widget.onApprove,
                onReject: widget.onReject,
                onEdit: widget.onEdit,
                // The clear group carries the "Mark all N correct" bulk
                // action. It approves every clear candidate (the honest,
                // high-confidence set), never the worth-checking or
                // not-sure ones.
                bulkAction: widget.editingEnabled
                    ? AdminActionButton(
                        key: const Key(
                          'admin_corpus_connections_mark_all_clear',
                        ),
                        label: AdminKnowledgeBaseCopy.connectionsMarkAllCorrect(
                          clearTotal,
                        ),
                        onPressed: widget.busy
                            ? null
                            : () => widget.onBulkApprove(
                                _all
                                    .where(
                                      (c) =>
                                          corpusConnectionClarity(c) ==
                                              CorpusConnectionClarity.clear &&
                                          _canApprove(c),
                                    )
                                    .toList(growable: false),
                              ),
                        icon: Icons.done_all_outlined,
                        role: AdminActionRole.primary,
                        compact: true,
                      )
                    : null,
              ),
            if (_groupVisible(CorpusConnectionClarity.check) && check.isNotEmpty)
              _ConnectionsGroup(
                groupKey: const Key('admin_corpus_connections_group_check'),
                clarity: CorpusConnectionClarity.check,
                heading: AdminKnowledgeBaseCopy.connectionsGroupCheck,
                candidates: check,
                shown: _shownCheck,
                onShowMore: (more) => setState(() => _shownCheck += more),
                showMoreLabel: AdminKnowledgeBaseCopy.connectionsShowMoreCheck,
                editingEnabled: widget.editingEnabled,
                showTechDetails: widget.showTechDetails,
                busy: widget.busy,
                queuedDecisionFor: widget.queuedDecisionFor,
                onApprove: widget.onApprove,
                onReject: widget.onReject,
                onEdit: widget.onEdit,
              ),
            if (_groupVisible(CorpusConnectionClarity.unsure) &&
                unsure.isNotEmpty)
              _ConnectionsGroup(
                groupKey: const Key('admin_corpus_connections_group_unsure'),
                clarity: CorpusConnectionClarity.unsure,
                heading: AdminKnowledgeBaseCopy.connectionsGroupUnsure,
                candidates: unsure,
                shown: _shownUnsure,
                onShowMore: (more) => setState(() => _shownUnsure += more),
                showMoreLabel: AdminKnowledgeBaseCopy.connectionsShowMoreUnsure,
                editingEnabled: widget.editingEnabled,
                showTechDetails: widget.showTechDetails,
                busy: widget.busy,
                queuedDecisionFor: widget.queuedDecisionFor,
                onApprove: widget.onApprove,
                onReject: widget.onReject,
                onEdit: widget.onEdit,
              ),

            if (widget.editingEnabled) ...<Widget>[
              const SizedBox(height: 24),
              AdminActionBar(
                alignment: WrapAlignment.start,
                children: <Widget>[
                  AdminActionButton(
                    key: const Key('admin_corpus_connections_save'),
                    label: AdminKnowledgeBaseCopy.connectionsSaveChoices(
                      widget.pendingCount,
                    ),
                    // Disabled until at least one decision is staged, while
                    // a commit is in flight, or when no commit target is
                    // configured (canSave false) so a click cannot write
                    // against the wrong tenant.
                    onPressed:
                        (widget.pendingCount == 0 ||
                            widget.busy ||
                            !widget.canSave)
                        ? null
                        : widget.onSave,
                    icon: Icons.check_circle_outline,
                    role: AdminActionRole.primary,
                  ),
                  AdminActionButton(
                    key: const Key('admin_corpus_connections_start_over'),
                    label: AdminKnowledgeBaseCopy.connectionsStartOver,
                    onPressed: (widget.pendingCount == 0 || widget.busy)
                        ? null
                        : widget.onStartOver,
                    icon: Icons.clear,
                  ),
                ],
              ),
              // Honest hint when saving is disabled because no commit
              // target is configured. Lightweight guidance only: it points
              // the operator at the Scope pane (the redesign deliberately
              // dropped the old in-tab operator-picker button). The
              // demo/test path always supplies a target, so it stays hidden
              // there.
              if (!widget.canSave)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    key: const Key('admin_corpus_connections_no_target_hint'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Icon(
                        Icons.info_outline,
                        size: 16,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AdminKnowledgeBaseCopy.connectionsNoTargetHint,
                          style: AppTextStyles.body12(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The compact scope control at the top of the Connections tab. Names
/// exactly where approvals land ("Approving connections for: Business :
/// Location") with a change affordance, or an honest empty state before
/// a target is chosen. This is the ONLY scope control on the screen: the
/// Knowledge tab has none because its documents are global Forge & Flow
/// content. Replaces the redundant shell-level left scope pane for this
/// route.
class _ConnectionsScopeControl extends StatelessWidget {
  const _ConnectionsScopeControl({
    required this.hasTarget,
    required this.scopeLabel,
    required this.onChangeScope,
  });

  /// Whether a commit target (operator + location) is configured. Drives
  /// the "target set" vs "choose a business" state independently of
  /// whether a friendly label happens to be known.
  final bool hasTarget;
  final String? scopeLabel;
  final VoidCallback? onChangeScope;

  @override
  Widget build(BuildContext context) {
    final label = scopeLabel?.trim();
    // Honest fallback: a target can be set without a friendly label
    // (e.g. a host-supplied default with only IDs). Never claim "no
    // business chosen" when one actually is.
    final displayLabel = (label != null && label.isNotEmpty)
        ? label
        : 'the selected business and location';
    // Soft, calm surface (peacock-tinted fill, no hard border) so it
    // reads as a quiet context strip rather than another boxed card.
    return Container(
      key: const Key('admin_corpus_connections_scope_control'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Icon(
            hasTarget ? Icons.place_outlined : Icons.help_outline,
            size: 18,
            color: AppColors.peacockDark,
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: hasTarget
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        AdminKnowledgeBaseCopy.connectionsScopeLabel,
                        style: AppTextStyles.body12(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        displayLabel,
                        key: const Key(
                          'admin_corpus_connections_scope_value',
                        ),
                        style: AppTextStyles.body14(
                          color: AppColors.textPrimary,
                        ).copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  )
                : Text(
                    AdminKnowledgeBaseCopy.connectionsScopeNone,
                    key: const Key('admin_corpus_connections_scope_none'),
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
          ),
          if (onChangeScope != null)
            AdminActionButton(
              key: const Key('admin_corpus_connections_scope_change'),
              label: hasTarget
                  ? AdminKnowledgeBaseCopy.connectionsScopeChange
                  : AdminKnowledgeBaseCopy.connectionsScopeChoose,
              onPressed: onChangeScope,
              icon: Icons.account_tree_outlined,
              role: hasTarget
                  ? AdminActionRole.secondary
                  : AdminActionRole.primary,
              compact: true,
            ),
        ],
      ),
    );
  }
}

/// C2: summary card. Headline count + three clarity chips + search box +
/// "Show" dropdown. Mirrors the preview's `.summary` + `.toolbar`.
class _ConnectionsSummaryCard extends StatelessWidget {
  const _ConnectionsSummaryCard({
    required this.total,
    required this.clearCount,
    required this.checkCount,
    required this.unsureCount,
    required this.attentionCount,
    required this.searchController,
    required this.query,
    required this.show,
    required this.onShowChanged,
    required this.onClearSearch,
  });

  final int total;
  final int clearCount;
  final int checkCount;
  final int unsureCount;
  final int attentionCount;
  final TextEditingController searchController;
  final String query;
  final _ConnectionsShow show;
  final ValueChanged<_ConnectionsShow?> onShowChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_corpus_connections_summary'),
      title: AdminKnowledgeBaseCopy.connectionsFound(total),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              // De-clutter: only show a clarity chip when that bucket has
              // connections. A prominent "0 worth checking" chip is noise,
              // not signal, so empty buckets drop out entirely.
              if (clearCount > 0)
                _ClarityCountChip(
                  clarity: CorpusConnectionClarity.clear,
                  label: AdminKnowledgeBaseCopy.connectionsClearChip(clearCount),
                ),
              if (checkCount > 0)
                _ClarityCountChip(
                  clarity: CorpusConnectionClarity.check,
                  label: AdminKnowledgeBaseCopy.connectionsCheckChip(checkCount),
                ),
              if (unsureCount > 0)
                _ClarityCountChip(
                  clarity: CorpusConnectionClarity.unsure,
                  label: AdminKnowledgeBaseCopy.connectionsUnsureChip(
                    unsureCount,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
                child: TextField(
                  key: const Key('admin_corpus_connections_search'),
                  controller: searchController,
                  decoration: InputDecoration(
                    hintText: AdminKnowledgeBaseCopy.connectionsSearchHint,
                    hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
                    prefixIcon: const Icon(
                      Icons.search_outlined,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                    suffixIcon: query.isNotEmpty
                        ? AdminIconAction(
                            icon: Icons.clear,
                            tooltip: 'Clear search',
                            onPressed: onClearSearch,
                          )
                        : null,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.small),
                      borderSide: const BorderSide(
                        color: AppColors.borderSubtle,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.small),
                      borderSide: const BorderSide(
                        color: AppColors.borderSubtle,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.small),
                      borderSide: const BorderSide(
                        color: AppColors.sunset,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              _ShowDropdown(
                show: show,
                attentionCount: attentionCount,
                everythingCount: total,
                clearCount: clearCount,
                onChanged: onShowChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// C2: a clarity summary chip (a colored dot + "N clear" style label).
class _ClarityCountChip extends StatelessWidget {
  const _ClarityCountChip({required this.clarity, required this.label});

  final CorpusConnectionClarity clarity;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = _clarityColor(clarity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label, style: AppTextStyles.chipLabel(color: color)),
        ],
      ),
    );
  }
}

/// C2: the "Show" dropdown (needs my attention / everything / clear only).
class _ShowDropdown extends StatelessWidget {
  const _ShowDropdown({
    required this.show,
    required this.attentionCount,
    required this.everythingCount,
    required this.clearCount,
    required this.onChanged,
  });

  final _ConnectionsShow show;
  final int attentionCount;
  final int everythingCount;
  final int clearCount;
  final ValueChanged<_ConnectionsShow?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<_ConnectionsShow>(
          key: const Key('admin_corpus_connections_show'),
          value: show,
          isDense: true,
          borderRadius: BorderRadius.circular(AppRadius.small),
          icon: const Icon(
            Icons.expand_more_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          style: AppTextStyles.body13(color: AppColors.textPrimary),
          dropdownColor: AppColors.backgroundSurface,
          items: <DropdownMenuItem<_ConnectionsShow>>[
            DropdownMenuItem<_ConnectionsShow>(
              value: _ConnectionsShow.attention,
              child: Text(
                AdminKnowledgeBaseCopy.connectionsShowAttention(attentionCount),
              ),
            ),
            DropdownMenuItem<_ConnectionsShow>(
              value: _ConnectionsShow.everything,
              child: Text(
                AdminKnowledgeBaseCopy.connectionsShowEverything(
                  everythingCount,
                ),
              ),
            ),
            DropdownMenuItem<_ConnectionsShow>(
              value: _ConnectionsShow.clear,
              child: Text(
                AdminKnowledgeBaseCopy.connectionsShowClearOnly(clearCount),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// C2: one clarity-grouped list (clear / worth checking / not sure). Shows
/// a heading with a colored dot + count pill (+ optional bulk action), the
/// first [shown] rows, then a "Show N more" pager.
class _ConnectionsGroup extends StatelessWidget {
  const _ConnectionsGroup({
    required this.groupKey,
    required this.clarity,
    required this.heading,
    required this.candidates,
    required this.shown,
    required this.onShowMore,
    required this.showMoreLabel,
    required this.editingEnabled,
    required this.showTechDetails,
    required this.busy,
    required this.queuedDecisionFor,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    this.bulkAction,
  });

  final Key groupKey;
  final CorpusConnectionClarity clarity;
  final String heading;
  final List<GraphCandidate> candidates;
  final int shown;
  final ValueChanged<int> onShowMore;
  final String Function(int count) showMoreLabel;
  final bool editingEnabled;
  final bool showTechDetails;
  final bool busy;
  final GraphDecisionKind? Function(String candidateId) queuedDecisionFor;
  final void Function(GraphCandidate candidate) onApprove;
  final void Function(GraphCandidate candidate) onReject;
  final void Function(GraphCandidate candidate) onEdit;
  final Widget? bulkAction;

  @override
  Widget build(BuildContext context) {
    final color = _clarityColor(clarity);
    final visible = candidates.take(shown).toList(growable: false);
    final remaining = candidates.length - visible.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        key: groupKey,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Group heading row: dot + label + count pill (+ bulk action).
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  heading,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 8),
                _CountPill(count: candidates.length),
                const Spacer(),
                if (bulkAction != null) bulkAction!,
              ],
            ),
          ),
          ...visible.map(
            (c) => _ConnectionRow(
              key: Key('admin_corpus_connection_tile_${c.candidateId}'),
              candidate: c,
              clarity: clarity,
              editingEnabled: editingEnabled,
              showTechDetails: showTechDetails,
              busy: busy,
              stagedDecision: queuedDecisionFor(c.candidateId),
              onApprove: () => onApprove(c),
              onReject: () => onReject(c),
              onEdit: () => onEdit(c),
            ),
          ),
          if (remaining > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              child: TextButton.icon(
                key: Key(
                  'admin_corpus_connections_show_more_${clarity.name}',
                ),
                onPressed: () => onShowMore(_kInitialPageSize),
                icon: const Icon(Icons.expand_more_outlined, size: 16),
                label: Text(showMoreLabel(remaining)),
              ),
            ),
        ],
      ),
    );
  }
}

/// C2: count pill next to a group heading.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        '$count',
        style: AppTextStyles.mono8(color: AppColors.textSecondary),
      ),
    );
  }
}

/// C2: one connection row. A from -> verb -> to flow, a plain-English
/// sentence, a clarity chip, edit-only actions, and a per-row technical
/// disclosure (shown only when [showTechDetails] is on; machine IDs hidden
/// when off).
class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    super.key,
    required this.candidate,
    required this.clarity,
    required this.editingEnabled,
    required this.showTechDetails,
    required this.busy,
    required this.stagedDecision,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
  });

  final GraphCandidate candidate;
  final CorpusConnectionClarity clarity;
  final bool editingEnabled;
  final bool showTechDetails;
  final bool busy;
  final GraphDecisionKind? stagedDecision;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final queued = stagedDecision != null;
    final approvable = _canApprove(candidate);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: queued
            ? AppColors.sunset.withValues(alpha: 0.10)
            : AppColors.backgroundSurface,
        border: Border.all(
          color: queued
              ? AppColors.sunset
              : AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _ConnectionFlow(candidate: candidate, clarity: clarity),
          const SizedBox(height: 8),
          Text(
            corpusConnectionSentence(candidate),
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          _ClarityChip(clarity: clarity),
          if (queued) ...<Widget>[
            const SizedBox(height: 8),
            _StagedChip(
              key: Key('admin_corpus_connection_staged_${candidate.candidateId}'),
              kind: stagedDecision!,
            ),
          ],
          if (editingEnabled) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                // Clear + worth-checking rows lead with "Looks right".
                // Not-sure rows lead with "Set how they connect" (Change)
                // and never expose a bare approve, per the AMBIGUOUS
                // debug-only contract.
                if (approvable)
                  FilledButton.icon(
                    key: Key(
                      'admin_corpus_connection_approve_${candidate.candidateId}',
                    ),
                    onPressed: busy ? null : onApprove,
                    style: AdminButtonStyles.approval(
                      selected: stagedDecision == GraphDecisionKind.approve,
                    ),
                    icon: Icon(
                      stagedDecision == GraphDecisionKind.approve
                          ? Icons.check_circle_outline
                          : Icons.check_outlined,
                      size: 14,
                    ),
                    label: Text(
                      stagedDecision == GraphDecisionKind.approve
                          ? 'Selected'
                          : AdminKnowledgeBaseCopy.connectionsLooksRight,
                    ),
                  )
                else
                  AdminActionButton(
                    key: Key(
                      'admin_corpus_connection_set_how_${candidate.candidateId}',
                    ),
                    label: AdminKnowledgeBaseCopy.connectionsSetHow,
                    onPressed: busy ? null : onEdit,
                    icon: Icons.edit_outlined,
                    role: AdminActionRole.primary,
                    compact: true,
                  ),
                OutlinedButton.icon(
                  key: Key(
                    'admin_corpus_connection_reject_${candidate.candidateId}',
                  ),
                  onPressed: busy ? null : onReject,
                  style: AdminButtonStyles.reject(
                    selected: stagedDecision == GraphDecisionKind.reject,
                  ),
                  icon: const Icon(Icons.close_outlined, size: 14),
                  label: Text(
                    stagedDecision == GraphDecisionKind.reject
                        ? 'Selected'
                        : AdminKnowledgeBaseCopy.connectionsNotRight,
                  ),
                ),
                // Clear + worth-checking rows also expose "Change" (the
                // not-sure row already leads with it).
                if (approvable)
                  AdminActionButton(
                    key: Key(
                      'admin_corpus_connection_change_${candidate.candidateId}',
                    ),
                    label: stagedDecision == GraphDecisionKind.edit
                        ? 'Change queued'
                        : AdminKnowledgeBaseCopy.connectionsChange,
                    onPressed: busy ? null : onEdit,
                    icon: Icons.edit_outlined,
                    compact: true,
                  ),
              ],
            ),
          ],
          if (showTechDetails) ...<Widget>[
            const SizedBox(height: 6),
            _ConnectionTechDetails(candidate: candidate),
          ],
        ],
      ),
    );
  }
}

/// C2: the from -> verb -> to flow row (kind icon + name + kind label per
/// node, connector verb in the middle).
class _ConnectionFlow extends StatelessWidget {
  const _ConnectionFlow({required this.candidate, required this.clarity});

  final GraphCandidate candidate;
  final CorpusConnectionClarity clarity;

  @override
  Widget build(BuildContext context) {
    // Node candidates carry a single endpoint; edge candidates carry two.
    // For an edge we read the from/to types out of the payload when the
    // producer recorded them; otherwise the kind falls back to Document.
    final fromType = candidate.payload['from_node_type'] as String?;
    final toType = candidate.payload['to_node_type'] as String?;
    final fromKind = corpusConnectionNodeKind(
      fromType ?? (candidate.kind == GraphCandidateKind.node
          ? candidate.candidateType
          : null),
    );
    final toKind = corpusConnectionNodeKind(toType);
    final verb = corpusRelationshipVerb(candidate.candidateType);

    if (candidate.kind == GraphCandidateKind.node) {
      // A single-node candidate: show one node chip.
      return _FlowNode(
        kind: fromKind,
        name: corpusConnectionNodeName(
          candidate.displayLabel.isNotEmpty
              ? candidate.displayLabel
              : candidate.candidateKey,
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        _FlowNode(
          kind: fromKind,
          name: corpusConnectionNodeName(candidate.fromNodeKey),
        ),
        _FlowConnector(verb: verb, color: _clarityColor(clarity)),
        _FlowNode(
          kind: toKind,
          name: corpusConnectionNodeName(candidate.toNodeKey),
        ),
      ],
    );
  }
}

/// C2: one node in a connection flow: kind icon + name + kind label.
class _FlowNode extends StatelessWidget {
  const _FlowNode({required this.kind, required this.name});

  final AdminCorpusTopicKind kind;
  final String name;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TopicKindIcon(kind: kind),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                Text(
                  kind.pill,
                  style: AppTextStyles.mono8(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// C2: the verb connector between two flow nodes.
class _FlowConnector extends StatelessWidget {
  const _FlowConnector({required this.verb, required this.color});

  final String verb;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          verb,
          style: AppTextStyles.mono11(color: color),
        ),
        const SizedBox(width: 6),
        Icon(Icons.arrow_forward, size: 14, color: color),
      ],
    );
  }
}

/// C2: per-row clarity chip (Clear match / Worth checking / Not sure).
class _ClarityChip extends StatelessWidget {
  const _ClarityChip({required this.clarity});

  final CorpusConnectionClarity clarity;

  @override
  Widget build(BuildContext context) {
    final color = _clarityColor(clarity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            _clarityChipLabel(clarity),
            style: AppTextStyles.mono8(color: color),
          ),
        ],
      ),
    );
  }
}

/// C2: staged-decision chip shown on a row with a pending choice.
class _StagedChip extends StatelessWidget {
  const _StagedChip({super.key, required this.kind});

  final GraphDecisionKind kind;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final String label;
    switch (kind) {
      case GraphDecisionKind.approve:
        bg = AppColors.positive.withValues(alpha: 0.15);
        fg = AppColors.positive;
        label = 'Marked correct';
        break;
      case GraphDecisionKind.reject:
        bg = AppColors.negative.withValues(alpha: 0.15);
        fg = AppColors.negative;
        label = 'Marked not right';
        break;
      case GraphDecisionKind.edit:
        bg = AppColors.warningBadgeBg;
        fg = AppColors.warning;
        label = 'Changed';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        'Your choice: $label',
        style: AppTextStyles.mono8(color: fg),
      ),
    );
  }
}

/// C2: per-row technical disclosure. Relationship type, confidence, and
/// the from/to machine IDs. Rendered only when the screen-level "Show
/// technical details" is on (the parent passes [showTechDetails]); the
/// machine IDs never render when it is off.
class _ConnectionTechDetails extends StatelessWidget {
  const _ConnectionTechDetails({required this.candidate});

  final GraphCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final score = candidate.confidenceScore;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.small),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            AdminKnowledgeBaseCopy.connectionsTechTitle,
            style: AppTextStyles.mono8(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          _TechRow(label: 'Relationship', value: candidate.candidateType),
          _TechRow(
            label: 'Confidence',
            value: score == null ? '—' : score.toStringAsFixed(2),
          ),
          if (candidate.kind == GraphCandidateKind.edge)
            _TechRow(
              label: 'From / to',
              value:
                  '${candidate.fromNodeKey ?? '(unknown)'} -> '
                  '${candidate.toNodeKey ?? '(unknown)'}',
            )
          else
            _TechRow(
              label: 'Item',
              value: candidate.candidateKey,
            ),
        ],
      ),
    );
  }
}

class _TechRow extends StatelessWidget {
  const _TechRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono11(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// C2: the "Change" modal. "How are these connected?" / "Pick the sentence
/// that is true." / the candidate's relationship options as plain-English
/// sentences / an optional note / Cancel + "Save this connection".
///
/// Returns an [ApprovalDecision] (kind == edit) that re-buckets the
/// candidate to the chosen relationship type and forwards the original
/// payload verbatim (the proxy 400s on an edit missing `edited_payload`).
/// Null = the operator cancelled.
class CorpusConnectionChangeDialog extends StatefulWidget {
  const CorpusConnectionChangeDialog({
    super.key,
    required this.candidate,
    this.initialDecision,
  });

  final GraphCandidate candidate;
  final ApprovalDecision? initialDecision;

  @override
  State<CorpusConnectionChangeDialog> createState() =>
      _CorpusConnectionChangeDialogState();
}

class _CorpusConnectionChangeDialogState
    extends State<CorpusConnectionChangeDialog> {
  late final TextEditingController _noteController;
  late String _selectedType;

  /// The relationship options offered as plain-English sentences. Built
  /// from a small, honest vocabulary plus the candidate's own current type
  /// so the operator can keep it as-is. Each maps to a wire relationship
  /// type the proxy understands.
  late final List<_RelationshipOption> _options;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController(
      text: widget.initialDecision?.reason ?? '',
    );
    final from = corpusConnectionNodeName(widget.candidate.fromNodeKey);
    final to = corpusConnectionNodeName(widget.candidate.toNodeKey);
    final current = widget.candidate.candidateType.trim().toUpperCase();
    final seen = <String>{};
    final options = <_RelationshipOption>[];
    void add(String type, String sentence) {
      final t = type.trim().toUpperCase();
      if (t.isEmpty || !seen.add(t)) return;
      options.add(_RelationshipOption(type: t, sentence: sentence));
    }

    // The candidate's current type first so "keep it" is the default.
    if (current.isNotEmpty && current != 'RELATES_TO' && current != 'NEAR') {
      add(current, '$from ${corpusRelationshipVerb(current)} $to.');
    }
    add('CONTAINS', '$from includes $to.');
    add('INFORMS', '$from informs $to.');
    add('REQUIRES', '$from requires $to.');
    add('REDUCES_RISK_OF', '$from reduces the risk of $to.');
    add('PART_OF', '$from is part of $to.');
    add('RELATES_TO', '$from is related to $to.');

    _options = options;
    _selectedType = widget.initialDecision?.editedCandidateType
            ?.trim()
            .toUpperCase() ??
        (options.isNotEmpty ? options.first.type : current);
  }

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_corpus_connection_change_dialog'),
      title: AdminKnowledgeBaseCopy.connectionsChangeTitle,
      maxWidth: 520,
      actions: <Widget>[
        AdminActionButton(
          label: AdminKnowledgeBaseCopy.connectionsChangeCancel,
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_corpus_connection_change_dialog_save'),
          label: AdminKnowledgeBaseCopy.connectionsChangeSave,
          onPressed: () {
            final note = _noteController.text.trim();
            Navigator.of(context).pop(
              ApprovalDecision(
                candidateId: widget.candidate.candidateId,
                kind: GraphDecisionKind.edit,
                editedCandidateType: _selectedType,
                // The proxy rejects an edit decision without
                // `edited_payload` (`missing_edited_payload` 400). The
                // launch slice forwards the original candidate payload
                // verbatim; the operator's structural change is the
                // relationship type.
                editedPayload: Map<String, Object?>.from(
                  widget.candidate.payload,
                ),
                reason: note.isEmpty ? null : note,
              ),
            );
          },
          role: AdminActionRole.primary,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            AdminKnowledgeBaseCopy.connectionsChangeSub,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          ..._options.map(
            (option) => _RelationshipOptionTile(
              key: Key(
                'admin_corpus_connection_change_option_${option.type}',
              ),
              option: option,
              selected: option.type == _selectedType,
              onTap: () => setState(() => _selectedType = option.type),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            AdminKnowledgeBaseCopy.connectionsChangeNoteLabel,
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          TextField(
            key: const Key('admin_corpus_connection_change_dialog_note'),
            controller: _noteController,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: AdminKnowledgeBaseCopy.connectionsChangeNoteHint,
              hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.small),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One relationship choice in the Change modal: a radio + a plain-English
/// sentence.
class _RelationshipOption {
  const _RelationshipOption({required this.type, required this.sentence});

  final String type;
  final String sentence;
}

class _RelationshipOptionTile extends StatelessWidget {
  const _RelationshipOptionTile({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _RelationshipOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.small),
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sunset.withValues(alpha: 0.10)
              : AppColors.backgroundSurface,
          border: Border.all(
            color: selected ? AppColors.sunset : AppColors.borderSubtle,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(AppRadius.small),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.sunsetDark : AppColors.textMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                option.sentence,
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
