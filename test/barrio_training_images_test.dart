// Wave A (Barrio Training Media + Search V1): content pictures inside the
// verbatim training lesson cards.
//
// Covers: a unit with images is picture-first (all its images render ABOVE
// the body, in source list order, through the Image.asset errorBuilder path
// since widget tests have no bundled assets); tapping an image opens the
// full-screen viewer and the viewer closes; a unit without images renders
// each blank-line paragraph as its own structured Text block; bullet /
// numbered / table paragraphs render with real list structure (no literal
// '- ' or ' | ' markers); no exceptions at the 390x844 mobile surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_training_image_viewer.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

/// The bundled asset behind an [Image], seeing through the [ResizeImage]
/// that a display-size decode (`cacheWidth`, perf audit A1) wraps the
/// [AssetImage] in. Null for anything that is not an asset image.
String? _assetNameOf(Image image) {
  var provider = image.image;
  if (provider is ResizeImage) provider = provider.imageProvider;
  return provider is AssetImage ? provider.assetName : null;
}

const _kBodyWithImages =
    'First paragraph of the fixture body.\n\n'
    'Second paragraph, which carries the picture.\n\n'
    'Third paragraph after the picture.';

/// A photograph plus a house-style diagram pictogram. Two SEPARATE
/// picture holders on purpose: a diagram never joins a photograph's
/// slide group (T10, 2026-08-02), so this fixture keeps proving the
/// stacked picture-first render order that slide grouping leaves alone.
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
      caption: 'Diagram: a literal source caption',
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
  testWidgets('unit with images is picture-first: all images above the body',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(
      _host(const HandbookLessonCard(unit: _kUnitWithImages)),
    );
    await tester.pumpAndSettle();

    // Two images (both resolve through errorBuilder in tests: no assets).
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.image_not_supported_outlined), findsNWidgets(2));

    // Structured rendering: each blank-line paragraph is still its own
    // Text block (even spacing); the body words are unchanged.
    expect(find.text('First paragraph of the fixture body.'), findsOneWidget);
    expect(
      find.text('Second paragraph, which carries the picture.'),
      findsOneWidget,
    );
    expect(find.text('Third paragraph after the picture.'), findsOneWidget);
    // The unsplit single-text body must NOT be present.
    expect(find.text(_kBodyWithImages), findsNothing);

    // Caption renders under its image.
    expect(find.text('Diagram: a literal source caption'), findsOneWidget);

    // Picture-first: BOTH images now render ABOVE the entire body. This
    // card was previously interleaved (afterParagraph -1 image led, the
    // afterParagraph 1 image sat between paragraphs 2 and 3); with the
    // all-cards picture-first change, both sit above the first paragraph.
    final order = tester
        .widgetList(find.descendant(
          of: find.byType(HandbookLessonCard),
          matching: find.byWidgetPredicate((w) => w is Image || w is Text),
        ))
        .toList();
    final imageIndexes = <int>[
      for (var i = 0; i < order.length; i++)
        if (order[i] is Image) i,
    ];
    int textIndex(String text) {
      for (var i = 0; i < order.length; i++) {
        final w = order[i];
        if (w is Text && (w.data ?? w.textSpan?.toPlainText()) == text) {
          return i;
        }
      }
      return -1;
    }

    final para1 = textIndex('First paragraph of the fixture body.');
    expect(imageIndexes, hasLength(2));
    expect(para1, isNot(-1));
    // Both images precede the first body paragraph.
    expect(imageIndexes.last, lessThan(para1));
    // Source list order is preserved: 01.webp renders above 02.webp. The
    // provider is unwrapped because reader pictures decode at their
    // on-screen width (perf audit A1), which wraps the AssetImage in a
    // ResizeImage.
    final assetNames = <String>[
      for (final w in order)
        if (w is Image && _assetNameOf(w) != null) _assetNameOf(w)!,
    ];
    expect(assetNames, <String>[
      'assets/internal/barrio/training/fixture/01.webp',
      'assets/internal/barrio/training/fixture/02.webp',
    ]);

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
