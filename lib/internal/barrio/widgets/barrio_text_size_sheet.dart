// Text-size settings sheet (accessibility pass, rec #12, 2026-07-24).
//
// A quiet bottom sheet reachable from the home header's 'Aa' icon:
// three steps (Standard / Large / Extra large), persisted via
// BarrioTextSizeController and applied shell-wide by BarrioTextScale.
// The preview line renders at the highlighted step's multiplier so the
// choice is honest before it is made; the note says plainly that the
// step adds to the phone's own setting (composition contract in
// ../services/barrio_text_size.dart).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../services/barrio_text_size.dart';
import 'barrio_destination_scaffold.dart';

/// The Barrio text-size stepper sheet.
class BarrioTextSizeSheet extends StatelessWidget {
  final Color accent;

  const BarrioTextSizeSheet({
    super.key,
    this.accent = BarrioColors.tealWarm,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: BarrioColors.shellDeep,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: Color(0x1F16243B))),
      ),
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<BarrioTextSize>(
          valueListenable: BarrioTextSizeController.notifier,
          builder: (context, current, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Text size',
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: BarrioColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final size in BarrioTextSize.values)
                        _SizeOptionRow(
                          size: size,
                          selected: size == current,
                          accent: accent,
                          onTap: () {
                            HapticFeedback.selectionClick();
                            BarrioTextSizeController.set(size);
                          },
                        ),
                      const SizedBox(height: 12),
                      _PreviewLine(size: current, accent: accent),
                      const SizedBox(height: 8),
                      Text(
                        'This adds to the text size set on your phone.',
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 11.5,
                          color: BarrioColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One selectable step row: radio-style semantics (button + selected),
/// step label, and a quiet check on the active step.
class _SizeOptionRow extends StatelessWidget {
  final BarrioTextSize size;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _SizeOptionRow({
    required this.size,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Text size: ${size.label}',
        child: GestureDetector(
          key: ValueKey<String>('barrio_text_size_${size.name}'),
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: selected
                    ? accent.withValues(alpha: 0.10)
                    : const Color(0x0A16243B),
                borderRadius: BorderRadius.circular(BarrioRadii.card),
                border: Border.all(
                  color: selected
                      ? accent.withValues(alpha: 0.55)
                      : BarrioColors.hairline,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      size.label,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                        color: selected
                            ? BarrioColors.textPrimary
                            : BarrioColors.textSecondary,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_rounded, size: 18, color: accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The honest preview: one sample line in the reader body style. The
/// sheet lives under BarrioTextScale and a tapped step applies
/// immediately, so this line ALWAYS renders at the real effective
/// scale (system setting x chosen step): what you see here is exactly
/// how card text reads after the sheet closes. No simulated
/// screenshot, just the live scaling math.
class _PreviewLine extends StatelessWidget {
  final BarrioTextSize size;
  final Color accent;

  const _PreviewLine({required this.size, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x0A16243B),
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(color: BarrioColors.hairline),
      ),
      child: Text(
        'Card text will read like this.',
        style: GoogleFonts.ibmPlexSans(
          fontSize: 13.5,
          height: 1.62,
          color: BarrioColors.textSecondary,
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
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
