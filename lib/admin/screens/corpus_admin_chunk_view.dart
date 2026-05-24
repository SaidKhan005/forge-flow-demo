// B3 — Grouped sections view for the corpus admin screen.
//
// Extracted from corpus_admin_screen.dart to keep that file under the
// operator_web_size_lint frozen ceiling (see tool/operator_web_size_lint.dart).
//
// Public surface: [ChunkGroupedView]. Private helpers [_DocGroup] stay
// file-private. The tile builder callback decouples this file from the
// private [_ChunkPreviewTile] in the parent screen.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/corpus_admin_models.dart';

/// Groups [chunks] by their [ChunkPreview.sourcePath] and renders each
/// group as a collapsible document section. A search box above filters
/// sections client-side by section name and snippet text, keeping the
/// list usable with 8 documents and 233+ sections in staging.
///
/// The [sectionTileBuilder] callback renders the individual tiles so
/// this widget stays decoupled from private widgets in the parent screen.
class ChunkGroupedView extends StatefulWidget {
  const ChunkGroupedView({
    super.key,
    required this.chunks,
    required this.sectionTileBuilder,
  });

  final List<ChunkPreview> chunks;

  /// Renders one tile for [chunk]. Typically returns a `_ChunkPreviewTile`
  /// with the appropriate [Key] set by the caller.
  final Widget Function(ChunkPreview chunk) sectionTileBuilder;

  @override
  State<ChunkGroupedView> createState() => _ChunkGroupedViewState();
}

class _ChunkGroupedViewState extends State<ChunkGroupedView> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// Paths currently expanded. Starts all-expanded for non-empty corpora.
  final Set<String> _expandedDocs = {};
  bool _initialExpansionDone = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q != _query) setState(() => _query = q);
    });
  }

  @override
  void didUpdateWidget(ChunkGroupedView old) {
    super.didUpdateWidget(old);
    // When the chunk list changes (new version selected), reset expansion
    // so the new corpus starts in all-open state.
    if (old.chunks != widget.chunks) {
      _initialExpansionDone = false;
      _expandedDocs.clear();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// All unique source paths, preserving the original ordering.
  List<String> get _allDocPaths {
    final seen = <String>{};
    final result = <String>[];
    for (final c in widget.chunks) {
      if (seen.add(c.sourcePath)) result.add(c.sourcePath);
    }
    return result;
  }

  /// Friendly display name: filename without directory prefix or extension;
  /// underscores replaced with spaces.
  static String _docDisplayName(String sourcePath) {
    final last = sourcePath.split('/').last.split('\\').last;
    final dotIndex = last.lastIndexOf('.');
    if (dotIndex > 0) return last.substring(0, dotIndex).replaceAll('_', ' ');
    return last.isEmpty ? sourcePath : last;
  }

  bool _chunkMatchesQuery(ChunkPreview chunk, String q) {
    if (q.isEmpty) return true;
    final sectionName = chunk.headingPath.isNotEmpty
        ? chunk.headingPath.last.toLowerCase()
        : '';
    return sectionName.contains(q) || chunk.snippet.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final chunks = widget.chunks;

    if (chunks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No content loaded yet.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      );
    }

    final docPaths = _allDocPaths;

    // Default all groups to expanded on first render.
    if (!_initialExpansionDone) {
      _expandedDocs.addAll(docPaths);
      _initialExpansionDone = true;
    }

    final q = _query;

    // Build per-doc buckets, filtering as we go.
    final docBuckets = <String, List<ChunkPreview>>{};
    for (final path in docPaths) {
      final filtered = chunks
          .where((c) => c.sourcePath == path && _chunkMatchesQuery(c, q))
          .toList();
      if (filtered.isNotEmpty || q.isEmpty) {
        docBuckets[path] = filtered;
      }
    }

    final visiblePaths = docPaths
        .where((p) => docBuckets.containsKey(p))
        .toList();

    final totalVisible = docBuckets.values.fold<int>(
      0,
      (sum, list) => sum + list.length,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Search bar.
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            key: const Key('admin_corpus_content_search'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search sections...',
              hintStyle: AppTextStyles.body13(color: AppColors.textMuted),
              prefixIcon: const Icon(
                Icons.search_outlined,
                size: 18,
                color: AppColors.textMuted,
              ),
              suffixIcon: _query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      color: AppColors.textMuted,
                      tooltip: 'Clear search',
                      onPressed: () => _searchController.clear(),
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: AppColors.borderSubtle),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(color: AppColors.borderSubtle),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
                borderSide: const BorderSide(
                  color: AppColors.sunset,
                  width: 1.5,
                ),
              ),
            ),
          ),
        ),

        // Result count hint while searching.
        if (q.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              '$totalVisible section${totalVisible == 1 ? '' : 's'} match',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ),

        // Document groups or empty-search notice.
        if (visiblePaths.isEmpty && q.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No sections match your search.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          )
        else
          ...visiblePaths.map((path) {
            final sections = docBuckets[path]!;
            final isExpanded = _expandedDocs.contains(path);
            final docName = _docDisplayName(path);
            return _DocGroup(
              key: Key('admin_corpus_doc_group_${path.hashCode}'),
              docPath: path,
              docName: docName,
              sections: sections,
              isExpanded: isExpanded,
              sectionTileBuilder: widget.sectionTileBuilder,
              onToggle: () => setState(() {
                if (isExpanded) {
                  _expandedDocs.remove(path);
                } else {
                  _expandedDocs.add(path);
                }
              }),
            );
          }),
      ],
    );
  }
}

/// One collapsible document group inside [ChunkGroupedView].
class _DocGroup extends StatelessWidget {
  const _DocGroup({
    super.key,
    required this.docPath,
    required this.docName,
    required this.sections,
    required this.isExpanded,
    required this.sectionTileBuilder,
    required this.onToggle,
  });

  final String docPath;
  final String docName;
  final List<ChunkPreview> sections;
  final bool isExpanded;
  final Widget Function(ChunkPreview chunk) sectionTileBuilder;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row — always visible.
          InkWell(
            key: Key('admin_corpus_doc_group_header_${docPath.hashCode}'),
            onTap: onToggle,
            borderRadius: isExpanded
                ? const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  )
                : BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.backgroundMid,
                borderRadius: isExpanded
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(7),
                        topRight: Radius.circular(7),
                      )
                    : BorderRadius.circular(7),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 16,
                    color: AppColors.peacockDark,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      docName,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Section count chip.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.peacock.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${sections.length} '
                      'section${sections.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono8(color: AppColors.peacockDark),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: const Icon(
                      Icons.keyboard_arrow_down_outlined,
                      size: 18,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Sections list — conditionally shown.
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: sections.map(sectionTileBuilder).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
