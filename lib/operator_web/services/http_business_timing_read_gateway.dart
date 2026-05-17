// Doc 1 timing web/admin live parity (2026-05-08) - Operator Web
// Business setup live read adapter.
//
// Fix #4 / S3 (G13) — REWRITTEN 2026-05-16. Previously this adapter
// listed the operator's profiles via `GET /v1/operator/business-
// timing-profiles` and ran a lossy operator-web-only local resolver
// (`business_business_timing_resolver_local.dart`, now DELETED) whose
// `:56` same-value heuristic mislabeled a deliberate same-value
// override as "inherited". It also discarded every org-unit rung
// between the operator default and the location.
//
// It now consumes the S1 route
// `GET /v1/operator/locations/:locationId/business-timing-resolution`
// (PR #872) which returns the FULL ordered candidate chain (operator
// default -> org-unit ancestors -> location override) in canonical
// `scope_depth asc` precedence order with scope ancestry + the
// location timezone + full service-period fields. The adapter maps
// those candidates to the domain `BusinessTimingProfile` (mirroring
// the blessed `sink_business_date_projector.dart` row->profile
// mapping) and runs the ONE canonical pure
// `BusinessTimingProfileResolver`. Per-field provenance is derived
// from the resolver's `inheritanceChain` / `resolvedScope` on the
// resulting `EffectiveBusinessTimingProfile` — no client-side
// heuristic, no resolver fork.
//
// Scope: read-only adapter; writes still flow through
// [WebBusinessTimingGateway] from the editor screen, and
// [BusinessTimingProfileWriteResult] carries the existing resolved
// profile back to the editor (sub-deliverable 2 of the closeout doc).

import '../../domain/models/business_timing_profile.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/business_timing_profile_resolver.dart';
import 'business_timing_gateway.dart';
import 'web_business_timing_gateway.dart';

/// Live read adapter that resolves the operator's business-timing
/// inheritance chain through the canonical resolver and projects it
/// into the [BusinessTimingBundle] the Business setup screen renders.
/// Implements [BusinessTimingGateway] so the existing screen surface
/// stays untouched - only the wiring changes.
class HttpBusinessTimingReadGateway implements BusinessTimingGateway {
  HttpBusinessTimingReadGateway({
    required WebBusinessTimingGateway gateway,
  }) : _gateway = gateway;

  final WebBusinessTimingGateway _gateway;

  /// The ordered candidate chain pulled from the most recent
  /// successful [loadTiming], in canonical resolver precedence order
  /// (operator default first, location override last). Persisted
  /// between reads so the router can hand the resolved profile to the
  /// editor (sub-deliverable 2: "Pass existing resolved/profile state
  /// into the timing editor instead of defaulting to a new
  /// profile.").
  List<BusinessTimingResolutionCandidate> _lastCandidates =
      const <BusinessTimingResolutionCandidate>[];

  /// The candidate chain from the most recent successful [loadTiming],
  /// projected to the editor's [BusinessTimingProfileWriteResult]
  /// shape. Empty before the first call.
  List<BusinessTimingProfileWriteResult> get lastProfiles =>
      <BusinessTimingProfileWriteResult>[
        for (final c in _lastCandidates) _candidateToWriteResult(c),
      ];

  /// Picks the location-scoped candidate (when present) for
  /// [locationId]; otherwise falls back to the operator default; else
  /// the deepest candidate. Returns `null` when no candidate was
  /// loaded so the editor can still mount in create mode.
  ///
  /// G45 / Gap 28: the returned [BusinessTimingProfileWriteResult]
  /// carries the FULL service-period fields (`applicableDays` /
  /// `shortLabel` / `sortOrder`) the S1 wire now provides, so a
  /// day-restricted period round-trips into the editor instead of
  /// being silently flattened to all-days.
  BusinessTimingProfileWriteResult? selectProfileForLocation(
    String locationId,
  ) {
    if (_lastCandidates.isEmpty) return null;
    for (final c in _lastCandidates) {
      if (c.scopeType == 'location' && c.scopeId == locationId) {
        return _candidateToWriteResult(c);
      }
    }
    for (final c in _lastCandidates) {
      if (c.scopeType == 'operator') {
        return _candidateToWriteResult(c);
      }
    }
    return _candidateToWriteResult(_lastCandidates.last);
  }

  @override
  Future<BusinessTimingBundle> loadTiming({
    required String operatorId,
    required String locationId,
    String? operatorName,
    String? locationName,
  }) async {
    // S1 route: full ordered candidate chain for this location. The
    // proxy defaults `business_date` to UTC today when omitted,
    // matching the existing resolved-timing-config caller's default.
    final resolution = await _gateway.resolveForLocation(
      locationId: locationId,
    );
    _lastCandidates = List<BusinessTimingResolutionCandidate>.unmodifiable(
      resolution.candidates,
    );
    return _projectBundle(
      operatorId: operatorId,
      locationId: locationId,
      operatorName: operatorName,
      locationName: locationName,
      resolution: resolution,
    );
  }

  BusinessTimingBundle _projectBundle({
    required String operatorId,
    required String locationId,
    required String? operatorName,
    required String? locationName,
    required BusinessTimingResolutionResult resolution,
  }) {
    final opName = _clean(operatorName) ?? 'Operator';
    final locName = _clean(locationName) ?? 'This location';
    final candidates = resolution.candidates;

    if (candidates.isEmpty) {
      return BusinessTimingBundle(
        operatorId: operatorId,
        locationId: locationId,
        operatorName: opName,
        locationName: locName,
        effectiveDateLabel: 'No timing profile yet',
        hasLocationOverride: false,
        writesAvailable: true,
        inheritanceChain: <BusinessTimingScopeSummary>[
          BusinessTimingScopeSummary(
            label: opName,
            scopeKind: 'Operator default',
            summary:
                'No operator default has been saved. Save a profile to '
                'lock the timing rules used by Shift.',
            active: false,
          ),
          BusinessTimingScopeSummary(
            label: locName,
            scopeKind: 'Location',
            summary: 'No location override; will inherit operator default.',
            active: false,
          ),
        ],
        effectiveFields: const <BusinessTimingInheritedValue>[],
        servicePeriods: const <BusinessTimingServicePeriod>[],
      );
    }

    // The S1 route returns candidates already ordered highest-scope
    // first (operator default) to lowest-scope last (location
    // override) — exactly the order the canonical resolver expects.
    // Map each rung to the domain `BusinessTimingProfile` (mirroring
    // the blessed `sink_business_date_projector` row->profile shape)
    // and run the ONE canonical resolver. No resolver fork; no
    // client-side same-value heuristic.
    final domainCandidates = <BusinessTimingProfile>[
      for (var i = 0; i < candidates.length; i++)
        _toBusinessTimingProfile(
          candidates[i],
          fallbackTimezone: resolution.ianaTimezone,
          // Only the top (operator default) rung carries the
          // resolver-required shiftCloseAuthority constant. The S1
          // wire does not carry close authority (Gap 31 deletes it
          // as an operator setting) and the operator-web Business
          // setup surface never displays it, so a fixed value on the
          // root rung satisfies the resolver without affecting any
          // shown value.
          seedCloseAuthority: i == 0,
        ),
    ];

    final EffectiveBusinessTimingProfile effective =
        BusinessTimingProfileResolver.resolve(domainCandidates);

    // Per-field provenance from the resolver's resolved scope.
    //
    // The S1 route returns one candidate per scope that ACTUALLY has
    // a profile row (the canonical CTE only emits scopes the operator
    // configured), with every field denormalised on every row. So the
    // honest source of any effective field is the DEEPEST configured
    // scope: a profile row existing at the location scope means the
    // operator deliberately created a location override — even when
    // its field values equal the parent's. This is exactly the case
    // the deleted `:56` same-value heuristic got wrong; deriving the
    // source from the resolver's `resolvedScope` (deepest candidate)
    // instead of from a value comparison fixes it.
    //
    // `inherited` = the resolved scope is a default that flows DOWN
    // to the location (operator / org-unit), i.e. NOT a
    // location-specific override.
    final provenance = _provenanceForResolvedScope(effective);

    final inheritance = <BusinessTimingScopeSummary>[
      for (final candidate in candidates)
        BusinessTimingScopeSummary(
          label: candidate.scopeLabel,
          scopeKind: _scopeKindLabel(candidate.scopeType),
          summary: _scopeSummary(candidate),
          // A rung is "active" when it contributes at least one
          // resolved field (it is in the inheritance chain AND set a
          // value the resolver kept or was overridden by a deeper
          // rung). Every candidate the CTE returned contributed at
          // least its effective-date window, so each is a real rung.
          active: true,
        ),
    ];

    final fields = <BusinessTimingInheritedValue>[
      BusinessTimingInheritedValue(
        label: 'Timezone',
        value: effective.businessTimezone,
        sourceLabel: provenance.sourceLabel,
        inherited: provenance.inheritedFromAncestor,
      ),
      BusinessTimingInheritedValue(
        label: 'Business day starts',
        value: effective.businessDayStartLocalTime,
        sourceLabel: provenance.sourceLabel,
        inherited: provenance.inheritedFromAncestor,
      ),
      BusinessTimingInheritedValue(
        label: 'Week starts',
        value: _weekdayLabel(effective.weekStartDay),
        sourceLabel: provenance.sourceLabel,
        inherited: provenance.inheritedFromAncestor,
      ),
    ];

    final periods = <BusinessTimingServicePeriod>[
      for (final period in effective.servicePeriodDefinitions)
        BusinessTimingServicePeriod(
          name: period.label,
          startsAt: period.startLocalTime,
          endsAt: period.endLocalTime,
          sourceLabel: provenance.sourceLabel,
          rollsPastMidnight: period.rollsPastMidnight,
          // G45 / Gap 28: surface day-restricted periods instead of
          // implying every period runs all week.
          daysLabel: _daysLabel(period.applicableDays),
        ),
    ];

    final hasLocationOverride = effective.resolvedScope ==
            BusinessTimingScope.location ||
        candidates.any((c) => c.scopeType == 'location');
    final deepest = candidates.last;
    final effectiveDateLabel =
        'Effective ${deepest.effectiveAtBusinessDate}';

    return BusinessTimingBundle(
      operatorId: operatorId,
      locationId: locationId,
      operatorName: opName,
      locationName: locName,
      effectiveDateLabel: effectiveDateLabel,
      hasLocationOverride: hasLocationOverride,
      writesAvailable: true,
      inheritanceChain: inheritance,
      effectiveFields: fields,
      servicePeriods: periods,
    );
  }

  /// Build a domain [BusinessTimingProfile] candidate from an S1
  /// resolution candidate. Mirrors the blessed
  /// `sink_business_date_projector.dart` row->profile shape so the
  /// resolver semantics are identical between the backend projector
  /// and this display projection.
  static BusinessTimingProfile _toBusinessTimingProfile(
    BusinessTimingResolutionCandidate c, {
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
      // The S1 wire does not carry close authority (Gap 31 removes it
      // as an operator setting). Seed a fixed value on the root rung
      // so the canonical resolver — which requires a
      // shiftCloseAuthority after inheritance — does not throw. This
      // is never surfaced on the operator-web Business setup screen,
      // so the constant is display-neutral.
      shiftCloseAuthority:
          seedCloseAuthority ? ShiftCloseAuthority.vendorFinalization : null,
    );
  }

  /// Map an S1 candidate back to the editor's
  /// [BusinessTimingProfileWriteResult] (the type the editor screen
  /// and `_resolvedExistingTimingProfile` consume). Service periods
  /// keep their full `applicableDays` / `shortLabel` / `sortOrder`
  /// for the G45 round-trip.
  static BusinessTimingProfileWriteResult _candidateToWriteResult(
    BusinessTimingResolutionCandidate c,
  ) {
    return BusinessTimingProfileWriteResult(
      profileId: c.profileId,
      versionId: c.profileId,
      scopeKind: c.scopeType,
      scopeId: c.scopeId,
      effectiveAtBusinessDate: c.effectiveAtBusinessDate,
      ianaTimezone: c.ianaTimezone,
      weekStartDay: c.weekStartDay,
      businessDayStartLocal: c.businessDayStartLocal,
      servicePeriods: List<ServicePeriod>.from(c.servicePeriods),
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
  }

  /// Provenance from the resolver's `resolvedScope` — the DEEPEST
  /// configured scope in the chain.
  ///
  /// The S1 CTE emits one candidate per scope that actually has a
  /// profile row, with every field denormalised on every row, so the
  /// honest "where did the effective value come from" answer is the
  /// deepest scope the operator configured:
  ///   - operator-only chain  -> "Operator default", inherited
  ///   - operator + org-unit  -> "Org unit override", inherited
  ///     (org-unit is still an ancestor of the location being viewed)
  ///   - any location profile -> "Location override", NOT inherited
  ///     (a deliberate location-scoped row — even if its field values
  ///     equal the parent's; this is the exact same-value case the
  ///     deleted `:56` heuristic mislabeled as "inherited").
  ///
  /// `inherited` is true when the effective value flows DOWN from a
  /// default scope (operator / org-unit) to the location surface the
  /// operator is viewing, and false when the location itself supplied
  /// a deliberate override.
  static _FieldProvenance _provenanceForResolvedScope(
    EffectiveBusinessTimingProfile effective,
  ) {
    switch (effective.resolvedScope) {
      case BusinessTimingScope.operatorDefault:
        return const _FieldProvenance(
          sourceLabel: 'Operator default',
          inheritedFromAncestor: true,
        );
      case BusinessTimingScope.orgUnit:
        return const _FieldProvenance(
          sourceLabel: 'Org unit override',
          inheritedFromAncestor: true,
        );
      case BusinessTimingScope.location:
        return const _FieldProvenance(
          sourceLabel: 'Location override',
          inheritedFromAncestor: false,
        );
    }
  }

  static String _scopeKindLabel(String scopeType) {
    switch (scopeType) {
      case 'operator':
        return 'Operator default';
      case 'org_unit':
        return 'Org unit';
      case 'location':
        return 'Location';
    }
    return scopeType;
  }

  static String _scopeSummary(BusinessTimingResolutionCandidate c) {
    final effective = 'Effective ${c.effectiveAtBusinessDate}.';
    switch (c.scopeType) {
      case 'operator':
        return 'Default timing for the operator. $effective';
      case 'org_unit':
        return 'Org-unit override. $effective';
      case 'location':
        return 'Location override. $effective';
    }
    return effective;
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
    if (parsed != null && parsed >= DateTime.monday &&
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

  static String _weekdayLabel(int isoWeekday) {
    if (isoWeekday < DateTime.monday || isoWeekday > DateTime.sunday) {
      return isoWeekday.toString();
    }
    return _weekdayNames[isoWeekday - 1];
  }

  /// G45 — plain-English day-restriction label, or `null` when the
  /// period runs every day (the common case; no chrome needed).
  static String? _daysLabel(List<int> applicableDays) {
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

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class _FieldProvenance {
  const _FieldProvenance({
    required this.sourceLabel,
    required this.inheritedFromAncestor,
  });

  final String sourceLabel;
  final bool inheritedFromAncestor;
}
