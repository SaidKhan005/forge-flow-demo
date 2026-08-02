// T10 picture-holder slideshow (2026-08-02): mechanism plus the wired
// corpus.
//
// A training card carrying a run of consecutive photographs shows them
// one at a time: two small visible chevron chips on the picture's edges,
// a dot strip, and a 'K of N' counter. The full-screen viewer pages
// between the same slides and swaps the credit caption with the picture.
//
// Covers:
// - Corpus guards: the deliberate shipped slide-group count, the wired
//   second photographs, their credit captions, and the rule that no
//   group ever mixes a captioned diagram in with photographs.
// - Degrade rule: a one-photograph card renders today's tree exactly
//   (no chips, no dots, no counter, bare caption semantics), and a
//   diagram never joins a group.
// - A slide group renders the chrome, the next chip advances the slide
//   and swaps the credit caption, and the chips are absent at the ends
//   (no wrap-around).
// - Accessibility strings: '<caption>. Photo K of N' on the holder,
//   'Next photo' / 'Previous photo' on the chips.
// - The in-card slide decodes at the holder's pixel width (cacheWidth).
// - Reduced motion swaps the picture with no running animation.
// - Viewer: opening from slide k lands on slide k, paging swaps the
//   caption, and a single-slide open renders today's viewer.
//
// The gesture-conflict guard (the reader's page turns must survive the
// new chips) lives in barrio_learning_carousel_gestures_test.dart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_training_image_viewer.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';

/// Body with no bullet list: the bullet marker is also a small circle,
/// so keeping it out of the fixture makes the circle count below a clean
/// dot-and-chip census.
const _kBody = 'A single fixture paragraph for the slide holder card.';

const _kLeadPath =
    'assets/internal/barrio/training/fixture_photos/slides_unit.webp';
const _kSecondPath =
    'assets/internal/barrio/training/fixture_photos/slides_unit_2.webp';
const _kThirdPath =
    'assets/internal/barrio/training/fixture_photos/slides_unit_3.webp';

const _kFirstCaption = 'Photo: First Creator, CC BY 2.0';
const _kSecondCaption = 'Photo: Second Creator, CC BY-SA 4.0';
const _kThirdCaption = 'Photo: Third Creator, Public domain';

/// One photograph: the shape of ~140 real build-32 cards. Must render
/// literally today's tree.
const _kSinglePhotoUnit = HandbookUnit(
  id: 'fixture_single_photo_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Single Photo',
  body: _kBody,
  images: [
    HandbookUnitImage(
      assetPath: _kLeadPath,
      caption: _kFirstCaption,
      afterParagraph: -1,
    ),
  ],
);

/// A three-slide group: a lead photograph plus the `_2` and `_3`
/// alternates the content pipeline authors beside it.
const _kSlideGroupUnit = HandbookUnit(
  id: 'fixture_slide_group_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Slide Group',
  body: _kBody,
  images: [
    HandbookUnitImage(
      assetPath: _kLeadPath,
      caption: _kFirstCaption,
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: _kSecondPath,
      caption: _kSecondCaption,
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: _kThirdPath,
      caption: _kThirdCaption,
      afterParagraph: -1,
    ),
  ],
);

/// Two uncaptioned source-document figures with unrelated file stems:
/// the shape of the 28 shipped cards that already stacked scans (the
/// eight `bar_manual/03..10.webp` pages, for one). Operator-approved on
/// 2026-08-02 to slide rather than stack.
const _kTwoSourceFiguresUnit = HandbookUnit(
  id: 'fixture_two_source_figures_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Two Source Figures',
  body: _kBody,
  images: [
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/03.webp',
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture/04.webp',
      afterParagraph: -1,
    ),
  ],
);

/// A photograph followed by a house-style diagram pictogram. A diagram
/// is a different teaching visual, so it never joins a slide group: this
/// card must keep stacking two separate pictures.
const _kPhotoThenDiagramUnit = HandbookUnit(
  id: 'fixture_photo_then_diagram_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Photo Then Diagram',
  body: _kBody,
  images: [
    HandbookUnitImage(
      assetPath: _kLeadPath,
      caption: _kFirstCaption,
      afterParagraph: -1,
    ),
    HandbookUnitImage(
      assetPath: 'assets/internal/barrio/training/fixture_diagrams/pict.webp',
      caption: 'Diagram: the fixture pictogram',
      afterParagraph: -1,
    ),
  ],
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

/// Circle-decorated boxes inside the card. Dots and chevron chips are
/// the only circles the slide holder draws, and the fixture body has no
/// bullet list, so this is an exact dot-and-chip census.
int _circleCount(WidgetTester tester) {
  return tester
      .widgetList(find.descendant(
        of: find.byType(HandbookLessonCard),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle),
      ))
      .length;
}

Finder _cardIcon(IconData icon) => find.descendant(
      of: find.byType(HandbookLessonCard),
      matching: find.byIcon(icon),
    );

Finder _cardImages() => find.descendant(
      of: find.byType(HandbookLessonCard),
      matching: find.byType(Image),
    );

void main() {
  group('live training corpus', () {
    // One walk of the shipped corpus, reused by every guard below.
    final groups = <List<HandbookUnitImage>>[];
    var imagedUnits = 0;
    var unitsWithSlideGroup = 0;
    var unitsWithNoSlideGroup = 0;
    var wiredSecondPhotos = 0;
    var wiredSecondPhotosInAGroup = 0;

    setUpAll(() {
      for (final doc in kBarrioTrainingDocs.values) {
        for (final chapter in doc.chapters) {
          for (final unit in chapter.units) {
            if (unit.images.isEmpty) continue;
            imagedUnits++;
            final unitGroups = barrioPhotoSlideGroups(unit.images)
                .where((group) => group.length > 1)
                .toList();
            if (unitGroups.isEmpty) {
              unitsWithNoSlideGroup++;
            } else {
              unitsWithSlideGroup++;
              groups.addAll(unitGroups);
            }
            for (final image in unit.images) {
              if (!image.assetPath.endsWith('_2.webp')) continue;
              wiredSecondPhotos++;
              final inGroup = unitGroups.any(
                (group) => group.any((s) => s.assetPath == image.assetPath),
              );
              if (inGroup) wiredSecondPhotosInAGroup++;
            }
          }
        }
      }
    });

    // Deliberate numbers, recomputed from the wired content on
    // 2026-08-02 (same discipline as the diagram guards). Moving any of
    // them means content changed: update them on purpose or find out
    // why a card silently gained or lost a slideshow.
    //
    // Where 88 comes from. The broad positional rule first produced 91
    // groups: 28 shipped cards already stacked two or more uncaptioned
    // source-document figures (the eight `bar_manual/03..10.webp`
    // uniform-guideline scans, for one), plus 65 wired second
    // photographs, minus the 2 of those 65 that landed on cards already
    // stacking figures. 28 + 65 - 2 = 91.
    //
    // The classifier pass then captioned 7 drawn source figures on 5
    // cards as diagrams, because each was sharing a holder with real
    // photographs, and a diagram ends a run:
    //
    //   - 3 cards lost their group outright, 2 slides each
    //     (`company_handbook_c5_u0`, `company_handbook_c23_u5`,
    //     `training_food_safety_c12_u1`): 91 - 3 = 88 groups over 88
    //     cards, and those 3 cards move to the single-picture column,
    //     which is the +3 in 655 below.
    //   - 2 cards kept a group but shed drawn figures from it:
    //     `company_handbook_c16_u30` (3 slides to 2) and
    //     `training_food_safety_c17_u1` (5 slides to 2).
    //
    // So the slide total drops by 2 + 2 + 2 + 1 + 3 = 10, to 200.
    //
    // Two of these numbers also carry a correction. The wiring slice
    // shipped 744 imaged cards and 653 single-picture cards, but the
    // corpus held 743 and 652, so both guards were failing on master
    // before this pass. 743 is the true imaged count; 652 + the 3 cards
    // above = 655.
    test('forms exactly 88 slide groups across 88 cards', () {
      expect(imagedUnits, 743);
      expect(groups, hasLength(88));
      expect(unitsWithSlideGroup, 88,
          reason: 'no card carries two separate slide holders today');
      expect(
        groups.fold<int>(0, (sum, group) => sum + group.length),
        200,
        reason: '200 photographs now live inside a holder that slides',
      );
      expect(
        groups.map((group) => group.length).reduce((a, b) => a > b ? a : b),
        8,
        reason: 'the deepest group is the 8-photo uniform-guidelines card',
      );
    });

    test('655 imaged cards keep the single-picture degrade path', () {
      // The degrade rule at corpus scale: the overwhelming majority of
      // imaged cards still render exactly today's tree, one picture per
      // holder, no chips, no dots, no counter.
      expect(unitsWithNoSlideGroup, 655);
      expect(unitsWithSlideGroup + unitsWithNoSlideGroup, imagedUnits);
    });

    test('no slide group mixes a diagram in with photographs', () {
      // The rule the classifier pass exists to hold. A drawn source
      // figure (values poster, WHMIS chart, step illustration) is a
      // different teaching visual from a photograph, so it must never
      // share a swipe holder with one. Because grouping is positional,
      // this is equivalent to: no group contains a diagram at all.
      final offenders = [
        for (final group in groups)
          if (group.any(HandbookUnitPhotos.isDiagram))
            group.map((s) => s.assetPath).join(' + '),
      ];
      expect(offenders, isEmpty,
          reason: 'a drawn figure must stack on its own, not slide with '
              'photographs');
    });

    test('all 65 wired second photographs land inside a slide group', () {
      expect(wiredSecondPhotos, 65);
      expect(wiredSecondPhotosInAGroup, 65,
          reason: 'a second photograph that does not slide is dead weight');
    });

    test('every wired second photograph carries a credit, no em dash', () {
      var checked = 0;
      for (final group in groups) {
        for (final slide in group) {
          // UX no-em-dash law applies to every slide caption, wired or
          // pre-existing.
          expect(slide.caption ?? '', isNot(contains('—')),
              reason: slide.assetPath);
          if (!slide.assetPath.endsWith('_2.webp')) continue;
          checked++;
          expect(slide.caption, isNotNull, reason: slide.assetPath);
          expect(slide.caption!, startsWith('Photo: '),
              reason: '${slide.assetPath} must credit its source');
        }
      }
      expect(checked, 65);
    });
  });

  group('degrade rule', () {
    testWidgets('a one-photograph card renders no chips, no dots and no '
        'counter', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSinglePhotoUnit)),
      );
      await tester.pumpAndSettle();

      expect(_cardImages(), findsOneWidget);
      expect(_circleCount(tester), 0,
          reason: 'a lone photograph must draw no dots and no chips');
      expect(_cardIcon(Icons.chevron_right_rounded), findsNothing);
      expect(_cardIcon(Icons.chevron_left_rounded), findsNothing);
      expect(find.text('1 of 1'), findsNothing);
      expect(find.textContaining(' of '), findsNothing,
          reason: 'a lone photograph must not claim a slide position');

      // Credit caption still renders exactly as it does today.
      expect(find.text(_kFirstCaption), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a one-photograph holder keeps the bare caption for screen '
        'readers', (tester) async {
      final handle = tester.ensureSemantics();
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSinglePhotoUnit)),
      );
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel(_kFirstCaption), findsOneWidget,
          reason: 'no position tail on a single picture');
      expect(find.bySemanticsLabel('Next photo'), findsNothing);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('a photograph followed by a diagram keeps stacking',
        (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kPhotoThenDiagramUnit)),
      );
      await tester.pumpAndSettle();

      // A pictogram is not another view of the photograph, so the run
      // ends at the diagram and both pictures render at once.
      expect(_cardImages(), findsNWidgets(2));
      expect(_circleCount(tester), 0,
          reason: 'neither picture is part of a slide group');
      expect(_cardIcon(Icons.chevron_right_rounded), findsNothing);
      expect(find.textContaining(' of '), findsNothing);
      expect(find.text(_kFirstCaption), findsOneWidget);
      expect(find.text('Diagram: the fixture pictogram'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('consecutive source figures', () {
    testWidgets('two uncaptioned figures share one holder that slides',
        (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kTwoSourceFiguresUnit)),
      );
      await tester.pumpAndSettle();

      // Broadened grouping (operator-approved 2026-08-02): 03.webp and
      // 04.webp are consecutive photographs, so they slide instead of
      // stacking down the card.
      expect(_cardImages(), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget);
      // Two dots plus the next chip; no previous chip on slide 1.
      expect(_circleCount(tester), 3);
      expect(_cardIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(_cardIcon(Icons.chevron_left_rounded), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an uncaptioned figure invents no caption', (tester) async {
      final handle = tester.ensureSemantics();
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kTwoSourceFiguresUnit)),
      );
      await tester.pumpAndSettle();

      // Verbatim law: no source caption means the honest card-title
      // fallback, never an invented description.
      expect(
        find.bySemanticsLabel(
          'Photo: Fixture Two Source Figures. Photo 1 of 2',
        ),
        findsOneWidget,
      );
      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('slide group', () {
    testWidgets('renders one holder with a dot strip, a counter and only '
        'the next chip', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      // One picture on screen, not three stacked.
      expect(_cardImages(), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);
      // Three dots plus the next chip; no previous chip on slide 1.
      expect(_circleCount(tester), 4);
      expect(_cardIcon(Icons.chevron_right_rounded), findsOneWidget);
      expect(_cardIcon(Icons.chevron_left_rounded), findsNothing,
          reason: 'no wrap-around: the back chip is absent at the start');

      expect(find.text(_kFirstCaption), findsOneWidget);
      expect(find.text(_kSecondCaption), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the next chip advances the slide and swaps the credit '
        'caption', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();

      expect(find.text('2 of 3'), findsOneWidget);
      expect(find.text(_kSecondCaption), findsOneWidget,
          reason: 'each photograph carries its own credit');
      expect(find.text(_kFirstCaption), findsNothing);
      // Both chips are live in the middle of the group.
      expect(_circleCount(tester), 5);
      expect(_cardIcon(Icons.chevron_left_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the next chip disappears on the last slide and the back '
        'chip returns to the previous one', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();

      expect(find.text('3 of 3'), findsOneWidget);
      expect(find.text(_kThirdCaption), findsOneWidget);
      expect(_cardIcon(Icons.chevron_right_rounded), findsNothing,
          reason: 'no wrap-around: the next chip is absent at the end');
      expect(_circleCount(tester), 4);

      await tester.tap(_cardIcon(Icons.chevron_left_rounded));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);
      expect(find.text(_kSecondCaption), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the holder announces its position in plain English and the '
        'chips are labelled', (tester) async {
      final handle = tester.ensureSemantics();
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('$_kFirstCaption. Photo 1 of 3'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Next photo'), findsOneWidget);
      expect(find.bySemanticsLabel('Previous photo'), findsNothing);

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('$_kSecondCaption. Photo 2 of 3'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Previous photo'), findsOneWidget);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('the in-card slide decodes at the holder width, not the '
        'source resolution', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      // Image.asset encodes cacheWidth by wrapping the provider in a
      // ResizeImage, so a non-null ResizeImage.width IS the cacheWidth.
      final provider = tester.widget<Image>(_cardImages()).image;
      expect(provider, isA<ResizeImage>());
      expect((provider as ResizeImage).width, isNotNull);
      expect(provider.width, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('reduced motion swaps the picture in one pump, with no '
        'crossfade', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const HandbookLessonCard(unit: _kSlideGroupUnit),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pump();

      // One pump, one picture: the outgoing slide is already gone, so
      // nothing is fading. (The card's own AnimatedSize is pre-existing
      // chrome and is not what this rule is about.)
      expect(_cardImages(), findsOneWidget,
          reason: 'reduce motion means an instant swap, never a crossfade');
      expect(find.text('2 of 3'), findsOneWidget);
      expect(find.text(_kSecondCaption), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with motion on, the swap crossfades and then settles',
        (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pump();

      // The contrast case for the reduced-motion rule above: both
      // pictures are on screen mid-crossfade.
      expect(_cardImages(), findsNWidgets(2));
      await tester.pumpAndSettle();
      expect(_cardImages(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('viewer', () {
    Finder inViewer(Finder matching) => find.descendant(
          of: find.byType(BarrioTrainingImageViewer),
          matching: matching,
        );

    testWidgets('tapping the picture opens the viewer on the slide that was '
        'on screen', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kSlideGroupUnit)),
      );
      await tester.pumpAndSettle();

      await tester.tap(_cardIcon(Icons.chevron_right_rounded));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);

      await tester.tap(_cardImages(), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(BarrioTrainingImageViewer), findsOneWidget);
      expect(inViewer(find.text(_kSecondCaption)), findsOneWidget,
          reason: 'opening from slide 2 must land on slide 2');
      expect(inViewer(find.text('2 of 3')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('opening at an explicit index lands there and paging swaps '
        'the caption', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        const MaterialApp(
          home: BarrioTrainingImageViewer(
            slides: [
              BarrioTrainingImageSlide(
                assetPath: _kLeadPath,
                caption: _kFirstCaption,
              ),
              BarrioTrainingImageSlide(
                assetPath: _kSecondPath,
                caption: _kSecondCaption,
              ),
              BarrioTrainingImageSlide(
                assetPath: _kThirdPath,
                caption: _kThirdCaption,
              ),
            ],
            initialIndex: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_kSecondCaption), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1200);
      await tester.pumpAndSettle();

      expect(find.text(_kThirdCaption), findsOneWidget,
          reason: 'paging must swap the credit caption with the picture');
      expect(find.text(_kSecondCaption), findsNothing);
      expect(find.text('3 of 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a single-slide open renders today\'s viewer: caption pill, '
        'no counter', (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        const MaterialApp(
          home: BarrioTrainingImageViewer(
            slides: [
              BarrioTrainingImageSlide(
                assetPath: _kLeadPath,
                caption: _kFirstCaption,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(_kFirstCaption), findsOneWidget);
      expect(find.textContaining(' of '), findsNothing,
          reason: 'a lone picture must not claim a slide position');
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
