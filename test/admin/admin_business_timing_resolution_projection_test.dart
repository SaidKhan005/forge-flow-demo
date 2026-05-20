// Fix #4 / S4 (G41 + G42) — tests for the admin-side business-timing
// display projection (the admin analogue of the S3 op-web
// `http_business_timing_read_gateway` projection).
//
// Covers (spec §4):
//  - PARITY: the same candidate chain, projected through (a) the
//    blessed `sink_business_date_projector` row->profile mapping and
//    (b) the new S4 admin projection, yields an identical
//    `EffectiveBusinessTimingProfile`.
//  - PROVENANCE: a 3-level org-unit fixture INCLUDING a deliberate
//    same-value override — the field is labeled an override, NOT
//    "inherited" (the exact case the deleted synthetic scope-flag
//    path got wrong).
//  - NO-SYNTHETIC: a config with a 4th service period and a
//    non-default (non-Monday) week-start renders the REAL resolved
//    values — the deleted hardcoded 3-period / "Monday" / close-rule
//    path could not have produced this.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/domain/models/business_timing_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/business_timing_profile_resolver.dart';

void main() {
  group('AdminBusinessTimingResolutionProjection', () {
    test('admin Timing dialog labels timezone as location-owned', () {
      final operatorLocationSource = File(
        'lib/admin/screens/operator_location_admin_screen.dart',
      ).readAsStringSync();
      final timingSetupSource = File(
        'lib/admin/screens/admin_timing_setup_screen.dart',
      ).readAsStringSync();
      expect(operatorLocationSource, contains("label: 'Timezone source'"));
      expect(operatorLocationSource, contains("value: 'Location timezone'"));
      expect(operatorLocationSource, contains("label: 'Week-start source'"));
      expect(timingSetupSource, contains("label: 'Timezone source'"));
      expect(timingSetupSource, contains("value: 'Location timezone'"));
      expect(timingSetupSource, contains("label: 'Week-start source'"));
    });

    test(
      'throws for an empty candidate chain (caller renders empty state)',
      () {
        final resolution = _resolution(
          candidates: const <AdminResolutionCandidate>[],
        );
        expect(
          () => AdminBusinessTimingResolutionProjection.project(resolution),
          throwsA(isA<BusinessTimingProfileResolutionException>()),
        );
      },
    );

    test('operator-default-only chain: provenance is "Operator default" and '
        'inherited', () {
      final resolution = _resolution(
        candidates: <AdminResolutionCandidate>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
          ),
        ],
      );
      final projection = AdminBusinessTimingResolutionProjection.project(
        resolution,
      );
      expect(projection.provenance.sourceLabel, equals('Operator default'));
      expect(projection.provenance.inheritedFromAncestor, isTrue);
      expect(
        projection.provenance.detailLabel,
        equals('Inherited (Operator default)'),
      );
      expect(projection.hasLocationOverride, isFalse);
      expect(projection.effective.businessTimezone, equals('America/Toronto'));
    });

    // ---- Mandatory parity test (spec §4 / D7/G51 lesson) ----
    test('PARITY: same candidate chain through the blessed projector mapping '
        'and the S4 admin projection resolves identically', () {
      // Canonical reference: the blessed
      // `sink_business_date_projector._toBusinessTimingProfile` row->
      // profile shape (byte-identical to the open-shift projector),
      // resolved through the ONE canonical resolver.
      final canonicalCandidates = <BusinessTimingProfile>[
        _blessedProfile(
          profileId: 'op-default',
          scopeType: 'operator',
          scopeId: 'op-1',
          tz: 'America/Toronto',
          dayStart: '04:00',
          weekStart: DateTime.monday,
          periods: const <ServicePeriodDefinition>[
            ServicePeriodDefinition(
              id: 'lunch',
              label: 'Lunch',
              shortLabel: 'L',
              sortOrder: 1,
              startLocalTime: '11:00',
              endLocalTime: '15:00',
              rollsPastMidnight: false,
              applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
            ),
          ],
          seedCloseAuthority: true,
        ),
        _blessedProfile(
          profileId: 'ou-region',
          scopeType: 'org_unit',
          scopeId: 'ou-east',
          tz: null,
          dayStart: '05:00',
          weekStart: null,
          periods: null,
          seedCloseAuthority: false,
        ),
        _blessedProfile(
          profileId: 'loc-override',
          scopeType: 'location',
          scopeId: 'loc-1',
          tz: 'America/Vancouver',
          dayStart: null,
          weekStart: null,
          periods: null,
          seedCloseAuthority: false,
        ),
      ];
      final canonical = BusinessTimingProfileResolver.resolve(
        canonicalCandidates,
      );

      // S4 admin path: the SAME chain in the documented S2 wire shape,
      // every field denormalised on every rung (the canonical CTE
      // emits one row per configured scope with all fields).
      final resolution = _resolution(
        topTimezone: 'America/Toronto',
        candidates: <AdminResolutionCandidate>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
            periods: <AdminResolutionServicePeriod>[
              _period(
                'lunch',
                'Lunch',
                '11:00',
                '15:00',
                shortLabel: 'L',
                sortOrder: 1,
              ),
            ],
          ),
          _candidate(
            profileId: 'ou-region',
            scopeType: 'org_unit',
            scopeId: 'ou-east',
            scopeLabel: 'East Region',
            rank: 1,
            tz: 'America/Toronto',
            dayStart: '05:00',
            weekStart: 'monday',
            periods: <AdminResolutionServicePeriod>[
              _period(
                'lunch',
                'Lunch',
                '11:00',
                '15:00',
                shortLabel: 'L',
                sortOrder: 1,
              ),
            ],
          ),
          _candidate(
            profileId: 'loc-override',
            scopeType: 'location',
            scopeId: 'loc-1',
            scopeLabel: 'Yonge & Bloor',
            rank: 2,
            tz: 'America/Vancouver',
            dayStart: '05:00',
            weekStart: 'monday',
            periods: <AdminResolutionServicePeriod>[
              _period(
                'lunch',
                'Lunch',
                '11:00',
                '15:00',
                shortLabel: 'L',
                sortOrder: 1,
              ),
            ],
          ),
        ],
      );
      final admin = AdminBusinessTimingResolutionProjection.project(
        resolution,
      ).effective;

      expect(admin.businessTimezone, equals(canonical.businessTimezone));
      expect(
        admin.businessDayStartLocalTime,
        equals(canonical.businessDayStartLocalTime),
      );
      expect(admin.weekStartDay, equals(canonical.weekStartDay));
      expect(admin.resolvedScope, equals(canonical.resolvedScope));
      expect(admin.resolvedScopeId, equals(canonical.resolvedScopeId));
      expect(
        admin.servicePeriodDefinitions.map((p) => p.id).toList(),
        equals(canonical.servicePeriodDefinitions.map((p) => p.id).toList()),
      );
      expect(
        admin.servicePeriodDefinitions.first.startLocalTime,
        equals(canonical.servicePeriodDefinitions.first.startLocalTime),
      );
      // Effective values: timezone from the location override,
      // business-day-start from the org-unit — proves the full chain
      // (incl. the intermediate org-unit rung the OLD synthetic path
      // discarded) flowed end-to-end.
      expect(admin.businessTimezone, equals('America/Vancouver'));
      expect(admin.businessDayStartLocalTime, equals('05:00'));
    });

    // ---- Provenance: 3-level fixture + deliberate same-value override
    test('PROVENANCE: a same-value override on the location rung is labeled '
        'an override, not "inherited"', () {
      // operator weekStart=monday -> org-unit weekStart=monday
      // (DELIBERATE same value) -> location weekStart=monday (also a
      // deliberate same-value row). The deleted synthetic scope-flag
      // path keyed provenance off `selectedScope.isOrgUnitScope` /
      // `isBusinessScope`, NOT the resolver's resolved scope, so it
      // could label a real location override "Inherited from
      // business". The resolver-chain walk must report the LOCATION
      // rung as the contributor (deepest configured scope = override).
      final resolution = _resolution(
        candidates: <AdminResolutionCandidate>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            weekStart: 'monday',
          ),
          _candidate(
            profileId: 'ou-region',
            scopeType: 'org_unit',
            scopeId: 'ou-east',
            scopeLabel: 'East Region',
            rank: 1,
            // Deliberate SAME value as the operator default.
            weekStart: 'monday',
          ),
          _candidate(
            profileId: 'loc-1-profile',
            scopeType: 'location',
            scopeId: 'loc-1',
            scopeLabel: 'Yonge & Bloor',
            rank: 2,
            // Deliberate SAME value again — a real location override
            // row whose value happens to equal the parent's.
            weekStart: 'monday',
          ),
        ],
      );
      final projection = AdminBusinessTimingResolutionProjection.project(
        resolution,
      );
      expect(projection.effective.weekStartDay, equals(DateTime.monday));
      expect(
        AdminBusinessTimingResolutionProjection.weekdayLabel(
          projection.effective.weekStartDay,
        ),
        equals('Monday'),
      );
      // Deepest configured scope is the LOCATION rung => override,
      // NOT inherited. The old synthetic path would have said
      // "Inherited from business".
      expect(
        projection.provenance.inheritedFromAncestor,
        isFalse,
        reason: 'same-value deeper override must NOT read as inherited',
      );
      expect(projection.provenance.sourceLabel, equals('Location override'));
      expect(projection.provenance.detailLabel, equals('Location override'));
      expect(projection.hasLocationOverride, isTrue);
    });

    // ---- No-synthetic regression: real 4-period / non-Monday config
    test('NO-SYNTHETIC: a 4th service period + a non-default week-start '
        'render the REAL resolved values', () {
      // The deleted G41 path hardcoded exactly 3 periods (Lunch /
      // Dinner / Late night) + "Monday"; the deleted G42 path used
      // `_defaultAdminTimingServicePeriods` (3 fixed periods) +
      // `DateTime.monday`. Neither could produce a 4th period or a
      // Thursday week-start. This config proves the values are real.
      final resolution = _resolution(
        candidates: <AdminResolutionCandidate>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            weekStart: 'thursday',
            periods: <AdminResolutionServicePeriod>[
              _period(
                'breakfast',
                'Breakfast',
                '06:00',
                '10:30',
                shortLabel: 'B',
                sortOrder: 1,
              ),
              _period(
                'lunch',
                'Lunch',
                '10:30',
                '15:00',
                shortLabel: 'L',
                sortOrder: 2,
              ),
              _period(
                'dinner',
                'Dinner',
                '15:00',
                '21:00',
                shortLabel: 'D',
                sortOrder: 3,
              ),
              _period(
                'weekend_brunch',
                'Weekend Brunch',
                '21:00',
                '23:30',
                shortLabel: 'WB',
                sortOrder: 4,
                applicableDays: <int>[6, 7],
              ),
            ],
          ),
        ],
      );
      final projection = AdminBusinessTimingResolutionProjection.project(
        resolution,
      );
      final periods = projection.effective.servicePeriodDefinitions.toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

      // FOUR periods (the old hardcoded path capped at 3).
      expect(periods, hasLength(4));
      expect(
        periods.map((p) => p.label).toList(),
        equals(<String>['Breakfast', 'Lunch', 'Dinner', 'Weekend Brunch']),
      );
      // Non-Monday week start (the old path hardcoded Monday).
      expect(projection.effective.weekStartDay, equals(DateTime.thursday));
      expect(
        AdminBusinessTimingResolutionProjection.weekdayLabel(
          projection.effective.weekStartDay,
        ),
        equals('Thursday'),
      );
      // Day-restricted 4th period surfaces its restriction (G45/Gap
      // 28) — the old hardcoded set was always all-days.
      expect(
        AdminBusinessTimingResolutionProjection.daysLabel(
          periods.last.applicableDays,
        ),
        equals('Sat, Sun'),
      );
      // An all-days period gets no restriction chrome.
      expect(
        AdminBusinessTimingResolutionProjection.daysLabel(
          periods.first.applicableDays,
        ),
        isNull,
      );
    });

    test(
      'InMemory gateway returns an empty chain for an unseeded key',
      () async {
        final gw = InMemoryAdminBusinessTimingResolutionGateway();
        final res = await gw.resolve(operatorId: 'op-x', locationId: 'loc-x');
        expect(res.candidates, isEmpty);
        expect(res.operatorId, equals('op-x'));
        expect(res.locationId, equals('loc-x'));
      },
    );

    test(
      'InMemory gateway serves a seeded chain by (operator, location)',
      () async {
        final gw = InMemoryAdminBusinessTimingResolutionGateway();
        gw.put(
          'op-1',
          'loc-1',
          _resolution(
            candidates: <AdminResolutionCandidate>[
              _candidate(
                profileId: 'op-default',
                scopeType: 'operator',
                scopeId: 'op-1',
                scopeLabel: 'Acme Eats',
                rank: 0,
              ),
            ],
          ),
        );
        final res = await gw.resolve(operatorId: 'op-1', locationId: 'loc-1');
        expect(res.candidates, hasLength(1));
        final projection = AdminBusinessTimingResolutionProjection.project(res);
        expect(
          projection.effective.businessTimezone,
          equals('America/Toronto'),
        );
      },
    );
  });
}

// --- helpers -------------------------------------------------------

AdminResolutionServicePeriod _period(
  String key,
  String label,
  String start,
  String end, {
  String shortLabel = '',
  int sortOrder = 0,
  List<int> applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
  bool rollsPastMidnight = false,
}) {
  return AdminResolutionServicePeriod(
    key: key,
    label: label,
    startLocal: start,
    endLocal: end,
    rollsPastMidnight: rollsPastMidnight,
    shortLabel: shortLabel,
    sortOrder: sortOrder,
    applicableDays: applicableDays,
  );
}

AdminResolutionCandidate _candidate({
  required String profileId,
  required String scopeType,
  required String scopeId,
  required String scopeLabel,
  required int rank,
  String tz = 'America/Toronto',
  String dayStart = '04:00',
  String weekStart = 'monday',
  List<AdminResolutionServicePeriod>? periods,
}) {
  return AdminResolutionCandidate(
    profileId: profileId,
    scopeType: scopeType,
    scopeId: scopeId,
    scopeLabel: scopeLabel,
    scopeDepthRank: rank,
    ianaTimezone: tz,
    effectiveAtBusinessDate: '2026-05-01',
    weekStartDay: weekStart,
    businessDayStartLocal: dayStart,
    servicePeriods:
        periods ??
        <AdminResolutionServicePeriod>[
          _period('lunch', 'Lunch', '11:00', '15:00'),
        ],
  );
}

AdminBusinessTimingResolution _resolution({
  required List<AdminResolutionCandidate> candidates,
  String topTimezone = 'America/Toronto',
}) {
  return AdminBusinessTimingResolution(
    operatorId: 'op-1',
    locationId: 'loc-1',
    businessDate: '2026-05-01',
    ianaTimezone: topTimezone,
    candidates: candidates,
  );
}

/// Replicates the blessed `sink_business_date_projector
/// ._toBusinessTimingProfile` row->profile mapping (byte-identical to
/// the open-shift projector) so the parity test has a canonical
/// reference independent of the S4 admin projection code path.
BusinessTimingProfile _blessedProfile({
  required String profileId,
  required String scopeType,
  required String scopeId,
  required String? tz,
  required String? dayStart,
  required int? weekStart,
  required List<ServicePeriodDefinition>? periods,
  required bool seedCloseAuthority,
}) {
  return BusinessTimingProfile(
    profileId: profileId,
    scope: BusinessTimingScope.fromValue(scopeType),
    scopeId: scopeId,
    businessTimezone: tz,
    businessDayStartLocalTime: dayStart,
    weekStartDay: weekStart,
    servicePeriodDefinitions: periods,
    shiftCloseAuthority: seedCloseAuthority
        ? ShiftCloseAuthority.vendorFinalization
        : null,
  );
}
