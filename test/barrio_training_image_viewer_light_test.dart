import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_training_image_viewer.dart';

void main() {
  testWidgets(
    'photo viewer uses the light cream backdrop with a navy close icon',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: BarrioTrainingImageViewer(
            slides: [
              BarrioTrainingImageSlide(
                assetPath: 'x',
                caption: 'Photo: Test, CC BY 2.0',
              ),
            ],
          ),
        ),
      );

      // Backdrop is the warm cream shell, not the old dark scrim.
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, BarrioColors.shellDeep);

      // The literal caption renders.
      expect(find.text('Photo: Test, CC BY 2.0'), findsOneWidget);

      // The close button exists and its icon is navy.
      final iconButton = tester.widget<IconButton>(find.byType(IconButton));
      expect(iconButton.color, BarrioColors.textPrimary);
    },
  );
}
