// B-r3 — Add-knowledge + Update-history presentation for the admin
// Knowledge tab.
//
// Two backend-backed cards, extracted from corpus_admin_screen.dart to
// keep that file under the operator_web_size_lint frozen ceiling (see
// tool/operator_web_size_lint.dart):
//
//   * [CorpusAddKnowledgeCard] — a dropzone the operator drops a
//     document on (reusing B1's [CorpusUploadDropZone] + the
//     [pickCorpusFile] seam) plus a "What this update changes" preview
//     rendered from the [CorpusDiff] the proxy returned. "Save this
//     update" commits; "Cancel" discards. Edit-only: the read-only
//     ff_support walkthrough never sees the dropzone or the buttons.
//
//   * [CorpusUpdateHistoryCard] — a current-first timeline of every
//     saved version. The current version (`supersededAt == null`) gets
//     an "In use now" badge; prior versions get an edit-only "Go back
//     to this version" button that writes a NEW version (the ledger is
//     append-only) behind a confirm dialog.
//
// Both cards are pure presentation over the screen's existing gateway
// calls (previewDiff / commitVersion / rollbackToVersion). They never
// reach the gateway themselves — the parent screen owns the async work
// and the idempotency keys; these widgets only render + raise callbacks.
//
// Reuse, not duplication:
//   * B-r2's [TopicKindIcon] / [corpusTopicKindForChunk] derive the kind
//     icon + plain-English line for each changed piece. No kind is
//     fabricated (rich-kind extraction is the later C3 slice).
//   * B1's [CorpusUploadDropZone] handles the web drag-drop seam.
//   * [AdminKnowledgeBaseCopy] holds every operator-facing string
//     (no em dash; plain English that reads as training).

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import '../services/corpus_file_picker.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/corpus_upload_drop_zone.dart';
import 'corpus_admin_chunk_view.dart';

// kDemoMode carve-out: the Add-knowledge card renders a "Use a sample
// file" button when running in demo mode so the walkthrough click-path
// works without a real file on disk. Mirrors the existing
// corpus_upload_dialog.dart carve-out documented in CLAUDE.md "Demo Mode".
const bool _kDemoMode = bool.fromEnvironment('kDemoMode');

/// Builds an [UploadCommand] from a freshly-picked file, repeating the
/// same content-type mapping + idempotency shape B1's upload dialog uses.
UploadCommand _commandFromPicked(PickedCorpusFile file) {
  final lower = file.filename.toLowerCase();
  final contentType = lower.endsWith('.txt') ? 'text/plain' : 'text/markdown';
  return UploadCommand(
    fileName: file.filename,
    contentType: contentType,
    bytes: file.bytes,
    idempotencyKey: 'corpus-upload-${DateTime.now().microsecondsSinceEpoch}',
  );
}

/// Synthetic sample upload for the demo walkthrough. Body matches the
/// upload dialog's sample so both entry points stage the same content.
UploadCommand _sampleUploadCommand() {
  const body =
      '# Forge & Flow Methodology\n\n'
      '## Cycles\n\n'
      'Sixty-day target cycles lock standards. Weekly plan snapshots '
      'compare actuals against the locked target.\n\n'
      '## Daypart\n\n'
      'Daypart guidance lives alongside whole-day truth.\n\n'
      '## Operator review\n\n'
      'Operators should review advisor content changes before publishing.\n';
  return UploadCommand(
    fileName: 'methodology_seed.md',
    contentType: 'text/markdown',
    bytes: Uint8List.fromList(body.codeUnits),
    idempotencyKey: 'corpus-sample-${DateTime.now().microsecondsSinceEpoch}',
  );
}

/// The "Add knowledge" card. Renders a dropzone (edit-only) and, once a
/// file has been staged, the "What this update changes" preview built
/// from [stagedDiff].
class CorpusAddKnowledgeCard extends StatelessWidget {
  const CorpusAddKnowledgeCard({
    super.key,
    required this.editingEnabled,
    required this.busy,
    required this.stagedDiff,
    required this.stagedFileName,
    required this.onChooseFile,
    required this.onUploadCommand,
    required this.onSave,
    required this.onCancel,
  });

  final bool editingEnabled;
  final bool busy;

  /// The diff the proxy returned for the staged upload, or null when no
  /// file is staged yet.
  final CorpusDiff? stagedDiff;
  final String? stagedFileName;

  /// Opens the host-supplied picker (a dialog in production, an injected
  /// stub in tests). Used by the "Choose a file" button.
  final VoidCallback onChooseFile;

  /// Raised when a file is dropped onto the dropzone (web drag-drop).
  /// The parent runs previewDiff against it, exactly like onChooseFile.
  final ValueChanged<UploadCommand> onUploadCommand;

  /// Commits the staged upload as a new version.
  final VoidCallback onSave;

  /// Discards the staged upload without committing.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final diff = stagedDiff;
    return OperatorWebPanel(
      key: const Key('admin_corpus_add_knowledge_card'),
      title: AdminKnowledgeBaseCopy.addTitle,
      subtitle: AdminKnowledgeBaseCopy.addLead,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (editingEnabled) ...<Widget>[
            _DropZone(
              busy: busy,
              onUploadCommand: onUploadCommand,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                AdminActionButton(
                  key: const Key('admin_corpus_add_choose_file'),
                  label: AdminKnowledgeBaseCopy.addChooseFile,
                  onPressed: busy ? null : onChooseFile,
                  icon: Icons.attach_file_outlined,
                ),
                if (_kDemoMode)
                  AdminActionButton(
                    // kDemoMode carve-out: visible only in demo mode.
                    key: const Key('admin_corpus_add_use_sample'),
                    label: AdminKnowledgeBaseCopy.addUseSample,
                    onPressed: busy
                        ? null
                        : () => onUploadCommand(_sampleUploadCommand()),
                    icon: Icons.science_outlined,
                  ),
              ],
            ),
          ],
          if (diff != null) ...<Widget>[
            const SizedBox(height: 18),
            _ChangePreview(
              diff: diff,
              fileName: stagedFileName,
              editingEnabled: editingEnabled,
              busy: busy,
              onSave: onSave,
              onCancel: onCancel,
            ),
          ],
        ],
      ),
    );
  }
}

/// The inline dropzone. Wraps B1's [CorpusUploadDropZone] (which owns the
/// web drag-event seam) with the preview's prompt copy. Validates size +
/// extension client-side before raising [onUploadCommand]; the proxy
/// repeats the checks server-side.
class _DropZone extends StatefulWidget {
  const _DropZone({required this.busy, required this.onUploadCommand});

  final bool busy;
  final ValueChanged<UploadCommand> onUploadCommand;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  String? _error;

  void _handleDropped(PickedCorpusFile file) {
    if (widget.busy) return;
    final error = _validate(file);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _error = null);
    widget.onUploadCommand(_commandFromPicked(file));
  }

  /// Client-side guardrails mirroring corpus_upload_dialog.dart so a
  /// drag-drop gets the same clean banner the dialog gives.
  String? _validate(PickedCorpusFile file) {
    if (file.bytes.length > kCorpusUploadMaxBytes) {
      final kb = (file.bytes.length / 1024).toStringAsFixed(0);
      return 'That file is too large. The limit is 1 MB. This one is '
          '$kb KB.';
    }
    final lower = file.filename.toLowerCase();
    final ok =
        lower.endsWith('.md') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.doc') ||
        lower.endsWith('.docx');
    if (!ok) {
      return 'That file type is not supported. Choose a Word, text, or '
          'markdown document and try again.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // The B1 dropzone renders the drop target + web drag-event seam.
        // We sit our preview-styled prompt on top by passing a null
        // pickedFile (it only drives the dropzone's own internal visual);
        // the prompt copy below the icon comes from the shared widget.
        CorpusUploadDropZone(
          key: const Key('admin_corpus_add_drop_zone'),
          pickedFile: null,
          onFilePicked: _handleDropped,
        ),
        if (_error != null) ...<Widget>[
          const SizedBox(height: 10),
          OperatorWebBanner(
            key: const Key('admin_corpus_add_error'),
            message: _error!,
            tone: OperatorWebBannerTone.error,
          ),
        ],
      ],
    );
  }
}

/// "What this update changes": one row per added / modified piece, each
/// with B-r2's kind icon and a plain-English line, then Save / Cancel.
class _ChangePreview extends StatelessWidget {
  const _ChangePreview({
    required this.diff,
    required this.fileName,
    required this.editingEnabled,
    required this.busy,
    required this.onSave,
    required this.onCancel,
  });

  final CorpusDiff diff;
  final String? fileName;
  final bool editingEnabled;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final hasChanges = diff.added.isNotEmpty || diff.modified.isNotEmpty;
    return Container(
      key: const Key('admin_corpus_change_preview'),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            AdminKnowledgeBaseCopy.addChangeTitle,
            style: AppTextStyles.body14(color: AppColors.textPrimary),
          ),
          if (fileName != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              fileName!,
              key: const Key('admin_corpus_change_filename'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
          const SizedBox(height: 12),
          if (!hasChanges)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                AdminKnowledgeBaseCopy.addNoChanges,
                key: const Key('admin_corpus_change_none'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            )
          else ...<Widget>[
            for (final chunk in diff.added)
              _ChangeRow(
                key: Key('admin_corpus_change_added_${chunk.chunkId}'),
                chunk: chunk,
                line: AdminKnowledgeBaseCopy.addAddedLine(
                  corpusTopicKindForChunk(chunk),
                ),
                badge: _ChangeBadge.added,
              ),
            for (final chunk in diff.modified)
              _ChangeRow(
                key: Key('admin_corpus_change_modified_${chunk.chunkId}'),
                chunk: chunk,
                line: AdminKnowledgeBaseCopy.addModifiedLine,
                badge: _ChangeBadge.modified,
              ),
          ],
          if (editingEnabled) ...<Widget>[
            const SizedBox(height: 16),
            AdminActionBar(
              alignment: WrapAlignment.start,
              children: <Widget>[
                AdminActionButton(
                  key: const Key('admin_corpus_save_update_button'),
                  label: AdminKnowledgeBaseCopy.addSaveUpdate,
                  // No-op when there is nothing to save: a document that
                  // matches the current corpus has no diff to commit.
                  onPressed: (busy || !hasChanges) ? null : onSave,
                  role: AdminActionRole.primary,
                ),
                AdminActionButton(
                  key: const Key('admin_corpus_cancel_update_button'),
                  label: AdminKnowledgeBaseCopy.addCancel,
                  onPressed: busy ? null : onCancel,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Whether a changed piece is new or reworded. Drives the row's small
/// trailing word so the operator can scan added vs changed at a glance.
enum _ChangeBadge { added, modified }

/// One row in the "What this update changes" list: kind icon + name +
/// plain-English line, with a small trailing "New" / "Updated" word.
class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    super.key,
    required this.chunk,
    required this.line,
    required this.badge,
  });

  final ChunkPreview chunk;
  final String line;
  final _ChangeBadge badge;

  @override
  Widget build(BuildContext context) {
    final kind = corpusTopicKindForChunk(chunk);
    final name = chunk.headingPath.isNotEmpty
        ? chunk.headingPath.last
        : chunk.sourcePath;
    final isAdded = badge == _ChangeBadge.added;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          TopicKindIcon(kind: kind),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  name,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  line,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _MiniTag(
            label: isAdded ? 'New' : 'Updated',
            color: isAdded ? AppColors.positive : AppColors.sunsetDark,
          ),
        ],
      ),
    );
  }
}

/// A small rounded word-tag ("New" / "Updated"). Tinted from the shared
/// palette, no new colors.
class _MiniTag extends StatelessWidget {
  const _MiniTag({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(label, style: AppTextStyles.chipLabel(color: color)),
    );
  }
}

/// The "Update history" card: a current-first timeline of every saved
/// version. Rollback is edit-only and writes a NEW version.
class CorpusUpdateHistoryCard extends StatelessWidget {
  const CorpusUpdateHistoryCard({
    super.key,
    required this.versions,
    required this.editingEnabled,
    required this.busy,
    required this.onGoBack,
  });

  /// Current-first list of every saved version (the gateway already
  /// sorts current-first, prior-by-recency).
  final List<CorpusVersionRef> versions;
  final bool editingEnabled;
  final bool busy;

  /// Raised when the operator confirms "go back to this version".
  final ValueChanged<CorpusVersionRef> onGoBack;

  @override
  Widget build(BuildContext context) {
    // "No earlier versions yet" only when the current version is the
    // sole entry; the current row always renders when any version exists.
    final hasPrior = versions.where((v) => !v.isCurrent).isNotEmpty;
    return OperatorWebPanel(
      key: const Key('admin_corpus_history_card'),
      title: AdminKnowledgeBaseCopy.historyTitle,
      subtitle: AdminKnowledgeBaseCopy.historyLead,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final v in versions)
            _HistoryRow(
              key: Key('admin_corpus_history_row_${v.versionId}'),
              version: v,
              editingEnabled: editingEnabled,
              busy: busy,
              onGoBack: () => onGoBack(v),
            ),
          if (!hasPrior)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                AdminKnowledgeBaseCopy.historyNoPrior,
                key: const Key('admin_corpus_history_empty'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// One timeline row. Current version gets a colored dot + "In use now"
/// badge; prior versions get a muted dot + an edit-only "Go back to this
/// version" button.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    super.key,
    required this.version,
    required this.editingEnabled,
    required this.busy,
    required this.onGoBack,
  });

  final CorpusVersionRef version;
  final bool editingEnabled;
  final bool busy;
  final VoidCallback onGoBack;

  @override
  Widget build(BuildContext context) {
    final isCurrent = version.isCurrent;
    final title = version.summary.trim().isEmpty
        ? 'Saved a new version'
        : version.summary.trim();
    final byline =
        '${adminHumanDateTime(version.createdAt)} '
        ': ${AdminKnowledgeBaseCopy.historyByStaff}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // Timeline dot.
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 12),
            child: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isCurrent ? AppColors.positive : AppColors.borderSubtle,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        title,
                        style: AppTextStyles.body14(color: AppColors.textPrimary),
                      ),
                    ),
                    if (isCurrent) ...<Widget>[
                      const SizedBox(width: 8),
                      _InUseNowBadge(
                        key: Key(
                          'admin_corpus_history_in_use_${version.versionId}',
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  byline,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  AdminKnowledgeBaseCopy.historyPieceCount(version.chunkCount),
                  style: AppTextStyles.body11(color: AppColors.textMuted),
                ),
                if (version.rollbackOf != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    AdminKnowledgeBaseCopy.historyRestoredNote,
                    style: AppTextStyles.body11(color: AppColors.textMuted),
                  ),
                ],
                if (editingEnabled && !isCurrent) ...<Widget>[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: AdminActionButton(
                      key: Key(
                        'admin_corpus_go_back_${version.versionId}',
                      ),
                      label: AdminKnowledgeBaseCopy.historyGoBack,
                      onPressed: busy ? null : onGoBack,
                      icon: Icons.history_outlined,
                      compact: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The "In use now" badge on the current version row.
class _InUseNowBadge extends StatelessWidget {
  const _InUseNowBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        AdminKnowledgeBaseCopy.historyInUseNow,
        style: AppTextStyles.chipLabel(color: AppColors.positive),
      ),
    );
  }
}
