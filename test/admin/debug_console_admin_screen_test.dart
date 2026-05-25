// Phase 11A.5 / Support logs redesign P3 — Support logs admin screen
// widget tests.
//
// Drives `DebugConsoleAdminScreen` against an
// `InMemoryDebugConsoleAdminGateway` so the click path runs end-to-
// end without a backend. Coverage:
//
//   * Initial render shows the Refresh button + the compact filter row
//     (Search / Type / When / Result) and the Live chip OFF by default;
//     the gateway is hit only after Refresh.
//   * Filters AND together: result / time-window narrow the visible
//     rows; clearing returns the full list.
//   * Search by request_id and by idempotency_key both work.
//   * The folded Type filter: picking an AI type narrows to that
//     usage_class; picking a support-help group switches to the typed
//     relationship / account list (replacing the old three tabs + the
//     request-type key box). Clearing back to "All activity" restores.
//   * Live chip is OFF by default and starts polling when tapped; it
//     never stacks in-flight requests and merges back to the bounded
//     list limit so the table cannot grow unbounded.
//   * Full-message-text reveal: super_admin + opt-in ON → expand-row
//     surfaces the payload; super_admin + opt-in OFF → hidden;
//     ff_support → hidden even when opt-in is on.
//   * Expanded row shows the plain "What happened" facts and the
//     collapsible "Technical reference" zone with the real telemetry
//     (and honest "—" sentinels where not recorded).
//   * Narrow-viewport rendering: the screen embeds inside the admin
//     shell's detail pane (~540x158 on the default 800x600 test
//     viewport) without a `RenderFlex` overflow.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_human_labels.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/debug_console_admin_models.dart';
import 'package:forge_and_flow/admin/screens/debug_console_admin_screen.dart';
import 'package:forge_and_flow/admin/services/debug_console_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/roles_hierarchy_sessions_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/theme/scope_icons.dart';

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
    Map<String, Object?>? requestMeta,
    String? provider,
    String? modelId,
    int? promptTokenCount,
    int? completionTokenCount,
    double? costUsd,
    String? actorUserId,
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
      requestMeta:
          requestMeta ??
          const <String, Object?>{'route': '/v1/test', 'method': 'POST'},
      fullContentOptInOn: fullContentOptInOn,
      fullContentPayload: fullContent,
      provider: provider,
      modelId: modelId,
      promptTokenCount: promptTokenCount,
      completionTokenCount: completionTokenCount,
      costUsd: costUsd,
      actorUserId: actorUserId,
    );
  }

  Future<void> pressRefresh(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const Key('admin_debug_console_refresh_button')),
    );
    await tester.pumpAndSettle();
  }

  /// Open the folded Type dropdown and pick the option labelled [label].
  Future<void> pickType(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('admin_debug_console_filter_type')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'initial render exposes Refresh, the compact filter row, and Live off',
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
      // The compact filter row replaces the old three tabs + Filters panel.
      expect(
        find.byKey(const Key('admin_debug_console_filter_bar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_debug_console_filter_type')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_debug_console_search_field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_debug_console_refresh_button')),
        findsOneWidget,
      );
      // The old tab bar + request-type key box are gone (folded into Type).
      expect(find.byKey(const Key('admin_debug_console_tabs')), findsNothing);
      expect(
        find.byKey(const Key('admin_debug_console_use_case_key')),
        findsNothing,
      );
      // Live chip present and off by default.
      expect(
        find.byKey(const Key('admin_debug_console_live_tail_toggle')),
        findsOneWidget,
      );
      expect(find.text('Live'), findsOneWidget);
      // The view-only ff_support indicator is absent because the
      // default `editingEnabled = true` lands on the super_admin path.
      expect(
        find.byKey(const Key('admin_debug_console_view_only_indicator')),
        findsNothing,
      );
    },
  );

  testWidgets('Refresh fetches the request list and renders rows', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-001',
          operatorId: 'op-A',
          startedAt: DateTime.utc(2026, 5, 3, 11, 50),
          provider: 'anthropic',
          modelId: 'claude-sonnet-4-6',
          promptTokenCount: 820,
          completionTokenCount: 240,
          costUsd: 0.0117,
          actorUserId: '11111111-1111-4111-8111-111111111111',
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
    await tester.pumpAndSettle();
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
    // Plain title (from the shared label catalog, unchanged).
    expect(find.text('Advisor answers'), findsWidgets);
    // Header reads "Updated <relative>" (no monospace "Last checked").
    expect(find.textContaining('Updated'), findsOneWidget);
    expect(find.textContaining('Last checked'), findsNothing);

    // Expand the first row → the plain "What happened" facts appear,
    // including the human date as the "When" value.
    await tester.tap(find.byKey(const Key('admin_debug_console_row_req-001')));
    await tester.pumpAndSettle();
    expect(find.text('What happened'.toUpperCase()), findsOneWidget);
    expect(
      find.text(adminHumanDateTime(DateTime.utc(2026, 5, 3, 11, 50))),
      findsOneWidget,
    );
    expect(find.text('Worked'), findsWidgets);
    // The real measured latency renders in seconds (412 ms -> 0.4 seconds).
    expect(find.text('0.4 seconds'), findsOneWidget);
  });

  testWidgets('expanded technical reference shows real telemetry + honest '
      'sentinels for missing fields', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        // An LLM request with full telemetry.
        seedEntry(
          id: 'req-rich',
          operatorId: 'op-A',
          provider: 'anthropic',
          modelId: 'claude-sonnet-4-6',
          promptTokenCount: 820,
          completionTokenCount: 240,
          costUsd: 0.0117,
          actorUserId: '11111111-1111-4111-8111-111111111111',
        ),
        // A failed/timed-out LLM request: P1b writes stats only on
        // success, so this row honestly carries NO telemetry → "—".
        seedEntry(
          id: 'req-bare',
          operatorId: 'op-A',
          usageClass: 'advisor_qa',
          status: RequestLogStatus.timeout,
          latencyMs: 0,
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
      find.byKey(const Key('admin_debug_console_row_req-rich')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-bare')),
      findsOneWidget,
    );

    // Open the failed/timed-out row first (it stays short) and reveal its
    // Technical reference → model / tokens / cost are the honest empty
    // sentinel, never a phantom 0.
    await tester.tap(find.byKey(const Key('admin_debug_console_row_req-bare')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const Key('admin_debug_console_technical_toggle_req-bare'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('—'), findsWidgets);
    // Collapse it again.
    await tester.tap(find.byKey(const Key('admin_debug_console_row_req-bare')));
    await tester.pumpAndSettle();

    // Open the rich LLM row + its Technical reference → real telemetry.
    await tester.tap(find.byKey(const Key('admin_debug_console_row_req-rich')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_debug_console_technical_req-rich')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(
        const Key('admin_debug_console_technical_toggle_req-rich'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('claude-sonnet-4-6'), findsOneWidget);
    expect(find.text('820 in / 240 out'), findsOneWidget);
    expect(find.text(r'$0.0117'), findsOneWidget);
    // The raw request reference lives only inside the technical block.
    expect(find.text('req-rich'), findsOneWidget);
  });

  testWidgets('initial filter loads the matching support logs', (tester) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-op-a', operatorId: 'op-a', locationId: 'loc-a'),
        seedEntry(id: 'req-op-b', operatorId: 'op-b', locationId: 'loc-b'),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );

    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          initialFilter: const RequestLogFilter(
            operatorId: 'op-a',
            locationId: 'loc-a',
          ),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The compact row no longer re-renders standalone Business/Location ID
    // chips (scope fills them); only the matching row appears.
    expect(
      find.byKey(const Key('admin_debug_console_row_req-op-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-op-b')),
      findsNothing,
    );
  });

  testWidgets('org-unit scope expands to covered support-log locations', (
    tester,
  ) async {
    setLargeViewport(tester);
    const scope = AdminHierarchyScopeIntent.orgUnit(
      operatorId: 'op-scope',
      orgUnitId: 'ou-region',
      operatorName: 'Scope Group',
      orgUnitName: 'Region',
      hierarchyPath: <String>['Canada'],
    );
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-covered-a',
          operatorId: 'op-scope',
          locationId: 'loc-covered-a',
        ),
        seedEntry(
          id: 'req-covered-child',
          operatorId: 'op-scope',
          locationId: 'loc-covered-child',
        ),
        seedEntry(
          id: 'req-outside',
          operatorId: 'op-scope',
          locationId: 'loc-outside',
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: const <String, List<OrgUnitAdminNode>>{
        'op-scope': <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'ou-root',
            name: 'Scope Group',
            operatorId: 'op-scope',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'ou-region',
            name: 'Region',
            operatorId: 'op-scope',
            parentOrgUnitId: 'ou-root',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'ou-district',
            name: 'District',
            operatorId: 'op-scope',
            parentOrgUnitId: 'ou-region',
          ),
          OrgUnitAdminNode(
            orgUnitId: 'ou-other',
            name: 'Other',
            operatorId: 'op-scope',
            parentOrgUnitId: 'ou-root',
          ),
        ],
      },
      locationsByOperator: const <String, List<HierarchyLocationLeaf>>{
        'op-scope': <HierarchyLocationLeaf>[
          HierarchyLocationLeaf(
            locationId: 'loc-covered-a',
            name: 'Covered A',
            operatorId: 'op-scope',
            orgUnitId: 'ou-region',
          ),
          HierarchyLocationLeaf(
            locationId: 'loc-covered-child',
            name: 'Covered Child',
            operatorId: 'op-scope',
            orgUnitId: 'ou-district',
          ),
          HierarchyLocationLeaf(
            locationId: 'loc-outside',
            name: 'Outside',
            operatorId: 'op-scope',
            orgUnitId: 'ou-other',
          ),
        ],
      },
    );

    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          hierarchyScope: scope,
          initialFilter: const RequestLogFilter(operatorId: 'op-scope'),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_scope_banner')),
      findsOneWidget,
    );
    expect(
      find.text('Org unit: Scope Group / Canada / Region'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-covered-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-covered-child')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-outside')),
      findsNothing,
    );
  });

  testWidgets('org-unit scope without hierarchy data shows unsupported copy', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(id: 'req-business-row', operatorId: 'op-scope'),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );

    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
            operatorId: 'op-scope',
            orgUnitId: 'ou-region',
            orgUnitName: 'Region',
          ),
          initialFilter: const RequestLogFilter(operatorId: 'op-scope'),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'Org-unit support logs need the hierarchy location list',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-business-row')),
      findsNothing,
    );
  });

  testWidgets(
    'scope banner renders the canonical scope-entity glyph per scope tier '
    '(location -> place, business -> apartment, org unit -> tree)',
    (tester) async {
      setLargeViewport(tester);

      Future<void> pumpWithScope(AdminHierarchyScopeIntent scope) async {
        final gateway = InMemoryDebugConsoleAdminGateway(
          seed: <RequestLogEntry>[
            seedEntry(id: 'req-scope', operatorId: 'op-scope'),
          ],
          now: () => DateTime.utc(2026, 5, 3, 12),
        );
        await tester.pumpWidget(
          wrap(
            DebugConsoleAdminScreen(
              gateway: gateway,
              hierarchyScope: scope,
              initialFilter: const RequestLogFilter(operatorId: 'op-scope'),
              now: () => DateTime.utc(2026, 5, 3, 12),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      IconData bannerIcon() {
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('admin_debug_console_scope_banner')),
            matching: find.byType(Icon),
          ),
        );
        return icon.icon!;
      }

      // Location scope -> canonical location glyph (place), not the legacy
      // admin storefront_outlined.
      await pumpWithScope(
        const AdminHierarchyScopeIntent.location(
          operatorId: 'op-scope',
          locationId: 'loc-scope',
          operatorName: 'Scope Co.',
          locationName: 'Scope Location',
          valueState: AdminHierarchyScopeValueState.locationOnly,
        ),
      );
      expect(bannerIcon(), scopeIcon(kind: ScopeEntityKind.location));
      expect(bannerIcon(), isNot(Icons.storefront_outlined));

      // Business scope -> canonical business glyph (apartment), not the
      // legacy admin business_outlined.
      await pumpWithScope(
        const AdminHierarchyScopeIntent.business(
          operatorId: 'op-scope',
          operatorName: 'Scope Co.',
        ),
      );
      expect(bannerIcon(), scopeIcon(kind: ScopeEntityKind.business));
      expect(bannerIcon(), isNot(Icons.business_outlined));

      // Org-unit scope -> canonical generic org-unit glyph (account tree).
      await pumpWithScope(
        const AdminHierarchyScopeIntent.orgUnit(
          operatorId: 'op-scope',
          orgUnitId: 'ou-scope',
          operatorName: 'Scope Co.',
          orgUnitName: 'Region',
        ),
      );
      expect(bannerIcon(), scopeIcon(kind: ScopeEntityKind.orgUnit));
    },
  );

  testWidgets('org-unit support logs cap expanded location filters', (
    tester,
  ) async {
    setLargeViewport(tester);
    const scope = AdminHierarchyScopeIntent.orgUnit(
      operatorId: 'op-scope',
      orgUnitId: 'ou-region',
      operatorName: 'Scope Group',
      orgUnitName: 'Region',
    );
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-too-wide',
          operatorId: 'op-scope',
          locationId: 'loc-000',
        ),
      ],
      now: () => DateTime.utc(2026, 5, 3, 12),
    );
    final hierarchyGateway = InMemoryRolesHierarchySessionsAdminGateway(
      orgUnitsByOperator: const <String, List<OrgUnitAdminNode>>{
        'op-scope': <OrgUnitAdminNode>[
          OrgUnitAdminNode(
            orgUnitId: 'ou-region',
            name: 'Region',
            operatorId: 'op-scope',
          ),
        ],
      },
      locationsByOperator: <String, List<HierarchyLocationLeaf>>{
        'op-scope': <HierarchyLocationLeaf>[
          for (var i = 0; i < 101; i++)
            HierarchyLocationLeaf(
              locationId: 'loc-${i.toString().padLeft(3, '0')}',
              name: 'Location $i',
              operatorId: 'op-scope',
              orgUnitId: 'ou-region',
            ),
        ],
      },
    );

    await tester.pumpWidget(
      wrap(
        DebugConsoleAdminScreen(
          gateway: gateway,
          hierarchyGateway: hierarchyGateway,
          hierarchyScope: scope,
          initialFilter: const RequestLogFilter(operatorId: 'op-scope'),
          now: () => DateTime.utc(2026, 5, 3, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('cap explicit location filters at 100'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-too-wide')),
      findsNothing,
    );
  });

  testWidgets('search by request_id narrows the visible rows', (tester) async {
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

  testWidgets('search by idempotency_key narrows the visible rows', (
    tester,
  ) async {
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

  testWidgets('Result filter (Worked) narrows the visible rows', (
    tester,
  ) async {
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

    // Result only offers Any / Worked / Not recorded (no error/timeout
    // standing options). "Worked" maps to the real success status.
    await tester.tap(
      find.byKey(const Key('admin_debug_console_filter_status')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Worked').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_debug_console_row_req-ok')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-bad')),
      findsNothing,
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
      wrap(DebugConsoleAdminScreen(gateway: gateway, now: () => now)),
    );
    await pressRefresh(tester);

    await tester.tap(
      find.byKey(const Key('admin_debug_console_filter_window')),
    );
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

  testWidgets('Type filter narrows to an AI usage class and clears back', (
    tester,
  ) async {
    setLargeViewport(tester);
    final gateway = InMemoryDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[
        seedEntry(
          id: 'req-advisor',
          operatorId: 'op-A',
          usageClass: 'advisor_qa',
        ),
        seedEntry(id: 'req-coach', operatorId: 'op-A', usageClass: 'coach_qa'),
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

    await pickType(tester, 'Coaching help');

    expect(
      find.byKey(const Key('admin_debug_console_row_req-advisor')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-coach')),
      findsOneWidget,
    );

    // Clear back to All activity → both AI rows return.
    await pickType(tester, 'All activity');

    expect(
      find.byKey(const Key('admin_debug_console_row_req-advisor')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_debug_console_row_req-coach')),
      findsOneWidget,
    );
  });

  testWidgets(
    'Type filter switches to the typed relationship and account groups',
    (tester) async {
      setLargeViewport(tester);
      final gateway = InMemoryDebugConsoleAdminGateway(
        seed: <RequestLogEntry>[
          seedEntry(
            id: 'req-relationship',
            operatorId: 'op-A',
            usageClass: 'relationship_review',
            requestMeta: const <String, Object?>{
              'summary': 'Relationship review',
            },
          ),
          seedEntry(
            id: 'req-account',
            operatorId: 'op-A',
            usageClass: 'account_help',
            requestMeta: const <String, Object?>{'summary': 'MFA account check'},
          ),
          // A usage_class outside both support groups must not leak in even
          // though its summary mentions "relationship".
          seedEntry(
            id: 'req-fuzzy-relationship',
            operatorId: 'op-A',
            usageClass: 'advisor_qa',
            requestMeta: const <String, Object?>{
              'summary': 'relationship word should not make this support help',
            },
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

      // Relationship help group.
      await pickType(tester, 'Relationship help');
      expect(
        find.byKey(const Key('admin_debug_console_row_req-relationship')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_debug_console_row_req-fuzzy-relationship'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_debug_console_row_req-account')),
        findsNothing,
      );

      // Account help group.
      await pickType(tester, 'Account help');
      expect(
        find.byKey(const Key('admin_debug_console_row_req-account')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_debug_console_row_req-relationship')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'super_admin + opt-in ON reveals the full message text on expand',
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
      await tester.tap(
        find.byKey(const Key('admin_debug_console_row_req-full')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_debug_console_full_content_req-full')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_debug_console_full_content_locked')),
        findsNothing,
      );
    },
  );

  testWidgets('super_admin + opt-in OFF keeps the full message text locked', (
    tester,
  ) async {
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
    await tester.tap(
      find.byKey(const Key('admin_debug_console_row_req-meta-only')),
    );
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

      await tester.tap(
        find.byKey(const Key('admin_debug_console_row_req-readonly')),
      );
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
    },
  );

  testWidgets('live chip starts polling when tapped on', (tester) async {
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

    // Tap the Live chip on; the gateway already returns the existing row
    // so the row count is unchanged but the tail poll should run.
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

  testWidgets('live-tail polls do not stack when the prior tailRecent has not '
      'returned yet', (tester) async {
    setLargeViewport(tester);
    final gateway = _HoldableDebugConsoleAdminGateway(
      seed: <RequestLogEntry>[seedEntry(id: 'req-base', operatorId: 'op-A')],
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

  testWidgets(
    'live-tail merge clamps the table back to the bounded list limit',
    (tester) async {
      setLargeViewport(tester);
      // Seed exactly the limit so the initial refresh fills the table
      // to its cap.
      final initialEntries = <RequestLogEntry>[
        for (var i = 0; i < kDebugConsoleListLimit; i++)
          seedEntry(
            id: 'req-init-${i.toString().padLeft(3, '0')}',
            operatorId: 'op-A',
            startedAt: DateTime.utc(2026, 5, 3, 11).add(Duration(seconds: i)),
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
    },
  );

  testWidgets(
    'screen composes without overflow at the default 800x600 viewport',
    (tester) async {
      // Pins the Codex regression: the prior Column-based request log
      // body overflowed ~124 px at the normal shell viewport when the
      // shell embedded the screen. The default Flutter test viewport
      // (800x600) is the same shape the shell uses, so a vanilla pump
      // here exercises the same overflow surface. The single-body
      // (folded Type filter, no tabs) layout + tightened header must
      // keep the screen rendering without throwing `RenderFlex
      // overflowed`.
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

      // Expanding a row at the tight viewport must also stay overflow-free.
      await tester.tap(
        find.byKey(const Key('admin_debug_console_row_req-default')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

/// Test gateway that lets the harness hold `tailRecent` futures open.
/// Used by the live-tail "do not stack" test to simulate a slow proxy
/// response that takes longer than the polling interval.
class _HoldableDebugConsoleAdminGateway
    extends InMemoryDebugConsoleAdminGateway {
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
