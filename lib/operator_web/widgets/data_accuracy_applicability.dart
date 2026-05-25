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

/// Like [connectedPollingCadences], but also honors the admin polling
/// applicability DENY model. When [vendorApplicabilityBound] is true,
/// any vendor whose slug is in [turnedOffVendorSlugs] is dropped from
/// the cadence map (the admin turned its scheduled checks OFF for this
/// (operator, location) via a `setting_kind = 'polling'` row with
/// `enabled = false`). When [vendorApplicabilityBound] is false (no
/// applicability gateway wired) this behaves EXACTLY like
/// [connectedPollingCadences] — the turn-off list is ignored, so this
/// can only further restrict the existing behavior, never loosen it.
/// Consistent with the background worker's deny semantics: a row with
/// `enabled = true` (or no row) leaves the vendor polled by default.
Map<String, int> connectedPollingCadencesHonoringApplicability({
  required VendorConnectionsBundle? bundle,
  required Map<String, int> source,
  required bool vendorApplicabilityBound,
  required Iterable<String> turnedOffVendorSlugs,
}) {
  final base = connectedPollingCadences(bundle, source);
  if (!vendorApplicabilityBound) return base;
  final turnedOff = turnedOffVendorSlugs.toSet();
  return <String, int>{
    for (final entry in base.entries)
      if (!turnedOff.contains(entry.key)) entry.key: entry.value,
  };
}

/// Whether the data-freshness card still applies once the admin polling
/// turn-offs are taken into account. Mirrors [dataFreshnessAppliesToBundle]
/// (at least one connected poll-only vendor) but, when
/// [vendorApplicabilityBound] is true, subtracts the vendors in
/// [turnedOffVendorSlugs] first. When not bound, the turn-off list is
/// ignored and this matches [dataFreshnessAppliesToBundle] exactly.
bool dataFreshnessAppliesHonoringApplicability({
  required VendorConnectionsBundle? bundle,
  required bool vendorApplicabilityBound,
  required Iterable<String> turnedOffVendorSlugs,
}) {
  final connectedPollOnly = dataAccuracyConnectedPollOnlyVendors(
    bundle,
  ).map((row) => row.vendorId).toSet();
  if (!vendorApplicabilityBound) return connectedPollOnly.isNotEmpty;
  connectedPollOnly.removeAll(turnedOffVendorSlugs);
  return connectedPollOnly.isNotEmpty;
}

String dataFreshnessNotApplicableCopy(VendorConnectionsBundle? bundle) {
  if (!dataAccuracyHasAnyConnectedVendor(bundle)) {
    return 'Does not apply until a vendor that needs scheduled checks is connected.';
  }
  return 'Does not apply to your integrations. Your connected vendors push updates to Forge & Flow when they happen.';
}

bool wageVendorOptionApplies(VendorConnectionsBundle? bundle) =>
    bundle?.laborConnection != null;

bool wageVendorOptionSelectable({
  required VendorConnectionsBundle? bundle,
  required bool vendorApplicabilityBound,
  required Iterable<String> applicableWageVendorSlugs,
}) {
  final laborVendorId = bundle?.laborConnection?.vendorId;
  return wageVendorOptionApplies(bundle) &&
      (!vendorApplicabilityBound ||
          applicableWageVendorSlugs.contains(laborVendorId));
}

WageSource effectiveWageSource({
  required WageSource configured,
  required VendorConnectionsBundle? bundle,
  required bool vendorApplicabilityBound,
  required Iterable<String> applicableWageVendorSlugs,
}) {
  if (configured != WageSource.vendor) return configured;
  return wageVendorOptionSelectable(
        bundle: bundle,
        vendorApplicabilityBound: vendorApplicabilityBound,
        applicableWageVendorSlugs: applicableWageVendorSlugs,
      )
      ? WageSource.vendor
      : WageSource.manualMix;
}

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

CoversSource effectiveCoversSource(
  CoversSource configured,
  VendorConnectionsBundle? bundle,
) {
  return coversSourceOptionApplies(configured, bundle)
      ? configured
      : CoversSource.manual;
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

/// Whether a covers [source] is selectable once the admin allow-list is
/// taken into account. Mirrors [wageVendorOptionSelectable]: it ANDs the
/// existing capability check ([coversSourceOptionApplies]) with "the
/// relevant connected vendor is in [applicableCoversVendorSlugs]". The
/// allow-list is consulted only for the two vendor-backed sources:
///   * `vendor` (POS covers)  -> gated by the connected POS vendor id.
///   * `reservationPlusWalkin` -> gated by the connected reservation
///     vendor id.
/// `forecast` and `manual` are Forge & Flow-computed / operator-typed and
/// are never gated by the allow-list. When [vendorApplicabilityBound] is
/// false (no applicability gateway wired) the allow-list is not enforced
/// and only the capability check applies, so this can only further
/// restrict the existing behavior, never loosen it.
bool coversSourceOptionSelectable({
  required CoversSource source,
  required VendorConnectionsBundle? bundle,
  required bool vendorApplicabilityBound,
  required Iterable<String> applicableCoversVendorSlugs,
}) {
  if (!coversSourceOptionApplies(source, bundle)) return false;
  if (!vendorApplicabilityBound) return true;
  switch (source) {
    case CoversSource.vendor:
      final posVendorId = bundle?.posConnection?.vendorId;
      return applicableCoversVendorSlugs.contains(posVendorId);
    case CoversSource.reservationPlusWalkin:
      final reservationVendorId = bundle?.reservationConnection?.vendorId;
      return applicableCoversVendorSlugs.contains(reservationVendorId);
    case CoversSource.forecast:
    case CoversSource.manual:
      return true;
  }
}

/// Disabled-reason copy for a covers [source] once the admin allow-list
/// is taken into account. Defers to [coversSourceDisabledReason] for the
/// capability-level reasons (no POS, POS without covers, no reservation
/// vendor); adds an allow-list reason only when the vendor is connected
/// and capable but Forge & Flow has not cleared it for this setting.
/// Plain English, operator-web vocabulary ("covers", "vendor covers",
/// "reservations + walk-ins"); no em dashes.
String? coversSourceDisabledReasonWithApplicability({
  required CoversSource source,
  required VendorConnectionsBundle? bundle,
  required bool vendorApplicabilityBound,
  required Iterable<String> applicableCoversVendorSlugs,
}) {
  final capabilityReason = coversSourceDisabledReason(source, bundle);
  if (capabilityReason != null) return capabilityReason;
  if (!vendorApplicabilityBound) return null;
  switch (source) {
    case CoversSource.vendor:
      final pos = bundle?.posConnection;
      if (pos != null && !applicableCoversVendorSlugs.contains(pos.vendorId)) {
        return '${pos.displayName} is not cleared by Forge & Flow for vendor covers yet. Use forecast, manual, or reservations plus walk-ins.';
      }
      return null;
    case CoversSource.reservationPlusWalkin:
      final reservation = bundle?.reservationConnection;
      if (reservation != null &&
          !applicableCoversVendorSlugs.contains(reservation.vendorId)) {
        return '${reservation.displayName} is not cleared by Forge & Flow for reservations + walk-ins yet. Use forecast or manual.';
      }
      return null;
    case CoversSource.forecast:
    case CoversSource.manual:
      return null;
  }
}
