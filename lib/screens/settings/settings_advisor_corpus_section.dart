// Phase 11a.12 — dev/admin-only ADVISOR CORPUS Settings section.
//
// Lets a dev/admin paste a single Markdown document into the app and
// click `Preview` to see a deterministic local summary (file name,
// line count, estimated tokens, local-only status). The "Load to
// cloud" action is intentionally disabled with an explanatory message
// — the 11a.11b cloud DB apply prerequisites are not satisfied in
// this environment.
//
// Hidden in non-debug builds via `kDebugMode` and gated on the
// settings_screen dispatcher receiving an `advisorCorpusAdminService`
// (or the test-only `forceShowAdvisorCorpusSection` flag).

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/advisor_corpus_admin_service.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

class SettingsAdvisorCorpusSection extends StatefulWidget {
  /// Service that owns local validation and the (currently blocked)
  /// cloud-load entry point. Tests inject a service directly;
  /// production wires the default service.
  final AdvisorCorpusAdminService service;

  const SettingsAdvisorCorpusSection({super.key, required this.service});

  @override
  State<SettingsAdvisorCorpusSection> createState() =>
      _SettingsAdvisorCorpusSectionState();
}

class _SettingsAdvisorCorpusSectionState
    extends State<SettingsAdvisorCorpusSection> {
  late final TextEditingController _fileNameController;
  late final TextEditingController _markdownController;
  CorpusPreviewResult? _lastPreview;
  bool _previewing = false;

  @override
  void initState() {
    super.initState();
    _fileNameController = TextEditingController();
    _markdownController = TextEditingController();
  }

  @override
  void dispose() {
    _fileNameController.dispose();
    _markdownController.dispose();
    super.dispose();
  }

  Future<void> _onPreview() async {
    setState(() => _previewing = true);
    final result = await widget.service.preview(
      fileName: _fileNameController.text,
      markdown: _markdownController.text,
    );
    if (!mounted) return;
    setState(() {
      _previewing = false;
      _lastPreview = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        const _CorpusHeader(),
        const SettingsRowDivider(),
        _FileNameField(controller: _fileNameController),
        const SettingsRowDivider(),
        _MarkdownField(controller: _markdownController),
        const SettingsRowDivider(),
        _ActionsRow(
          previewing: _previewing,
          onPreview: _onPreview,
        ),
        if (_lastPreview != null) ...[
          const SettingsRowDivider(),
          _PreviewResultRow(result: _lastPreview!),
        ],
        const SettingsRowDivider(),
        const _CloudBlockedRow(),
      ],
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────────

class _CorpusHeader extends StatelessWidget {
  const _CorpusHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('advisor_corpus_header'),
      padding: EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CORPUS DOC PREVIEW (LOCAL-ONLY)',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          SizedBox(height: 4),
          Text(
            'Paste a single Markdown document below and tap Preview to '
            'see a deterministic local summary. Nothing leaves the app.',
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _FileNameField extends StatelessWidget {
  final TextEditingController controller;
  const _FileNameField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FILE NAME',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('advisor_corpus_file_name_field'),
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'example.md',
              isDense: true,
            ),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownField extends StatelessWidget {
  final TextEditingController controller;
  const _MarkdownField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'MARKDOWN',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('advisor_corpus_markdown_field'),
            controller: controller,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '# Heading\n\nMarkdown body...',
              isDense: true,
            ),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionsRow extends StatelessWidget {
  final bool previewing;
  final VoidCallback onPreview;

  const _ActionsRow({
    required this.previewing,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              key: const Key('advisor_corpus_preview_button'),
              onPressed: previewing ? null : onPreview,
              child: Text(previewing ? 'Previewing...' : 'Preview'),
            ),
          ),
          const SizedBox(width: 8),
          // The cloud-load action is permanently disabled while the
          // 11a.11b prerequisites are unmet — `onPressed: null` is
          // what makes the button non-interactive (Material renders
          // it greyed-out and ignores hit-tests). The visible label
          // and the always-rendered `_CloudBlockedRow` below explain
          // why; tapping never triggers an attempt.
          Expanded(
            child: TextButton(
              key: const Key('advisor_corpus_cloud_load_button'),
              onPressed: null,
              child: const Text('Load to cloud (blocked)'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewResultRow extends StatelessWidget {
  final CorpusPreviewResult result;
  const _PreviewResultRow({required this.result});

  @override
  Widget build(BuildContext context) {
    if (!result.isValid) {
      return Padding(
        key: const Key('advisor_corpus_preview_error'),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PREVIEW REJECTED',
              style: TextStyle(color: AppColors.negative, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Text(
              result.errorMessage ?? 'Preview rejected.',
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          ],
        ),
      );
    }
    return Padding(
      key: const Key('advisor_corpus_preview_result'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'PREVIEW LOCAL ONLY',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            'file · ${result.normalizedFileName}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'source · ${result.sourcePathPreview}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'title · ${result.titlePreview}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'headings · ${result.headingCount}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'lines · ${result.lineCount}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'est tokens · ${result.estimatedTokens}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'est chunks · ${result.estimatedChunkCount}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            'status · ${result.localStatus}',
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _CloudBlockedRow extends StatelessWidget {
  const _CloudBlockedRow();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('advisor_corpus_cloud_blocked'),
      padding: EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CLOUD LOAD · BLOCKED',
            style: TextStyle(color: AppColors.sunset, fontSize: 11),
          ),
          SizedBox(height: 4),
          Text(
            'Cloud load is blocked: 11a.11b apply prerequisites missing. '
            'See docs/phases/phase_11a/'
            'phase_11a_11b_cloud_db_apply_readiness.md.',
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

// ─── Visibility helper for the settings_screen dispatcher ────────────────────

/// True only when running a debug/dev build. Settings dispatch
/// consults this so the section disappears in release builds.
bool get advisorCorpusSectionEnabled => kDebugMode;
