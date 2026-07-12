// Wave A (Barrio Training Media + Search V1): content pictures inside the
// verbatim training lesson cards.
//
// Covers: a unit with images renders its paragraphs and image widgets in
// order (through the Image.asset errorBuilder path, since widget tests have
// no bundled assets); tapping an image opens the full-screen viewer and the
// viewer closes; a unit without images renders each blank-line paragraph as
// its own structured Text block; bullet / numbered / table paragraphs render
// with real list structure (no literal '- ' or ' | ' markers); no exceptions
// at the 390x844 mobile surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_training_image_viewer.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

const _kBodyWithImages =
    'First paragraph of the fixture body.\n\n'
    'Second paragraph, which carries the picture.\n\n'
    'Third paragraph after the picture.';

const _kUnitWithImages = HandbookUnit(
  id: 'fixture_images_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture With Pictures',
  body: _kBodyWithImages,
  images: [
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/01.webp',
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/02.webp',
      caption: 'A literal source caption',
      afterParagraph: 1,
    ),
  ],
);

const _kUnitWithoutImages = HandbookUnit(
  id: 'fixture_plain_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Without Pictures',
  body: _kBodyWithImages,
);

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: child,
      ),
    ),
  );
}

Future<void> _setMobileSurface(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('unit with images renders paragraph runs and images in order',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(
      _host(const HandbookLessonCard(unit: _kUnitWithImages)),
    );
    await tester.pumpAndSettle();

    // Two images (both resolve through errorBuilder in tests: no assets).
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNWidgets(2));

    // Structured rendering: each blank-line paragraph is its own Text
    // block (even spacing), and the image sits at its afterParagraph
    // boundary between paragraph 1 and paragraph 2.
    expect(find.text('First paragraph of the fixture body.'), findsOneWidget);
    expect(
      find.text('Second paragraph, which carries the picture.'),
      findsOneWidget,
    );
    expect(find.text('Third paragraph after the picture.'), findsOneWidget);
    // The unsplit single-text body must NOT be present.
    expect(find.text(_kBodyWithImages), findsNothing);

    // Caption renders under its image.
    expect(find.text('A literal source caption'), findsOneWidget);

    // Order: image (afterParagraph -1) -> text run -> image -> text run.
    final columnOrder = <Type>[];
    for (final w in tester.widgetList(find.descendant(
      of: find.byType(HandbookLessonCard),
      matching: find.byWidgetPredicate((w) => w is Image || w is Text),
    ))) {
      columnOrder.add(w.runtimeType);
    }
    final firstImage = columnOrder.indexOf(Image);
    final lastImage = columnOrder.lastIndexOf(Image);
    expect(firstImage, isNot(-1));
    expect(lastImage, greaterThan(firstImage));

    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping an image opens the viewer and the viewer closes',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(
      _host(const HandbookLessonCard(unit: _kUnitWithImages)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Image).last, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(BarrioTrainingImageViewer), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(BarrioTrainingImageViewer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unit without images renders each paragraph as its own block',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(
      _host(const HandbookLessonCard(unit: _kUnitWithoutImages)),
    );
    await tester.pumpAndSettle();

    // Structured body: every blank-line paragraph renders as a separate
    // Text block (consistent spacing), not one flat run.
    expect(find.text('First paragraph of the fixture body.'), findsOneWidget);
    expect(
      find.text('Second paragraph, which carries the picture.'),
      findsOneWidget,
    );
    expect(find.text('Third paragraph after the picture.'), findsOneWidget);
    expect(find.text(_kBodyWithImages), findsNothing);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bullet, numbered and table paragraphs render as real '
      'structure without their literal markers', (tester) async {
    await _setMobileSurface(tester);
    const unit = HandbookUnit(
      id: 'fixture_structured_unit',
      type: HandbookUnitType.explainer,
      badgeHint: 'READ',
      title: 'Structured Fixture',
      body: 'Intro paragraph before the list.\n\n'
          '- First bullet point\n\n'
          '- Second bullet point\n\n'
          '1. Call the manager\n\n'
          '2. Log the incident\n\n'
          'Metric | Value\n\n'
          'CPLH | 4.2',
    );
    await tester.pumpWidget(_host(const HandbookLessonCard(unit: unit)));
    await tester.pumpAndSettle();

    // Bullet items render their text without the literal '- ' prefix.
    expect(find.text('First bullet point'), findsOneWidget);
    expect(find.text('Second bullet point'), findsOneWidget);
    expect(find.text('- First bullet point'), findsNothing);

    // Numbered steps split the marker from the body; the body text is
    // findable on its own and the '1.'/'2.' markers render separately.
    expect(find.text('Call the manager'), findsOneWidget);
    expect(find.text('Log the incident'), findsOneWidget);
    expect(find.text('1. Call the manager'), findsNothing);
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);

    // Table cells render individually (no literal ' | ' run).
    expect(find.text('Metric'), findsOneWidget);
    expect(find.text('Value'), findsOneWidget);
    expect(find.text('CPLH'), findsOneWidget);
    expect(find.text('4.2'), findsOneWidget);
    expect(find.text('Metric | Value'), findsNothing);

    expect(tester.takeException(), isNull);
  });
}
