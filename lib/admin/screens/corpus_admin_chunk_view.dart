// B3 — Grouped sections view for the corpus admin screen.
// B-r2 — Topics-the-advisor-knows presentation: kind filter +
//        "Showing X of Y" count + per-topic kind icon/label/pill.
//
// Extracted from corpus_admin_screen.dart to keep that file under the
// operator_web_size_lint frozen ceiling (see tool/operator_web_size_lint.dart).
//
// Public surface: [ChunkGroupedView] + [corpusTopicKindIcon]. Private
// helpers [_DocGroup] stay file-private. The tile builder callback
// decouples this file from the private [_ChunkPreviewTile] in the parent
// screen (the tile renders the kind icon/label/pill itself; this view
// owns the search + kind filter + grouping that wraps the tiles).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import '../widgets/admin_action_controls.dart';

/// B-r2: the outlined line-icon for a topic [kind]. Mirrors the approved
/// preview's icon set (book / SOP / policy / concept / metric / formula /
/// risk / person). Kept here next to the grouped view because it is pure
/// presentation; the kind itself is derived by [corpusTopicKindForChunk].
IconData corpusTopicKindIcon(AdminCorpusTopicKind kind) {
  switch (kind) {
    case AdminCorpusTopicKind.document:
      return Icons.menu_book_outlined;
    case AdminCorpusTopicKind.sop:
      return Icons.checklist_outlined;
    case AdminCorpusTopicKind.policy:
      return Icons.shield_outlined;
    case AdminCorpusTopicKind.concept:
      return Icons.lightbulb_outline;
    case AdminCorpusTopicKind.metric:
      return Icons.bar_chart_outlined;
    case AdminCorpusTopicKind.formula:
      return Icons.functions_outlined;
    case AdminCorpusTopicKind.risk:
      return Icons.warning_amber_outlined;
    case AdminCorpusTopicKind.role:
      return Icons.person_outline;
  }
}

/// B-r2: the tinted square holding a topic's kind icon. Mirrors the
/// preview's `.tic` chip (rounded square, muted fill, peacock glyph).
/// Public so the parent screen's content tile can render it without
/// regrowing past its frozen size ceiling.
class TopicKindIcon extends StatelessWidget {
  const TopicKindIcon({super.key, required this.kind});

  final AdminCorpusTopicKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        corpusTopicKindIcon(kind),
        size: 18,
        color: AppColors.peacockDark,
      ),
    );
  }
}

/// B-r2: the kind pill (Document / SOP / Policy / ...). Mirrors the
/// preview's `.kind-pill`: muted fill, fully rounded, secondary text.
class TopicKindPill extends StatelessWidget {
  const TopicKindPill({super.key, required this.kind});

  final AdminCorpusTopicKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        kind.pill,
        style: AppTextStyles.chipLabel(color: AppColors.textSecondary),
      ),
    );
  }
}

/// Groups [chunks] by their [ChunkPreview.sourcePath] and renders each
/// group as a collapsible document section. A search box + a kind filter
/// above narrow the list client-side; a "Showing X of Y" count keeps the
/// list legible with 8 documents and 233+ sections in staging.
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

  /// B-r2: active kind filter. Null means "All kinds" (unfiltered).
  AdminCorpusTopicKind? _kindFilter;

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

  /// Combined search + kind filter. A topic shows only when it matches
  /// the typed query AND the selected kind (when one is selected).
  bool _chunkMatchesFilters(ChunkPreview chunk, String q) {
    if (!_chunkMatchesQuery(chunk, q)) return false;
    final kind = _kindFilter;
    if (kind == null) return true;
    return corpusTopicKindForChunk(chunk) == kind;
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
    final hasActiveFilter = q.isNotEmpty || _kindFilter != null;

    // Build per-doc buckets, filtering as we go.
    final docBuckets = <String, List<ChunkPreview>>{};
    for (final path in docPaths) {
      final filtered = chunks
          .where((c) => c.sourcePath == path && _chunkMatchesFilters(c, q))
          .toList();
      // Keep an empty bucket only when nothing is filtering, so the doc
      // group still renders (and reads "0 sections") in the unfiltered
      // view. Under a search/kind filter, empty docs drop out.
      if (filtered.isNotEmpty || !hasActiveFilter) {
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
    final totalAll = chunks.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Toolbar: search box + kind filter + "Showing X of Y".
        _TopicToolbar(
          searchController: _searchController,
          query: _query,
          kindFilter: _kindFilter,
          shown: totalVisible,
          total: totalAll,
          onKindChanged: (kind) => setState(() => _kindFilter = kind),
          onClearSearch: () => _searchController.clear(),
        ),

        // Document groups or empty-filter notice.
        if (visiblePaths.isEmpty && hasActiveFilter)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              AdminKnowledgeBaseCopy.topicsEmpty,
              key: const Key('admin_corpus_topics_empty'),
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

/// B-r2: the search + kind-filter + count toolbar above the topic groups.
/// Mirrors the approved preview's `.toolbar` (search box, kind dropdown,
/// "Showing X of Y"). The dropdown's first option is "All kinds"; each
/// other option pluralizes one [AdminCorpusTopicKind].
class _TopicToolbar extends StatelessWidget {
  const _TopicToolbar({
    required this.searchController,
    required this.query,
    required this.kindFilter,
    required this.shown,
    required this.total,
    required this.onKindChanged,
    required this.onClearSearch,
  });

  final TextEditingController searchController;
  final String query;
  final AdminCorpusTopicKind? kindFilter;
  final int shown;
  final int total;
  final ValueChanged<AdminCorpusTopicKind?> onKindChanged;
  final VoidCallback onClearSearch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          // Search box.
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 360),
            child: TextField(
              key: const Key('admin_corpus_content_search'),
              controller: searchController,
              decoration: InputDecoration(
                hintText: AdminKnowledgeBaseCopy.topicSearchHint,
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
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  borderSide: const BorderSide(color: AppColors.borderSubtle),
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

          // Kind filter dropdown. The value is nullable: null = "All kinds".
          _KindFilterDropdown(value: kindFilter, onChanged: onKindChanged),

          // "Showing X of Y" count.
          Text(
            AdminKnowledgeBaseCopy.topicsShowing(shown, total),
            key: const Key('admin_corpus_topics_count'),
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// B-r2: the "All kinds / Documents / SOPs / ..." dropdown. Uses a
/// nullable value so "All kinds" is a real unfiltered state rather than a
/// sentinel kind. Styled to match the search box (hairline border, small
/// radius) so the toolbar reads as one control row.
class _KindFilterDropdown extends StatelessWidget {
  const _KindFilterDropdown({required this.value, required this.onChanged});

  final AdminCorpusTopicKind? value;
  final ValueChanged<AdminCorpusTopicKind?> onChanged;

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
        child: DropdownButton<AdminCorpusTopicKind?>(
          key: const Key('admin_corpus_kind_filter'),
          value: value,
          isDense: true,
          borderRadius: BorderRadius.circular(AppRadius.small),
          icon: const Icon(
            Icons.expand_more_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          style: AppTextStyles.body13(color: AppColors.textPrimary),
          dropdownColor: AppColors.backgroundSurface,
          items: <DropdownMenuItem<AdminCorpusTopicKind?>>[
            DropdownMenuItem<AdminCorpusTopicKind?>(
              value: null,
              child: Text(adminCorpusKindFilterOptionLabel(null)),
            ),
            for (final kind in AdminCorpusTopicKind.values)
              DropdownMenuItem<AdminCorpusTopicKind?>(
                value: kind,
                child: Text(adminCorpusKindFilterOptionLabel(kind)),
              ),
          ],
          onChanged: onChanged,
        ),
      ),
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
