// Phase 10a.UX.1 — Provider integration test.
//
// Pin the production wiring chain that ForgeFlowScope sets up:
//   Provider<RealtimeEventBus>
//     → ChangeNotifierProxyProvider<RealtimeEventBus,
//          LastSyncedTimestampsNotifier>
//     → PeerEditToast(events: bus.events) wraps the route
//     → SettingsDataFreshnessSection consumes the notifier
//
// Publishing a shared_state frame to the bus must:
//   * surface a SnackBar via ScaffoldMessenger (toast)
//   * stamp the freshness notifier so the SettingsDataFreshnessSection
//     row for that table flips from "Never" to a relative timestamp
//
// This proves both surfaces wire end-to-end through the Provider
// chain — guarding against a regression where the runtime
// integration silently breaks even though the unit tests still pass.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/state/last_synced_timestamps_notifier.dart';
import 'package:forge_and_flow/state/realtime_event_bus.dart';
import 'package:forge_and_flow/widgets/peer_edit_toast.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  testWidgets(
    'bus.publish drives both PeerEditToast and '
    'SettingsDataFreshnessSection through the Provider chain',
    (tester) async {
      final bus = RealtimeEventBus();
      addTearDown(bus.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            Provider<RealtimeEventBus>.value(value: bus),
            ChangeNotifierProxyProvider<
              RealtimeEventBus,
              LastSyncedTimestampsNotifier
            >(
              create: (_) => LastSyncedTimestampsNotifier(),
              update: (_, b, previous) {
                final notifier = previous ?? LastSyncedTimestampsNotifier();
                notifier.subscribeRealtime(b.events);
                return notifier;
              },
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) {
                final providedBus = context.read<RealtimeEventBus>();
                return PeerEditToast(
                  events: providedBus.events,
                  child: const Scaffold(
                    body: SettingsDataFreshnessSection(),
                  ),
                );
              },
            ),
          ),
        ),
      );

      // Pre-publish: every freshness row reads "Never"; no toast.
      expect(find.text('Never'), findsNWidgets(8));
      expect(find.byType(SnackBar), findsNothing);

      bus.publish(
        RealtimeEvent(
          eventId: 'evt-int-1',
          topic: 'shared_state.$_opA.audit_trail',
          operatorId: _opA,
          occurredAt: DateTime.utc(2026, 5, 3, 12, 0, 0),
          payload: const <String, Object?>{'table': 'audit_trail'},
        ),
      );
      // First pump: stream listeners run, notifier stamps + notifies,
      // PeerEditToast schedules SnackBar.
      await tester.pump();
      // Second pump: SnackBar enters the tree.
      await tester.pump(const Duration(milliseconds: 50));

      // Toast surface — SnackBar appeared via the Scaffold's messenger.
      expect(find.text('Peer edit: audit_trail'), findsOneWidget);

      // Freshness surface — the audit_trail row no longer reads
      // "Never". Seven other rows still do.
      expect(
        find.descendant(
          of: find.byKey(
            const Key('settings_data_freshness_row_audit_trail'),
          ),
          matching: find.text('Never'),
        ),
        findsNothing,
      );
      expect(find.text('Never'), findsNWidgets(7));

      // Drain SnackBar timer for clean teardown.
      await tester.pumpAndSettle(const Duration(seconds: 6));
    },
  );
}
