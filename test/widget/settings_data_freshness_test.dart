// Phase 10a.UX.1 — SettingsDataFreshnessSection widget test.
//
// Pinned behavior:
//   * one row per shared-state table from the phase doc list (8 rows;
//     `restaurant_users`, `roles`, and `role_permissions` share a row
//     per the Phase 9 user/role grouping)
//   * rows read "No updates yet" when no event has stamped that table
//   * after the notifier ingests a `shared_state.*` frame for a
//     table, that row flips to a relative timestamp ("just now") and
//     the absolute UTC ISO timestamp surfaces in the row's tooltip
//   * the section reacts to notifier changes (no manual rebuild)
//   * non-shared topics with a payload `table` are ignored upstream
//     (LastSyncedTimestampsNotifier guards the topic prefix)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
import 'package:forge_and_flow/services/realtime/realtime_event.dart';
import 'package:forge_and_flow/state/last_synced_timestamps_notifier.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';

void main() {
  group('SettingsDataFreshnessSection', () {
    testWidgets(
      'renders one row per shared-state table; all read "No updates yet" when '
      'no event has been ingested',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: SettingsDataFreshnessSection()),
          ),
        );

        for (final label in <String>[
          'Restaurant profile',
          'Benchmarks and targets',
          'Weekly plans',
          'Target change history',
          'Notifications',
          'Audit history',
          'Connector setup',
          'Team members and roles',
        ]) {
          expect(
            find.byKey(Key('settings_data_freshness_row_$label')),
            findsOneWidget,
            reason: 'row for $label must render',
          );
          expect(find.text(label), findsOneWidget);
        }
        // 8 rows × at least one "No updates yet" each.
        expect(find.text('No updates yet'), findsNWidgets(8));
      },
    );

    testWidgets('after ingesting a shared_state frame for a table, that row '
        'flips from "No updates yet" to a relative timestamp and tooltip shows '
        'the UTC ISO', (tester) async {
      final stamp = DateTime.utc(2026, 5, 3, 12, 0, 0);
      final notifier = LastSyncedTimestampsNotifier(now: () => stamp);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsDataFreshnessSection(notifier: notifier),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('settings_data_freshness_row_Weekly plans')),
          matching: find.text('No updates yet'),
        ),
        findsOneWidget,
      );

      notifier.ingest(
        _event(
          topic: 'shared_state.$_opA.weekly_plan_snapshots',
          payload: const <String, Object?>{'table': 'weekly_plan_snapshots'},
        ),
      );
      await tester.pump();

      expect(
        find.descendant(
          of: find.byKey(const Key('settings_data_freshness_row_Weekly plans')),
          matching: find.text('No updates yet'),
        ),
        findsNothing,
      );

      // Other rows still read "No updates yet".
      expect(
        find.descendant(
          of: find.byKey(
            const Key('settings_data_freshness_row_Restaurant profile'),
          ),
          matching: find.text('No updates yet'),
        ),
        findsOneWidget,
      );

      // Tooltip surfaces the absolute UTC ISO timestamp.
      final tooltipFinder = find.descendant(
        of: find.byKey(const Key('settings_data_freshness_row_Weekly plans')),
        matching: find.byType(Tooltip),
      );
      expect(tooltipFinder, findsOneWidget);
      final tooltip = tester.widget<Tooltip>(tooltipFinder);
      expect(tooltip.message, stamp.toIso8601String());
    });

    testWidgets('restaurant_users + roles + role_permissions row updates when '
        'ANY of the three Phase 9 tables receives a frame; row reflects '
        'the newest of the three timestamps', (tester) async {
      var tick = 0;
      final clock = <DateTime>[
        DateTime.utc(2026, 5, 3, 12, 0, 0),
        DateTime.utc(2026, 5, 3, 12, 0, 30),
        DateTime.utc(2026, 5, 3, 12, 1, 0),
      ];
      final notifier = LastSyncedTimestampsNotifier(now: () => clock[tick++]);
      addTearDown(notifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsDataFreshnessSection(notifier: notifier),
          ),
        ),
      );

      notifier.ingest(
        _event(
          topic: 'shared_state.$_opA.restaurant_users',
          payload: const <String, Object?>{'table': 'restaurant_users'},
        ),
      );
      await tester.pump();

      notifier.ingest(
        _event(
          topic: 'shared_state.$_opA.roles',
          payload: const <String, Object?>{'table': 'roles'},
        ),
      );
      await tester.pump();

      // role_permissions is the third member of the Phase 9 group.
      notifier.ingest(
        _event(
          topic: 'shared_state.$_opA.role_permissions',
          payload: const <String, Object?>{'table': 'role_permissions'},
        ),
      );
      await tester.pump();

      final tooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byKey(
            const Key('settings_data_freshness_row_Team members and roles'),
          ),
          matching: find.byType(Tooltip),
        ),
      );
      // Newest of the three stamps is the role_permissions tick
      // (clock[2]); the row tooltip reflects that.
      expect(tooltip.message, clock[2].toIso8601String());
    });
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
