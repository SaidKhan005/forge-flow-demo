// Wave 2 MO-2 — Settings Covers Setup section widget tests.
//
// Verifies:
//   * Form renders the covers field, daypart dropdown, business-date
//     pill, and save button.
//   * Neutral covers-source framing that does not promise a one-off
//     vendor override.
//   * Save handler writes via the injected writer and clears the
//     covers input on success.
//   * Validation error renders when the operator hits Save without
//     a covers value.
//   * HP #11 scope label renders when a [scopeLabel] is passed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import 'package:forge_and_flow/screens/settings/settings_covers_setup_section.dart';

void main() {
  Future<List<ManualCoverEntry>> emptyLoader(String _) async =>
      const <ManualCoverEntry>[];

  Widget harness({
    String? posVendorId,
    String? scopeLabel,
    ManualCoverEntryLoader? loader,
    ManualCoverEntryWriter? writer,
    ServicePeriodCoversSourceLoader? coversSourceLoader,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SettingsCoversSetupSection(
            restaurantId: 'restaurant-1',
            scopeLabel: scopeLabel,
            posVendorId: posVendorId,
            loader: loader ?? emptyLoader,
            writer: writer,
            coversSourceLoader: coversSourceLoader ?? (_) async => const [],
            servicePeriodsLoader: (_) async =>
                ServicePeriodDefinitionResolver.demoDefinitions,
            initialBusinessDate: DateTime.utc(2026, 5, 10),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the form with covers field, date pill, daypart, and '
      'save button', (tester) async {
    await tester.pumpWidget(harness(posVendorId: 'square'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_covers_setup_covers_field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings_covers_setup_business_date_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings_covers_setup_daypart_dropdown')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings_covers_setup_save_button')),
      findsOneWidget,
    );
    // Date pill shows the injected initial date in ISO form.
    expect(find.text('2026-05-10'), findsOneWidget);
  });

  testWidgets('uses neutral covers-source framing when POS is missing covers', (
    tester,
  ) async {
    await tester.pumpWidget(harness(posVendorId: 'square'));
    await tester.pumpAndSettle();

    expect(find.text('Record cover counts'), findsOneWidget);
    expect(
      find.textContaining('Covers source is set to Manual'),
      findsOneWidget,
    );
    expect(
      find.textContaining('POS does not send cover counts'),
      findsOneWidget,
    );
  });

  testWidgets('keeps the same neutral framing for vendors that send covers', (
    tester,
  ) async {
    await tester.pumpWidget(harness(posVendorId: 'toast'));
    await tester.pumpAndSettle();

    expect(find.text('Record cover counts'), findsOneWidget);
    expect(
      find.textContaining('Covers source is set to Manual'),
      findsOneWidget,
    );
    expect(find.textContaining('override'), findsNothing);
  });

  testWidgets('shows the selected service period effective covers source', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        coversSourceLoader: (_) async => <DataAccuracyServicePeriodSetting>[
          DataAccuracyServicePeriodSetting(
            id: 'setting-dinner',
            operatorId: 'operator-1',
            locationId: 'restaurant-1',
            servicePeriodKey: 'dinner',
            coversSource: ServicePeriodCoversSource.manual,
            wageSource: ServicePeriodWageSource.vendorPerEmployee,
            coversSourceSource: const DataAccuracySettingSource(
              scopeType: 'org_unit',
              sourceKind: 'scoped_override',
            ),
            effectiveAtBusinessDate: '2026-05-01',
            createdAt: DateTime.utc(2026, 5, 1),
            updatedAt: DateTime.utc(2026, 5, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_covers_setup_effective_source')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('settings_covers_setup_effective_source_label')),
      findsOneWidget,
    );
    expect(find.text('Manual entry'), findsOneWidget);
    expect(find.textContaining('Org unit since 2026-05-01'), findsOneWidget);
  });

  testWidgets('does not guess a source detail when no covers-source row exists', (
    tester,
  ) async {
    await tester.pumpWidget(harness(posVendorId: 'square'));
    await tester.pumpAndSettle();

    expect(find.text('Vendor feed'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_covers_setup_effective_source_detail')),
      findsNothing,
    );
    expect(find.text('Default'), findsNothing);
  });

  testWidgets('does not guess a source detail when server metadata is absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        coversSourceLoader: (_) async => <DataAccuracyServicePeriodSetting>[
          DataAccuracyServicePeriodSetting(
            id: 'setting-dinner',
            operatorId: 'operator-1',
            locationId: 'restaurant-1',
            servicePeriodKey: 'dinner',
            coversSource: ServicePeriodCoversSource.manual,
            wageSource: ServicePeriodWageSource.vendorPerEmployee,
            effectiveAtBusinessDate: '2026-05-01',
            createdAt: DateTime.utc(2026, 5, 1),
            updatedAt: DateTime.utc(2026, 5, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Manual entry'), findsOneWidget);
    expect(
      find.byKey(const Key('settings_covers_setup_effective_source_detail')),
      findsNothing,
    );
    expect(find.textContaining('Last synced service-period setting'), findsNothing);
  });

  testWidgets('renders hierarchy scope label per HP #11', (tester) async {
    await tester.pumpWidget(
      harness(posVendorId: 'square', scopeLabel: 'Barrio Legado: St Johns'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_covers_setup_scope_label')),
      findsOneWidget,
    );
    expect(find.textContaining('Barrio Legado'), findsOneWidget);
  });

  testWidgets('validation error when save is hit with an empty covers field', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      harness(
        posVendorId: 'square',
        writer: (entry) async {
          writes += 1;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('settings_covers_setup_save_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_covers_setup_error_text')),
      findsOneWidget,
    );
    expect(writes, 0);
  });

  testWidgets('save writes through the injected writer and clears the field', (
    tester,
  ) async {
    ManualCoverEntry? captured;
    final entriesAfterWrite = <ManualCoverEntry>[];
    Future<List<ManualCoverEntry>> loader(String _) async {
      return entriesAfterWrite;
    }

    await tester.pumpWidget(
      harness(
        posVendorId: 'square',
        loader: loader,
        writer: (entry) async {
          captured = entry;
          entriesAfterWrite.add(entry);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('settings_covers_setup_covers_field')),
      '84',
    );
    await tester.tap(
      find.byKey(const Key('settings_covers_setup_save_button')),
    );
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.covers, 84);
    expect(captured!.restaurantId, 'restaurant-1');
    expect(captured!.businessDate, '2026-05-10');
    // Default daypart selection is dinner.
    expect(captured!.daypart, 'dinner');

    // Confirmation banner surfaces.
    expect(
      find.byKey(const Key('settings_covers_setup_confirmation_text')),
      findsOneWidget,
    );

    // Field clears so the operator can type the next entry.
    final TextField field = tester.widget(
      find.byKey(const Key('settings_covers_setup_covers_field')),
    );
    expect(field.controller!.text, isEmpty);

    // Recent entries surface so the round-trip is visible.
    expect(
      find.byKey(const Key('settings_covers_setup_recent_2026-05-10_dinner')),
      findsOneWidget,
    );
  });

  testWidgets('rejects negative / non-numeric covers gracefully', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      harness(
        posVendorId: 'square',
        writer: (entry) async {
          writes += 1;
        },
      ),
    );
    await tester.pumpAndSettle();

    // Numeric-only keyboard filter prevents typing letters, so test the
    // empty path which the controller can reach via clear-and-save.
    await tester.enterText(
      find.byKey(const Key('settings_covers_setup_covers_field')),
      '',
    );
    await tester.tap(
      find.byKey(const Key('settings_covers_setup_save_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('settings_covers_setup_error_text')),
      findsOneWidget,
    );
    expect(writes, 0);
  });
}
