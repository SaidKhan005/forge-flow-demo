// A-Z jump index for the glossary manuals (2026-07-23 operator-approved
// rec #6), plus the photo-grid browse view (visual-first pass, rec #4).
//
// A bottom sheet opened from the training reader's header index icon on
// the three TERM manuals only. It lists every card title alphabetically
// under letter headers computed at runtime from the titles themselves.
// Presentation-only: the verbatim content (including chapter titles
// like "8 to C") is never renamed or touched. A section split across
// several cards is listed once under the first card's title, jumping to
// that card.
//
// Run folding reads RUN METADATA (runIndex/runLength), never the title
// text. Continuation cards used to be titled "<base> (cont.)", so a
// regex could strip the suffix and recover the base; they are now
// titled for what each card teaches
// (tool/barrio_training_card_titles.json), and no string test can
// recover a run from an authored title. runIndex was always the honest
// signal: do not reintroduce the suffix regex.
//
// Photos view: on manuals whose cards carry bundled photos (today the
// two food glossaries; Words To Know has none, so it shows no toggle),
// an "A to Z" / "Photos" toggle adds a two-column photo grid. Each tile
// is the card's own bundled picture with the term on a SOLID strip
// below it (never text composited over the photo). Terms without a
// picture are simply absent from the grid: no placeholder art. The A-Z
// list stays the complete index either way. Tapping a tile jumps to
// the card exactly like the A-Z row does. Tiles carry no read-state or
// progress: the A-Z rows show none, and the grid mirrors them exactly
// (Metric Honesty).
//
// Letter-rail decision (operator dislikes jam-packed UI): no edge rail.
// Twenty-plus rail letters at 390pt width would land under 16px per tap
// target; clearly separated letter headers in one smooth scroll list
// stay calm and legible instead.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/company_handbook_content.dart';
import '../content/training/barrio_training_doc.dart';
import '../search/barrio_training_search.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_row_thumbnail.dart';

/// One tappable index entry: the base card title and the flat-deck
/// page of the first card carrying it, plus the term's first bundled
/// photo when its card run has one (visual-first pass, rec #9). A term
/// whose run carries no picture has a null [assetPath] and its A-Z row
/// stays plain text (Metric Honesty: no placeholder art).
class TrainingIndexEntry {
  final String title;
  final int page;

  /// First bundled image asset across the term's card run (first card of
  /// the run with a picture wins), or null when the run has no photo.
  final String? assetPath;

  const TrainingIndexEntry({
    required this.title,
    required this.page,
    this.assetPath,
  });
}

/// One letter section of the index ('#' collects titles that do not
/// start with a letter, e.g. 86'D and 911).
class TrainingIndexGroup {
  final String letter;
  final List<TrainingIndexEntry> entries;

  const TrainingIndexGroup({required this.letter, required this.entries});
}

/// The three folded lookups both index views are built from: display
/// title, flat-deck jump page, and thumbnail asset, all keyed by the
/// folded title of a run's first card.
typedef _IndexWalk = ({
  Map<String, String> titleByKey,
  Map<String, int> pageByKey,
  Map<String, String> assetByKey,
});

/// One pass over [doc]'s flat deck, folding each split run into the
/// entry its first card opened.
///
/// Shared by both index views on purpose: the A-Z list and the photo
/// grid must never disagree about which cards belong to which term, and
/// two copies of this walk would eventually drift.
///
/// A card with runIndex > 1 contributes no entry of its own; its photo
/// accumulates into the run's entry, so a term whose picture sits on a
/// later card of the run still shows a thumbnail. Run metadata, not the
/// title text, decides this (see the library comment).
_IndexWalk _walkIndexRuns(BarrioTrainingDoc doc) {
  final titleByKey = <String, String>{};
  final pageByKey = <String, int>{};
  final assetByKey = <String, String>{};
  var page = 0;
  for (final chapter in doc.chapters) {
    // A run never spans chapters, so a chapter boundary closes any open
    // one. An untitled first card opens no run: its continuations are
    // skipped with it rather than folding into the previous term.
    String? runKey;
    for (final unit in chapter.units) {
      if (unit.runIndex == 1) {
        final base = unit.title.trim();
        runKey = base.isEmpty ? null : BarrioTrainingSearch.fold(base);
        if (runKey != null) {
          titleByKey.putIfAbsent(runKey, () => base);
          pageByKey.putIfAbsent(runKey, () => page);
        }
      }
      // Photo-only: the A-Z index and its photo grid show real photos, not
      // diagram pictograms (a pictogram is not a photo of the term).
      final photo = unit.firstPhoto;
      if (runKey != null && photo != null) {
        assetByKey.putIfAbsent(runKey, () => photo.assetPath);
      }
      page++;
    }
  }
  return (
    titleByKey: titleByKey,
    pageByKey: pageByKey,
    assetByKey: assetByKey,
  );
}

/// Builds the alphabetical index for [doc] at runtime.
///
/// Walks the flat deck in reading order, folds each split run into its
/// first card's title, sorts the unique titles case- and
/// diacritic-insensitively, and groups them by first letter. Digits and
/// other non-letters group under '#', which sorts first, matching the
/// glossaries' own "8 to C" reading order.
List<TrainingIndexGroup> buildTrainingIndexGroups(BarrioTrainingDoc doc) {
  final (:titleByKey, :pageByKey, :assetByKey) = _walkIndexRuns(doc);
  final sortedKeys = titleByKey.keys.toList()..sort();
  // Folded keys sort digits before letters, so group insertion order is
  // already '#' first, then A to Z.
  final grouped = <String, List<TrainingIndexEntry>>{};
  for (final key in sortedKeys) {
    grouped.putIfAbsent(_letterFor(key), () => []).add(
          TrainingIndexEntry(
            title: titleByKey[key]!,
            page: pageByKey[key]!,
            assetPath: assetByKey[key],
          ),
        );
  }
  return <TrainingIndexGroup>[
    for (final e in grouped.entries)
      TrainingIndexGroup(letter: e.key, entries: e.value),
  ];
}

/// Header letter for a folded (lowercase) sort key.
String _letterFor(String foldedKey) {
  final u = foldedKey.codeUnitAt(0);
  if (u >= 0x61 && u <= 0x7A) return String.fromCharCode(u - 0x20);
  return '#';
}

/// One photo-grid tile: a term with a bundled card photo. [page] is the
/// same flat-deck jump target the A-Z entry for this term uses.
class TrainingIndexPhotoEntry {
  final String title;
  final int page;
  final String assetPath;

  const TrainingIndexPhotoEntry({
    required this.title,
    required this.page,
    required this.assetPath,
  });
}

/// Builds the Photos-view entries for [doc]: the same folded, sorted
/// term list as [buildTrainingIndexGroups], kept ONLY where the term's
/// card run carries a bundled photo (first image of the run wins, in
/// reading order). Terms without a picture are absent by design: no
/// placeholder art. An empty result means the manual has no photo view
/// at all (e.g. Words To Know).
List<TrainingIndexPhotoEntry> buildTrainingIndexPhotoEntries(
  BarrioTrainingDoc doc,
) {
  final (:titleByKey, :pageByKey, :assetByKey) = _walkIndexRuns(doc);
  final sortedKeys = assetByKey.keys.toList()..sort();
  return <TrainingIndexPhotoEntry>[
    for (final key in sortedKeys)
      TrainingIndexPhotoEntry(
        title: titleByKey[key]!,
        page: pageByKey[key]!,
        assetPath: assetByKey[key]!,
      ),
  ];
}

/// Whether [doc] earns the Photos browse view (2026-07-31). The photo grid
/// only reads as premium when photos cover a healthy share of the manual's
/// terms; a half-empty grid looks worse than none. So the browse appears
/// only where photos back at least half the folded terms. The two food
/// glossaries clear this easily; a mostly-text glossary that happens to
/// carry a few concrete photos (e.g. Words To Know) keeps the plain A-Z
/// sheet while its cards still show those photos inline.
bool trainingDocHasPhotoBrowse(BarrioTrainingDoc doc) {
  final termCount = buildTrainingIndexGroups(doc)
      .fold<int>(0, (sum, g) => sum + g.entries.length);
  if (termCount == 0) return false;
  return buildTrainingIndexPhotoEntries(doc).length * 2 >= termCount;
}

/// The two ways to browse the index sheet.
enum _IndexView { az, photos }

/// One row of the flattened A-Z list: a letter header, or the term
/// entry under it.
///
/// A DATA row, not a widget (audit A7). The list used to be built as a
/// `List<Widget>` and then indexed from `itemBuilder`, which quietly
/// defeated the builder: every header and every one of the 100+ term
/// rows (each with its own tap closure) was constructed on every sheet
/// build, whether or not it was on screen. Flattening to data and
/// constructing in `itemBuilder` matches what the sibling photo grid
/// below already does.
class _IndexRow {
  /// Set on a letter header; null on a term row.
  final String? letter;

  /// Set on a term row; null on a letter header.
  final TrainingIndexEntry? entry;

  const _IndexRow.header(String this.letter) : entry = null;

  const _IndexRow.entry(TrainingIndexEntry this.entry) : letter = null;
}

/// Flattens [groups] into the header/entry row sequence the A-Z list
/// scrolls, in the same order the eager widget list produced: each
/// group's letter header, then that group's entries.
List<_IndexRow> _flattenIndexRows(List<TrainingIndexGroup> groups) {
  return <_IndexRow>[
    for (final group in groups) ...[
      _IndexRow.header(group.letter),
      for (final entry in group.entries) _IndexRow.entry(entry),
    ],
  ];
}

/// The A-Z index bottom sheet for one glossary manual, with the Photos
/// grid view on manuals whose cards carry bundled photos.
class TrainingDocIndexSheet extends StatefulWidget {
  final BarrioTrainingDoc doc;
  final Color accent;

  /// Called with the flat-deck page of the tapped entry. The caller
  /// closes the sheet and jumps the deck in place. A photo tile emits
  /// exactly the same page its A-Z entry does.
  final ValueChanged<int> onEntryTap;

  const TrainingDocIndexSheet({
    super.key,
    required this.doc,
    required this.accent,
    required this.onEntryTap,
  });

  @override
  State<TrainingDocIndexSheet> createState() => _TrainingDocIndexSheetState();
}

class _TrainingDocIndexSheetState extends State<TrainingDocIndexSheet> {
  late final List<TrainingIndexGroup> _groups =
      buildTrainingIndexGroups(widget.doc);

  /// The A-Z list as flat header/entry data, built once (audit A7).
  late final List<_IndexRow> _rows = _flattenIndexRows(_groups);

  late final List<TrainingIndexPhotoEntry> _photoEntries =
      buildTrainingIndexPhotoEntries(widget.doc);

  /// A to Z is always the default; the sheet opens on the complete list.
  _IndexView _view = _IndexView.az;

  /// Whether this manual earns the Photos browse (see the shared rule in
  /// [trainingDocHasPhotoBrowse]).
  late final bool _hasPhotoBrowse = trainingDocHasPhotoBrowse(widget.doc);

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final termCount =
        _groups.fold<int>(0, (sum, g) => sum + g.entries.length);
    final showPhotos = _view == _IndexView.photos && _hasPhotoBrowse;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Container(
        decoration: const BoxDecoration(
          color: BarrioColors.shellDeep,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: Color(0x1F16243B))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            _SheetHeader(
              // The count states a fact about the visible view: the
              // full term list, or how many terms carry a photo.
              termCount: showPhotos ? _photoEntries.length : termCount,
              countNoun: showPhotos ? 'photos' : 'terms',
              accent: accent,
            ),
            // The toggle exists only where the photo browse earns its
            // place (see [_hasPhotoBrowse]); sparse or photo-less manuals
            // keep the plain A-Z sheet.
            if (_hasPhotoBrowse)
              _ViewToggle(
                view: _view,
                accent: accent,
                onChanged: (view) => setState(() => _view = view),
              ),
            Expanded(child: showPhotos ? _buildGrid() : _buildList()),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    // One flat DATA list (headers + entries) walked once at mount; the
    // widgets themselves build on demand, so a 100+ term glossary
    // constructs only the rows on screen (audit A7).
    return ListView.builder(
      key: const ValueKey<String>('training_doc_index_list'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      itemCount: _rows.length,
      itemBuilder: (context, index) {
        final row = _rows[index];
        final letter = row.letter;
        if (letter != null) {
          return _LetterHeader(letter: letter, accent: widget.accent);
        }
        final entry = row.entry!;
        return _EntryRow(
          entry: entry,
          onTap: () => widget.onEntryTap(entry.page),
        );
      },
    );
  }

  Widget _buildGrid() {
    // Lazy two-column grid: the dishes glossary carries 100+ photos,
    // so tiles build on demand exactly like the A-Z rows.
    return GridView.builder(
      key: const ValueKey<String>('training_doc_index_photo_grid'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.84,
      ),
      itemCount: _photoEntries.length,
      itemBuilder: (context, index) {
        final entry = _photoEntries[index];
        return _PhotoTile(
          entry: entry,
          onTap: () => widget.onEntryTap(entry.page),
        );
      },
    );
  }
}

/// Small rounded drag handle at the top of the sheet.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// Sheet title plus the honest count of what the visible view lists
/// (a fact from the list: 'N terms' or 'N photos').
class _SheetHeader extends StatelessWidget {
  final int termCount;
  final String countNoun;
  final Color accent;

  const _SheetHeader({
    required this.termCount,
    required this.countNoun,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    // Accessibility (rec #12): both texts sit in flexible slots so
    // large text scales wrap instead of overflowing the header row.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                'Jump to a term',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: BarrioColors.textPrimary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              '$termCount $countNoun',
              textAlign: TextAlign.right,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                letterSpacing: 0.5,
                color: accent.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The quiet "A to Z" / "Photos" two-way toggle. Two small pills in the
/// house pill idiom (mono uppercase, accent when selected); the sheet
/// stays calm: no segmented-control chrome.
class _ViewToggle extends StatelessWidget {
  final _IndexView view;
  final Color accent;
  final ValueChanged<_IndexView> onChanged;

  const _ViewToggle({
    required this.view,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Row(
        children: [
          _TogglePill(
            key: const ValueKey<String>('training_doc_index_view_az'),
            label: 'A TO Z',
            selected: view == _IndexView.az,
            accent: accent,
            onTap: () => onChanged(_IndexView.az),
          ),
          const SizedBox(width: 8),
          _TogglePill(
            key: const ValueKey<String>('training_doc_index_view_photos'),
            label: 'PHOTOS',
            selected: view == _IndexView.photos,
            accent: accent,
            onTap: () => onChanged(_IndexView.photos),
          ),
        ],
      ),
    );
  }
}

/// One toggle pill. Selected = accent tint + accent border; unselected
/// stays quiet in the sheet's own neutrals.
class _TogglePill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _TogglePill({
    super.key,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Accessibility (rec #12): button role + honest selected state.
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.55)
                  : const Color(0x2916243B),
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: selected ? accent : BarrioColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// One photo-grid tile: the card's bundled picture on top, the term on
/// a SOLID strip below it. The label never composites over the photo,
/// so it stays readable on any picture. Tiles carry no read-state or
/// progress, mirroring the A-Z rows exactly (Metric Honesty).
class _PhotoTile extends StatelessWidget {
  final TrainingIndexPhotoEntry entry;
  final VoidCallback onTap;

  const _PhotoTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Half the sheet width per column: decode at display size so a
    // 100+ photo glossary never holds full-size bitmaps in memory.
    final cacheWidth = (MediaQuery.sizeOf(context).width / 2 * dpr).round();
    // Accessibility (rec #12): one button per tile, labeled with the
    // FULL term (the visible strip may ellipsize); the photo itself
    // stays unlabeled (no invented descriptions).
    return Semantics(
      button: true,
      image: true,
      label: entry.title,
      child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Image.asset(
                entry.assetPath,
                fit: BoxFit.cover,
                cacheWidth: cacheWidth > 0 ? cacheWidth : null,
                // Same fallback posture as the reader cards: a quiet
                // solid block, never a crash (also the widget-test
                // path, where bundled assets do not load).
                errorBuilder: (_, __, ___) => Container(
                  color: BarrioColors.shellSurface,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    size: 22,
                    color: BarrioColors.textMuted.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            // SOLID label strip: fully opaque surface color under the
            // photo, one steady line per tile.
            Container(
              color: BarrioColors.shellSurface,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                entry.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: BarrioColors.textPrimary,
                ),
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

/// Clearly separated letter header: accent letter plus a thin rule.
class _LetterHeader extends StatelessWidget {
  final String letter;
  final Color accent;

  const _LetterHeader({required this.letter, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 14, 0, 6),
      child: Row(
        children: [
          Text(
            letter,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: accent.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: const Color(0x1A16243B),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tappable term row.
class _EntryRow extends StatelessWidget {
  final TrainingIndexEntry entry;
  final VoidCallback onTap;

  const _EntryRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final asset = entry.assetPath;
    final title = Text(
      entry.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.ibmPlexSans(
        fontSize: 14,
        color: BarrioColors.textPrimary,
      ),
    );
    // Visual-first pass (rec #9): a term whose card carries a photo
    // leads its A-Z row with a small thumbnail of it, so a visual
    // learner recognizes the term before tapping. A term with no photo
    // keeps its plain text row exactly (Metric Honesty).
    final Widget content = asset == null
        ? Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            child: title,
          )
        : Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                BarrioRowThumbnail(assetPath: asset),
                const SizedBox(width: 12),
                Expanded(child: title),
              ],
            ),
          );
    // Accessibility (rec #12): a proper button whose label always
    // carries the FULL term even when the visible line ellipsizes; the
    // thumbnail stays decorative (it is inside ExcludeSemantics and is
    // itself semantics-excluded), so it never adds a duplicate node.
    return Semantics(
      button: true,
      label: entry.title,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ExcludeSemantics(child: content),
      ),
    );
  }
}
