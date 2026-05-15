// feat(11W.metric-pill) — MetricPill widget behavioral tests.
//
// Covers render rules per module doc:
//   * live   → value visible, no zero-phantom risk.
//   * empty  → "No data yet" visible, NO "0" or numeric zero present.
//   * stale  → value rendered + stale indicator badge present.
//   * demo   → value rendered + "Demo" chip visible.
//   * unavailable → em dash, no numeric value rendered.
//   * live + value == null → assert fires in kDebugMode.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/widgets/metric_pill.dart';

/// Wraps [child] in a minimal [MaterialApp] + [Scaffold].
Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Standard provenance used across most tests.
const _toastProv = MetricPillProvenance(
  label: 'Toast',
  tooltip: 'Connected via Toast POS.',
);

/// Provenance with tooltip used for empty/unavailable tests.
const _unknownProv = MetricPillProvenance(
  label: 'Unknown',
  tooltip: 'Connect a vendor to see this metric.',
);

void main() {
  // ── live state ────────────────────────────────────────────────────────────

  group('MetricPill — state: live', () {
    testWidgets('renders the formatted value', (tester) async {
      await tester.pumpWidget(_wrap(
        MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'CPLH',
          value: 12.5,
          formatter: (v) => v.toStringAsFixed(1),
        ),
      ));
      await tester.pump();

      expect(find.text('12.5'), findsOneWidget);
    });

    testWidgets('renders the provenance label', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'PPA',
          value: 45.0,
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_provenance_PPA')),
          findsOneWidget);
    });

    testWidgets('does not render "No data yet"', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'Sales',
          value: 3450.0,
        ),
      ));
      await tester.pump();

      expect(find.text('No data yet'), findsNothing);
    });

    testWidgets('does not render demo badge', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'Sales',
          value: 3450.0,
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_demo_badge')), findsNothing);
    });
  });

  // ── empty state ───────────────────────────────────────────────────────────

  group('MetricPill — state: empty', () {
    testWidgets('"No data yet" visible; zero is NOT visible', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.empty,
          provenance: _unknownProv,
          label: 'CPLH',
          // value intentionally absent — no number should appear
        ),
      ));
      await tester.pump();

      expect(find.text('No data yet'), findsOneWidget);

      // No bare "0" anywhere in the widget tree.
      expect(find.text('0'), findsNothing);
      expect(find.text('0.0'), findsNothing);
    });

    testWidgets('provenance tooltip rendered when present', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.empty,
          provenance: _unknownProv,
          label: 'PPA',
        ),
      ));
      await tester.pump();

      expect(find.text('Connect a vendor to see this metric.'),
          findsOneWidget);
    });

    testWidgets('no stale badge rendered', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.empty,
          provenance: _unknownProv,
          label: 'CPLH',
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_stale_badge_CPLH')),
          findsNothing);
    });
  });

  // ── stale state ───────────────────────────────────────────────────────────

  group('MetricPill — state: stale', () {
    testWidgets('value rendered AND stale badge present', (tester) async {
      await tester.pumpWidget(_wrap(
        MetricPill(
          state: MetricState.stale,
          provenance: _toastProv,
          label: 'CPLH',
          value: 12.5,
          formatter: (v) => v.toStringAsFixed(1),
        ),
      ));
      await tester.pump();

      expect(find.text('12.5'), findsOneWidget);
      expect(find.byKey(const Key('metric_pill_stale_badge_CPLH')),
          findsOneWidget);
    });

    testWidgets('stale badge has "Stale" text', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.stale,
          provenance: _toastProv,
          label: 'PPA',
          value: 42.0,
        ),
      ));
      await tester.pump();

      expect(find.text('Stale'), findsOneWidget);
    });
  });

  // ── demo state ────────────────────────────────────────────────────────────

  group('MetricPill — state: demo', () {
    testWidgets('value rendered + "Demo" chip badge visible', (tester) async {
      await tester.pumpWidget(_wrap(
        MetricPill(
          state: MetricState.demo,
          provenance: const MetricPillProvenance(label: 'Demo seed'),
          label: 'SPLH',
          value: 250.0,
          formatter: (v) => '\$${v.toStringAsFixed(0)}',
        ),
      ));
      await tester.pump();

      expect(find.text('\$250'), findsOneWidget);
      expect(find.byKey(const Key('metric_pill_demo_badge')), findsOneWidget);
      expect(find.text('Demo'), findsOneWidget);
    });

    testWidgets('no stale badge in demo state', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.demo,
          provenance: MetricPillProvenance(label: 'Demo seed'),
          label: 'COVERS',
          value: 80,
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_stale_badge_COVERS')),
          findsNothing);
    });
  });

  // ── unavailable state ─────────────────────────────────────────────────────

  group('MetricPill — state: unavailable', () {
    testWidgets('renders em dash, not a number', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.unavailable,
          provenance: MetricPillProvenance(
            label: 'Unknown',
            tooltip: 'Connect a labor vendor.',
          ),
          label: 'CPLH',
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_unavailable_CPLH')),
          findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      // No numeric zero
      expect(find.text('0'), findsNothing);
    });

    testWidgets('tooltip rendered', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.unavailable,
          provenance: MetricPillProvenance(
            label: 'Unknown',
            tooltip: 'Connect a labor vendor.',
          ),
          label: 'CPLH',
        ),
      ));
      await tester.pump();

      expect(find.text('Connect a labor vendor.'), findsOneWidget);
    });
  });

  // ── assertion guard: live + value == null ─────────────────────────────────

  group('MetricPill — assertion guard', () {
    testWidgets(
        'assert fires in kDebugMode when state==live and value==null',
        (tester) async {
      // This test only validates the assertion in debug mode.
      // In profile/release mode the assert is a no-op; skip there.
      if (!kDebugMode) return;

      expect(
        () => MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'CPLH',
          // value deliberately absent (null)
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  // ── compact layout ────────────────────────────────────────────────────────

  group('MetricPill — compact layout', () {
    testWidgets('compact=true renders the label key', (tester) async {
      await tester.pumpWidget(_wrap(
        const MetricPill(
          state: MetricState.live,
          provenance: _toastProv,
          label: 'PPA',
          value: 45.0,
          compact: true,
        ),
      ));
      await tester.pump();

      expect(find.byKey(const Key('metric_pill_label_PPA')), findsOneWidget);
    });
  });

  // ── FU-mobile-shift-card-overflow-17px regression guard ───────────────────
  //
  // Reproduces the SHIFT OUTPUTS row-2 layout (IntrinsicHeight + Row +
  // Expanded children) at a narrow per-card width. Before the fix, the
  // long unavailable / empty-state tooltip wrapped from 1 line (during
  // the IntrinsicHeight intrinsic-height pass with unbounded width) to
  // 2 lines (during actual layout at the constrained width), and the
  // Column's natural height exceeded the height that IntrinsicHeight
  // had locked in — producing a "RenderFlex overflowed by ~17 PIXELS"
  // exception. The fix wraps the tooltip Text in a Flexible with
  // maxLines:2 + ellipsis so the Column can shrink that child instead
  // of overflowing.
  //
  // Note: in widget tests the default font is a fixed-width fallback
  // (not IBM Plex Mono), so the tooltip strings here are deliberately
  // longer than the production copy to guarantee the wrap-trigger fires
  // at the chosen test width.
  group('MetricPill — overflow guard (FU-mobile-shift-card-overflow-17px)',
      () {
    /// Tooltip long enough to wrap to 2+ lines at the per-card width
    /// used below. Mirrors the production copy
    /// "Connect a labor vendor to see blended wage." but extended so
    /// the wrap happens reliably with the widget-test fallback font.
    const longUnavailableTooltip =
        'Connect a labor vendor to see blended wage. '
        'Once a labor vendor is connected, this card will show the '
        'blended hourly wage across FOH and BOH for the active shift.';

    const longEmptyTooltip =
        'Connect a labor vendor to see covers per labor hour. '
        'Once a labor vendor is connected, this card will show CPLH '
        'across FOH and BOH for the active shift.';

    testWidgets(
      'no RenderFlex overflow when long unavailable tooltip lives '
      'inside IntrinsicHeight + Row + Expanded at narrow width',
      (tester) async {
        // Force a narrow logical width close to a Pixel 9 half-screen
        // card so the long tooltip wraps during real layout.
        tester.view.physicalSize = const Size(372, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: MetricPill(
                        state: MetricState.live,
                        provenance:
                            MetricPillProvenance(label: 'Toast'),
                        label: 'COVERS',
                        value: 80,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: MetricPill(
                        state: MetricState.unavailable,
                        provenance: MetricPillProvenance(
                          label: 'Unknown',
                          tooltip: longUnavailableTooltip,
                        ),
                        label: 'BLENDED WAGE',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull,
            reason: 'IntrinsicHeight + Expanded + long unavailable tooltip '
                'must not overflow at narrow widths.');
        // Sanity: the unavailable em dash is still rendered.
        expect(find.byKey(const Key('metric_pill_unavailable_BLENDED WAGE')),
            findsOneWidget);
      },
    );

    testWidgets(
      'no RenderFlex overflow when long empty-state tooltip lives '
      'inside IntrinsicHeight + Row + Expanded at narrow width',
      (tester) async {
        tester.view.physicalSize = const Size(372, 1600);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: MetricPill(
                        state: MetricState.live,
                        provenance:
                            MetricPillProvenance(label: 'Toast'),
                        label: 'COVERS',
                        value: 80,
                      ),
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: MetricPill(
                        state: MetricState.empty,
                        provenance: MetricPillProvenance(
                          label: 'Unknown',
                          tooltip: longEmptyTooltip,
                        ),
                        label: 'CPLH',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull,
            reason: 'IntrinsicHeight + Expanded + long empty-state tooltip '
                'must not overflow at narrow widths.');
        expect(find.text('No data yet'), findsOneWidget);
      },
    );
  });
}
