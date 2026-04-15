// One historical closed shift presented as a baseline candidate.
// The manager inspects these and toggles isSelected to define the benchmark set.

class BaselineCandidateShift {
  final String recordKey;       // '${weekId}|${dayLabel}|${daypart}'
  final String weekId;
  final String weekLabel;
  final String dayLabel;
  final String daypart;         // 'lunch' | 'dinner' | 'late_night'
  final int covers;
  final double cplh;
  final double splh;
  final double ppa;
  final String primaryLeverId;  // normalizedLeverId from ShiftRecord
  final bool isSelected;

  /// ISO 8601 business date from ShiftRecord (e.g. '2026-03-27').
  /// Nullable for backward compatibility with older records.
  final String? businessDate;

  /// Historical actual labor percentage from the closed shift
  /// (ShiftRecord.totalLaborPct) when source-backed labor truth exists.
  /// This is not the target/theoretical value.
  final double actualLaborPct;

  /// Whether [actualLaborPct] comes from source-backed labor truth.
  /// When false, downstream UI should render an honest unknown state
  /// instead of treating the numeric fallback as real vendor evidence.
  final bool hasActualLaborPctTruth;

  const BaselineCandidateShift({
    required this.recordKey,
    required this.weekId,
    required this.weekLabel,
    required this.dayLabel,
    required this.daypart,
    required this.covers,
    required this.cplh,
    required this.splh,
    required this.ppa,
    required this.primaryLeverId,
    required this.isSelected,
    this.businessDate,
    this.actualLaborPct = 0.0,
    this.hasActualLaborPctTruth = true,
  });

  String get daypartLabel {
    switch (daypart) {
      case 'lunch':      return 'Lunch';
      case 'dinner':     return 'Dinner';
      case 'late_night': return 'Late Night';
      default:           return daypart;
    }
  }

  String get displayLabel => '$weekLabel • $dayLabel $daypartLabel';

  BaselineCandidateShift copyWith({bool? isSelected}) {
    return BaselineCandidateShift(
      recordKey:      recordKey,
      weekId:         weekId,
      weekLabel:      weekLabel,
      dayLabel:       dayLabel,
      daypart:        daypart,
      covers:         covers,
      cplh:           cplh,
      splh:           splh,
      ppa:            ppa,
      primaryLeverId: primaryLeverId,
      isSelected:     isSelected ?? this.isSelected,
      businessDate:   businessDate,
      actualLaborPct: actualLaborPct,
      hasActualLaborPctTruth: hasActualLaborPctTruth,
    );
  }
}
