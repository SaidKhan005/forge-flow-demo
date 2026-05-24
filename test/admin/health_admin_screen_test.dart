// Phase 11A.UX.health (Slice 2) — health admin screen widget tests.
//
// Drives `HealthAdminScreen` against an `InMemoryHealthAdminGateway`
// so the click path runs end-to-end without a backend or real proxy.
//
// Slice 1 replaced the cluttered metric tile with a slim card: a
// plain-English name, a single status pill, one line (curated "meaning"
// when good, actionable next step otherwise), and a collapsible Details
// disclosure. A global "Show technical details" switch forces every
// card's Details open. Those behaviours are unchanged and still covered.
//
// Slice 2 adds a lead-with-the-answer summary as the FIRST element of
// the body. It subsumes the old dependencies-unavailable banner, tier-1
// failure banner, and overall-severity chip:
//   * Red "Action needed" when a dependency probe fails, a 503 makes
//     results stale, or a tier-1 metric is failing.
//   * Amber "N things need attention" when only tier-2/3 checks warn.
//   * Green "Everything looks good" otherwise.
// When red or amber it lists every failing/needs-attention check across
// all tabs; tapping a row jumps to that check's tab. Each tab shows a
// count badge for its failing/needs-attention checks, and within a
// section tiles are ordered problems-first (failing, then needs
// attention, then good, then no-data). The third tab is renamed from
// "Ecosystem" to "Behind the scenes".
//
// Slice 3 declutters the top of the screen. The priority key and the
// plain-English definitions move behind a single "What these mean" info
// button in a slim controls row above the tabs (the technical-details
// toggle sits on the right of that row), and the all-green "Service
// checks" dependency strip is hidden unless technical details are on
// (any dependency failure is already called out by the red summary). The
// content stays centered and capped at the shared operator-web width.
//
// Slice 4 drops the verbose hierarchy scope notice (the "Where this
// applies" pill / "Section details" expander / source / effective-value
// block). System health is platform-wide: the proxy `/health` envelope
// carries no operator/tenant/scope identifiers per
// docs/contracts/proxy_health_contract.md, so a per-scope block does not
// belong. When a hierarchy scope is selected, one short muted line
// (key `admin_health_platform_note`) states the checks do not change per
// scope. The scope is still sent to the gateway fetch for request
// shaping; only the on-screen per-scope block is gone.
//
// Coverage:
//   * Initial render is manual-only and does not fetch.
//   * Manual check carries the selected hierarchy scope to the gateway.
//   * Confirmed manual fetch shows three tabs, a green summary, and the
//     "Behind the scenes" label (not "Ecosystem"); opening the legend
//     popover reveals the priority key + definitions; turning technical
//     details on reveals the dependency strip + its probe chips.
//   * The decluttered default hides the legend blocks + dependency strip.
//   * On a wide viewport the body is capped at the shared content width.
//   * The 503 path and a tier-1 metric fail both render the summary's
//     red "Action needed" state.
//   * A tier-2 yellow shows the amber summary, lists the offending
//     check in the triage list, and badges its tab.
//   * Tapping a triage row jumps to that check's tab.
//   * Problems-first ordering puts a failing tile before a green tile.
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
  /// summary + dependencies strip + tabs + scrollable tab body to
  /// coexist; bump the test viewport so the layout matches production.
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

  /// The plain text shown by the summary headline.
  String summaryHeadline(WidgetTester tester) =>
      textByKey(tester, 'admin_health_summary_headline');

  /// The index of the currently selected health tab, read straight off
  /// the screen's own [TabController] via the keyed [TabBar].
  int selectedTabIndex(WidgetTester tester) {
    final bar = tester.widget<TabBar>(
      find.byKey(const Key('admin_health_tabs')),
    );
    return bar.controller!.index;
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
    expect(find.byKey(const Key('admin_health_summary')), findsNothing);
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

    // The verbose hierarchy scope notice was removed (System health is
    // platform-wide: the /health envelope carries no scope identifiers per
    // docs/contracts/proxy_health_contract.md). One short muted platform
    // note renders in its place; the old notice is gone from the tree.
    expect(
      find.byKey(const Key('admin_health_scope_notice')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_health_platform_note')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_health_confirm_run')));
    await tester.pump();

    // Scope still flows to the gateway fetch (request shaping is unchanged);
    // only the on-screen per-scope block was dropped.
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
    // "Ecosystem" is gone from the screen entirely.
    expect(find.text('Ecosystem'), findsNothing);

    // The legend + definitions now live behind a single "What these mean"
    // info button so the default face stays calm. They are not visible
    // until the popover is opened.
    expect(find.byKey(const Key('admin_health_legend_info')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_priority_key')), findsNothing);
    expect(
      find.byKey(const Key('admin_health_plain_english_definitions')),
      findsNothing,
    );

    // Open the popover; both legend blocks (and their text) are now found.
    await tester.tap(find.byKey(const Key('admin_health_legend_info')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_health_priority_key')), findsOneWidget);
    expect(
      find.byKey(const Key('admin_health_plain_english_definitions')),
      findsOneWidget,
    );
    expect(find.text('Critical'), findsOneWidget);
    expect(find.text('Important'), findsWidgets);
    expect(find.text('Info'), findsWidgets);
    expect(
      find.textContaining('Advisor data', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining('App service', findRichText: true),
      findsWidgets,
    );
    // The third tab + its definitions entry both read "Behind the scenes".
    expect(
      find.textContaining('Behind the scenes', findRichText: true),
      findsWidgets,
    );
    expect(
      find.textContaining(
        'Read-only pings that confirm each required service answered successfully.',
        findRichText: true,
      ),
      findsOneWidget,
    );

    // Dismiss the popover (tap the trigger again to toggle it closed).
    await tester.tap(find.byKey(const Key('admin_health_legend_info')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_health_priority_key')), findsNothing);

    // The global tech-details switch sits in the controls row above the
    // tabs. The "Service checks" dependency strip is hidden until it is on.
    expect(find.byKey(const Key('admin_health_tech_toggle')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_dependencies')), findsNothing);

    await showTechnicalDetails(tester);
    expect(find.byKey(const Key('admin_health_dependencies')), findsOneWidget);
    expect(find.textContaining('Service checks'), findsWidgets);
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

    // A green envelope leads with the calm "Everything looks good"
    // summary (the old banners / overall chip are gone).
    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    expect(summaryHeadline(tester), equals('Everything looks good'));
    expect(
      find.textContaining('All 3 checks passed.'),
      findsOneWidget,
    );
  });

  testWidgets('decluttered default hides the legend and dependency strip', (
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

    // No info-button tap, tech toggle off: the priority key, the
    // plain-English definitions, and the dependency strip are all absent
    // from the tree so the default face stays uncluttered.
    expect(find.byKey(const Key('admin_health_priority_key')), findsNothing);
    expect(
      find.byKey(const Key('admin_health_plain_english_definitions')),
      findsNothing,
    );
    expect(find.byKey(const Key('admin_health_dependencies')), findsNothing);
    // But the entry points to reveal them are present.
    expect(find.byKey(const Key('admin_health_legend_info')), findsOneWidget);
    expect(find.byKey(const Key('admin_health_tech_toggle')), findsOneWidget);
  });

  testWidgets('content is capped at the shared max width on a wide viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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

    // The tabbed body is centered and capped at the shared operator-web
    // content width (1120) even though the viewport is 1600 wide, so the
    // tabs do not span edge-to-edge.
    final tabsWidth = tester.getSize(
      find.byKey(const Key('admin_health_tabs')),
    ).width;
    expect(tester.takeException(), isNull);
    expect(tabsWidth, lessThanOrEqualTo(1121));
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
    // 503 → the summary leads with the red "Action needed" verdict.
    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    expect(summaryHeadline(tester), startsWith('Action needed'));
  });

  testWidgets('tier-1 metric failure surfaces the red Action needed summary', (
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

    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    expect(
      summaryHeadline(tester),
      equals('Action needed: 1 critical check failing'),
    );
    // The failing tier-1 check is listed in the triage list (it lives in
    // the "Behind the scenes" tab, not the default one).
    expect(
      find.byKey(const Key('admin_health_attn_migration_apply_drift_count')),
      findsOneWidget,
    );
  });

  testWidgets('HTTP 503 path renders the red Action needed summary', (
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

    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    // No tier-1 metric is failing on a green envelope, so the 503
    // headline names the unavailable service rather than a count.
    expect(
      summaryHeadline(tester),
      equals('Action needed: a required service is unavailable'),
    );
  });

  testWidgets('tier-2 yellow shows an amber summary, triage row, and a badge', (
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

    // Amber state: a count + "needs attention", never "Action needed".
    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    expect(summaryHeadline(tester), isNot(startsWith('Action needed')));
    expect(summaryHeadline(tester), equals('1 thing needs attention'));

    // The offending check is listed in the cross-tab triage list.
    expect(
      find.byKey(const Key('admin_health_attn_rollup_freshness_per_grain')),
      findsOneWidget,
    );

    // Its tab (Advisor data / retrieval, index 0) shows a "1" count badge.
    expect(
      find.descendant(
        of: find.byKey(const Key('admin_health_tab_retrieval')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // The Retrieval tab is selected by default; the rollup card status
    // pill reads "Needs attention".
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

  testWidgets('tapping a triage row jumps to that check\'s tab', (
    tester,
  ) async {
    setLargeViewport(tester);
    // Force a circuit-breaker fail. That metric lives in the App service
    // (proxy) tab — index 1 — not the default Retrieval tab.
    final json = _greenEnvelope();
    (json['metrics']!
        as Map<String, Object?>)['circuit_breaker_anthropic_state'] =
        <String, Object?>{
          'status': 'red',
          'value': 'open',
          'unit': 'state',
          'description': 'breaker open',
          'owner': 'B42',
          'observed_at': '2026-05-02T12:00:00.000Z',
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

    // Default selection is the first (Retrieval) tab.
    expect(selectedTabIndex(tester), equals(0));

    // The breaker is failing → it appears in the triage list. Tap it.
    final row = find.byKey(
      const Key('admin_health_attn_circuit_breaker_anthropic_state'),
    );
    expect(row, findsOneWidget);
    await tester.tap(row);
    await tester.pumpAndSettle();

    // The screen animated to the App service tab (index 1).
    expect(selectedTabIndex(tester), equals(1));
  });

  testWidgets('problems-first ordering puts a failing tile before a good one', (
    tester,
  ) async {
    setLargeViewport(tester);
    // The "Advisor content freshness" section (Retrieval tab) holds two
    // tiles: rollup_freshness_per_grain (authored first) and
    // rollup_refresh_lag_seconds (authored second). Make the freshness
    // tile good and the refresh-lag tile fail; the failing tile must
    // sort ahead of the good one even though it was authored second.
    final json = _greenEnvelope();
    (json['metrics']! as Map<String, Object?>)['rollup_refresh_lag_seconds'] =
        <String, Object?>{
          'status': 'red',
          'value': 99999,
          'unit': 'seconds',
          'description': 'refresh lag forced fail',
          'owner': 'B45',
          'observed_at': '2026-05-02T12:00:00.000Z',
          'thresholds': <String, Object?>{'yellow': 3600, 'red': 14400},
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

    final failing = tester.getTopLeft(
      find.byKey(const Key('admin_health_tile_rollup_refresh_lag_seconds')),
    );
    final good = tester.getTopLeft(
      find.byKey(const Key('admin_health_tile_rollup_freshness_per_grain')),
    );
    // Reading order: above, or to the left on the same row.
    final failingPrecedes =
        failing.dy < good.dy ||
        (failing.dy == good.dy && failing.dx < good.dx);
    expect(
      failingPrecedes,
      isTrue,
      reason:
          'failing tile should render before the good tile within the '
          'section (failing=$failing, good=$good)',
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

    // A green envelope is calm: the summary is not in the red state.
    expect(find.byKey(const Key('admin_health_summary')), findsOneWidget);
    expect(summaryHeadline(tester), isNot(startsWith('Action needed')));

    // Now seed an envelope with a tier-1 fail and confirm another manual
    // check. The summary should escalate to red after the fetch.
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

    expect(summaryHeadline(tester), startsWith('Action needed'));
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
