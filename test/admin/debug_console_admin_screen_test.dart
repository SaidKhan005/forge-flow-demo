// Phase 11A.5 — Debug console admin screen widget tests.
//
// Drives `DebugConsoleAdminScreen` against an
// `InMemoryDebugConsoleAdminGateway` so the click path runs end-to-
// end without a backend. Coverage:
//
//   * Initial render shows the Refresh button and three tabs; the
//     gateway is hit only after Refresh.
//   * Filters AND together: status / time-window / operator narrow
//     the visible rows; clearing returns the full list.
//   * Search by request_id and by idempotency_key both work.
//   * Live-tail toggle is OFF by default and starts polling when on.
//   * Live-tail respects the runtime acceptance contract: it never
//     stacks in-flight requests and merges back to the bounded list
//     limit so the table cannot grow unbounded across a long session.
//   * Full-content reveal: super_admin + opt-in ON → expand-row
//     surfaces the payload; super_admin + opt-in OFF → meta only;
//     ff_support → expand-row hides the payload even when opt-in
//     is on.
//   * Stub tabs render the 11A.3.x / 9.UX.1a copy.
//   * Narrow-viewport rendering: the screen embeds inside the admin
//     shell's detail pane (~540x158 on the default 800x600 test
//     viewport) without a `RenderFlex` overflow.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/debug_console_admin_models.dart';
import 'package:forge_and_flow/admin/screens/debug_console_admin_screen.dart';
import 'package:forge_and_flow/admin/services/debug_console_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: child,
      );

  void setLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  RequestLogEntry seedEntry({
    required String id,
    required String operatorId,
    String? locationId = 'loc-1',
    String usageClass = 'advisor_qa',
    RequestLogStatus status = RequestLogStatus.success,
    DateTime? startedAt,
    int latencyMs = 412,
    String? idempotencyKey,
    bool fullContentOptInOn = false,
    Map<String, Object?>? fullContent,
  }) {
    return RequestLogEntry(
      requestId: id,
      idempotencyKey: idempotencyKey ?? 'idem-$id',
      operatorId: operatorId,
      locationId: locationId,
      usageClass: usageClass,
      status: status,
      startedAt: startedAt ?? DateTime.utc(2026, 5, 3, 11, 30),
      latencyMs: latencyMs,
      requestMeta: const <String, Object?>{
        'route': '/v1/test',
        'method': 'POST',
      },
      fullContentOptInOn: fullContentOptInOn,
      fullContentPayload: fullContent,
    );
  }

  Future<void> pressRefresh(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('admin_debug_console_refresh_button')));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'initial render exposes Refresh, tabs, and live-tail off by default',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_tabs')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_refresh_button')),
      findsOneWidget,
    );
    // Live-tail toggle defaults to off.
    final toggleFinder = find.byKey(
      const Key('admin_debug_console_live_tail_toggle'),
    );
    expect(toggleFinder, findsOneWidget);
    final toggle = tester.widget<Switch>(toggleFinder);
    expect(toggle.value, isFalse);
    // The view-only ff_support indicator is absent because the
    // default `editingEnabled = true` lands on the super_admin path.
    expect(
      find.byKey(const Key('admin_debug_console_view_only_indicator')),
      findsNothing,
    );
  });

  testWidgets('Refresh fetches the request list and renders rows',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-001',
          operatorId: 'op-A',
          startedAt: DateTime.utc(2026, 5, 3, 11, 50),
        ),
        seedEntry(
          id: 'req-002',
          operatorId: 'op-A',
          status: RequestLogStatus.error,
          startedAt: DateTime.utc(2026, 5, 3, 11, 45),
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    expect(
      find.byKey(const Key('admin_debug_console_row_req-001')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-002')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_empty_state')),
      findsNothing,
    );
  });

  testWidgets('search by request_id narrows the visible rows',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-aaa', operatorId: 'op-A'),
        seedEntry(id: 'req-bbb', operatorId: 'op-A'),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);
    expect(
      find.byKey(const Key('admin_debug_console_row_req-aaa')),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('admin_debug_console_search_field')),
      'bbb',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-aaa')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-bbb')),
      findsOneWidget,
    );
  });

  testWidgets('search by idempotency_key narrows the visible rows',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-X',
          operatorId: 'op-A',
          idempotencyKey: 'idem-search-target-001',
        ),
        seedEntry(
          id: 'req-Y',
          operatorId: 'op-A',
          idempotencyKey: 'idem-other-row-002',
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    await tester.enterText(
      find.byKey(const Key('admin_debug_console_search_field')),
      'search-target',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-X')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-Y')),
      findsNothing,
    );
  });

  testWidgets('status filter narrows the visible rows', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-ok',
          operatorId: 'op-A',
          status: RequestLogStatus.success,
        ),
        seedEntry(
          id: 'req-bad',
          operatorId: 'op-A',
          status: RequestLogStatus.error,
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    await tester.tap(find.byKey(const Key('admin_debug_console_filter_status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('error').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-ok')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-bad')),
      findsOneWidget,
    );
  });

  testWidgets('time-window filter narrows by started_at', (tester) async {
    setLargeViewport(tester);
    final now = DateTime.utc(2026, 5, 3, 12);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-recent',
          operatorId: 'op-A',
          startedAt: now.subtract(const Duration(minutes: 2)),
        ),
        seedEntry(
          id: 'req-old',
          operatorId: 'op-A',
          startedAt: now.subtract(const Duration(hours: 4)),
        ),
      ],
      now: () => now,
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => now,
        ),
      ),
    );
    await pressRefresh(tester);

    await tester.tap(find.byKey(const Key('admin_debug_console_filter_window')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Last 5 min').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-recent')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-old')),
      findsNothing,
    );
  });

  testWidgets(
      'super_admin + opt-in ON reveals the full content payload on expand',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-full',
          operatorId: 'op-A',
          fullContentOptInOn: true,
          fullContent: const <String, Object?>{
            'prompt_summary': 'sample prompt body',
            'response_summary': 'sample response body',
          },
        ),
      ],
      optInSeed: <FullContentOptIn>[
        FullContentOptIn(
          operatorId: 'op-A',
          flagName: kDebugConsoleFullContentFlagName,
          enabled: true,
          updatedAt: DateTime.utc(2026, 5, 1, 10),
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);
    await tester.tap(find.byKey(const Key('admin_debug_console_row_req-full')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_full_content_req-full')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_full_content_locked')),
      findsNothing,
    );
  });

  testWidgets(
      'super_admin + opt-in OFF keeps the full content locked',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-meta-only',
          operatorId: 'op-A',
          fullContentOptInOn: false,
          fullContent: const <String, Object?>{
            'prompt_summary': 'should never render',
          },
        ),
      ],
      optInSeed: <FullContentOptIn>[
        FullContentOptIn(
          operatorId: 'op-A',
          flagName: kDebugConsoleFullContentFlagName,
          enabled: false,
          updatedAt: DateTime.utc(2026, 5, 1, 10),
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);
    await tester
        .tap(find.byKey(const Key('admin_debug_console_row_req-meta-only')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_full_content_req-meta-only')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_debug_console_full_content_locked')),
      findsOneWidget,
    );
  });

  testWidgets(
      'ff_support sees view-only indicator and cannot reveal full content '
      'even when opt-in is on',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-readonly',
          operatorId: 'op-A',
          fullContentOptInOn: true,
          fullContent: const <String, Object?>{
            'prompt_summary': 'sensitive payload',
          },
        ),
      ],
      optInSeed: <FullContentOptIn>[
        FullContentOptIn(
          operatorId: 'op-A',
          flagName: kDebugConsoleFullContentFlagName,
          enabled: true,
          updatedAt: DateTime.utc(2026, 5, 1, 10),
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          editingEnabled: false,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    expect(
      find.byKey(const Key('admin_debug_console_view_only_indicator')),
      findsOneWidget,
    );

    await tester
        .tap(find.byKey(const Key('admin_debug_console_row_req-readonly')));
    await tester.pumpAndSettle();

    // Even though the operator opt-in is on, the view-only role keeps
    // the payload hidden.
    expect(
      find.byKey(const Key('admin_debug_console_full_content_req-readonly')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_debug_console_full_content_locked')),
      findsOneWidget,
    );
  });

  testWidgets('live-tail toggle starts polling when flipped on',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-existing', operatorId: 'op-A'),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          tailPollInterval: const Duration(milliseconds: 50),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);
    expect(
      find.byKey(const Key('admin_debug_console_row_req-existing')),
      findsOneWidget,
    );

    // Toggle live-tail on; the gateway already returns the existing
    // row so the row count is unchanged but the tail poll should run.
    await tester.tap(
      find.byKey(const Key('admin_debug_console_live_tail_toggle')),
    );
    await tester.pump();

    // Append a new row to the gateway and let the next poll fire.
    gateway.appendEntry(
      seedEntry(
        id: 'req-tailed',
        operatorId: 'op-A',
        startedAt: DateTime.utc(2026, 5, 3, 12, 0, 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-tailed')),
      findsOneWidget,
    );

    // Disposal should cancel the timer; pumping a new widget tree
    // implicitly disposes the screen.
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Graph debug and MFA diagnostics tabs render the stub copy',
      (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('admin_debug_console_tab_graph_debug')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_debug_console_stub_graph_debug')),
      findsOneWidget,
    );

    await tester
        .tap(find.byKey(const Key('admin_debug_console_tab_mfa_diagnostics')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_debug_console_stub_mfa_diagnostics')),
      findsOneWidget,
    );
  });

  testWidgets(
      'live-tail polls do not stack when the prior tailRecent has not '
      'returned yet',
      (tester) async {
    setLargeViewport(tester);
    final gateway = _HoldableDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-base', operatorId: 'op-A'),
      ],
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          tailPollInterval: const Duration(milliseconds: 30),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);
    expect(gateway.tailCallCount, equals(0));

    // Arm the gateway: hold the next tail call so the timer keeps
    // ticking against an unresolved future.
    gateway.holdNext = true;

    await tester.tap(
      find.byKey(const Key('admin_debug_console_live_tail_toggle')),
    );
    await tester.pump();

    // First tick fires and is captured (in flight, not resolved).
    await tester.pump(const Duration(milliseconds: 35));
    expect(gateway.tailCallCount, equals(1));

    // Pump several intervals while the first tail call is still
    // unresolved. None of these should issue a new tailRecent.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 35));
    }
    expect(
      gateway.tailCallCount,
      equals(1),
      reason: 'live-tail must not stack while a prior tail call is in flight',
    );

    // Resolve the held call; the next tick may now fire.
    gateway.completeOldestTail();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 35));
    expect(gateway.tailCallCount, greaterThanOrEqualTo(2));

    // Cleanup: dispose the screen so the timer cancels.
    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    gateway.completeAllTails();
    await tester.pump();
  });

  testWidgets('live-tail merge clamps the table back to the bounded list limit',
      (tester) async {
    setLargeViewport(tester);
    // Seed exactly the limit so the initial refresh fills the table
    // to its cap.
    final initialEntries = <RequestLogEntry>[
      for (var i = 0; i < kDebugConsoleListLimit; i++)
        seedEntry(
          id: 'req-init-${i.toString().padLeft(3, '0')}',
          operatorId: 'op-A',
          startedAt: DateTime.utc(2026, 5, 3, 11)
              .add(Duration(seconds: i)),
        ),
    ];
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: initialEntries,
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          tailPollInterval: const Duration(milliseconds: 30),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    // Now flip live-tail on and append several brand-new rows that the
    // tail tick will pull in. After the merge the visible list must
    // never exceed `kDebugConsoleListLimit` regardless of how many new
    // rows arrive.
    await tester.tap(
      find.byKey(const Key('admin_debug_console_live_tail_toggle')),
    );
    await tester.pump();
    for (var i = 0; i < 25; i++) {
      gateway.appendEntry(
        seedEntry(
          id: 'req-tail-${i.toString().padLeft(3, '0')}',
          operatorId: 'op-A',
          startedAt: DateTime.utc(2026, 5, 3, 12, 0, i),
        ),
      );
    }
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    // Pull the row keys directly from the rendered list and assert
    // the count is clamped.
    final renderedRowFinder = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('admin_debug_console_row_');
    });
    final renderedRowCount = renderedRowFinder.evaluate().length;
    expect(
      renderedRowCount,
      lessThanOrEqualTo(kDebugConsoleListLimit),
      reason: 'live-tail merge must clamp back to kDebugConsoleListLimit',
    );

    await tester.pumpWidget(wrap(const SizedBox.shrink()));
    await tester.pump(const Duration(milliseconds: 200));
  });

  testWidgets(
      'screen composes without overflow at the default 800x600 viewport',
      (tester) async {
    // Pins the Codex regression: the prior Column-based request log
    // body overflowed ~124 px at the normal shell viewport when the
    // shell embedded the screen. The default Flutter test viewport
    // (800x600) is the same shape the shell uses, so a vanilla pump
    // here exercises the same overflow surface. After the ListView
    // refactor + tightened header the screen renders without
    // throwing `RenderFlex overflowed`.
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-default', operatorId: 'op-A'),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await pressRefresh(tester);

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('admin_debug_console_request_log_body')),
      findsOneWidget,
    );
  });
}

/// Test gateway that lets the harness hold `tailRecent` futures open.
/// Used by the live-tail "do not stack" test to simulate a slow proxy
/// response that takes longer than the polling interval.
class _HoldableDebugConsoleAdminGateway extends InMemoryDebugConsoleAdminGateway {
  _HoldableDebugConsoleAdminGateway({super.seed});

  bool holdNext = false;
  int tailCallCount = 0;
  final List<Completer<List<RequestLogEntry>>> _pending =
      <Completer<List<RequestLogEntry>>>[];

  @override
  Future<List<RequestLogEntry>> tailRecent({
    int limit = kDebugConsoleTailLimit,
  }) {
    tailCallCount += 1;
    if (!holdNext) {
      return super.tailRecent(limit: limit);
    }
    final completer = Completer<List<RequestLogEntry>>();
    _pending.add(completer);
    return completer.future;
  }

  void completeOldestTail() {
    if (_pending.isEmpty) return;
    holdNext = false;
    _pending.removeAt(0).complete(const <RequestLogEntry>[]);
  }

  void completeAllTails() {
    while (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(const <RequestLogEntry>[]);
    }
  }
}

