import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_celebration_overlay.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_training_image_viewer.dart';
import '../content/company_handbook_content.dart';
import '../content/training/training_docs.dart';
import '../search/barrio_training_search.dart';
import '../services/barrio_numeric_highlight.dart';
import '../services/barrio_term_links.dart';

final _whitespaceRegExp = RegExp(r'\s+');

/// Renders a single [HandbookUnit] as a premium dark glassmorphism card.
///
/// Features: expand/collapse for interactive cards, reading time estimate,
/// correct-answer sparkle, haptic feedback, premium badge depth.
///
/// Explainer units show body text (always expanded). Decision and checkpoint
/// units show interactive options with feedback revealed after selection.
class HandbookLessonCard extends StatefulWidget {
  final HandbookUnit unit;
  final VoidCallback? onCompleted;
  final bool isCarouselMode;
  final String? cardPosition;
  final VoidCallback? onRequestAdvance;

  /// Search deep-link highlighting (2026-07-11 operator request): folded
  /// query words to mark inside the body text. Matching is
  /// case- and diacritic-insensitive via the search service's
  /// length-preserving fold, so span offsets apply to the original
  /// text directly. Empty = no highlighting (the default everywhere
  /// outside a search deep link).
  final List<String> highlightTerms;

  /// Bookmark toggle (rec #8, 2026-07-23): whether this card is
  /// currently saved. Only meaningful when [onBookmarkTap] is wired.
  final bool bookmarked;

  /// Non-null renders the quiet bookmark toggle in the badge row. The
  /// training reader wires this for content cards; curated screens
  /// and quiz cards leave it null (no toggle, layout unchanged).
  final VoidCallback? onBookmarkTap;

  /// Tap-to-define term links (rec #9, 2026-07-23): non-null enables
  /// quiet underline-dot styling on known TERM titles inside the body
  /// and reports taps. The training reader wires this ONLY on the
  /// culinary host manuals; null (the default) renders every body
  /// exactly as before.
  final void Function(BarrioTermCard card)? onTermTap;

  const HandbookLessonCard({
    super.key,
    required this.unit,
    this.onCompleted,
    this.isCarouselMode = false,
    this.cardPosition,
    this.onRequestAdvance,
    this.highlightTerms = const [],
    this.bookmarked = false,
    this.onBookmarkTap,
    this.onTermTap,
  });

  @override
  State<HandbookLessonCard> createState() => _HandbookLessonCardState();
}

class _HandbookLessonCardState extends State<HandbookLessonCard> {
  int? _selectedIndex;
  bool _expanded = false;
  bool _showSparkle = false;
  bool _isPressed = false;

  Color get _borderColor {
    switch (widget.unit.type) {
      case HandbookUnitType.explainer:
        return const Color(0x22FFFFFF);
      case HandbookUnitType.decision:
        return const Color(0xFF2ECC71).withValues(alpha: 0.22);
      case HandbookUnitType.checkpoint:
        return const Color(0xFFF39C12).withValues(alpha: 0.22);
    }
  }

  bool get _isInteractive => widget.unit.type != HandbookUnitType.explainer;

  String get _readingTime {
    final words = widget.unit.body.split(_whitespaceRegExp).length +
        widget.unit.options.fold<int>(
            0, (sum, o) => sum + o.label.split(_whitespaceRegExp).length);
    final minutes = (words / 200).ceil().clamp(1, 99);
    return '~$minutes min';
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.unit;

    final carousel = widget.isCarouselMode;

    return GestureDetector(
      onTapDown: _isInteractive && !_expanded
          ? (_) {
              HapticFeedback.lightImpact();
              setState(() => _isPressed = true);
            }
          : null,
      onTapUp: _isInteractive && !_expanded
          ? (_) {
              setState(() {
                _isPressed = false;
                _expanded = true;
              });
            }
          : null,
      // Conditional EXACTLY like onTapDown/onTapUp (#1483 audit fix):
      // an unconditional onTapCancel registered a TapGestureRecognizer
      // on every card, so explainer (non-interactive) cards won the
      // gesture arena and starved the carousel's #1481 edge tap zones.
      // Explainer cards must register NO tap recognizer at all.
      onTapCancel: _isInteractive && !_expanded
          ? () => setState(() => _isPressed = false)
          : null,
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutBack,
        child: Container(
          margin: carousel ? EdgeInsets.zero : const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: const Color(0x14FFFFFF), // premium glass fill
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _borderColor),
            boxShadow: [
              // Inner accent glow
              BoxShadow(
                color: _badgeColor.withValues(alpha: _isPressed ? 0.22 : 0.10),
                blurRadius: _isPressed ? 12 : 20,
                spreadRadius: -4,
              ),
              // Outer ambient shadow
              BoxShadow(
                color: const Color(0x44000000),
                blurRadius: _isPressed ? 14 : 28,
                spreadRadius: _isPressed ? -6 : -2,
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // Specular highlight — overhead light catch
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.7, -0.8),
                        radius: 0.8,
                        colors: [
                          Colors.white.withValues(alpha: 0.08),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Accent bottom tint
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          _badgeColor.withValues(alpha: 0.05),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Content
              Padding(
                padding: const EdgeInsets.all(20),
                child: AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TypeBadge(type: unit.type, badgeHint: unit.badgeHint),
                  // Bookmark toggle (rec #8): next to the badge, well
                  // clear of the carousel's edge tap gutters.
                  if (widget.onBookmarkTap != null) ...[
                    const SizedBox(width: 6),
                    _BookmarkToggle(
                      saved: widget.bookmarked,
                      accent: _badgeColor,
                      onTap: widget.onBookmarkTap!,
                    ),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      unit.title,
                      style: GoogleFonts.playfairDisplay(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                  ),
                  if (_isInteractive && !carousel) ...[
                    const SizedBox(width: 8),
                    Text(
                      _readingTime,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: BarrioColors.textMuted.withValues(alpha: 0.7),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ],
              ),

              // Collapsed preview for interactive cards (list mode only)
              if (_isInteractive && !_expanded && !carousel) ...[
                const SizedBox(height: 10),
                Text(
                  unit.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13,
                    height: 1.8,
                    color: BarrioColors.textSecondary.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.expand_more_rounded,
                      size: 18,
                      color: _badgeColor.withValues(alpha: 0.45),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Tap to expand',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: _badgeColor.withValues(alpha: 0.45),
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
              ],

              // Carousel mode: show full body + "Tap to begin" for interactive cards
              if (carousel && _isInteractive && !_expanded) ...[
                const SizedBox(height: 14),
                _UnitBody(
                  unit: unit,
                  highlightTerms: widget.highlightTerms,
                  onTermTap: widget.onTermTap,
                  accent: _numberAccent,
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.touch_app_rounded,
                      size: 16,
                      color: _badgeColor.withValues(alpha: 0.5),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Tap to begin',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _badgeColor.withValues(alpha: 0.5),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ],

              // Full body (always shown for explainers; list mode: shown when expanded;
              // carousel mode: shown when expanded since pre-expand body is in the carousel block above)
              if (!_isInteractive || _expanded) ...[
                const SizedBox(height: 14),
                _UnitBody(
                  unit: unit,
                  highlightTerms: widget.highlightTerms,
                  onTermTap: widget.onTermTap,
                  accent: _numberAccent,
                ),
              ],

              if (_isInteractive && _expanded && unit.options.isNotEmpty) ...[
                const SizedBox(height: 16),
                ...List.generate(unit.options.length, (i) {
                  return _StaggeredOption(
                    index: i,
                    child: _OptionTile(
                      option: unit.options[i],
                      index: i,
                      selectedIndex: _selectedIndex,
                      showSparkle: _showSparkle && unit.options[i].isCorrect,
                      onSparkleComplete: () {
                        if (mounted) setState(() => _showSparkle = false);
                      },
                      onTap: _selectedIndex == null
                          ? () => _selectOption(i)
                          : null,
                    ),
                  );
                }),
              ],
              if (!_isInteractive) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: BarrioColors.tealWarm.withValues(alpha: 0.35),
                  ),
                ),
              ],
                  ],
                ),
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color get _badgeColor {
    return switch (widget.unit.type) {
      HandbookUnitType.explainer  => BarrioColors.tealWarm,
      HandbookUnitType.decision   => const Color(0xFF2ECC71),
      HandbookUnitType.checkpoint => const Color(0xFFF39C12),
    };
  }

  /// Accent for numeric fact pops (visual-first pass rec #3): the
  /// owning manual's identity color from [kBarrioTrainingAccents],
  /// resolved by the longest doc-id prefix of the unit id (training
  /// unit ids are `<docId>_cN_uM`). Units outside the training
  /// registry (curated handbook, fixtures) reuse the badge accent,
  /// the same plumbing the type badge already resolves.
  Color get _numberAccent {
    Color? best;
    var bestLength = -1;
    for (final entry in kBarrioTrainingAccents.entries) {
      if (entry.key.length > bestLength &&
          widget.unit.id.startsWith('${entry.key}_')) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    return best ?? _badgeColor;
  }

  void _selectOption(int index) {
    setState(() {
      _selectedIndex = index;
      if (widget.unit.options[index].isCorrect) _showSparkle = true;
    });
    if (widget.unit.options[index].isCorrect) {
      HapticFeedback.mediumImpact();
      widget.onCompleted?.call();
      widget.onRequestAdvance?.call();
    } else {
      HapticFeedback.lightImpact();
    }
  }
}

class _TypeBadge extends StatelessWidget {
  final HandbookUnitType type;
  final String? badgeHint;
  const _TypeBadge({required this.type, this.badgeHint});

  @override
  Widget build(BuildContext context) {
    final (defaultLabel, color) = switch (type) {
      HandbookUnitType.explainer  => ('LEARN',  BarrioColors.tealWarm),
      HandbookUnitType.decision   => ('DECIDE', const Color(0xFF2ECC71)),
      HandbookUnitType.checkpoint => ('CHECK',  const Color(0xFFF39C12)),
    };
    final label = badgeHint ?? defaultLabel;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.08),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
          color: color,
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final HandbookOption option;
  final int index;
  final int? selectedIndex;
  final bool showSparkle;
  final VoidCallback? onSparkleComplete;
  final VoidCallback? onTap;

  const _OptionTile({
    required this.option,
    required this.index,
    required this.selectedIndex,
    this.showSparkle = false,
    this.onSparkleComplete,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = selectedIndex == index;
    final isRevealed = selectedIndex != null;
    final showCorrect = isRevealed && option.isCorrect;
    final showWrong = isSelected && !option.isCorrect;

    Color borderColor;
    Color bgColor;
    if (showCorrect) {
      borderColor = const Color(0xFF2ECC71).withValues(alpha: 0.55);
      bgColor = const Color(0xFF2ECC71).withValues(alpha: 0.10);
    } else if (showWrong) {
      borderColor = const Color(0xFFE74C3C).withValues(alpha: 0.55);
      bgColor = const Color(0xFFE74C3C).withValues(alpha: 0.10);
    } else {
      borderColor = const Color(0x1AFFFFFF);
      bgColor = const Color(0x08FFFFFF);
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    String.fromCharCode(0x41 + index),
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: BarrioColors.tealWarm,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      option.label,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        color: BarrioColors.textPrimary,
                      ),
                    ),
                  ),
                  if (showCorrect) ...[
                    if (showSparkle)
                      CorrectAnswerSparkle(
                        accentColor: const Color(0xFF2ECC71),
                        onComplete: onSparkleComplete,
                      ),
                    const Icon(Icons.check_circle,
                        size: 18, color: Color(0xFF2ECC71)),
                  ],
                  if (showWrong)
                    const Icon(Icons.cancel, size: 18, color: Color(0xFFE74C3C)),
                ],
              ),
              if (isSelected) ...[
                const SizedBox(height: 8),
                Text(
                  option.feedback,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    height: 1.55,
                    fontStyle: FontStyle.italic,
                    color: BarrioColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One parsed body block. The generator joins body paragraphs with a
/// blank line; a paragraph beginning '- ' is a bullet, one beginning
/// 'N. ' is a numbered step, and one containing ' | ' is a table row.
/// Everything else is prose. Consecutive same-kind paragraphs group into
/// one list/table block so they render with real structure and tight,
/// even spacing instead of one flat run of text.
enum _BlockKind { prose, bullet, numbered, table }

final _numberedItem = RegExp(r'^(\d+)\.\s+(.*)$', dotAll: true);

_BlockKind _classifyPara(String para) {
  final t = para.trimLeft();
  if (t.startsWith('- ')) return _BlockKind.bullet;
  if (_numberedItem.hasMatch(t)) return _BlockKind.numbered;
  if (para.contains(' | ')) return _BlockKind.table;
  return _BlockKind.prose;
}

class _BodyBlock {
  final _BlockKind kind;
  final List<String> items; // prose: one entry; list/table: one per line
  const _BodyBlock(this.kind, this.items);
}

/// Groups a paragraph slice into ordered blocks, merging runs of
/// same-kind list/table paragraphs.
List<_BodyBlock> _parseBlocks(List<String> paras) {
  final blocks = <_BodyBlock>[];
  var i = 0;
  while (i < paras.length) {
    final kind = _classifyPara(paras[i]);
    if (kind == _BlockKind.prose) {
      blocks.add(_BodyBlock(kind, [paras[i]]));
      i++;
      continue;
    }
    final items = <String>[];
    while (i < paras.length && _classifyPara(paras[i]) == kind) {
      items.add(paras[i]);
      i++;
    }
    blocks.add(_BodyBlock(kind, items));
  }
  return blocks;
}

/// Full unit body, rendered as typed blocks (prose, bullet list,
/// numbered list, table) with consistent spacing so every slide reads
/// the same way. Words are the verbatim body string, unchanged; only the
/// layout is structured. Units with images keep the same interleaving:
/// each image is inserted after its [HandbookUnitImage.afterParagraph]
/// blank-line-paragraph index (-1 = before the first paragraph).
class _UnitBody extends StatelessWidget {
  final HandbookUnit unit;
  final List<String> highlightTerms;

  /// Tap-to-define term links (rec #9): non-null styles known TERM
  /// titles with a quiet underline-dot and reports taps. Null renders
  /// exactly as before.
  final void Function(BarrioTermCard card)? onTermTap;

  /// Accent for numeric fact pops (visual-first rec #3): number+unit
  /// tokens in the body render bold in this color. Styling only; the
  /// body string is never altered (verbatim law).
  final Color accent;

  const _UnitBody({
    required this.unit,
    required this.accent,
    this.highlightTerms = const [],
    this.onTermTap,
  });

  static const double _blockGap = 12;
  static const double _itemGap = 7;

  TextStyle get _style => GoogleFonts.ibmPlexSans(
        fontSize: 13.5,
        height: 1.62,
        color: BarrioColors.textSecondary,
      );

  @override
  Widget build(BuildContext context) {
    // First-occurrence-per-card term linking: one fresh set per build,
    // threaded through every text chunk in reading order, so a term
    // appearing many times on one card links only its first occurrence.
    final linked = <String>{};
    final paragraphs = unit.body.split('\n\n');
    if (unit.images.isEmpty) {
      return _renderRun(paragraphs, linked);
    }
    // Picture-first TERM cards (visual-first pass rec #1, 2026-07-24):
    // glossary definition cards show the dish/ingredient BEFORE the
    // words, so every image renders above the body regardless of its
    // afterParagraph anchor (this early return replaces interleaving,
    // so no image can double-render). Non-TERM cards keep the exact
    // source interleaving below.
    if (unit.badgeHint == 'TERM') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final image in unit.images) _UnitImage(image: image),
          _renderRun(paragraphs, linked),
        ],
      );
    }
    final byBoundary = <int, List<HandbookUnitImage>>{};
    for (final image in unit.images) {
      final boundary = image.afterParagraph.clamp(-1, paragraphs.length - 1);
      byBoundary.putIfAbsent(boundary, () => []).add(image);
    }
    final children = <Widget>[];
    _addImages(children, byBoundary[-1]);
    var runStart = 0;
    for (var p = 0; p < paragraphs.length; p++) {
      final imagesAfter = byBoundary[p];
      if (imagesAfter == null) continue;
      children.add(_renderRun(paragraphs.sublist(runStart, p + 1), linked));
      _addImages(children, imagesAfter);
      runStart = p + 1;
    }
    if (runStart < paragraphs.length) {
      children.add(_renderRun(paragraphs.sublist(runStart), linked));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  void _addImages(List<Widget> out, List<HandbookUnitImage>? images) {
    if (images == null) return;
    for (final image in images) {
      out.add(_UnitImage(image: image));
    }
  }

  /// Renders a contiguous paragraph slice. A lone prose paragraph renders
  /// as a single Text; anything else stacks typed blocks with even gaps.
  Widget _renderRun(List<String> paras, Set<String> linked) {
    final blocks = _parseBlocks(paras);
    if (blocks.length == 1 && blocks.first.kind == _BlockKind.prose) {
      return _bodyText(blocks.first.items.first, _style, linked);
    }
    final children = <Widget>[];
    for (var b = 0; b < blocks.length; b++) {
      if (b > 0) children.add(const SizedBox(height: _blockGap));
      children.add(_renderBlock(blocks[b], linked));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _renderBlock(_BodyBlock block, Set<String> linked) {
    switch (block.kind) {
      case _BlockKind.prose:
        return _bodyText(block.items.first, _style, linked);
      case _BlockKind.bullet:
        return _spacedColumn([
          for (final item in block.items)
            _bulletRow(item.trimLeft().substring(2), linked),
        ]);
      case _BlockKind.numbered:
        return _spacedColumn([
          for (final item in block.items)
            _numberedRow(item.trimLeft(), linked),
        ]);
      case _BlockKind.table:
        return _table(block.items, linked);
    }
  }

  /// A column of list rows separated by [_itemGap].
  Widget _spacedColumn(List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) children.add(const SizedBox(height: _itemGap));
      children.add(rows[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _bulletRow(String text, Set<String> linked) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 8, left: 2, right: 10),
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            color: BarrioColors.tealWarm.withValues(alpha: 0.85),
            shape: BoxShape.circle,
          ),
        ),
        Expanded(child: _bodyText(text, _style, linked)),
      ],
    );
  }

  Widget _numberedRow(String text, Set<String> linked) {
    final match = _numberedItem.firstMatch(text);
    final marker = match != null ? '${match.group(1)}.' : '•';
    final body = match != null ? match.group(2)! : text;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            marker,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 13,
              height: 1.62,
              fontWeight: FontWeight.w700,
              color: BarrioColors.tealWarm.withValues(alpha: 0.85),
            ),
          ),
        ),
        Expanded(child: _bodyText(body, _style, linked)),
      ],
    );
  }

  Widget _table(List<String> rows, Set<String> linked) {
    final children = <Widget>[];
    for (var r = 0; r < rows.length; r++) {
      children.add(_tableRow(rows[r].split(' | '), r == 0, linked));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _tableRow(List<String> cells, bool header, Set<String> linked) {
    final cellStyle = _style.copyWith(
      fontSize: 12.5,
      fontWeight: header ? FontWeight.w700 : FontWeight.w400,
      color: header ? BarrioColors.textPrimary : BarrioColors.textSecondary,
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x14FFFFFF))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cell in cells)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _bodyText(cell.trim(), cellStyle, linked),
              ),
            ),
        ],
      ),
    );
  }

  /// One text chunk: plain, search-highlighted, term-linked, and/or
  /// number-popped. The search fold is length-preserving per code
  /// unit, so fold-space match offsets index the original string
  /// directly. Precedence: search highlights win over term links (the
  /// matcher drops overlaps via [blockedRanges]), and both win over
  /// numeric pops (a number+unit token overlapping either is dropped
  /// whole, so text inside a term link is never re-styled). The text
  /// itself is NEVER altered: styling only (verbatim law).
  Widget _bodyText(String text, TextStyle style, Set<String> linked) {
    final highlightRanges = highlightTerms.isEmpty
        ? const <List<int>>[]
        : _mergeRanges(_rawMatchRanges(BarrioTrainingSearch.fold(text)));
    final termMatches = onTermTap == null
        ? const <BarrioTermMatch>[]
        : BarrioTermLinks.matchesIn(
            text,
            alreadyLinked: linked,
            blockedRanges: highlightRanges,
          );
    final numericMatches = BarrioNumericHighlight.matchesIn(
      text,
      blockedRanges: [
        ...highlightRanges,
        for (final t in termMatches) [t.start, t.end],
      ],
    );
    if (highlightRanges.isEmpty &&
        termMatches.isEmpty &&
        numericMatches.isEmpty) {
      return Text(text, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: _composeSpans(
            text, highlightRanges, termMatches, numericMatches, style),
      ),
    );
  }

  /// All [start, end) fold-space match ranges of every term, unsorted.
  List<List<int>> _rawMatchRanges(String folded) {
    final ranges = <List<int>>[];
    for (final term in highlightTerms) {
      if (term.isEmpty) continue;
      var idx = folded.indexOf(term);
      while (idx >= 0) {
        ranges.add([idx, idx + term.length]);
        idx = folded.indexOf(term, idx + term.length);
      }
    }
    return ranges;
  }

  /// Sorts ranges and merges overlaps so span runs never intersect.
  List<List<int>> _mergeRanges(List<List<int>> ranges) {
    if (ranges.isEmpty) return ranges;
    ranges.sort((a, b) => a[0].compareTo(b[0]));
    final merged = <List<int>>[ranges.first];
    for (final r in ranges.skip(1)) {
      if (r[0] > merged.last[1]) {
        merged.add(r);
      } else if (r[1] > merged.last[1]) {
        merged.last[1] = r[1];
      }
    }
    return merged;
  }

  /// Interleaves the highlight ranges, term-link matches, and numeric
  /// fact tokens (all sorted, mutually non-overlapping) into one span
  /// run over [text].
  List<InlineSpan> _composeSpans(
    String text,
    List<List<int>> highlights,
    List<BarrioTermMatch> terms,
    List<BarrioNumericMatch> numerics,
    TextStyle style,
  ) {
    final segments = <_BodySegment>[
      for (final r in highlights) _BodySegment(r[0], r[1], null),
      for (final t in terms) _BodySegment(t.start, t.end, t),
      for (final n in numerics)
        _BodySegment(n.start, n.end, null, numeric: true),
    ]..sort((a, b) => a.start.compareTo(b.start));
    final mark = style.copyWith(
      color: BarrioColors.textPrimary,
      fontWeight: FontWeight.w700,
      backgroundColor: BarrioColors.tealWarm.withValues(alpha: 0.28),
    );
    // Numeric fact pop (rec #3): bold + the manual's accent, colors
    // only; the verbatim substring renders unchanged.
    final numberPop = style.copyWith(
      fontWeight: FontWeight.w700,
      color: accent,
    );
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final seg in segments) {
      if (seg.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, seg.start)));
      }
      final segText = text.substring(seg.start, seg.end);
      final term = seg.term;
      if (term != null) {
        spans.add(_termLinkSpan(segText, term, style));
      } else if (seg.numeric) {
        spans.add(TextSpan(text: segText, style: numberPop));
      } else {
        spans.add(TextSpan(text: segText, style: mark));
      }
      cursor = seg.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans;
  }

  /// One tappable term occurrence: the VERBATIM substring with a quiet
  /// dotted underline. Rendered as an inline widget so the tap needs
  /// no recognizer lifecycle management; baseline alignment keeps it
  /// sitting in the text line.
  InlineSpan _termLinkSpan(
    String segText,
    BarrioTermMatch match,
    TextStyle style,
  ) {
    return WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: Semantics(
        button: true,
        label: 'See the definition of $segText',
        child: GestureDetector(
          key: ValueKey<String>(
              'barrio_term_link_${unit.id}_${match.foldedTerm}'),
          onTap: () => onTermTap?.call(match.card),
          child: Text(
            segText,
            style: style.copyWith(
              decoration: TextDecoration.underline,
              decorationStyle: TextDecorationStyle.dotted,
              decorationColor: BarrioColors.tealWarm.withValues(alpha: 0.75),
              decorationThickness: 1.6,
            ),
          ),
        ),
      ),
    );
  }
}

/// One styled segment inside a text chunk: a search highlight
/// ([term] null), a term link, or a numeric fact pop ([numeric] true).
class _BodySegment {
  final int start;
  final int end;
  final BarrioTermMatch? term;
  final bool numeric;
  const _BodySegment(this.start, this.end, this.term, {this.numeric = false});
}

/// One content picture inside a unit body: rounded corners, full card
/// width, tap to open the full-screen viewer. The [Image.asset]
/// errorBuilder keeps widget tests (no bundled assets) from throwing.
class _UnitImage extends StatelessWidget {
  final HandbookUnitImage image;
  const _UnitImage({required this.image});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => BarrioTrainingImageViewer.open(
              context,
              assetPath: image.assetPath,
              caption: image.caption,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                image.assetPath,
                width: double.infinity,
                fit: BoxFit.fitWidth,
                errorBuilder: (context, error, stackTrace) => Container(
                  width: double.infinity,
                  height: 120,
                  color: const Color(0x14FFFFFF),
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 28,
                    color: BarrioColors.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          if (image.caption != null) ...[
            const SizedBox(height: 6),
            Text(
              image.caption!,
              style: GoogleFonts.ibmPlexSans(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: BarrioColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Quiet bookmark toggle in the badge row (rec #8). Small icon-only
/// tap target next to the type badge, deliberately far from the
/// carousel's edge tap gutters so saving never turns the page.
class _BookmarkToggle extends StatelessWidget {
  final bool saved;
  final Color accent;
  final VoidCallback onTap;

  const _BookmarkToggle({
    required this.saved,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: saved ? 'Remove from saved' : 'Save this card',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            size: 17,
            color: saved
                ? accent.withValues(alpha: 0.95)
                : BarrioColors.textMuted.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }
}

/// Staggered option animation for premium reveal.
class _StaggeredOption extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredOption({required this.index, required this.child});

  @override
  State<_StaggeredOption> createState() => _StaggeredOptionState();
}

class _StaggeredOptionState extends State<_StaggeredOption>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.15),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 100 * widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
