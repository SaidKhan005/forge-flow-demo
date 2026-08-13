// The recipe calculator as the cook meets it: where the way in appears,
// that it cannot cost the reader a page turn, and that what is on screen
// is a list of amounts and nothing else.
//
// HOW THIS STAYS AN HONEST GUARD (see
// `feedback_negative_controls_can_be_vacuous`): the amounts asserted below
// are hand-worked from the committed ingredient lines, never read back out
// of the calculator. The gating tests assert the RENDERED button against
// an independently stated fact about the data (that
// `barrioRecipeIngredientsForUnit` answers empty for that card), so a
// button that appeared everywhere and a button that appeared nowhere both
// fail. Every sweep counts what it touched and fails on zero.
//
// THE NO-VERBIAGE GUARD (operator direction, REC-6) is the last group.
// One half sweeps every recipe card's sheet and requires every rendered
// string to be an ingredient's own name, an amount, a unit, or the
// multiplier, against shapes this file states by hand. The other half
// scans the calculator's source for the exact sentences REC-6 deleted, and
// proves the scanner works by running it over a string that contains one.
//
// Every test runs at a phone-width viewport and asserts takeException() is
// null, the same bar as the rest of the Barrio widget suites (RenderFlex
// overflow throws in tests).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_ingredients.dart';
import 'package:forge_and_flow/internal/barrio/content/recipes/barrio_recipe_models.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_recipe_scaler_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size _phoneSize = Size(390, 844);

/// Tall enough that every row of every recipe card is built, so the
/// no-verbiage sweep sees the whole sheet rather than the first screenful.
const Size _tallSize = Size(390, 1600);

const String _kRecipesDocId = 'training_recipes';

/// The first recipe card of the manual (Aji Amarillo Dressing): nine
/// ingredient lines covering a jar, stalks, cloves, a fraction glyph and
/// one line with no number at all.
const String _kDressingUnitId = 'training_recipes_c0_u0';

/// The method card that follows it: prose, no ingredient list.
const String _kMethodUnitId = 'training_recipes_c0_u1';

/// Pickled Beets: carries the range '8-10lbs of beets'.
const String _kBeetsUnitId = 'training_recipes_c3_u0';

/// Beef Skewer Topping: carries '235 Pumpkin Seeds', which the card prints
/// with no unit and the operator confirmed as grams on 2026-08-13.
const String _kConfirmedUnitId = 'training_recipes_c8_u0';

final ValueKey<String> _kScaleButton =
    const ValueKey<String>('barrio_recipe_scale_button');

final ValueKey<String> _kAmountField =
    const ValueKey<String>('barrio_recipe_scale_amount');

/// The shape of an amount, written by hand: digits, a fraction glyph,
/// amount punctuation, and at most the unit word or two a range repeats.
final RegExp _kAmountShape = RegExp(
  r'^(?:\d+(?:\.\d+)?(?:/\d+)?|[¼½¾⅓⅔])\s?[A-Za-z]*'
  r'(?:-(?:\d+(?:\.\d+)?)\s?[A-Za-z]*)?$',
);

/// The multiplier readout, which is the only thing on the sheet that is
/// not part of an ingredient line.
final RegExp _kMultiplierShape = RegExp(r'^x\d+(\.\d+)?$');

/// Every sentence REC-6 deleted, written out by hand. None of these may
/// come back into the calculator's source, as copy or as an identifier.
const List<String> _kDeletedWording = <String>[
  'Counted in containers.',
  'Counted as whole items.',
  'No amount to scale.',
  'The recipe gives a range.',
  'Round it yourself.',
  'Go by taste and by eye.',
  'Pick a number inside it.',
  'The recipe prints no unit here.',
  'Every amount below is',
  'Type an amount to see',
  'That is the recipe exactly as it is written',
  'Nothing in this recipe can be scaled',
  'cannot be multiplied honestly',
  'Scales with your amount',
  'Stays as the recipe wrote it',
  'Starting from this one',
  'do you have?',
  'BarrioIngredientHold',
  'barrioHoldReason',
  'barrioUnitSourceNote',
  'unitFromOperator',
];

/// The calculator, source file by source file.
const List<String> _kCalculatorSources = <String>[
  'lib/internal/barrio/content/recipes/barrio_recipe_models.dart',
  'lib/internal/barrio/content/recipes/barrio_recipe_scaler.dart',
  'lib/internal/barrio/content/recipes/barrio_recipe_ingredients.dart',
  'lib/internal/barrio/widgets/barrio_recipe_scaler_sheet.dart',
];

/// Which of [_kDeletedWording] [source] still contains.
List<String> _deletedWordingIn(String source) => <String>[
      for (final phrase in _kDeletedWording)
        if (source.contains(phrase)) phrase,
    ];

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

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  /// One reading card on its own, the way the deck builds it.
  Future<void> pumpCard(WidgetTester tester, HandbookUnit unit,
      {double textScale = 1.0}) async {
    useViewport(tester, _phoneSize);
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

  /// The sheet on its own, so the assertions are about the calculator
  /// rather than about the reader around it.
  Future<void> pumpLines(
    WidgetTester tester,
    List<BarrioRecipeIngredient> lines, {
    double textScale = 1.0,
    Size size = _phoneSize,
  }) async {
    useViewport(tester, size);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            backgroundColor: BarrioColors.shellDeep,
            body: BarrioRecipeScalerSheet(
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

  Future<void> pumpSheet(
    WidgetTester tester,
    String unitId, {
    double textScale = 1.0,
    Size size = _phoneSize,
  }) async {
    final lines = barrioRecipeIngredientsForUnit(unitId);
    expect(lines, isNotEmpty, reason: '$unitId carries no ingredient lines');
    await pumpLines(tester, lines, textScale: textScale, size: size);
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
      // Swept across manuals rather than asserted on one, because the card
      // looks its own ingredients up and the lookup is what has to stay
      // quiet everywhere else.
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
    /// Pumps the real Recipes manual in the reader. Card 1 is the dressing
    /// recipe, card 2 its method.
    Future<void> pumpReader(WidgetTester tester) async {
      useViewport(tester, _phoneSize);
      await tester.pumpWidget(
        MaterialApp(
          home: TrainingDocScreen(doc: kBarrioTrainingDocs[_kRecipesDocId]!),
        ),
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
    testWidgets('opens on the recipe exactly as it is written',
        (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      // Hand-read off the card: the first line a cook can type against is
      // the 500mL of oil, so its box shows 500 and its unit, and every
      // other amount is the one the card printed.
      expect(find.text('500'), findsOneWidget,
          reason: 'an untouched box shows the amount the recipe wrote');
      expect(find.text('mL'), findsOneWidget);
      expect(find.text('x1'), findsOneWidget,
          reason: 'nothing has been typed, so this is one times the recipe');
      expect(find.text('1 Jar'), findsOneWidget);
      expect(find.text('2 Stalks'), findsOneWidget);
      expect(find.text('4 Cloves'), findsOneWidget);
      expect(find.text('10g'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing one amount moves every amount that has a number',
        (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      await tester.enterText(find.byKey(_kAmountField), '1250');
      await tester.pump();

      // Worked by hand from the card: 1250mL of a 500mL line is 2.5 times,
      // so the jar count reads 2.5 and the celery reads 5 stalks. Both are
      // amounts the first release refused to move.
      expect(find.text('x2.5'), findsOneWidget);
      expect(find.text('2.5 Jar'), findsOneWidget);
      expect(find.text('125ml'), findsOneWidget);
      expect(find.text('5 Stalks'), findsOneWidget);
      expect(find.text('10 Cloves'), findsOneWidget);
      expect(find.text('0.625'), findsOneWidget);
      expect(find.text('25g'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('starting from a different ingredient re-reads the recipe '
        'from that one', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      await tester.tap(find.text('Ginger'));
      await tester.pump();
      // The box moved to the ginger line, showing that line's own amount.
      expect(find.text('10'), findsOneWidget);
      expect(find.text('g'), findsOneWidget);
      expect(find.text('x1'), findsOneWidget,
          reason: 'picking a different ingredient goes back to the recipe '
              'as written rather than carrying an amount across');

      await tester.enterText(find.byKey(_kAmountField), '24');
      await tester.pump();

      // THE OPERATOR'S OWN EXAMPLE. 24g of a 10g line is 2.4 times, so the
      // celery reads 4.8 stalks. If the multiplier were still read off the
      // oil, 24 would make this 0.048 times and the oil would read 24mL.
      expect(find.text('x2.4'), findsOneWidget);
      expect(find.text('1200mL'), findsOneWidget);
      expect(find.text('4.8 Stalks'), findsOneWidget);
      expect(find.text('9.6 Cloves'), findsOneWidget);
      expect(find.text('2.4 Jar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a range moves on both of its numbers', (tester) async {
      // The gate, stated independently of the widget.
      final beets = barrioRecipeIngredientsForUnit(_kBeetsUnitId)
          .where((line) => line.quantityHigh != null)
          .toList();
      expect(beets, hasLength(1),
          reason: 'this card is the range case');

      await pumpSheet(tester, _kBeetsUnitId);
      expect(find.text('8-10lbs'), findsOneWidget,
          reason: 'the untouched sheet shows the range the card printed');

      // 6L of water is 2 times the recipe, worked by hand, so 8-10 becomes
      // 16-20 rather than 16-10 or 8-20.
      await tester.enterText(find.byKey(_kAmountField), '6');
      await tester.pump();
      expect(find.text('x2'), findsOneWidget);
      expect(find.text('16-20lbs'), findsOneWidget);
      expect(find.text('400mL'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a line with no number prints exactly as written and says '
        'nothing about it', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      await tester.enterText(find.byKey(_kAmountField), '1250');
      await tester.pump();

      // Hand-read off the card: this is the one line of the dressing with
      // no number in it.
      expect(find.text('Salt TT'), findsOneWidget,
          reason: 'the line still shows, word for word as the card wrote it');
      for (final gone in _kDeletedWording) {
        expect(find.textContaining(gone), findsNothing,
            reason: '"$gone" is wording REC-6 deleted');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a unit the recipe never printed comes along with the '
        'number, and explains nothing', (tester) async {
      // The gate, stated independently of the widget.
      final confirmed = barrioRecipeIngredientsForUnit(_kConfirmedUnitId)
          .where((line) =>
              line.unit != null && !line.raw.contains(line.unit!))
          .toList();
      expect(confirmed, hasLength(1),
          reason: 'this card is the unit-the-recipe-never-printed case');

      await pumpSheet(tester, _kConfirmedUnitId, size: _tallSize);
      expect(find.text('235 g'), findsOneWidget,
          reason: 'the card prints 235 with no unit; the calculator shows '
              'the confirmed gram beside it');

      // 940g of corn nuts is 2 times the recipe, worked by hand, so the
      // 235 becomes 470.
      await tester.enterText(find.byKey(_kAmountField), '940');
      await tester.pump();
      expect(find.text('x2'), findsOneWidget);
      expect(find.text('470 g'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an amount that is not a batch size leaves the recipe as '
        'written', (tester) async {
      await pumpSheet(tester, _kDressingUnitId);
      for (final typed in <String>['', '0', '.', '0.0']) {
        await tester.enterText(find.byKey(_kAmountField), typed);
        await tester.pump();
        expect(find.text('x1'), findsOneWidget,
            reason: '"$typed" is not a batch size, so the recipe stays as '
                'written');
        expect(find.text('1 Jar'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('a recipe with no number anywhere shows its lines and no '
        'box to type in', (tester) async {
      // Hand-built, because no card of the manual is like this: the lines
      // are the two the manual writes with no number at all, so the sheet
      // has nothing to anchor on.
      const lines = <BarrioRecipeIngredient>[
        BarrioRecipeIngredient(raw: 'Salt TT', name: 'Salt TT'),
        BarrioRecipeIngredient(raw: 'L5S TT', name: 'L5S TT'),
      ];
      await pumpLines(tester, lines);
      expect(find.byKey(_kAmountField), findsNothing,
          reason: 'there is no number to start from, so there is nothing to '
              'type');
      expect(find.text('Salt TT'), findsOneWidget);
      expect(find.text('L5S TT'), findsOneWidget);
      expect(find.text('x1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('nothing on the sheet is a sentence', () {
    testWidgets('every rendered string is a name, an amount, a unit, or the '
        'multiplier', (tester) async {
      // THE NO-VERBIAGE GUARD. Swept over every recipe card of the manual,
      // against shapes stated by hand at the top of this file. A heading,
      // an instruction, a hold reason or any other prose put back on the
      // sheet fails here naming itself.
      var cardsChecked = 0;
      var stringsChecked = 0;
      for (final unitId in kBarrioRecipeIngredients.keys) {
        final lines = barrioRecipeIngredientsForUnit(unitId);
        expect(lines, isNotEmpty);
        await pumpSheet(tester, unitId, size: _tallSize);

        final names = lines.map((line) => line.name).toSet();
        final units = lines
            .map((line) => line.unit)
            .whereType<String>()
            .toSet();
        var seenOnThisCard = 0;
        for (final text in tester.widgetList<Text>(find.byType(Text))) {
          final data = text.data;
          if (data == null || data.trim().isEmpty) continue;
          seenOnThisCard += 1;
          stringsChecked += 1;
          final allowed = names.contains(data) ||
              units.contains(data) ||
              _kAmountShape.hasMatch(data) ||
              _kMultiplierShape.hasMatch(data);
          expect(allowed, isTrue,
              reason: '$unitId renders "$data", which is not one of this '
                  "recipe's own ingredient names, an amount, a unit, or the "
                  'multiplier');
        }
        expect(seenOnThisCard, greaterThanOrEqualTo(lines.length),
            reason: '$unitId rendered only $seenOnThisCard strings for '
                '${lines.length} ingredient lines, so the sheet did not '
                'build and this card proved nothing');
        expect(tester.takeException(), isNull);
        cardsChecked += 1;
      }
      expect(cardsChecked, greaterThan(25),
          reason: 'the sweep covered $cardsChecked recipe cards');
      expect(stringsChecked, greaterThan(300),
          reason: 'only $stringsChecked strings were checked, so the sheets '
              'did not render and this proved nothing');
    });

    test('the wording REC-6 deleted is gone from the source, not hidden',
        () {
      // A rendered sweep cannot see a sentence that is one flag away from
      // being shown again, so the source is scanned too.
      var filesScanned = 0;
      final offenders = <String>[];
      for (final path in _kCalculatorSources) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path is not where this guard expects the calculator');
        final source = file.readAsStringSync();
        expect(source.length, greaterThan(1000),
            reason: '$path is too small to be the real file');
        for (final phrase in _deletedWordingIn(source)) {
          offenders.add('$path still contains "$phrase"');
        }
        filesScanned += 1;
      }
      expect(filesScanned, _kCalculatorSources.length);
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('the scanner would notice if it did come back', () {
      // Non-vacuity for the scan above: prove the matcher fires, so an
      // empty offender list means something.
      expect(_kDeletedWording, isNotEmpty);
      for (final phrase in _kDeletedWording) {
        expect(_deletedWordingIn('prefix $phrase suffix'), contains(phrase),
            reason: 'the scanner cannot see "$phrase"');
      }
      expect(_deletedWordingIn('500mL Olive Oil'), isEmpty,
          reason: 'an ordinary ingredient line is not an offender');
    });
  });

  group('bigger text still lays out', () {
    for (final scale in <double>[1.3, 2.0]) {
      testWidgets('the calculator renders at ${scale}x with no overflow',
          (tester) async {
        await pumpSheet(tester, _kDressingUnitId, textScale: scale);
        expect(tester.takeException(), isNull);

        await tester.enterText(find.byKey(_kAmountField), '1250');
        await tester.pump();
        expect(find.text('2.5 Jar'), findsOneWidget);
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
