// Tap-to-define definition sheet (operator-approved rec #9,
// 2026-07-23). Opened when a linked TERM inside a culinary manual's
// card body is tapped: shows the term title, its picture (if the
// glossary card has one), the VERBATIM definition body, and an
// 'Open in manual' link that deep-links to the term's own card.
//
// The body text is rendered word-for-word from the glossary card
// (verbatim law): this sheet formats, it never rewrites.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/company_handbook_content.dart';
import '../services/barrio_term_links.dart';
import 'barrio_destination_scaffold.dart';

/// Bottom sheet showing one TERM glossary card.
class BarrioTermDefinitionSheet extends StatelessWidget {
  final BarrioTermCard card;
  final Color accent;

  /// Called when the reader taps 'Open in manual'. The owner closes
  /// the sheet and deep-links to the term's card.
  final VoidCallback onOpenInManual;

  const BarrioTermDefinitionSheet({
    super.key,
    required this.card,
    required this.accent,
    required this.onOpenInManual,
  });

  @override
  Widget build(BuildContext context) {
    final unit = card.unit;
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
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    unit.title,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: BarrioColors.textPrimary,
                    ),
                  ),
                  if (unit.firstPhoto != null) ...[
                    const SizedBox(height: 12),
                    // Screen-reader label (rec #12): the literal source
                    // caption when present, else 'Photo: <term>'. Photo-only:
                    // a diagram pictogram is never shown in the term sheet.
                    Semantics(
                      image: true,
                      label: unit.firstPhoto!.caption ?? 'Photo: ${unit.title}',
                      child: _termImage(unit.firstPhoto!.assetPath),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    unit.body,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 13.5,
                      height: 1.62,
                      color: BarrioColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: _OpenInManualLink(accent: accent, onTap: onOpenInManual),
          ),
        ],
      ),
    );
  }

  /// The glossary card's picture. The errorBuilder keeps widget tests
  /// (no bundled assets) from throwing, same as the lesson cards.
  Widget _termImage(String assetPath) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.asset(
        assetPath,
        width: double.infinity,
        height: 160,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => Container(
          width: double.infinity,
          height: 100,
          color: const Color(0x0F16243B),
          child: Icon(
            Icons.image_not_supported_outlined,
            size: 26,
            color: BarrioColors.textMuted.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _OpenInManualLink extends StatelessWidget {
  final Color accent;
  final VoidCallback onTap;

  const _OpenInManualLink({required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Accessibility (rec #12): a proper button role; the visible text
    // merges in as the label.
    return MergeSemantics(
      child: Semantics(
      button: true,
      child: GestureDetector(
      key: const ValueKey<String>('barrio_term_open_in_manual'),
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book_rounded, size: 16, color: accent),
            const SizedBox(width: 8),
            Text(
              'Open in manual',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: accent,
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
