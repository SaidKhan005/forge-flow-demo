// Hand-authored diagrams/pictograms wired into the training content
// (operator-approved 2026-07-26). These are NOT extracted from any source
// PDF; they ride tool/barrio_training_diagrams_manifest.json, which the
// generator appends to the matching card's images. This test locks that
// wiring so a future regeneration or manifest edit can never silently drop
// or mis-anchor a diagram.
//
// Diagram coverage after the accuracy cull (2026-07-31): forced/nonsensical
// auto-icons were removed (566 of 977 across all manuals), leaving only the
// illustrations that clearly fit their card. The guarded counts are now
// 63 Company Handbook + 41 Food Safety = 104 diagrams. If a diagram is
// intentionally added or cut, update these numbers deliberately (that is
// the point of the guard).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

const _kHandbookDiagramDir =
    'assets/internal/barrio/training/barrio_company_handbook_diagrams/';
const _kFoodSafetyDiagramDir =
    'assets/internal/barrio/training/food_safety_manual_diagrams/';

bool _isDiagram(HandbookUnitImage image) =>
    image.assetPath.contains('_diagrams/');

void main() {
  final handbook = kBarrioTrainingDocs['company_handbook'];
  final foodSafety = kBarrioTrainingDocs['training_food_safety'];

  test('both target manuals are in the registry', () {
    expect(handbook, isNotNull);
    expect(foodSafety, isNotNull);
  });

  List<HandbookUnitImage> diagramsIn(BarrioTrainingDoc? doc) => [
        for (final chapter in doc!.chapters)
          for (final unit in chapter.units)
            for (final image in unit.images)
              if (_isDiagram(image)) image,
      ];

  test('Company Handbook carries exactly its 63 approved diagrams', () {
    final diagrams = diagramsIn(handbook);
    expect(diagrams, hasLength(63));
    for (final image in diagrams) {
      expect(image.assetPath, startsWith(_kHandbookDiagramDir));
      expect(image.assetPath, endsWith('.webp'));
    }
  });

  test('Food Safety carries exactly its 41 approved diagrams', () {
    final diagrams = diagramsIn(foodSafety);
    expect(diagrams, hasLength(41));
    for (final image in diagrams) {
      expect(image.assetPath, startsWith(_kFoodSafetyDiagramDir));
      expect(image.assetPath, endsWith('.webp'));
    }
  });

  test('every diagram leads its card and carries an honest alt caption', () {
    final all = [...diagramsIn(handbook), ...diagramsIn(foodSafety)];
    expect(all, hasLength(104));
    for (final image in all) {
      // afterParagraph -1 renders the diagram before the first paragraph:
      // the picture sets context, then the verbatim text follows.
      expect(image.afterParagraph, -1,
          reason: '${image.assetPath} should lead its card');
      // A real caption (not null) so screen readers get a description
      // rather than the generic "Photo:" fallback; UX no-em-dash law.
      expect(image.caption, isNotNull);
      expect(image.caption!, startsWith('Diagram: '));
      expect(image.caption!, isNot(contains('—')));
    }
  });

  test('no diagram asset path is duplicated', () {
    final all = [...diagramsIn(handbook), ...diagramsIn(foodSafety)];
    final paths = all.map((i) => i.assetPath).toList();
    expect(paths.toSet(), hasLength(paths.length));
  });
}
