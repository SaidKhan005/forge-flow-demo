// Advisor Knowledge Activation B1 — Corpus upload dialog.
//
// Shown when the admin clicks "Upload markdown" on the Knowledge Base
// screen. Offers:
//   * A click-to-pick button (browser native file picker via the
//     [corpus_file_picker.dart] / [corpus_file_picker_web.dart] seam).
//   * A drag-and-drop drop zone (web only, dart:html window event
//     listeners attached while the dialog is open).
//   * Client-side content-type and size enforcement
//     ([kCorpusUploadAcceptedContentTypes], [kCorpusUploadMaxBytes]).
//   * A "Use sample file" affordance when [_kDemoMode] is true so the
//     demo click-path runs without a real file on disk.
//
// The dialog resolves to an [UploadCommand] on success or null on cancel.
// Wired by `lib/admin/admin_routes.dart` `_buildCorpus` as the
// [CorpusAdminScreen.uploadPicker].

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../models/corpus_admin_models.dart';
import '../services/corpus_file_picker.dart';
import '../../widgets/console/console_surface.dart';
import 'corpus_upload_drop_zone.dart';

// kDemoMode carve-out: the upload dialog renders a "Use sample file"
// button when running in demo mode so the click-path works without a real
// file on disk. Mirrors the existing login_screen + settings_screen
// carve-outs documented in CLAUDE.md "Demo Mode".
const bool _kDemoMode = bool.fromEnvironment('kDemoMode');

/// Shows the corpus upload dialog and resolves to an [UploadCommand]
/// when the admin picks a valid file, or null when the admin cancels.
///
/// Passed to [CorpusAdminScreen.uploadPicker] by [_buildCorpus].
Future<UploadCommand?> showCorpusUploadDialog(BuildContext context) {
  return showDialog<UploadCommand>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _CorpusUploadDialog(),
  );
}

class _CorpusUploadDialog extends StatefulWidget {
  const _CorpusUploadDialog();

  @override
  State<_CorpusUploadDialog> createState() => _CorpusUploadDialogState();
}

class _CorpusUploadDialogState extends State<_CorpusUploadDialog> {
  PickedCorpusFile? _picked;
  String? _validationError;
  bool _picking = false;

  String _newIdempotencyKey() {
    return 'corpus-upload-${DateTime.now().microsecondsSinceEpoch}';
  }

  /// Client-side validation. Returns the validated file or null (state
  /// updated with the error banner).
  PickedCorpusFile? _validate(PickedCorpusFile file) {
    if (file.bytes.length > kCorpusUploadMaxBytes) {
      setState(() {
        _validationError =
            'File is too large. The limit is 1 MB. '
            'This file is ${(file.bytes.length / 1024).toStringAsFixed(0)} KB.';
        _picked = null;
      });
      return null;
    }
    final lower = file.filename.toLowerCase();
    if (!lower.endsWith('.md') && !lower.endsWith('.txt')) {
      setState(() {
        _validationError =
            'Only .md and .txt files are accepted. '
            'Choose a markdown or plain-text file and try again.';
        _picked = null;
      });
      return null;
    }
    return file;
  }

  Future<void> _handlePick() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _validationError = null;
    });
    try {
      final file = await pickCorpusFile();
      if (!mounted) return;
      if (file == null) {
        setState(() => _picking = false);
        return;
      }
      final valid = _validate(file);
      setState(() {
        _picked = valid;
        _picking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _picking = false;
        _validationError = 'Could not open the file picker: $error';
      });
    }
  }

  void _handleDroppedFile(PickedCorpusFile file) {
    final valid = _validate(file);
    if (valid != null) {
      setState(() {
        _picked = valid;
        _validationError = null;
      });
    }
  }

  void _handleUseSampleFile() {
    // kDemoMode carve-out: synthetic fixture so the demo walkthrough runs
    // without a real file on disk. Seed body matches _defaultDemoPicker
    // in corpus_admin_screen.dart.
    const body =
        '# Forge & Flow Methodology\n\n'
        '## Cycles\n\n'
        'Sixty-day target cycles lock standards. Weekly plan snapshots '
        'compare actuals against the locked target.\n\n'
        '## Daypart\n\n'
        'Daypart guidance lives alongside whole-day truth.\n\n'
        '## Operator review\n\n'
        'Operators should review advisor content changes before publishing.\n';
    setState(() {
      _picked = PickedCorpusFile(
        bytes: Uint8List.fromList(body.codeUnits),
        filename: 'methodology_seed.md',
      );
      _validationError = null;
    });
  }

  UploadCommand _buildCommand(PickedCorpusFile file) {
    final lower = file.filename.toLowerCase();
    final contentType = lower.endsWith('.txt') ? 'text/plain' : 'text/markdown';
    return UploadCommand(
      fileName: file.filename,
      contentType: contentType,
      bytes: file.bytes,
      idempotencyKey: _newIdempotencyKey(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    return OperatorWebDialog(
      key: const Key('admin_corpus_upload_dialog'),
      title: 'Upload advisor content',
      maxWidth: 480,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_corpus_upload_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_corpus_upload_dialog_submit'),
          style: AdminButtonStyles.primary,
          onPressed: picked == null
              ? null
              : () => Navigator.of(context).pop(_buildCommand(picked)),
          child: const Text('Preview upload'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose a markdown (.md) or plain-text (.txt) file. '
            'Maximum size: 1 MB.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          CorpusUploadDropZone(
            pickedFile: picked,
            onFilePicked: _handleDroppedFile,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('admin_corpus_upload_dialog_pick'),
                onPressed: _picking ? null : _handlePick,
                icon: const Icon(Icons.attach_file_outlined, size: 16),
                label: Text(
                  picked == null ? 'Choose file' : 'Choose another file',
                ),
              ),
              if (_kDemoMode)
                OutlinedButton.icon(
                  // kDemoMode carve-out: visible only in demo mode.
                  key: const Key('admin_corpus_upload_dialog_sample'),
                  onPressed: _handleUseSampleFile,
                  icon: const Icon(Icons.science_outlined, size: 16),
                  label: const Text('Use sample file'),
                ),
            ],
          ),
          if (picked != null) ...[
            const SizedBox(height: 12),
            _PickedFileTile(
              key: const Key('admin_corpus_upload_dialog_picked_tile'),
              file: picked,
            ),
          ],
          if (_validationError != null) ...[
            const SizedBox(height: 12),
            _ValidationError(
              key: const Key('admin_corpus_upload_dialog_error'),
              message: _validationError!,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Picked file tile ────────────────────────────────────────────────────────

class _PickedFileTile extends StatelessWidget {
  const _PickedFileTile({super.key, required this.file});

  final PickedCorpusFile file;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.positive.withValues(alpha: 0.06),
        border: Border.all(
          color: AppColors.positive.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.insert_drive_file_outlined,
            size: 16,
            color: AppColors.positive,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  file.filename,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${(file.bytes.length / 1024).toStringAsFixed(1)} KB',
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Validation error banner ─────────────────────────────────────────────────

class _ValidationError extends StatelessWidget {
  const _ValidationError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.40),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}
