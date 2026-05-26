import '../../operator_web/services/web_vendor_applicability_gateway.dart';
import 'vendor_applicability_admin_gateway.dart';

class AdminOperatorWebVendorApplicabilityGateway
    implements WebVendorApplicabilityGateway {
  const AdminOperatorWebVendorApplicabilityGateway({
    required VendorApplicabilityAdminGateway adminGateway,
    required String operatorId,
    required String locationId,
  }) : _adminGateway = adminGateway,
       _operatorId = operatorId,
       _locationId = locationId;

  final VendorApplicabilityAdminGateway _adminGateway;
  final String _operatorId;
  final String _locationId;

  @override
  Future<List<WebVendorApplicabilityRow>> list({
    required String settingKind,
    String? settingKey,
  }) async {
    final rows = await _adminGateway.list(
      filter: VendorApplicabilityAdminFilter(
        settingKind: settingKind,
        settingKey: settingKey,
        currentOnly: true,
      ),
    );
    final winners = _effectiveRowsForLocation(rows);
    return <WebVendorApplicabilityRow>[
      for (final row in winners)
        WebVendorApplicabilityRow(
          id: row.id,
          operatorId: row.operatorId,
          locationId: row.locationId,
          settingKind: row.settingKind,
          settingKey: row.settingKey,
          vendorSlug: row.vendorSlug,
          enabled: row.enabled,
          metadata: row.metadata,
          effectiveFrom: row.effectiveFrom,
          effectiveUntil: row.effectiveUntil,
          createdAt: row.createdAt,
          createdBy: row.createdBy,
        ),
    ];
  }

  List<VendorApplicabilityAdminRow> _effectiveRowsForLocation(
    List<VendorApplicabilityAdminRow> rows,
  ) {
    final visible = rows.where(_rowCanApplyToLocation).toList(growable: false)
      ..sort(_compareEffectiveRows);
    final winners = <String, VendorApplicabilityAdminRow>{};
    for (final row in visible) {
      winners.putIfAbsent(
        '${row.settingKey}\u0000${row.vendorSlug}',
        () => row,
      );
    }
    return winners.values.toList(growable: false)..sort((a, b) {
      final keyCompare = a.settingKey.compareTo(b.settingKey);
      if (keyCompare != 0) return keyCompare;
      return a.vendorSlug.compareTo(b.vendorSlug);
    });
  }

  bool _rowCanApplyToLocation(VendorApplicabilityAdminRow row) {
    final operatorId = row.operatorId;
    if (operatorId == null) return true;
    if (operatorId != _operatorId) return false;
    final locationId = row.locationId;
    return locationId == null || locationId == _locationId;
  }

  int _compareEffectiveRows(
    VendorApplicabilityAdminRow a,
    VendorApplicabilityAdminRow b,
  ) {
    final rankCompare = _scopeRank(a).compareTo(_scopeRank(b));
    if (rankCompare != 0) return rankCompare;
    return b.effectiveFrom.compareTo(a.effectiveFrom);
  }

  int _scopeRank(VendorApplicabilityAdminRow row) {
    if (row.locationId == _locationId) return 0;
    if (row.operatorId == _operatorId) return 1;
    return 2;
  }
}
