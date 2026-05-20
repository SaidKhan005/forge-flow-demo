// Fix #4 / S4 (G41 + G42) — Admin-side business-timing display
// projection.
//
// Admin analogue of the operator-web `http_business_timing_read_
// gateway.dart` projection. Consumes the FULL ordered candidate chain
// the S2 admin route returns (operator default -> org-unit ancestors
// -> location override, in canonical `scope_depth asc` precedence
// order), maps each rung to the domain `BusinessTimingProfile`
// (mirroring the blessed `sink_business_date_projector.dart`
// row->profile shape), and runs the ONE canonical pure
// `BusinessTimingProfileResolver`. Per-field provenance is derived
// from the resolver's `resolvedScope` / `inheritanceChain` on the
// resulting `EffectiveBusinessTimingProfile` — no admin-side
// heuristic, no synthetic candidate fabrication, no resolver fork.
//
// READ-ONLY. This projection only renders resolved values for the
// admin UI. Server-side super admin repair routes exist elsewhere for
// audited profile writes.

import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import 'admin_business_timing_resolution_gateway.dart';

/// Per-field provenance derived from the resolver's `resolvedScope`
/// (the DEEPEST configured scope in the chain).
///
/// The S2 CTE emits one candidate per scope that ACTUALLY has a
/// profile row, with every field denormalised on every row, so the
/// honest "where did the effective value come from" answer is the
/// deepest scope the operator configured:
///   - operator-only chain  -> "Operator default", inherited
///   - operator + org-unit  -> "Org unit override", inherited
///     (org-unit is still an ancestor of the location being viewed)
///   - any location profile -> "Location override", NOT inherited
///     (a deliberate location-scoped row — even when its field
///     values equal the parent's; this is the exact same-value case
///     the deleted synthetic scope-flag path got wrong).
class AdminTimingFieldProvenance {
  const AdminTimingFieldProvenance({
    required this.sourceLabel,
    required this.inheritedFromAncestor,
  });

  final String sourceLabel;
  final bool inheritedFromAncestor;

  /// Plain-English source string for the admin detail rows. Mirrors
  /// the prior admin copy vocabulary ("Inherited from …" / "Set at
  /// this scope") so the only behavior change is the value being
  /// real instead of derived from a scope flag.
  String get detailLabel =>
      inheritedFromAncestor ? 'Inherited ($sourceLabel)' : sourceLabel;
}

/// The resolved admin timing projection: the canonical
/// `EffectiveBusinessTimingProfile` plus the per-field provenance the
/// admin surfaces render. Built ONLY from real S2 candidates.
class AdminEffectiveTimingProjection {
  const AdminEffectiveTimingProjection({
    required this.effective,
    required this.provenance,
    required this.effectiveDateLabel,
    required this.hasLocationOverride,
  });

  final EffectiveBusinessTimingProfile effective;
  final AdminTimingFieldProvenance provenance;
  final String effectiveDateLabel;
  final bool hasLocationOverride;
}

/// Pure projection of an [AdminBusinessTimingResolution] (the parsed
/// S2 wire) into the canonical resolver output + provenance. Throws
/// [BusinessTimingProfileResolutionException] only if the resolver
/// itself rejects the real candidate chain; callers treat an empty
/// candidate list as "no profile yet" BEFORE calling this.
class AdminBusinessTimingResolutionProjection {
  const AdminBusinessTimingResolutionProjection._();

  static AdminEffectiveTimingProjection project(
    AdminBusinessTimingResolution resolution,
  ) {
    final candidates = resolution.candidates;
    if (candidates.isEmpty) {
      throw const BusinessTimingProfileResolutionException(
        'No business timing profile configured for this location.',
      );
    }

    // The S2 route returns candidates already ordered highest-scope
    // first (operator default) to lowest-scope last (location
    // override) — exactly the order the canonical resolver expects.
    final domainCandidates = <BusinessTimingProfile>[
      for (var i = 0; i < candidates.length; i++)
        _toBusinessTimingProfile(
          candidates[i],
          fallbackTimezone: resolution.ianaTimezone,
          // Only the top (operator default) rung carries the
          // resolver-required shiftCloseAuthority constant. The S2
          // wire does not carry close authority (Gap 31 deletes it
          // as an operator setting) and no admin timing surface
          // displays it, so a fixed value on the root rung satisfies
          // the resolver without affecting any shown value.
          seedCloseAuthority: i == 0,
        ),
    ];

    final EffectiveBusinessTimingProfile effective =
        BusinessTimingProfileResolver.resolve(domainCandidates);
    final provenance = _provenanceForResolvedScope(effective);
    final deepest = candidates.last;
    final hasLocationOverride =
        effective.resolvedScope == BusinessTimingScope.location ||
            candidates.any((c) => c.scopeType == 'location');

    return AdminEffectiveTimingProjection(
      effective: effective,
      provenance: provenance,
      effectiveDateLabel: 'Effective ${deepest.effectiveAtBusinessDate}',
      hasLocationOverride: hasLocationOverride,
    );
  }

  /// Build a domain [BusinessTimingProfile] candidate from an S2
  /// resolution candidate. Mirrors the blessed
  /// `sink_business_date_projector.dart` row->profile shape (and the
  /// op-web `http_business_timing_read_gateway` mapping) so the
  /// resolver semantics are byte-identical between the backend
  /// projector and this admin display projection.
  static BusinessTimingProfile _toBusinessTimingProfile(
    AdminResolutionCandidate c, {
    required String? fallbackTimezone,
    required bool seedCloseAuthority,
  }) {
    final tz = c.ianaTimezone.trim().isNotEmpty
        ? c.ianaTimezone
        : (fallbackTimezone ?? 'UTC');
    return BusinessTimingProfile(
      profileId: c.profileId,
      scope: BusinessTimingScope.fromValue(c.scopeType),
      scopeId: c.scopeId,
      businessTimezone: tz,
      businessDayStartLocalTime: c.businessDayStartLocal,
      weekStartDay: _weekStartToInt(c.weekStartDay),
      servicePeriodDefinitions: c.servicePeriods.isEmpty
          ? null
          : <ServicePeriodDefinition>[
              for (final p in c.servicePeriods)
                ServicePeriodDefinition(
                  id: p.key,
                  label: p.label,
                  shortLabel: p.shortLabel,
                  sortOrder: p.sortOrder,
                  startLocalTime: p.startLocal,
                  endLocalTime: p.endLocal,
                  rollsPastMidnight: p.rollsPastMidnight,
                  applicableDays: p.applicableDays,
                ),
            ],
      shiftCloseAuthority:
          seedCloseAuthority ? ShiftCloseAuthority.vendorFinalization : null,
    );
  }

  static AdminTimingFieldProvenance _provenanceForResolvedScope(
    EffectiveBusinessTimingProfile effective,
  ) {
    switch (effective.resolvedScope) {
      case BusinessTimingScope.operatorDefault:
        return const AdminTimingFieldProvenance(
          sourceLabel: 'Operator default',
          inheritedFromAncestor: true,
        );
      case BusinessTimingScope.orgUnit:
        return const AdminTimingFieldProvenance(
          sourceLabel: 'Org unit override',
          inheritedFromAncestor: true,
        );
      case BusinessTimingScope.location:
        return const AdminTimingFieldProvenance(
          sourceLabel: 'Location override',
          inheritedFromAncestor: false,
        );
    }
  }

  static int _weekStartToInt(String value) {
    switch (value.trim().toLowerCase()) {
      case 'monday':
        return DateTime.monday;
      case 'tuesday':
        return DateTime.tuesday;
      case 'wednesday':
        return DateTime.wednesday;
      case 'thursday':
        return DateTime.thursday;
      case 'friday':
        return DateTime.friday;
      case 'saturday':
        return DateTime.saturday;
      case 'sunday':
        return DateTime.sunday;
    }
    final parsed = int.tryParse(value.trim());
    if (parsed != null &&
        parsed >= DateTime.monday &&
        parsed <= DateTime.sunday) {
      return parsed;
    }
    return DateTime.monday;
  }

  static const List<String> _weekdayNames = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static String weekdayLabel(int isoWeekday) {
    if (isoWeekday < DateTime.monday || isoWeekday > DateTime.sunday) {
      return isoWeekday.toString();
    }
    return _weekdayNames[isoWeekday - 1];
  }

  /// Plain-English day-restriction label, or `null` when the period
  /// runs every day (the common case; no chrome needed). Mirrors the
  /// op-web `_daysLabel`.
  static String? daysLabel(List<int> applicableDays) {
    final days = applicableDays.toSet().toList()..sort();
    if (days.length >= 7) return null;
    if (days.isEmpty) return null;
    const short = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return days
        .where((d) => d >= DateTime.monday && d <= DateTime.sunday)
        .map((d) => short[d - 1])
        .join(', ');
  }
}

/// In-memory [AdminBusinessTimingResolutionGateway] for demo /
/// share-preview / widget tests. Mirrors the established
/// `InMemory*AdminGateway` pattern: production wires the HTTP-backed
/// [HttpAdminBusinessTimingResolutionGateway]; the demo / test path
/// seeds known candidate chains keyed by `(operatorId, locationId)`.
///
/// READ-ONLY (no write surface — admin never writes cross-tenant
/// business-timing).
class InMemoryAdminBusinessTimingResolutionGateway
    implements AdminBusinessTimingResolutionGateway {
  InMemoryAdminBusinessTimingResolutionGateway({
    Map<String, AdminBusinessTimingResolution>? seed,
  }) : _seed = <String, AdminBusinessTimingResolution>{...?seed};

  /// Keyed `'<operatorId>::<locationId>'`. A missing key resolves to
  /// an EMPTY candidate list so the screen renders its honest
  /// "no timing profile yet" state instead of fabricating values.
  final Map<String, AdminBusinessTimingResolution> _seed;

  static String keyFor(String operatorId, String locationId) =>
      '$operatorId::$locationId';

  void put(
    String operatorId,
    String locationId,
    AdminBusinessTimingResolution resolution,
  ) {
    _seed[keyFor(operatorId, locationId)] = resolution;
  }

  @override
  Future<AdminBusinessTimingResolution> resolve({
    required String operatorId,
    required String locationId,
    String? businessDate,
  }) async {
    final found = _seed[keyFor(operatorId, locationId)];
    if (found != null) return found;
    return AdminBusinessTimingResolution(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate ?? '',
      ianaTimezone: null,
      candidates: const <AdminResolutionCandidate>[],
    );
  }
}
