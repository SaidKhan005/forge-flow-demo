// Phase 11A.UX.health (Slice 1) — health admin screen widget tests.
//
// Drives `HealthAdminScreen` against an `InMemoryHealthAdminGateway`
// so the click path runs end-to-end without a backend or real
// proxy. Slice 1 replaced the cluttered metric tile with a slim card:
// a plain-English name, a single status pill, one line (curated
// "meaning" when good, actionable next step otherwise), and a
// collapsible Details disclosure. A global "Show technical details"
// switch forces every card's Details open. Everything else on the
// screen (manual run/confirm, header, scope notice, banners, priority
// key, definitions card, dependencies strip, overall chip, three tabs)
// is unchanged this slice and is still covered here.
//
// Coverage:
//   * Initial render is manual-only and does not fetch.
//   * Manual check carries the selected hierarchy scope to the gateway.
//   * Confirmed manual fetch shows three tabs + the dependencies strip.
//   * The 503 path renders the "Dependencies unavailable" banner.
//   * A tier-1 metric fail still surfaces the red top-of-page banner.
//   * Manual refresh re-fetches; no auto-poll / no stacking in flight.
//   * HONESTY: an `unknown` (producer-timeout) metric and a metric
//     missing from the envelope both show the "No data" status pill
//     (never "Good"); the card line still shows the actionable next
//     step. Flipping the global tech-details switch reveals the
//     Source / Owner / Measured rows.
//   * A compact viewport still renders without exceptions.
//
// Health checks are manual-only, so tests explicitly confirm the
// read-only diagnostic before expecting an envelope to render.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/health_admin_models.dart';
import 'package:forge_and_flow/admin/screens/health_admin_screen.dart';
import 'package:forge_and_flow/admin/services/health_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  /// The Health screen is sized for a desktop admin console viewport.
  /// Default Flutter test viewport (800x600) is too small for the
  /// tier-1 banner + dependencies strip + severity chip + tabs +
  /// scrollable tab body to coexist; bump the test viewport so the
  /// layout matches production.
  void setLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> runHealthCheck(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_health_confirm_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_health_confirm_run')));
    await tester.pumpAndSettle();
  }

  /// Reads the visible text of a card sub-element by key. The Details
  /// rows (Measured / Source / Owner) only mount when their card's
  /// Details disclosure is expanded, so callers must flip the global
  /// tech-details switch (or expand the card) first.
  String textByKey(WidgetTester tester, String key) {
    return tester.widget<Text>(find.byKey(Key(key))).data!;
  }

  Future<void> showTechnicalDetails(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('admin_health_tech_toggle')));
    await tester.pumpAndSettle();
  }

  testWidgets('initial render waits for a confirmed manual check', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _BlockingHealthGateway();
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.fetchCount, equals(0));
    expect(find.byKey(const Key('admin_health_manual_prompt')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tabs')), findsNothing);
  });

  testWidgets('manual check carries selected hierarchy scope to gateway', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _BlockingHealthGateway();
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
            operatorId: 'op-a',
            orgUnitId: 'ou-a',
            operatorName: 'Demo Diner',
            orgUnitName: 'Downtown',
          ),
          scopeLocationIds: const <String>{'loc-a', 'loc-b'},
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Demo Diner / Downtown'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_health_confirm_run')));
    await tester.pump();

    expect(gateway.fetchCount, equals(1));
    expect(gateway.requests.single.operatorId, equals('op-a'));
    expect(gateway.requests.single.locationId, isNull);
    expect(
      gateway.requests.single.locationIds,
      equals(<String>{'loc-a', 'loc-b'}),
    );
  });

  testWidgets('confirmed manual check renders three tabs with dependencies', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    expect(find.byKey(const Key('admin_health_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tabs')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_retrieval')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_proxy')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_infra')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_priority_key')), findsOneWidget);
    expect(find.text('Critical'), findsOneWidget);
    expect(find.text('Important'), findsWidgets);
    expect(find.text('Info'), findsWidgets);
    expect(
      find.byKey(const Key('admin_health_plain_english_definitions')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Advisor data', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('App service', findRichText: true),
      findsWidgets,
    );
    expect(find.textContaining('Ecosystem', findRichText: true), findsWidgets);
    expect(find.textContaining('Service checks'), findsWidgets);
    expect(
      find.textContaining(
        'Read-only pings that confirm each required service answered successfully.',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_health_dependencies')), findsOneWidget);
    // All three dependency probes are rendered.
    expect(
      find.byKey(const Key('admin_health_dependency_postgres')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_health_dependency_age')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_health_dependency_pgvector')),
      findsOneWidget,
    );
    // The new global tech-details switch sits above the tabs.
    expect(
      find.byKey(const Key('admin_health_tech_toggle')),
      findsOneWidget,
    );
    // The tier-1 banner is absent on a green envelope.
    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);
    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsNothing,
    );
  });

  testWidgets('green metric card shows a Good status pill and a meaning line', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    // The Retrieval tab is selected by default; rollup freshness is a
    // green tile there.
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_status'),
      equals('Good'),
    );
    // Curated meaning line on the card face (not the next-step text).
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_line'),
      equals(
        "Whether the advisor's data is current across all time periods.",
      ),
    );
  });

  testWidgets('compact viewport keeps health status chrome readable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(380, 920);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final gateway = InMemoryHealthAdminGateway(
      envelope: _greenEnvelope(),
      dependenciesUnavailable: true,
    );
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('System health'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_health_refresh_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('tier-1 metric failure surfaces the red top-of-page banner', (
    tester,
  ) async {
    setLargeViewport(tester);
    final json = _greenEnvelope();
    (json['metrics']! as Map<String, Object?>)['migration_apply_drift_count'] =
        <String, Object?>{
          'status': 'red',
          'value': 4,
          'unit': 'count',
          'description': 'tier-1 forced fail',
          'owner': 'B42',
          'observed_at': '2026-05-02T12:00:00.000Z',
          'thresholds': <String, Object?>{'red': 1},
          'metadata': <String, Object?>{'tier': 1},
        };
    final gateway = InMemoryHealthAdminGateway(envelope: json);
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsOneWidget);
    expect(
      find.text(
        'Critical checks are failing. Fix the cause before relying on this environment.',
      ),
      findsOneWidget,
    );
    // The 503 banner stays absent — tier-1 failure is metric-level,
    // not dependency-level.
    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsNothing,
    );
  });

  testWidgets('HTTP 503 path renders the dependencies-unavailable banner', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(
      envelope: _greenEnvelope(),
      dependenciesUnavailable: true,
    );
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('tier-2 yellow keeps the banner absent and surfaces a pill', (
    tester,
  ) async {
    setLargeViewport(tester);
    final json = _greenEnvelope();
    (json['metrics']! as Map<String, Object?>)['rollup_freshness_per_grain'] =
        <String, Object?>{
          'status': 'yellow',
          'value': 4218,
          'unit': 'seconds',
          'description': 'tier-2 forced fail',
          'owner': 'B45',
          'observed_at': '2026-05-02T12:00:00.000Z',
          'thresholds': <String, Object?>{'yellow': 3600, 'red': 21600},
          'metadata': <String, Object?>{'tier': 2},
        };
    final gateway = InMemoryHealthAdminGateway(envelope: json);
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    // Top-of-page tier-1 banner stays absent.
    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);
    // The Retrieval tab is selected by default; the rollup card is in
    // the visible tab body. Its status pill reads "Needs attention".
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_status'),
      equals('Needs attention'),
    );
    // The face line is the actionable next step, not the meaning.
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_line'),
      startsWith('Next step:'),
    );
  });

  testWidgets('unknown producer warning shows No data pill and a next step', (
    tester,
  ) async {
    setLargeViewport(tester);
    final json = _greenEnvelope();
    (json['metrics']! as Map<String, Object?>)['rollup_freshness_per_grain'] =
        <String, Object?>{
          'status': 'unknown',
          'value': null,
          'unit': 'seconds',
          'description': 'rollup freshness query timed out',
          'source': 'aggregation_state',
          'owner': 'B45',
          'observed_at': '2026-05-02T12:00:00.000Z',
          'thresholds': <String, Object?>{'yellow': 3600, 'red': 21600},
          'metadata': <String, Object?>{
            'tier': 2,
            'warning': 'producer_timeout',
            'budget_ms': 300,
          },
        };
    final gateway = InMemoryHealthAdminGateway(envelope: json);
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    // HONESTY: an unknown producer reads as "No data", never "Good".
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_status'),
      equals('No data'),
    );
    // The card line still shows the actionable next step.
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_line'),
      equals(
        'Next step: The health producer timed out. Retry once; if it repeats, check the producer budget and proxy logs.',
      ),
    );

    // Details (Source / Owner / Measured) only mount once the global
    // tech-details switch is on.
    await showTechnicalDetails(tester);
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_source'),
      equals('aggregation_state'),
    );
    expect(
      textByKey(tester, 'admin_health_tile_rollup_freshness_per_grain_owner'),
      equals('B45'),
    );
    // No value present → the empty-state sentinel, never "0".
    expect(
      textByKey(
        tester,
        'admin_health_tile_rollup_freshness_per_grain_measured',
      ),
      equals('—'),
    );
  });

  testWidgets('missing producer signal is not presented as healthy', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    // graph_traversal_latency_ms is in the (default) Retrieval tab but
    // absent from the green envelope → it must read "No data".
    expect(
      textByKey(tester, 'admin_health_tile_graph_traversal_latency_ms_status'),
      equals('No data'),
    );
    expect(
      textByKey(tester, 'admin_health_tile_graph_traversal_latency_ms_line'),
      equals(
        'Next step: This signal was missing from the health response. Check the proxy health producer registry before relying on it.',
      ),
    );

    // Reveal Details; the missing-signal source fallback shows.
    await showTechnicalDetails(tester);
    expect(
      textByKey(tester, 'admin_health_tile_graph_traversal_latency_ms_source'),
      equals('/health did not return this signal'),
    );
    expect(
      textByKey(
        tester,
        'admin_health_tile_graph_traversal_latency_ms_measured',
      ),
      equals('—'),
    );
  });

  testWidgets('manual refresh re-fetches the envelope', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await runHealthCheck(tester);

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);

    // Now seed an envelope with a tier-1 fail and confirm another
    // manual check. The tier-1 banner should appear after the fetch.
    final json = _greenEnvelope();
    (json['metrics']! as Map<String, Object?>)['azure_extensions_present'] =
        <String, Object?>{
          'status': 'red',
          'value': 5,
          'unit': 'count',
          'description': 'forced fail (missing extension)',
          'owner': 'B42',
          'observed_at': '2026-05-02T12:01:00.000Z',
          'metadata': <String, Object?>{'tier': 1},
        };
    gateway.setEnvelope(json);

    await runHealthCheck(tester);

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsOneWidget);
  });

  testWidgets('manual health check does not auto-poll or stack in flight', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = _BlockingHealthGateway();
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateway.fetchCount, equals(0));
    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_health_confirm_run')));
    await tester.pump();

    expect(
      gateway.fetchCount,
      equals(1),
      reason: 'manual /health calls must not stack while one is in flight',
    );
    await tester.pump(const Duration(milliseconds: 55));
    expect(gateway.fetchCount, equals(1));

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    gateway.completeOldest(HealthEnvelope.fromJson(_greenEnvelope()));
    await tester.pump();
  });
}

class _BlockingHealthGateway implements HealthAdminGateway {
  int fetchCount = 0;
  final List<Completer<HealthEnvelope>> _pending =
      <Completer<HealthEnvelope>>[];
  final List<HealthAdminFetchRequest> requests = <HealthAdminFetchRequest>[];

  @override
  Future<HealthEnvelope> fetch([
    HealthAdminFetchRequest request = const HealthAdminFetchRequest(),
  ]) {
    fetchCount += 1;
    requests.add(request);
    final completer = Completer<HealthEnvelope>();
    _pending.add(completer);
    return completer.future;
  }

  void completeOldest(HealthEnvelope envelope) {
    if (_pending.isEmpty) return;
    _pending.removeAt(0).complete(envelope);
  }
}

Map<String, Object?> _greenEnvelope() => <String, Object?>{
  'status': 'ok',
  'severity': 'green',
  'contract': 'proxy_health.v1',
  'schema_version': 1,
  'checked_at': '2026-05-02T12:00:00.000Z',
  'dependencies': <String, Object?>{
    'postgres': <String, Object?>{
      'status': 'green',
      'check': 'select_1',
      'legacy_key': 'postgres_select_1',
    },
    'age': <String, Object?>{
      'status': 'green',
      'check': 'cypher_match',
      'legacy_key': 'age_cypher_match',
    },
    'pgvector': <String, Object?>{
      'status': 'green',
      'check': 'similarity',
      'legacy_key': 'pgvector_similarity',
    },
  },
  'surfaces': <String, Object?>{},
  'metrics': <String, Object?>{
    'audit_chain_lag_seconds': <String, Object?>{
      'status': 'green',
      'value': 12,
      'unit': 'seconds',
      'description': 'audit lag',
      'owner': 'B37/B43',
      'observed_at': '2026-05-02T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 1800, 'red': 21600},
      'metadata': <String, Object?>{'tier': 1},
    },
    'rollup_freshness_per_grain': <String, Object?>{
      'status': 'green',
      'value': 60,
      'unit': 'seconds',
      'description': 'rollup',
      'owner': 'B45',
      'observed_at': '2026-05-02T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 3600, 'red': 21600},
      'metadata': <String, Object?>{'tier': 2},
    },
    'prompt_cache_hit_rate': <String, Object?>{
      'status': 'green',
      'value': 0.62,
      'unit': 'ratio',
      'description': 'cache hit',
      'owner': 'B42',
      'observed_at': '2026-05-02T12:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.30, 'red': 0.10},
      'metadata': <String, Object?>{'tier': 3},
    },
  },
  'warnings': <Object?>[],
};
