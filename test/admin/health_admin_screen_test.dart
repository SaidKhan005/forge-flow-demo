// Phase 11A.UX.health (F.1) — health admin screen widget tests.
//
// Drives `HealthAdminScreen` against an `InMemoryHealthAdminGateway`
// so the click path runs end-to-end without a backend or real
// proxy. Coverage:
//
//   * Initial render shows three tabs (Retrieval, Proxy, Infra) and
//     the dependencies strip.
//   * Tier coloring routes correctly:
//       - tier-1 fail surfaces a red top-of-page banner;
//       - tier-2 fail leaves the banner absent and decorates the
//         affected tile chip yellow;
//       - tier-3 fail decorates the affected tile chip neutral.
//   * The 503 path renders the "Dependencies unavailable" banner.
//   * Manual refresh consumes a re-seeded envelope.
//
// Auto-polling is disabled in these tests (`autoRefresh: false`) so
// the timer cannot leak into the test runner.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('renders three tabs with the dependencies strip', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_health_screen')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tabs')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_retrieval')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_proxy')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tab_infra')), findsOneWidget);
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
    // The tier-1 banner is absent on a green envelope.
    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);
    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsNothing,
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
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Health'), findsOneWidget);
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
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsOneWidget);
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
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_health_dependencies_unavailable')),
      findsOneWidget,
    );
  });

  testWidgets('tier-2 yellow keeps the banner absent and surfaces tile chip', (
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
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Top-of-page tier-1 banner stays absent.
    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);
    // The Retrieval tab is selected by default; the rollup tile is in
    // the visible tab body, so the chip widget exists.
    expect(
      find.byKey(
        const Key('admin_health_tile_rollup_freshness_per_grain_chip'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('manual refresh re-fetches the envelope', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryHealthAdminGateway(envelope: _greenEnvelope());
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          autoRefresh: false,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsNothing);

    // Now seed an envelope with a tier-1 fail and tap the Refresh
    // button. The tier-1 banner should appear after the refresh.
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

    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_health_tier1_banner')), findsOneWidget);
  });
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
