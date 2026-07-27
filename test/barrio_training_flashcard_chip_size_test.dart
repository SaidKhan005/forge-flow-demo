// Widget tests for the enlarged, more prominent "Review as flashcards"
// chip (2026-07-26 operator request "flash cards button bigger and more
// prominent in places where it exists").
//
// The chip went from a quiet outline pill to a solid accent-filled chip
// with a larger tap target, a soft accent glow, and dark high-contrast
// text. These tests lock the "bigger + more prominent" intent and prove
// it still pushes the flashcard review screen scoped to this manual and
// stays overflow-safe on a phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _kChip = find.byKey(const ValueKey<String>(
  'training_doc_flashcards_chip',
));

void main() {
  const phoneSize = Size(390, 844);
  const docId = 'training_general_words';

  Future<void> pumpDoc(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: kBarrioTrainingDocs[docId]!)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('the chip renders at its larger, filled size', (tester) async {
    await pumpDoc(tester);
    expect(_kChip, findsOneWidget);

    // Bigger tap target: the old quiet pill sat around 19px tall; the
    // enlarged chip clears 30px and reads as a real button.
    final size = tester.getSize(_kChip);
    expect(size.height, greaterThan(30),
        reason: 'the enlarged chip is a comfortably larger tap target');
    expect(size.width, greaterThan(100),
        reason: 'the enlarged chip is visibly wider than the old pill');

    // Stronger fill, not a quiet outline: solid accent, a glow, no
    // outline border.
    final container = tester.widget<Container>(
      find.descendant(of: _kChip, matching: find.byType(Container)),
    );
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.color, BarrioColors.tealWarm,
        reason: 'the chip is filled with the manual accent');
    expect(decoration.border, isNull,
        reason: 'the prominent chip is a fill, not a quiet outline');
    expect(decoration.boxShadow, isNotNull);
    expect(decoration.boxShadow, isNotEmpty,
        reason: 'the chip carries an accent glow for prominence');

    // Larger, high-contrast content.
    // Light theme: the foreground is luminance-picked. On the bright
    // tealWarm accent (the doc's default) that resolves to near-black
    // ink for a legible, high-contrast label.
    const onBrightAccent = Color(0xFF10151F);
    final icon = tester.widget<Icon>(
      find.descendant(of: _kChip, matching: find.byIcon(Icons.style_rounded)),
    );
    expect(icon.size, 16, reason: 'the icon grew for prominence');
    expect(icon.color, onBrightAccent,
        reason: 'dark icon reads clearly on the bright accent fill');

    final label = tester.widget<Text>(find.text('FLASHCARDS'));
    expect(label.style!.fontSize, 11, reason: 'the label text grew');
    expect(label.style!.color, onBrightAccent,
        reason: 'dark label reads clearly on the bright accent fill');

    expect(tester.takeException(), isNull,
        reason: 'the wider chip must stay overflow-safe in the hero row');
  });

  testWidgets('tapping the larger chip still pushes the review screen '
      'scoped to this manual', (tester) async {
    await pumpDoc(tester);
    await tester.tap(_kChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final screenFinder = find.byType(BarrioFlashcardReviewScreen);
    expect(screenFinder, findsOneWidget,
        reason: 'the enlarged chip still opens flashcard review');
    final screen = tester.widget<BarrioFlashcardReviewScreen>(screenFinder);
    expect(screen.deck.id, docId,
        reason: 'the review deck is scoped to this manual only');
    expect(tester.takeException(), isNull);
  });
}
