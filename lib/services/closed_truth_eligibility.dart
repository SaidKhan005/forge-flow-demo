import '../domain/models/restaurant_timing_config.dart';
import '../domain/services/shift_boundary_resolver.dart';
import '../models/shift_record.dart';
import 'integration/close_authority_capability.dart';

class ClosedTruthEligibility {
  ClosedTruthEligibility._();

  static ShiftCloseAuthority closeAuthorityForShift(ShiftRecord shift) {
    return closeAuthorityForSourceSystem(shift.sourceSystem);
  }

  static ShiftCloseAuthority closeAuthorityForSourceSystem(
    String? sourceSystem,
  ) {
    final capability = resolveCloseAuthorityCapability(sourceSystem);
    switch (capability) {
      case CloseAuthorityCapability.vendorReliableFinalization:
        return ShiftCloseAuthority.vendorFinalization;
      case CloseAuthorityCapability.unreliableFallbackToBusinessDayStart:
        return ShiftCloseAuthority.appLocalCutoffFallback;
    }
  }

  static bool isEligible(
    ShiftRecord shift, {
    String? currentOperationalBusinessDate,
  }) {
    if (currentOperationalBusinessDate == null) return shift.isClosed;
    return ShiftBoundaryResolver.isEligibleForClosedTruth(
      rowStatus: shift.status,
      shiftCloseAuthority: closeAuthorityForShift(shift),
      rowBusinessDate: shift.businessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
  }

  static List<ShiftRecord> filter(
    Iterable<ShiftRecord> shifts, {
    String? currentOperationalBusinessDate,
  }) {
    return shifts
        .where(
          (shift) => isEligible(
            shift,
            currentOperationalBusinessDate: currentOperationalBusinessDate,
          ),
        )
        .toList(growable: false);
  }
}
