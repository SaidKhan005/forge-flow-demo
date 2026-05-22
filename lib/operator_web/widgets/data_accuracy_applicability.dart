import '../../domain/models/data_accuracy_settings.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/integration/polling_tier_presets.dart';
import 'vendor_relativity_label.dart';

const Set<String> kDataAccuracyPollOnlyVendorIds = <String>{
  'oracle_micros_simphony',
  'quickbooks_time',
  'humanity',
  'agendrix',
  'push_operations',
};

bool dataAccuracyHasAnyConnectedVendor(VendorConnectionsBundle? bundle) =>
    bundle?.posConnection != null ||
    bundle?.laborConnection != null ||
    bundle?.reservationConnection != null;

List<VendorConnectionRow> dataAccuracyConnectedPollOnlyVendors(
  VendorConnectionsBundle? bundle,
) {
  return <VendorConnectionRow?>[bundle?.posConnection, bundle?.laborConnection]
      .whereType<VendorConnectionRow>()
      .where((row) => kDataAccuracyPollOnlyVendorIds.contains(row.vendorId))
      .toList(growable: false);
}

bool dataFreshnessAppliesToBundle(VendorConnectionsBundle? bundle) =>
    dataAccuracyConnectedPollOnlyVendors(bundle).isNotEmpty;

Map<String, int> connectedPollingCadences(
  VendorConnectionsBundle? bundle,
  Map<String, int> source,
) {
  final connectedPollOnly = dataAccuracyConnectedPollOnlyVendors(
    bundle,
  ).map((row) => row.vendorId).toSet();
  return <String, int>{
    for (final entry in source.entries)
      if (connectedPollOnly.contains(entry.key)) entry.key: entry.value,
  };
}

Map<String, int> defaultConnectedPollingCadences(
  VendorConnectionsBundle? bundle,
) => connectedPollingCadences(bundle, kStandardTierPresets);

String dataFreshnessNotApplicableCopy(VendorConnectionsBundle? bundle) {
  if (!dataAccuracyHasAnyConnectedVendor(bundle)) {
    return 'No vendor is connected for this location yet. Data freshness unlocks when Oracle MICROS Simphony, QuickBooks Time, Humanity, Agendrix, or Push Operations is connected.';
  }
  return 'Does not apply to your integrations. Your connected vendors push updates to Forge & Flow when they happen.';
}

bool wageVendorOptionApplies(VendorConnectionsBundle? bundle) =>
    bundle?.laborConnection != null;

bool coversSourceOptionApplies(
  CoversSource source,
  VendorConnectionsBundle? bundle,
) {
  switch (source) {
    case CoversSource.vendor:
      final pos = bundle?.posConnection;
      return pos != null && posVendorExposesCovers(pos.vendorId);
    case CoversSource.reservationPlusWalkin:
      return bundle?.reservationConnection != null;
    case CoversSource.forecast:
    case CoversSource.manual:
      return true;
  }
}

String? coversSourceDisabledReason(
  CoversSource source,
  VendorConnectionsBundle? bundle,
) {
  switch (source) {
    case CoversSource.vendor:
      final pos = bundle?.posConnection;
      if (pos == null) return 'Connect a POS before using vendor covers.';
      if (!posVendorExposesCovers(pos.vendorId)) {
        return '${pos.displayName} does not expose covers. Use forecast, manual, or reservations plus walk-ins.';
      }
      return null;
    case CoversSource.reservationPlusWalkin:
      if (bundle?.reservationConnection == null) {
        return 'Connect a reservation vendor before using reservations plus walk-ins.';
      }
      return null;
    case CoversSource.forecast:
    case CoversSource.manual:
      return null;
  }
}
