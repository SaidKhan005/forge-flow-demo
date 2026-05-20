// Per-Daypart Targets V1 — Operating Inputs strip alignment.
//
// Operator finding (live walkthrough): the Benchmark screen's
// Operating Inputs strip is a single bordered card split into two
// halves. The left title "Operating Wage Mix" is one line; the right
// title "Theoretical Labor %: The Floor" is longer and wraps to two
// lines at phone width, which pushed the right half's hairline rule
// and its data rows DOWN relative to the left half so the two halves
// read ragged.
//
// The fix reserves a fixed two-line header band in each `_StripHalf`
// so the rule + every data row sit at the same vertical position in
// both halves regardless of title length. These tests prove that at
// phone width (1080) and narrow width (360):
//   - the two halves' header bands share an identical top edge,
//   - the first AND last data rows are pixel-aligned across halves
//     (so the whole row stack — and the rule between rows — lines
//     up), and
//   - the strip's own content stays within its horizontal bounds.
//
// Scope note: a separate, PRE-EXISTING horizontal RenderFlex overflow
// (~37px to the right, from a `mainAxisSize: min` Row elsewhere on
// the BaselineTracker screen — NOT inside the strip) is present on
// unmodified master at 360px. It is unrelated to this strip and out
// of scope for this layout-only slice. The pump helper therefore
// captures framework errors and tolerates ONLY a horizontal overflow
// (the known pre-existing one); a vertical ("bottom") overflow — the
// shape a header-band regression would produce — is still treated as
// a hard failure.
//
// `_OperatingStrip` / `_StripHalf` are private to baseline_tracker.dart
// so the strip is exercised through the public `BaselineTracker`
// screen in bridge-only mode (the same honest fallback path the other
// baseline widget tests use).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/screens/baseline_tracker.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';

void main() {
  setUp(() {
    BenchmarkTrackerReadService.enableBridgeOnly();
  });

  tearDown(() {
    BenchmarkTrackerReadService.disableBridgeOnly();
  });

  Future<Finder> pumpStripAtWidth(WidgetTester tester, double width) async {
    // 2026-05-20 mobile-UX dial-in: the Benchmark screen grew enough
    // content above the Operating Inputs strip (sticky CPLH RANGE &
    // TARGET header, sticky DAYPART TARGET BREAKDOWNS header + the
    // DaypartTable, the per-period rollup line) that the strip sits
    // far below a 1600-tall surface and isn't built by the lazy
    // CustomScrollView even with `cacheExtent: 9999`. Bump the surface
    // tall enough that the entire screen is in the cache-built region.
    await tester.binding.setSurfaceSize(Size(width, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Collect framework errors during pump instead of letting the test
    // binding auto-fail on the known pre-existing screen overflow.
    final captured = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = captured.add;

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: BaselineTracker(key: ValueKey('strip-align'))),
      ),
    );
    // Let the CustomScrollView slivers (incl. the Operating strip's
    // IntrinsicHeight + LayoutBuilder neighbours) settle.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    FlutterError.onError = previous;

    // Tolerate ONLY the known pre-existing horizontal overflow. A
    // vertical ("overflowed ... on the bottom") error is exactly what
    // a broken/undersized header band would produce, so it must still
    // fail loudly.
    for (final d in captured) {
      final msg = d.exception.toString();
      final isHorizontalOverflow = msg.contains('A RenderFlex overflowed') &&
          (msg.contains('on the right') || msg.contains('on the left'));
      expect(isHorizontalOverflow, isTrue,
          reason: 'unexpected framework error at ${width.toInt()}px '
              '(only the pre-existing horizontal screen overflow is '
              'tolerated): $msg');
    }

    // Scroll the strip into view so its anchor text is in the rendered
    // tree (lazy slivers below the cache region remain unbuilt without
    // a scroll; the cache-extent bump above usually solves this but the
    // explicit scrollUntilVisible is the most defensive shape).
    final leftTitle = find.text('Operating Wage Mix');
    if (leftTitle.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        leftTitle,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
    }

    // Anchor on the two unique strip titles, then resolve their shared
    // IntrinsicHeight so the row finders below cannot accidentally
    // match a like-named label elsewhere on the screen.
    final rightTitle = find.text('Theoretical Labor %: The Floor');
    expect(leftTitle, findsOneWidget);
    expect(rightTitle, findsOneWidget);

    final strip =
        find.ancestor(of: leftTitle, matching: find.byType(IntrinsicHeight));
    expect(strip, findsOneWidget);
    expect(
      find.ancestor(of: rightTitle, matching: find.byType(IntrinsicHeight)),
      findsOneWidget,
    );
    return strip;
  }

  for (final width in <double>[1080, 360]) {
    final w = width.toInt();

    testWidgets('Operating Inputs strip header bands align at ${w}px',
        (tester) async {
      final strip = await pumpStripAtWidth(tester, width);

      // Both titles sit in a fixed-height band: identical top edge
      // across halves regardless of the right title wrapping to two
      // lines. (This is the root cause the operator reported.)
      final leftTitleRect = tester.getRect(find.text('Operating Wage Mix'));
      final rightTitleRect =
          tester.getRect(find.text('Theoretical Labor %: The Floor'));
      expect(leftTitleRect.top,
          moreOrLessEquals(rightTitleRect.top, epsilon: 0.5),
          reason: 'header band top must match across halves at ${w}px');

      // The strip stays within its own horizontal bounds — the fix is
      // vertical-only and must not push any strip content past the
      // strip's right edge (no strip-introduced horizontal overflow).
      final stripRight = tester.getRect(strip).right;
      for (final label in const [
        'FOH Wage',
        'BOH Wage',
        'Blended Wage',
        'FOH %',
        'BOH %',
        'Total %',
      ]) {
        final f = find.descendant(of: strip, matching: find.text(label));
        expect(f, findsOneWidget, reason: '"$label" must render in the strip');
        expect(tester.getRect(f).right, lessThanOrEqualTo(stripRight + 0.5),
            reason: '"$label" must stay within the strip at ${w}px');
      }
    });

    testWidgets(
        'Operating Inputs strip rows pixel-align across halves at ${w}px',
        (tester) async {
      final strip = await pumpStripAtWidth(tester, width);

      double leftTop(String s) => tester
          .getTopLeft(find.descendant(of: strip, matching: find.text(s)))
          .dy;

      // First rows align (the user-visible symptom) ...
      expect(leftTop('FOH Wage'),
          moreOrLessEquals(leftTop('FOH %'), epsilon: 0.5),
          reason: 'first data rows must align at ${w}px');
      // ... and so do the last rows, proving the entire row stack —
      // and therefore the hairline rule between them — lines up.
      expect(leftTop('Blended Wage'),
          moreOrLessEquals(leftTop('Total %'), epsilon: 0.5),
          reason: 'last data rows must align at ${w}px');
    });
  }
}
