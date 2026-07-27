// Widget test for the branded monogram front (2026-07-27). The "Words
// To Know" deck has 92 abstract-vocabulary cards with no picture (you
// cannot photograph slang like "86" or "in the weeds"). A picture-less
// card must read as intentional: it shows a teal monogram medallion of
// the term's first letter above the term, not a bare/broken-looking
// term. A card WITH a picture is unaffected: it uses the photo branch
// and shows no standalone monogram letter.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_flashcard_deck.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_flashcard_card.dart';

Widget _host(BarrioFlashcard card) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          height: 420,
          child: BarrioFlashcardCard(
            card: card,
            accent: BarrioColors.tealWarm,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('picture-less card shows the monogram medallion above the term',
      (tester) async {
    const card = BarrioFlashcard(
      id: 't',
      term: 'MISE EN PLACE',
      body: 'Everything in its place before service begins.',
      imageAssetPath: null,
    );

    await tester.pumpWidget(_host(card));
    await tester.pump();

    // The monogram (term's first letter, uppercased) renders as its own
    // Text, and the term itself still renders.
    expect(find.text('M'), findsOneWidget);
    expect(find.text('MISE EN PLACE'), findsOneWidget);
    // No photo on a picture-less card.
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card with a picture uses the photo branch, no monogram letter',
      (tester) async {
    const card = BarrioFlashcard(
      id: 't',
      term: 'MISE EN PLACE',
      body: 'Everything in its place before service begins.',
      imageAssetPath: 'assets/x.webp',
    );

    await tester.pumpWidget(_host(card));
    await tester.pump();

    // The photo branch is used: an Image widget is present.
    expect(find.byType(Image), findsOneWidget);
    // No standalone first-letter monogram is shown for a picture card.
    expect(find.text('M'), findsNothing);
    // The term still renders as normal.
    expect(find.text('MISE EN PLACE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
