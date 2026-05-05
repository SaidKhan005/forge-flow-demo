import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/data_accuracy_audit_history_panel.dart';
import 'package:forge_and_flow/admin/widgets/per_location_data_accuracy_table.dart';
import 'package:forge_and_flow/admin/widgets/per_location_tier_assignment_table.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
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

        expect(find.text('Applied data accuracy override'), findsOneWidget);
        expect(find.text('Actor: Forge & Flow admin'), findsOneWidget);
        expect(
          find.text('Event key: admin.data_accuracy.override'),
          findsOneWidget,
        );
        expect(
          find.text('User ID: 90000000-0000-0000-0000-000000000003'),
          findsOneWidget,
        );
        expect(
          find.text('Covers source - lunch: Vendor feed -> Manual entry'),
          findsOneWidget,
        );
        expect(
          find.text('Wage source: Vendor wage data -> Manual mix'),
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

        expect(find.text('Covers source'), findsOneWidget);
        expect(
          find.text(
            'Covers are shown as lunch / dinner / late night. '
            'Scroll sideways for override history and actions.',
          ),
          findsOneWidget,
        );
        expect(find.text('Vendor / Vendor / Vendor'), findsOneWidget);
        expect(find.text('Vendor'), findsOneWidget);
        expect(find.text('No override yet'), findsOneWidget);
        expect(find.textContaining('1969'), findsNothing);
        expect(find.textContaining('1970'), findsNothing);
      },
    );

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
      expect(
        find.text(
          'Use the filters to narrow operator locations. Scroll sideways '
          'for price, cost, margin, notes, and assignment actions.',
        ),
        findsOneWidget,
      );
    });
  });
}
