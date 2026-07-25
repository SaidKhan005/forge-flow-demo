// Widget tests for the in-manual flashcard entry (visual-first pass,
// rec #6): the three glossary manuals carry a compact "Review as
// flashcards" chip on the hero eyebrow row; tapping it pushes the
// flashcard review screen scoped to ONLY that manual. Narrative
// manuals show no chip at all.
//
// All tests run at a 390x844 phone viewport and assert takeException()
// is null (overflow guard: the eyebrow row gains a chip and must not
// overflow or wrap the hero).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_flashcard_review_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _kChip = find.byKey(const ValueKey<String>(
  'training_doc_flashcards_chip',
));

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpDoc(WidgetTester tester, String docId) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: TrainingDocScreen(doc: kBarrioTrainingDocs[docId]!)),
    );
    // Restore setState frame, then the hero fade + carousel entrance.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
  }

  testWidgets('the chip shows on exactly the three glossary manuals',
      (tester) async {
    for (final docId in kBarrioFlashcardManualIds) {
      await pumpDoc(tester, docId);
      expect(_kChip, findsOneWidget,
          reason: '$docId is deck material and carries the chip');
      expect(find.text('FLASHCARDS'), findsOneWidget);
      final semantics = tester.widget<Semantics>(
        find.ancestor(of: _kChip, matching: find.byType(Semantics)).first,
      );
      expect(semantics.properties.label, 'Review as flashcards',
          reason: 'the chip announces its full name to assistive tech');
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrative manuals show no flashcard chip', (tester) async {
    for (final docId in const ['training_tequila', 'company_handbook']) {
      await pumpDoc(tester, docId);
      expect(_kChip, findsNothing,
          reason: '$docId is not deck material: no chip');
      expect(find.text('FLASHCARDS'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('tapping the chip pushes the review screen scoped to ONLY '
      'this manual', (tester) async {
    const docId = 'training_general_words';
    final doc = kBarrioTrainingDocs[docId]!;
    final ownUnitIds = <String>{
      for (final c in doc.chapters)
        for (final u in c.units) u.id,
    };

    await pumpDoc(tester, docId);
    await tester.tap(_kChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final screenFinder = find.byType(BarrioFlashcardReviewScreen);
    expect(screenFinder, findsOneWidget,
        reason: 'the chip pushes the flashcard review screen');
    final screen = tester.widget<BarrioFlashcardReviewScreen>(screenFinder);
    expect(screen.deck.id, docId,
        reason: 'the deck is the single-manual deck for this doc');
    expect(screen.deck.title, doc.title,
        reason: 'the deck carries the manual\'s own title');
    expect(screen.deck.cards.length, ownUnitIds.length,
        reason: 'every card of this manual is in the deck, nothing more');
    for (final card in screen.deck.cards) {
      expect(ownUnitIds, contains(card.id),
          reason: 'no card leaks in from any other manual');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving the review screen returns to the same manual',
      (tester) async {
    await pumpDoc(tester, 'training_latin_ingredients');
    await tester.tap(_kChip);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(BarrioFlashcardReviewScreen), findsOneWidget);

    // The barrio app bar's back affordance is a plain arrow icon.
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(TrainingDocScreen), findsOneWidget);
    expect(_kChip, findsOneWidget,
        reason: 'back lands on the manual with its chip intact');
    expect(tester.takeException(), isNull);
  });
}
