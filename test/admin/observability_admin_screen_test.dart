// Phase 11A.6 — Observability admin screen widget tests.
//
// Drives `ObservabilityAdminScreen` against an
// `InMemoryObservabilityAdminGateway` so the click path runs end-to-
// end without a backend or real proxy. Coverage:
//
//   * Initial render is manual-only and does not fetch.
//   * Confirmed manual fetch shows all six tabs and the as-of strip.
//   * Cost telemetry rows render across the full axis tuple
//     (operator / location / staff / workflow / usage_class /
//     query_class) so phase_11A lines 356-359 are exercised.
//   * Operator dormancy flags 30+ days silent.
//   * Underwater margin row surfaces the negative chip.
//   * Cap event stream renders the rows.
//   * Graph observability renders approved / inferred / rejected /
//     isolated counts plus projection age and traversal p95.
//   * Manual refresh re-fetches the envelope (no auto-poll).
//   * Stacked in-flight refresh requests do not double-fire.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  /// Same large-viewport setup as the health screen test — six tabs +
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
    expect(find.textContaining('system metrics'), findsNothing);
    expect(find.byKey(const Key('admin_observability_tabs')), findsNothing);
  });

  testWidgets('confirmed manual fetch renders six tabs + as-of strip', (
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
    expect(
      find.byKey(const Key('admin_observability_tab_cost')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_tab_top')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_tab_operators')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_tab_cap_events')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_tab_graph')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_tab_cloud_run')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_as_of_strip')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_metrics_key')),
      findsOneWidget,
    );
    expect(find.text('Metrics key'), findsOneWidget);
    expect(find.textContaining('Losing money'), findsWidgets);
    expect(find.text('Limit events'), findsWidgets);
    expect(find.textContaining('reached a usage limit'), findsOneWidget);
  });

  testWidgets('cost telemetry rows render across the full axis tuple', (
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

    // Cost tab is selected by default; backend request group IDs stay
    // inside the advanced disclosure.
    expect(
      find.byKey(const Key('admin_observability_request_group_advanced')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_request_group_key')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('admin_observability_request_group_advanced')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_observability_request_group_key')),
      findsOneWidget,
    );
    expect(find.text('Advisor answers'), findsWidgets);
    // Per-(operator, location, query_class) row.
    expect(
      find.byKey(
        const Key(
          'admin_observability_cost_row_'
          '00000000-0000-4000-8000-000000000001_'
          '00000000-0000-4000-8000-0000000000a1_none_none_advisor_qa',
        ),
      ),
      findsOneWidget,
    );
    // Per-(operator, location, staff, query_class) row exercises the
    // staff axis from phase_11A line 356.
    expect(
      find.byKey(
        const Key(
          'admin_observability_cost_row_'
          '00000000-0000-4000-8000-000000000001_'
          '00000000-0000-4000-8000-0000000000a1_'
          '00000000-0000-4000-8000-0000000000s1_none_coach_qa',
        ),
      ),
      findsOneWidget,
    );
    // Per-(operator, location, workflow, query_class) row exercises
    // the workflow axis from phase_11A line 357.
    expect(
      find.byKey(
        const Key(
          'admin_observability_cost_row_'
          '00000000-0000-4000-8000-000000000001_'
          '00000000-0000-4000-8000-0000000000a1_none_'
          '00000000-0000-4000-8000-0000000000w1_wf_pl',
        ),
      ),
      findsOneWidget,
    );
    // Per-query_class cache hit rate / model mix / batch share render.
    expect(
      find.byKey(const Key('admin_observability_cache_hit_rate_advisor_qa')),
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
  });

  testWidgets('column labels expose plain-language tooltip help across tabs', (
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

    expect(
      find.byTooltip(
        'Operator, location, staff, and workflow scope for this cost row.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('admin_observability_tab_top')));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip(
        'Whether this row is an operator, staff member, or workflow.',
      ),
      findsWidgets,
    );

    await tester.tap(
      find.byKey(const Key('admin_observability_tab_operators')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip(
        'Whether the operator has been active recently or needs follow-up.',
      ),
      findsOneWidget,
    );
    expect(
      find.byTooltip('Plan revenue minus estimated AI cost for this window.'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin_observability_tab_cap_events')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Operator, use case, and time that hit a usage limit.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('admin_observability_tab_graph')));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip(
        'Knowledge items that are not connected to a confirmed relationship yet.',
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin_observability_tab_cloud_run')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip(
        'Readable service area being measured. Route paths are in advanced details.',
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('Current active hosting instances.'), findsOneWidget);
  });

  testWidgets('operator dormancy flags 30+ days silent', (tester) async {
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
      find.byKey(const Key('admin_observability_tab_operators')),
    );
    await tester.pumpAndSettle();

    // Demo Diner Co. is active (not dormant).
    expect(
      find.byKey(
        const Key(
          'admin_observability_dormancy_row_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_observability_dormancy_flag_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsNothing,
    );
    // Sunset Cafe Group last_active_at = 2026-04-01; as_of =
    // 2026-05-03 -> 32 days silent -> inactive chip rendered.
    expect(
      find.byKey(
        const Key(
          'admin_observability_dormancy_flag_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('null last_active_at renders as never-active dormant '
      '(no silent collapse to as_of)', (tester) async {
    setLargeViewport(tester);
    // Build an envelope where one operator has a missing
    // last_active_at — the parser must NOT default it to as_of, and
    // the dormancy flag must trip because never-active is the
    // strongest skip-precompute signal.
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'dormancy': <Map<String, Object?>>[
        <String, Object?>{
          'operator_id': '00000000-0000-4000-8000-000000000099',
          'business_name': 'Never-Active Cafe',
          'subscription_tier': 'pilot',
          // last_active_at intentionally absent.
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
      find.byKey(const Key('admin_observability_tab_operators')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key(
          'admin_observability_dormancy_flag_'
          '00000000-0000-4000-8000-000000000099',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('never active - inactive'), findsOneWidget);
  });

  testWidgets('cost telemetry truncation hint surfaces when capped', (
    tester,
  ) async {
    setLargeViewport(tester);
    // Seed > kObservabilityCostTelemetryLimit rows so the in-memory
    // gateway clamps and the truncated meta flag is true.
    final overflowRows = <Map<String, Object?>>[
      for (var i = 0; i < kObservabilityCostTelemetryLimit + 5; i++)
        <String, Object?>{
          'operator_id':
              '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
          'location_id': null,
          'staff_id': null,
          'workflow_id': null,
          'usage_class': 'advisor_qa',
          'query_class': 'advisor_qa',
          'total_usd': 0.10 + i * 0.01,
          'request_count': 10 + i,
        },
    ];
    final envelope = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'cost_telemetry': overflowRows,
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
      find.byKey(const Key('admin_observability_cost_truncated')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('admin_observability_request_group_advanced')),
    );
    await tester.pumpAndSettle();
    // Filter chip and Apply button are present.
    expect(
      find.byKey(const Key('admin_observability_cost_query_class_filter')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('admin_observability_cost_query_class_filter_apply'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('applying a query_class filter narrows the cost table and '
      'echoes the active filter chip', (tester) async {
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

    // Default state: no active filter chip.
    expect(
      find.byKey(const Key('admin_observability_cost_query_class_filter_chip')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('admin_observability_request_group_advanced')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_observability_cost_query_class_filter')),
      'wf_pl',
    );
    await tester.tap(
      find.byKey(
        const Key('admin_observability_cost_query_class_filter_apply'),
      ),
    );
    await tester.pumpAndSettle();

    // Active filter chip echoes the current scope.
    expect(
      find.byKey(const Key('admin_observability_cost_query_class_filter_chip')),
      findsOneWidget,
    );
    // After filtering to wf_pl, only the workflow row from the
    // demo seed remains in the cost table.
    expect(
      find.byKey(
        const Key(
          'admin_observability_cost_row_'
          '00000000-0000-4000-8000-000000000001_'
          '00000000-0000-4000-8000-0000000000a1_none_'
          '00000000-0000-4000-8000-0000000000w1_wf_pl',
        ),
      ),
      findsOneWidget,
    );
    // The advisor_qa rows are gone after filtering.
    expect(
      find.byKey(
        const Key(
          'admin_observability_cost_row_'
          '00000000-0000-4000-8000-000000000001_'
          '00000000-0000-4000-8000-0000000000a1_none_none_advisor_qa',
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('underwater margin row surfaces the negative chip', (
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
      find.byKey(const Key('admin_observability_tab_operators')),
    );
    await tester.pumpAndSettle();

    // Demo Diner Co. revenue \$199 - cost \$29.51 = +\$169.49 → not
    // underwater.
    expect(
      find.byKey(
        const Key(
          'admin_observability_margin_underwater_'
          '00000000-0000-4000-8000-000000000001',
        ),
      ),
      findsNothing,
    );
    // Sunset Cafe Group revenue \$0 - cost \$0.42 → underwater.
    expect(
      find.byKey(
        const Key(
          'admin_observability_margin_underwater_'
          '00000000-0000-4000-8000-000000000002',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('cap event stream renders rows on the cap events tab', (
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
      find.byKey(const Key('admin_observability_tab_cap_events')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key(
          'admin_observability_cap_event_'
          '00000000-0000-4000-8000-0000000000e1',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key(
          'admin_observability_cap_event_'
          '00000000-0000-4000-8000-0000000000e2',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('graph observability renders all phase_11A counts', (
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
    await tester.tap(find.byKey(const Key('admin_observability_tab_graph')));
    await tester.pumpAndSettle();

    // Phase_11A lines 351-353 require approved/inferred-approved/
    // rejected/isolated counts + projection age + traversal p95.
    expect(
      find.byKey(const Key('admin_observability_graph_approved_nodes')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_approved_edges')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_inferred_approved')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_rejected')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_graph_isolated_nodes')),
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

  testWidgets('cloud run + route latency render on the cloud run tab', (
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
      find.byKey(const Key('admin_observability_tab_cloud_run')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(
        const Key('admin_observability_route_latency__v1_advisor_answer'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cloud_run_advisor-proxy')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_cloud_run_admin-proxy')),
      findsOneWidget,
    );
    expect(find.text('/v1/advisor/answer'), findsNothing);
    expect(find.text('advisor-proxy-00037-n1k'), findsNothing);

    await tester.tap(
      find.byKey(const Key('admin_observability_route_latency_advanced')),
    );
    await tester.pumpAndSettle();
    expect(find.text('/v1/advisor/answer'), findsOneWidget);

    final hostingAdvanced = find.byKey(
      const Key('admin_observability_hosting_advanced'),
    );
    await tester.ensureVisible(hostingAdvanced);
    await tester.pumpAndSettle();
    await tester.tap(hostingAdvanced);
    await tester.pumpAndSettle();
    expect(find.textContaining('advisor-proxy-00037-n1k'), findsOneWidget);
  });

  testWidgets('top-N renders 1d / 7d / 30d sections', (tester) async {
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
    await tester.tap(find.byKey(const Key('admin_observability_tab_top')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_observability_section_top_1d')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_top_7d')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_observability_section_top_30d')),
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

    // Default demo envelope has 2 cap events.
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_cap_events')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const Key(
          'admin_observability_cap_event_'
          '00000000-0000-4000-8000-0000000000e1',
        ),
      ),
      findsOneWidget,
    );

    // Re-seed with an envelope that has zero cap events; manual
    // refresh should consume the new envelope.
    final reseeded = <String, Object?>{
      ...kObservabilityAdminDemoEnvelope,
      'cap_events': const <Map<String, Object?>>[],
    };
    gateway.setEnvelope(reseeded);
    await runCheck(tester);
    await tester.tap(
      find.byKey(const Key('admin_observability_tab_cap_events')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_observability_cap_events_empty')),
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

  // ─── Phase 10a.4 — Realtime bridge tripwires section ───────────────
  testWidgets(
    'tripwire section renders one row per Q22 metric and the worst-wins pill',
    (tester) async {
      setLargeViewport(tester);
      final observability = InMemoryObservabilityAdminGateway(
        envelope: kObservabilityAdminDemoEnvelope,
      );
      // Seeded: bridge_lag yellow (90s), undelivered green (5),
      // publish error red (10%), notify queue green (5%). Worst-wins
      // → red header pill.
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

      // Section is mounted above the tab bar.
      expect(
        find.byKey(const Key('admin_observability_bridge_tripwires_section')),
        findsOneWidget,
      );
      expect(find.text('Realtime bridge tripwires'), findsOneWidget);

      // One row per Q22 metric (4 total).
      for (final metric in OutboxTripwireMetric.values) {
        final key = outboxTripwireMetricKey(metric);
        expect(
          find.byKey(Key('admin_observability_bridge_tripwire_row_$key')),
          findsOneWidget,
          reason: 'expected a row for $key in the bridge tripwires section',
        );
      }

      // Worst-wins header pill is red because publish_error_rate
      // breached red even though bridge_lag is only yellow.
      expect(
        find.byKey(const Key('admin_observability_bridge_tripwire_status_red')),
        findsOneWidget,
      );
    },
  );
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
