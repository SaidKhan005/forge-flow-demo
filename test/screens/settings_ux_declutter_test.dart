// Per-Daypart V1 UX — Settings declutter acceptance tests.
//
// Pins the operator's live-walkthrough findings:
//   E — descriptive sub-paragraphs under Settings section headers are
//       removed (Setup / Integrations tabs) while the headers and the
//       actual controls/values stay.
//   F — the mobile Wage Setup section renders the restyled,
//       operator-web-consistent informative layout (blended-mix
//       summary card + HP #11 "Source:" provenance line + per-bucket
//       cards with the single formula crumb), with no editor button in
//       viewOnly and the editor control intact when editable.
//   G — descriptive prose under the Data tab section headers is
//       removed while the per-table freshness rows and the
//       data-alignment audit panel stay intact.
//
// HP #11: the Wage Setup "Source:" provenance line + effective
// front/back wage badges are preserved — only decorative prose was
// stripped.
//
// Note: mobile `WageAuthoritySection` resolves its rows from a seeded
// SQLite DB that is not reachable under `flutter test` (the section
// stays in its keyless "Loading…" shell when mounted through
// `SettingsScreen`). The F cases therefore mount the section directly
// with the production-parity test seam (`initialRowsForTest`, mirrors
// `SettingsScreen.initialStatus`) so the restyled layout is actually
// exercised. E/G mount the full screen for the screen-level prose
// removal.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/wage_standard_context.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings/settings_data_sections.dart';
import 'package:forge_and_flow/screens/settings/settings_timing_authority_section.dart';
import 'package:forge_and_flow/screens/settings/settings_wage_authority_section.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/services/team/team_scope_visibility_policy.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';

const TeamScopeActor _ownerActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

const TeamScopeActor _ffSupportActor = TeamScopeActor(
  actorRoles: <String>{'ff_support'},
  actorOperatorId: 'op-1',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{},
);

AuthSession _session() => AuthSession(
  userId: 'user-1',
  operatorId: 'op-1',
  locationId: 'loc-1',
  firebaseIdToken: 'token',
  issuedAt: DateTime.utc(2026, 5, 15, 12),
  expiresAt: DateTime.utc(2026, 5, 15, 13),
  lastFreshAuthAt: DateTime.utc(2026, 5, 15, 12),
  roles: const <String>['operator_owner'],
  mfaEnrolled: true,
);

AuthSessionNotifier _notifier() {
  return AuthSessionNotifier(
    loginService: const ScaffoldFailingAuthLoginService(),
    storage: InMemorySecureSessionStorage(),
  )..debugSetSession(_session());
}

Widget _wrap({required AuthSessionNotifier notifier, required Widget child}) {
  return ChangeNotifierProvider<AuthSessionNotifier>.value(
    value: notifier,
    child: MaterialApp(home: child),
  );
}

const _ctx = WageStandardContext(
  restaurantId: 'demo_restaurant_001',
  fohWage: 16.00,
  bohWage: 18.50,
  referenceBlendedWage: 17.25,
  source: WageStandardSource.appConfiguredGenerator,
  builtAt: '2026-05-15T00:00:00Z',
);

const _rows = <WageRoleRow>[
  WageRoleRow(
    restaurantId: 'demo_restaurant_001',
    roleName: 'Server',
    laborBucket: 'foh',
    hourlyRate: 16.00,
    weightedHours: 30.0,
  ),
  WageRoleRow(
    restaurantId: 'demo_restaurant_001',
    roleName: 'Line cook',
    laborBucket: 'boh',
    hourlyRate: 18.50,
    weightedHours: 32.0,
  ),
  WageRoleRow(
    restaurantId: 'demo_restaurant_001',
    roleName: 'GM',
    laborBucket: 'manager',
    hourlyRate: 30.00,
    weightedHours: 40.0,
  ),
];

Widget _wageHarness({required bool viewOnly, String? scopeLabel}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: WageAuthoritySection(
          onChanged: () {},
          viewOnly: viewOnly,
          scopeLabel: scopeLabel,
          initialWageContextForTest: _ctx,
          initialRowsForTest: _rows,
        ),
      ),
    ),
  );
}

Widget _timingHarness({required String scopeLabel}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TimingAuthoritySection(
          restaurantId: 'demo_restaurant_001',
          scopeLabel: scopeLabel,
          initialConfigForTest: const RestaurantTimingConfig(
            restaurantId: 'demo_restaurant_001',
            businessTimezone: 'America/St_Johns',
            businessDayStartLocalTime: '05:00',
            weekStartDay: DateTime.monday,
            servicePeriodDefinitions: [],
            createdAt: '2026-05-15T00:00:00Z',
            updatedAt: '2026-05-15T00:00:00Z',
            selectedScopeType: 'location',
            selectedScopeId: 'demo_restaurant_001',
            sourceScopeType: 'org_unit',
            sourceScopeId: 'district-1',
            sourceScopeLabel: 'Metro District',
            inheritedFromAncestor: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E — Setup keeps the Wage Setup control; Integrations keeps its '
      'content but drops the descriptive sub-paragraph', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final notifier = _notifier();
    await tester.pumpWidget(
      _wrap(
        notifier: notifier,
        child: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          teamActor: _ownerActor,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Setup tab (default) still mounts the Wage Setup control.
    expect(
      find.byType(WageAuthoritySection, skipOffstage: false),
      findsOneWidget,
    );

    // Integrations tab: section content remains, prose removed.
    await tester.tap(find.byKey(const Key('settings_tab_integrations')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(
        const Key('settings_integrations_section'),
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'See which categories are still on demo data',
        skipOffstage: false,
      ),
      findsNothing,
    );
  });

  testWidgets(
    'F — Wage Setup renders the restyled summary + HP #11 Source line + '
    'bucket cards with the formula crumb (viewOnly: no editor button)',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _wageHarness(viewOnly: true, scopeLabel: 'Barrio Legado: St Johns'),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('settings_wage_setup_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('settings_wage_setup_scope_label')),
        findsOneWidget,
      );
      expect(find.text('Applies to: Barrio Legado: St Johns'), findsOneWidget);
      expect(
        find.byKey(const Key('settings_wage_setup_summary_card')),
        findsOneWidget,
      );
      // HP #11 provenance affordance preserved with the real label.
      expect(
        find.byKey(const Key('settings_wage_setup_source')),
        findsOneWidget,
      );
      expect(find.text('Source: Custom wage mix'), findsOneWidget);
      expect(find.text('Blended wage mix'), findsOneWidget);
      expect(find.text('\$17.25/hr'), findsOneWidget);
      // Effective front/back wage badges (HP #11 effective values).
      expect(find.text('Front of house · \$16.00/hr'), findsOneWidget);
      expect(find.text('Back of house · \$18.50/hr'), findsOneWidget);

      // Three labor-bucket cards.
      for (final wire in const <String>['foh', 'boh', 'manager']) {
        expect(
          find.byKey(Key('settings_wage_setup_bucket_$wire')),
          findsOneWidget,
        );
      }
      // Role rows render with the operator-web formula-crumb grammar.
      expect(find.text('Server'), findsOneWidget);
      expect(
        find.text('@ \$16.00/hr · 30.0 weighted hrs/wk = \$480.00'),
        findsOneWidget,
      );
      expect(find.text('Line cook'), findsOneWidget);
      expect(find.text('GM'), findsOneWidget);

      // viewOnly — no editor control.
      expect(find.text('Edit wage mix'), findsNothing);
    },
  );

  testWidgets(
    'F â€” Business Timing renders the selected scope before timing values',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        _timingHarness(scopeLabel: 'Barrio Legado: St Johns'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings_timing_authority_scope_label')),
        findsOneWidget,
      );
      expect(find.text('Applies to: Barrio Legado: St Johns'), findsOneWidget);
      expect(
        find.byKey(const Key('settings_timing_authority_source_label')),
        findsOneWidget,
      );
      expect(find.text('Inherited from: Metro District'), findsOneWidget);
      expect(find.text('Timezone'), findsOneWidget);
      expect(find.text('America/St_Johns'), findsOneWidget);
    },
  );

  testWidgets('F — editable path still exposes the Edit wage mix control '
      '(no control removed by the restyle)', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_wageHarness(viewOnly: false));
    await tester.pump();

    expect(
      find.byKey(const Key('settings_wage_setup_section')),
      findsOneWidget,
    );
    expect(find.text('Edit wage mix'), findsOneWidget);
  });

  testWidgets(
    'G — Data tab drops the section sub-paragraphs but keeps freshness '
    'rows and the data-alignment audit panel',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notifier = _notifier();
      await tester.pumpWidget(
        _wrap(
          notifier: notifier,
          child: SettingsScreen(
            initialStatus: AppDataStatus.current(),
            teamActor: _ffSupportActor,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byKey(const Key('settings_tab_data')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.byKey(
          const Key('settings_data_freshness_card'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(
        find.byType(SettingsAuditSection, skipOffstage: false),
        findsOneWidget,
      );

      expect(
        find.text(
          'See whether this device has the local data it needs.',
          skipOffstage: false,
        ),
        findsNothing,
      );
      expect(
        find.text(
          'Shows when shared restaurant data last updated on this device.',
          skipOffstage: false,
        ),
        findsNothing,
      );
    },
  );
}
