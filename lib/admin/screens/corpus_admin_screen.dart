// Phase 11A.3a — Corpus admin screen.
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
import '../models/corpus_admin_models.dart';
import '../services/corpus_admin_gateway.dart';

/// Test seam: lets widget tests inject a synthetic upload byte source
/// without driving the platform file picker. Production's
/// drag-and-drop / file picker integration lands in 11A.3b; the
/// launch slice exposes a "Choose demo upload" affordance that returns
/// a fixture markdown body when this picker is left null.
typedef CorpusUploadPicker = Future<UploadCommand?> Function(
  BuildContext context,
);

class CorpusAdminScreen extends StatefulWidget {
  const CorpusAdminScreen({
    super.key,
    required this.gateway,
    this.editingEnabled = true,
    this.uploadPicker,
    this.idempotencyKeyGenerator,
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

  @override
  State<CorpusAdminScreen> createState() => _CorpusAdminScreenState();
}

class _CorpusAdminScreenState extends State<CorpusAdminScreen> {
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
        _selectedVersionId ??=
            versions.isEmpty ? null : versions.first.versionId;
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
        _loadError = 'Could not load corpus data: $error';
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(successHint)),
        );
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
    await _runAndRefresh(
      () async {
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
      },
      successHint: 'Corpus updated.',
    );
  }

  Future<void> _onRollbackPressed(CorpusVersionRef target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Rollback to this version?',
        message:
            'Replaces the active corpus with the chunk set from this '
            'version. A new ledger row will record the rollback. '
            'Existing chunks stay in the ledger so prior advisor '
            'recommendations remain replayable.',
        confirmLabel: 'Rollback',
      ),
    );
    if (confirmed != true) return;
    await _runAndRefresh(
      () async {
        await widget.gateway.rollbackToVersion(
          RollbackCommand(
            targetVersionId: target.versionId,
            summary: 'Rolled back to ${_shortVersion(target.versionId)}',
            idempotencyKey: _newIdempotencyKey(),
          ),
        );
      },
      successHint: 'Corpus rolled back.',
    );
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
    return Container(
      key: const Key('admin_corpus_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Header(),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_corpus_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_corpus_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
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
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_corpus_load_error'),
        message: _loadError!,
      );
    }
    if (_versions.isEmpty) {
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
                  'No corpus versions yet',
                  style: AppTextStyles.display20(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Upload a markdown methodology seed to commit the '
                  'first corpus version.',
                  style: AppTextStyles.body13(
                    color: AppColors.textSecondary,
                  ),
                ),
                if (widget.editingEnabled) ...[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('admin_corpus_first_upload_button'),
                    onPressed: _busy ? null : _onUploadPressed,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunset,
                      foregroundColor: AppColors.backgroundSurface,
                    ),
                    icon: const Icon(Icons.upload_file_outlined, size: 16),
                    label: const Text('Upload markdown'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: _VersionList(
            versions: _versions,
            selectedVersionId: _selectedVersionId,
            editingEnabled: widget.editingEnabled,
            busy: _busy,
            onSelect: (id) {
              setState(() => _selectedVersionId = id);
              _loadSelectedBundle();
            },
            onUploadPressed: _onUploadPressed,
            onRollbackPressed: _onRollbackPressed,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _selected == null
              ? const SizedBox.shrink()
              : _VersionDetail(
                  version: _selected!,
                  bundle: _selectedBundle,
                  stagedDiff: _stagedDiff,
                  stagedFileName: _stagedFileName,
                  editingEnabled: widget.editingEnabled,
                  busy: _busy,
                  onCommitPressed: _onCommitPressed,
                  onDiscardStaged: () => setState(() {
                    _stagedDiff = null;
                    _stagedFileName = null;
                  }),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Corpus',
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Markdown corpus admin. Upload a seed, preview the diff '
          'against the active corpus, commit, or rollback to a prior '
          'version.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline,
            size: 16,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View-only: corpus uploads, commits, and rollbacks '
              'require the super_admin role.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
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
              child: FilledButton.icon(
                key: const Key('admin_corpus_upload_button'),
                onPressed: busy ? null : onUploadPressed,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                ),
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('Upload markdown'),
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
                                  _shortVersion(v.versionId),
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
                            v.summary.isEmpty ? '(no summary)' : v.summary,
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${v.chunkCount} chunk'
                            '${v.chunkCount == 1 ? '' : 's'} · '
                            'created ${_iso(v.createdAt)}',
                            style: AppTextStyles.mono8(
                              color: AppColors.textMuted,
                            ),
                          ),
                          if (v.rollbackOf != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'rollback of ${_shortVersion(v.rollbackOf!)}',
                              style: AppTextStyles.mono8(
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                          if (editingEnabled && !v.isCurrent) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                key: Key(
                                  'admin_corpus_rollback_${v.versionId}',
                                ),
                                onPressed:
                                    busy ? null : () => onRollbackPressed(v),
                                icon: const Icon(
                                  Icons.history_outlined,
                                  size: 14,
                                ),
                                label: const Text('Rollback'),
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
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortVersion(version.versionId),
                  style:
                      AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 10),
                _DetailRow(
                  label: 'Status',
                  value: version.isCurrent ? 'Current' : 'Superseded',
                ),
                _DetailRow(
                  label: 'Created at',
                  value: _iso(version.createdAt),
                ),
                _DetailRow(
                  label: 'Created by',
                  value: version.createdBy ?? '—',
                ),
                _DetailRow(label: 'Summary', value: version.summary),
                if (version.rollbackOf != null)
                  _DetailRow(
                    label: 'Rollback of',
                    value: _shortVersion(version.rollbackOf!),
                  ),
                _DetailRow(
                  label: 'Chunks',
                  value: '${chunks.length}',
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
          _Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chunks in this version',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (chunks.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No chunks loaded yet.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  )
                else
                  ...chunks.map(
                    (c) => _ChunkPreviewTile(
                      key: Key('admin_corpus_chunk_${c.chunkId}'),
                      chunk: c,
                    ),
                  ),
              ],
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
    return _Card(
      key: const Key('admin_corpus_staged_diff'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Staged upload${fileName != null ? ': $fileName' : ''}',
            style: AppTextStyles.mono15(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            diff.summary,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
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
            label: 'Inactivated',
            countKey: const Key('admin_corpus_diff_inactivated_count'),
            chunks: diff.inactivated,
            color: AppColors.negative,
            keyPrefix: 'inactivated',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                key: const Key('admin_corpus_commit_button'),
                onPressed: busy ? null : onCommit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                ),
                child: const Text('Commit'),
              ),
              OutlinedButton(
                key: const Key('admin_corpus_discard_button'),
                onPressed: busy ? null : onDiscard,
                child: const Text('Discard'),
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
                '— none —',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            )
          else
            ...chunks.take(6).map(
                  (c) => Padding(
                    padding: const EdgeInsets.fromLTRB(18, 2, 0, 4),
                    child: _ChunkPreviewTile(
                      key: Key(
                        'admin_corpus_diff_${keyPrefix}_${c.chunkId}',
                      ),
                      chunk: c,
                    ),
                  ),
                ),
          if (chunks.length > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 0, 0),
              child: Text(
                '… +${chunks.length - 6} more',
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
            chunk.chunkId,
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
            'risk ${chunk.riskLevel} · ~${chunk.estimatedTokens} tokens · '
            'sha256 ${chunk.contentSha256.substring(0, math.min(12, chunk.contentSha256.length))}…',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _CurrentChip extends StatelessWidget {
  const _CurrentChip({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'Current',
        style: AppTextStyles.mono8(color: AppColors.positive),
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

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
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
    return AlertDialog(
      key: const Key('admin_corpus_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        title,
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_corpus_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_corpus_confirm_ok'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

String _shortVersion(String versionId) {
  if (versionId.length <= 8) return versionId;
  return versionId.substring(0, 8);
}

String _iso(DateTime when) => when.toUtc().toIso8601String();

/// Default upload picker used when the screen is dropped into the
/// admin shell without a custom picker. Pops a dialog letting the
/// admin paste markdown into a text field; this keeps the launch
/// click path working in `kDemoMode` even before 11A.3b wires the
/// platform file picker.
Future<UploadCommand?> _defaultDemoPicker(BuildContext context) async {
  final controller = TextEditingController(
    text: '# Forge & Flow Methodology\n\n'
        '## Cycles\n\n'
        'Sixty-day target cycles lock standards. Weekly plan snapshots '
        'compare actuals against the locked target.\n\n'
        '## Daypart\n\n'
        'Daypart guidance lives alongside whole-day truth.\n\n'
        '## Operator review\n\n'
        'Operators must review the corpus diff before commit.\n',
  );
  final fileNameController = TextEditingController(
    text: 'methodology_seed.md',
  );
  final result = await showDialog<UploadCommand>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        key: const Key('admin_corpus_demo_picker_dialog'),
        backgroundColor: AppColors.backgroundSurface,
        title: Text(
          'Demo upload',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        content: SizedBox(
          width: 520,
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
              Expanded(
                child: TextField(
                  key: const Key('admin_corpus_demo_picker_body'),
                  controller: controller,
                  maxLines: null,
                  decoration: const InputDecoration(
                    labelText: 'Markdown body',
                    alignLabelWithHint: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('admin_corpus_demo_picker_submit'),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
            ),
            onPressed: () {
              final fileName = fileNameController.text.trim();
              final body = controller.text;
              if (body.isEmpty) {
                Navigator.of(dialogContext).pop();
                return;
              }
              Navigator.of(dialogContext).pop(
                UploadCommand(
                  fileName:
                      fileName.isEmpty ? 'methodology_seed.md' : fileName,
                  contentType: 'text/markdown',
                  bytes: Uint8List.fromList(body.codeUnits),
                  idempotencyKey:
                      'demo-upload-${DateTime.now().microsecondsSinceEpoch}',
                ),
              );
            },
            child: const Text('Stage upload'),
          ),
        ],
      );
    },
  );
  return result;
}
