import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  group('VendorApplicabilityAdminScreen', () {
    testWidgets('loads wage rules and renders the friendly guide + chips', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast'),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_screen')),
        findsOneWidget,
      );
      // Operator-web vocabulary: the wage guide talks about "labor dollars".
      expect(find.textContaining('work out labor dollars'), findsOneWidget);
      // Friendly vendor display name (not the slug).
      expect(find.text('Toast'), findsOneWidget);
      // Allowed pill + compact scope text render.
      expect(find.text('Allowed'), findsWidgets);
      expect(find.text('All operators'), findsOneWidget);
      expect(gateway.listFilters.single.settingKind, 'wage');
      expect(gateway.listFilters.single.currentOnly, isFalse);
    });

    testWidgets('data freshness tab reloads with setting_kind=polling', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'polling', vendorSlug: 'agendrix'),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Data freshness'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('how often Forge & Flow checks'),
        findsOneWidget,
      );
      expect(gateway.listFilters.last.settingKind, 'polling');
    });

    testWidgets('friendly wage fields generate valid metadata on upsert', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway();

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_vendor_applicability_add')));
      await tester.pumpAndSettle();

      // Pick a vendor from the friendly dropdown (display names).
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('7shifts').last);
      await tester.pumpAndSettle();

      // Friendly wage authority -> generates authority_basis.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_wage_authority')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_wage_authority')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('By role (job code)').last);
      await tester.pumpAndSettle();

      // "Only count shifts that have a role" -> requires_job_code.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_requires_job_code')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_requires_job_code')),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-200 launch wage source',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      final command = gateway.upserts.single;
      expect(command.settingKind, 'wage');
      expect(command.settingKey, 'default');
      expect(command.vendorSlug, 'seven_shifts');
      expect(command.enabled, isTrue);
      expect(command.operatorId, isNull);
      expect(command.locationId, isNull);
      expect(command.metadata['authority_basis'], 'job_code');
      expect(command.metadata['requires_job_code'], isTrue);
      expect(command.adminReason, 'admin.vendor_applicability.upsert');
      expect(command.reasonNote, 'Ticket VA-200 launch wage source');
      expect(command.idempotencyKey, startsWith('admin-vendor-applicability-'));
    });

    testWidgets('per-location scope threads operator + location into upsert', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway();
      final operatorGateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[_operatorBundle()],
      );

      await tester.pumpWidget(
        wrap(
          VendorApplicabilityAdminScreen(
            gateway: gateway,
            operatorLocationGateway: operatorGateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_vendor_applicability_add')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('7shifts').last);
      await tester.pumpAndSettle();

      // Scope opens by default so location-scoped rules take fewer clicks.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_scope_location')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_scope_location')),
      );
      await tester.pumpAndSettle();

      // Operator dropdown -> business name.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_operator_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_operator_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Barrio Legado').last);
      await tester.pumpAndSettle();

      // Location dropdown -> location name.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_location_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_location_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('North Loop').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-210 per-location wage source',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      final command = gateway.upserts.single;
      expect(command.operatorId, _kOperatorId);
      expect(command.locationId, _kLocationId);
    });

    testWidgets(
      'location scope without an operator blocks submit (UI mirror of CHECK)',
      (tester) async {
        await _size(tester);
        final gateway = _FakeVendorApplicabilityAdminGateway();
        final operatorGateway = InMemoryOperatorLocationAdminGateway(
          seed: <OperatorAdminBundle>[_operatorBundle()],
        );

        await tester.pumpWidget(
          wrap(
            VendorApplicabilityAdminScreen(
              gateway: gateway,
              operatorLocationGateway: operatorGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_add')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7shifts').last);
        await tester.pumpAndSettle();

        // Scope opens by default; pick location without choosing an operator.
        await tester.ensureVisible(
          find.byKey(const Key('admin_vendor_applicability_scope_location')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_scope_location')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('admin_vendor_applicability_reason')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('admin_vendor_applicability_reason')),
          'Ticket VA-211 missing operator',
        );
        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_submit')),
        );
        await tester.pumpAndSettle();

        // No write happened; the dialog is still open with an error banner.
        expect(gateway.upserts, isEmpty);
        expect(
          find.byKey(const Key('admin_vendor_applicability_dialog_error')),
          findsOneWidget,
        );
      },
    );

    testWidgets('covers custom service-period chips feed metadata', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway();

      await tester.pumpWidget(
        wrap(
          VendorApplicabilityAdminScreen(
            gateway: gateway,
            initialSettingKind: 'covers',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_vendor_applicability_add')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('SevenRooms').last);
      await tester.pumpAndSettle();

      // "Which guests count?" -> cover_filter.
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_cover_filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_cover_filter')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('All guests').last);
      await tester.pumpAndSettle();

      // Add two service-period keys.
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_service_period_add')),
        'brunch',
      );
      await tester.ensureVisible(
        find.byKey(
          const Key('admin_vendor_applicability_service_period_button'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('admin_vendor_applicability_service_period_button'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_service_period_add')),
        'happy_hour',
      );
      await tester.ensureVisible(
        find.byKey(
          const Key('admin_vendor_applicability_service_period_button'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('admin_vendor_applicability_service_period_button'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-201 covers custom periods',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      final command = gateway.upserts.single;
      expect(command.settingKind, 'covers');
      expect(command.vendorSlug, 'sevenrooms');
      expect(command.metadata['cover_filter'], 'all_covers');
      expect(command.metadata['service_periods'], <String>[
        'brunch',
        'happy_hour',
      ]);
    });

    testWidgets('end action requires a reason and sends an end command', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast'),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_end_row-wage-toast')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason_note')),
        'End Toast while staging the new payroll source',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(gateway.ends, hasLength(1));
      final command = gateway.ends.single;
      expect(command.settingKind, 'wage');
      expect(command.settingKey, 'default');
      expect(command.vendorSlug, 'toast');
      expect(command.adminReason, 'admin.vendor_applicability.end');
      expect(
        command.reasonNote,
        'End Toast while staging the new payroll source',
      );
      expect(command.idempotencyKey, startsWith('admin-vendor-applicability-'));
    });

    testWidgets('history section reveals ended rules on tap', (tester) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast'),
          _row(
            settingKind: 'wage',
            vendorSlug: 'square',
            id: 'row-wage-square-old',
            effectiveUntil: DateTime.utc(2026, 5, 12, 15),
          ),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_history')),
        findsOneWidget,
      );
      // Collapsed by default: the ended row is not shown yet.
      expect(
        find.byKey(
          const Key('vendor_applicability_history_row-wage-square-old'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_history_toggle')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const Key('vendor_applicability_history_row-wage-square-old'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('read-only mode hides mutation actions', (tester) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast'),
        ]);

      await tester.pumpWidget(
        wrap(
          VendorApplicabilityAdminScreen(
            gateway: gateway,
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_readonly')),
        findsOneWidget,
      );
      final addButton = tester.widget<FilledButton>(
        find.byKey(const Key('admin_vendor_applicability_add')),
      );
      expect(addButton.onPressed, isNull);
      // Edit / End icon buttons are not rendered in read-only mode.
      expect(
        find.byKey(const Key('admin_vendor_applicability_edit_row-wage-toast')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_vendor_applicability_end_row-wage-toast')),
        findsNothing,
      );
    });
  });
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

const String _kOperatorId = '22222222-2222-4222-8222-222222222222';
const String _kLocationId = '33333333-3333-4333-8333-333333333333';

OperatorAdminBundle _operatorBundle() {
  final ts = DateTime.utc(2026, 5, 1);
  return OperatorAdminBundle(
    operator: OperatorAdminRecord(
      operatorId: _kOperatorId,
      businessName: 'Barrio Legado',
      ownerEmail: 'owner@example.com',
      subscriptionTier: 'standard',
      preferredCurrency: 'USD',
      primaryLocationId: _kLocationId,
      suspendedAt: null,
      createdAt: ts,
      updatedAt: ts,
    ),
    locations: <LocationAdminRecord>[
      LocationAdminRecord(
        locationId: _kLocationId,
        operatorId: _kOperatorId,
        name: 'North Loop',
        address: '',
        timezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        createdAt: ts,
        updatedAt: ts,
      ),
    ],
  );
}

VendorApplicabilityAdminRow _row({
  required String settingKind,
  required String vendorSlug,
  bool enabled = true,
  String? id,
  String? operatorId,
  String? locationId,
  DateTime? effectiveUntil,
}) {
  final now = DateTime.utc(2026, 5, 13, 15);
  return VendorApplicabilityAdminRow(
    id: id ?? 'row-$settingKind-$vendorSlug',
    operatorId: operatorId,
    locationId: locationId,
    settingKind: settingKind,
    settingKey: 'default',
    vendorSlug: vendorSlug,
    enabled: enabled,
    metadata: const <String, Object?>{'authority_basis': 'job_code'},
    effectiveFrom: now,
    effectiveUntil: effectiveUntil,
    createdAt: now,
    createdBy: 'admin-user',
  );
}

class _FakeVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  final List<VendorApplicabilityAdminFilter> listFilters =
      <VendorApplicabilityAdminFilter>[];
  final List<VendorApplicabilityUpsertCommand> upserts =
      <VendorApplicabilityUpsertCommand>[];
  final List<VendorApplicabilityEndCommand> ends =
      <VendorApplicabilityEndCommand>[];
  final List<VendorApplicabilityAdminRow> _rows =
      <VendorApplicabilityAdminRow>[];

  void seed(Iterable<VendorApplicabilityAdminRow> rows) {
    _rows
      ..clear()
      ..addAll(rows);
  }

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    listFilters.add(filter);
    return _rows
        .where(
          (row) =>
              filter.settingKind == null ||
              row.settingKind == filter.settingKind,
        )
        .toList(growable: false);
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) async {
    upserts.add(command);
    final row = _row(
      settingKind: command.settingKind,
      vendorSlug: command.vendorSlug,
      enabled: command.enabled,
      operatorId: command.operatorId,
      locationId: command.locationId,
    );
    _rows
      ..removeWhere(
        (existing) =>
            existing.settingKind == command.settingKind &&
            existing.settingKey == command.settingKey &&
            existing.vendorSlug == command.vendorSlug &&
            existing.operatorId == command.operatorId &&
            existing.locationId == command.locationId,
      )
      ..add(row);
    return row;
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) async {
    ends.add(command);
    return null;
  }
}
