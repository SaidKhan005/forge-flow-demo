// Manage one of the reader's own marks (Kindle-style highlights,
// Slice C, 2026-08-06). Opened by tapping a highlight in a card body,
// or its note glyph.
//
// Three things a reader can do to a mark they already made: change its
// colour, write or edit a note on it, and remove it. Nothing else: the
// words a mark covers are fixed when it is made, so there is no "edit"
// state to fall into and no confirm dialog to dismiss.
//
// Removal is a single tap with an Undo in the SnackBar, not a
// "are you sure?" gate. A confirm dialog on a reversible action trains
// people to tap through dialogs; an Undo tells the truth about what
// just happened and offers the way back.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/barrio_highlight_anchors.dart';
import '../services/barrio_highlights_service.dart';
import 'barrio_destination_scaffold.dart';

/// Plain-English name of each marker colour token, for the reader and
/// for a screen reader. The stored tokens are internal words ('fresh',
/// 'steel'); nobody should ever have to learn them.
const Map<String, String> kBarrioHighlightColorNames = <String, String>{
  'gold': 'Gold',
  'fresh': 'Green',
  'plum': 'Purple',
  'steel': 'Blue',
};

/// The colour name shown for [token], falling back to the default
/// marker's name for a token this build cannot paint.
String barrioHighlightColorName(String token) =>
    kBarrioHighlightColorNames[token] ??
    kBarrioHighlightColorNames[kBarrioHighlightDefaultColor]!;

/// The removal action's red.
///
/// [BarrioColors.error] is the house red, but at 3.78:1 on the sheet's
/// cream surface it sits under the 4.5:1 AA floor for 13px text. This is
/// that red pulled toward black until it clears the floor (4.87:1 on
/// cream, measured in `test/barrio_highlight_manage_test.dart`), which
/// also reads as the quieter, less alarming tone this action wants: one
/// tap, fully undoable, not a warning.
const Color kBarrioHighlightRemoveRed = Color(0xFFBD3E31);

/// Bottom sheet for managing one highlight.
class BarrioHighlightActionsSheet extends StatefulWidget {
  /// The mark being managed. Its colour is the one shown ringed when the
  /// sheet opens; its note decides whether the note row reads "Add" or
  /// "Edit".
  final BarrioHighlight highlight;

  /// The manual's accent, used for the note row's glyph so the sheet
  /// reads as part of this manual.
  final Color accent;

  /// A marker colour the reader picked. Called with the token; the
  /// owner persists it. The ring moves immediately either way, so the
  /// sheet never looks like it ignored a tap.
  final ValueChanged<String> onColorPicked;

  /// The reader wants to write or edit the note. The owner closes this
  /// sheet and opens the note editor.
  final VoidCallback onNoteTap;

  /// The reader wants the mark gone. The owner closes this sheet,
  /// removes it, and offers Undo.
  final VoidCallback onRemove;

  const BarrioHighlightActionsSheet({
    super.key,
    required this.highlight,
    required this.accent,
    required this.onColorPicked,
    required this.onNoteTap,
    required this.onRemove,
  });

  @override
  State<BarrioHighlightActionsSheet> createState() =>
      _BarrioHighlightActionsSheetState();
}

class _BarrioHighlightActionsSheetState
    extends State<BarrioHighlightActionsSheet> {
  /// The colour shown as chosen. Held here so the ring moves on the
  /// frame the reader taps, without waiting for the store or for the
  /// owner to rebuild this sheet.
  late String _color = widget.highlight.color;

  void _pick(String token) {
    if (token == _color) return;
    setState(() => _color = token);
    widget.onColorPicked(token);
  }

  @override
  Widget build(BuildContext context) {
    final note = widget.highlight.note.trim();
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.72,
      ),
      decoration: const BoxDecoration(
        color: BarrioColors.shellDeep,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0x1F16243B))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SheetHandle(),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BarrioHighlightQuote(highlight: widget.highlight),
                  const SizedBox(height: 18),
                  Text(
                    'Marker colour',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: BarrioColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 10),
                  _ColorDots(selected: _color, onPick: _pick),
                  const SizedBox(height: 18),
                  _SheetAction(
                    icon: Icons.sticky_note_2_rounded,
                    color: widget.accent,
                    label: note.isEmpty ? 'Add note' : 'Edit note',
                    detail: note.isEmpty ? null : _oneLine(note),
                    onTap: widget.onNoteTap,
                    valueKey: 'barrio_highlight_note_action',
                  ),
                  const SizedBox(height: 8),
                  _SheetAction(
                    icon: Icons.delete_outline_rounded,
                    color: kBarrioHighlightRemoveRed,
                    label: 'Remove highlight',
                    onTap: widget.onRemove,
                    valueKey: 'barrio_highlight_remove_action',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A note collapsed onto one line for the preview row: the reader's
  /// own words, never rewritten, just unwrapped.
  static String _oneLine(String note) =>
      note.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The words this mark covers, quoted on their own marker wash.
///
/// Shared with the note editor so both sheets say "this one" the same
/// way: the reader should never have to guess which mark they opened.
class BarrioHighlightQuote extends StatelessWidget {
  final BarrioHighlight highlight;

  /// How much of a long passage to show before trailing off.
  final int maxLines;

  const BarrioHighlightQuote({
    super.key,
    required this.highlight,
    this.maxLines = 3,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: barrioHighlightWash(highlight.color),
        borderRadius: BorderRadius.circular(BarrioRadii.chip),
      ),
      child: Text(
        highlight.plainText,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: GoogleFonts.ibmPlexSans(
          fontSize: 13.5,
          height: 1.5,
          color: BarrioColors.textPrimary,
        ),
      ),
    );
  }
}

/// The four marker colours, the current one ringed.
class _ColorDots extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onPick;

  const _ColorDots({required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final token in kBarrioHighlightColorTokens) ...[
          _ColorDot(
            token: token,
            chosen: token == selected,
            onTap: () => onPick(token),
          ),
          const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _ColorDot extends StatelessWidget {
  final String token;
  final bool chosen;
  final VoidCallback onTap;

  const _ColorDot({
    required this.token,
    required this.chosen,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = barrioHighlightColorName(token);
    final ink = barrioHighlightNoteGlyphColor(token);
    // A fixed 44px target: the dot must stay tappable at every text
    // scale, and a colour swatch carries no text to scale anyway.
    return Semantics(
      button: true,
      selected: chosen,
      label: '$name marker',
      child: GestureDetector(
        key: ValueKey<String>('barrio_highlight_color_$token'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: barrioHighlightWash(token),
            border: Border.all(
              color: chosen ? ink : BarrioColors.hairline,
              width: chosen ? 2.5 : 1,
            ),
          ),
          // The tick is the non-colour second cue: which marker is on
          // must not be readable by colour alone.
          child: chosen
              ? Icon(Icons.check_rounded, size: 20, color: ink)
              : null,
        ),
      ),
    );
  }
}

/// One tappable row of the sheet: glyph, label, and an optional quiet
/// second line (today, the note preview).
class _SheetAction extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String? detail;
  final VoidCallback onTap;
  final String valueKey;

  const _SheetAction({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
    required this.valueKey,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final preview = detail;
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: GestureDetector(
          key: ValueKey<String>(valueKey),
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            decoration: BoxDecoration(
              color: BarrioColors.shellMid,
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              border: Border.all(color: BarrioColors.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 19, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      if (preview != null && preview.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 12.5,
                            height: 1.35,
                            fontStyle: FontStyle.italic,
                            color: BarrioColors.textMuted,
                          ),
                        ),
                      ],
                    ],
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

/// The house grab handle every Barrio bottom sheet wears.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
