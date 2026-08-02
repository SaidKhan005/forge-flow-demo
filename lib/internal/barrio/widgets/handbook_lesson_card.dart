import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_celebration_overlay.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_training_image_viewer.dart';
import '../content/company_handbook_content.dart';
import '../content/highlight/barrio_key_terms.dart';
import '../content/highlight/cards/barrio_card_keys_index.dart';
import '../content/quiz/barrio_quiz_models.dart';
import '../content/training/training_docs.dart';
import '../search/barrio_training_search.dart';
import '../services/barrio_numeric_highlight.dart';
import '../services/barrio_term_links.dart';

final _whitespaceRegExp = RegExp(r'\s+');

/// Renders a single [HandbookUnit] as a premium light glassmorphism card.
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
        return const Color(0x1F16243B); // hairline navy on the white card
      case HandbookUnitType.decision:
        return const Color(0xFF2ECC71).withValues(alpha: 0.35);
      case HandbookUnitType.checkpoint:
        return BarrioColors.warning.withValues(alpha: 0.35);
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

    // Answer highlight (operator request 2026-07-26): the card looks up its
    // own chapter-end quiz answer phrases by unit id, so no call site changes
    // and no new constructor param. Empty for the vast majority of cards.
    final answerEvidence = barrioAnswerEvidenceForUnit(unit.id);

    // Key-term color emphasis (2026-07-28, rolled out 2026-07-29): the card
    // looks up its own curated key terms by unit id, so no call-site changes
    // and no new public constructor param. Every prose reading manual has a
    // curated list; glossary decks, SOP/screenshot manuals, recipe cards,
    // slides, and picture-first docs return an empty list (no highlighting).
    //
    // Per-CARD phrases (T8, 2026-08-02): the lookup now asks
    // [barrioCardKeysForUnit], which answers with THIS card's authored
    // phrase set when it has one and falls back to the per-manual list
    // above when it does not. The mechanism shipped with an empty registry,
    // so today every card takes the fallback and rendering is unchanged
    // (proved by `test/barrio_card_key_sets_test.dart`); authored sets then
    // land as pure data, doc by doc, with no further renderer change.
    final keyTerms = barrioCardKeysForUnit(unit.id);

    // Accessibility (rec #12): a collapsed interactive card is one big
    // tap target, so ONLY that state gets a button-role wrapper (its
    // texts merge into one actionable node). Explainer and expanded
    // cards get NO wrapper: their title, body, toggle, and images stay
    // separate granular semantics nodes.
    final wrapAsButton = _isInteractive && !_expanded;

    final card = GestureDetector(
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
            color: BarrioColors.glassFill,
            borderRadius: BorderRadius.circular(BarrioRadii.card),
            border: Border.all(color: _borderColor),
            // One neutral navy lift, no colored glow — matches the de-glowed
            // home bubbles for a consistent premium shadow language.
            boxShadow: barrioSoftShadow(
              y: _isPressed ? 4 : 10,
              blur: _isPressed ? 14 : 24,
              opacity: _isPressed ? 0.14 : 0.10,
            ),
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
                  answerEvidence: answerEvidence,
                  keyTerms: keyTerms,
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
                  answerEvidence: answerEvidence,
                  keyTerms: keyTerms,
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
    if (!wrapAsButton) return card;
    return Semantics(button: true, child: card);
  }

  Color get _badgeColor {
    return switch (widget.unit.type) {
      HandbookUnitType.explainer  => BarrioColors.tealWarm,
      HandbookUnitType.decision   => const Color(0xFF2ECC71),
      HandbookUnitType.checkpoint => BarrioColors.warning,
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
      HandbookUnitType.checkpoint => ('CHECK',  BarrioColors.warning),
    };
    final label = badgeHint ?? defaultLabel;
    // Solid accent chip with a luminance-picked foreground so the label
    // stays legible on the white card (the old pale-tint-on-dark badge
    // relied on bright accent text against a dark surface).
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
            ? Colors.white
            : const Color(0xFF10151F);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.28),
            blurRadius: 5,
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
          color: onColor,
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

  bool get _isSelected => selectedIndex == index;
  bool get _isRevealed => selectedIndex != null;

  /// (border, background) colors for the current reveal state. Split
  /// out of [build] to honor the 80-line engineering bar.
  (Color, Color) _stateColors(bool showCorrect, bool showWrong) {
    if (showCorrect) {
      return (
        const Color(0xFF2ECC71).withValues(alpha: 0.55),
        const Color(0xFF2ECC71).withValues(alpha: 0.10),
      );
    }
    if (showWrong) {
      return (
        BarrioColors.error.withValues(alpha: 0.55),
        BarrioColors.error.withValues(alpha: 0.10),
      );
    }
    return (const Color(0x2216243B), const Color(0x0A16243B));
  }

  /// Merged screen-reader label (rec #12): one button per option, with
  /// the honest state appended after reveal.
  String _semanticsLabel(bool showCorrect, bool showWrong) {
    final letter = String.fromCharCode(0x41 + index);
    var built = '$letter: ${option.label}';
    if (!_isRevealed) return built;
    if (showCorrect) {
      built = _isSelected
          ? '$built, your pick, correct answer'
          : '$built, correct answer';
    } else if (showWrong) {
      built = '$built, your pick, not correct. ${option.feedback}';
    }
    return built;
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = _isSelected;
    final showCorrect = _isRevealed && option.isCorrect;
    final showWrong = isSelected && !option.isCorrect;
    final (borderColor, bgColor) = _stateColors(showCorrect, showWrong);
    final semanticsLabel = _semanticsLabel(showCorrect, showWrong);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: isSelected,
        label: semanticsLabel,
        child: GestureDetector(
        onTap: onTap,
        child: ExcludeSemantics(
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
                      color: BarrioColors.tealDeep,
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
                    const Icon(Icons.cancel, size: 18, color: BarrioColors.error),
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
/// layout is structured. Every unit with images is picture-first: all of
/// its images render above the body text, in source list order, so the
/// reader always sees the picture before the words.
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

  /// Verbatim chapter-end quiz answer phrases for this unit (operator
  /// request 2026-07-26, restyled 2026-07-27): each occurrence in the body
  /// renders as teal-colored, slightly bolder wording (no background wash)
  /// so the answer is easy to scan before the quiz.
  /// Styling only; the body string is never altered (verbatim law). Empty
  /// for cards with no quiz evidence (the default), which render unchanged.
  final List<String> answerEvidence;

  /// Curated key terms to emphasize (color-emphasis, 2026-07-28; rolled out
  /// to all prose manuals 2026-07-29). Each first occurrence per card renders
  /// bold + [BarrioColors.tealInk] (AA on cream), capped at
  /// [kBarrioKeyTermCardCap] spans per card. Styling only; the body string is
  /// never altered (verbatim law). Empty for non-prose docs (glossary decks,
  /// SOP/screenshot manuals, recipe cards, slides, picture-first docs), which
  /// render unchanged.
  final List<String> keyTerms;

  const _UnitBody({
    required this.unit,
    required this.accent,
    this.highlightTerms = const [],
    this.onTermTap,
    this.answerEvidence = const [],
    this.keyTerms = const [],
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
    // First-occurrence-per-card + hard density cap for the key-term pilot:
    // one fresh set per build threaded through every chunk in reading order,
    // so a curated term emphasizes only its first occurrence on the card and
    // the set size caps total emphasized spans at [kBarrioKeyTermCardCap].
    final keyed = <String>{};
    final paragraphs = unit.body.split('\n\n');
    if (unit.images.isEmpty) {
      return _renderRun(paragraphs, linked, keyed);
    }
    // Picture-first for every imaged card (visual-first pass rec #1,
    // 2026-07-24; extended 2026-07-26 from TERM glossary cards to ALL
    // cards): any card that has an image shows the image(s) BEFORE the
    // words, rendered in source list order above the full body. This
    // single return replaces the old per-image afterParagraph
    // interleaving, so no image can double-render. Cards with no images
    // (handled above) are unchanged.
    //
    // Slide grouping (T10, 2026-08-02): a run of consecutive
    // photographs collapses into ONE picture holder that slides, so a
    // card never stacks a tall pile of pictures above its words. Every
    // diagram, and every lone photograph, keeps rendering as its own
    // [_UnitImage], exactly as it does today.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in barrioPhotoSlideGroups(unit.images))
          if (group.length == 1)
            _UnitImage(image: group.single, cardTitle: unit.title)
          else
            _UnitPhotoSlides(
              slides: group,
              cardTitle: unit.title,
              accent: accent,
            ),
        _renderRun(paragraphs, linked, keyed),
      ],
    );
  }

  /// Renders a contiguous paragraph slice. A lone prose paragraph renders
  /// as a single Text; anything else stacks typed blocks with even gaps.
  Widget _renderRun(List<String> paras, Set<String> linked, Set<String> keyed) {
    final blocks = _parseBlocks(paras);
    if (blocks.length == 1 && blocks.first.kind == _BlockKind.prose) {
      return _bodyText(blocks.first.items.first, _style, linked, keyed);
    }
    final children = <Widget>[];
    for (var b = 0; b < blocks.length; b++) {
      if (b > 0) children.add(const SizedBox(height: _blockGap));
      children.add(_renderBlock(blocks[b], linked, keyed));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _renderBlock(_BodyBlock block, Set<String> linked, Set<String> keyed) {
    switch (block.kind) {
      case _BlockKind.prose:
        return _bodyText(block.items.first, _style, linked, keyed);
      case _BlockKind.bullet:
        return _spacedColumn([
          for (final item in block.items)
            _bulletRow(item.trimLeft().substring(2), linked, keyed),
        ]);
      case _BlockKind.numbered:
        return _spacedColumn([
          for (final item in block.items)
            _numberedRow(item.trimLeft(), linked, keyed),
        ]);
      case _BlockKind.table:
        return _table(block.items, linked, keyed);
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

  Widget _bulletRow(String text, Set<String> linked, Set<String> keyed) {
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
        Expanded(child: _bodyText(text, _style, linked, keyed)),
      ],
    );
  }

  Widget _numberedRow(String text, Set<String> linked, Set<String> keyed) {
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
        Expanded(child: _bodyText(body, _style, linked, keyed)),
      ],
    );
  }

  Widget _table(List<String> rows, Set<String> linked, Set<String> keyed) {
    final children = <Widget>[];
    for (var r = 0; r < rows.length; r++) {
      children.add(_tableRow(rows[r].split(' | '), r == 0, linked, keyed));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _tableRow(
      List<String> cells, bool header, Set<String> linked, Set<String> keyed) {
    final cellStyle = _style.copyWith(
      fontSize: 12.5,
      fontWeight: header ? FontWeight.w700 : FontWeight.w400,
      color: header ? BarrioColors.textPrimary : BarrioColors.textSecondary,
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1416243B))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final cell in cells)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _bodyText(cell.trim(), cellStyle, linked, keyed),
              ),
            ),
        ],
      ),
    );
  }

  /// One text chunk: plain, search-highlighted, term-linked,
  /// number-popped, answer-evidence, and/or key-term-emphasized. The
  /// search fold is length-preserving per code unit, so fold-space match
  /// offsets index the original string directly. Precedence (highest
  /// first): search highlights, term links, numeric pops, answer evidence,
  /// then curated key terms. Each lower tier passes the higher tiers'
  /// ranges as [blockedRanges] and drops any overlap whole, so no span
  /// fights another. The text itself is NEVER altered: styling only
  /// (verbatim law).
  Widget _bodyText(
      String text, TextStyle style, Set<String> linked, Set<String> keyed) {
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
    // Answer highlight ranges: any that overlap a search highlight, term
    // link, or numeric pop are dropped whole, so the teal answer wording
    // never fights another span (verbatim substrings, so plain
    // case-sensitive matching).
    final answerRanges = answerEvidence.isEmpty
        ? const <List<int>>[]
        : _answerEvidenceRanges(
            text,
            blockedRanges: [
              ...highlightRanges,
              for (final t in termMatches) [t.start, t.end],
              for (final n in numericMatches) [n.start, n.end],
            ],
          );
    // Key-term emphasis is the LOWEST precedence: any curated term that
    // overlaps a search highlight, term link, numeric pop, or answer span
    // is dropped whole (the existing span wins). First-occurrence-per-card
    // and the [kBarrioKeyTermCardCap] density cap are enforced through the
    // [keyed] set threaded across the card's chunks.
    final keyTermMatches = keyTerms.isEmpty
        ? const <BarrioKeyTermMatch>[]
        : BarrioKeyTermHighlight.matchesIn(
            text,
            keyTerms,
            alreadyUsed: keyed,
            blockedRanges: [
              ...highlightRanges,
              for (final t in termMatches) [t.start, t.end],
              for (final n in numericMatches) [n.start, n.end],
              ...answerRanges,
            ],
          );
    if (highlightRanges.isEmpty &&
        termMatches.isEmpty &&
        numericMatches.isEmpty &&
        answerRanges.isEmpty &&
        keyTermMatches.isEmpty) {
      return Text(text, style: style);
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: _composeSpans(text, highlightRanges, termMatches,
            numericMatches, answerRanges, keyTermMatches, style),
      ),
    );
  }

  /// Exact [start, end) ranges of every answer-evidence phrase in [text],
  /// sorted and merged, dropping whole any range that intersects a
  /// higher-precedence span in [blockedRanges] (search highlight, term
  /// link, or numeric pop). Phrases are true verbatim substrings of the
  /// source body, so matching is a plain case-sensitive indexOf.
  List<List<int>> _answerEvidenceRanges(
    String text, {
    List<List<int>> blockedRanges = const [],
  }) {
    final raw = <List<int>>[];
    for (final phrase in answerEvidence) {
      if (phrase.isEmpty) continue;
      var idx = text.indexOf(phrase);
      while (idx >= 0) {
        final range = <int>[idx, idx + phrase.length];
        if (!_intersectsAny(range, blockedRanges)) raw.add(range);
        idx = text.indexOf(phrase, idx + phrase.length);
      }
    }
    return _mergeRanges(raw);
  }

  static bool _intersectsAny(List<int> range, List<List<int>> ranges) {
    for (final other in ranges) {
      if (range[0] < other[1] && range[1] > other[0]) return true;
    }
    return false;
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

  /// Interleaves the highlight ranges, term-link matches, numeric fact
  /// tokens, answer-evidence spans, and key-term spans (all sorted,
  /// mutually non-overlapping) into one span run over [text].
  List<InlineSpan> _composeSpans(
    String text,
    List<List<int>> highlights,
    List<BarrioTermMatch> terms,
    List<BarrioNumericMatch> numerics,
    List<List<int>> answers,
    List<BarrioKeyTermMatch> keyTermSpans,
    TextStyle style,
  ) {
    // Search highlight: bold navy on a soft tealWarm wash.
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
    // Answer highlight (operator request 2026-07-27): the quiz answer
    // phrase renders as teal-COLORED, slightly bolder wording, NOT a
    // background highlighter wash. tealDeep is the icon-leaf teal that
    // stays legible on the light cream/white card. The verbatim substring
    // renders unchanged; only style is added (no backgroundColor).
    final answerMark = style.copyWith(
      fontWeight: FontWeight.w600,
      color: BarrioColors.tealDeep,
    );
    // Key-term emphasis (color-emphasis, 2026-07-28): a curated domain
    // concept renders bold + tealInk, a bold, vivid AA-compliant deep teal
    // on cream (4.74:1). Bold is the required non-color second cue for
    // accessibility. Colors+weight only; the verbatim substring is
    // unchanged (no backgroundColor).
    final keyTermMark = style.copyWith(
      fontWeight: FontWeight.w700,
      color: BarrioColors.tealInk,
    );
    // Each segment carries its resolved style ([mark]) up front so the
    // render loop stays a single term-link-or-styled-span decision (a
    // term link is a tappable widget span; every other tier is a plain
    // styled TextSpan over the verbatim substring).
    final segments = <_BodySegment>[
      for (final r in highlights) _BodySegment(r[0], r[1], mark: mark),
      for (final t in terms) _BodySegment(t.start, t.end, term: t),
      for (final n in numerics) _BodySegment(n.start, n.end, mark: numberPop),
      for (final r in answers) _BodySegment(r[0], r[1], mark: answerMark),
      for (final k in keyTermSpans)
        _BodySegment(k.start, k.end, mark: keyTermMark),
    ]..sort((a, b) => a.start.compareTo(b.start));
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
      } else {
        spans.add(TextSpan(text: segText, style: seg.mark));
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

/// One styled segment inside a text chunk. [term] non-null renders a
/// tappable term-link widget span; otherwise the segment renders as a
/// styled TextSpan using [mark] (a search highlight, numeric fact pop,
/// quiz answer highlight, or curated key-term emphasis: the caller resolves
/// which style up front). Styling only; the substring is verbatim.
class _BodySegment {
  final int start;
  final int end;
  final BarrioTermMatch? term;
  final TextStyle? mark;
  const _BodySegment(this.start, this.end, {this.term, this.mark});
}

/// Partitions a unit's images into render groups, in source order.
///
/// A group of one renders as a plain [_UnitImage], exactly as every
/// picture does today. A group of two or more is a SLIDE GROUP: a run of
/// consecutive photographs sharing one [_UnitPhotoSlides] holder, shown
/// one at a time.
///
/// The rule is positional and nothing else: consecutive photographs in a
/// unit's image list belong to the same holder, and a diagram ends the
/// run. Diagrams never join a group, because a house-style pictogram and
/// a photograph are different teaching visuals (see
/// [HandbookUnitPhotos]).
///
/// History, kept because the reasoning still governs what may be wired.
/// This function shipped deliberately narrow on 2026-08-02: it grouped
/// ONLY a lead `<folder>/<unit_id>.webp` with its named alternates
/// `_2.webp`, `_3.webp`. The corpus census behind that choice was 744
/// imaged cards, 28 of them already stacking two or more uncaptioned
/// photographs (source-document figures such as the eight
/// `bar_manual/03..10.webp` page scans), and ZERO slide groups. The
/// worry was that unrelated page scans are not alternate views of one
/// subject, and turning those 28 cards into slideshows had never been
/// approved.
///
/// Operator decision, 2026-08-02: approved. Those 28 stacked-figure
/// cards read better as one slideshow than as a tall pile of pictures on
/// a phone, so the rule is now the broad positional one above and the
/// stacked figures become slides. The narrow naming convention still
/// governs how second photographs are AUTHORED (`<unit_id>_2.webp`
/// beside its lead); it is simply no longer what the renderer keys on.
///
/// Degrade rule is absolute and unchanged: a lone photograph is a group
/// of one and renders exactly today's tree, no chips, no dots, no
/// counter.
///
/// Public so the corpus guard in `barrio_photo_slideshow_test.dart` can
/// hold the shipped slide-group count to a deliberate number.
List<List<HandbookUnitImage>> barrioPhotoSlideGroups(
  List<HandbookUnitImage> images,
) {
  final groups = <List<HandbookUnitImage>>[];
  var i = 0;
  while (i < images.length) {
    final lead = images[i];
    final group = <HandbookUnitImage>[lead];
    i++;
    if (!HandbookUnitPhotos.isDiagram(lead)) {
      while (i < images.length && !HandbookUnitPhotos.isDiagram(images[i])) {
        group.add(images[i]);
        i++;
      }
    }
    groups.add(group);
  }
  return groups;
}

/// One content picture inside a unit body: rounded corners, full card
/// width, tap to open the full-screen viewer. The [Image.asset]
/// errorBuilder keeps widget tests (no bundled assets) from throwing.
///
/// Screen-reader contract (rec #12): the literal source caption when
/// the picture has one, else `Photo: <card title>`. Descriptions are
/// never invented (verbatim law).
class _UnitImage extends StatelessWidget {
  final HandbookUnitImage image;

  /// Owning card title, the honest fallback when there is no caption.
  final String cardTitle;

  const _UnitImage({required this.image, required this.cardTitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: true,
            image: true,
            label: image.caption ?? 'Photo: $cardTitle',
            child: GestureDetector(
            onTap: () => BarrioTrainingImageViewer.open(
              context,
              slides: [
                BarrioTrainingImageSlide(
                  assetPath: image.assetPath,
                  caption: image.caption,
                ),
              ],
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
                  color: const Color(0x0F16243B),
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 28,
                    color: BarrioColors.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ),
          ),
          if (image.caption != null) ...[
            const SizedBox(height: 6),
            // Excluded from semantics: the thumbnail's label above IS
            // this literal caption, so it must not read twice (rec #12).
            ExcludeSemantics(
              child: Text(
                image.caption!,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: BarrioColors.textMuted,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A slide group inside a unit body: two or more consecutive
/// photographs sharing one picture holder, shown one at a time.
///
/// Gesture grammar (T10, 2026-08-02), and the reason this holder looks
/// the way it does. The reading deck turns pages with a strongly
/// horizontal drag recognizer plus invisible edge tap zones
/// (`learning_carousel.dart`). An inner horizontal [PageView] would
/// claim those page-turn swipes across most of the visible card, which
/// is exactly the arena regression the 2026-07 fixes cleaned up. So this
/// holder adds NO drag recognizer at all. Slides advance from two small
/// visible chevron chips on the picture's edges: plain child
/// [GestureDetector]s, the same proven recipe as [_BookmarkToggle], so
/// they win only inside their own 32px bounds and every other tap still
/// reaches the reader's edge zones. No wrap-around: each chip is simply
/// absent at its end of the group.
///
/// Tapping the picture itself still opens the full-screen viewer,
/// unchanged, at the slide on screen. Real swipe paging lives there:
/// that is a separate route with none of the deck's recognizers.
///
/// Degrade rule: a card with one photograph or none never reaches this
/// widget ([barrioPhotoSlideGroups] hands it a group of one, rendered by
/// [_UnitImage]), so today's single-picture cards keep today's tree
/// exactly: no chips, no dots, no counter.
class _UnitPhotoSlides extends StatefulWidget {
  /// The run of consecutive photographs, in source order.
  final List<HandbookUnitImage> slides;

  /// Owning card title, the honest fallback when a slide has no caption.
  final String cardTitle;

  /// The owning manual's identity color, used for the active dot (the
  /// same accent the body's numeric fact pops use).
  final Color accent;

  const _UnitPhotoSlides({
    required this.slides,
    required this.cardTitle,
    required this.accent,
  });

  @override
  State<_UnitPhotoSlides> createState() => _UnitPhotoSlidesState();
}

class _UnitPhotoSlidesState extends State<_UnitPhotoSlides> {
  int _index = 0;

  HandbookUnitImage get _slide => widget.slides[_index];

  /// Screen-reader contract (rec #12): the literal source caption when
  /// the picture has one, else `Photo: <card title>` (the same honest
  /// fallback [_UnitImage] uses), then the plain-English position. The
  /// phrasing mirrors the reading deck's 'Card X of Y'.
  String get _semanticLabel {
    final base = _slide.caption ?? 'Photo: ${widget.cardTitle}';
    final stem =
        base.endsWith('.') ? base.substring(0, base.length - 1) : base;
    return '$stem. Photo ${_index + 1} of ${widget.slides.length}';
  }

  /// Moves to [next]. Never wraps: the chips are hidden at the ends, and
  /// this guard means nothing else can walk off either end either.
  void _show(int next) {
    if (next < 0 || next >= widget.slides.length) return;
    HapticFeedback.selectionClick();
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    // Accessibility (rec #12): reduce motion swaps the picture
    // instantly, the same rule the carousel entrance and the staggered
    // options follow. Nothing here ever autoplays.
    final swapDuration = MediaQuery.of(context).disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final caption = _slide.caption;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHolder(context, swapDuration),
          if (caption != null) ...[
            const SizedBox(height: 6),
            // Excluded from semantics: the holder's label above IS this
            // literal caption, so it must not read twice (rec #12).
            ExcludeSemantics(
              child: Text(
                caption,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: BarrioColors.textMuted,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _SlidePositionStrip(
            count: widget.slides.length,
            index: _index,
            accent: widget.accent,
          ),
        ],
      ),
    );
  }

  /// The picture plus its two edge chips. The chips sit ABOVE the
  /// picture's tap target in the stack and hit-test opaque, so a chip
  /// tap advances the slide and never opens the viewer.
  Widget _buildHolder(BuildContext context, Duration swapDuration) {
    final last = widget.slides.length - 1;
    return Semantics(
      button: true,
      image: true,
      label: _semanticLabel,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: () => BarrioTrainingImageViewer.open(
              context,
              slides: [
                for (final slide in widget.slides)
                  BarrioTrainingImageSlide(
                    assetPath: slide.assetPath,
                    caption: slide.caption,
                  ),
              ],
              initialIndex: _index,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AnimatedSwitcher(
                duration: swapDuration,
                child: _buildSlideImage(context),
              ),
            ),
          ),
          if (_index > 0)
            Positioned(
              left: 8,
              child: _SlideChevron(
                forward: false,
                onTap: () => _show(_index - 1),
              ),
            ),
          if (_index < last)
            Positioned(
              right: 8,
              child: _SlideChevron(
                forward: true,
                onTap: () => _show(_index + 1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSlideImage(BuildContext context) {
    return LayoutBuilder(
      // Keyed by asset so the switcher knows one slide replaced another.
      key: ValueKey<String>(_slide.assetPath),
      builder: (context, constraints) {
        // Perf (premium audit A1): decode at the holder's on-screen
        // pixel width, not the source resolution. A full-size decode of
        // a 1400px webp costs megabytes, and a slide group multiplies
        // that by the number of slides.
        final cacheWidth = constraints.hasBoundedWidth
            ? (constraints.maxWidth * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 4096)
            : null;
        return Image.asset(
          _slide.assetPath,
          width: double.infinity,
          fit: BoxFit.fitWidth,
          cacheWidth: cacheWidth,
          errorBuilder: (context, error, stackTrace) => Container(
            width: double.infinity,
            height: 120,
            color: const Color(0x0F16243B),
            child: Icon(
              Icons.image_not_supported_outlined,
              size: 28,
              color: BarrioColors.textMuted.withValues(alpha: 0.6),
            ),
          ),
        );
      },
    );
  }
}

/// One slide-advance chip on a picture edge.
///
/// A plain child tap target on the [_BookmarkToggle] recipe: opaque, so
/// it wins inside its own bounds, and no drag recognizer, so the reading
/// deck's page-turn arena is untouched.
class _SlideChevron extends StatelessWidget {
  /// True for the next-photo chip on the right edge.
  final bool forward;
  final VoidCallback onTap;

  const _SlideChevron({required this.forward, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: forward ? 'Next photo' : 'Previous photo',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // The viewer close-chip recipe: soft cream on a hairline
            // navy border, so it stays legible over any photograph.
            color: BarrioColors.shellMid.withValues(alpha: 0.82),
            border: Border.all(color: const Color(0x2216243B)),
          ),
          child: Icon(
            forward ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
            size: 20,
            color: BarrioColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Position chrome under a slide holder: one dot per slide plus the
/// plain 'K of N' counter.
///
/// The dots are decoration and are excluded from semantics; the counter
/// carries position for screen readers, so it never reads twice.
class _SlidePositionStrip extends StatelessWidget {
  final int count;
  final int index;
  final Color accent;

  const _SlidePositionStrip({
    required this.count,
    required this.index,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ExcludeSemantics(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++)
                Container(
                  margin: const EdgeInsets.only(right: 5),
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == index
                        ? accent.withValues(alpha: 0.9)
                        // Hairline navy on the white card, the same
                        // resting weight as the card's own border.
                        : const Color(0x2216243B),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${index + 1} of $count',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
            color: BarrioColors.textMuted,
          ),
        ),
      ],
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

  bool _motionDecided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_motionDecided) return;
    _motionDecided = true;
    if (MediaQuery.of(context).disableAnimations) {
      // Accessibility (rec #12): reduce motion shows the options
      // settled immediately, no stagger.
      _ctrl.value = 1.0;
      return;
    }
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
