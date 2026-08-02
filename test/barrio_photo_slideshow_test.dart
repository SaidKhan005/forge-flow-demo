// T10 picture-holder slideshow (2026-08-02), mechanism only.
//
// A training card whose picture holder carries a lead photograph plus
// its numbered alternate views shows them one at a time: two small
// visible chevron chips on the picture's edges, a dot strip, and a
// 'K of N' counter. The full-screen viewer pages between the same
// slides and swaps the credit caption with the picture.
//
// Covers:
// - Degrade rule: a one-photograph card renders today's tree exactly
//   (no chips, no dots, no counter, bare caption semantics).
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

/// A three-slide group: the lead photograph plus `_2` and `_3` alternate
/// views of the same subject, the naming the content pipeline emits.
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

/// Two photographs that are NOT alternate views (different stems, the
/// shape of the 28 real cards holding stacked source-document figures).
/// These must keep stacking, untouched.
const _kTwoUnrelatedPhotosUnit = HandbookUnit(
  id: 'fixture_two_unrelated_unit',
  type: HandbookUnitType.explainer,
  badgeHint: 'READ',
  title: 'Fixture Two Unrelated',
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
  test('the live training corpus forms ZERO slide groups today', () {
    var slideGroups = 0;
    var unitsWithTwoOrMorePhotos = 0;
    for (final doc in kBarrioTrainingDocs.values) {
      for (final chapter in doc.chapters) {
        for (final unit in chapter.units) {
          if (unit.images.length < 2) continue;
          if (unit.photos.length >= 2) unitsWithTwoOrMorePhotos++;
          slideGroups += barrioPhotoSlideGroups(unit.images)
              .where((group) => group.length > 1)
              .length;
        }
      }
    }

    // The discovery this slice is built around: 28 shipped cards
    // (2026-08-02) already stack two or more uncaptioned photographs,
    // such as the eight `bar_manual/03..10.webp` source-document scans.
    // A bare "two or more photographs" rule would have turned every one
    // of them into a slideshow the day it landed.
    expect(unitsWithTwoOrMorePhotos, greaterThan(0));

    expect(slideGroups, 0,
        reason: 'shipped content must render exactly as it does today. '
            'Wiring the approved second photographs is what moves this '
            'number, and that is the operator sign-off gate.');
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

    testWidgets('two photographs that are NOT alternate views keep stacking',
        (tester) async {
      await _setMobileSurface(tester);
      await tester.pumpWidget(
        _host(const HandbookLessonCard(unit: _kTwoUnrelatedPhotosUnit)),
      );
      await tester.pumpAndSettle();

      // Both render at once, as they do today: 03.webp is not the lead
      // of 04.webp, so no slide group forms.
      expect(_cardImages(), findsNWidgets(2));
      expect(_circleCount(tester), 0);
      expect(find.textContaining(' of '), findsNothing);
      expect(tester.takeException(), isNull);
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
