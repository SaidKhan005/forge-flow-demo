// Advisor Knowledge Activation B1 — Corpus upload drop zone.
//
// Renders a drag-and-drop target inside the corpus upload dialog. The
// widget uses a conditional import seam so the [dart:html] drag-event
// wiring only runs on Flutter Web; the VM target renders a static
// visual placeholder.
//
// This split mirrors the pattern at
// `lib/operator_web/services/business_logo_file_picker.dart` (stub /
// conditional-import / web implementation).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../services/corpus_file_picker.dart';
import 'corpus_upload_drop_zone_stub.dart'
    if (dart.library.html) 'corpus_upload_drop_zone_web.dart' as drop_impl;

/// A drag-and-drop target rendered inside the corpus upload dialog.
///
/// On Flutter Web, OS-level file drag events from the browser are
/// captured and forwarded to [onFilePicked]. On the VM (widget tests,
/// desktop builds) the widget renders the visual only — drag events are
/// not wired.
///
/// [pickedFile] drives the visual state: null shows the "drop here"
/// prompt; non-null shows a "file ready" confirmation.
class CorpusUploadDropZone extends StatefulWidget {
  const CorpusUploadDropZone({
    super.key,
    required this.pickedFile,
    required this.onFilePicked,
  });

  final PickedCorpusFile? pickedFile;
  final ValueChanged<PickedCorpusFile> onFilePicked;

  @override
  State<CorpusUploadDropZone> createState() => _CorpusUploadDropZoneState();
}

class _CorpusUploadDropZoneState extends State<CorpusUploadDropZone> {
  bool _isDragOver = false;
  Object? _dragTarget; // opaque handle returned by the impl

  @override
  void initState() {
    super.initState();
    _dragTarget = drop_impl.attachDropListener(
      onDragOver: () {
        if (!mounted) return;
        setState(() => _isDragOver = true);
      },
      onDragLeave: () {
        if (!mounted) return;
        setState(() => _isDragOver = false);
      },
      onDrop: (PickedCorpusFile file) {
        if (!mounted) return;
        setState(() => _isDragOver = false);
        widget.onFilePicked(file);
      },
    );
  }

  @override
  void dispose() {
    drop_impl.detachDropListener(_dragTarget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDragOver = _isDragOver;
    final hasPicked = widget.pickedFile != null;
    final borderColor = isDragOver
        ? AppColors.sunset
        : hasPicked
        ? AppColors.positive
        : AppColors.borderSubtle;
    final bgColor = isDragOver
        ? AppColors.sunset.withValues(alpha: 0.06)
        : hasPicked
        ? AppColors.positive.withValues(alpha: 0.04)
        : AppColors.backgroundDeep;

    return Container(
      key: const Key('admin_corpus_drop_zone'),
      height: 120,
      decoration: BoxDecoration(
        color: bgColor,
        border: Border.all(
          color: borderColor,
          width: isDragOver ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isDragOver
                  ? Icons.file_download_outlined
                  : hasPicked
                  ? Icons.check_circle_outline
                  : Icons.upload_file_outlined,
              size: 28,
              color: isDragOver
                  ? AppColors.sunset
                  : hasPicked
                  ? AppColors.positive
                  : AppColors.textMuted,
            ),
            const SizedBox(height: 6),
            Text(
              isDragOver
                  ? 'Drop the file here'
                  : hasPicked
                  ? 'File ready to upload'
                  : 'Drag and drop a file here, or use "Choose file" below',
              style: AppTextStyles.body13(
                color: isDragOver
                    ? AppColors.sunset
                    : hasPicked
                    ? AppColors.positive
                    : AppColors.textMuted,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
