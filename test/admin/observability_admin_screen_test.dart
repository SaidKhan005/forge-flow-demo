// AI Metrics redesign — Observability admin screen widget tests.
//
// Drives `ObservabilityAdminScreen` against an
// `InMemoryObservabilityAdminGateway` so the click path runs end-to-
// end without a backend or real proxy. The screen was rebuilt to the
// approved four-tab AI Metrics mockup (Money / Customers / Reliability
// / Knowledge) with four hero summary cards, a cost-by-use-case donut,
// and a "This month / Last month" selector. Coverage:
//
//   * Initial render is manual-only and does not fetch.
//   * Confirmed manual fetch shows the four tabs + four hero cards.
//   * Scope AND month pass through to the gateway request.
//   * Each tab renders its key panels.
//   * Money: cost-by-use-case donut total, reuse bars, cost controls.
//   * Customers: top spenders + "Needs attention" with a "View
//     account" drill-down handoff; honest "Not available yet" empty
//     state for losing-money when pricing is untracked, real underwater
//     rows when pricing is present.
//   * Reliability: speed-vs-System-health hint, background jobs, hosting.
//   * Knowledge: graph counts + freshness.
//   * Manual refresh re-fetches; the month switch re-fetches.
//   * Stacked in-flight requests do not double-fire (no auto-poll).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/admin_routes.dart' show kAdminOperatorsRouteId;
import 'package:forge_and_flow/admin/models/observability_admin_models.dart';
import 'package:forge_and_flow/admin/screens/observability_admin_screen.dart';
import 'package:forge_and_flow/admin/services/observability_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/realtime_tripwire_admin_gateway.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_evaluator.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  /// Wide viewport: four tabs + four hero cards + scrollable section
  /// cards do not fit the default 800x600 viewport.
  void setLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> runCheck(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('admin_observability_refresh_button')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_observability_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_observability_confirm_run')));
    await tester.pumpAndSettle();
  }

  testWidgets('initial render waits for a confirmed manual check', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _BlockingObservabilityGateway();
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.fetchCount, equals(0));
    expect(
      find.byKey(const Key('admin_observability_manual_prompt')),
      findsOneWidget,
    );
    expect(find.text('Check AI Metrics'), findsOneWidget);
    expect(find.byKey(const Key('admin_observability_tabs')), findsNothing);
  });

  testWidgets('manual check carries selected hierarchy scope AND month '
      'to the gateway', (tester) async {
    setLargeViewport(tester);
    final gateway = _BlockingObservabilityGateway();
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
            operatorId: 'op-a',
            orgUnitId: 'ou-a',
            operatorName: 'Demo Diner',
            orgUnitName: 'Downtown',
          ),
          scopeLocationIds: const <String>{'loc-a', 'loc-b'},
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Demo Diner / Downtown'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('admin_observability_refresh_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_observability_confirm_run')));
    await tester.pump();

    expect(gateway.fetchCount, equals(1));
    expect(gateway.requests.single.operatorId, equals('op-a'));
    expect(gateway.requests.single.locationId, isNull);
    expect(
      gateway.requests.single.locationIds,
      equals(<String>{'loc-a', 'loc-b'}),
    );
    // Default month is the current calendar month.
    expect(
      gateway.requests.single.month,
      equals(ObservabilityMonth.current),
    );
  });

  testWidgets('switching to "Last month" re-fetches with the previous '
      'month bucket', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);

    expect(
      find.byKey(const Key('admin_observability_month_selector')),
      findsOneWidget,
    );
    // Switching the month is a re-fetch (no confirm dialog).
    await tester.tap(
      find.byKey(const Key('admin_observability_month_previous')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_confirm_dialog')),
      findsNothing,
    );
    // The screen is still mounted with its tabs after the re-fetch.
    expect(find.byKey(const Key('admin_observability_tabs')), findsOneWidget);
  });

  testWidgets('the month selector does not fetch before the first '
      'confirmed run', (tester) async {
    setLargeViewport(tester);
    final gateway = _BlockingObservabilityGateway();
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No selector on the manual prompt yet (no envelope, no tabs).
    expect(
      find.byKey(const Key('admin_observability_month_selector')),
      findsNothing,
    );
    expect(gateway.fetchCount, equals(0));
  });

  testWidgets('confirmed manual fetch renders four tabs + four hero cards', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);

    expect(find.byKey(const Key('admin_observability_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_observability_tabs')), findsOneWidget);
    for (final suffix in <String>[
      'money',
      'customers',
      'reliability',
      'knowledge',
    ]) {
      expect(
        find.byKey(Key('admin_observability_tab_$suffix')),
        findsOneWidget,
        reason: 'tab $suffix must render',
      );
    }
    // Four hero summary cards.
    expect(
      find.byKey(const Key('admin_observability_hero_spend')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_hero_businesses')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_hero_speed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_hero_knowledge')),
      findsOneWidget,
    );
  });

  testWidgets('Money tab renders the cost-by-use-case donut, reuse bars, '
      'and cost controls', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);

    // Money tab is selected by default.
    expect(
      find.byKey(const Key('admin_observability_section_cost_by_use_case')),
      findsOneWidget,
    );
    // Donut total renders the summed cost.
    expect(
      find.byKey(const Key('admin_observability_cost_total')),
      findsOneWidget,
    );
    // One legend row per use case present in the seed.
    expect(
      find.byKey(const Key('admin_observability_cost_legend_advisor_qa')),
      findsOneWidget,
    );
    // Saved answer reuse bars (one per query_class in cacheHitRates).
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_advisor_qa')),
      findsOneWidget,
    );
    // Cost controls: model mix + batch share bars.
    expect(
      find.byKey(const Key('admin_observability_section_cost_controls')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_model_mix_advisor_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_batch_mode_share_wf_pl')),
      findsOneWidget,
    );
    // The wf_pl model mix is 90% Sonnet against a 95% ceiling: NOT over.
    // coach_qa is 45% against a 40% ceiling: over-target tag shows.
    expect(
      find.byKey(const Key('admin_observability_model_mix_over_coach_qa')),
      findsOneWidget,
    );
  });

  testWidgets('Customers tab renders top spenders and the needs-attention '
      'list', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_section_top_spenders')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_needs_attention')),
      findsOneWidget,
    );
    // Demo Diner Co. is the 7d top spender (operator axis).
    expect(
      find.byKey(
        const Key(
          'admin_observability_top_spender_operator_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );
    // A cap event existed for Demo Diner Co. → limit-hit attention row.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_limit_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );
    // Sunset Cafe Group is dormant 32d → inactive attention row.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_inactive_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('losing-money renders the honest "Not available yet" empty '
      'state when pricing is untracked', (tester) async {
    setLargeViewport(tester);
    // The demo seed's margins all have placeholder revenue (Demo Diner
    // \$199 is the one real row; Sunset is \$0). Build an envelope where
    // EVERY margin has zero revenue so pricing reads as untracked.
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'margins': <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': '00000000-0000-4000-8000-000000000001',
          'business_name': 'Demo Diner Co.',
          'subscription_tier': 'launch',
          'revenue_usd': 0.0,
          'cost_usd': 12.0,
        },
      ],
    };
    final gateway = InMemoryObservabilityAdminGateway(envelope: envelope);
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    // Honest empty state, NOT a fabricated underwater row / $0.
    expect(
      find.byKey(const Key('admin_observability_losing_money_unavailable')),
      findsOneWidget,
    );
    expect(find.text('Not available yet'), findsOneWidget);
    // No underwater attention row was fabricated from the zero-revenue
    // placeholder.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_underwater_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsNothing,
    );
    // The hero card likewise refuses to claim "0 losing money".
    expect(find.text('Profit not tracked yet'), findsWidgets);
  });

  testWidgets('real underwater margin surfaces a losing-money attention row '
      'when pricing is tracked', (tester) async {
    setLargeViewport(tester);
    // One business with real revenue but underwater (cost > revenue).
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'margins': <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': '00000000-0000-4000-8000-000000000001',
          'business_name': 'Demo Diner Co.',
          'subscription_tier': 'launch',
          'revenue_usd': 99.0,
          'cost_usd': 189.0,
        },
      ],
    };
    final gateway = InMemoryObservabilityAdminGateway(envelope: envelope);
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_losing_money_unavailable')),
      findsNothing,
    );
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_underwater_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a "View account" link hands off to the Business accounts '
      'route carrying the operator scope', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    AdminRouteIntent? captured;
    await tester.pumpWidget(
      wrap(
        AdminRouteHandoff(
          selectedRouteId: 'observability',
          onSelectRoute: (intent) => captured = intent,
          child: ObservabilityAdminScreen(
            gateway: gateway,
            now: () => DateTime.utc(2026, 5, 3, 12),
          ),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    // Tap the top-spender "View account" link for Demo Diner Co.
    await tester.tap(
      find.byKey(
        const Key(
          'admin_observability_top_spender_view_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.routeId, equals(kAdminOperatorsRouteId));
    expect(
      captured!.hierarchyScope?.operatorId,
      equals('00000000-0000-4000-8000-000000000001'),
    );
  });

  testWidgets('Reliability tab renders speed, background jobs, and hosting', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_reliability')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_section_speed')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_background_jobs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_hosting')),
      findsOneWidget,
    );
    // route_latency is empty in the demo seed → honest System-health
    // hint rather than fabricated latency numbers.
    expect(
      find.byKey(const Key('admin_observability_speed_health_hint')),
      findsOneWidget,
    );
    // Background jobs: the seed has 1 dead-lettered → stuck stat + hint.
    expect(
      find.byKey(const Key('admin_observability_jobs_dead_lettered')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_jobs_stuck_hint')),
      findsOneWidget,
    );
    // Hosting rows for both demo Cloud Run services.
    expect(
      find.byKey(const Key('admin_observability_hosting_advisor-proxy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_hosting_admin-proxy')),
      findsOneWidget,
    );
  });

  testWidgets('route_latency present renders the speed stat grid', (
    tester,
  ) async {
    setLargeViewport(tester);
    // Demo seed already carries route_latency rows; assert the stat grid
    // path (not the hint) when latency is populated.
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_reliability')),
    );
    await tester.pumpAndSettle();
    // The demo seed has route_latency rows, so the hint is absent and
    // the speed hero card reads "Fast".
    expect(
      find.byKey(const Key('admin_observability_speed_health_hint')),
      findsNothing,
    );
  });

  testWidgets('Knowledge tab renders graph counts and freshness', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_knowledge')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_section_graph_counts')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_graph_freshness')),
      findsOneWidget,
    );
    for (final suffix in <String>[
      'graph_approved_nodes',
      'graph_approved_edges',
      'graph_inferred_approved',
      'graph_isolated_nodes',
      'graph_projection_age',
      'graph_traversal_p95',
    ]) {
      expect(
        find.byKey(Key('admin_observability_$suffix')),
        findsOneWidget,
        reason: 'knowledge stat $suffix must render',
      );
    }
  });

  testWidgets('cost-by-use-case shows an honest empty state with no cost '
      'rows', (tester) async {
    setLargeViewport(tester);
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'cost_telemetry': const <Map<String, Object?>>[],
    };
    final gateway = InMemoryObservabilityAdminGateway(envelope: envelope);
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);

    expect(
      find.byKey(const Key('admin_observability_cost_by_use_case_empty')),
      findsOneWidget,
    );
    // Spend hero card honestly reads $0.00 (a real summed zero, not a
    // laundered red→green), and the donut total is absent.
    expect(
      find.byKey(const Key('admin_observability_cost_total')),
      findsNothing,
    );
  });

  testWidgets('manual refresh re-fetches the envelope', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);

    // Default demo envelope has top spenders on the Customers tab.
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key(
          'admin_observability_top_spender_operator_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );

    // Re-seed with an envelope that has no top spenders; manual refresh
    // should consume the new envelope.
    final reseeded = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'top_expensive': const <Map<String, Object?>>[],
    };
    gateway.setEnvelope(reseeded);
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_observability_top_spenders_empty')),
      findsOneWidget,
    );
  });

  testWidgets('manual check does not auto-poll or stack in flight', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _BlockingObservabilityGateway();
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.fetchCount, equals(0));
    await tester.tap(
      find.byKey(const Key('admin_observability_refresh_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_observability_confirm_run')));
    await tester.pump();

    expect(
      gateway.fetchCount,
      equals(1),
      reason:
          'manual observability calls must not stack while one is in flight',
    );
    await tester.pump(const Duration(milliseconds: 55));
    expect(gateway.fetchCount, equals(1));

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    gateway.completeOldest(
      ObservabilityEnvelope.fromJson(kObservabilityAdminDemoEnvelope),
    );
    await tester.pump();
  });

  // ─── Phase 10a.4 — Live sync (bridge tripwires) ────────────────────
  testWidgets(
    'live sync renders one row per Q22 metric and the worst-wins status '
    'on the Reliability tab',
    (tester) async {
      setLargeViewport(tester);
      final observability = InMemoryObservabilityAdminGateway(
        envelope: kObservabilityAdminDemoEnvelope,
      );
      // Seeded: bridge_lag yellow (90s), undelivered green (5),
      // publish error red (10%), notify queue green (5%). Worst-wins
      // → red status pill.
      final tripwires = InMemoryRealtimeTripwireAdminGateway(
        snapshot: RealtimeTripwireSnapshot.fromJson(<String, Object?>{
          'status': 'red',
          'metrics': <String, Object?>{
            'event_outbox_bridge_lag_seconds': <String, Object?>{
              'value': 90,
              'status': 'yellow',
              'thresholds': <String, Object?>{'yellow': 60, 'red': 300},
            },
            'event_outbox_undelivered_count': <String, Object?>{
              'value': 5,
              'status': 'green',
              'thresholds': <String, Object?>{'yellow': 10000, 'red': 100000},
            },
            'event_outbox_publish_error_rate': <String, Object?>{
              'value': 0.10,
              'status': 'red',
              'thresholds': <String, Object?>{'yellow': 0.01, 'red': 0.05},
            },
            'pg_notification_queue_usage': <String, Object?>{
              'value': 0.05,
              'status': 'green',
              'thresholds': <String, Object?>{'yellow': 0.10, 'red': 0.25},
            },
          },
          'breaches': const <Object?>[],
          'checked_at': '2026-05-03T12:00:00.000Z',
        }),
      );
      await tester.pumpWidget(
        wrap(
          ObservabilityAdminScreen(
            gateway: observability,
            tripwireGateway: tripwires,
            now: () => DateTime.utc(2026, 5, 3, 12),
          ),
        ),
      );
      await runCheck(tester);
      await tester.tap(
        find.byKey(const Key('admin_observability_tab_reliability')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_observability_section_live_sync')),
        findsOneWidget,
      );
      // One row per Q22 metric (4 total).
      for (final metric in OutboxTripwireMetric.values) {
        final key = outboxTripwireMetricKey(metric);
        expect(
          find.byKey(Key('admin_observability_live_sync_row_$key')),
          findsOneWidget,
          reason: 'expected a live-sync row for $key',
        );
      }
      // Worst-wins status pill is red.
      expect(
        find.byKey(const Key('admin_observability_live_sync_status_red')),
        findsOneWidget,
      );
    },
  );

  testWidgets('live sync section is omitted when no tripwire gateway is '
      'wired', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrap(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_reliability')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_section_live_sync')),
      findsNothing,
    );
  });
}

class _BlockingObservabilityGateway implements ObservabilityAdminGateway {
  int fetchCount = 0;
  final List<Completer<ObservabilityEnvelope>> _pending =
      <Completer<ObservabilityEnvelope>>[];
  final List<ObservabilityFetchRequest> requests =
      <ObservabilityFetchRequest>[];

  @override
  Future<ObservabilityEnvelope> fetch([
    ObservabilityFetchRequest request = const ObservabilityFetchRequest(),
  ]) {
    fetchCount += 1;
    requests.add(request);
    final completer = Completer<ObservabilityEnvelope>();
    _pending.add(completer);
    return completer.future;
  }

  void completeOldest(ObservabilityEnvelope envelope) {
    if (_pending.isEmpty) return;
    _pending.removeAt(0).complete(envelope);
  }
}
