// Phase 10a.UX.0 — SyncStateBadge widget tests.
//
// Pinned behavior:
//   * each non-idle connection state renders the right pill
//     (label + dot color), and the live state renders the green
//     "Live" pill while the back-off / connecting states render the
//     amber pill;
//   * idle (or no scope) renders an empty SizedBox so the badge
//     stays invisible before/after the subscription's lifetime;
//   * the visible pill width is stable across non-idle states so
//     the surrounding app-bar actions don't shift (no layout jitter).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';
import 'package:forge_and_flow/services/realtime/realtime_subscription.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/sync_state_badge.dart';

Widget _harness({
  Stream<RealtimeConnectionState>? stream,
  RealtimeConnectionState initialState = RealtimeConnectionState.idle,
}) {
  return MaterialApp(
    home: Scaffold(
      body: RealtimeConnectionScope(
        connectionStateStream: stream,
        initialState: initialState,
        child: const Center(child: SyncStateBadge()),
      ),
    ),
  );
}

void main() {
  group('SyncStateBadge', () {
    testWidgets('renders nothing when no scope is mounted', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: SyncStateBadge())),
        ),
      );

      expect(find.text('Live'), findsNothing);
      expect(find.text('Connecting…'), findsNothing);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('renders nothing when stream is null in scope', (tester) async {
      await tester.pumpWidget(_harness(stream: null));

      expect(find.text('Live'), findsNothing);
      expect(find.text('Connecting…'), findsNothing);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('renders nothing for the idle state', (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(_harness(stream: controller.stream));
      controller.add(RealtimeConnectionState.idle);
      await tester.pumpAndSettle();

      expect(find.text('Live'), findsNothing);
      expect(find.text('Connecting…'), findsNothing);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('renders green Live pill when connected', (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _harness(
          stream: controller.stream,
          initialState: RealtimeConnectionState.connected,
        ),
      );
      await tester.pump();

      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Reconnecting…'), findsNothing);
      // Pin the color contract so a future regression that swaps the
      // connected pill to amber (or any other accent) fails this
      // suite instead of slipping through.
      final visual =
          syncStateBadgeVisualFor(RealtimeConnectionState.connected)!;
      expect(visual.dot, AppColors.positive);
      expect(visual.text, AppColors.positive);
    });

    testWidgets('renders amber Connecting… pill while connecting',
        (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _harness(
          stream: controller.stream,
          initialState: RealtimeConnectionState.connecting,
        ),
      );
      await tester.pump();

      expect(find.text('Connecting…'), findsOneWidget);
      expect(find.text('Live'), findsNothing);
      final visual =
          syncStateBadgeVisualFor(RealtimeConnectionState.connecting)!;
      expect(visual.dot, AppColors.warning);
      expect(visual.text, AppColors.warning);
    });

    testWidgets('renders amber Reconnecting… pill while waiting on back-off',
        (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _harness(
          stream: controller.stream,
          initialState: RealtimeConnectionState.reconnecting,
        ),
      );
      await tester.pump();

      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Live'), findsNothing);
      final visual =
          syncStateBadgeVisualFor(RealtimeConnectionState.reconnecting)!;
      expect(visual.dot, AppColors.warning);
      expect(visual.text, AppColors.warning);
    });

    test('color contract: connected is green, in-flight states are amber', () {
      final connected =
          syncStateBadgeVisualFor(RealtimeConnectionState.connected)!;
      final connecting =
          syncStateBadgeVisualFor(RealtimeConnectionState.connecting)!;
      final reconnecting =
          syncStateBadgeVisualFor(RealtimeConnectionState.reconnecting)!;

      // Connected = green positive accent. Locked so a future change
      // that flips this to amber fails here.
      expect(connected.dot, AppColors.positive);
      expect(connected.text, AppColors.positive);

      // Both in-flight states share the amber warning accent.
      expect(connecting.dot, AppColors.warning);
      expect(connecting.text, AppColors.warning);
      expect(reconnecting.dot, AppColors.warning);
      expect(reconnecting.text, AppColors.warning);

      // The connected and in-flight palettes must be different —
      // otherwise the operator can't visually distinguish a healthy
      // channel from a recovering one.
      expect(connected.dot, isNot(equals(connecting.dot)));
      expect(connected.dot, isNot(equals(reconnecting.dot)));

      // Idle has no visual; the badge collapses to SizedBox.shrink.
      expect(syncStateBadgeVisualFor(RealtimeConnectionState.idle), isNull);
    });

    testWidgets('updates pill when stream emits a new state', (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _harness(
          stream: controller.stream,
          initialState: RealtimeConnectionState.connected,
        ),
      );
      await tester.pump();
      expect(find.text('Live'), findsOneWidget);

      controller.add(RealtimeConnectionState.reconnecting);
      await tester.pumpAndSettle();
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Live'), findsNothing);

      controller.add(RealtimeConnectionState.connected);
      await tester.pumpAndSettle();
      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('renders SizedBox.shrink (no pill chrome) when stream is null',
        (tester) async {
      await tester.pumpWidget(_harness(stream: null));
      // Two SizedBox.shrink() instances — the badge itself + the
      // ConstrainedBox short-circuit. We only assert no Tooltip
      // chrome leaks through, which is the user-visible surface.
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('non-idle pill width is stable across state transitions',
        (tester) async {
      final controller = StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _harness(
          stream: controller.stream,
          initialState: RealtimeConnectionState.connected,
        ),
      );
      await tester.pump();
      final connectedSize = tester.getSize(find.byKey(SyncStateBadge.pillKey));

      controller.add(RealtimeConnectionState.connecting);
      await tester.pumpAndSettle();
      final connectingSize = tester.getSize(find.byKey(SyncStateBadge.pillKey));

      controller.add(RealtimeConnectionState.reconnecting);
      await tester.pumpAndSettle();
      final reconnectingSize =
          tester.getSize(find.byKey(SyncStateBadge.pillKey));

      // The pill width is gated by the min-width constraint and must
      // not shrink between the shorter "Live" label and the longer
      // "Reconnecting…" label, so the surrounding app-bar actions
      // don't shift on state change.
      expect(connectedSize.width, equals(reconnectingSize.width));
      expect(connectingSize.width, equals(reconnectingSize.width));
    });

    // ─── Phase 10a.4 — degraded branch ─────────────────────────────
    //
    // When the WebSocket is alive AND the tripwire stream reports
    // red, the badge shifts to "Degraded" (amber) instead of the
    // green "Live" pill. Yellow tripwires DO NOT trip the badge —
    // yellow is "trending bad", red is "events being dropped".

    testWidgets(
      'shifts to Degraded when tripwire stream reports red while connected',
      (tester) async {
        final connectionController =
            StreamController<RealtimeConnectionState>.broadcast();
        final tripwireController =
            StreamController<OutboxTripwireStatus>.broadcast();
        addTearDown(connectionController.close);
        addTearDown(tripwireController.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RealtimeConnectionScope(
                connectionStateStream: connectionController.stream,
                initialState: RealtimeConnectionState.connected,
                child: RealtimeTripwireScope(
                  tripwireStatusStream: tripwireController.stream,
                  initialStatus: OutboxTripwireStatus.red,
                  child: const Center(child: SyncStateBadge()),
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Degraded'), findsOneWidget);
        expect(find.text('Live'), findsNothing);

        // Tripwire recovers → pill returns to green Live.
        tripwireController.add(OutboxTripwireStatus.green);
        await tester.pumpAndSettle();
        expect(find.text('Live'), findsOneWidget);
        expect(find.text('Degraded'), findsNothing);
      },
    );

    testWidgets('yellow tripwire does NOT shift the badge to Degraded',
        (tester) async {
      final connectionController =
          StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(connectionController.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RealtimeConnectionScope(
              connectionStateStream: connectionController.stream,
              initialState: RealtimeConnectionState.connected,
              child: const RealtimeTripwireScope(
                tripwireStatusStream: null,
                initialStatus: OutboxTripwireStatus.yellow,
                child: Center(child: SyncStateBadge()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Live'), findsOneWidget);
      expect(find.text('Degraded'), findsNothing);
    });

    testWidgets('connecting/reconnecting still wins over red tripwire',
        (tester) async {
      // Mid-handshake the connection-state pill is the more urgent
      // signal — operator sees "Connecting…" / "Reconnecting…", not
      // "Degraded".
      final connectionController =
          StreamController<RealtimeConnectionState>.broadcast();
      addTearDown(connectionController.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RealtimeConnectionScope(
              connectionStateStream: connectionController.stream,
              initialState: RealtimeConnectionState.reconnecting,
              child: const RealtimeTripwireScope(
                tripwireStatusStream: null,
                initialStatus: OutboxTripwireStatus.red,
                child: Center(child: SyncStateBadge()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Degraded'), findsNothing);
    });
  });
}
