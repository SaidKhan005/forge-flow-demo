// Characterization tests for the shared body-chunk parser
// (`content/barrio_body_chunks.dart`, Kindle-style highlights Slice A).
//
// WHY THESE TESTS EXIST. Highlight offsets are addressed against the
// RENDERED chunk. If `chunksForBody` and the lesson card's own parse
// ever disagree by one character, a stored highlight paints on the
// wrong words. Until Slice B deletes the card's private parse, the two
// implementations live side by side, so this file pins them together:
//
//   * pure rule tests on crafted strings (paragraph split, bullet and
//     numbered marker stripping, table cell split and trim, same-kind
//     run grouping, chunk numbering), and
//   * render-equality tests that pump a REAL shipped training card and
//     assert the strings the card actually put on screen are, in order
//     and byte for byte, the strings `chunksForBody` produces.
//
// Fixtures are picked at RUNTIME by scanning the shipped registry for
// the card that renders the MOST chunks of each block kind, so the
// tests survive content regeneration: no manual is named, and no
// "manual X has no tables" assumption is baked in. If a kind is absent
// from the whole corpus the case skips honestly instead of failing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/barrio_body_chunks.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

/// Every unit of every shipped training manual, in registry order.
Iterable<HandbookUnit> _allUnits() => kBarrioTrainingDocs.values
    .expand((doc) => doc.chapters)
    .expand((chapter) => chapter.units);

/// Cards a widget test can pump cheaply and honestly.
///
/// Only picture-free explainer cards qualify: an explainer always
/// renders its body (card line 330), and a picture-free card keeps the
/// test off the asset bundle. The length bound just keeps the pumped
/// tree small. None of the three touches the parse, which is a pure
/// function of the body string.
Iterable<HandbookUnit> _pumpableUnits() => _allUnits().where((unit) =>
    unit.type == HandbookUnitType.explainer &&
    unit.images.isEmpty &&
    unit.body.trim().isNotEmpty &&
    unit.body.length <= 3000);

/// The shipped card that renders the MOST chunks of [kind] (shortest
/// body wins a tie), or null when no shipped card renders that kind.
///
/// Richest-wins, not first-found, so each case exercises a real list or
/// table with many rows instead of a two-word stub. Picked by scanning
/// the registry, so no manual is named and content can change freely.
HandbookUnit? _richestUnitRendering(BarrioBodyChunkKind kind) {
  HandbookUnit? best;
  var bestCount = 0;
  for (final unit in _pumpableUnits()) {
    final count =
        chunksForBody(unit.body).where((c) => c.kind == kind).length;
    if (count == 0) continue;
    if (count > bestCount ||
        (count == bestCount &&
            best != null &&
            unit.body.length < best.body.length)) {
      best = unit;
      bestCount = count;
    }
  }
  return best;
}

/// The shipped card mixing the most block kinds in one body (most
/// chunks wins a tie), or null when every shipped card is single-kind.
HandbookUnit? _richestMixedUnit() {
  HandbookUnit? best;
  var bestKinds = 1;
  var bestChunks = 0;
  for (final unit in _pumpableUnits()) {
    final chunks = chunksForBody(unit.body);
    final kinds = chunks.map((c) => c.kind).toSet().length;
    if (kinds < 2) continue;
    if (kinds > bestKinds ||
        (kinds == bestKinds && chunks.length > bestChunks)) {
      best = unit;
      bestKinds = kinds;
      bestChunks = chunks.length;
    }
  }
  return best;
}

/// Body text as the card actually rendered it, in reading order.
///
/// The body chunks are the only `Text`s the card styles at the body
/// sizes: 13.5 for prose, bullets, and numbered rows (card lines 706 to
/// 710) and 12.5 for table cells (card line 862), both at height 1.62.
/// The 'N.' marker beside a numbered row is IBM Plex Mono at 13 (card
/// lines 836 to 838), so it is excluded, exactly as the parser excludes
/// it from the chunk text.
///
/// A chunk with no emphasis renders as a plain `Text` carrying the
/// style; a chunk with any emphasis renders as `Text.rich`, which hangs
/// the same style on the root span instead (card lines 952 and 954).
/// Both shapes are read here, and the plain text of a rich chunk is the
/// unchanged body string (the verbatim law: styling only).
List<String> _renderedBodyTexts(WidgetTester tester) {
  final out = <String>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final span = text.textSpan;
    final style = text.style ?? (span is TextSpan ? span.style : null);
    if (style == null || style.height != 1.62) continue;
    if (style.fontSize != 13.5 && style.fontSize != 12.5) continue;
    out.add(
      text.data ??
          (span == null
              ? ''
              : span.toPlainText(
                  includeSemanticsLabels: false,
                  includePlaceholders: false,
                )),
    );
  }
  return out;
}

Future<void> _pumpCard(WidgetTester tester, HandbookUnit unit) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: HandbookLessonCard(unit: unit)),
      ),
    ),
  );
  await tester.pump();
}

/// Pumps [unit] and asserts the card rendered exactly the chunk texts
/// `chunksForBody` produces, in order. [minChunksOfKind] guards that the
/// runtime-picked fixture is still a meaningful example of [kind].
Future<void> _expectRenderMatchesChunks(
  WidgetTester tester,
  HandbookUnit unit, {
  BarrioBodyChunkKind? kind,
  int minChunksOfKind = 1,
}) async {
  await _pumpCard(tester, unit);
  final chunks = chunksForBody(unit.body);
  final expected = [for (final c in chunks) c.text];
  expect(expected, isNotEmpty, reason: 'sanity: the fixture has a body');
  if (kind != null) {
    expect(chunks.where((c) => c.kind == kind).length,
        greaterThanOrEqualTo(minChunksOfKind),
        reason: 'sanity: the picked fixture really exercises ${kind.name}');
  } else {
    expect(expected.length, greaterThanOrEqualTo(minChunksOfKind),
        reason: 'sanity: the picked fixture has more than one chunk');
  }
  expect(
    _renderedBodyTexts(tester),
    equals(expected),
    reason: 'the parser must reproduce the card\'s rendered chunks '
        'byte for byte, in order (unit ${unit.id})',
  );
  expect(tester.takeException(), isNull);
}

void main() {
  group('chunksForBody: paragraph and prose rules', () {
    test('a lone prose paragraph is one verbatim chunk', () {
      final chunks = chunksForBody('One plain paragraph of words.');
      expect(chunks, hasLength(1));
      expect(chunks.single.index, 0);
      expect(chunks.single.kind, BarrioBodyChunkKind.prose);
      expect(chunks.single.text, 'One plain paragraph of words.');
    });

    test('paragraphs split on a blank line, each verbatim and untrimmed',
        () {
      final chunks = chunksForBody('First para.\n\nSecond para.\n\nThird.');
      expect([for (final c in chunks) c.text],
          ['First para.', 'Second para.', 'Third.']);
      expect(chunks.every((c) => c.kind == BarrioBodyChunkKind.prose), isTrue);
      expect([for (final c in chunks) c.index], [0, 1, 2]);
    });

    test('a single newline inside a paragraph never splits it', () {
      final chunks = chunksForBody('Line one\nstill the same paragraph.');
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'Line one\nstill the same paragraph.');
    });
  });

  group('chunksForBody: bullets', () {
    test('the leading "- " is dropped (the card draws the dot)', () {
      final chunks = chunksForBody('- First point\n\n- Second point');
      expect([for (final c in chunks) c.kind], [
        BarrioBodyChunkKind.bullet,
        BarrioBodyChunkKind.bullet,
      ]);
      expect([for (final c in chunks) c.text], ['First point', 'Second point']);
    });

    test('a leading-whitespace bullet is still a bullet, marker dropped', () {
      final chunks = chunksForBody('   - Indented point');
      expect(chunks.single.kind, BarrioBodyChunkKind.bullet);
      expect(chunks.single.text, 'Indented point');
    });

    test('a bullet that also contains " | " is a bullet, not a table', () {
      final chunks = chunksForBody('- Pour | then stir');
      expect(chunks.single.kind, BarrioBodyChunkKind.bullet);
      expect(chunks.single.text, 'Pour | then stir',
          reason: 'the bullet rule is checked before the table rule');
    });
  });

  group('chunksForBody: numbered steps', () {
    test('the "N. " marker is dropped (the card renders it separately)', () {
      final chunks = chunksForBody('1. Chill the glass\n\n2. Pour slowly');
      expect([for (final c in chunks) c.kind], [
        BarrioBodyChunkKind.numbered,
        BarrioBodyChunkKind.numbered,
      ]);
      expect([for (final c in chunks) c.text],
          ['Chill the glass', 'Pour slowly']);
    });

    test('multi-digit markers and wrapped step text are handled', () {
      final chunks = chunksForBody('12. Step twelve\nwraps to a second line');
      expect(chunks.single.kind, BarrioBodyChunkKind.numbered);
      expect(chunks.single.text, 'Step twelve\nwraps to a second line');
    });

    test('a bare number with no words after it stays prose', () {
      final chunks = chunksForBody('1.');
      expect(chunks.single.kind, BarrioBodyChunkKind.prose);
      expect(chunks.single.text, '1.');
    });
  });

  group('chunksForBody: tables', () {
    test('each row splits on " | " and every cell is trimmed', () {
      final chunks = chunksForBody(
        'Spirit | Style | Notes\n\nTequila |  Blanco  | Bright',
      );
      expect(chunks.every((c) => c.kind == BarrioBodyChunkKind.tableCell),
          isTrue);
      expect([for (final c in chunks) c.text], [
        'Spirit',
        'Style',
        'Notes',
        'Tequila',
        'Blanco',
        'Bright',
      ]);
      expect([for (final c in chunks) c.index], [0, 1, 2, 3, 4, 5]);
    });

    test('a paragraph with no " | " is prose, even right after a table', () {
      final chunks = chunksForBody('A | B\n\n  Just a paragraph  ');
      expect([for (final c in chunks) c.kind], [
        BarrioBodyChunkKind.tableCell,
        BarrioBodyChunkKind.tableCell,
        BarrioBodyChunkKind.prose,
      ]);
      expect([for (final c in chunks) c.text],
          ['A', 'B', '  Just a paragraph  '],
          reason: 'table cells are trimmed, prose stays verbatim');
    });
  });

  group('chunksForBody: mixed bodies keep reading order', () {
    test('prose, bullets, numbered steps, and a table all in one body', () {
      final chunks = chunksForBody(
        'Opening prose.\n\n'
        '- Bullet one\n\n'
        '- Bullet two\n\n'
        'Middle prose.\n\n'
        '1. Step one\n\n'
        '2. Step two\n\n'
        'Head A | Head B\n\n'
        'Cell A | Cell B\n\n'
        'Closing prose.',
      );
      expect([for (final c in chunks) (c.index, c.kind, c.text)], [
        (0, BarrioBodyChunkKind.prose, 'Opening prose.'),
        (1, BarrioBodyChunkKind.bullet, 'Bullet one'),
        (2, BarrioBodyChunkKind.bullet, 'Bullet two'),
        (3, BarrioBodyChunkKind.prose, 'Middle prose.'),
        (4, BarrioBodyChunkKind.numbered, 'Step one'),
        (5, BarrioBodyChunkKind.numbered, 'Step two'),
        (6, BarrioBodyChunkKind.tableCell, 'Head A'),
        (7, BarrioBodyChunkKind.tableCell, 'Head B'),
        (8, BarrioBodyChunkKind.tableCell, 'Cell A'),
        (9, BarrioBodyChunkKind.tableCell, 'Cell B'),
        (10, BarrioBodyChunkKind.prose, 'Closing prose.'),
      ]);
    });

    test('offsets into a chunk address the rendered words, not the body', () {
      const body = '- Serve the guest first';
      final chunk = chunksForBody(body).single;
      // 'guest' sits at 10 in the chunk and at 12 in the raw body: the
      // whole reason anchors are chunk-relative.
      expect(chunk.text.substring(10, 15), 'guest');
      expect(body.substring(10, 15), isNot('guest'));
    });
  });

  group('chunksForBody: real shipped manuals render exactly these chunks',
      () {
    testWidgets('the most paragraph-heavy card', (tester) async {
      final unit = _richestUnitRendering(BarrioBodyChunkKind.prose);
      if (unit == null) {
        markTestSkipped('no shipped card renders prose');
        return;
      }
      await _expectRenderMatchesChunks(tester, unit, minChunksOfKind: 2);
    });

    testWidgets('the longest bullet list', (tester) async {
      final unit = _richestUnitRendering(BarrioBodyChunkKind.bullet);
      if (unit == null) {
        markTestSkipped('no shipped card currently renders a bullet list');
        return;
      }
      await _expectRenderMatchesChunks(tester, unit,
          kind: BarrioBodyChunkKind.bullet, minChunksOfKind: 2);
    });

    testWidgets('the longest numbered list', (tester) async {
      final unit = _richestUnitRendering(BarrioBodyChunkKind.numbered);
      if (unit == null) {
        markTestSkipped('no shipped card currently renders numbered steps');
        return;
      }
      await _expectRenderMatchesChunks(tester, unit,
          kind: BarrioBodyChunkKind.numbered, minChunksOfKind: 2);
    });

    testWidgets('the biggest table', (tester) async {
      final unit = _richestUnitRendering(BarrioBodyChunkKind.tableCell);
      if (unit == null) {
        markTestSkipped('no shipped card currently renders a table');
        return;
      }
      await _expectRenderMatchesChunks(tester, unit,
          kind: BarrioBodyChunkKind.tableCell, minChunksOfKind: 4);
    });

    testWidgets('the card mixing the most block kinds', (tester) async {
      final unit = _richestMixedUnit();
      if (unit == null) {
        markTestSkipped('no shipped card mixes prose with a list or table');
        return;
      }
      await _expectRenderMatchesChunks(tester, unit);
    });
  });
}
