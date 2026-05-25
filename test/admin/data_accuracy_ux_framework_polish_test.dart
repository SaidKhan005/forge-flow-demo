import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/admin_shell.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/data_accuracy_audit_history_panel.dart';
import 'package:forge_and_flow/admin/widgets/per_location_data_accuracy_table.dart';
import 'package:forge_and_flow/admin/widgets/per_location_tier_assignment_table.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
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
  const ref2 = OperatorLocationRef(
    operatorId: 'op-1',
    businessName: 'Barrio Legado',
    locationId: 'loc-2',
    locationName: 'Duckworth Street',
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
                title: 'Covers and Wage Data Accuracy',
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
                  actorDisplayName: 'Amira Chen',
                  actorRole: 'Super admin',
                  actorEmail: 'amira@forgeflow.app',
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
        expect(
          find.text('Actor: Amira Chen - Super admin - amira@forgeflow.app'),
          findsOneWidget,
        );
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

    testWidgets(
      'R7c: a NEW per-period (service_period_override) audit row renders '
      'with human labels, AND a legacy-keyed row still renders '
      '(additive reconciliation, not a swap)',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            DataAccuracyAuditHistoryPanel(
              events: <DataAccuracyAdminAuditEvent>[
                // New per-period audit shape (R7a/R7b/R7c): the
                // service_period_override event keys the diff by
                // service_period_key + covers_source.
                DataAccuracyAdminAuditEvent(
                  eventId: 'audit-per-period-1',
                  eventType: 'admin.data_accuracy.service_period_override',
                  occurredAt: DateTime.utc(2026, 5, 6, 12),
                  actorUserId: '90000000-0000-0000-0000-000000000004',
                  actorDisplayName: 'Amira Chen',
                  actorRole: 'Super admin',
                  actorEmail: 'amira@forgeflow.app',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  diff: const <String, Object?>{
                    'service_period_key': 'dinner',
                    'covers_source': <String, String>{
                      'from': 'vendor',
                      'to': 'manual',
                    },
                  },
                  reasonNote: 'Dinner switched to manual entry.',
                ),
                // Legacy-keyed historical row must still render.
                DataAccuracyAdminAuditEvent(
                  eventId: 'audit-legacy-1',
                  eventType: 'admin.data_accuracy.override',
                  occurredAt: DateTime.utc(2026, 5, 5, 12),
                  actorUserId: '90000000-0000-0000-0000-000000000003',
                  actorDisplayName: 'Amira Chen',
                  actorRole: 'Super admin',
                  actorEmail: 'amira@forgeflow.app',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  diff: const <String, Object?>{
                    'covers_source_lunch': <String, String>{
                      'from': 'vendor',
                      'to': 'manual',
                    },
                  },
                  reasonNote: 'Corrected a stale vendor import.',
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('admin_data_accuracy_audit_toggle')),
        );
        await tester.pumpAndSettle();

        // New per-period row renders with a human label and the
        // service period stated.
        expect(
          find.text('Changed Covers source from Vendor feed to Manual entry'),
          findsOneWidget,
        );
        expect(find.text('Set Service period to dinner'), findsOneWidget);
        // Legacy-keyed historical row still renders unchanged.
        expect(
          find.text(
            'Changed Covers source - lunch from Vendor feed to Manual entry',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'data accuracy table does not show epoch dates for empty rows',
      (tester) async {
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
                    coversSourcePerServicePeriod:
                        const <String, CoversSource>{},
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

        expect(find.text('Service periods'), findsOneWidget);
        expect(find.text('Vendor default'), findsOneWidget);
        expect(find.text('Lunch'), findsNothing);
        expect(find.text('Dinner'), findsNothing);
        expect(find.text('Late night'), findsNothing);
        expect(find.text('Covers and wage data accuracy'), findsOneWidget);
        expect(find.textContaining('Covers are shown as'), findsNothing);
        expect(find.text('Vendor'), findsWidgets);
        expect(find.text('No override yet'), findsOneWidget);
        expect(find.textContaining('1969'), findsNothing);
        expect(find.textContaining('1970'), findsNothing);
      },
    );

    testWidgets(
      'data accuracy table uses configured service-period labels for defaults',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        await tester.pumpWidget(
          wrap(
            PerLocationDataAccuracyTable(
              rows: <DataAccuracyAdminRow>[
                DataAccuracyAdminRow(
                  operatorRef: ref,
                  configuredServicePeriods: const <ServicePeriodDefinition>[
                    ServicePeriodDefinition(
                      id: 'breakfast_service',
                      label: 'Breakfast service',
                      shortLabel: 'B',
                      sortOrder: 1,
                      startLocalTime: '08:00',
                      endLocalTime: '11:00',
                      rollsPastMidnight: false,
                      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                    ),
                    ServicePeriodDefinition(
                      id: 'late_service',
                      label: 'Late service',
                      shortLabel: 'L',
                      sortOrder: 2,
                      startLocalTime: '21:00',
                      endLocalTime: '01:00',
                      rollsPastMidnight: true,
                      applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
                    ),
                  ],
                  settings: DataAccuracySettings(
                    settingId: 'default:op-1:loc-1',
                    operatorId: 'op-1',
                    locationId: 'loc-1',
                    coversSourcePerServicePeriod:
                        const <String, CoversSource>{},
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

        expect(find.text('Breakfast service'), findsOneWidget);
        expect(find.text('Late service'), findsOneWidget);
        expect(find.text('Service periods'), findsNothing);
        expect(find.text('Lunch'), findsNothing);
        expect(find.text('Dinner'), findsNothing);
        expect(find.text('Late night'), findsNothing);
      },
    );

    testWidgets('data accuracy table shows server source labels', (
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
                  settingId: 'source-row',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  coversSourcePerServicePeriod: const <String, CoversSource>{
                    'breakfast': CoversSource.manual,
                  },
                  coversSourcePerServicePeriodSources:
                      const <String, DataAccuracySettingSource>{
                        'breakfast': DataAccuracySettingSource(
                          scopeType: 'business',
                          sourceKind: 'scoped_override',
                          overrideId: 'ovr-breakfast',
                        ),
                      },
                  coversManualEntries: const <String, Map<String, int>>{},
                  wageSource: WageSource.vendor,
                  wageSourceSource: const DataAccuracySettingSource(
                    scopeType: 'org_unit',
                    sourceKind: 'scoped_override',
                    overrideId: 'ovr-wage',
                  ),
                  walkInHandlingModeSource: const DataAccuracySettingSource(
                    scopeType: 'default',
                    sourceKind: 'default',
                  ),
                  createdAt: DateTime.utc(2026, 5, 1),
                  updatedAt: DateTime.utc(2026, 5, 1),
                ),
              ),
            ],
            editingEnabled: false,
            onEditRow: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Source: Business'), findsOneWidget);
      expect(find.text('Source: Org unit'), findsOneWidget);
      expect(find.text('Source: Default'), findsNothing);
    });

    testWidgets('service-period rows use effective source label', (
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
                  settingId: 'effective-row',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  coversSourcePerServicePeriod: const <String, CoversSource>{
                    'breakfast': CoversSource.manual,
                  },
                  coversSourcePerServicePeriodSources:
                      const <String, DataAccuracySettingSource>{
                        'breakfast': DataAccuracySettingSource(
                          scopeType: 'business',
                          sourceKind: 'scoped_override',
                          overrideId: 'ovr-breakfast',
                        ),
                      },
                  coversManualEntries: const <String, Map<String, int>>{},
                  wageSource: WageSource.vendor,
                  createdAt: DateTime.utc(2026, 5, 1),
                  updatedAt: DateTime.utc(2026, 5, 1),
                ),
                servicePeriodSettings: <DataAccuracyServicePeriodSetting>[
                  DataAccuracyServicePeriodSetting(
                    id: 'period-breakfast',
                    operatorId: 'op-1',
                    locationId: 'loc-1',
                    servicePeriodKey: 'breakfast',
                    coversSource: ServicePeriodCoversSource.forecast,
                    wageSource: ServicePeriodWageSource.targetSubstitution,
                    coversSourceSource: const DataAccuracySettingSource(
                      scopeType: 'location',
                      sourceKind: 'service_period_setting',
                      scopeId: 'loc-1',
                      settingId: 'period-breakfast',
                    ),
                    effectiveAtBusinessDate: '2026-05-20',
                    createdAt: DateTime.utc(2026, 5, 20),
                    updatedAt: DateTime.utc(2026, 5, 20),
                  ),
                ],
              ),
            ],
            editingEnabled: false,
            onEditRow: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Source: Business'), findsOneWidget);
      expect(find.text('Source: Location setting'), findsNothing);
    });

    testWidgets('data accuracy table filters rows using vendor source', (
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
                  settingId: 'vendor-row',
                  operatorId: 'op-1',
                  locationId: 'loc-1',
                  coversSourcePerServicePeriod: const <String, CoversSource>{},
                  coversManualEntries: const <String, Map<String, int>>{},
                  wageSource: WageSource.vendor,
                  createdAt: DateTime.utc(2026, 5, 1),
                  updatedAt: DateTime.utc(2026, 5, 1),
                ),
              ),
              DataAccuracyAdminRow(
                operatorRef: ref2,
                settings: DataAccuracySettings(
                  settingId: 'manual-row',
                  operatorId: 'op-1',
                  locationId: 'loc-2',
                  coversSourcePerServicePeriod: const <String, CoversSource>{
                    'lunch': CoversSource.manual,
                    'dinner': CoversSource.forecast,
                    'late_night': CoversSource.manual,
                  },
                  coversManualEntries: const <String, Map<String, int>>{},
                  wageSource: WageSource.manualMix,
                  createdAt: DateTime.utc(2026, 5, 1),
                  updatedAt: DateTime.utc(2026, 5, 1),
                ),
              ),
            ],
            editingEnabled: false,
            onEditRow: (_) {},
            vendorSourceFilter: 'manual_or_forecast',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Vendor data'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_data_accuracy_vendor_source_filter')),
        findsOneWidget,
      );
      expect(find.text('Duckworth Street'), findsOneWidget);
      expect(find.text('95 Water Street'), findsNothing);
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

    testWidgets('tier assignment rows show effective tier defaults', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final now = DateTime.utc(2026, 5, 20, 12);

      await tester.pumpWidget(
        wrap(
          PerLocationTierAssignmentTable(
            rows: <TierAssignmentAdminRow>[
              TierAssignmentAdminRow(
                operatorRef: ref,
                assignment: ForgeFlowPollingTierAssignment(
                  assignmentId: 'assignment-1',
                  operatorId: ref.operatorId,
                  locationId: ref.locationId,
                  tierKey: PollingTierKey.standard,
                  pollingCadencePerVendorSeconds: const <String, int>{},
                  effectiveAt: now,
                  createdAt: now,
                ),
              ),
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

      expect(find.text('Tier default: \$99.00'), findsOneWidget);
      expect(find.text('Tier default: \$12.00'), findsOneWidget);
      expect(find.text('Tier default: 300s'), findsOneWidget);
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

    testWidgets('polling setup filters rows by polling vendor', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final now = DateTime.utc(2026, 5, 5, 12);
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref, ref2],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
        initialAssignments: <String, ForgeFlowPollingTierAssignment>{
          'op-1/loc-1': ForgeFlowPollingTierAssignment(
            assignmentId: 'a-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            tierKey: PollingTierKey.custom,
            pollingCadencePerVendorSeconds: const <String, int>{
              'quickbooks_time': 300,
            },
            monthlyPriceCents: 1900,
            vendorApiCostEstimateCentsMonthly: 500,
            effectiveAt: now,
            createdAt: now,
          ),
          'op-1/loc-2': ForgeFlowPollingTierAssignment(
            assignmentId: 'a-2',
            operatorId: 'op-1',
            locationId: 'loc-2',
            tierKey: PollingTierKey.custom,
            pollingCadencePerVendorSeconds: const <String, int>{
              'oracle_micros_simphony': 300,
            },
            monthlyPriceCents: 1900,
            vendorApiCostEstimateCentsMonthly: 500,
            effectiveAt: now,
            createdAt: now,
          ),
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

      expect(find.text('95 Water Street'), findsOneWidget);
      expect(find.text('Duckworth Street'), findsOneWidget);

      // The filter controls row sits below the fold on the test surface, so
      // the vendor-filter dropdown button itself renders off-screen. A real
      // user scrolls down to it; mirror that here so the open tap is a
      // deterministic on-screen hit instead of an off-screen miss.
      final vendorFilterDropdown = find.byKey(
        const Key('admin_polling_vendor_filter_dropdown'),
      );
      await tester.ensureVisible(vendorFilterDropdown);
      await tester.pumpAndSettle();
      await tester.tap(vendorFilterDropdown);
      await tester.pumpAndSettle();
      // The opened menu is anchored as a full-screen overlay; ensure the
      // target item is on-screen before tapping it too.
      final quickBooksItem = find.text('QuickBooks Time').last;
      await tester.ensureVisible(quickBooksItem);
      await tester.pumpAndSettle();
      await tester.tap(quickBooksItem);
      await tester.pumpAndSettle();

      expect(find.text('QuickBooks Time'), findsWidgets);
      expect(find.text('95 Water Street'), findsOneWidget);
      expect(find.text('Duckworth Street'), findsNothing);
    });

    testWidgets('polling setup overview and requests use admin labels', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final now = DateTime.utc(2026, 5, 5, 12);
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
        initialAssignments: <String, ForgeFlowPollingTierAssignment>{
          'op-1/loc-1': ForgeFlowPollingTierAssignment(
            assignmentId: 'a-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            tierKey: PollingTierKey.standard,
            pollingCadencePerVendorSeconds: const <String, int>{},
            monthlyPriceCents: 9900,
            vendorApiCostEstimateCentsMonthly: 1200,
            effectiveAt: now,
            createdAt: now,
          ),
        },
        initialChangeRequests: <TierChangeRequest>[
          TierChangeRequest(
            requestId: 'req-1',
            operatorRef: ref,
            currentTier: PollingTierKey.standard,
            requestedTier: PollingTierKey.premium,
            operatorNote: 'Dinner volume needs fresher data.',
            submittedAt: now,
            status: TierChangeRequestStatus.pending,
          ),
        ],
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

      expect(
        find.byKey(const Key('admin_polling_setup_overview_panel')),
        findsOneWidget,
      );
      expect(find.text('Locations shown'), findsOneWidget);
      expect(find.text('Assigned'), findsOneWidget);
      expect(find.text('Pending requests'), findsOneWidget);
      expect(find.text('Monthly margin'), findsOneWidget);
      expect(find.text('Tier change: Regular to Premium'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);

      final overviewY = tester
          .getTopLeft(
            find.byKey(const Key('admin_polling_setup_overview_panel')),
          )
          .dy;
      final assignmentsY = tester
          .getTopLeft(find.byKey(const Key('admin_tier_assignment_table')))
          .dy;
      expect(overviewY, lessThan(assignmentsY));
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

      expect(find.text('Regular'), findsWidgets);
      expect(find.text('standard'), findsNothing);
    });

    // Removed 2026-05-24: 'Operators can hand off a location to the new
    // Operations tabs' drove the Data Accuracy + Polling/Pricing handoff
    // through the `admin_business_setup_tile_data_accuracy` /
    // `_polling_pricing` drill-in tiles, which the Business-accounts
    // scope-pane rebuild deleted. That location handoff now lives in the
    // always-on admin sidebar cluster and is covered by
    // `admin_shell_widget_test.dart`; the screen's
    // `onOpenDataAccuracyScope` / `onOpenPollingPricingScope` callbacks are
    // no longer triggered from within this screen.
  });
}
