// Phase 11A.6 — AI Metrics (observability) admin screen widget tests.
//
// Drives the redesigned `ObservabilityAdminScreen` (four plain-English
// tabs: Money / Customers / Reliability / Knowledge) against an
// `InMemoryObservabilityAdminGateway` so the click path runs end-to-end
// without a backend or real proxy. Coverage:
//
//   * Initial render is manual-only and does not fetch.
//   * Confirmed manual fetch shows the four tabs, hero cards, and the
//     as-of strip.
//   * Scope AND month (current / previous) pass through to the gateway
//     request; switching month re-fetches with the new bucket.
//   * Each tab renders its key panels:
//       - Money: cost donut, saved-answer reuse, cost controls.
//       - Customers: top spenders + needs-attention (losing money /
//         limit hits / inactive).
//       - Reliability: speed, background jobs, hosting, live sync.
//       - Knowledge: graph counts + freshness.
//   * "Losing money" renders an honest "Not available yet" empty state
//     when no margin (pricing) rows are present — never $0.
//   * Cloud Run unknown instance count renders "unknown", not 0.
//   * "View account" drill-down dispatches an operators route intent.
//   * Manual refresh re-fetches the envelope (no auto-poll).
//   * Stacked in-flight refresh requests do not double-fire.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/admin_routes.dart'
    show kAdminOperatorsRouteId;
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

  /// A route-handoff host so the "View account" drill-down has a handoff
  /// to dispatch into. Captures the intents the screen emits.
  Widget wrapWithHandoff(Widget child, List<AdminRouteIntent> captured) => wrap(
    AdminRouteHandoff(
      selectedRouteId: 'observability',
      onSelectRoute: captured.add,
      child: child,
    ),
  );

  /// Same large-viewport setup as the health screen test — four tabs +
  /// scrollable section cards do not fit the default 800x600 viewport.
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

  testWidgets('manual check carries selected hierarchy scope to gateway', (
    tester,
  ) async {
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

    expect(find.textContaining('Demo Diner / Downtown'), findsNothing);
    // The workspace scope picker already names the selected scope. The old
    // per-screen scope note and verbose "Where this applies" block are gone.
    expect(
      find.byKey(const Key('admin_observability_scope_note')),
      findsNothing,
    );
    expect(
      find.textContaining('hosting and the knowledge graph stay platform-wide'),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_observability_scope_notice')),
      findsNothing,
    );
    expect(find.text('Where this applies'), findsNothing);

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
    // Month defaults to the current calendar-month bucket.
    expect(gateway.requests.single.month, equals(ObservabilityMonth.current));
  });

  testWidgets('confirmed manual fetch renders four tabs, hero cards, as-of '
      'strip', (tester) async {
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
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Run metrics check'), findsNothing);
    expect(find.textContaining('Updated'), findsOneWidget);
    expect(find.byKey(const Key('admin_observability_tabs')), findsOneWidget);
    for (final suffix in const <String>[
      'money',
      'customers',
      'reliability',
      'knowledge',
    ]) {
      expect(
        find.byKey(Key('admin_observability_tab_$suffix')),
        findsOneWidget,
        reason: 'expected the $suffix tab',
      );
    }
    // Four hero summary cards.
    for (final hero in const <String>[
      'spend',
      'customers',
      'speed',
      'knowledge',
    ]) {
      expect(
        find.byKey(Key('admin_observability_hero_$hero')),
        findsOneWidget,
        reason: 'expected the $hero hero card',
      );
    }
    expect(
      find.byKey(const Key('admin_observability_as_of_strip')),
      findsOneWidget,
    );
  });

  testWidgets('switching to Last month re-fetches with the previous bucket', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _RecordingObservabilityGateway(
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

    expect(gateway.requests.length, equals(1));
    expect(gateway.requests.last.month, equals(ObservabilityMonth.current));

    // Switching month re-fetches without a second confirm dialog.
    await tester.tap(
      find.byKey(const Key('admin_observability_month_previous')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_confirm_dialog')),
      findsNothing,
    );
    expect(gateway.requests.length, equals(2));
    expect(gateway.requests.last.month, equals(ObservabilityMonth.previous));
  });

  testWidgets('month selector does NOT fetch before the first confirmed run', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _RecordingObservabilityGateway(
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
    await tester.pumpAndSettle();

    // No envelope loaded yet — picking a month must not trigger a fetch
    // (manual-run gate still applies).
    await tester.tap(
      find.byKey(const Key('admin_observability_month_previous')),
    );
    await tester.pumpAndSettle();
    expect(gateway.requests, isEmpty);

    // The first confirmed run then uses the stored previous bucket.
    await runCheck(tester);
    expect(gateway.requests.single.month, equals(ObservabilityMonth.previous));
  });

  testWidgets('Money tab renders the cost donut, reuse bars, and cost '
      'controls', (tester) async {
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
    // Money is the default tab.
    expect(
      find.byKey(const Key('admin_observability_section_cost_telemetry')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cost_donut')),
      findsOneWidget,
    );
    // Cost summed by query_class -> a legend row per use case.
    expect(
      find.byKey(const Key('admin_observability_cost_legend_advisor_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_cache_hit_rates')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_advisor_qa')),
      findsOneWidget,
    );
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
    // Coaching help routes 45% to the detailed model (ceiling 40%) ->
    // over-target tag.
    expect(
      find.byKey(const Key('admin_observability_model_mix_over_coach_qa')),
      findsOneWidget,
    );
  });

  testWidgets('Customers tab renders top spenders and needs-attention rows', (
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
    // Default 7d window: Demo Diner Co. is the top spender.
    expect(
      find.byKey(
        const Key('admin_observability_spender_7d_operator_Demo Diner Co.'),
      ),
      findsOneWidget,
    );
    // Sunset Cafe Group is underwater (revenue $0 - cost $0.42) and
    // inactive (32 days silent) -> attention rows.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_losing_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_inactive_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsOneWidget,
    );
    // Demo Diner Co. hit a limit -> limit-hit attention row.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_limit_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('top spenders window selector switches between 1d / 7d / 30d', (
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
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    // Switch to 30d; a 30d-only staff spender row appears.
    await tester.tap(find.byKey(const Key('admin_observability_window_30d')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key(
          'admin_observability_spender_30d_staff_Owner @ Demo Diner Co.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Losing money shows an honest "Not available yet" empty state '
      'when no pricing rows are present (no phantom \$0)', (tester) async {
    setLargeViewport(tester);
    // Margins is the pricing-backed surface. With it empty the section
    // must NOT render $0 rows; it renders the honest unavailable note.
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'margins': const <Map<String, Object?>>[],
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
      findsOneWidget,
    );
    expect(find.textContaining('Not available yet'), findsOneWidget);
    // No underwater row was synthesized.
    expect(
      find.byKey(
        const Key(
          'admin_observability_attention_losing_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('View account drill-down dispatches an operators route intent', (
    tester,
  ) async {
    setLargeViewport(tester);
    final captured = <AdminRouteIntent>[];
    final gateway = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    await tester.pumpWidget(
      wrapWithHandoff(
        ObservabilityAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
        captured,
      ),
    );
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_customers')),
    );
    await tester.pumpAndSettle();

    // Tap the "View account" link on the inactive Sunset Cafe Group row.
    final link = find.byKey(
      const Key(
        'admin_observability_attention_view_inactive_'
        '00000000-0000-4000-8000-000000000002',
      ),
    );
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pump();

    expect(captured, isNotEmpty);
    final intent = captured.last;
    expect(intent.routeId, equals(kAdminOperatorsRouteId));
    expect(
      intent.operatorLocationScope?.operatorId,
      equals('00000000-0000-4000-8000-000000000002'),
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
    // Per-route latency lives in System health -> a link-out hint, not
    // invented numbers.
    expect(
      find.byKey(const Key('admin_observability_speed_health_link')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_background_jobs')),
      findsOneWidget,
    );
    // Demo seed has 1 dead-lettered job -> "stuck" stat + hint.
    expect(
      find.byKey(const Key('admin_observability_jobs_dead_lettered')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_jobs_stuck_hint')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_cloud_run_instances')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cloud_run_advisor-proxy')),
      findsOneWidget,
    );
  });

  testWidgets('Cloud Run unknown instance count renders "unknown", not 0', (
    tester,
  ) async {
    setLargeViewport(tester);
    // A service reporting instance_count 0 is "unknown", never a hard 0.
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'cloud_run': <Map<String, Object?>>[
        <String, Object?>{
          'service_name': 'advisor-proxy',
          'instance_count': 0,
          'revision_id': 'advisor-proxy-00037-n1k',
          'min_instances': 1,
          'max_instances': 8,
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
      find.byKey(const Key('admin_observability_tab_reliability')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('admin_observability_cloud_run_unknown_advisor-proxy'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('unknown'), findsWidgets);
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
    for (final stat in const <String>[
      'graph_approved_nodes',
      'graph_approved_edges',
      'graph_inferred_approved',
      'graph_isolated_nodes',
    ]) {
      expect(
        find.byKey(Key('admin_observability_$stat')),
        findsOneWidget,
        reason: 'expected the $stat knowledge stat',
      );
    }
    expect(
      find.byKey(const Key('admin_observability_section_graph_freshness')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_projection_age')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_traversal_p95')),
      findsOneWidget,
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

    // Default demo envelope has cache-hit rows -> reuse bars present.
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_advisor_qa')),
      findsOneWidget,
    );

    // Re-seed with an envelope that has zero cache-hit rows; manual
    // refresh should consume the new envelope.
    final reseeded = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'cache_hit_rates': const <Map<String, Object?>>[],
    };
    gateway.setEnvelope(reseeded);
    await runCheck(tester);
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rates_empty')),
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

  // ─── Use case filter (whole-page, client-side over the envelope) ───
  testWidgets('use-case selector is present after a run and defaults to All', (
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

    final selector = find.byKey(
      const Key('admin_observability_use_case_selector'),
    );
    expect(selector, findsOneWidget);
    // Defaults to All: the chip shows "All" and the full-breakdown spend
    // caption ("Across every use case this month.").
    expect(
      find.descendant(of: selector, matching: find.text('All')),
      findsOneWidget,
    );
    expect(find.text('Across every use case this month.'), findsOneWidget);
  });

  testWidgets('selecting a use case scopes the hero spend and the Money panels '
      'to that class', (tester) async {
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

    // The hero "AI spend" value lives inside the spend hero card; scope to
    // it so the donut center total / legend amounts do not collide.
    Finder heroSpendText(String dollars) => find.descendant(
      of: find.byKey(const Key('admin_observability_hero_spend')),
      matching: find.text(dollars),
    );

    // Baseline (All): hero spend is the cross-class total ($29.93) and the
    // coach_qa / wf_pl reuse + model-mix rows are present.
    expect(heroSpendText('\$29.93'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_coach_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_model_mix_wf_pl')),
      findsOneWidget,
    );

    // Filter to Advisor answers.
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_advisor_qa')),
    );
    await tester.pumpAndSettle();

    // Hero spend now sums only advisor_qa rows ($18.42 + $0.42 = $18.84) and
    // the caption names the class (caption is unique to the hero tile).
    expect(heroSpendText('\$18.84'), findsOneWidget);
    expect(heroSpendText('\$29.93'), findsNothing);
    expect(find.text('Advisor answers this month.'), findsOneWidget);

    // Saved-answer reuse + model-mix narrow to advisor_qa: the other
    // classes' bars are gone.
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_advisor_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_coach_qa')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_observability_model_mix_advisor_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_model_mix_wf_pl')),
      findsNothing,
    );
    // advisor_qa has no batch-share row -> the panel shows its honest
    // empty state (no phantom zero).
    expect(
      find.byKey(const Key('admin_observability_batch_mode_share_empty')),
      findsOneWidget,
    );
  });

  testWidgets('donut keeps the full breakdown and highlights the selected use '
      'case', (tester) async {
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
      find.byKey(const Key('admin_observability_use_case_selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_advisor_qa')),
    );
    await tester.pumpAndSettle();

    // The donut still renders, and every class's legend row is still there
    // (NOT collapsed to one slice): coach_qa + wf_pl rows survive.
    expect(
      find.byKey(const Key('admin_observability_cost_donut')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cost_legend_coach_qa')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cost_legend_wf_pl')),
      findsOneWidget,
    );
    // The advisor_qa row carries the highlighted key (renamed when chosen).
    expect(
      find.byKey(
        const Key('admin_observability_cost_legend_advisor_qa_highlighted'),
      ),
      findsOneWidget,
    );
    // Sub-caption names the highlighted use case.
    expect(
      find.text('All use cases. Advisor answers highlighted.'),
      findsOneWidget,
    );
  });

  testWidgets('selecting a use case shows the platform-wide note on Customers, '
      'Reliability, Knowledge; All hides it', (tester) async {
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

    // Filter to Workflow planning.
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_wf_pl')),
    );
    await tester.pumpAndSettle();

    Future<void> openTab(String suffix) async {
      await tester.tap(find.byKey(Key('admin_observability_tab_$suffix')));
      await tester.pumpAndSettle();
    }

    await openTab('customers');
    expect(
      find.byKey(const Key('admin_observability_use_case_note_customers')),
      findsOneWidget,
    );
    await openTab('reliability');
    expect(
      find.byKey(const Key('admin_observability_use_case_note_reliability')),
      findsOneWidget,
    );
    await openTab('knowledge');
    expect(
      find.byKey(const Key('admin_observability_use_case_note_knowledge')),
      findsOneWidget,
    );

    // Switch back to All -> the notes disappear.
    await openTab('customers');
    await tester.tap(
      find.byKey(const Key('admin_observability_use_case_selector')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_observability_use_case_all')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_use_case_note_customers')),
      findsNothing,
    );
    await openTab('reliability');
    expect(
      find.byKey(const Key('admin_observability_use_case_note_reliability')),
      findsNothing,
    );
    await openTab('knowledge');
    expect(
      find.byKey(const Key('admin_observability_use_case_note_knowledge')),
      findsNothing,
    );
  });

  // ─── Phase 10a.4 — live sync (Realtime bridge tripwires) ───────────
  testWidgets('live sync section renders one row per Q22 metric and the '
      'worst-wins pill', (tester) async {
    setLargeViewport(tester);
    final observability = InMemoryObservabilityAdminGateway(
      envelope: kObservabilityAdminDemoEnvelope,
    );
    // Seeded: bridge_lag yellow (90s), undelivered green (5), publish
    // error red (10%), notify queue green (5%). Worst-wins → red pill.
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
    expect(
      find.byKey(const Key('admin_observability_bridge_tripwires_section')),
      findsOneWidget,
    );

    // One row per Q22 metric (4 total).
    for (final metric in OutboxTripwireMetric.values) {
      final key = outboxTripwireMetricKey(metric);
      expect(
        find.byKey(Key('admin_observability_bridge_tripwire_row_$key')),
        findsOneWidget,
        reason: 'expected a row for $key in the live sync section',
      );
    }

    // Worst-wins pill is red because publish_error_rate breached red
    // even though bridge_lag is only yellow.
    expect(
      find.byKey(const Key('admin_observability_bridge_tripwire_status_red')),
      findsOneWidget,
    );
  });

  testWidgets('live sync section is hidden when no tripwire gateway is wired', (
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
      find.byKey(const Key('admin_observability_section_live_sync')),
      findsNothing,
    );
  });
}

/// Blocks every fetch on a Completer so a test can assert the in-flight
/// guard. Records the requests it receives.
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

/// Resolves immediately from a seeded envelope while recording the
/// requests, so month-passthrough + re-fetch behaviour can be asserted.
class _RecordingObservabilityGateway implements ObservabilityAdminGateway {
  _RecordingObservabilityGateway({required Map<String, Object?> envelope})
    : _envelope = envelope;

  final Map<String, Object?> _envelope;
  final List<ObservabilityFetchRequest> requests =
      <ObservabilityFetchRequest>[];

  @override
  Future<ObservabilityEnvelope> fetch([
    ObservabilityFetchRequest request = const ObservabilityFetchRequest(),
  ]) async {
    requests.add(request);
    return ObservabilityEnvelope.fromJson(_envelope);
  }
}
