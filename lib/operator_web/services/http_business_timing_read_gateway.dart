// Doc 1 timing web/admin live parity (2026-05-08) - Operator Web
// Business setup live read adapter.
//
// Closes the leftover from
// `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md` -
// "Hydrate Operator Web timing reads from live server truth instead of
// demo fallback." The Business setup screen renders inheritance,
// effective fields, and service periods. Until now the operator-web
// router fell back to [DemoBusinessTimingGateway] even on a live
// session; this adapter delegates to the operator-scoped
// [WebBusinessTimingGateway] (`GET /v1/operator/business-timing-
// profiles`) and projects the resolver-precedence list into the
// [BusinessTimingBundle] the read view consumes.
//
// Scope: read-only adapter; writes still flow through
// [WebBusinessTimingGateway] from the editor screen, and
// [BusinessTimingProfileWriteResult] carries the existing profile back
// to the editor (sub-deliverable 2 of the closeout doc).

import 'business_business_timing_resolver_local.dart';
import 'business_timing_gateway.dart';
import 'web_business_timing_gateway.dart';

/// Live read adapter that projects operator-scoped timing-profile
/// records into the [BusinessTimingBundle] the Business setup screen
/// renders. Implements [BusinessTimingGateway] so the existing screen
/// surface stays untouched - only the wiring changes.
class HttpBusinessTimingReadGateway implements BusinessTimingGateway {
  HttpBusinessTimingReadGateway({
    required WebBusinessTimingGateway gateway,
  }) : _gateway = gateway;

  final WebBusinessTimingGateway _gateway;

  /// Most-recent profile list pulled from the proxy. Persisted between
  /// reads so the router can hand the resolved profile to the editor
  /// (sub-deliverable 2: "Pass existing resolved/profile state into the
  /// timing editor instead of defaulting to a new profile.").
  List<BusinessTimingProfileWriteResult> _lastProfiles =
      const <BusinessTimingProfileWriteResult>[];

  /// Profiles snapshot from the most recent successful [loadTiming].
  /// Empty before the first call.
  List<BusinessTimingProfileWriteResult> get lastProfiles =>
      List<BusinessTimingProfileWriteResult>.unmodifiable(_lastProfiles);

  /// Picks the location-scoped profile (when present) for [locationId];
  /// otherwise falls back to the deepest profile by precedence (the
  /// resolver returns operator-scope last after locations). Returns
  /// `null` when [_lastProfiles] is empty so the editor can still mount
  /// in create mode.
  BusinessTimingProfileWriteResult? selectProfileForLocation(
    String locationId,
  ) {
    if (_lastProfiles.isEmpty) return null;
    for (final profile in _lastProfiles) {
      if (profile.scopeKind == 'location' && profile.scopeId == locationId) {
        return profile;
      }
    }
    for (final profile in _lastProfiles) {
      if (profile.scopeKind == 'operator') {
        return profile;
      }
    }
    return _lastProfiles.first;
  }

  @override
  Future<BusinessTimingBundle> loadTiming({
    required String operatorId,
    required String locationId,
    String? operatorName,
    String? locationName,
  }) async {
    final profiles = await _gateway.listProfiles();
    _lastProfiles = List<BusinessTimingProfileWriteResult>.unmodifiable(
      profiles,
    );
    return _projectBundle(
      operatorId: operatorId,
      locationId: locationId,
      operatorName: operatorName,
      locationName: locationName,
      profiles: profiles,
    );
  }

  BusinessTimingBundle _projectBundle({
    required String operatorId,
    required String locationId,
    required String? operatorName,
    required String? locationName,
    required List<BusinessTimingProfileWriteResult> profiles,
  }) {
    final opName = _clean(operatorName) ?? 'Operator';
    final locName = _clean(locationName) ?? 'This location';

    if (profiles.isEmpty) {
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

    // Walk the candidate stack lowest-first so the resolver applies
    // overrides correctly. The proxy returns operator-scope first by
    // precedence, then org-units, then locations; reverse for the
    // resolver, but render the inheritance chain in display order
    // (top-down, operator first).
    final operatorProfile = profiles.firstWhere(
      (p) => p.scopeKind == 'operator',
      orElse: () => profiles.first,
    );
    final locationProfile = profiles
        .where((p) => p.scopeKind == 'location' && p.scopeId == locationId)
        .cast<BusinessTimingProfileWriteResult?>()
        .firstWhere((_) => true, orElse: () => null);

    final resolved = resolveOperatorWebTimingFields(
      operatorProfile: operatorProfile,
      locationProfile: locationProfile,
    );

    final inheritance = <BusinessTimingScopeSummary>[
      BusinessTimingScopeSummary(
        label: opName,
        scopeKind: 'Operator default',
        summary:
            'Default timing for the operator. Effective '
            '${operatorProfile.effectiveAtBusinessDate}.',
        active: true,
      ),
      BusinessTimingScopeSummary(
        label: locName,
        scopeKind: 'Location',
        summary: locationProfile == null
            ? 'No location override; inherits from operator default.'
            : 'Location override effective '
                '${locationProfile.effectiveAtBusinessDate}.',
        active: locationProfile != null,
      ),
    ];

    final fields = <BusinessTimingInheritedValue>[
      BusinessTimingInheritedValue(
        label: 'Timezone',
        value: resolved.timezone.value,
        sourceLabel: resolved.timezone.sourceLabel,
        inherited: resolved.timezone.inheritedFromOperator,
      ),
      BusinessTimingInheritedValue(
        label: 'Business day starts',
        value: resolved.businessDayStart.value,
        sourceLabel: resolved.businessDayStart.sourceLabel,
        inherited: resolved.businessDayStart.inheritedFromOperator,
      ),
      BusinessTimingInheritedValue(
        label: 'Week starts',
        value: _capitalize(resolved.weekStartDay.value),
        sourceLabel: resolved.weekStartDay.sourceLabel,
        inherited: resolved.weekStartDay.inheritedFromOperator,
      ),
    ];

    final periods = <BusinessTimingServicePeriod>[
      for (final period in resolved.servicePeriods.value)
        BusinessTimingServicePeriod(
          name: period.label,
          startsAt: period.startLocal,
          endsAt: period.endLocal,
          sourceLabel: resolved.servicePeriods.sourceLabel,
          rollsPastMidnight: period.rollsPastMidnight,
        ),
    ];

    final hasLocationOverride = locationProfile != null;
    final effectiveDateLabel = hasLocationOverride
        ? 'Effective ${locationProfile.effectiveAtBusinessDate}'
        : 'Effective ${operatorProfile.effectiveAtBusinessDate}';

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

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  static String _capitalize(String input) {
    if (input.isEmpty) return input;
    return input[0].toUpperCase() + input.substring(1).toLowerCase();
  }
}
