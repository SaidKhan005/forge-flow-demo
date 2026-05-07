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
}
