import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'barrio_destination_scaffold.dart';
import '../routes/barrio_preview_role.dart';

/// Compact access-intent banner for Barrio destination screens.
///
/// Shows the current preview role, the intended audiences, and a
/// Phase 9 handoff note. Styled as a glassmorphism panel that
/// matches the destination's accent color.
class BarrioAccessIntentBanner extends StatelessWidget {
  final BarrioPreviewRole previewRole;
  final List<String> intendedAudiences;
  final Color accentColor;

  const BarrioAccessIntentBanner({
    super.key,
    required this.previewRole,
    required this.intendedAudiences,
    this.accentColor = BarrioColors.tealWarm,
  });

  @override
  Widget build(BuildContext context) {
    final isIntended =
        intendedAudiences.any(
            (a) => a.toLowerCase() == previewRole.label.toLowerCase()) ||
        previewRole == BarrioPreviewRole.admin;

    final borderColor = isIntended
        ? accentColor.withValues(alpha: 0.25)
        : const Color(0xFFF39C12).withValues(alpha: 0.20);

    final iconColor = isIntended
        ? accentColor
        : const Color(0xFFF39C12);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0x10FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: accentColor.withValues(alpha: 0.08),
            blurRadius: 14,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            isIntended ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 15,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  text: TextSpan(
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 11,
                      color: BarrioColors.textMuted,
                      letterSpacing: 0.2,
                    ),
                    children: [
                      const TextSpan(text: 'Preview: '),
                      TextSpan(
                        text: previewRole.label,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: accentColor,
                        ),
                      ),
                      TextSpan(
                        text: isIntended
                            ? '  ·  Intended for this role'
                            : '  ·  Not intended for this role',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Intended: ${intendedAudiences.join(", ")}  |  Real gating: Phase 9',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    color: BarrioColors.textMuted.withValues(alpha: 0.5),
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
