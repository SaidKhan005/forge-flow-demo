import '../models/shift_record.dart';

/// Minimal closed-label snapshot needed by mobile closed-history consumers.
///
/// This is intentionally flatter than the full business-timing hierarchy:
/// proxy/local cache hydration only needs `business_timing_profile_version_id`,
/// `service_period_key`, display label fields, and an optional stable sort
/// order to render historical closed rows without using mutable current labels.
class ClosedTimingLabelSnapshot {
  const ClosedTimingLabelSnapshot({
    required this.businessTimingProfileVersionId,
    required this.servicePeriodKey,
    required this.label,
    this.shortLabel,
    this.sortOrder,
  });

  final String businessTimingProfileVersionId;
  final String servicePeriodKey;
  final String label;
  final String? shortLabel;
  final int? sortOrder;
}

class ClosedTimingLabelResolver {
  ClosedTimingLabelResolver(Iterable<ClosedTimingLabelSnapshot> snapshots)
    : _byVersionAndPeriod = {
        for (final snapshot in snapshots)
          _key(
            snapshot.businessTimingProfileVersionId,
            snapshot.servicePeriodKey,
          ): snapshot,
      };

  final Map<String, ClosedTimingLabelSnapshot> _byVersionAndPeriod;

  static String _key(String versionId, String servicePeriodKey) =>
      '$versionId::$servicePeriodKey';

  bool hasSavedTimingIdentity(ShiftRecord shift) =>
      shift.businessTimingProfileVersionId != null &&
      shift.businessTimingProfileVersionId!.trim().isNotEmpty &&
      shift.servicePeriodKey != null &&
      shift.servicePeriodKey!.trim().isNotEmpty;

  String bucketKeyFor(ShiftRecord shift) {
    if (hasSavedTimingIdentity(shift)) {
      return shift.servicePeriodKey!;
    }
    return shift.daypart;
  }

  String labelFor(ShiftRecord shift) {
    final snapshot = snapshotFor(shift);
    if (snapshot != null) return snapshot.label;
    return shift.daypartLabel;
  }

  int? sortOrderFor(ShiftRecord shift) => snapshotFor(shift)?.sortOrder;

  ClosedTimingLabelSnapshot? snapshotFor(ShiftRecord shift) {
    if (!hasSavedTimingIdentity(shift)) return null;
    final versionId = shift.businessTimingProfileVersionId!.trim();
    final servicePeriodKey = shift.servicePeriodKey!.trim();
    return _byVersionAndPeriod[_key(versionId, servicePeriodKey)];
  }
}
