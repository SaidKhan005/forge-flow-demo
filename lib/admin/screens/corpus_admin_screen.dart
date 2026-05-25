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

import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import '../services/corpus_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/admin_responsive_layout.dart';
import 'corpus_admin_chunk_view.dart';
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
    }, successHint: 'Advisor content published.');
  }

  Future<void> _onPickOperatorPressed() async {
    final opener = widget.operatorPickerOpener;
    if (opener == null) return;
    final result = await opener(context);
    if (result == null || !mounted) return;
    setState(() {
      _pickedOperatorId = result.operatorId;
      _pickedLocationId = result.locationId;
      _pickedTargetLabel =
          '${result.operatorBusinessName} - ${result.locationName}';
    });
  }

  Future<void> _onRollbackPressed(CorpusVersionRef target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Restore this version?',
        message:
            'Makes this version current again. The previous version stays '
            'in history, so past advisor recommendations can still be traced.',
        confirmLabel: 'Restore',
      ),
    );
    if (confirmed != true) return;
    await _runAndRefresh(() async {
      await widget.gateway.rollbackToVersion(
        RollbackCommand(
          targetVersionId: target.versionId,
          summary: 'Restored ${_shortVersion(target.versionId)}',
          idempotencyKey: _newIdempotencyKey(),
        ),
      );
    }, successHint: 'Advisor content restored.');
  }

  CorpusVersionRef? get _selected {
    final id = _selectedVersionId;
    if (id == null) return null;
    for (final v in _versions) {
      if (v.versionId == id) return v;
    }
    return null;
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
                        selectedVersionId: _selectedVersionId,
                        selectedBundle: _selectedBundle,
                        stagedDiff: _stagedDiff,
                        stagedFileName: _stagedFileName,
                        editingEnabled: widget.editingEnabled,
                        busy: _busy,
                        selected: _selected,
                        onSelect: (id) {
                          setState(() => _selectedVersionId = id);
                          _loadSelectedBundle();
                        },
                        onUploadPressed: _onUploadPressed,
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
                          pickedTargetLabel: _pickedTargetLabel,
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

class _VersionsTab extends StatelessWidget {
  const _VersionsTab({
    required this.loading,
    required this.loadError,
    required this.versions,
    required this.selectedVersionId,
    required this.selectedBundle,
    required this.stagedDiff,
    required this.stagedFileName,
    required this.editingEnabled,
    required this.busy,
    required this.selected,
    required this.onSelect,
    required this.onUploadPressed,
    required this.onRollbackPressed,
    required this.onCommitPressed,
    required this.onDiscardStaged,
  });

  final bool loading;
  final String? loadError;
  final List<CorpusVersionRef> versions;
  final String? selectedVersionId;
  final CorpusBundle? selectedBundle;
  final CorpusDiff? stagedDiff;
  final String? stagedFileName;
  final bool editingEnabled;
  final bool busy;
  final CorpusVersionRef? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onUploadPressed;
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
    if (versions.isEmpty) {
      return Center(
        key: const Key('admin_corpus_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No advisor content yet',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Upload a document to create the first set of knowledge the advisor can use.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                if (editingEnabled) ...[
                  const SizedBox(height: 16),
                  AdminActionButton(
                    key: const Key('admin_corpus_first_upload_button'),
                    label: 'Upload a document',
                    onPressed: busy ? null : onUploadPressed,
                    icon: Icons.upload_file_outlined,
                    role: AdminActionRole.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return AdminMasterDetailLayout(
      masterWidth: 320,
      compactMasterHeight: 260,
      master: _VersionList(
        versions: versions,
        selectedVersionId: selectedVersionId,
        editingEnabled: editingEnabled,
        busy: busy,
        onSelect: onSelect,
        onUploadPressed: onUploadPressed,
        onRollbackPressed: onRollbackPressed,
      ),
      detail: selected == null
          ? const SizedBox.shrink()
          : _VersionDetail(
              version: selected!,
              bundle: selectedBundle,
              stagedDiff: stagedDiff,
              stagedFileName: stagedFileName,
              editingEnabled: editingEnabled,
              busy: busy,
              onCommitPressed: onCommitPressed,
              onDiscardStaged: onDiscardStaged,
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
    required this.pickedTargetLabel,
  });

  final CorpusAdminGateway gateway;
  final bool editingEnabled;
  final String Function() newIdempotencyKey;

  /// When either is null the tab still renders the diff but disables
  /// the commit button and asks the admin to choose a location scope.
  final String? targetOperatorId;
  final String? targetLocationId;

  /// Phase 11A.3a follow-up - opens the legacy operator picker when
  /// a standalone host wires it. Shared admin setup hosts leave this
  /// null and rely on the workspace scope pane instead.
  final VoidCallback? onPickOperator;

  /// "Business name - Location name" for the actively-picked target,
  /// when the admin resolved it through the picker this session.
  /// Null when no pick has occurred yet (or the target came from a
  /// host-supplied default).
  final String? pickedTargetLabel;

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
  AgeRebuildResult? _ageRebuildBanner;
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

  bool _isQueued(String candidateId) {
    return _approveQueue.contains(candidateId) ||
        _rejectQueue.contains(candidateId) ||
        _editQueue.containsKey(candidateId);
  }

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

  void _bulkApproveExtracted() {
    final diff = _diff;
    if (diff == null) return;
    setState(() {
      for (final c in diff.extracted) {
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

  Future<void> _onEditPressed(GraphCandidate candidate) async {
    final existing = _editQueue[candidate.candidateId];
    final result = await showDialog<ApprovalDecision>(
      context: context,
      builder: (dialogContext) => _GraphCandidateEditDialog(
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
          content: Text('$approved approved, ${result.rejectedCount} rejected'),
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

  Future<void> _onAgeRebuild() async {
    setState(() {
      _actionError = null;
      _busy = true;
    });
    try {
      final result = await widget.gateway.requestAgeRebuild(
        idempotencyKey: widget.newIdempotencyKey(),
      );
      if (!mounted) return;
      setState(() {
        _ageRebuildBanner = result;
      });
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
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.editingEnabled)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'View-only',
                style: AppTextStyles.mono11(color: AppColors.textSecondary),
              ),
            ),
          if (_actionError != null)
            _ErrorBanner(
              key: const Key('admin_corpus_graph_candidates_action_error'),
              message: _actionError!,
            ),
          if (_ageRebuildBanner != null)
            _AgeRebuildBanner(
              key: const Key('admin_corpus_age_rebuild_banner'),
              result: _ageRebuildBanner!,
            ),
          _GraphCandidateMetaCard(diff: diff),
          const SizedBox(height: 16),
          _GraphCandidateSection(
            sectionKey: const Key('admin_corpus_graph_extracted_section'),
            label: 'Ready to approve',
            description:
                'These were found directly in the content. Approve them when the relationship looks right.',
            candidates: diff.extracted,
            isQueuedForApprove: _approveQueue.contains,
            isQueuedForReject: _rejectQueue.contains,
            isQueuedForEdit: _editQueue.containsKey,
            isQueued: _isQueued,
            editingEnabled: widget.editingEnabled,
            busy: _busy,
            onApprove: _toggleApprove,
            onReject: _toggleReject,
            onEdit: _onEditPressed,
            trailing: widget.editingEnabled && diff.extracted.isNotEmpty
                ? AdminActionButton(
                    key: const Key('admin_corpus_graph_bulk_approve_extracted'),
                    label: 'Bulk approve all',
                    onPressed: _busy ? null : _bulkApproveExtracted,
                    icon: Icons.done_all_outlined,
                    role: AdminActionRole.primary,
                  )
                : null,
          ),
          const SizedBox(height: 16),
          _GraphCandidateSection(
            sectionKey: const Key('admin_corpus_graph_inferred_section'),
            label: 'Review one by one',
            description:
                'These are suggestions. Approve, edit, or reject each one before it goes live.',
            candidates: diff.inferred,
            isQueuedForApprove: _approveQueue.contains,
            isQueuedForReject: _rejectQueue.contains,
            isQueuedForEdit: _editQueue.containsKey,
            isQueued: _isQueued,
            editingEnabled: widget.editingEnabled,
            busy: _busy,
            onApprove: _toggleApprove,
            onReject: _toggleReject,
            onEdit: _onEditPressed,
          ),
          const SizedBox(height: 16),
          _GraphCandidateSection(
            sectionKey: const Key('admin_corpus_graph_ambiguous_section'),
            label: 'Needs clarification',
            description:
                'These cannot be approved as-is. Edit the relationship or reject it.',
            candidates: diff.ambiguous,
            isQueuedForApprove: _approveQueue.contains,
            isQueuedForReject: _rejectQueue.contains,
            isQueuedForEdit: _editQueue.containsKey,
            isQueued: _isQueued,
            editingEnabled: widget.editingEnabled,
            // Spec line 249: AMBIGUOUS is debug-only until edited.
            // The Approve button is hidden on every row in this
            // section; only Edit + Reject are available.
            allowApprove: false,
            busy: _busy,
            onApprove: _toggleApprove,
            onReject: _toggleReject,
            onEdit: _onEditPressed,
          ),
          const SizedBox(height: 24),
          if (widget.editingEnabled && !widget.hasTarget)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OperatorWebBanner(
                key: const Key('admin_corpus_graph_no_target_banner'),
                tone: OperatorWebBannerTone.warning,
                message: widget.onPickOperator == null
                    ? 'Select a location in the Scope pane before '
                          'applying relationship decisions. This '
                          'keeps approvals attached to the right '
                          'business workspace.'
                    : 'Choose the operator and location before '
                          'applying relationship decisions. This '
                          'keeps approvals attached to the right '
                          'operator workspace for this session.',
                action: widget.onPickOperator == null
                    ? null
                    : AdminActionButton(
                        key: const Key(
                          'admin_corpus_graph_pick_operator_button',
                        ),
                        label: 'Choose operator',
                        onPressed: _busy ? null : widget.onPickOperator,
                        icon: Icons.swap_horiz_outlined,
                        role: AdminActionRole.primary,
                      ),
              ),
            ),
          if (widget.editingEnabled &&
              widget.hasTarget &&
              widget.pickedTargetLabel != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OperatorWebBanner(
                key: const Key('admin_corpus_graph_picked_target_indicator'),
                tone: OperatorWebBannerTone.success,
                message:
                    'Applying decisions to ${widget.pickedTargetLabel} for this '
                    'session.',
              ),
            ),
          if (widget.editingEnabled)
            AdminActionBar(
              alignment: WrapAlignment.start,
              children: <Widget>[
                AdminActionButton(
                  key: const Key('admin_corpus_graph_commit_button'),
                  label:
                      'Apply decisions (${_approveQueue.length + _rejectQueue.length + _editQueue.length} '
                      'decision'
                      '${(_approveQueue.length + _rejectQueue.length + _editQueue.length) == 1 ? '' : 's'})',
                  // Disabled when no decisions are queued, when a
                  // commit is already in flight, OR when the host
                  // (admin_routes.dart) has not picked a target
                  // operator/location for this surface (live mode
                  // pre-operator-picker).
                  onPressed:
                      (!_hasQueuedDecisions || _busy || !widget.hasTarget)
                      ? null
                      : _onCommitBatch,
                  icon: Icons.check_circle_outline,
                  role: AdminActionRole.primary,
                ),
                AdminActionButton(
                  key: const Key('admin_corpus_graph_candidates_discard_queue'),
                  label: 'Clear selections',
                  onPressed: (!_hasQueuedDecisions || _busy)
                      ? null
                      : _discardQueue,
                  icon: Icons.clear,
                ),
                AdminActionButton(
                  key: const Key('admin_corpus_age_rebuild_button'),
                  label: 'Rebuild relationship search',
                  onPressed: _busy ? null : _onAgeRebuild,
                  icon: Icons.refresh_outlined,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _GraphCandidateMetaCard extends StatelessWidget {
  const _GraphCandidateMetaCard({required this.diff});

  final GraphCandidateDiff diff;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      title: 'Connections to review',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(label: 'Total suggestions', value: '${diff.totalCount}'),
          _AdvancedDetails(
            keyName: 'admin_corpus_graph_review_advanced',
            title: 'Technical details',
            children: <Widget>[
              _DetailRow(label: 'Review scope', value: diff.graphScope),
              _DetailRow(label: 'Relationship set', value: diff.graphVersion),
              _DetailRow(label: 'Review engine', value: diff.graphifyVersion),
              if (diff.graphifySourceCommit != null)
                _DetailRow(
                  label: 'Source version',
                  value: diff.graphifySourceCommit!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GraphCandidateSection extends StatelessWidget {
  const _GraphCandidateSection({
    required this.sectionKey,
    required this.label,
    required this.description,
    required this.candidates,
    required this.isQueuedForApprove,
    required this.isQueuedForReject,
    required this.isQueuedForEdit,
    required this.isQueued,
    required this.editingEnabled,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    this.allowApprove = true,
    this.trailing,
  });

  final Key sectionKey;
  final String label;
  final String description;
  final List<GraphCandidate> candidates;
  final bool Function(String candidateId) isQueuedForApprove;
  final bool Function(String candidateId) isQueuedForReject;
  final bool Function(String candidateId) isQueuedForEdit;
  final bool Function(String candidateId) isQueued;
  final bool editingEnabled;
  final bool busy;
  final void Function(GraphCandidate candidate) onApprove;
  final void Function(GraphCandidate candidate) onReject;
  final void Function(GraphCandidate candidate) onEdit;

  /// Spec line 249: AMBIGUOUS relationships are debug-only until
  /// edited. The AMBIGUOUS section passes `allowApprove: false` so
  /// the row never renders an Approve button - only Edit + Reject.
  /// EXTRACTED + INFERRED keep `allowApprove: true`.
  final bool allowApprove;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: sectionKey,
      title: '$label (${candidates.length})',
      subtitle: description,
      trailing: trailing,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'None',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            )
          else
            ...candidates.map(
              (c) => _GraphCandidateRow(
                key: Key('admin_corpus_graph_tile_${c.candidateId}'),
                candidate: c,
                queuedForApprove: isQueuedForApprove(c.candidateId),
                queuedForReject: isQueuedForReject(c.candidateId),
                queuedForEdit: isQueuedForEdit(c.candidateId),
                queued: isQueued(c.candidateId),
                editingEnabled: editingEnabled,
                allowApprove: allowApprove,
                busy: busy,
                onApprove: () => onApprove(c),
                onReject: () => onReject(c),
                onEdit: () => onEdit(c),
              ),
            ),
        ],
      ),
    );
  }
}

class _GraphCandidateRow extends StatelessWidget {
  const _GraphCandidateRow({
    super.key,
    required this.candidate,
    required this.queuedForApprove,
    required this.queuedForReject,
    required this.queuedForEdit,
    required this.queued,
    required this.editingEnabled,
    required this.busy,
    required this.onApprove,
    required this.onReject,
    required this.onEdit,
    this.allowApprove = true,
  });

  final GraphCandidate candidate;
  final bool queuedForApprove;
  final bool queuedForReject;
  final bool queuedForEdit;
  final bool queued;
  final bool editingEnabled;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onEdit;

  /// Spec line 249: AMBIGUOUS rows hide the Approve button. The
  /// admin must Edit (re-classify into a clear approved relation)
  /// or Reject; bare Approve would leak an unedited ambiguous
  /// candidate into canonical storage and then AGE.
  final bool allowApprove;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  candidate.displayLabel,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _TypeChip(label: _friendlyCandidateType(candidate.candidateType)),
              const SizedBox(width: 6),
              _ConfidenceChip(candidate: candidate),
            ],
          ),
          const SizedBox(height: 6),
          if (candidate.kind == GraphCandidateKind.edge)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Relationship between two knowledge items',
                style: AppTextStyles.mono11(color: AppColors.textSecondary),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                'Item type: ${_friendlyCandidateType(candidate.candidateType)}',
                style: AppTextStyles.mono11(color: AppColors.textSecondary),
              ),
            ),
          _GraphCandidateDetails(candidate: candidate),
          if (queued) ...[
            const SizedBox(height: 6),
            _StagedDecisionChip(
              key: Key('admin_corpus_graph_staged_${candidate.candidateId}'),
              label: queuedForApprove
                  ? 'Approve'
                  : queuedForReject
                  ? 'Reject'
                  : 'Edit',
            ),
          ],
          if (editingEnabled) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                if (allowApprove)
                  FilledButton.icon(
                    key: Key(
                      'admin_corpus_graph_candidate_approve_'
                      '${candidate.candidateId}',
                    ),
                    onPressed: busy ? null : onApprove,
                    style: AdminButtonStyles.approval(
                      selected: queuedForApprove,
                    ),
                    icon: Icon(
                      queuedForApprove
                          ? Icons.check_circle_outline
                          : Icons.check_outlined,
                      size: 14,
                    ),
                    label: Text(queuedForApprove ? 'Selected' : 'Approve'),
                  ),
                OutlinedButton.icon(
                  key: Key(
                    'admin_corpus_graph_candidate_reject_'
                    '${candidate.candidateId}',
                  ),
                  onPressed: busy ? null : onReject,
                  style: AdminButtonStyles.reject(selected: queuedForReject),
                  icon: Icon(Icons.close_outlined, size: 14),
                  label: Text(queuedForReject ? 'Selected' : 'Reject'),
                ),
                AdminActionButton(
                  key: Key(
                    'admin_corpus_graph_candidate_edit_'
                    '${candidate.candidateId}',
                  ),
                  label: queuedForEdit ? 'Edit queued' : 'Edit',
                  onPressed: busy ? null : onEdit,
                  icon: Icons.edit_outlined,
                  compact: true,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _GraphCandidateDetails extends StatelessWidget {
  const _GraphCandidateDetails({required this.candidate});

  final GraphCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (candidate.kind == GraphCandidateKind.edge) {
      rows.add(
        _DetailRow(
          label: 'From item',
          value: candidate.fromNodeKey ?? 'Unknown',
        ),
      );
      rows.add(
        _DetailRow(label: 'To item', value: candidate.toNodeKey ?? 'Unknown'),
      );
    }
    if (candidate.sourceFile != null) {
      rows.add(
        _DetailRow(
          label: 'Source file',
          value:
              '${candidate.sourceFile}'
              '${candidate.sourceRef != null ? ' (${candidate.sourceRef})' : ''}',
        ),
      );
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return _AdvancedDetails(
      keyName: 'admin_corpus_graph_candidate_details_${candidate.candidateId}',
      title: 'Technical details',
      children: rows,
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: AppColors.peacockDark),
      ),
    );
  }
}

class _StagedDecisionChip extends StatelessWidget {
  const _StagedDecisionChip({super.key, required this.label});

  /// One of `approve`, `reject`, `edit`.
  final String label;

  @override
  Widget build(BuildContext context) {
    Color bg;
    Color fg;
    switch (label) {
      case 'Approve':
        bg = AppColors.positive.withValues(alpha: 0.15);
        fg = AppColors.positive;
        break;
      case 'Reject':
        bg = AppColors.negative.withValues(alpha: 0.15);
        fg = AppColors.negative;
        break;
      case 'Edit':
      default:
        bg = AppColors.warningBadgeBg;
        fg = AppColors.warning;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Text('Selection: $label', style: AppTextStyles.mono11(color: fg)),
    );
  }
}

class _ConfidenceChip extends StatelessWidget {
  const _ConfidenceChip({required this.candidate});

  final GraphCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final score = candidate.confidenceScore;
    if (score == null) {
      return const SizedBox.shrink();
    }
    final low = candidate.hasLowConfidence;
    final showTech = _CorpusTechDetailsScope.of(context);
    // The low-confidence WARNING is a plain-English clarity signal, so it
    // always shows. The raw numeric score is a machine-flavored detail,
    // appended only when "Show technical details" is ON. A normal
    // (not-low) confidence chip is just a number, so it hides entirely
    // when the toggle is OFF (the default), matching the approved preview.
    if (!low && !showTech) return const SizedBox.shrink();
    final scoreText = score.toStringAsFixed(2);
    final label = low
        ? (showTech ? 'Low confidence ($scoreText)' : 'Low confidence')
        : 'Confidence $scoreText';
    return Container(
      key: low
          ? Key('admin_corpus_graph_candidate_warning_${candidate.candidateId}')
          : Key(
              'admin_corpus_graph_candidate_confidence_${candidate.candidateId}',
            ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: low
            ? AppColors.warningBadgeBg
            : AppColors.positive.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(
          color: low ? AppColors.warning : AppColors.positive,
        ),
      ),
    );
  }
}

class _GraphCandidateEditDialog extends StatefulWidget {
  const _GraphCandidateEditDialog({
    required this.candidate,
    this.initialDecision,
  });

  final GraphCandidate candidate;
  final ApprovalDecision? initialDecision;

  @override
  State<_GraphCandidateEditDialog> createState() =>
      _GraphCandidateEditDialogState();
}

class _GraphCandidateEditDialogState extends State<_GraphCandidateEditDialog> {
  late final TextEditingController _typeController;
  late final TextEditingController _reasonController;

  @override
  void initState() {
    super.initState();
    _typeController = TextEditingController(
      text:
          widget.initialDecision?.editedCandidateType ??
          widget.candidate.candidateType,
    );
    _reasonController = TextEditingController(
      text: widget.initialDecision?.reason ?? '',
    );
  }

  @override
  void dispose() {
    _typeController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_corpus_graph_candidates_edit_dialog'),
      title: 'Edit relationship suggestion',
      maxWidth: 480,
      actions: <Widget>[
        AdminActionButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_corpus_graph_candidates_edit_dialog_submit'),
          label: 'Queue edit',
          onPressed: () {
            final editedType = _typeController.text.trim();
            final reason = _reasonController.text.trim();
            // The proxy's commit-batch validation rejects an edit
            // decision that arrives without an `edited_payload`
            // (`missing_edited_payload` 400). The launch slice does
            // not yet expose a per-property edit form, so we forward
            // the original candidate payload verbatim - the
            // structural change the admin made is only the
            // `edited_candidate_type`. This keeps the wire contract
            // satisfied and lets a follow-up slice add full payload
            // editing without changing the proxy contract.
            Navigator.of(context).pop(
              ApprovalDecision(
                candidateId: widget.candidate.candidateId,
                kind: GraphDecisionKind.edit,
                editedCandidateType: editedType.isEmpty ? null : editedType,
                editedPayload: Map<String, Object?>.from(
                  widget.candidate.payload,
                ),
                reason: reason.isEmpty ? null : reason,
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
          Text(
            widget.candidate.displayLabel,
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w600,
            ),
          ),
          if (widget.candidate.kind == GraphCandidateKind.edge)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${widget.candidate.fromNodeKey ?? '?'} → '
                '${widget.candidate.toNodeKey ?? '?'}',
                style: AppTextStyles.mono11(color: AppColors.textSecondary),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key(
              'admin_corpus_graph_candidates_edit_dialog_type_field',
            ),
            controller: _typeController,
            decoration: InputDecoration(
              labelText: widget.candidate.kind == GraphCandidateKind.node
                  ? 'Item type'
                  : 'Relationship type',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key(
              'admin_corpus_graph_candidates_edit_dialog_reason_field',
            ),
            controller: _reasonController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason (optional)',
              alignLabelWithHint: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgeRebuildBanner extends StatelessWidget {
  const _AgeRebuildBanner({super.key, required this.result});

  final AgeRebuildResult result;

  @override
  Widget build(BuildContext context) {
    final pending = !result.implemented;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: OperatorWebBanner(
        message: result.message,
        tone: pending
            ? OperatorWebBannerTone.warning
            : OperatorWebBannerTone.success,
      ),
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
              Text(
                AdminKnowledgeBaseCopy.showTechnicalDetails,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
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

class _VersionList extends StatelessWidget {
  const _VersionList({
    required this.versions,
    required this.selectedVersionId,
    required this.editingEnabled,
    required this.busy,
    required this.onSelect,
    required this.onUploadPressed,
    required this.onRollbackPressed,
  });

  final List<CorpusVersionRef> versions;
  final String? selectedVersionId;
  final bool editingEnabled;
  final bool busy;
  final ValueChanged<String> onSelect;
  final VoidCallback onUploadPressed;
  final void Function(CorpusVersionRef target) onRollbackPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_corpus_version_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (editingEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: AdminActionButton(
                key: const Key('admin_corpus_upload_button'),
                label: 'Upload a document',
                onPressed: busy ? null : onUploadPressed,
                icon: Icons.upload_file_outlined,
                role: AdminActionRole.primary,
              ),
            ),
          const Divider(height: 1, color: AppColors.borderSubtle),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: versions.length,
              separatorBuilder: (_, __) => Container(
                height: 1,
                color: AppColors.borderSubtle.withValues(alpha: 0.4),
              ),
              itemBuilder: (context, index) {
                final v = versions[index];
                final selected = v.versionId == selectedVersionId;
                return Material(
                  color: selected
                      ? AppColors.sunset.withValues(alpha: 0.10)
                      : Colors.transparent,
                  child: InkWell(
                    key: Key('admin_corpus_row_${v.versionId}'),
                    onTap: () => onSelect(v.versionId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  v.isCurrent
                                      ? 'Current version'
                                      : 'Prior version',
                                  style: AppTextStyles.mono14(
                                    color: AppColors.textPrimary,
                                    weight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (v.isCurrent)
                                _CurrentChip(
                                  key: Key(
                                    'admin_corpus_current_${v.versionId}',
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            v.summary.isEmpty ? 'No summary' : v.summary,
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${v.chunkCount} content piece'
                            '${v.chunkCount == 1 ? '' : 's'} - '
                            'created ${adminHumanDateTime(v.createdAt)}',
                            style: AppTextStyles.mono8(
                              color: AppColors.textMuted,
                            ),
                          ),
                          if (v.rollbackOf != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Restored from an earlier version',
                              style: AppTextStyles.mono8(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                          if (editingEnabled && !v.isCurrent) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: AdminActionButton(
                                key: Key(
                                  'admin_corpus_rollback_${v.versionId}',
                                ),
                                label: 'Restore',
                                onPressed: busy
                                    ? null
                                    : () => onRollbackPressed(v),
                                icon: Icons.history_outlined,
                                compact: true,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _VersionDetail extends StatelessWidget {
  const _VersionDetail({
    required this.version,
    required this.bundle,
    required this.stagedDiff,
    required this.stagedFileName,
    required this.editingEnabled,
    required this.busy,
    required this.onCommitPressed,
    required this.onDiscardStaged,
  });

  final CorpusVersionRef version;
  final CorpusBundle? bundle;
  final CorpusDiff? stagedDiff;
  final String? stagedFileName;
  final bool editingEnabled;
  final bool busy;
  final VoidCallback onCommitPressed;
  final VoidCallback onDiscardStaged;

  @override
  Widget build(BuildContext context) {
    final chunks = bundle?.chunks ?? const <ChunkPreview>[];
    return SingleChildScrollView(
      key: Key('admin_corpus_detail_${version.versionId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OperatorWebPanel(
            title: version.isCurrent
                ? 'Current knowledge'
                : 'Earlier knowledge version',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  label: 'Status',
                  value: version.isCurrent
                      ? 'Live now'
                      : 'Replaced by a newer version',
                ),
                _DetailRow(
                  label: 'Created',
                  value: adminHumanDateTime(version.createdAt),
                ),
                _DetailRow(
                  label: 'Created by',
                  value: version.createdBy ?? 'Unknown',
                ),
                _DetailRow(label: 'Summary', value: version.summary),
                if (version.rollbackOf != null)
                  _DetailRow(
                    label: 'Restored from',
                    value: 'Earlier content version',
                  ),
                _DetailRow(label: 'Content pieces', value: '${chunks.length}'),
                _AdvancedDetails(
                  keyName: 'admin_corpus_version_details_${version.versionId}',
                  title: 'Technical details',
                  children: <Widget>[
                    _DetailRow(label: 'Version ID', value: version.versionId),
                    if (version.rollbackOf != null)
                      _DetailRow(
                        label: 'Restored from ID',
                        value: version.rollbackOf!,
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (stagedDiff != null && editingEnabled) ...[
            _StagedDiffCard(
              diff: stagedDiff!,
              fileName: stagedFileName,
              busy: busy,
              onCommit: onCommitPressed,
              onDiscard: onDiscardStaged,
            ),
            const SizedBox(height: 16),
          ],
          OperatorWebPanel(
            title: 'Content in this version',
            child: ChunkGroupedView(
              key: Key('admin_corpus_grouped_view_${version.versionId}'),
              chunks: chunks,
              sectionTileBuilder: (c) => _ChunkPreviewTile(
                key: Key('admin_corpus_chunk_${c.chunkId}'),
                chunk: c,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StagedDiffCard extends StatelessWidget {
  const _StagedDiffCard({
    required this.diff,
    required this.fileName,
    required this.busy,
    required this.onCommit,
    required this.onDiscard,
  });

  final CorpusDiff diff;
  final String? fileName;
  final bool busy;
  final VoidCallback onCommit;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_corpus_staged_diff'),
      title: 'Upload preview',
      subtitle: diff.summary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (fileName != null)
            _AdvancedDetails(
              keyName: 'admin_corpus_staged_file_details',
              title: 'Technical details',
              children: <Widget>[
                _DetailRow(label: 'Uploaded file', value: fileName!),
              ],
            ),
          const SizedBox(height: 12),
          _DiffSection(
            label: 'New',
            countKey: const Key('admin_corpus_diff_added_count'),
            chunks: diff.added,
            color: AppColors.positive,
            keyPrefix: 'added',
          ),
          _DiffSection(
            label: 'Modified',
            countKey: const Key('admin_corpus_diff_modified_count'),
            chunks: diff.modified,
            color: AppColors.sunset,
            keyPrefix: 'modified',
          ),
          _DiffSection(
            label: 'Archived',
            countKey: const Key('admin_corpus_diff_inactivated_count'),
            chunks: diff.inactivated,
            color: AppColors.negative,
            keyPrefix: 'inactivated',
          ),
          const SizedBox(height: 12),
          AdminActionBar(
            alignment: WrapAlignment.start,
            children: <Widget>[
              AdminActionButton(
                key: const Key('admin_corpus_commit_button'),
                label: 'Publish content',
                onPressed: busy ? null : onCommit,
                role: AdminActionRole.primary,
              ),
              AdminActionButton(
                key: const Key('admin_corpus_discard_button'),
                label: 'Clear preview',
                onPressed: busy ? null : onDiscard,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DiffSection extends StatelessWidget {
  const _DiffSection({
    required this.label,
    required this.countKey,
    required this.chunks,
    required this.color,
    required this.keyPrefix,
  });

  final String label;
  final Key countKey;
  final List<ChunkPreview> chunks;
  final Color color;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${chunks.length}',
                key: countKey,
                style: AppTextStyles.mono14(color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (chunks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'None',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            )
          else
            ...chunks
                .take(6)
                .map(
                  (c) => Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 0, 4),
                    child: _ChunkPreviewTile(
                      key: Key('admin_corpus_diff_${keyPrefix}_${c.chunkId}'),
                      chunk: c,
                    ),
                  ),
                ),
          if (chunks.length > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 0, 0),
              child: Text(
                '+${chunks.length - 6} more',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChunkPreviewTile extends StatelessWidget {
  const _ChunkPreviewTile({super.key, required this.chunk});

  final ChunkPreview chunk;

  @override
  Widget build(BuildContext context) {
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
          Text(
            _chunkTitle(chunk),
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          if (chunk.headingPath.isNotEmpty)
            Text(
              chunk.headingPath.join(' › '),
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          const SizedBox(height: 4),
          Text(
            chunk.snippet,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'About ${chunk.estimatedTokens} words of context',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          _AdvancedDetails(
            keyName: 'admin_corpus_chunk_details_${chunk.chunkId}',
            title: 'Technical details',
            children: <Widget>[
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

class _CurrentChip extends StatelessWidget {
  const _CurrentChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AdminButtonStyles.radius),
      ),
      child: Text(
        'Current',
        style: AppTextStyles.mono8(color: AppColors.positive),
      ),
    );
  }
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
    // The per-card "Technical details" disclosure is itself a
    // progressive-disclosure control (collapsed by default), so it stays
    // available regardless of the screen-level toggle. Reconciling the
    // toggle with the Connections-tab disclosures is C2's scope; B-r1
    // leaves this existing disclosure behavior unchanged.
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

String _friendlyCandidateType(String type) {
  final parts = type
      .replaceAll('_', ' ')
      .trim()
      .split(' ')
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty) return 'Unknown type';
  return parts
      .map((part) => part.substring(0, 1).toUpperCase() + part.substring(1))
      .join(' ');
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
