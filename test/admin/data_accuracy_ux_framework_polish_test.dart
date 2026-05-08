import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/operator_location_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/data_accuracy_audit_history_panel.dart';
import 'package:forge_and_flow/admin/widgets/per_location_data_accuracy_table.dart';
import 'package:forge_and_flow/admin/widgets/per_location_tier_assignment_table.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  const ref = OperatorLocationRef(
    operatorId: 'op-1',
    businessName: 'Barrio Legado',
    locationId: 'loc-1',
    locationName: '95 Water Street',
  );

  group('Data Accuracy / Polling UX framework polish', () {
    testWidgets('Data accuracy moves under Operations with a WIP route badge', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: AdminShell(
            session: const AdminAuthSession(
              uid: 'demo-super-admin',
              email: 'super.admin@forgeflow.test',
              displayName: 'Demo Super Admin',
              roles: <String>['super_admin'],
            ),
            authSource: DemoAdminAuthSource.signedInAsSuperAdmin(),
            initialRouteId: 'ai-placeholder',
            routes: <AdminRoute>[
              AdminRoute(
                id: 'ai-placeholder',
                title: 'Plans and limits',
                path: '/plans',
                icon: Icons.tune,
                section: AdminRouteSection.ai,
                placeholder: true,
                builder: (_) => const SizedBox.shrink(),
              ),
              AdminRoute(
                id: 'data-placeholder',
                title: 'Data accuracy',
                path: '/data-accuracy',
                icon: Icons.fact_check_outlined,
                section: AdminRouteSection.operations,
                badge: 'Work in progress',
                placeholder: true,
                builder: (_) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_nav_section_panel_operations')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_section_panel_ai')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_section_icon_operations')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_section_divider_operations')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_section_count_operations')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_section_badge_ai')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_nav_section_dataAccuracy')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_nav_item_badge_data-placeholder')),
        findsOneWidget,
      );
      expect(find.text('Work in progress'), findsNWidgets(2));
    });

    testWidgets(
      'audit rows lead with human labels and keep raw keys secondary',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            DataAccuracyAuditHistoryPanel(
              events: <DataAccuracyAdminAuditEvent>[
                DataAccuracyAdminAuditEvent(
                  eventId: 'audit-1',
                  eventType: 'admin.data_accuracy.override',
                  occurredAt: DateTime.utc(2026, 5, 5, 12),
                  actorUserId: '90000000-0000-0000-0000-000000000003',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  diff: const <String, Object?>{
                    'covers_source_lunch': <String, String>{
                      'from': 'vendor',
                      'to': 'manual',
                    },
                    'wage_source': <String, String>{
                      'from': 'vendor',
                      'to': 'manual_mix',
                    },
                  },
                  reasonNote: 'Corrected a stale vendor import.',
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('1 event'), findsOneWidget);
        expect(find.text('Show history'), findsOneWidget);
        expect(find.text('Applied data accuracy override'), findsNothing);
        expect(
          find.text('Event key: admin.data_accuracy.override'),
          findsNothing,
        );
        expect(
          find.text('User ID: 90000000-0000-0000-0000-000000000003'),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const Key('admin_data_accuracy_audit_toggle')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Applied data accuracy override'), findsOneWidget);
        expect(find.text('Actor: Forge & Flow admin'), findsOneWidget);
        expect(
          find.text('Event key: admin.data_accuracy.override'),
          findsNothing,
        );
        expect(
          find.text('User ID: 90000000-0000-0000-0000-000000000003'),
          findsNothing,
        );
        expect(
          find.text(
            'Changed Covers source - lunch from Vendor feed to Manual entry',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Changed Wage source from Vendor wage data to Manual mix'),
          findsOneWidget,
        );
      },
    );

    testWidgets('data accuracy table does not show epoch dates for empty rows', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyTable(
            rows: <DataAccuracyAdminRow>[
              DataAccuracyAdminRow(
                operatorRef: ref,
                settings: DataAccuracySettings(
                  settingId: 'default:op-1:loc-1',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  coversSourceLunch: CoversSource.vendor,
                  coversSourceDinner: CoversSource.vendor,
                  coversSourceLateNight: CoversSource.vendor,
                  coversManualEntries: const <String, Map<String, int>>{},
                  wageSource: WageSource.vendor,
                  createdAt: DateTime.utc(1970),
                  updatedAt: DateTime.utc(1970),
                ),
              ),
            ],
            editingEnabled: false,
            onEditRow: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Late night'), findsOneWidget);
      expect(
        find.text(
          'Covers are shown as lunch, dinner, and late night so support can scan each location without moving sideways.',
        ),
        findsOneWidget,
      );
      expect(find.text('Vendor'), findsWidgets);
      expect(find.text('No override yet'), findsOneWidget);
      expect(find.textContaining('1969'), findsNothing);
      expect(find.textContaining('1970'), findsNothing);
    });

    testWidgets('tier assignment filters use operator-safe wording', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        wrap(
          PerLocationTierAssignmentTable(
            rows: const <TierAssignmentAdminRow>[
              TierAssignmentAdminRow(operatorRef: ref, assignment: null),
            ],
            tierDefinitions: <TierDefinition>[
              kDemoStandardTierDefinition(),
              kDemoPremiumTierDefinition(),
              kDemoCustomTierDefinition(),
            ],
            editingEnabled: false,
            onAssign: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Operator location count'), findsOneWidget);
      expect(find.text('All location counts'), findsOneWidget);
      expect(find.text('Location count'), findsNothing);
      expect(find.text('All operators'), findsNothing);
      expect(find.text('Not assigned'), findsOneWidget);
      expect(find.text('Not assigned yet'), findsOneWidget);
      expect(find.text('Tier default'), findsWidgets);
      expect(find.text('Not calculated'), findsOneWidget);
      expect(find.text('No notes'), findsOneWidget);
      expect(
        find.text(
          'Use filters to narrow operator locations. Each row keeps tier, cadence, pricing, margin, and notes together.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('tier assignment filters can be cleared in one action', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      PollingTierKey? tierFilter = PollingTierKey.standard;
      var cleared = false;

      await tester.pumpWidget(
        wrap(
          StatefulBuilder(
            builder: (context, setState) {
              return PerLocationTierAssignmentTable(
                rows: const <TierAssignmentAdminRow>[
                  TierAssignmentAdminRow(operatorRef: ref, assignment: null),
                ],
                tierDefinitions: <TierDefinition>[
                  kDemoStandardTierDefinition(),
                  kDemoPremiumTierDefinition(),
                  kDemoCustomTierDefinition(),
                ],
                editingEnabled: false,
                onAssign: (_) {},
                tierFilter: tierFilter,
                onTierFilterChanged: (value) => setState(() {
                  tierFilter = value;
                  cleared = value == null;
                }),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_tier_assignment_clear_filters')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('admin_tier_assignment_clear_filters')),
      );
      await tester.pumpAndSettle();

      expect(cleared, isTrue);
      expect(
        find.byKey(const Key('admin_tier_assignment_clear_filters')),
        findsNothing,
      );
    });

    testWidgets('tier assignment dialog uses human tier labels', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: Scaffold(
            body: PollingAndPricingAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_tier_assignment_assign_op-1_loc-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Standard'), findsWidgets);
      expect(find.text('standard'), findsNothing);
    });

    testWidgets(
      'Operators can hand off a location to the new Operations tabs',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final scopes = <AdminHierarchyScopeIntent>[];
        final gateway = InMemoryOperatorLocationAdminGateway(
          seed: <OperatorAdminBundle>[
            OperatorAdminBundle(
              operator: OperatorAdminRecord(
                operatorId: 'op-1',
                businessName: 'Barrio Legado',
                ownerEmail: 'owner@barrio.test',
                subscriptionTier: 'launch',
                preferredCurrency: 'CAD',
                primaryLocationId: 'loc-1',
                suspendedAt: null,
                createdAt: DateTime.utc(2026, 1, 1),
                updatedAt: DateTime.utc(2026, 1, 1),
              ),
              locations: <LocationAdminRecord>[
                LocationAdminRecord(
                  locationId: 'loc-1',
                  operatorId: 'op-1',
                  name: '95 Water Street',
                  address: '',
                  timezone: 'America/St_Johns',
                  businessDayRolloverHour: 4,
                  createdAt: DateTime.utc(2026, 1, 1),
                  updatedAt: DateTime.utc(2026, 1, 1),
                ),
              ],
            ),
          ],
        );

        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.themeData,
            home: Scaffold(
              body: OperatorLocationAdminScreen(
                gateway: gateway,
                onOpenDataAccuracyScope: scopes.add,
                onOpenPollingPricingScope: scopes.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final locationScope = find.byKey(
          const Key('admin_hierarchy_location_loc-1'),
        );
        await tester.ensureVisible(locationScope);
        await tester.tap(locationScope);
        await tester.pumpAndSettle();

        final dataAccuracyAction = find.byKey(
          const Key('admin_business_setup_tile_data_accuracy'),
        );
        await tester.ensureVisible(dataAccuracyAction);
        await tester.tap(dataAccuracyAction);
        await tester.pumpAndSettle();

        final pollingPricingAction = find.byKey(
          const Key('admin_business_setup_tile_polling_pricing'),
        );
        await tester.ensureVisible(pollingPricingAction);
        await tester.tap(pollingPricingAction);
        await tester.pumpAndSettle();

        expect(scopes, hasLength(2));
        expect(scopes.first.operatorId, 'op-1');
        expect(scopes.first.locationId, 'loc-1');
        expect(scopes.first.displayLabel, 'Barrio Legado / 95 Water Street');
        expect(scopes.last.locationId, 'loc-1');
        expect(scopes.last.inheritanceLabel, 'Location only');
      },
    );
  });
}
