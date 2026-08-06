// Write a note on one of the reader's own marks (Kindle-style
// highlights, Slice C, 2026-08-06). Opened from the highlight actions
// sheet.
//
// Keyboard-aware by construction: the sheet is scroll-controlled and
// padded by the view insets, so the field and both buttons stay above
// the keyboard on a short phone. The words the note is about are quoted
// on their own marker wash right above the field, so a reader who
// reopened the wrong mark can see it before they type.
//
// Visual recipe mirrors the reader's existing web-search input (Playfair
// title, IBM Plex Sans field on the raised surface, quiet Cancel beside
// a filled accent action) rather than inventing a second look.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/barrio_highlights_service.dart';
import 'barrio_destination_scaffold.dart';
import 'barrio_highlight_actions_sheet.dart';

/// Bottom sheet for writing or editing one highlight's note.
///
/// Pops the note text on Save (an empty field saves an empty note,
/// which is how a reader deletes one), and null on Cancel or on a
/// dismiss, which changes nothing.
class BarrioHighlightNoteSheet extends StatefulWidget {
  /// The mark the note belongs to. Its current note seeds the field and
  /// its colour paints the quote.
  final BarrioHighlight highlight;

  /// The manual's accent: the title glyph, the caret, the focused
  /// border, and the Save button.
  final Color accent;

  const BarrioHighlightNoteSheet({
    super.key,
    required this.highlight,
    required this.accent,
  });

  @override
  State<BarrioHighlightNoteSheet> createState() =>
      _BarrioHighlightNoteSheetState();
}

class _BarrioHighlightNoteSheetState extends State<BarrioHighlightNoteSheet> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.highlight.note);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    // Height budget is what is left ABOVE the keyboard, not the whole
    // screen: a sheet sized to the screen would put its buttons behind
    // the keys on a short phone.
    final available = MediaQuery.sizeOf(context).height - insets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets),
      child: Container(
        constraints: BoxConstraints(maxHeight: available * 0.92),
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
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.sticky_note_2_rounded,
                          size: 20,
                          color: accent,
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Semantics(
                            header: true,
                            child: Text(
                              'Your note',
                              style: GoogleFonts.playfairDisplay(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: BarrioColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Kept on this device, for you.',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12.5,
                        height: 1.4,
                        color: BarrioColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 14),
                    BarrioHighlightQuote(
                      highlight: widget.highlight,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      key: const ValueKey<String>('barrio_highlight_note_field'),
                      controller: _controller,
                      autofocus: true,
                      minLines: 3,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 14.5,
                        height: 1.5,
                        color: BarrioColors.textPrimary,
                      ),
                      cursorColor: accent,
                      decoration: InputDecoration(
                        hintText: 'What do you want to remember?',
                        hintStyle: GoogleFonts.ibmPlexSans(
                          fontSize: 14.5,
                          color: BarrioColors.textMuted,
                        ),
                        filled: true,
                        fillColor: BarrioColors.shellSurface,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 14,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(BarrioRadii.card),
                          borderSide: BorderSide(
                            color:
                                BarrioColors.textMuted.withValues(alpha: 0.25),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(BarrioRadii.card),
                          borderSide: BorderSide(color: accent, width: 2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const ValueKey<String>('barrio_highlight_note_cancel'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Cancel',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: BarrioColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  _NoteSaveButton(accent: accent, onTap: _save),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sheet's primary action: a filled accent Save, with a
/// luminance-picked foreground so the label stays legible on any
/// manual's accent. Same recipe as the reader's web-search action.
class _NoteSaveButton extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _NoteSaveButton({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final onAccent = barrioOnAccent(accent);
    return Semantics(
      button: true,
      label: 'Save note',
      child: Material(
        color: accent,
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        child: InkWell(
          key: const ValueKey<String>('barrio_highlight_note_save'),
          borderRadius: BorderRadius.circular(BarrioRadii.card),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_rounded, size: 16, color: onAccent),
                const SizedBox(width: 5),
                Text(
                  'Save',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: onAccent,
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
