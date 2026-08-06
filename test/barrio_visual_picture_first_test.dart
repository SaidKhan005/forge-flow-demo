// Visual-first pass recs #1 + #3 (2026-07-24; picture-first extended to
// all cards 2026-07-26), render layer only.
//
// Covers: TERM glossary cards render their picture ABOVE the definition
// text (exactly once, credit caption and tap-to-zoom intact); every
// non-TERM (READ) card with images is picture-first too, rendering all
// of its images ABOVE the body in source list order; numeric fact tokens
// in body prose render as bold accent spans while the concatenated
// visible string stays byte-identical to the verbatim source; the
// per-manual accent resolves from the unit id prefix; search highlights
// win over the number pop; term links and number pops compose in one
// paragraph.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
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

const _kTermBody =
    'a vibrant fixture dish description that stands in for a verbatim '
    'glossary definition.';

const _kTermUnit = HandbookUnit(
  id: 'fixture_term_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'TERM',
  title: 'FIXTURE DISH',
  body: _kTermBody,
  images: [
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/01.webp',
      caption: 'Photo: Fixture Credit, CC BY-SA 4.0',
      afterParagraph: 0,
    ),
  ],
);

const _kReadBody = 'First paragraph of the fixture body.\n\n'
    'Second paragraph, which carries the picture.\n\n'
    'Third paragraph after the picture.';

/// A photograph plus a house-style diagram pictogram: two SEPARATE
/// picture holders, because a diagram never joins a photograph's slide
/// group (T10, 2026-08-02). That keeps this fixture testing the
/// picture-first stacking order rather than the slide holder.
const _kReadUnit = HandbookUnit(
  id: 'fixture_read_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture With Pictures',
  body: _kReadBody,
  images: [
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/01.webp',
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/02.webp',
      caption: 'Diagram: the fixture pictogram',
      afterParagraph: 1,
    ),
  ],
);

const _kNumericBody = 'Cook chicken to a safe 165 F before service.';

const _kNumericUnit = HandbookUnit(
  id: 'fixture_numeric_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Numeric Fixture',
  body: _kNumericBody,
);

const _kCoffeeNumericUnit = HandbookUnit(
  id: 'training_coffee_c1_u99',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Coffee Numeric Fixture',
  body: _kNumericBody,
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

/// Traversal-ordered Image/Text descendants of the lesson card.
List<Widget> _cardImageAndTextOrder(WidgetTester tester) {
  return tester
      .widgetList(find.descendant(
        of: find.byType(HandbookLessonCard),
        matching: find.byWidgetPredicate((w) => w is Image || w is Text),
      ))
      .toList();
}

/// Index of the Text widget whose visible string is [text], -1 if absent.
int _textIndex(List<Widget> widgets, String text) {
  for (var i = 0; i < widgets.length; i++) {
    final w = widgets[i];
    if (w is Text) {
      final plain = w.data ?? w.textSpan?.toPlainText();
      if (plain == text) return i;
    }
  }
  return -1;
}

/// All leaf TextSpans of the Text widget rendering [bodyText].
List<TextSpan> _spansOf(WidgetTester tester, String bodyText) {
  final textWidget = tester.widget<Text>(find.text(bodyText));
  final spans = <TextSpan>[];
  void visit(InlineSpan span) {
    if (span is TextSpan) {
      if (span.text != null) spans.add(span);
      for (final child in span.children ?? const <InlineSpan>[]) {
        visit(child);
      }
    }
  }

  visit(textWidget.textSpan!);
  return spans;
}

void main() {
  testWidgets('TERM card renders its picture above the definition text',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(_host(const HandbookLessonCard(unit: _kTermUnit)));
    await tester.pumpAndSettle();

    // Exactly one image: the flip never double-renders a picture.
    expect(find.byType(Image), findsOneWidget);

    final order = _cardImageAndTextOrder(tester);
    final imageIndex = order.indexWhere((w) => w is Image);
    final bodyIndex = _textIndex(order, _kTermBody);
    expect(imageIndex, isNot(-1));
    expect(bodyIndex, isNot(-1));
    expect(imageIndex, lessThan(bodyIndex),
        reason: 'TERM picture must render before the definition text');

    // Credit caption and tap-to-zoom viewer stay intact.
    expect(find.text('Photo: Fixture Credit, CC BY-SA 4.0'), findsOneWidget);
    await tester.tap(find.byType(Image), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(BarrioTrainingImageViewer), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'multi-image READ card is picture-first: all images above the body, '
      'in list order', (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(_host(const HandbookLessonCard(unit: _kReadUnit)));
    await tester.pumpAndSettle();

    expect(find.byType(Image), findsNWidgets(2));

    final order = _cardImageAndTextOrder(tester);
    final imageIndexes = <int>[
      for (var i = 0; i < order.length; i++)
        if (order[i] is Image) i,
    ];
    final para1 = _textIndex(order, 'First paragraph of the fixture body.');
    final para2 =
        _textIndex(order, 'Second paragraph, which carries the picture.');
    final para3 = _textIndex(order, 'Third paragraph after the picture.');
    expect(imageIndexes, hasLength(2));
    expect(para1, isNot(-1));
    expect(para2, isNot(-1));
    expect(para3, isNot(-1));
    // Picture-first for every imaged card (extended from TERM-only on
    // 2026-07-26): both images now render ABOVE the whole body. This
    // card previously interleaved (afterParagraph -1 image led, the
    // afterParagraph 1 image sat between paragraphs 2 and 3).
    expect(imageIndexes.last, lessThan(para1));
    expect(para1, lessThan(para2));
    expect(para2, lessThan(para3));
    // Source list order is preserved: 01.webp above 02.webp. The
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

  testWidgets('no-image card renders its body with no image widgets',
      (tester) async {
    await _setMobileSurface(tester);
    await tester
        .pumpWidget(_host(const HandbookLessonCard(unit: _kNumericUnit)));
    await tester.pumpAndSettle();

    // A card with no images is unchanged: body renders, zero image widgets.
    expect(find.byType(Image), findsNothing);
    expect(find.text(_kNumericBody), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'numeric fact renders as a bold accent span, string byte-identical',
      (tester) async {
    await _setMobileSurface(tester);
    await tester
        .pumpWidget(_host(const HandbookLessonCard(unit: _kNumericUnit)));
    await tester.pumpAndSettle();

    // The visible string is byte-identical to the verbatim source.
    expect(find.text(_kNumericBody), findsOneWidget);
    final textWidget = tester.widget<Text>(find.text(_kNumericBody));
    expect(textWidget.textSpan, isNotNull);
    expect(textWidget.textSpan!.toPlainText(), _kNumericBody);

    // The '165 F' token is bold in the accent color (explainer badge
    // fallback: tealWarm); surrounding prose is untouched.
    final spans = _spansOf(tester, _kNumericBody);
    final pop = spans.where((s) => s.text == '165 F').toList();
    expect(pop, hasLength(1));
    expect(pop.single.style?.fontWeight, FontWeight.w700);
    expect(pop.single.style?.color, BarrioColors.tealWarm);
    final plain = spans.where((s) => s.text != '165 F').toList();
    for (final span in plain) {
      expect(span.style?.fontWeight, isNot(FontWeight.w700));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('numeric accent resolves the owning manual color by id prefix',
      (tester) async {
    await _setMobileSurface(tester);
    await tester
        .pumpWidget(_host(const HandbookLessonCard(unit: _kCoffeeNumericUnit)));
    await tester.pumpAndSettle();

    final spans = _spansOf(tester, _kNumericBody);
    final pop = spans.where((s) => s.text == '165 F').toList();
    expect(pop, hasLength(1));
    expect(pop.single.style?.color, BarrioColors.accentCoffee);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search highlight wins: an overlapped number is not popped',
      (tester) async {
    await _setMobileSurface(tester);
    await tester.pumpWidget(_host(const HandbookLessonCard(
      unit: _kNumericUnit,
      highlightTerms: ['165'],
    )));
    await tester.pumpAndSettle();

    expect(find.text(_kNumericBody), findsOneWidget);
    final spans = _spansOf(tester, _kNumericBody);
    // The search mark claims '165'; the overlapping '165 F' token is
    // dropped whole, so no span carries the accent pop.
    final marked = spans.where((s) => s.text == '165').toList();
    expect(marked, hasLength(1));
    expect(marked.single.style?.backgroundColor, isNotNull);
    expect(spans.where((s) => s.text == '165 F'), isEmpty);
    for (final span in spans) {
      expect(span.style?.color, isNot(BarrioColors.tealWarm));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('term links and number pops compose in one paragraph',
      (tester) async {
    await _setMobileSurface(tester);
    const body = 'Serve AGUACHILE chilled and cook shrimp to 165 F.';
    const unit = HandbookUnit(
      id: 'fixture_compose_unit',
      type: HandbookUnitType.explainer,
      badgeHint: 'READ',
      title: 'Compose Fixture',
      body: body,
    );
    await tester.pumpWidget(_host(HandbookLessonCard(
      unit: unit,
      onTermTap: (_) {},
    )));
    await tester.pumpAndSettle();

    // The dotted-underline term link renders as its own tappable text.
    expect(
      find.byKey(const ValueKey<String>(
          'barrio_term_link_fixture_compose_unit_aguachile')),
      findsOneWidget,
    );
    // And the numeric pop still styles the temperature token.
    final textWidget = tester.widget<Text>(
      find.byWidgetPredicate((w) =>
          w is Text &&
          w.textSpan != null &&
          w.textSpan!.toPlainText().endsWith('cook shrimp to 165 F.')),
    );
    final spans = <TextSpan>[];
    void visit(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text != null) spans.add(span);
        for (final child in span.children ?? const <InlineSpan>[]) {
          visit(child);
        }
      }
    }

    visit(textWidget.textSpan!);
    final pop = spans.where((s) => s.text == '165 F').toList();
    expect(pop, hasLength(1));
    expect(pop.single.style?.fontWeight, FontWeight.w700);
    expect(tester.takeException(), isNull);
  });
}
