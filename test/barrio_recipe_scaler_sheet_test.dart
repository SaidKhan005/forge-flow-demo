// The recipe calculator as the cook meets it: where the way in appears,
// that it cannot cost the reader a page turn, and what the sheet says.
//
// HOW THIS STAYS AN HONEST GUARD (see
// `feedback_negative_controls_can_be_vacuous`): the amounts asserted
// below are hand-worked from the committed ingredient lines, never read
// back out of the calculator. The gating tests assert the RENDERED
// button against an independently stated fact about the data (that
// `barrioRecipeIngredientsForUnit` answers empty for that card), so a
// button that appeared everywhere and a button that appeared nowhere
// both fail. Every sweep counts what it touched and fails on zero.
//
// Every test runs at a 390x844 phone viewport and asserts
// takeException() is null, the same bar as the rest of the Barrio
// widget suites (RenderFlex overflow throws in tests).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_recipe_scaler_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phoneSize = Size(390, 844);
const String _kRecipesDocId = 'training_recipes';

/// The first recipe card of the manual (Aji Amarillo Dressing): nine
/// ingredient lines, three of them scalable.
const String _kDressingUnitId = 'training_recipes_c0_u0';

/// The method card that follows it: prose, no ingredient list.
const String _kMethodUnitId = 'training_recipes_c0_u1';

/// A recipe card where nothing at all may be scaled.
const String _kAllHeldUnitId = 'training_recipes_c22_u0';

/// Beef Skewer Topping: five gram lines, one of which ('235 Pumpkin
/// Seeds') the card prints with no unit at all and the operator confirmed
/// as grams on 2026-08-13.
const String _kConfirmedUnitId = 'training_recipes_c8_u0';

final ValueKey<String> _kScaleButton =
    const ValueKey<String>('barrio_recipe_scale_button');

/// Every card of one registered manual, in reading order.
List<HandbookUnit> _unitsOf(String docId) {
  final doc = kBarrioTrainingDocs[docId];
  expect(doc, isNotNull, reason: '$docId must be a registered manual');
  return <HandbookUnit>[
    for (final chapter in doc!.chapters) ...chapter.units,
  ];
}

HandbookUnit _unit(String docId, String unitId) {
  final matches = _unitsOf(docId).where((unit) => unit.id == unitId).toList();
  expect(matches, hasLength(1),
      reason: '$unitId is no longer a card of $docId, so the tests written '
          'against it would prove nothing');
  return matches.single;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  void usePhone(WidgetTester tester) {
    tester.view.physicalSize = _phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// One reading card on its own, the way the deck builds it.
  Future<void> pumpCard(WidgetTester tester, HandbookUnit unit,
      {double textScale = 1.0}) async {
    usePhone(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: _phoneSize,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            backgroundColor: BarrioColors.shellDeep,
            body: SingleChildScrollView(
              child: HandbookLessonCard(unit: unit, isCarouselMode: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('the way in appears on recipe cards and nowhere else', () {
    testWidgets('a recipe card carrying ingredient lines shows the button',
        (tester) async {
      // The gate, stated independently of the widget.
      expect(barrioRecipeIngredientsForUnit(_kDressingUnitId), isNotEmpty,
          reason: 'this card is the positive case; with no ingredient data '
              'the negative cases below would pass vacuously');

      await pumpCard(tester, _unit(_kRecipesDocId, _kDressingUnitId));
      expect(find.byKey(_kScaleButton), findsOneWidget);
      expect(find.text('Scale this recipe'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the method card that follows it does not', (tester) async {
      expect(barrioRecipeIngredientsForUnit(_kMethodUnitId), isEmpty,
          reason: 'a method card carries no ingredient lines');

      await pumpCard(tester, _unit(_kRecipesDocId, _kMethodUnitId));
      expect(find.byKey(_kScaleButton), findsNothing,
          reason: 'there is nothing on a method card to scale');
      expect(tester.takeException(), isNull);
    });

    testWidgets('no card of any other manual does', (tester) async {
      // Swept across manuals rather than asserted on one, because the
      // card looks its own ingredients up and the lookup is what has to
      // stay quiet everywhere else.
      const otherDocIds = <String>[
        'training_wine',
        'training_latin_ingredients',
        'training_drink_specs',
        'training_food_safety',
      ];
      var cardsChecked = 0;
      for (final docId in otherDocIds) {
        final units = _unitsOf(docId);
        expect(units, isNotEmpty, reason: '$docId has no cards to check');
        for (final unit in units.take(3)) {
          expect(barrioRecipeIngredientsForUnit(unit.id), isEmpty,
              reason: '${unit.id} is outside the Recipes manual');
          await pumpCard(tester, unit);
          expect(find.byKey(_kScaleButton), findsNothing,
              reason: '${unit.id} is not a recipe, so it gets no calculator');
          expect(tester.takeException(), isNull);
          cardsChecked += 1;
        }
      }
      expect(cardsChecked, greaterThanOrEqualTo(8),
          reason: 'the sweep checked $cardsChecked cards, which means the '
              'manuals it names went missing and it proved nothing');
    });
  });

  group('the reader still turns the page', () {
    /// Pumps the real Recipes manual in the reader. Card 1 is the
    /// dressing recipe, card 2 its method.
    Future<void> pumpReader(WidgetTester tester) async {
      usePhone(tester);
      await tester.pumpWidget(
        MaterialApp(home: TrainingDocScreen(doc: kBarrioTrainingDocs[_kRecipesDocId]!)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
    }

    testWidgets('an edge tap level with the button still turns exactly one '
        'page', (tester) async {
      // THE GESTURE CONTROL. Slice A9 proved that a gesture-owning widget
      // inside the card body starves the carousel's edge tap zones. The
      // button is the only thing this slice puts in a card, so the probe
      // lands in the edge band at the button's own height: if the button
      // (or anything it plants) had claimed that band, this turns nothing.
      await pumpReader(tester);
      expect(find.text('1 of 58'), findsOneWidget,
          reason: 'the Recipes deck must be the manual under test');

      final button = find.byKey(_kScaleButton);
      expect(button, findsOneWidget);
      await tester.ensureVisible(button);
      await tester.pump();

      final buttonRect = tester.getRect(button);
      final pageRect = tester.getRect(find.byType(PageView));
      // The probe only means anything if it lands on the card area at the
      // button's own height, and beside the button rather than on it.
      expect(buttonRect.center.dy, greaterThan(pageRect.top),
          reason: 'the probe must land inside the card area');
      expect(buttonRect.center.dy, lessThan(pageRect.bottom),
          reason: 'the probe must land inside the card area');
      final probeX = pageRect.right - 62;
      expect(probeX, greaterThan(buttonRect.right),
          reason: 'the probe must land BESIDE the button, not on it, or it '
              'would only prove the button works');

      // Right of the button, inside the 22% edge band, clear of the 30px
      // chevron gutter: the same x probe the #1483 edge-tap suite uses.
      await tester.tapAt(Offset(probeX, buttonRect.center.dy));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('2 of 58'), findsOneWidget,
          reason: 'a tap beside the button, in the page-turn band, must '
              'still turn the page');
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the button opens the calculator and does not turn '
        'the page', (tester) async {
      await pumpReader(tester);
      expect(find.text('1 of 58'), findsOneWidget);

      final button = find.byKey(_kScaleButton);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(BarrioRecipeScalerSheet), findsOneWidget,
          reason: 'the button opens the calculator');
      expect(find.text('1 of 58'), findsOneWidget,
          reason: 'the button owns its own tap; the page must not move '
              'under the sheet');
      expect(tester.takeException(), isNull);
    });
  });

  group('the calculator', () {
    /// The sheet on its own, so the assertions are about the calculator
    /// rather than about the reader around it.
    Future<void> pumpSheet(
      WidgetTester tester,
      String unitId, {
      double textScale = 1.0,
    }) async {
      usePhone(tester);
      final lines = barrioRecipeIngredientsForUnit(unitId);
      expect(lines, isNotEmpty, reason: '$unitId carries no ingredient lines');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: _phoneSize,
              textScaler: TextScaler.linear(textScale),
            ),
            child: Scaffold(
              backgroundColor: BarrioColors.shellDeep,
              body: BarrioRecipeScalerSheet(
                recipeTitle: _unit(_kRecipesDocId, unitId).title,
                lines: lines,
                accent: BarrioColors.accentHerb,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Brings [text] on screen, scrolling the sheet's list if it has not
    /// been built yet.
    Future<void> reveal(WidgetTester tester, String text) async {
      final finder = find.text(text);
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          100,
          scrollable: find.byType(Scrollable).last,
          maxScrolls: 60,
        );
      }
      await tester.pump();
      expect(finder, findsWidgets, reason: '"$text" never came on screen');
    }

    testWidgets('opens on the recipe exactly as it is written',
        (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      // Hand-read off the card: the first scalable line is 500mL of oil.
      expect(find.text('How much Olive Oil do you have?'), findsOneWidget);
      expect(find.text('500mL'), findsOneWidget);
      expect(find.text('That is the recipe exactly as it is written.'),
          findsOneWidget);
      expect(find.textContaining('was '), findsNothing,
          reason: 'nothing has changed yet, so there is no old amount to '
              'show beside a new one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing one amount moves every amount that can move',
        (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
        '1250',
      );
      await tester.pump();

      // Worked by hand from the card: 1250mL of a 500mL line is 2.5
      // times, so 50ml of water becomes 125ml and 10g of ginger 25g.
      expect(find.text('Every amount below is 2.5 times the recipe.'),
          findsOneWidget);
      expect(find.text('1250mL'), findsOneWidget);
      expect(find.text('125ml'), findsOneWidget);
      expect(find.text('25g'), findsOneWidget);
      // The written amount stays beside the new one.
      expect(find.text('was 500mL'), findsOneWidget);
      expect(find.text('was 50ml'), findsOneWidget);
      expect(find.text('was 10g'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('starting from a different ingredient re-reads the recipe '
        'from that one', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      // The ginger row is the third scalable line of this card.
      await tester.tap(find.text('Ginger'));
      await tester.pump();
      expect(find.text('How much Ginger do you have?'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
        '30',
      );
      await tester.pump();

      // 30g of a 10g line is 3 times, so the oil is 1500mL. If the
      // multiplier were still read off the oil line, 30 would make this
      // 0.06 times and the oil would read 30mL.
      expect(find.text('Every amount below is 3 times the recipe.'),
          findsOneWidget);
      expect(find.text('1500mL'), findsOneWidget);
      expect(find.text('150ml'), findsOneWidget);
      expect(find.text('30g'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every line that cannot be scaled is shown, unchanged, with '
        'the reason', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
        '1250',
      );
      await tester.pump();

      // Hand-read off the card: these six lines and these reasons.
      // '¼ Red Onion' and '4 Juiced Limes' count whole things the same
      // way '2 Stalks Celery' does; the counted noun is just in the
      // ingredient's name rather than in a unit word (REC-4).
      const heldLines = <String, String>{
        '1 Jar Aji Amarillo': 'Counted in containers. Round it yourself.',
        '2 Stalks Celery': 'Counted as whole items. Round it yourself.',
        '4 Cloves of garlic': 'Counted as whole items. Round it yourself.',
        '¼ Red Onion': 'Counted as whole items. Round it yourself.',
        '4 Juiced Limes': 'Counted as whole items. Round it yourself.',
        'Salt TT': 'No amount to scale. Go by taste and by eye.',
      };
      var shown = 0;
      for (final entry in heldLines.entries) {
        await reveal(tester, entry.key);
        expect(find.text(entry.value), findsWidgets,
            reason: '"${entry.key}" must say why it did not move');
        shown += 1;
      }
      expect(shown, heldLines.length);

      // And the numbers on those lines were never multiplied: 2.5 jars,
      // 5 stalks and 10 cloves are what a silent scaler would have shown.
      for (final wrong in <String>['2.5 Jar', '5 Stalks', '10 Cloves']) {
        expect(find.textContaining(wrong), findsNothing,
            reason: 'a held line was scaled anyway');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('an amount that is not a batch size asks again instead of '
        'pretending', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      for (final typed in <String>['', '0', '.', '0.0']) {
        await tester.enterText(
          find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
          typed,
        );
        await tester.pump();
        expect(
          find.text('Type an amount to see the rest of the recipe change.'),
          findsOneWidget,
          reason: '"$typed" is not a batch size, so the calculator must ask '
              'again rather than call the written recipe an answer',
        );
        expect(find.text('500mL'), findsOneWidget,
            reason: 'the recipe stays as written meanwhile');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a recipe with nothing to scale says so instead of offering '
        'a box to type in', (tester) async {
      expect(
        barrioRecipeIngredientsForUnit(_kAllHeldUnitId)
            .every((line) => !line.scalable),
        isTrue,
        reason: 'this card is the every-line-is-held case',
      );

      await pumpSheet(tester, _kAllHeldUnitId);
      expect(find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
          findsNothing,
          reason: 'there is no ingredient to start from, so there is nothing '
              'to type');
      expect(
        find.textContaining('Nothing in this recipe can be scaled'),
        findsOneWidget,
      );
      // The line itself is still shown, with its reason. A cook reading
      // '12 Eggs' is told it counts whole things, not that the recipe
      // failed to say what the 12 measures (REC-4).
      expect(find.text('12 Eggs'), findsOneWidget);
      expect(find.text('Counted as whole items. Round it yourself.'),
          findsOneWidget);
      expect(find.textContaining('does not say what this number measures'),
          findsNothing,
          reason: 'that sentence was removed: it read as a broken app '
              'beside a line that plainly counts eggs');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a unit the operator gave says where it came from',
        (tester) async {
      // The gate, stated independently of the widget: this card carries
      // a line the recipe prints with no unit at all.
      final confirmed = barrioRecipeIngredientsForUnit(_kConfirmedUnitId)
          .where((line) => line.unitFromOperator)
          .toList();
      expect(confirmed, hasLength(1),
          reason: 'this card is the operator-confirmed-unit case');
      expect(confirmed.single.raw.contains(confirmed.single.unit!), isFalse,
          reason: 'the note only makes sense because the line prints no '
              'unit of its own');

      await pumpSheet(tester, _kConfirmedUnitId);
      await reveal(tester, 'Pumpkin Seeds');
      expect(
        find.text(
            'The recipe prints no unit here. The operator confirmed grams.'),
        findsOneWidget,
        reason: 'the calculator shows grams on a line the card printed '
            'without a unit, so it has to say where the grams came from',
      );

      // And the line really does scale: 940g of corn nuts is 2 times the
      // recipe, worked by hand, so 235 becomes 470.
      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
        '940',
      );
      await tester.pump();
      expect(find.text('Every amount below is 2 times the recipe.'),
          findsOneWidget);
      await reveal(tester, '470 g');
      expect(find.text('was 235 g'), findsWidgets,
          reason: 'the written amount stays beside the new one here too');

      // The note is for the lines that need it and nowhere else.
      expect(
        find.text(
            'The recipe prints no unit here. The operator confirmed grams.'),
        findsOneWidget,
        reason: 'four other lines of this card print their own grams and '
            'need no explanation',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('bigger text still lays out', () {
    for (final scale in <double>[1.3, 2.0]) {
      testWidgets('the calculator renders at ${scale}x with no overflow',
          (tester) async {
        usePhone(tester);
        final lines = barrioRecipeIngredientsForUnit(_kDressingUnitId);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: _phoneSize,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                backgroundColor: BarrioColors.shellDeep,
                body: BarrioRecipeScalerSheet(
                  recipeTitle: _unit(_kRecipesDocId, _kDressingUnitId).title,
                  lines: lines,
                  accent: BarrioColors.accentHerb,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        await tester.enterText(
          find.byKey(const ValueKey<String>('barrio_recipe_scale_amount')),
          '1250',
        );
        await tester.pump();
        expect(find.text('1250mL'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.drag(find.byType(Scrollable).last, const Offset(0, -400));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('the button on a recipe card renders at ${scale}x with no '
          'overflow', (tester) async {
        await pumpCard(tester, _unit(_kRecipesDocId, _kDressingUnitId),
            textScale: scale);
        expect(find.byKey(_kScaleButton), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
