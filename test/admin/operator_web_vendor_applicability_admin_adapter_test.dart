import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/operator_web_vendor_applicability_admin_adapter.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';

void main() {
  group('AdminOperatorWebVendorApplicabilityGateway', () {
    test(
      'resolves global, business, and location winners for admin embeds',
      () async {
        final gateway = _FakeVendorApplicabilityAdminGateway()
          ..rows = <VendorApplicabilityAdminRow>[
            _row(
              id: 'global-toast',
              settingKind: 'wage',
              vendorSlug: 'toast',
              enabled: true,
              effectiveFrom: DateTime.utc(2026, 5, 13),
            ),
            _row(
              id: 'business-toast',
              settingKind: 'wage',
              vendorSlug: 'toast',
              operatorId: _operatorId,
              enabled: false,
              effectiveFrom: DateTime.utc(2026, 5, 14),
            ),
            _row(
              id: 'location-toast',
              settingKind: 'wage',
              vendorSlug: 'toast',
              operatorId: _operatorId,
              locationId: _locationId,
              enabled: true,
              effectiveFrom: DateTime.utc(2026, 5, 12),
            ),
            _row(
              id: 'other-location-square',
              settingKind: 'wage',
              vendorSlug: 'square',
              operatorId: _operatorId,
              locationId: _otherLocationId,
              enabled: true,
              effectiveFrom: DateTime.utc(2026, 5, 15),
            ),
            _row(
              id: 'other-business-clover',
              settingKind: 'wage',
              vendorSlug: 'clover',
              operatorId: _otherOperatorId,
              enabled: true,
              effectiveFrom: DateTime.utc(2026, 5, 15),
            ),
          ];
        final adapter = AdminOperatorWebVendorApplicabilityGateway(
          adminGateway: gateway,
          operatorId: _operatorId,
          locationId: _locationId,
        );

        final rows = await adapter.list(settingKind: 'wage');

        expect(gateway.filters.single.operatorId, isNull);
        expect(gateway.filters.single.locationId, isNull);
        expect(rows, hasLength(1));
        expect(rows.single.id, 'location-toast');
        expect(rows.single.enabled, isTrue);
        expect(rows.single.operatorId, _operatorId);
        expect(rows.single.locationId, _locationId);
      },
    );

    test(
      'uses the business winner when there is no location override',
      () async {
        final gateway = _FakeVendorApplicabilityAdminGateway()
          ..rows = <VendorApplicabilityAdminRow>[
            _row(
              id: 'global-toast',
              settingKind: 'wage',
              vendorSlug: 'toast',
              enabled: true,
              effectiveFrom: DateTime.utc(2026, 5, 13),
            ),
            _row(
              id: 'business-toast',
              settingKind: 'wage',
              vendorSlug: 'toast',
              operatorId: _operatorId,
              enabled: false,
              effectiveFrom: DateTime.utc(2026, 5, 14),
            ),
          ];
        final adapter = AdminOperatorWebVendorApplicabilityGateway(
          adminGateway: gateway,
          operatorId: _operatorId,
          locationId: _locationId,
        );

        final rows = await adapter.list(settingKind: 'wage');

        expect(rows.single.id, 'business-toast');
        expect(rows.single.enabled, isFalse);
        expect(rows.single.locationId, isNull);
      },
    );
  });
}

const _operatorId = '22222222-2222-4222-8222-222222222222';
const _locationId = '33333333-3333-4333-8333-333333333333';
const _otherOperatorId = '44444444-4444-4444-8444-444444444444';
const _otherLocationId = '55555555-5555-4555-8555-555555555555';

VendorApplicabilityAdminRow _row({
  required String id,
  required String settingKind,
  required String vendorSlug,
  required bool enabled,
  required DateTime effectiveFrom,
  String? operatorId,
  String? locationId,
}) {
  return VendorApplicabilityAdminRow(
    id: id,
    operatorId: operatorId,
    locationId: locationId,
    settingKind: settingKind,
    settingKey: 'default',
    vendorSlug: vendorSlug,
    enabled: enabled,
    metadata: const <String, Object?>{'authority_basis': 'job_code'},
    effectiveFrom: effectiveFrom,
    effectiveUntil: null,
    createdAt: effectiveFrom,
    createdBy: 'admin-user',
  );
}

class _FakeVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  List<VendorApplicabilityAdminRow> rows =
      const <VendorApplicabilityAdminRow>[];
  final List<VendorApplicabilityAdminFilter> filters =
      <VendorApplicabilityAdminFilter>[];

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    filters.add(filter);
    return rows
        .where(
          (row) =>
              (filter.settingKind == null ||
                  row.settingKind == filter.settingKind) &&
              (filter.settingKey == null ||
                  row.settingKey == filter.settingKey),
        )
        .toList(growable: false);
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) {
    throw UnimplementedError();
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) {
    throw UnimplementedError();
  }
}
