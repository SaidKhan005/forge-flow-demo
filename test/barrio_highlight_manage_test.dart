// Kindle-style highlights, Slice C: managing a mark the reader already
// made.
//
// WHAT THESE TESTS ARE GUARDING, and how each one can actually rot:
//
//  1. THE MARK IS REACHABLE. A wash nobody can tap is decoration. Every
//     path in here starts the way a reader starts: by tapping the marked
//     words themselves, or the note glyph beside them. Nothing calls the
//     screen's handlers directly, so a broken recognizer, a swallowed
//     gesture, or a sheet that never opens fails the test.
//
//  2. THE SPAN MEMO CACHE, AGAIN. Slice B put the resolved highlight
//     plan in the cache key so a new mark could not hide behind a warm
//     entry. A note draws a GLYPH into that same memoized run, so the
//     note itself has to be in the key too. The glyph test deliberately
//     warms the entry with a note-free mark first, then writes the note,
//     then checks the very next frame. Clearing a note is checked the
//     same way, in the other direction.
//
//  3. THE GESTURES THAT WERE ALREADY THERE. Span recognizers sit at the
//     paragraph's depth, and #1483 is the standing reminder that a
//     recognizer in the wrong place silently starves the carousel's edge
//     tap zones. A marked card is page-turned from both edges here.
//
//  4. LEGIBILITY. The note glyph and the removal red are both measured
//     against the surface they sit on, not eyeballed.
//
// Fixtures are three plainly-worded cards with no repeated phrases: the
// carousel keeps neighbouring pages alive, so a substring probe has to
// be unique across the whole live deck, not just the visible card.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlight_anchors.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_highlight_actions_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_highlight_note_sheet.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _marked = 'the guest';
const _firstPara = 'Serve the guest before you clear the table.';
const _secondPara = 'Reset each setting for whoever arrives next.';

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_manage_doc',
  title: 'Manage Fixture',
  sourcePath: 'test://fixture',
  chapters: <HandbookChapter>[
    HandbookChapter(
      id: 'mg_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: <HandbookUnit>[
        HandbookUnit(
          id: 'mg_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Service',
          body: '$_firstPara\n\n$_secondPara',
        ),
        HandbookUnit(
          id: 'mg_c1_u2',
          type: HandbookUnitType.explainer,
          title: 'Pace',
          body: 'Pouring water early buys you a calmer opening.',
        ),
        HandbookUnit(
          id: 'mg_c1_u3',
          type: HandbookUnitType.explainer,
          title: 'Close',
          body: 'Wipe down every rail once orders have stopped.',
        ),
      ],
    ),
  ],
);

/// A manage callback that is the SAME object on every pump.
///
/// This matters more than it looks. The card's span memo keys on the
/// manage callback (a note glyph is an inline widget closing over it),
/// so a fresh `(_) {}` per pump would miss the cache every single time
/// and the warm-cache test below would pass no matter what the plan's
/// equality did. The reading screen passes a method tear-off, which
/// compares equal across rebuilds; this mirrors that.
void _noOpHighlightTap(String highlightId) {}

/// The stored mark every reader-level test starts from: one passage,
/// gold, no note.
BarrioHighlight _stored({
  String color = 'gold',
  String note = '',
  String id = 'h_manage_0001',
}) {
  final start = _firstPara.indexOf(_marked);
  return BarrioHighlight(
    id: id,
    unitId: 'mg_c1_u1',
    color: color,
    note: note,
    createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
    segments: <BarrioHighlightSegment>[
      BarrioHighlightSegment(
        chunk: 0,
        start: start,
        end: start + _marked.length,
        text: _marked,
      ),
    ],
  );
}

/// Every body run the reader is showing, as (text, style) pairs.
List<(String, TextStyle?)> _bodyRuns(WidgetTester tester) {
  final out = <(String, TextStyle?)>[];
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final span = text.textSpan;
    final rootStyle = text.style ?? (span is TextSpan ? span.style : null);
    if (rootStyle == null || rootStyle.height != 1.62) continue;
    if (rootStyle.fontSize != 13.5 && rootStyle.fontSize != 12.5) continue;
    if (text.data != null) {
      out.add((text.data!, rootStyle));
      continue;
    }
    if (span is! TextSpan) continue;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan && child.text != null) {
        out.add((child.text!, rootStyle.merge(child.style)));
      }
    }
  }
  return out;
}

/// The background the marked words are painted on right now, or null
/// when nothing is marked.
Color? _washOnMarkedWords(WidgetTester tester) {
  for (final run in _bodyRuns(tester)) {
    if (run.$1 == _marked) return run.$2?.backgroundColor;
  }
  return null;
}

/// Every highlight in the fixture doc's store, decoded.
Future<List<BarrioHighlight>> _readStore() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(BarrioHighlightsService.keyFor(_fixtureDoc.id));
  if (raw == null) return const <BarrioHighlight>[];
  return <BarrioHighlight>[
    for (final entry in json.decode(raw) as List<Object?>)
      if (BarrioHighlight.decode(entry) case final decoded?) decoded,
  ];
}

// --- contrast ---------------------------------------------------------------

double _channel(int value) {
  final c = value / 255.0;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  return 0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpReader(WidgetTester tester, {Size size = phoneSize}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pumpAndSettle();
  }

  /// Taps the marked words the way a reader does: on the text itself.
  Future<void> tapTheMark(WidgetTester tester) async {
    await tester.tapOnText(find.textRange.ofSubstring(_marked));
    await tester.pumpAndSettle();
  }

  setUp(() {
    barrioClearBodySpanCache();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(barrioClearBodySpanCache);

  /// Seeds the store with [highlight] before the reader opens.
  void seed(BarrioHighlight highlight) {
    SharedPreferences.setMockInitialValues(<String, Object>{
      BarrioHighlightsService.keyFor(_fixtureDoc.id):
          json.encode(<Object?>[highlight.toJson()]),
    });
  }

  // -------------------------------------------------------------------------
  // Reaching a mark
  // -------------------------------------------------------------------------
  group('tapping a mark opens the actions sheet', () {
    testWidgets('tapping the marked words themselves', (tester) async {
      seed(_stored());
      await pumpReader(tester);
      expect(_washOnMarkedWords(tester), barrioHighlightWash('gold'),
          reason: 'sanity: the seeded mark is painted before anything is '
              'tapped');
      expect(find.byType(BarrioHighlightActionsSheet), findsNothing);

      await tapTheMark(tester);

      expect(find.byType(BarrioHighlightActionsSheet), findsOneWidget,
          reason: 'a wash nobody can tap is decoration, not a highlight');
      expect(find.text('Add note'), findsOneWidget);
      expect(find.text('Remove highlight'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the note glyph of a mark that carries a note',
        (tester) async {
      seed(_stored(note: 'Ask the chef about this.'));
      await pumpReader(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>(
            'barrio_highlight_note_h_manage_0001')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BarrioHighlightActionsSheet), findsOneWidget);
      // The row reads Edit, not Add, and shows what is already written.
      expect(find.text('Edit note'), findsOneWidget);
      expect(find.text('Ask the chef about this.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Recolour
  // -------------------------------------------------------------------------
  group('recolouring a mark', () {
    testWidgets('picking a colour repaints it and survives a reopen',
        (tester) async {
      seed(_stored());
      await pumpReader(tester);
      await tapTheMark(tester);

      await tester
          .tap(find.byKey(const ValueKey<String>('barrio_highlight_color_plum')));
      await tester.pumpAndSettle();

      // Painted straight away, behind the open sheet.
      expect(_washOnMarkedWords(tester), barrioHighlightWash('plum'),
          reason: 'the resolved plan is part of the span cache key, so a '
              'recolour repaints on the next frame');

      // Written to the device store as a TOKEN, never an ARGB int.
      final stored = await _readStore();
      expect(stored, hasLength(1));
      expect(stored.single.color, 'plum');
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(BarrioHighlightsService.kLastColorKey),
        'plum',
        reason: 'reaching for a marker is choosing one: the next mark the '
            'reader makes uses it',
      );

      // And it comes back that colour when the manual is reopened.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      barrioClearBodySpanCache();
      await pumpReader(tester);
      expect(_washOnMarkedWords(tester), barrioHighlightWash('plum'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the current colour is the ticked one, and only that one',
        (tester) async {
      seed(_stored(color: 'steel'));
      await pumpReader(tester);
      await tapTheMark(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('barrio_highlight_color_steel')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
        reason: 'the stored colour opens ticked',
      );
      for (final token in const <String>['gold', 'fresh', 'plum']) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey<String>('barrio_highlight_color_$token')),
            matching: find.byIcon(Icons.check_rounded),
          ),
          findsNothing,
          reason: '$token is not the chosen marker',
        );
      }
    });
  });

  // -------------------------------------------------------------------------
  // Remove, and the way back
  // -------------------------------------------------------------------------
  group('removing a mark', () {
    testWidgets('one tap removes it, and Undo puts the same record back',
        (tester) async {
      final original = _stored(color: 'fresh', note: 'Worth keeping.');
      seed(original);
      await pumpReader(tester);
      await tapTheMark(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_remove_action')),
      );
      await tester.pumpAndSettle();

      // Gone from the page and from the store, with no confirm dialog in
      // between.
      expect(find.byType(BarrioHighlightActionsSheet), findsNothing);
      expect(_washOnMarkedWords(tester), isNull);
      expect(await _readStore(), isEmpty);
      expect(find.text(_firstPara), findsOneWidget,
          reason: 'verbatim law: the card still reads word for word');

      // The way back is offered in the same breath.
      expect(find.text('Highlight removed.'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();

      expect(_washOnMarkedWords(tester), barrioHighlightWash('fresh'),
          reason: 'Undo restores the mark, in its own colour');
      final restored = await _readStore();
      expect(restored, hasLength(1));
      expect(restored.single.id, original.id);
      expect(restored.single.color, 'fresh');
      expect(restored.single.note, 'Worth keeping.');
      expect(restored.single.createdAt, original.createdAt);
      expect(restored.single.segments.single.text, _marked);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Notes
  // -------------------------------------------------------------------------
  group('notes', () {
    testWidgets('a note written in the editor round-trips to the store and '
        'back into the sheet', (tester) async {
      seed(_stored());
      await pumpReader(tester);
      await tapTheMark(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_note_action')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(BarrioHighlightNoteSheet), findsOneWidget);
      expect(find.text('Your note'), findsOneWidget);
      // The words the note is about are quoted above the field.
      expect(find.text(_marked), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_highlight_note_field')),
        'Water first, then the menus.',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_note_save')),
      );
      await tester.pumpAndSettle();

      final stored = await _readStore();
      expect(stored, hasLength(1));
      expect(stored.single.note, 'Water first, then the menus.');
      // Everything else about the mark is untouched.
      expect(stored.single.color, 'gold');
      expect(stored.single.segments.single.text, _marked);

      // Reopening shows Edit, with the note previewed.
      await tapTheMark(tester);
      expect(find.text('Edit note'), findsOneWidget);
      expect(find.text('Water first, then the menus.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Cancel writes nothing', (tester) async {
      seed(_stored());
      await pumpReader(tester);
      await tapTheMark(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_note_action')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey<String>('barrio_highlight_note_field')),
        'Typed then thought better of it.',
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('barrio_highlight_note_cancel')),
      );
      await tester.pumpAndSettle();

      expect((await _readStore()).single.note, isEmpty);
      expect(
        find.byKey(
            const ValueKey<String>('barrio_highlight_note_h_manage_0001')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the note glyph appears against a WARM span cache',
        (tester) async {
      // This is the trap Slice B left behind: the glyph is composed in
      // the same memoized pass as the wash, so a note written right now
      // would hit a warm entry and stay invisible unless the note is
      // part of the cache key.
      const unit = HandbookUnit(
        id: 'mg_cache_u1',
        type: HandbookUnitType.explainer,
        title: 'Cache',
        body: 'Chill the glass before you pour the drink.',
      );
      final start = unit.body.indexOf('Chill the glass');
      BarrioHighlight mark(String note) => BarrioHighlight(
            id: 'h_note_0001',
            unitId: unit.id,
            color: 'gold',
            note: note,
            createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
            segments: <BarrioHighlightSegment>[
              BarrioHighlightSegment(
                chunk: 0,
                start: start,
                end: start + 'Chill the glass'.length,
                text: 'Chill the glass',
              ),
            ],
          );

      Future<void> pumpCard(BarrioHighlight highlight) async {
        tester.view.physicalSize = phoneSize;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HandbookLessonCard(
                  unit: unit,
                  highlights: <BarrioHighlight>[highlight],
                  onHighlightTap: _noOpHighlightTap,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      const glyph = ValueKey<String>('barrio_highlight_note_h_note_0001');

      // Frame 1: marked, no note. This RECORDS the span pass, so a
      // rebuild with the same key would replay it wholesale.
      await pumpCard(mark(''));
      expect(find.byKey(glyph), findsNothing,
          reason: 'sanity: a mark with no note carries no glyph');

      // Frame 2: the reader writes a note. Same card, same body, same
      // mark, same offsets: everything the old key held.
      await pumpCard(mark('Ask about the freezer.'));
      expect(find.byKey(glyph), findsOneWidget,
          reason: 'the note is part of the span cache key, so writing one '
              'misses the warm entry and recomposes on the next frame');

      // Frame 3: the reader EDITS the note. Presence did not change, so
      // only comparing the note text itself catches this one. The glyph
      // reads the note out to a screen reader, so a stale one is a stale
      // claim about what the reader wrote.
      await pumpCard(mark('Ask about the walk-in instead.'));
      expect(
        tester
            .widget<Semantics>(find
                .ancestor(of: find.byKey(glyph), matching: find.byType(Semantics))
                .first)
            .properties
            .label,
        'Your note: Ask about the walk-in instead.',
        reason: 'the note TEXT is part of the span cache key, not just '
            'whether there is one',
      );

      // And the other direction: clearing it takes the glyph away.
      await pumpCard(mark(''));
      expect(find.byKey(glyph), findsNothing,
          reason: 'clearing a note has to miss the warm entry too');

      // Verbatim law throughout: the glyph adds no characters.
      expect(_bodyRuns(tester).map((r) => r.$1).join(), unit.body);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Accessibility and fit
  // -------------------------------------------------------------------------
  group('the sheet is usable', () {
    testWidgets('every colour dot and every action is labelled for a screen '
        'reader', (tester) async {
      final handle = tester.ensureSemantics();
      seed(_stored(note: 'A note.'));
      await pumpReader(tester);
      await tapTheMark(tester);

      for (final label in const <String>[
        'Gold marker',
        'Green marker',
        'Purple marker',
        'Blue marker',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget,
            reason: 'a colour swatch needs a name a screen reader can say');
      }
      expect(find.bySemanticsLabel(RegExp('Edit note')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Remove highlight')), findsWidgets);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('the sheet fits a 360dp phone at 1.6x text', (tester) async {
      seed(_stored(note: 'A note long enough to want a second line of room.'));
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
        ),
      );
      await tester.pumpAndSettle();
      await tapTheMark(tester);

      expect(find.byType(BarrioHighlightActionsSheet), findsOneWidget);
      expect(find.text('Remove highlight'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'no overflow at the narrowest phone and large text');
    });
  });

  // -------------------------------------------------------------------------
  // The gestures that were already there
  // -------------------------------------------------------------------------
  group('reading gestures survive a tappable mark', () {
    /// The same in-card edge probe barrio_content_card_edge_tap_test.dart
    /// uses: inside the card content, inside the carousel's invisible
    /// edge band, clear of the chevron gutters.
    Future<void> tapCardEdgeZone(
      WidgetTester tester, {
      required bool right,
    }) async {
      final rect = tester.getRect(find.byType(PageView));
      final x = right ? rect.right - 62 : rect.left + 62;
      await tester.tapAt(Offset(x, rect.top + 36));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('marking a passage registers no new gesture recognizer on the '
        'card', (tester) async {
      // The structural half of the #1483 lesson, and the sharper one: an
      // end-to-end edge tap only probes one band of one card, but this
      // counts. A tappable mark must live in the paragraph that already
      // renders the words, NOT in a widget wrapped around it, because a
      // wrapper competes with the carousel's tap zones everywhere it
      // covers, not just where a test happens to poke.
      const unit = HandbookUnit(
        id: 'mg_arena_u1',
        type: HandbookUnitType.explainer,
        title: 'Arena',
        body: 'Chill the glass before you pour the drink.',
      );
      final start = unit.body.indexOf('Chill the glass');
      final mark = BarrioHighlight(
        id: 'h_arena_0001',
        unitId: unit.id,
        color: 'gold',
        note: '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
        segments: <BarrioHighlightSegment>[
          BarrioHighlightSegment(
            chunk: 0,
            start: start,
            end: start + 'Chill the glass'.length,
            text: 'Chill the glass',
          ),
        ],
      );

      Future<int> recognizersFor(List<BarrioHighlight> highlights) async {
        barrioClearBodySpanCache();
        tester.view.physicalSize = phoneSize;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: HandbookLessonCard(
                  unit: unit,
                  highlights: highlights,
                  onHighlightTap: _noOpHighlightTap,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        return tester.widgetList(find.byType(RawGestureDetector)).length;
      }

      final unmarked = await recognizersFor(const <BarrioHighlight>[]);
      final marked = await recognizersFor(<BarrioHighlight>[mark]);
      expect(marked, unmarked,
          reason: 'a mark must add no gesture detector to the card: the tap '
              'belongs to the text span, at the paragraph\'s depth, where '
              'term links have sat since 2026-07-23');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a marked card still turns the page from either edge',
        (tester) async {
      seed(_stored(note: 'And it carries a note glyph too.'));
      await pumpReader(tester);
      expect(find.text('1 of 3'), findsOneWidget);
      expect(_washOnMarkedWords(tester), isNotNull,
          reason: 'sanity: the card under test really is marked');

      await tapCardEdgeZone(tester, right: true);
      expect(find.text('2 of 3'), findsOneWidget,
          reason: 'span recognizers must not starve the carousel edge tap '
              'zones (the #1483 lesson)');

      await tapCardEdgeZone(tester, right: false);
      expect(find.text('1 of 3'), findsOneWidget);
      expect(find.byType(BarrioHighlightActionsSheet), findsNothing,
          reason: 'an edge tap is a page turn, not a mark tap');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the selection menu offers exactly its four labelled actions',
        (tester) async {
      // Slice C added nothing to this toolbar: a fourth action would have
      // pushed "Search the web" behind an overflow chevron. Slice D
      // replaced the toolbar outright and put the marker pens on a row of
      // their own, so the labelled actions went from three to four and
      // the count moved with them. What this still guards is that the
      // inventory is CLOSED: nothing else has crept onto the toolbar,
      // where it would compete for the same 344px.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        seed(_stored());
        await pumpReader(tester);
        tester
            .state<SelectableRegionState>(find.byType(SelectableRegion))
            .selectAll(SelectionChangedCause.toolbar);
        await tester.pumpAndSettle();

        expect(find.text('Highlight'), findsOneWidget);
        expect(find.text('Ask chat'), findsOneWidget);
        expect(find.text('Search the web'), findsOneWidget);
        expect(find.text('Add note'), findsOneWidget);
        expect(find.byType(TextButton), findsNWidgets(4),
            reason: 'four labelled actions, no fifth');
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  // -------------------------------------------------------------------------
  // Legibility
  // -------------------------------------------------------------------------
  group('legibility is measured, not assumed', () {
    test('every note glyph clears the 3:1 non-text floor on the card', () {
      // The card surface a body glyph is drawn on: white glass over the
      // cream page.
      final surface =
          Color.alphaBlend(BarrioColors.glassFill, BarrioColors.shellDeep);
      final measured = <String, double>{
        for (final token in kBarrioHighlightColorTokens)
          token: _contrast(surface, barrioHighlightNoteGlyphColor(token)),
      };
      printOnFailure('measured note glyph contrast: $measured');
      for (final entry in measured.entries) {
        expect(entry.value, greaterThanOrEqualTo(3.0),
            reason: '${entry.key} glyph measured ${entry.value}');
      }
    });

    test('the removal red clears AA on the sheet surface', () {
      final measured =
          _contrast(BarrioColors.shellDeep, kBarrioHighlightRemoveRed);
      printOnFailure('measured removal red contrast: $measured');
      expect(measured, greaterThanOrEqualTo(4.5),
          reason: 'a destructive action label has to be readable, not just '
              'red');
      // And it really is quieter than the raw house red would be loud:
      // the house error red does NOT clear the floor here, which is why
      // this constant exists at all.
      expect(_contrast(BarrioColors.shellDeep, BarrioColors.error),
          lessThan(4.5));
    });
  });
}
