// Raw closed-shift input from an external system (POS + labor management).
//
// This is the canonical source-of-truth record for one closed daypart shift.
// Every field is a direct reading from an external system — nothing here is
// derived.  Future live adapters (Phase 8) will produce this type; the
// close-shift ingest path (Phase 3) will persist it.
//
// No UI imports. No database code. No widget code.

class ClosedShiftInput {
  // ── Scope ────────────────────────────────────────────────────────────────

  /// Restaurant scope for this shift.
  final String restaurantId;

  // ── Identity ──────────────────────────────────────────────────────────────

  /// The calendar date this shift belongs to.
  final DateTime businessDate;

  /// ISO week identifier: "2026-W13".
  final String weekId;

  /// Short day label: "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun".
  final String dayLabel;

  /// Service period: "lunch" | "dinner" | "late_night".
  final String daypart;

  // ── POS source facts ──────────────────────────────────────────────────────

  /// Actual guests served (from POS).
  final int covers;

  /// Covers planned for this shift (from forecast / schedule system).
  final int forecastCovers;

  /// Gross sales in dollars (from POS).
  final double actualSales;

  // ── Labor-system source facts ─────────────────────────────────────────────

  /// Actual front-of-house hours worked (from timekeeping / labor system).
  final int actualFohHours;

  /// Actual back-of-house hours worked (from timekeeping / labor system).
  final int actualBohHours;

  /// FOH hours on the published schedule for this shift (optional).
  final int? scheduledFohHours;

  /// BOH hours on the published schedule for this shift (optional).
  final int? scheduledBohHours;

  /// Actual FOH labor dollars from the labor system (optional).
  /// When absent the ingest path falls back to actualFohHours × target wage.
  final double? actualFohLaborDollars;

  /// Actual BOH labor dollars from the labor system (optional).
  /// When absent the ingest path falls back to actualBohHours × target wage.
  final double? actualBohLaborDollars;

  // ── Provenance ────────────────────────────────────────────────────────────

  /// Identifier for the originating system (e.g. "toast", "square", "demo").
  final String? sourceSystem;

  /// Native shift/check id from the originating system.
  final String? sourceShiftId;

  const ClosedShiftInput({
    this.restaurantId = 'demo_restaurant_001',
    required this.businessDate,
    required this.weekId,
    required this.dayLabel,
    required this.daypart,
    required this.covers,
    required this.forecastCovers,
    required this.actualSales,
    required this.actualFohHours,
    required this.actualBohHours,
    this.scheduledFohHours,
    this.scheduledBohHours,
    this.actualFohLaborDollars,
    this.actualBohLaborDollars,
    this.sourceSystem,
    this.sourceShiftId,
  });

  /// Always true — discriminator for the closed-shift branch of the domain.
  bool get isClosedInput => true;
}
