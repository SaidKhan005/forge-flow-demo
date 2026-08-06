// Guard for the Wave 5 motion system (premium + performance audit
// B10 + B11 + B12).
//
// Two things have to stay true:
//
//  1. Staggered entrances are ticker-driven and honour reduce motion. They
//     used to be one `Future.delayed` per item: timers nothing owned, which
//     kept firing while the app was backgrounded, drifted under load, and
//     (on the quiz twin and El Podio) ignored `MediaQuery.disableAnimations`
//     outright. With reduce motion on, every item must be present AND
//     settled on the very first frame.
//
//  2. The overshoot curves stay retired. `easeOutBack` on a press and
//     `elasticOut` on a reveal read playful; this is a training tool for
//     staff on shift.
//
// Design notes, so this is not a vacuous guard:
//
//  * The settled assertions read the RENDERED animation values
//    (`FadeTransition.opacity.value`, `SlideTransition.position.value`),
//    not `barrioStaggerInterval`. A guard whose expected value is computed
//    by the code under test still passes after that code drifts.
//  * Every reduce-motion case has an animations-ON twin asserting the same
//    surface is NOT settled on frame zero. Without that pair, a reveal that
//    silently stopped animating at all would pass the settled check.
//  * Every source scan asserts it actually matched something, and the
//    banned-curve scan proves its own pattern by finding those curves in the
//    one file that is allowed to keep them.
//
// Proven to fail without the fix (checked by reverting each site):
//  * `LearningSurfaceCard` reduce motion — options sat at opacity 0 on the
//    first frame and the test then failed again at teardown on the pending
//    `Future.delayed` timers.
//  * `ElPodioScreen` reduce motion — same, and its entrance controller had
//    no reduce-motion branch at all.
//  * The `Future.delayed` scan — three matches.
//  * The banned-curve scan — six `easeOutBack` and one `elasticOut`.
//  * `HandbookLessonCard` reduce motion is honest about being the weaker
//    case: that one site DID already branch on `disableAnimations`, so only
//    the scans catch its regression. Its settled test guards the new shared
//    path from breaking what already worked.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/screens/el_podio_screen.dart';
import 'package:forge_and_flow/internal/barrio/widgets/barrio_destination_scaffold.dart';
import 'package:forge_and_flow/internal/barrio/widgets/handbook_lesson_card.dart';
import 'package:forge_and_flow/internal/barrio/widgets/learning_surface_card.dart';

/// Four options, written out here rather than generated, so the count the
/// assertions use is independent of anything the widgets do.
const int kOptionCount = 4;

const _quizUnit = HandbookUnit(
  id: 'motion_fixture_u1',
  type: HandbookUnitType.checkpoint,
  title: 'Which glass carries the house Rioja?',
  body: 'A guest orders the house Rioja by the glass. Pick the pour.',
  options: [
    HandbookOption(
        label: 'Option one', isCorrect: true, feedback: 'Correct.'),
    HandbookOption(
        label: 'Option two', isCorrect: false, feedback: 'Not this one.'),
    HandbookOption(
        label: 'Option three', isCorrect: false, feedback: 'Not this one.'),
    HandbookOption(
        label: 'Option four', isCorrect: false, feedback: 'Not this one.'),
  ],
);

const _surfaceOptions = <LearningOption>[
  LearningOption(label: 'Option one', isCorrect: true, feedback: 'Correct.'),
  LearningOption(
      label: 'Option two', isCorrect: false, feedback: 'Not this one.'),
  LearningOption(
      label: 'Option three', isCorrect: false, feedback: 'Not this one.'),
  LearningOption(
      label: 'Option four', isCorrect: false, feedback: 'Not this one.'),
];

/// The three files this slice converted from `Future.delayed` staggering.
const List<String> kConvertedAnimationPaths = <String>[
  'lib/internal/barrio/widgets/handbook_lesson_card.dart',
  'lib/internal/barrio/widgets/learning_surface_card.dart',
  'lib/internal/barrio/screens/el_podio_screen.dart',
];

/// The parked orbit hub is held byte-identical under the hide-only reversal
/// doctrine (see `barrio_home_screen.dart`), so it is the one file allowed
/// to still spell the retired curves. It doubles as the banned-curve scan's
/// proof that its own pattern matches real source.
const String kParkedHub = 'barrio_bubble_hub.dart';

const Map<String, String> kBannedCurves = <String, String>{
  'Curves.easeOutBack':
      'use BarrioMotion.curve; presses settle, they do not bounce',
  'Curves.elasticOut':
      'use BarrioMotion.curveEmphasis; nothing in the module springs',
};

List<File> _barrioSources() => Directory('lib/internal/barrio')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

/// Source lines with `//` comment bodies stripped, so prose that merely
/// mentions a retired construct is not mistaken for code using it.
List<String> _codeLines(File file) {
  return file.readAsLinesSync().map((line) {
    final marker = line.indexOf('//');
    return marker < 0 ? line : line.substring(0, marker);
  }).toList();
}

Widget _harness({required bool reduceMotion, required Widget child}) {
  return MaterialApp(
    builder: (context, inner) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: inner ?? const SizedBox.shrink(),
    ),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

/// The outermost [FadeTransition] inside stagger reveal [index].
FadeTransition _revealFade(WidgetTester tester, int index) {
  return tester.widget<FadeTransition>(
    find
        .descendant(
          of: find.byType(BarrioStaggerReveal).at(index),
          matching: find.byType(FadeTransition),
        )
        .first,
  );
}

/// The outermost [SlideTransition] inside stagger reveal [index].
SlideTransition _revealSlide(WidgetTester tester, int index) {
  return tester.widget<SlideTransition>(
    find
        .descendant(
          of: find.byType(BarrioStaggerReveal).at(index),
          matching: find.byType(SlideTransition),
        )
        .first,
  );
}

/// Every reveal on screen is fully faded in and back at its resting offset.
void _expectAllSettled(WidgetTester tester, {required int expectedCount}) {
  expect(
    find.byType(BarrioStaggerReveal),
    findsNWidgets(expectedCount),
    reason: 'every item must be built, not just the ones already revealed',
  );
  for (var i = 0; i < expectedCount; i++) {
    expect(_revealFade(tester, i).opacity.value, 1.0,
        reason: 'reveal $i must be fully opaque on the first frame');
    expect(_revealSlide(tester, i).position.value, Offset.zero,
        reason: 'reveal $i must be at its resting offset on the first frame');
  }
}

void main() {
  group('BarrioMotion scale (audit B10)', () {
    test('the scale still holds the values this guard was written against',
        () {
      // Hand-written, not read back from the tokens: a deliberate re-time
      // has to be acknowledged here rather than silently sliding past.
      expect(BarrioMotion.fast, const Duration(milliseconds: 150));
      expect(BarrioMotion.base, const Duration(milliseconds: 250));
      expect(BarrioMotion.slow, const Duration(milliseconds: 400));
      expect(BarrioMotion.hero, const Duration(milliseconds: 700));
      expect(BarrioMotion.curve, Curves.easeOutCubic);
      expect(BarrioMotion.curveEmphasis, Curves.easeOutQuart);
      expect(BarrioMotion.pressScale, 0.97);
      expect(BarrioMotion.stagger, const Duration(milliseconds: 300));
      expect(BarrioMotion.staggerStep, const Duration(milliseconds: 45));
    });

    test('a cascade never exceeds 45ms per step or 300ms end to end', () {
      // The bar from the slice brief, asserted in wall-clock milliseconds
      // against the interval the widgets actually receive.
      const totalMs = 300.0;
      for (final count in <int>[1, 2, 3, 4, 8, 20]) {
        final firstStart =
            barrioStaggerInterval(slot: 0, count: count).begin * totalMs;
        final lastEnd = barrioStaggerInterval(slot: count - 1, count: count)
                .end *
            totalMs;
        expect(firstStart, 0.0, reason: 'count $count starts immediately');
        expect(lastEnd, lessThanOrEqualTo(300.0 + 0.001),
            reason: 'count $count must settle inside BarrioMotion.stagger');

        if (count < 2) continue;
        final secondStart =
            barrioStaggerInterval(slot: 1, count: count).begin * totalMs;
        expect(secondStart, lessThanOrEqualTo(45.0 + 0.001),
            reason: 'count $count must not step more than 45ms per item');
      }
    });

    test('the retired overshoot curves are gone from the live module', () {
      final sources = _barrioSources();
      expect(sources.length, greaterThan(40),
          reason: 'expected the Barrio module, got ${sources.length} files');

      final offenders = <String>[];
      // Proof the patterns match real source: the parked hub keeps them.
      final parkedHits = <String, int>{for (final k in kBannedCurves.keys) k: 0};

      for (final file in sources) {
        final parked = file.path.endsWith(kParkedHub);
        final lines = _codeLines(file);
        for (var i = 0; i < lines.length; i++) {
          for (final entry in kBannedCurves.entries) {
            if (!lines[i].contains(entry.key)) continue;
            if (parked) {
              parkedHits[entry.key] = parkedHits[entry.key]! + 1;
              continue;
            }
            offenders.add('${file.path}:${i + 1}  ${entry.key}  ->  '
                '${entry.value}');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'Overshoot curves are back in the Barrio module:\n'
              '${offenders.join('\n')}');
      for (final entry in parkedHits.entries) {
        expect(entry.value, greaterThan(0),
            reason: '${entry.key} was not found in $kParkedHub either, so '
                'this scan is no longer matching anything. Either the '
                'parked hub changed or the pattern is wrong.');
      }
    });
  });

  group('Ticker-driven staggers (audit B11)', () {
    test('no Future.delayed remains in the converted animation paths', () {
      for (final path in kConvertedAnimationPaths) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: '$path moved; this guard is scanning nothing');

        final lines = _codeLines(file);
        // Anti-vacuity: the file has real content and the comment stripper
        // did not eat it.
        expect(lines.where((l) => l.trim().isNotEmpty).length,
            greaterThan(100),
            reason: '$path scanned as almost empty');

        final hits = <String>[];
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('Future.delayed(')) {
            hits.add('$path:${i + 1}  ${lines[i].trim()}');
          }
        }
        expect(hits, isEmpty,
            reason: 'Staggered entrances must run off an AnimationController, '
                'not an unowned timer:\n${hits.join('\n')}');
      }
    });

    test('the Future.delayed scanner can actually see a call', () {
      // Anti-vacuity for the scan above: prove the needle and the comment
      // stripper both behave, without depending on any production file.
      const sample = <String>[
        '    Future.delayed(Duration(milliseconds: 100 * i), noop);',
        '    // Future.delayed( in prose must not count.',
        '    doWork(); // Future.delayed( trailing prose must not count.',
      ];
      final stripped = sample.map((line) {
        final marker = line.indexOf('//');
        return marker < 0 ? line : line.substring(0, marker);
      }).toList();
      expect(stripped.where((l) => l.contains('Future.delayed(')).length, 1);
    });

    testWidgets(
        'HandbookLessonCard: reduce motion shows every option settled at once',
        (tester) async {
      await tester.pumpWidget(_harness(
        reduceMotion: true,
        child: const HandbookLessonCard(unit: _quizUnit),
      ));
      await tester.tap(find.text(_quizUnit.title));
      await tester.pump();

      _expectAllSettled(tester, expectedCount: kOptionCount);
      expect(find.text('Option four'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HandbookLessonCard: with motion on, options start hidden',
        (tester) async {
      await tester.pumpWidget(_harness(
        reduceMotion: false,
        child: const HandbookLessonCard(unit: _quizUnit),
      ));
      await tester.tap(find.text(_quizUnit.title));
      await tester.pump();

      expect(_revealFade(tester, 0).opacity.value, 0.0,
          reason: 'the settled assertion above would be vacuous if the '
              'cascade never animated in the first place');
      await tester.pumpAndSettle();
      _expectAllSettled(tester, expectedCount: kOptionCount);
    });

    testWidgets(
        'LearningSurfaceCard: reduce motion shows every option settled at once',
        (tester) async {
      await tester.pumpWidget(_harness(
        reduceMotion: true,
        child: const LearningSurfaceCard(
          title: 'Reading the table',
          body: 'A four-top has finished their mains. What do you do next?',
          badgeLabel: 'CHECK',
          badgeColor: BarrioColors.tealWarm,
          options: _surfaceOptions,
        ),
      ));
      await tester.tap(find.text('Reading the table'));
      await tester.pump();

      _expectAllSettled(tester, expectedCount: kOptionCount);
      expect(find.text('Option four'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('LearningSurfaceCard: with motion on, options start hidden',
        (tester) async {
      await tester.pumpWidget(_harness(
        reduceMotion: false,
        child: const LearningSurfaceCard(
          title: 'Reading the table',
          body: 'A four-top has finished their mains. What do you do next?',
          badgeLabel: 'CHECK',
          badgeColor: BarrioColors.tealWarm,
          options: _surfaceOptions,
        ),
      ));
      await tester.tap(find.text('Reading the table'));
      await tester.pump();

      expect(_revealFade(tester, 0).opacity.value, 0.0);
      await tester.pumpAndSettle();
      _expectAllSettled(tester, expectedCount: kOptionCount);
    });

    testWidgets('El Podio: reduce motion lands the ranked list settled',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: inner ?? const SizedBox.shrink(),
        ),
        home: const ElPodioScreen(),
      ));
      await tester.pump();

      final built = find.byType(BarrioStaggerReveal).evaluate().length;
      expect(built, greaterThan(0),
          reason: 'the ranked list must build rank tiles at this viewport');
      _expectAllSettled(tester, expectedCount: built);
      expect(tester.hasRunningAnimations, isFalse,
          reason: 'nothing may still be ticking under reduce motion');
      expect(tester.takeException(), isNull);
    });

    testWidgets('El Podio: with motion on, the ranked list starts hidden',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: ElPodioScreen()));
      await tester.pump();

      expect(find.byType(BarrioStaggerReveal), findsWidgets);
      expect(_revealFade(tester, 0).opacity.value, 0.0);

      await tester.pumpAndSettle();
      final built = find.byType(BarrioStaggerReveal).evaluate().length;
      _expectAllSettled(tester, expectedCount: built);
    });
  });
}
