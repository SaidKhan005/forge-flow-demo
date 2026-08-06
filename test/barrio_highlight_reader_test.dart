// Kindle-style highlights, Slice B: the reader end to end.
//
// The render and resolution rules live in
// `barrio_highlight_render_test.dart`. THIS file proves the wiring the
// reader actually touches:
//
//   * the selection menu offers Highlight alongside the two existing
//     actions,
//   * tapping it marks what is selected, across paragraph boundaries,
//     in one highlight with one segment per chunk,
//   * the mark paints immediately,
//   * it is written to the device store under the doc's own key, and
//   * it comes back painted when the manual is reopened.
//
// The last one is the point of the whole slice: a highlight that does
// not survive closing the manual is not a highlight.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/screens/training_doc_screen.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlight_anchors.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _firstPara = 'Serve the guest before you clear the table.';
const _secondPara = 'Then reset the setting for the next party.';

const _fixtureDoc = BarrioTrainingDoc(
  id: 'fixture_highlight_doc',
  title: 'Highlight Fixture',
  sourcePath: 'test://fixture',
  chapters: <HandbookChapter>[
    HandbookChapter(
      id: 'hl_ch1',
      title: 'Only Section',
      subtitle: 'fixture section',
      iconCodePoint: 0xe533,
      units: <HandbookUnit>[
        HandbookUnit(
          id: 'hl_c1_u1',
          type: HandbookUnitType.explainer,
          title: 'Service',
          body: '$_firstPara\n\n$_secondPara',
        ),
      ],
    ),
  ],
);

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

/// The washed runs, in reading order.
List<String> _washedTexts(WidgetTester tester) => <String>[
      for (final run in _bodyRuns(tester))
        if (run.$2?.backgroundColor != null) run.$1,
    ];

void main() {
  const phoneSize = Size(390, 844);

  Future<void> pumpReader(WidgetTester tester) async {
    tester.view.physicalSize = phoneSize;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
    );
    await tester.pumpAndSettle();
  }

  /// Selects both paragraphs of the open card and floats the reader's
  /// own selection menu, so it is on screen and tappable when this
  /// returns.
  ///
  /// A reader does this with a long-press and a drag. A widget test
  /// cannot: a long-press drag across a scrollable trips a framework
  /// assertion in `_ScrollableSelectionContainerDelegate`
  /// (`!_selectionStartsInScrollable`, scrollable.dart:1268), and that
  /// happens on this screen with or without the highlight anchors, so it
  /// is Flutter's, not this slice's. `selectAll` with a toolbar cause is
  /// the same public entry point the framework uses and lands in exactly
  /// the same place: a real multi-chunk selection with the menu shown.
  Future<void> selectAcrossBothParagraphs(WidgetTester tester) async {
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
  }

  setUp(() {
    barrioClearBodySpanCache();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('the selection menu offers Highlight alongside Ask chat and '
      'Search the web', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpReader(tester);
      await selectAcrossBothParagraphs(tester);

      expect(find.text('Highlight'), findsOneWidget);
      expect(find.text('Ask chat'), findsOneWidget);
      expect(find.text('Search the web'), findsOneWidget);
      // Operator curation (2026-07-29): the native defaults stay dropped.
      expect(find.text('Copy'), findsNothing);
      expect(find.text('Select all'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('all three actions stay on one row at 360dp, the narrowest '
      'phone', (tester) async {
    // TextSelectionToolbar does not wrap. An action that does not fit is
    // pushed behind an overflow chevron, where a reader will not look
    // for it, and nothing warns you. Going from two actions to three is
    // exactly when that happens: at the original 16px button padding
    // "Search the web" fell off even a 390dp phone.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: TrainingDocScreen(doc: _fixtureDoc)),
      );
      await tester.pumpAndSettle();
      await selectAcrossBothParagraphs(tester);

      var used = 0.0;
      for (final label in const <String>[
        'Highlight',
        'Ask chat',
        'Search the web',
      ]) {
        expect(find.text(label), findsOneWidget,
            reason: '"$label" must be on the row, not behind the overflow '
                'chevron');
        used += tester
            .getSize(find.ancestor(
              of: find.text(label),
              matching: find.byType(TextButton),
            ))
            .width;
      }
      // 360 less the toolbar's 8px screen padding each side.
      expect(used, lessThan(344),
          reason: 'measured row width was $used');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Highlight marks the selection across both paragraphs, paints '
      'it, and stores it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await pumpReader(tester);

      // Nothing marked before the reader asks for it.
      expect(_washedTexts(tester), isEmpty);

      await selectAcrossBothParagraphs(tester);
      await tester.tap(find.text('Highlight'));
      await tester.pumpAndSettle();

      // Stored, under this doc's own key, as ONE highlight carrying one
      // segment per chunk the drag touched.
      final prefs = await SharedPreferences.getInstance();
      final raw =
          prefs.getString(BarrioHighlightsService.keyFor(_fixtureDoc.id));
      expect(raw, isNotNull, reason: 'the mark must reach the device store');
      final entries = json.decode(raw!) as List<Object?>;
      expect(entries, hasLength(1),
          reason: 'a selection over two paragraphs is ONE highlight');
      final stored = BarrioHighlight.decode(entries.single)!;
      expect(stored.unitId, 'hl_c1_u1');
      expect(stored.color, kBarrioHighlightDefaultColor);
      expect(stored.segments.map((s) => s.chunk).toList(), <int>[0, 1],
          reason: 'one segment per rendered chunk, in reading order');
      expect(_firstPara, contains(stored.segments[0].text));
      expect(_secondPara, contains(stored.segments[1].text));

      // Painted right away, on exactly the words that were stored.
      expect(
        _washedTexts(tester),
        <String>[stored.segments[0].text, stored.segments[1].text],
      );
      final wash = barrioHighlightWash(kBarrioHighlightDefaultColor);
      for (final text in _washedTexts(tester)) {
        expect(
          _bodyRuns(tester).firstWhere((r) => r.$1 == text).$2?.backgroundColor,
          wash,
        );
      }
      // Verbatim law: the card still reads word for word.
      expect(_bodyRuns(tester).map((r) => r.$1).join(),
          '$_firstPara$_secondPara');
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a stored highlight comes back painted when the manual is '
      'reopened', (tester) async {
    final highlight = BarrioHighlight(
      id: 'h_remount_0001',
      unitId: 'hl_c1_u1',
      color: 'plum',
      note: '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
      segments: const <BarrioHighlightSegment>[
        BarrioHighlightSegment(
          chunk: 0,
          start: 6,
          end: 15,
          text: 'the guest',
        ),
      ],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      BarrioHighlightsService.keyFor(_fixtureDoc.id):
          json.encode(<Object?>[highlight.toJson()]),
    });

    await pumpReader(tester);

    expect(_washedTexts(tester), <String>['the guest'],
        reason: 'the stored mark paints on exactly the stored words');
    final marked = _bodyRuns(tester).firstWhere((r) => r.$1 == 'the guest');
    expect(marked.$2?.backgroundColor, barrioHighlightWash('plum'),
        reason: 'the stored colour token, not the default');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored highlight whose words are gone paints nothing and '
      'crashes nothing', (tester) async {
    final orphan = BarrioHighlight(
      id: 'h_orphan_0001',
      unitId: 'hl_c1_u1',
      color: 'gold',
      note: 'still worth keeping',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1722400000000),
      segments: const <BarrioHighlightSegment>[
        BarrioHighlightSegment(
          chunk: 0,
          start: 0,
          end: 24,
          text: 'words from an older draft',
        ),
      ],
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      BarrioHighlightsService.keyFor(_fixtureDoc.id):
          json.encode(<Object?>[orphan.toJson()]),
    });

    await pumpReader(tester);

    expect(_washedTexts(tester), isEmpty);
    expect(find.text(_firstPara), findsOneWidget,
        reason: 'the card reads exactly as it always did');
    expect(tester.takeException(), isNull);

    // And it is still in storage: it reappears if the content returns.
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(BarrioHighlightsService.keyFor(_fixtureDoc.id));
    expect(raw, contains('h_orphan_0001'));
  });
}
