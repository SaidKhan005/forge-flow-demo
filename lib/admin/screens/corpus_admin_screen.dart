// Phase 11A.3a - Corpus admin screen.
//
// Admin-side editor over the `corpus_versions` ledger plus the
// per-chunk `version_id` / `superseded_at` pointers. Replaces the
// 11A.0 placeholder in `admin_routes.dart`.
//
// Coverage:
//
//   * Versions list (left column) shows current-first, prior-after,
//     each row carrying actor + summary + created_at + chunk count.
//   * Detail card (right column) shows the selected version's
//     subscription metadata plus the chunks attached to it.
//   * Drag-and-drop / "Choose file" upload runs the proxy preview
//     pipeline (or the demo gateway in kDemoMode) and lands on a diff
//     pane with new / modified / inactivated chunks.
//   * Commit + Rollback buttons are gated by [editingEnabled]; the
//     ff_support read-only walkthrough hides every mutate affordance
//     and the proxy method-scoped role split rejects any forced
//     calls server-side.
//
// Brand styling reuses `lib/theme/app_theme.dart` verbatim per the
// 11A non-negotiable. The screen takes a [CorpusAdminGateway] from
// the outside; production passes the HTTP gateway, demo + widget
// tests pass the in-memory gateway.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_screen_body.dart';
import '../../widgets/console/console_screen_header.dart';
import '../../widgets/console/console_surface.dart';

import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import '../services/corpus_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import 'corpus_admin_chunk_view.dart';
import 'corpus_admin_connections_view.dart';
import 'corpus_admin_history_view.dart';
import 'operator_picker_screen.dart';

/// Test seam: lets widget tests inject a synthetic upload byte source
/// without driving the platform file picker. Production's
/// drag-and-drop / file picker integration lands in 11A.3b; the
/// launch slice exposes a "Choose demo upload" affordance that returns
/// a fixture markdown body when this picker is left null.
typedef CorpusUploadPicker =
    Future<UploadCommand?> Function(BuildContext context);

/// Phase 11A.3a follow-up - opens [OperatorPickerScreen] (or a stub
/// in tests) and resolves to the picked (operator, location) pair, or
/// null if the admin cancels. Wired by `admin_routes.dart`'s
/// `_buildCorpus`; tests can pass a deterministic stub.
typedef OperatorPickerOpener =
    Future<OperatorPickerResult?> Function(BuildContext context);

class CorpusAdminScreen extends StatefulWidget {
  const CorpusAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.uploadPicker,
    this.idempotencyKeyGenerator,
    this.targetOperatorId,
    this.targetLocationId,
    this.targetLabel,
    this.operatorPickerOpener,
  });

  final CorpusAdminGateway gateway;
  final bool editingEnabled;

  /// Optional override that returns the bytes + filename to upload.
  /// Widget tests pin this; production wires the platform file picker
  /// in 11A.3b. When null, the screen renders an inline "demo
  /// methodology seed" affordance so the launch walkthrough stays
  /// click-driven.
  final CorpusUploadPicker? uploadPicker;

  /// Test seam for idempotency keys. Production uses a UUID v4
  /// generator; widget tests pin this to keep replay tests
  /// deterministic.
  final String Function()? idempotencyKeyGenerator;

  /// Phase 11A.3b - destination (operator, location) for approved
  /// graph candidates. Super_admin is cross-tenant, so the Graph
  /// candidates commit must name an operator explicitly. The screen
  /// itself does NOT default these - the host wiring in
  /// [lib/admin/admin_routes.dart] picks the targets explicitly:
  /// the demo path passes the kDemoMode tenant seed; the live path
  /// leaves them null until the admin uses the "Pick operator"
  /// button (Phase 11A.3a follow-up), and the Graph candidates
  /// commit button stays disabled in that case so the operator
  /// cannot accidentally write against a wrong tenant.
  final String? targetOperatorId;
  final String? targetLocationId;

  /// Optional plain-English "Business : Location" label for a
  /// host-supplied default target (the demo path supplies this so the
  /// Connections tab's scope control reads the friendly business +
  /// location names without a gateway round-trip). When the admin picks
  /// a target through the in-tab control, that pick's label takes over.
  final String? targetLabel;

  /// Phase 11A.3a follow-up - opens the operator picker modal. When
  /// the admin confirms a pair, the screen state takes over the
  /// effective target so the commit button enables. Null disables
  /// the picker affordance (pre-follow-up tests; the banner still
  /// renders in that path).
  final OperatorPickerOpener? operatorPickerOpener;

  @override
  State<CorpusAdminScreen> createState() => _CorpusAdminScreenState();
}

class _CorpusAdminScreenState extends State<CorpusAdminScreen> {
  // B-r1: screen-level "Show technical details" toggle. OFF by default
  // so the everyday view stays free of machine noise (raw IDs, content
  // hashes, confidence scores, version IDs). When ON, those details
  // appear across the rendered cards. Mirrors the approved preview's
  // `techToggle`. The flag is broadcast to descendants through
  // [_CorpusTechDetailsScope] so individual cards do not each need a
  // constructor parameter threaded down.
  bool _showTechDetails = false;

  bool _loading = true;
  String? _loadError;
  List<CorpusVersionRef> _versions = const <CorpusVersionRef>[];
  String? _selectedVersionId;
  CorpusBundle? _selectedBundle;
  CorpusDiff? _stagedDiff;
  String? _stagedFileName;
  String? _actionError;
  bool _busy = false;
  int _idempotencyCounter = 0;

  // Phase 11A.3a follow-up - once the admin confirms a pair through
  // the operator picker, these override [widget.targetOperatorId] /
  // [widget.targetLocationId] for the rest of the admin session. They
  // are intentionally session-scoped (not durable) - durable
  // persistence is a future slice.
  String? _pickedOperatorId;
  String? _pickedLocationId;
  String? _pickedTargetLabel;

  String? get _effectiveTargetOperatorId =>
      _pickedOperatorId ?? widget.targetOperatorId;
  String? get _effectiveTargetLocationId =>
      _pickedLocationId ?? widget.targetLocationId;

  /// Friendly "Business : Location" label for the active commit target:
  /// the admin's in-session pick wins, otherwise the host-supplied
  /// default label (demo path). Null when no target has a known label.
  String? get _effectiveTargetLabel =>
      _pickedTargetLabel ?? widget.targetLabel;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final versions = await widget.gateway.listVersions();
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loading = false;
        if (_selectedVersionId != null &&
            versions.every((v) => v.versionId != _selectedVersionId)) {
          _selectedVersionId = null;
        }
        _selectedVersionId ??= versions.isEmpty
            ? null
            : versions.first.versionId;
      });
      await _loadSelectedBundle();
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load advisor content: $error';
        _loading = false;
      });
    }
  }

  Future<void> _loadSelectedBundle() async {
    final id = _selectedVersionId;
    if (id == null) {
      setState(() => _selectedBundle = null);
      return;
    }
    try {
      final bundle = await widget.gateway.fetchVersion(versionId: id);
      if (!mounted) return;
      setState(() => _selectedBundle = bundle);
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _selectedBundle = null;
        _actionError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectedBundle = null;
        _actionError = error.toString();
      });
    }
  }

  String _newIdempotencyKey() {
    final generator = widget.idempotencyKeyGenerator;
    if (generator != null) return generator();
    _idempotencyCounter += 1;
    return 'corpus-${DateTime.now().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() {
      _actionError = null;
      _busy = true;
    });
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onUploadPressed() async {
    final picker = widget.uploadPicker ?? _defaultDemoPicker;
    final command = await picker(context);
    if (command == null) return;
    await _previewUpload(command);
  }

  /// Stages [command] through the proxy preview pipeline and lands on the
  /// "What this update changes" diff. Shared by the "Choose a file"
  /// button (via [_onUploadPressed]) and the inline dropzone's drag-drop
  /// path so both entry points behave identically.
  Future<void> _previewUpload(UploadCommand command) async {
    try {
      final diff = await widget.gateway.previewDiff(command);
      if (!mounted) return;
      setState(() {
        _stagedDiff = diff;
        _stagedFileName = command.fileName;
        _actionError = null;
      });
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _stagedDiff = null;
        _stagedFileName = command.fileName;
        _actionError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stagedDiff = null;
        _actionError = error.toString();
      });
    }
  }

  Future<void> _onCommitPressed() async {
    final diff = _stagedDiff;
    if (diff == null) return;
    final summary = diff.summary;
    await _runAndRefresh(() async {
      await widget.gateway.commitVersion(
        CommitCommand(
          previewToken: diff.previewToken,
          summary: summary,
          idempotencyKey: _newIdempotencyKey(),
        ),
      );
      if (!mounted) return;
      setState(() {
        _stagedDiff = null;
        _stagedFileName = null;
      });
    }, successHint: AdminKnowledgeBaseCopy.addSavedToast);
  }

  Future<void> _onPickOperatorPressed() async {
    final opener = widget.operatorPickerOpener;
    if (opener == null) return;
    final result = await opener(context);
    if (result == null || !mounted) return;
    setState(() {
      _pickedOperatorId = result.operatorId;
      _pickedLocationId = result.locationId;
      // Colon separator (UX no-em-dash law: a colon is the label/value
      // joiner). Reads "Demo Diner Co. : Toronto Yorkville".
      _pickedTargetLabel =
          '${result.operatorBusinessName} : ${result.locationName}';
    });
  }

  Future<void> _onRollbackPressed(CorpusVersionRef target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: AdminKnowledgeBaseCopy.historyGoBackTitle,
        message: AdminKnowledgeBaseCopy.historyGoBackBody,
        confirmLabel: AdminKnowledgeBaseCopy.historyGoBackConfirm,
      ),
    );
    if (confirmed != true) return;
    await _runAndRefresh(() async {
      await widget.gateway.rollbackToVersion(
        RollbackCommand(
          targetVersionId: target.versionId,
          summary: 'Went back to ${_shortVersion(target.versionId)}',
          idempotencyKey: _newIdempotencyKey(),
        ),
      );
    }, successHint: AdminKnowledgeBaseCopy.historyWentBackToast);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: _CorpusTechDetailsScope(
        showTechDetails: _showTechDetails,
        child: ColoredBox(
          key: const Key('admin_corpus_screen'),
          color: AppColors.backgroundDeep,
          child: OperatorWebScreenFrame(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Header(),
                const SizedBox(height: 12),
                _TechDetailsToggle(
                  value: _showTechDetails,
                  onChanged: (value) =>
                      setState(() => _showTechDetails = value),
                ),
                const SizedBox(height: 12),
                if (!widget.editingEnabled)
                  const _ReadOnlyBanner(
                    key: Key('admin_corpus_readonly_banner'),
                  ),
                if (_actionError != null)
                  _ErrorBanner(
                    key: const Key('admin_corpus_action_error'),
                    message: _actionError!,
                  ),
                const TabBar(
                  key: Key('admin_corpus_tab_bar'),
                  isScrollable: true,
                  indicatorColor: AppColors.sunset,
                  labelColor: AppColors.textPrimary,
                  unselectedLabelColor: AppColors.textSecondary,
                  tabs: <Widget>[
                    Tab(
                      key: Key('admin_corpus_versions_tab'),
                      text: 'Knowledge',
                    ),
                    Tab(
                      key: Key('admin_corpus_graph_candidates_tab'),
                      text: 'Connections',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _VersionsTab(
                        loading: _loading,
                        loadError: _loadError,
                        versions: _versions,
                        currentBundle: _selectedBundle,
                        stagedDiff: _stagedDiff,
                        stagedFileName: _stagedFileName,
                        editingEnabled: widget.editingEnabled,
                        busy: _busy,
                        onUploadPressed: _onUploadPressed,
                        onUploadCommand: _previewUpload,
                        onRollbackPressed: _onRollbackPressed,
                        onCommitPressed: _onCommitPressed,
                        onDiscardStaged: () => setState(() {
                          _stagedDiff = null;
                          _stagedFileName = null;
                        }),
                      ),
                      _LazyGraphCandidatesTab(
                        builder: (_) => _GraphCandidatesTab(
                          gateway: widget.gateway,
                          editingEnabled: widget.editingEnabled,
                          newIdempotencyKey: _newIdempotencyKey,
                          targetOperatorId: _effectiveTargetOperatorId,
                          targetLocationId: _effectiveTargetLocationId,
                          onPickOperator: widget.operatorPickerOpener == null
                              ? null
                              : _onPickOperatorPressed,
                          targetLabel: _effectiveTargetLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Knowledge tab body. B-r3 redesigns it into the approved preview's
/// vertical card stack:
///
///   1. [CorpusAddKnowledgeCard] — dropzone + "What this update changes".
///   2. "Topics the advisor knows" — B-r2's grouped [ChunkGroupedView]
///      over the current version's content.
///   3. [CorpusUpdateHistoryCard] — current-first version timeline with
///      rollback.
///
/// The screen owns all async work + idempotency keys; this widget only
/// renders state and raises callbacks.
class _VersionsTab extends StatelessWidget {
  const _VersionsTab({
    required this.loading,
    required this.loadError,
    required this.versions,
    required this.currentBundle,
    required this.stagedDiff,
    required this.stagedFileName,
    required this.editingEnabled,
    required this.busy,
    required this.onUploadPressed,
    required this.onUploadCommand,
    required this.onRollbackPressed,
    required this.onCommitPressed,
    required this.onDiscardStaged,
  });

  final bool loading;
  final String? loadError;
  final List<CorpusVersionRef> versions;

  /// The current version's content, shown in the Topics card.
  final CorpusBundle? currentBundle;
  final CorpusDiff? stagedDiff;
  final String? stagedFileName;
  final bool editingEnabled;
  final bool busy;
  final VoidCallback onUploadPressed;
  final ValueChanged<UploadCommand> onUploadCommand;
  final void Function(CorpusVersionRef target) onRollbackPressed;
  final VoidCallback onCommitPressed;
  final VoidCallback onDiscardStaged;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        key: Key('admin_corpus_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_corpus_load_error'),
        message: loadError!,
      );
    }

    final addCard = CorpusAddKnowledgeCard(
      editingEnabled: editingEnabled,
      busy: busy,
      stagedDiff: stagedDiff,
      stagedFileName: stagedFileName,
      onChooseFile: onUploadPressed,
      onUploadCommand: onUploadCommand,
      onSave: onCommitPressed,
      onCancel: onDiscardStaged,
    );

    // Empty corpus: the Add-knowledge card is the whole story (no topics,
    // no history yet). It carries its own dropzone + "Choose a file", so
    // there is nothing more to show until the first version lands.
    if (versions.isEmpty) {
      return SingleChildScrollView(
        key: const Key('admin_corpus_empty'),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: addCard,
      );
    }

    final chunks = currentBundle?.chunks ?? const <ChunkPreview>[];
    return SingleChildScrollView(
      key: const Key('admin_corpus_knowledge_tab'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          addCard,
          const SizedBox(height: 16),
          OperatorWebPanel(
            title: AdminKnowledgeBaseCopy.topicsTitle,
            subtitle: AdminKnowledgeBaseCopy.topicsLead,
            child: ChunkGroupedView(
              key: const Key('admin_corpus_grouped_view_current'),
              chunks: chunks,
              sectionTileBuilder: (c) => _ChunkPreviewTile(
                key: Key('admin_corpus_chunk_${c.chunkId}'),
                chunk: c,
              ),
            ),
          ),
          const SizedBox(height: 16),
          CorpusUpdateHistoryCard(
            versions: versions,
            editingEnabled: editingEnabled,
            busy: busy,
            onGoBack: onRollbackPressed,
          ),
        ],
      ),
    );
  }
}

class _LazyGraphCandidatesTab extends StatefulWidget {
  const _LazyGraphCandidatesTab({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_LazyGraphCandidatesTab> createState() =>
      _LazyGraphCandidatesTabState();
}

class _LazyGraphCandidatesTabState extends State<_LazyGraphCandidatesTab> {
  TabController? _controller;
  bool _visited = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextController = DefaultTabController.maybeOf(context);
    if (_controller == nextController) {
      _markVisitedIfActive();
      return;
    }
    _controller?.removeListener(_handleTabChange);
    _controller = nextController;
    _controller?.addListener(_handleTabChange);
    _markVisitedIfActive();
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleTabChange);
    super.dispose();
  }

  void _handleTabChange() => _markVisitedIfActive();

  void _markVisitedIfActive() {
    if (_visited) return;
    final controller = _controller;
    if (controller == null || controller.index != 1) return;
    setState(() => _visited = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visited) return const SizedBox.shrink();
    return widget.builder(context);
  }
}

// ─── Phase 11A.3b - Graphify candidate review tab ────────────────────

class _GraphCandidatesTab extends StatefulWidget {
  const _GraphCandidatesTab({
    required this.gateway,
    required this.editingEnabled,
    required this.newIdempotencyKey,
    required this.targetOperatorId,
    required this.targetLocationId,
    required this.onPickOperator,
    required this.targetLabel,
  });

  final CorpusAdminGateway gateway;
  final bool editingEnabled;
  final String Function() newIdempotencyKey;

  /// When either is null the tab still renders the diff but disables
  /// the commit button and asks the admin to choose a business scope
  /// through the in-tab scope control.
  final String? targetOperatorId;
  final String? targetLocationId;

  /// Opens the business + location picker for the in-tab scope control.
  /// Null disables the control's change affordance (pre-picker test
  /// paths); the control still renders the current target read-only.
  final VoidCallback? onPickOperator;

  /// Friendly "Business : Location" label for the active commit target
  /// (an in-session pick, or a host-supplied default). Null when no
  /// target has a known label yet, so the control reads its
  /// "choose a business" empty state.
  final String? targetLabel;

  bool get hasTarget =>
      (targetOperatorId?.isNotEmpty ?? false) &&
      (targetLocationId?.isNotEmpty ?? false);

  @override
  State<_GraphCandidatesTab> createState() => _GraphCandidatesTabState();
}

class _GraphCandidatesTabState extends State<_GraphCandidatesTab> {
  bool _loading = true;
  String? _loadError;
  GraphCandidateDiff? _diff;
  final Set<String> _approveQueue = <String>{};
  final Set<String> _rejectQueue = <String>{};
  final Map<String, ApprovalDecision> _editQueue = <String, ApprovalDecision>{};
  String? _actionError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final diff = await widget.gateway.listGraphCandidates();
      if (!mounted) return;
      setState(() {
        _diff = diff;
        _loading = false;
      });
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load relationship suggestions: $error';
        _loading = false;
      });
    }
  }

  bool get _hasQueuedDecisions =>
      _approveQueue.isNotEmpty ||
      _rejectQueue.isNotEmpty ||
      _editQueue.isNotEmpty;

  void _toggleApprove(GraphCandidate candidate) {
    // Spec contract: AMBIGUOUS relationships are debug-only until
    // edited into a clear approved relationship (plan line 249).
    // The row UI hides the Approve button on AMBIGUOUS candidates;
    // this guard is defense-in-depth so a future code path that
    // calls _toggleApprove programmatically (or a bulk handler)
    // cannot accidentally route an unedited ambiguous candidate
    // into canonical storage.
    if (candidate.label == GraphCandidateLabel.ambiguous) return;
    setState(() {
      if (_approveQueue.contains(candidate.candidateId)) {
        _approveQueue.remove(candidate.candidateId);
      } else {
        _approveQueue.add(candidate.candidateId);
        _rejectQueue.remove(candidate.candidateId);
        _editQueue.remove(candidate.candidateId);
      }
    });
  }

  void _toggleReject(GraphCandidate candidate) {
    setState(() {
      if (_rejectQueue.contains(candidate.candidateId)) {
        _rejectQueue.remove(candidate.candidateId);
      } else {
        _rejectQueue.add(candidate.candidateId);
        _approveQueue.remove(candidate.candidateId);
        _editQueue.remove(candidate.candidateId);
      }
    });
  }

  /// C2: "Mark all N correct" on the clear group. Approves every clear
  /// candidate in one batch. The view passes the exact clear set (already
  /// filtered to approvable candidates), so this stages each one for
  /// approval.
  void _bulkApproveClear(List<GraphCandidate> clearCandidates) {
    if (clearCandidates.isEmpty) return;
    setState(() {
      for (final c in clearCandidates) {
        // Defense-in-depth: never route an AMBIGUOUS candidate into an
        // approve (it is debug-only until edited). The view already
        // excludes them, this is a second guard.
        if (c.label == GraphCandidateLabel.ambiguous) continue;
        _approveQueue.add(c.candidateId);
        _rejectQueue.remove(c.candidateId);
        _editQueue.remove(c.candidateId);
      }
    });
  }

  void _discardQueue() {
    setState(() {
      _approveQueue.clear();
      _rejectQueue.clear();
      _editQueue.clear();
    });
  }

  /// Total pending decisions across approve + reject + edit. Drives the
  /// "Save my choices (N)" count + enabled state.
  int get _pendingCount =>
      _approveQueue.length + _rejectQueue.length + _editQueue.length;

  /// The staged decision kind for [candidateId], or null when the row has
  /// no pending decision. Lets each row render its staged chip + selected
  /// button state.
  GraphDecisionKind? _queuedDecisionFor(String candidateId) {
    if (_approveQueue.contains(candidateId)) return GraphDecisionKind.approve;
    if (_rejectQueue.contains(candidateId)) return GraphDecisionKind.reject;
    if (_editQueue.containsKey(candidateId)) return GraphDecisionKind.edit;
    return null;
  }

  Future<void> _onEditPressed(GraphCandidate candidate) async {
    final existing = _editQueue[candidate.candidateId];
    final result = await showDialog<ApprovalDecision>(
      context: context,
      builder: (dialogContext) => CorpusConnectionChangeDialog(
        candidate: candidate,
        initialDecision: existing,
      ),
    );
    if (result == null) return;
    setState(() {
      _editQueue[candidate.candidateId] = result;
      _approveQueue.remove(candidate.candidateId);
      _rejectQueue.remove(candidate.candidateId);
    });
  }

  Future<void> _onCommitBatch() async {
    if (!_hasQueuedDecisions) return;
    final targetOperator = widget.targetOperatorId;
    final targetLocation = widget.targetLocationId;
    if (targetOperator == null ||
        targetOperator.isEmpty ||
        targetLocation == null ||
        targetLocation.isEmpty) {
      // Defense-in-depth: the commit button is already disabled when
      // targets are missing (see the build() guard) and the live
      // route in admin_routes.dart leaves the targets null until the
      // operator picker ships. This catch is the last-line guard so
      // any future code path that bypasses the button (programmatic
      // call, hot-reload state mismatch) cannot accidentally commit
      // against a wrong tenant.
      setState(() {
        _actionError =
            'Select an operator before committing graph decisions; the '
            'commit destination is not configured.';
      });
      return;
    }
    setState(() {
      _actionError = null;
      _busy = true;
    });
    try {
      final decisions = <ApprovalDecision>[
        for (final id in _approveQueue)
          ApprovalDecision(candidateId: id, kind: GraphDecisionKind.approve),
        for (final id in _rejectQueue)
          ApprovalDecision(candidateId: id, kind: GraphDecisionKind.reject),
        ..._editQueue.values,
      ];
      final result = await widget.gateway.commitGraphCandidatesBatch(
        BatchCommitCommand(
          idempotencyKey: widget.newIdempotencyKey(),
          targetOperatorId: targetOperator,
          targetLocationId: targetLocation,
          decisions: decisions,
        ),
      );
      if (!mounted) return;
      final approved = result.approvedNodeCount + result.approvedEdgeCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AdminKnowledgeBaseCopy.connectionsSavedToast(
              approved,
              result.rejectedCount,
            ),
          ),
        ),
      );
      setState(() {
        _approveQueue.clear();
        _rejectQueue.clear();
        _editQueue.clear();
      });
      await _refresh();
    } on CorpusAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_corpus_graph_tab_body'),
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(
        key: Key('admin_corpus_graph_candidates_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_corpus_graph_candidates_error'),
        message: _loadError!,
      );
    }
    final diff = _diff;
    if (diff == null) return const SizedBox.shrink();
    // C2: the redesigned Connections view lives in a sibling library so
    // it never reaches into this screen's private widgets. The screen
    // owns every gateway call + idempotency key and computes
    // `showTechDetails` from the existing [_CorpusTechDetailsScope] (set
    // by the screen-level "Show technical details" toggle), passing it
    // down as a plain bool. A stray action error (e.g. a failed commit)
    // still renders above the view.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_actionError != null)
          _ErrorBanner(
            key: const Key('admin_corpus_graph_candidates_action_error'),
            message: _actionError!,
          ),
        Expanded(
          child: CorpusConnectionsView(
            diff: diff,
            editingEnabled: widget.editingEnabled,
            showTechDetails: _CorpusTechDetailsScope.of(context),
            busy: _busy,
            // The knowledge documents are global, so the scope control
            // lives here on the Connections tab (not the Knowledge tab):
            // approving a connection is the only write that targets a
            // specific business + location. Saving stays disabled until a
            // target is set, so a click cannot write against the wrong
            // tenant (HP #4). The demo/test path supplies a default
            // target; the live path leaves it null until the admin picks.
            canSave: widget.hasTarget,
            scopeLabel: widget.targetLabel,
            onChangeScope: widget.onPickOperator,
            pendingCount: _pendingCount,
            queuedDecisionFor: _queuedDecisionFor,
            onApprove: _toggleApprove,
            onReject: _toggleReject,
            onEdit: _onEditPressed,
            onBulkApprove: _bulkApproveClear,
            onSave: _onCommitBatch,
            onStartOver: _discardQueue,
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    // B-r1: frames the screen around what the advisor knows, with a
    // "Staff only" badge in the trailing action slot. Copy lives in
    // [AdminKnowledgeBaseCopy] (plain English, no em dash). The nav
    // label stays "Knowledge base" in admin_routes.dart.
    return const OperatorWebScreenHeader(
      icon: Icons.menu_book_outlined,
      title: AdminKnowledgeBaseCopy.title,
      subtitle: AdminKnowledgeBaseCopy.subtitle,
      actions: <Widget>[_StaffOnlyBadge()],
    );
  }
}

/// B-r1: trailing header badge that marks the whole screen as internal
/// F and F staff only. Reuses the peacock accent + the shared chip
/// decoration token so it tracks the theme rather than inlining hex.
class _StaffOnlyBadge extends StatelessWidget {
  const _StaffOnlyBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_corpus_staff_only_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: AppDecoration.accentChip(AppColors.peacock),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.shield_outlined,
            size: 14,
            color: AppColors.peacockDark,
          ),
          const SizedBox(width: 6),
          Text(
            AdminKnowledgeBaseCopy.staffOnlyBadge,
            style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
          ),
        ],
      ),
    );
  }
}

/// B-r1: screen-level "Show technical details" toggle. OFF by default.
/// Mirrors the approved preview's `techToggle`. Flipping it broadcasts
/// the new value through [_CorpusTechDetailsScope] to every card.
class _TechDetailsToggle extends StatelessWidget {
  const _TechDetailsToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: AdminKnowledgeBaseCopy.showTechnicalDetailsHint,
      child: InkWell(
        key: const Key('admin_corpus_tech_details_toggle'),
        borderRadius: BorderRadius.circular(AppRadius.small),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Switch(value: value, onChanged: onChanged),
              const SizedBox(width: 8),
              // Let the label shrink rather than overflow: this toggle sits
              // in OperatorWebScreenFrame's capped content width, and the
              // admin console clamps OS text scaling up to a 1.12 floor.
              // Without Flexible the Row runs a few px past its bounds in the
              // narrower scoped-workspace function pane.
              Flexible(
                child: Text(
                  AdminKnowledgeBaseCopy.showTechnicalDetails,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        icon: Icons.lock_outline,
        message: AdminKnowledgeBaseCopy.readOnlyBanner,
      ),
    );
  }
}

/// B-r1: broadcasts the screen-level "Show technical details" state to
/// descendant cards without threading a constructor parameter through
/// every widget. [_AdvancedDetails] and [_ConfidenceChip] read this; a
/// false default (no scope) keeps machine details hidden.
class _CorpusTechDetailsScope extends InheritedWidget {
  const _CorpusTechDetailsScope({
    required this.showTechDetails,
    required super.child,
  });

  final bool showTechDetails;

  static bool of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_CorpusTechDetailsScope>();
    return scope?.showTechDetails ?? false;
  }

  @override
  bool updateShouldNotify(_CorpusTechDetailsScope oldWidget) =>
      showTechDetails != oldWidget.showTechDetails;
}

class _ChunkPreviewTile extends StatelessWidget {
  const _ChunkPreviewTile({super.key, required this.chunk});

  final ChunkPreview chunk;

  @override
  Widget build(BuildContext context) {
    // B-r2: each content piece reads as a "topic" in the preview shape:
    // a tinted kind icon, the topic name + a plain-English kind line,
    // then a kind pill. The kind is DERIVED from the text the chunk
    // already carries (rich kinds land in slice C3); when nothing is
    // clear it reads "Document". Nothing here fabricates data.
    final kind = corpusTopicKindForChunk(chunk);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Topic header row: kind icon · name + kind line · kind pill.
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              TopicKindIcon(kind: kind),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _chunkTitle(chunk),
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      kind.description,
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TopicKindPill(kind: kind),
            ],
          ),
          // Full heading breadcrumb (kept for sections nested under an
          // H1) below the header so it does not crowd the topic name.
          if (chunk.headingPath.length > 1) ...[
            const SizedBox(height: 4),
            Text(
              chunk.headingPath.join(' › '),
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            chunk.snippet,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          // B-r-polish: the machine-flavored "words of context" measure,
          // content ID, source file, risk level, and hash now ALL sit
          // behind the "Show technical details" toggle (OFF by default),
          // so the everyday topic row stays calm. The disclosure renders
          // nothing while the toggle is off.
          _AdvancedDetails(
            keyName: 'admin_corpus_chunk_details_${chunk.chunkId}',
            title: 'Technical details',
            children: <Widget>[
              _DetailRow(
                label: 'Words of context',
                value: 'About ${chunk.estimatedTokens}',
              ),
              _DetailRow(label: 'Content ID', value: chunk.chunkId),
              _DetailRow(label: 'Source file', value: chunk.sourcePath),
              _DetailRow(label: 'Risk level', value: chunk.riskLevel),
              _DetailRow(
                label: 'Source hash',
                value: chunk.contentSha256.substring(
                  0,
                  math.min(12, chunk.contentSha256.length),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _chunkTitle(ChunkPreview chunk) {
  if (chunk.headingPath.isNotEmpty) return chunk.headingPath.last;
  final doc = chunk.docId.trim();
  if (doc.isNotEmpty) return 'Knowledge content';
  return 'Content piece';
}

class _AdvancedDetails extends StatelessWidget {
  const _AdvancedDetails({
    required this.keyName,
    required this.title,
    required this.children,
  });

  final String keyName;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    // B-r1: the per-card technical-details disclosure only renders when
    // the screen-level "Show technical details" toggle is ON. OFF (the
    // default) hides raw IDs, content hashes, and version IDs from the
    // card entirely, matching the approved preview. The data stays
    // available; this only controls visibility.
    if (!_CorpusTechDetailsScope.of(context)) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          key: Key(keyName),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
          leading: const Icon(
            Icons.info_outline,
            size: 14,
            color: AppColors.textMuted,
          ),
          title: Text(
            title,
            style: AppTextStyles.mono8(
              color: AppColors.textMuted,
            ).copyWith(fontWeight: FontWeight.w700),
          ),
          children: children,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono14(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        message: message,
        tone: OperatorWebBannerTone.error,
      ),
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_corpus_confirm_dialog'),
      title: title,
      onClose: () => Navigator.of(context).pop(false),
      actions: <Widget>[
        AdminActionButton(
          key: const Key('admin_corpus_confirm_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(false),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_corpus_confirm_ok'),
          label: confirmLabel,
          onPressed: () => Navigator.of(context).pop(true),
          role: AdminActionRole.primary,
        ),
      ],
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}

String _shortVersion(String versionId) {
  if (versionId.length <= 8) return versionId;
  return versionId.substring(0, 8);
}

/// Default upload picker used when the screen is dropped into the
/// admin shell without a custom picker. Pops a dialog letting the
/// admin paste markdown into a text field; this keeps the launch
/// click path working in `kDemoMode` even before 11A.3b wires the
/// platform file picker.
Future<UploadCommand?> _defaultDemoPicker(BuildContext context) async {
  final controller = TextEditingController(
    text:
        '# Forge & Flow Methodology\n\n'
        '## Cycles\n\n'
        'Sixty-day target cycles lock standards. Weekly plan snapshots '
        'compare actuals against the locked target.\n\n'
        '## Daypart\n\n'
        'Daypart guidance lives alongside whole-day truth.\n\n'
        '## Operator review\n\n'
        'Operators should review advisor content changes before publishing.\n',
  );
  final fileNameController = TextEditingController(text: 'methodology_seed.md');
  final result = await showDialog<UploadCommand>(
    context: context,
    builder: (dialogContext) {
      return OperatorWebDialog(
        key: const Key('admin_corpus_demo_picker_dialog'),
        title: 'Demo upload',
        maxWidth: 520,
        actions: <Widget>[
          AdminActionButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(dialogContext).pop(),
            role: AdminActionRole.quiet,
          ),
          AdminActionButton(
            key: const Key('admin_corpus_demo_picker_submit'),
            label: 'Preview upload',
            onPressed: () {
              final fileName = fileNameController.text.trim();
              final body = controller.text;
              if (body.isEmpty) {
                Navigator.of(dialogContext).pop();
                return;
              }
              Navigator.of(dialogContext).pop(
                UploadCommand(
                  fileName: fileName.isEmpty ? 'methodology_seed.md' : fileName,
                  contentType: 'text/markdown',
                  bytes: Uint8List.fromList(body.codeUnits),
                  idempotencyKey:
                      'demo-upload-${DateTime.now().microsecondsSinceEpoch}',
                ),
              );
            },
            role: AdminActionRole.primary,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('admin_corpus_demo_picker_filename'),
              controller: fileNameController,
              decoration: const InputDecoration(labelText: 'File name'),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 260,
              child: TextField(
                key: const Key('admin_corpus_demo_picker_body'),
                controller: controller,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  labelText: 'Markdown content',
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  return result;
}
