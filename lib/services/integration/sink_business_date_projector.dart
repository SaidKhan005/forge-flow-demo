// Per-Daypart Targets V1 — Slice 7b option (b) shared business_date
// projector for vendor sinks.
//
// Closes Gap 46 (sub-hour cutoff truncation) AND Gap 47 (operator →
// org_unit → location hierarchy bypass) per the operator-locked
// decision in `docs/_audits/per_daypart_v1/slice_7b_research_2026_05_15.md`
// (2026-05-15) and the per-daypart V1 plan §"Vendor sink business_date
// gaps" Slice 7b LOCKED row.
//
// Background:
//   The 20 vendor sinks under `lib/infrastructure/persistence/postgres/
//   *_postgres_sink.dart` historically projected `business_date` from
//   `public.locations.business_day_rollover_hour` (INTEGER 0..23) via
//   `IanaTimezoneConverter.toBusinessDate`. That column truncates
//   sub-hour cutoffs and bypasses the canonical operator→org_unit→
//   location inheritance chain that the read side already uses
//   (HP #11). The canonical chain lives at:
//
//     - `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
//       — operator-tenant-scoped query that returns rows ordered
//       operator → org_unit ancestors → location.
//     - `BusinessTimingProfileResolver.resolve` — pure inheritance
//       resolver returning an `EffectiveBusinessTimingProfile` carrying
//       `businessDayStartLocalTime` as TIME (HH:MM, sub-hour aware).
//     - `BusinessDateResolver.resolve(localTimestamp:,
//       businessDayStartLocalTime:)` — pure ISO business-date string
//       producer that consumes the HH:MM cutoff.
//
//   The reference caller for the chain is
//   `lib/services/integration/open_shift_snapshot_projector.dart:32-94`
//   (`PostgresOpenShiftTimingProfileSource.resolveForBusinessDate`).
//   This helper generalizes that pattern from the open-shift projector
//   to every Postgres-backed vendor sink.
//
// Slice 7b is split:
//   - **7b.1 (this file + Square exemplar)** locks the helper API and
//     applies it to ONE sink so the orchestrator + operator can audit
//     the surface before bulk application.
//   - **7b.2** mechanically migrates the remaining 19 sinks.
//
// Operator decisions honored (locked 2026-05-15, do not revisit):
//   - Sub-option (b1): the SQL trigger in
//     `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147`
//     stays as a defense-in-depth backup. Not rewritten in 7b.
//   - Fallback cutoff `'04:00'` when the profile chain returns no
//     candidates. Matches Libro's Dart fallback and the operator-default
//     `business_day_start_local_time = '04:00'` in the demo seed. NOT
//     OpenTable's `0` and NOT the SQL trigger's `coalesce(…, 0)`.
//   - `locations.business_day_rollover_hour` deprecated, NOT dropped in
//     7b. Drop migration is a follow-up after a deprecation cycle.
//
// Architecture honoring:
//   - HP #4 (per-operator isolation): the helper does NOT open its own
//     tenant transaction. The caller's existing `withTenant(...)` block
//     is the outer scope; `listCandidateProfilesForLocation` opens its
//     own short tenant transaction internally (see the projector caller
//     at `open_shift_snapshot_projector.dart:39-50`). Every read is
//     operator-tenant-scoped.
//   - HP #11 (hierarchy-scoped settings): the resolver chain honors
//     operator → org_unit → location precedence by construction.
//   - Phase 7.55 Rule 11 (denormalized business_date): callers store the
//     resolved DateTime as a `DATE` column on the canonical-fact row;
//     this helper produces a UTC midnight `DateTime` so the caller can
//     format to 'YYYY-MM-DD' for the SQL `::date` cast.
//   - Time Guardrails ("Restaurant-local timing wins; business date is
//     the anchor"): the helper converts UTC instants to restaurant-local
//     wall-clock via `IanaTimezoneConverter.toBusinessLocal` before
//     applying the cutoff, mirroring the open-shift projector.

import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_date_resolver.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'iana_timezone_converter.dart';

/// Resolves `business_date` for vendor-sink writes via the canonical
/// `BusinessTimingProfilesRepository` → `BusinessTimingProfileResolver`
/// → `BusinessDateResolver` chain.
///
/// One instance is safe to share across operators: each call accepts the
/// `(operatorId, locationId)` tuple explicitly and the underlying
/// repository performs operator-scoped tenant resolution.
class SinkBusinessDateProjector {
  SinkBusinessDateProjector({
    required this.profilesRepository,
    IanaTimezoneConverter? timezoneConverter,
  }) : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared;

  final BusinessTimingProfilesRepository profilesRepository;
  final IanaTimezoneConverter _timezoneConverter;

  /// Operator-locked fallback cutoff (2026-05-15) — applied when the
  /// profile inheritance chain returns no candidates. Matches Libro's
  /// historical Dart fallback and the operator-default
  /// `business_day_start_local_time = '04:00'`. Positive default, not a
  /// sentinel; HH:MM format the same as `business_timing_profiles.
  /// business_day_start_local_time`.
  static const String _kFallbackBusinessDayStartLocalTime = '04:00';

  /// Operator-locked fallback timezone (2026-05-15) — applied when the
  /// caller supplies an empty `restaurantTimezone`. Matches Libro's
  /// historical Dart fallback. The combined `('UTC', '04:00')` fallback
  /// projects identically to Libro's legacy
  /// `(timezone='UTC', business_day_rollover_hour=4)` path.
  static const String _kFallbackRestaurantTimezone = 'UTC';

  /// Resolves the `business_date` for [instantUtc] under the
  /// (operator, location) tenant.
  ///
  /// Returns a UTC midnight `DateTime` representing the resolved
  /// business date. The caller is responsible for formatting it to
  /// 'YYYY-MM-DD' for the SQL `::date` cast (mirrors the existing
  /// `_formatDate` helper pattern in every sink).
  ///
  /// Algorithm:
  ///   1. Convert UTC instant to restaurant-local wall-clock.
  ///   2. Compute a coarse business_date seed (calendar date in
  ///      restaurant timezone) — keys the profile lookup.
  ///   3. Call `listCandidateProfilesForLocation` for that coarse seed.
  ///   4. Resolve the effective profile via
  ///      `BusinessTimingProfileResolver.resolve`.
  ///   5. Run `BusinessDateResolver.resolve` with the local wall-clock
  ///      and the effective `businessDayStartLocalTime` (HH:MM).
  ///   6. If the resolved business_date differs from the coarse seed by
  ///      ±1 day (operator changed the cutoff overnight on the same
  ///      calendar date the instant lands on), re-resolve once with the
  ///      corrected seed. Bounded at 1 iteration.
  ///
  /// Empty-chain fallback uses `('UTC', '04:00')` — the Libro-pattern
  /// default. Empty-string `restaurantTimezone` falls back to `'UTC'`.
  Future<DateTime> projectBusinessDate({
    required String operatorId,
    required String locationId,
    required String restaurantTimezone,
    required DateTime instantUtc,
    String? userId,
  }) async {
    final effectiveTimezone = restaurantTimezone.trim().isEmpty
        ? _kFallbackRestaurantTimezone
        : restaurantTimezone;
    final instant = instantUtc.toUtc();

    final localWallClock = _timezoneConverter.toBusinessLocal(
      restaurantTimezone: effectiveTimezone,
      instant: instant,
    );
    final coarseSeed = _formatDate(localWallClock);

    final firstResolved = await _resolveBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      coarseSeed: coarseSeed,
      localWallClock: localWallClock,
      userId: userId,
    );
    if (firstResolved == coarseSeed) {
      return _parseUtcMidnight(firstResolved);
    }

    // Bounded re-resolve: if the coarse seed was on the wrong side of an
    // overnight profile change, re-look-up using the actually-resolved
    // business_date. Capped at one extra iteration; a third hop would
    // mean an operator changed the cutoff on two adjacent business
    // dates simultaneously, which the resolver chain forbids by
    // `effective_from_business_date` ordering.
    final reResolved = await _resolveBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      coarseSeed: firstResolved,
      localWallClock: localWallClock,
      userId: userId,
    );
    return _parseUtcMidnight(reResolved);
  }

  /// Resolves `business_date` inside an existing tenant transaction.
  ///
  /// Returns `null` when the location or effective timezone cannot be
  /// read, or when the timezone is invalid. Callers with a hard
  /// non-null column may either skip the write (usage cap events) or
  /// fall back to their existing chain date (audit logs).
  Future<DateTime?> projectBusinessDateForLocation({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required DateTime instantUtc,
  }) {
    return projectBusinessDateForLocationInTransaction(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      instantUtc: instantUtc,
      timezoneConverter: _timezoneConverter,
    );
  }

  static Future<DateTime?> projectBusinessDateForLocationInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required DateTime instantUtc,
    IanaTimezoneConverter? timezoneConverter,
  }) async {
    final converter = timezoneConverter ?? IanaTimezoneConverter.shared;
    final timezone =
        await BusinessTimingProfilesRepository.readLocationBusinessTimezoneInTransaction(
          exec,
          operatorId: operatorId,
          locationId: locationId,
        );
    if (timezone == null) return null;
    final instant = instantUtc.toUtc();
    late final DateTime localWallClock;
    try {
      localWallClock = converter.toBusinessLocal(
        restaurantTimezone: timezone,
        instant: instant,
      );
    } on IanaTimezoneConverterError {
      return null;
    }
    final coarseSeed = _formatDate(localWallClock);
    final firstResolved = await _resolveBusinessDateInTransaction(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      coarseSeed: coarseSeed,
      localWallClock: localWallClock,
    );
    if (firstResolved == coarseSeed) return _parseUtcMidnight(firstResolved);
    final reResolved = await _resolveBusinessDateInTransaction(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      coarseSeed: firstResolved,
      localWallClock: localWallClock,
    );
    return _parseUtcMidnight(reResolved);
  }

  Future<String> _resolveBusinessDate({
    required String operatorId,
    required String locationId,
    required String coarseSeed,
    required DateTime localWallClock,
    required String? userId,
  }) async {
    final candidates = await profilesRepository
        .listCandidateProfilesForLocation(
          operatorId: operatorId,
          locationId: locationId,
          businessDate: coarseSeed,
          userId: userId,
        );

    return _resolveBusinessDateFromCandidates(candidates, localWallClock);
  }

  static Future<String> _resolveBusinessDateInTransaction(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String coarseSeed,
    required DateTime localWallClock,
  }) async {
    final candidates =
        await BusinessTimingProfilesRepository.listCandidateProfilesForLocationInTransaction(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          businessDate: coarseSeed,
        );
    return _resolveBusinessDateFromCandidates(candidates, localWallClock);
  }

  static String _resolveBusinessDateFromCandidates(
    List<BusinessTimingProfileRow> candidates,
    DateTime localWallClock,
  ) {
    if (candidates.isEmpty) {
      return BusinessDateResolver.resolve(
        localTimestamp: localWallClock,
        businessDayStartLocalTime: _kFallbackBusinessDayStartLocalTime,
      );
    }

    final effective = BusinessTimingProfileResolver.resolve(
      <BusinessTimingProfile>[
        for (final row in candidates) _toBusinessTimingProfile(row),
      ],
    );
    return BusinessDateResolver.resolve(
      localTimestamp: localWallClock,
      businessDayStartLocalTime: effective.businessDayStartLocalTime,
    );
  }

  /// Build a `BusinessTimingProfile` candidate from a repository row.
  /// Mirrors `open_shift_snapshot_projector.dart:53-82` byte-for-byte
  /// in shape so the resolver semantics are identical between the
  /// open-shift projector and the sink fanout.
  static BusinessTimingProfile _toBusinessTimingProfile(
    BusinessTimingProfileRow row,
  ) {
    return BusinessTimingProfile(
      profileId: row.profileId,
      scope: BusinessTimingScope.fromValue(row.scopeType),
      scopeId: row.scopeId,
      businessTimezone: row.locationTimezone,
      businessDayStartLocalTime: row.businessDayStartLocalTime,
      weekStartDay: row.weekStartDay,
      servicePeriodDefinitions: row.servicePeriods.isEmpty
          ? null
          : <ServicePeriodDefinition>[
              for (final period in row.servicePeriods)
                ServicePeriodDefinition(
                  id: period.servicePeriodKey,
                  label: period.label,
                  shortLabel: period.shortLabel,
                  sortOrder: period.sortOrder,
                  startLocalTime: period.startLocalTime,
                  endLocalTime: period.endLocalTime,
                  rollsPastMidnight: period.rollsPastMidnight,
                  applicableDays: period.applicableWeekdays,
                ),
            ],
      shiftCloseAuthority: ShiftCloseAuthority.fromValue(row.closeAuthority),
      localCloseFallback: row.localCloseFallbackTime,
    );
  }

  static String _formatDate(DateTime value) {
    final yyyy = value.year.toString().padLeft(4, '0');
    final mm = value.month.toString().padLeft(2, '0');
    final dd = value.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }

  static DateTime _parseUtcMidnight(String isoDate) {
    // BusinessDateResolver returns 'YYYY-MM-DD'; pin a UTC midnight
    // DateTime so the caller's `_formatDate` helper sees a stable
    // y/m/d under any local-time interpretation.
    final parts = isoDate.split('-');
    return DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }
}
