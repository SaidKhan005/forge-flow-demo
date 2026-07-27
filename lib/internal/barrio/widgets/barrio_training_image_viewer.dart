import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'barrio_destination_scaffold.dart';

/// Full-screen viewer for a training content picture.
///
/// Warm cream backdrop, pinch-zoom via [InteractiveViewer], a close button in a
/// soft circular chip, and an optional literal source caption on a cream pill.
/// No looping animation. Opened by tapping an inline image in a training lesson
/// card.
class BarrioTrainingImageViewer extends StatelessWidget {
  final String assetPath;
  final String? caption;

  const BarrioTrainingImageViewer({
    super.key,
    required this.assetPath,
    this.caption,
  });

  /// Pushes the viewer as a full-screen route.
  static Future<void> open(
    BuildContext context, {
    required String assetPath,
    String? caption,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => BarrioTrainingImageViewer(
          assetPath: assetPath,
          caption: caption,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                maxScale: 5,
                child: Center(
                  child: Image.asset(
                    assetPath,
                    // Accessibility (rec #12): the literal caption when
                    // present, else 'Photo'. Never invented.
                    semanticLabel: caption ?? 'Photo',
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.image_not_supported_outlined,
                      size: 48,
                      color: BarrioColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            if (caption != null)
              Positioned(
                left: 20,
                right: 20,
                bottom: 16,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: BarrioColors.shellMid.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      caption!,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12,
                        color: BarrioColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: BarrioColors.shellMid.withValues(alpha: 0.82),
                  border: Border.all(color: const Color(0x2216243B)),
                ),
                child: IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close_rounded),
                  color: BarrioColors.textPrimary,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
