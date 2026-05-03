// Phase 10a.UX.1 — PeerEditToast widget test.
//
// Pinned behavior:
//   * a `shared_state.<op>.<table>` frame with a matching payload
//     `table` field surfaces a SnackBar with "Peer edit: <table>"
//     via the nearest ScaffoldMessenger
//   * the topic-fallback path works: a `shared_state.<op>.<table>`
//     frame whose payload omits the field still toasts using the
//     topic last segment
//   * the configured duration is forwarded to the SnackBar
//   * non-`shared_state.*` topics are IGNORED even when they carry a
//     `table` payload field — preventing false-positive toasts from
//     `auth.*`/`rollup.invalidate.*`/etc.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/widgets/peer_edit_toast.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('PeerEditToast', () {
    testWidgets(
      'shared_state frame surfaces a SnackBar via ScaffoldMessenger '
      'and forwards the configured duration',
      (tester) async {
        final controller = StreamController<RealtimeEvent>.broadcast();
        addTearDown(controller.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PeerEditToast(
                events: controller.stream,
                duration: const Duration(seconds: 3),
                child: const Text('shell'),
              ),
            ),
          ),
        );

        // Sanity — child renders unchanged.
        expect(find.text('shell'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);

        controller.add(
          _event(
            topic: 'shared_state.$_opA.weekly_plan_snapshots',
            payload: const <String, Object?>{'table': 'weekly_plan_snapshots'},
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Peer edit: weekly_plan_snapshots'), findsOneWidget);
        final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
        expect(snackBar.duration, const Duration(seconds: 3));

        await tester.pumpAndSettle(const Duration(seconds: 6));
      },
    );

    testWidgets(
      'topic shared_state.<op>.<table> surfaces the table even when '
      'payload omits the field (Lock 9 fallback)',
      (tester) async {
        final controller = StreamController<RealtimeEvent>.broadcast();
        addTearDown(controller.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PeerEditToast(
                events: controller.stream,
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        );

        controller.add(
          _event(
            topic: 'shared_state.$_opA.connector_configs',
            payload: const <String, Object?>{},
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Peer edit: connector_configs'), findsOneWidget);
        await tester.pumpAndSettle(const Duration(seconds: 3));
      },
    );

    testWidgets(
      'non-shared topics with a payload table field are IGNORED — '
      'no false-positive toast from auth.* / rollup.invalidate.* etc.',
      (tester) async {
        final controller = StreamController<RealtimeEvent>.broadcast();
        addTearDown(controller.close);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PeerEditToast(
                events: controller.stream,
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        );

        controller.add(
          _event(
            topic: 'auth.session.login',
            payload: const <String, Object?>{'table': 'restaurants'},
          ),
        );
        controller.add(
          _event(
            topic: 'rollup.invalidate.variance_week',
            payload: const <String, Object?>{'table': 'weekly_plan_snapshots'},
          ),
        );
        controller.add(
          _event(
            topic: 'rollup.invalidate.variance_week',
            payload: const <String, Object?>{},
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });
}

RealtimeEvent _event({
  required String topic,
  required Map<String, Object?> payload,
}) {
  return RealtimeEvent(
    eventId: 'evt-${topic.hashCode}-${payload['table'] ?? 'none'}',
    topic: topic,
    operatorId: _opA,
    occurredAt: DateTime.utc(2026, 5, 3, 12),
    payload: payload,
  );
}
