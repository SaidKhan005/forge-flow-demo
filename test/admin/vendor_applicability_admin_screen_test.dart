import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  group('VendorApplicabilityAdminScreen', () {
    testWidgets('loads wage rows and renders the plain-English prompt', (
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
      expect(
        find.text('Which vendors can act as the wage source?'),
        findsOneWidget,
      );
      expect(find.text('toast'), findsOneWidget);
      expect(gateway.listFilters.single.settingKind, 'wage');
      expect(gateway.listFilters.single.currentOnly, isFalse);
    });

    testWidgets('switching to covers tab reloads with setting_kind=covers', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'covers', vendorSlug: 'libro'),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Covers'));
      await tester.pumpAndSettle();

      expect(
        find.text('Which vendors can act as the covers source?'),
        findsOneWidget,
      );
      expect(gateway.listFilters.last.settingKind, 'covers');
    });

    testWidgets('add dialog validates metadata schema and upserts row', (
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

      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_vendor_slug')),
        'toast',
      );
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_metadata')),
        '{"authority_basis":"job_code","requires_job_code":true}',
      );
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
      expect(command.vendorSlug, 'toast');
      expect(command.enabled, isTrue);
      expect(command.metadata['authority_basis'], 'job_code');
      expect(command.adminReason, 'admin.vendor_applicability.upsert');
      expect(command.reasonNote, 'Ticket VA-200 launch wage source');
      expect(command.idempotencyKey, startsWith('admin-vendor-applicability-'));
    });

    testWidgets('covers add dialog accepts custom service-period keys', (
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

      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_vendor_slug')),
        'sevenrooms',
      );
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_metadata')),
        '{"cover_filter":"all_covers","service_periods":["brunch","happy_hour"]}',
      );
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-201 covers source custom periods',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      final command = gateway.upserts.single;
      expect(command.settingKind, 'covers');
      expect(command.vendorSlug, 'sevenrooms');
      expect(command.metadata['service_periods'], <String>[
        'brunch',
        'happy_hour',
      ]);
    });

    testWidgets('toggle asks for a reason and writes temporal replacement', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast', enabled: true),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('admin_vendor_applicability_toggle_wage_default_toast'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason_note')),
        'Disable until payroll mapping is confirmed',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      expect(gateway.upserts.single.enabled, isFalse);
      expect(
        gateway.upserts.single.reasonNote,
        'Disable until payroll mapping is confirmed',
      );
    });

    testWidgets('end action requires reason and sends temporal end command', (
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

      final endButton = tester.widget<IconButton>(
        find.byKey(const Key('admin_vendor_applicability_end_row-wage-toast')),
      );
      expect(endButton.onPressed, isNotNull);
      endButton.onPressed!();
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

    testWidgets('read-only mode hides mutation behavior', (tester) async {
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
      final toggle = tester.widget<Switch>(
        find.byKey(
          const Key('admin_vendor_applicability_toggle_wage_default_toast'),
        ),
      );
      expect(toggle.onChanged, isNull);
    });
  });
}

Future<void> _size(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

VendorApplicabilityAdminRow _row({
  required String settingKind,
  required String vendorSlug,
  bool enabled = true,
}) {
  final now = DateTime.utc(2026, 5, 13, 15);
  return VendorApplicabilityAdminRow(
    id: 'row-$settingKind-$vendorSlug',
    operatorId: null,
    settingKind: settingKind,
    settingKey: 'default',
    vendorSlug: vendorSlug,
    enabled: enabled,
    metadata: const <String, Object?>{'authority_basis': 'job_code'},
    effectiveFrom: now,
    effectiveUntil: null,
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
    );
    _rows
      ..removeWhere(
        (existing) =>
            existing.settingKind == command.settingKind &&
            existing.settingKey == command.settingKey &&
            existing.vendorSlug == command.vendorSlug,
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
