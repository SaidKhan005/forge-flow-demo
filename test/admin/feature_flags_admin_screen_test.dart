// Phase 11A.7 — Feature flags admin screen widget tests.
//
// Drives the screen against an [InMemoryFeatureFlagsAdminGateway] so
// the click path runs end-to-end without a backend. Coverage:
//
//   * Initial render lists every seeded flag with kind chip + scope
//     chip + last-toggle metadata.
//   * Standard flag toggle: single tap → SnackBar → list re-renders
//     with the new value + new updated_by.
//   * Destructive flag toggle: tap surfaces the confirm-by-typing
//     dialog; the Toggle button stays disabled until the typed text
//     matches the flag name.
//   * Read-only mode (`editingEnabled: false`) hides every mutate
//     affordance — exercised by the `ff_support` walkthrough.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/feature_flags_admin_models.dart';
import 'package:forge_and_flow/admin/screens/feature_flags_admin_screen.dart';
import 'package:forge_and_flow/admin/services/feature_flags_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  FeatureFlagAdminRow row({
    required String id,
    required String name,
    bool enabled = false,
    String kind = kFeatureFlagKindStandard,
    String? description,
    String? operatorId,
    String? locationId,
  }) {
    return FeatureFlagAdminRow(
      flagId: id,
      flagName: name,
      operatorId: operatorId,
      locationId: locationId,
      enabled: enabled,
      kind: kind,
      description: description,
      updatedBy: 'seed-actor',
      createdAt: DateTime.utc(2026, 5, 1, 10, 0),
      updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
    );
  }

  testWidgets('renders one tile per seeded flag with kind + scope chips', (
    tester,
  ) async {
    final gateway = InMemoryFeatureFlagsAdminGateway(
      seed: <FeatureFlagAdminRow>[
        row(
          id: 'f-std',
          name: 'advisor_enabled',
          enabled: true,
          description: 'Advisor surface kill switch',
        ),
        row(
          id: 'f-dest',
          name: 'circuit_breaker_open',
          enabled: false,
          kind: kFeatureFlagKindDestructive,
          description: 'Circuit breaker for production traffic.',
        ),
      ],
    );
    await tester.pumpWidget(wrap(FeatureFlagsAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('Advisor access'), findsOneWidget);
    expect(find.text('Circuit Breaker Open'), findsOneWidget);
    // Destructive chip is on the destructive flag.
    expect(
      find.byKey(const Key('admin_feature_flag_danger_f-dest')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_feature_flag_danger_f-std')),
      findsNothing,
    );
    // Scope chips are present on both.
    expect(
      find.byKey(const Key('admin_feature_flag_scope_f-dest')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_feature_flag_scope_f-std')),
      findsOneWidget,
    );
    // Value chips read the seeded enabled bit.
    expect(find.text('On'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('Control ID: advisor_enabled'), findsNothing);
    await tester.tap(find.byKey(const Key('admin_feature_flag_details_f-std')));
    await tester.pumpAndSettle();
    expect(find.text('Control ID: advisor_enabled'), findsOneWidget);
  });

  testWidgets('selected hierarchy scope filters visible launch controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final gateway = InMemoryFeatureFlagsAdminGateway(
      seed: <FeatureFlagAdminRow>[
        row(id: 'global', name: 'global_control'),
        row(id: 'business', name: 'business_control', operatorId: 'op-a'),
        row(
          id: 'location-a',
          name: 'location_control_a',
          operatorId: 'op-a',
          locationId: 'loc-a',
        ),
        row(
          id: 'location-b',
          name: 'location_control_b',
          operatorId: 'op-a',
          locationId: 'loc-b',
        ),
        row(
          id: 'other-business',
          name: 'other_business_control',
          operatorId: 'op-b',
        ),
      ],
    );

    await tester.pumpWidget(
      wrap(
        FeatureFlagsAdminScreen(
          gateway: gateway,
          hierarchyScope: const AdminHierarchyScopeIntent.location(
            operatorId: 'op-a',
            locationId: 'loc-a',
            operatorName: 'Demo Diner',
            locationName: 'Harbor',
          ),
          scopeLocationIds: const <String>{'loc-a'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Global Control'), findsOneWidget);
    expect(find.text('Business Control'), findsOneWidget);
    expect(find.text('Location Control A'), findsOneWidget);
    expect(find.text('Location Control B'), findsNothing);
    expect(find.text('Other Business Control'), findsNothing);
    expect(find.textContaining('Demo Diner / Harbor'), findsNothing);
    expect(
      find.byKey(const Key('admin_feature_flags_scope_note')),
      findsNothing,
    );
    expect(find.text('Where this applies'), findsNothing);
    expect(
      find.byKey(const Key('admin_feature_flags_scope_notice')),
      findsNothing,
    );
  });

  testWidgets('standard flag toggle flips the value and shows the SnackBar', (
    tester,
  ) async {
    var keyCounter = 0;
    final gateway = InMemoryFeatureFlagsAdminGateway(
      actorUserId: 'super-admin-uuid',
      seed: <FeatureFlagAdminRow>[
        row(id: 'f-std', name: 'advisor_enabled', enabled: false),
      ],
    );
    await tester.pumpWidget(
      wrap(
        FeatureFlagsAdminScreen(
          gateway: gateway,
          idempotencyKeyFactory: () => 'idem-${keyCounter++}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsOneWidget);

    await tester.tap(find.byKey(const Key('admin_feature_flag_toggle_f-std')));
    await tester.pumpAndSettle();

    expect(find.text('Launch control updated'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);
    expect(find.textContaining('super-admin-uuid'), findsOneWidget);
  });

  testWidgets(
    'destructive flag toggle requires confirm-by-typing the flag name',
    (tester) async {
      final gateway = InMemoryFeatureFlagsAdminGateway(
        actorUserId: 'super-admin-uuid',
        seed: <FeatureFlagAdminRow>[
          row(
            id: 'f-dest',
            name: 'audit_logs_cutover_enabled',
            enabled: true,
            kind: kFeatureFlagKindDestructive,
          ),
        ],
      );
      await tester.pumpWidget(wrap(FeatureFlagsAdminScreen(gateway: gateway)));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_feature_flag_toggle_f-dest')),
      );
      await tester.pumpAndSettle();

      // Dialog opens; Toggle button is disabled until the typed text
      // matches the flag name.
      expect(
        find.byKey(const Key('admin_feature_flag_danger_dialog')),
        findsOneWidget,
      );
      final confirmFinder = find.byKey(
        const Key('admin_feature_flag_danger_confirm'),
      );
      expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNull);

      // Wrong text leaves the button disabled.
      await tester.enterText(
        find.byKey(const Key('admin_feature_flag_danger_input')),
        'wrong_name',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNull);

      // Exact match enables the button.
      await tester.enterText(
        find.byKey(const Key('admin_feature_flag_danger_input')),
        'audit_logs_cutover_enabled',
      );
      await tester.pump();
      expect(tester.widget<FilledButton>(confirmFinder).onPressed, isNotNull);

      await tester.tap(confirmFinder);
      await tester.pumpAndSettle();

      // Toggle landed; flag flipped off.
      expect(find.text('Launch control updated'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
    },
  );

  testWidgets('destructive cancel keeps the prior value (no toggle fires)', (
    tester,
  ) async {
    final gateway = InMemoryFeatureFlagsAdminGateway(
      seed: <FeatureFlagAdminRow>[
        row(
          id: 'f-dest',
          name: 'audit_logs_cutover_enabled',
          enabled: true,
          kind: kFeatureFlagKindDestructive,
        ),
      ],
    );
    await tester.pumpWidget(wrap(FeatureFlagsAdminScreen(gateway: gateway)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_feature_flag_toggle_f-dest')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_feature_flag_danger_cancel')));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
    expect(find.text('Launch control updated'), findsNothing);
  });

  testWidgets('editingEnabled = false hides toggle affordance + shows banner', (
    tester,
  ) async {
    final gateway = InMemoryFeatureFlagsAdminGateway(
      seed: <FeatureFlagAdminRow>[
        row(id: 'f-std', name: 'advisor_enabled', enabled: true),
      ],
    );
    await tester.pumpWidget(
      wrap(FeatureFlagsAdminScreen(gateway: gateway, editingEnabled: false)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_feature_flags_readonly_banner')),
      findsOneWidget,
    );
    // Active toggle button is absent; the disabled placeholder is
    // present so the screen still shows the prospective action label.
    expect(
      find.byKey(const Key('admin_feature_flag_toggle_f-std')),
      findsNothing,
    );
    final disabledButton = tester.widget<FilledButton>(
      find.byKey(const Key('admin_feature_flag_toggle_disabled_f-std')),
    );
    expect(disabledButton.onPressed, isNull);
  });
}
