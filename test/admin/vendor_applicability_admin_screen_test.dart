import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/models/operator_location_admin_models.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_recommended_defaults.dart';
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
      expect(command.adminReason, 'Ticket VA-200 launch wage source');
      expect(command.reasonNote, 'Ticket VA-200 launch wage source');
      expect(command.idempotencyKey, startsWith('admin-vendor-applicability-'));
    });

    testWidgets(
      'recommended defaults add missing rules without changing existing rules',
      (tester) async {
        await _size(tester);
        final wageDefaults = recommendedVendorApplicabilityDefaultsFor('wage');
        final gateway = _FakeVendorApplicabilityAdminGateway()
          ..seed(<VendorApplicabilityAdminRow>[
            for (final recommended in wageDefaults)
              if (recommended.vendorSlug != 'toast')
                _rowFromRecommended(
                  recommended,
                  metadata: recommended.vendorSlug == 'square'
                      ? const <String, Object?>{'authority_basis': 'job_code'}
                      : recommended.metadata,
                ),
          ]);

        await tester.pumpWidget(
          wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('admin_vendor_applicability_recommended_defaults'),
          ),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(
            const Key('admin_vendor_applicability_recommended_defaults'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Use recommended defaults?'), findsOneWidget);
        expect(find.text('Add 1 missing wage rule.'), findsOneWidget);
        expect(find.text('Toast'), findsOneWidget);
        expect(
          find.text('1 existing rule differs. Review separately.'),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_recommended_apply')),
        );
        await tester.pumpAndSettle();

        expect(gateway.upserts, hasLength(1));
        final command = gateway.upserts.single;
        expect(command.vendorSlug, 'toast');
        expect(command.settingKind, 'wage');
        expect(command.settingKey, 'default');
        expect(command.enabled, isTrue);
        expect(command.metadata['authority_basis'], 'vendor_pay_rate');
        expect(command.metadata['vendor_field'], 'gross_wages');
        expect(command.reasonNote, 'Apply recommended wage defaults');
      },
    );

    testWidgets('recommended defaults require a reason', (tester) async {
      await _size(tester);
      final wageDefaults = recommendedVendorApplicabilityDefaultsFor('wage');
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          for (final recommended in wageDefaults)
            if (recommended.vendorSlug != 'toast')
              _rowFromRecommended(recommended),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('admin_vendor_applicability_recommended_defaults'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_recommended_reason')),
        '',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_recommended_apply')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_recommended_error')),
        findsOneWidget,
      );
      expect(gateway.upserts, isEmpty);
    });

    testWidgets('reset defaults replaces current tab rules', (tester) async {
      await _size(tester);
      final wageDefaults = recommendedVendorApplicabilityDefaultsFor('wage');
      final firstDefault = wageDefaults.first;
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _rowFromRecommended(
            firstDefault,
            metadata: const <String, Object?>{
              'authority_basis': 'manual_mapping',
            },
          ),
          _row(
            settingKind: 'wage',
            vendorSlug: 'libro',
            metadata: const <String, Object?>{
              'authority_basis': 'manual_mapping',
            },
          ),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_reset_defaults')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_reset_defaults')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Reset defaults?'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason_note')),
        'Reset wage defaults',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(gateway.ends, hasLength(1));
      expect(gateway.ends.single.vendorSlug, 'libro');
      expect(gateway.ends.single.adminReason, 'Reset wage defaults');
      expect(gateway.upserts, hasLength(wageDefaults.length));
      final resetFirst = gateway.upserts.firstWhere(
        (command) => command.vendorSlug == firstDefault.vendorSlug,
      );
      expect(resetFirst.enabled, firstDefault.enabled);
      expect(resetFirst.metadata, firstDefault.metadata);
      expect(resetFirst.adminReason, 'Reset wage defaults');
      expect(resetFirst.idempotencyKey, contains('reset-defaults'));
    });

    testWidgets(
      'selected location scope threads operator + location into upsert',
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
              hierarchyScope: const AdminHierarchyScopeIntent.location(
                operatorId: _kOperatorId,
                operatorName: 'Barrio Legado',
                locationId: _kLocationId,
                locationName: 'North Loop',
              ),
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

        expect(
          find.byKey(const Key('admin_vendor_applicability_scope_summary')),
          findsOneWidget,
        );
        expect(find.text('Barrio Legado / North Loop'), findsOneWidget);

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
      },
    );

    testWidgets(
      'editing an inherited rule saves an override at the selected location',
      (tester) async {
        await _size(tester);
        final gateway = _FakeVendorApplicabilityAdminGateway()
          ..seed(<VendorApplicabilityAdminRow>[
            _row(settingKind: 'wage', vendorSlug: 'toast'),
          ]);
        final operatorGateway = InMemoryOperatorLocationAdminGateway(
          seed: <OperatorAdminBundle>[_operatorBundle()],
        );

        await tester.pumpWidget(
          wrap(
            VendorApplicabilityAdminScreen(
              gateway: gateway,
              operatorLocationGateway: operatorGateway,
              hierarchyScope: const AdminHierarchyScopeIntent.location(
                operatorId: _kOperatorId,
                operatorName: 'Barrio Legado',
                locationId: _kLocationId,
                locationName: 'North Loop',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Inherited'), findsOneWidget);
        await tester.tap(
          find.byKey(
            const Key('admin_vendor_applicability_edit_row-wage-toast'),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Add override'), findsOneWidget);
        expect(find.text('Barrio Legado / North Loop'), findsOneWidget);

        await tester.ensureVisible(
          find.byKey(const Key('admin_vendor_applicability_reason')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('admin_vendor_applicability_reason')),
          'Ticket VA-211 local Toast override',
        );
        await tester.tap(
          find.byKey(const Key('admin_vendor_applicability_submit')),
        );
        await tester.pumpAndSettle();

        expect(gateway.upserts, hasLength(1));
        final command = gateway.upserts.single;
        expect(command.vendorSlug, 'toast');
        expect(command.operatorId, _kOperatorId);
        expect(command.locationId, _kLocationId);
        expect(command.reasonNote, 'Ticket VA-211 local Toast override');
      },
    );

    testWidgets('stopping an inherited rule adds a local block override', (
      tester,
    ) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(settingKind: 'wage', vendorSlug: 'toast'),
        ]);
      final operatorGateway = InMemoryOperatorLocationAdminGateway(
        seed: <OperatorAdminBundle>[_operatorBundle()],
      );

      await tester.pumpWidget(
        wrap(
          VendorApplicabilityAdminScreen(
            gateway: gateway,
            operatorLocationGateway: operatorGateway,
            hierarchyScope: const AdminHierarchyScopeIntent.location(
              operatorId: _kOperatorId,
              operatorName: 'Barrio Legado',
              locationId: _kLocationId,
              locationName: 'North Loop',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_end_row-wage-toast')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Block Toast here?'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason_note')),
        'Block Toast only at North Loop',
      );
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(gateway.ends, isEmpty);
      expect(gateway.upserts, hasLength(1));
      final command = gateway.upserts.single;
      expect(command.vendorSlug, 'toast');
      expect(command.enabled, isFalse);
      expect(command.operatorId, _kOperatorId);
      expect(command.locationId, _kLocationId);
      expect(command.reasonNote, 'Block Toast only at North Loop');
    });

    testWidgets(
      'org-unit scope disables adding because backend stores business/location rules',
      (tester) async {
        await _size(tester);
        final gateway = _FakeVendorApplicabilityAdminGateway()
          ..seed(<VendorApplicabilityAdminRow>[
            _row(settingKind: 'wage', vendorSlug: 'toast'),
          ]);

        await tester.pumpWidget(
          wrap(
            VendorApplicabilityAdminScreen(
              gateway: gateway,
              hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
                operatorId: _kOperatorId,
                operatorName: 'Barrio Legado',
                orgUnitId: 'ou-east',
                orgUnitName: 'East region',
              ),
              scopeLocationIds: const <String>{_kLocationId},
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_vendor_applicability_org_unit_notice')),
          findsOneWidget,
        );
        final addButton = tester.widget<FilledButton>(
          find.byKey(const Key('admin_vendor_applicability_add')),
        );
        expect(addButton.onPressed, isNull);
        expect(
          find.byKey(
            const Key('admin_vendor_applicability_edit_row-wage-toast'),
          ),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key('admin_vendor_applicability_end_row-wage-toast'),
          ),
          findsNothing,
        );
        expect(gateway.upserts, isEmpty);
      },
    );

    testWidgets('special handling info opens the plain-English help', (
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

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_special_info')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_applicability_special_help')),
        findsOneWidget,
      );
      expect(
        find.text('Use these only when allow/block is not enough.'),
        findsOneWidget,
      );
      expect(find.text('By role'), findsOneWidget);
    });

    testWidgets('advanced JSON validates and can reset to friendly fields', (
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
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('7shifts').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_details_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_wage_authority')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('By role (job code)').last);
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_advanced_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_advanced_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_metadata')),
        '[]',
      );
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-230 advanced reset',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Advanced JSON is invalid'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_reset_json')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('admin_vendor_applicability_metadata')),
            )
            .controller!
            .text,
        contains('authority_basis'),
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      expect(gateway.upserts.single.metadata['authority_basis'], 'job_code');
    });

    testWidgets('editing preserves advanced metadata fields', (tester) async {
      await _size(tester);
      final gateway = _FakeVendorApplicabilityAdminGateway()
        ..seed(<VendorApplicabilityAdminRow>[
          _row(
            settingKind: 'wage',
            vendorSlug: 'seven_shifts',
            metadata: const <String, Object?>{
              'authority_basis': 'job_code',
              'requires_job_code': true,
              'vendor_field': 'gross_wages',
              'notes': 'Keep advanced note.',
            },
          ),
        ]);

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('admin_vendor_applicability_edit_row-wage-seven_shifts'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-240 metadata retention',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      expect(gateway.upserts.single.metadata['authority_basis'], 'job_code');
      expect(gateway.upserts.single.metadata['requires_job_code'], isTrue);
      expect(gateway.upserts.single.metadata['vendor_field'], 'gross_wages');
      expect(gateway.upserts.single.metadata['notes'], 'Keep advanced note.');
    });

    testWidgets('advanced setting key matches backend validation', (
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
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_vendor_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('7shifts').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_advanced_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_advanced_toggle')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_setting_key')),
        'pay.rate+v2',
      );
      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        'Ticket VA-241 named key',
      );
      await tester.tap(
        find.byKey(const Key('admin_vendor_applicability_submit')),
      );
      await tester.pumpAndSettle();

      expect(gateway.upserts, hasLength(1));
      expect(gateway.upserts.single.settingKey, 'pay.rate+v2');
    });

    testWidgets('short dialog viewport can scroll to the reason field', (
      tester,
    ) async {
      await _size(tester, const Size(900, 520));
      final gateway = _FakeVendorApplicabilityAdminGateway();

      await tester.pumpWidget(
        wrap(VendorApplicabilityAdminScreen(gateway: gateway)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('admin_vendor_applicability_add')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('admin_vendor_applicability_reason')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('admin_vendor_applicability_reason')),
        findsOneWidget,
      );
    });

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
      expect(
        command.adminReason,
        'End Toast while staging the new payroll source',
      );
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

Future<void> _size(
  WidgetTester tester, [
  Size size = const Size(1400, 1200),
]) async {
  tester.view.physicalSize = size;
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
  Map<String, Object?>? metadata,
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
    metadata:
        metadata ?? const <String, Object?>{'authority_basis': 'job_code'},
    effectiveFrom: now,
    effectiveUntil: effectiveUntil,
    createdAt: now,
    createdBy: 'admin-user',
  );
}

VendorApplicabilityAdminRow _rowFromRecommended(
  VendorApplicabilityRecommendedDefault recommended, {
  Map<String, Object?>? metadata,
}) {
  final now = DateTime.utc(2026, 5, 13, 15);
  return VendorApplicabilityAdminRow(
    id:
        'row-${recommended.settingKind}-${recommended.settingKey}-'
        '${recommended.vendorSlug}',
    operatorId: null,
    locationId: null,
    settingKind: recommended.settingKind,
    settingKey: recommended.settingKey,
    vendorSlug: recommended.vendorSlug,
    enabled: recommended.enabled,
    metadata: metadata ?? recommended.metadata,
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
