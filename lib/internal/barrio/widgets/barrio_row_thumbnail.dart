// Shared row thumbnail for browse-layer list rows (visual-first pass,
// rec #9).
//
// A visual learner recognizes a card by its picture faster than by a
// generic wayfinding icon. So on browse rows that point to a card WITH
// an image (in-manual search results, the A-Z term index, the home
// Saved shelf), the row leads with a small rounded photo of that card
// IN PLACE OF the wayfinding icon. A row whose target card has NO image
// keeps its existing icon exactly (Metric Honesty: no placeholder or
// stock art is ever invented for an imageless row).
//
// Presentation-only. This widget renders an already-resolved asset path;
// nothing here touches verbatim body text or the content files. The
// thumbnail is decorative for screen readers (wrapped in
// [ExcludeSemantics]): the row's own button label already names the
// item, so the photo must not add a second, duplicate node.

import 'package:flutter/material.dart';

import '../content/training/training_docs.dart';
import 'barrio_destination_scaffold.dart';

/// First bundled image asset of the unit at ([docId], [chapterIndex],
/// [unitIndex]) in the training registry, or null when the coordinate
/// carries no picture (or does not resolve). Callers show a thumbnail
/// only when this is non-null, and keep their icon otherwise.
///
/// This is the coordinate-space companion to `barrioChapterIconAt`: it
/// answers "does the card the row points to have a photo, and which
/// one" for the same (docId, chapterIndex, unitIndex) address search
/// results and bookmarks already carry.
String? barrioUnitFirstImageAt(
  String docId,
  int chapterIndex,
  int unitIndex,
) {
  final doc = kBarrioTrainingDocs[docId];
  if (doc == null) return null;
  if (chapterIndex < 0 || chapterIndex >= doc.chapters.length) return null;
  final units = doc.chapters[chapterIndex].units;
  if (unitIndex < 0 || unitIndex >= units.length) return null;
  final images = units[unitIndex].images;
  return images.isEmpty ? null : images.first.assetPath;
}

/// A small rounded photo of a card, shown on a browse row's leading
/// edge in place of the wayfinding icon.
///
/// Sized ~40px square (NN/g: large enough to recognize, never a tiny
/// unreadable dot), decoded at display size so long photo glossaries
/// never hold full bitmaps, `BoxFit.cover` so it always fills the
/// square. The [errorBuilder] mirrors the reader cards and the photo
/// grid: a quiet solid block, never a crash. That fallback ONLY renders
/// where a real image is declared (it is also the widget-test path,
/// where bundled assets do not load); it is never used to fill an
/// imageless row.
class BarrioRowThumbnail extends StatelessWidget {
  /// Bundled asset path of the card's first image. The caller resolves
  /// this (see [barrioUnitFirstImageAt]) and renders the thumbnail only
  /// when a real image exists.
  final String assetPath;

  /// Square edge length in logical pixels.
  final double size;

  const BarrioRowThumbnail({
    super.key,
    required this.assetPath,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (size * dpr).round();
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.asset(
          assetPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: cacheWidth > 0 ? cacheWidth : null,
          errorBuilder: (_, __, ___) => Container(
            width: size,
            height: size,
            color: BarrioColors.shellSurface,
            alignment: Alignment.center,
            child: Icon(
              Icons.image_outlined,
              size: size * 0.5,
              color: Colors.white.withValues(alpha: 0.30),
            ),
          ),
        ),
      ),
    );
  }
}
