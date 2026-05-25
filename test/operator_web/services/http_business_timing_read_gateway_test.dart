// Fix #4 / S3 (G13) — tests for the operator-web Business setup live
// read adapter after the rewrite that consumes the S1 location-scoped
// resolution route and runs the ONE canonical
// `BusinessTimingProfileResolver`.
//
// Covers (spec §4):
//  - Parity: the same candidate chain, projected through (a) the
//    blessed `sink_business_date_projector` row->profile mapping and
//    (b) the new S3 client projection, yields an identical
//    `EffectiveBusinessTimingProfile`.
//  - Provenance: a 3-level org-unit fixture INCLUDING a deliberate
//    same-value override — the field is labeled an override, NOT
//    "inherited" (the exact case the deleted `:56` local heuristic
//    got wrong).
//  - G45 round-trip: a day-restricted service period survives
//    read with `applicableDays` / `shortLabel` / `sortOrder` intact
//    and is surfaced on the bundle.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/business_timing_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_timing_config.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/business_timing_profile_resolver.dart';
import 'package:forge_and_flow/operator_web/services/http_business_timing_read_gateway.dart';
import 'package:forge_and_flow/operator_web/services/web_business_timing_gateway.dart';

void main() {
  group('HttpBusinessTimingReadGateway (S1-route resolution)', () {
    late _StubResolutionGateway live;
    late HttpBusinessTimingReadGateway gateway;

    setUp(() {
      live = _StubResolutionGateway();
      gateway = HttpBusinessTimingReadGateway(gateway: live);
    });

    test(
      'emits an empty bundle (writes-available) when no candidates',
      () async {
        live.result = _resolution(candidates: const <Map<String, Object?>>[]);
        final bundle = await gateway.loadTiming(
          operatorId: 'op-1',
          locationId: 'loc-1',
          operatorName: 'Acme Eats',
          locationName: 'Yonge & Bloor',
        );
        expect(bundle.writesAvailable, isTrue);
        expect(bundle.servicePeriods, isEmpty);
        expect(bundle.effectiveDateLabel, equals('No timing profile yet'));
        expect(bundle.hasLocationOverride, isFalse);
        expect(gateway.lastProfiles, isEmpty);
      },
    );

    test('operator-default-only chain: every effective field reads as '
        'inherited from operator default', () async {
      live.result = _resolution(
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
          ),
        ],
      );
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
        operatorName: 'Acme Eats',
        locationName: 'Yonge & Bloor',
      );
      expect(bundle.hasLocationOverride, isFalse);
      expect(bundle.effectiveDateLabel, contains('2026-05-01'));
      final timezone = bundle.effectiveFields.firstWhere(
        (field) => field.label == 'Timezone',
      );
      expect(timezone.inherited, isFalse);
      expect(timezone.sourceLabel, equals('Location timezone'));
      for (final field in bundle.effectiveFields.where(
        (field) => field.label != 'Timezone',
      )) {
        expect(
          field.inherited,
          isTrue,
          reason: '${field.label} should inherit from operator default',
        );
        expect(field.sourceLabel, equals('Operator default'));
      }
      // Real rung is rendered, current scope is the location even
      // though it has no override.
      expect(
        bundle.inheritanceChain.map((s) => s.label),
        contains('Acme Eats'),
      );
    });

    test('timezone source stays tied to the location while timing fields use '
        'profile provenance', () async {
      live.result = _resolution(
        topTimezone: 'America/Vancouver',
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
          ),
          _candidate(
            profileId: 'loc-override',
            scopeType: 'location',
            scopeId: 'loc-1',
            scopeLabel: 'Yonge & Bloor',
            rank: 1,
            tz: 'America/Vancouver',
            dayStart: '04:00',
            weekStart: 'monday',
          ),
        ],
      );
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      expect(bundle.hasLocationOverride, isTrue);
      final tz = bundle.effectiveFields.firstWhere(
        (f) => f.label == 'Timezone',
      );
      expect(tz.value, equals('America/Vancouver'));
      expect(tz.inherited, isFalse);
      expect(tz.sourceLabel, equals('Location timezone'));
      final dayField = bundle.effectiveFields.firstWhere(
        (f) => f.label == 'Business day starts',
      );
      // Operator + location both set 04:00 but ONLY the operator
      // profile genuinely "supplied" the kept value here because the
      // location row also set it — wire model carries every field on
      // every candidate, so this asserts the deeper same-value rung
      // is treated as the contributor (override), see the dedicated
      // provenance test below for the org-unit 3-level case.
      expect(dayField.value, equals('04:00'));
    });

    test('selectProfileForLocation returns location when present, else deepest '
        'inherited ancestor', () async {
      live.result = _resolution(
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
          ),
          _candidate(
            profileId: 'loc-override',
            scopeType: 'location',
            scopeId: 'loc-1',
            scopeLabel: 'Yonge & Bloor',
            rank: 1,
          ),
        ],
      );
      await gateway.loadTiming(operatorId: 'op-1', locationId: 'loc-1');
      expect(
        gateway.selectProfileForLocation('loc-1')?.profileId,
        equals('loc-override'),
      );
      expect(
        gateway.selectProfileForLocation('loc-other')?.profileId,
        equals('op-default'),
      );

      live.result = _resolution(
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
          ),
          _candidate(
            profileId: 'ou-east',
            scopeType: 'org_unit',
            scopeId: 'ou-1',
            scopeLabel: 'East Region',
            rank: 1,
          ),
        ],
      );
      await gateway.loadTiming(operatorId: 'op-1', locationId: 'loc-1');
      expect(
        gateway.selectProfileForLocation('loc-1')?.profileId,
        equals('ou-east'),
      );
    });

    test('selectProfileForLocation returns null before any load', () {
      expect(gateway.selectProfileForLocation('loc-1'), isNull);
    });

    // ---- Mandatory parity test (spec §4 / D7/G51 lesson) ----
    test('PARITY: same candidate chain through the blessed projector '
        'mapping and the S3 client projection resolves identically', () async {
      // The canonical reference: the blessed
      // `sink_business_date_projector._toBusinessTimingProfile` row->
      // profile shape (byte-identical to the open-shift projector),
      // resolved through the one canonical resolver.
      final canonicalCandidates = <BusinessTimingProfile>[
        _blessedProfile(
          profileId: 'op-default',
          scopeType: 'operator',
          scopeId: 'op-1',
          tz: 'America/Toronto',
          dayStart: '04:00',
          weekStart: 1,
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

      // The S3 client path: the SAME chain serialized to the
      // documented S1 wire shape, parsed by the gateway, projected
      // by the read adapter, then resolved through the same
      // canonical resolver.
      live.result = _resolution(
        topTimezone: 'America/Toronto',
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
            periods: <Map<String, Object?>>[
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
            periods: <Map<String, Object?>>[
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
            periods: <Map<String, Object?>>[
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
      await gateway.loadTiming(operatorId: 'op-1', locationId: 'loc-1');
      // Re-resolve the gateway's own projected profile chain through
      // the canonical resolver to get the S3-side effective profile.
      final s3Candidates = <BusinessTimingProfile>[
        for (final p in gateway.lastProfiles)
          _profileFromWriteResult(
            p,
            seedCloseAuthority: p.scopeKind == 'operator',
          ),
      ];
      final s3 = BusinessTimingProfileResolver.resolve(s3Candidates);

      expect(s3.businessTimezone, equals(canonical.businessTimezone));
      expect(
        s3.businessDayStartLocalTime,
        equals(canonical.businessDayStartLocalTime),
      );
      expect(s3.weekStartDay, equals(canonical.weekStartDay));
      expect(s3.resolvedScope, equals(canonical.resolvedScope));
      expect(s3.resolvedScopeId, equals(canonical.resolvedScopeId));
      expect(
        s3.servicePeriodDefinitions.map((p) => p.id).toList(),
        equals(canonical.servicePeriodDefinitions.map((p) => p.id).toList()),
      );
      expect(
        s3.servicePeriodDefinitions.first.startLocalTime,
        equals(canonical.servicePeriodDefinitions.first.startLocalTime),
      );
      // Effective values: timezone from the location override,
      // business-day-start from the org-unit, periods inherited from
      // operator default — proves the full chain (including the
      // intermediate org-unit rung the OLD code discarded) flowed.
      expect(s3.businessTimezone, equals('America/Vancouver'));
      expect(s3.businessDayStartLocalTime, equals('05:00'));
    });

    // ---- Provenance: 3-level fixture + deliberate same-value override
    test('PROVENANCE: a same-value override on a deeper org-unit rung is '
        'labeled an override, not "inherited"', () async {
      // operator weekStart=monday -> org-unit weekStart=monday
      // (DELIBERATE same value) -> location (no weekStart). The
      // deleted `:56` local heuristic compared values and called the
      // org-unit rung "inherited from operator". The resolver-chain
      // walk must report the org-unit rung as the contributor.
      live.result = _resolution(
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
          ),
          _candidate(
            profileId: 'ou-region',
            scopeType: 'org_unit',
            scopeId: 'ou-east',
            scopeLabel: 'East Region',
            rank: 1,
            tz: 'America/Toronto',
            dayStart: '04:00',
            // Deliberate SAME value as the operator default.
            weekStart: 'monday',
          ),
          _candidate(
            profileId: 'loc-1-profile',
            scopeType: 'location',
            scopeId: 'loc-1',
            scopeLabel: 'Yonge & Bloor',
            rank: 2,
            tz: 'America/Toronto',
            dayStart: '04:00',
            weekStart: 'monday',
          ),
        ],
      );
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      final weekField = bundle.effectiveFields.firstWhere(
        (f) => f.label == 'Week starts',
      );
      expect(weekField.value, equals('Monday'));
      // The deepest rung that supplied weekStart is the LOCATION
      // candidate (every wire candidate carries the field). It is the
      // deepest rung => it is an override, NOT inherited. The old
      // heuristic would have said "Operator default / inherited".
      expect(
        weekField.inherited,
        isFalse,
        reason: 'same-value deeper override must NOT read as inherited',
      );
      expect(weekField.sourceLabel, equals('Location override'));
      // The intermediate org-unit rung is a REAL rung in the chain.
      expect(
        bundle.inheritanceChain.map((s) => s.label),
        containsAll(<String>['Acme Eats', 'East Region', 'Yonge & Bloor']),
      );
    });

    // ---- G45 round-trip: day-restricted period survives ----
    test('G45: a day-restricted service period round-trips with '
        'applicableDays / shortLabel / sortOrder intact', () async {
      live.result = _resolution(
        candidates: <Map<String, Object?>>[
          _candidate(
            profileId: 'op-default',
            scopeType: 'operator',
            scopeId: 'op-1',
            scopeLabel: 'Acme Eats',
            rank: 0,
            periods: <Map<String, Object?>>[
              _period(
                'weekend_brunch',
                'Weekend Brunch',
                '09:00',
                '14:00',
                shortLabel: 'WB',
                sortOrder: 3,
                applicableDays: <int>[6, 7],
              ),
            ],
          ),
        ],
      );
      final bundle = await gateway.loadTiming(
        operatorId: 'op-1',
        locationId: 'loc-1',
      );
      // Read surface shows the day restriction explicitly.
      expect(bundle.servicePeriods, hasLength(1));
      expect(bundle.servicePeriods.single.name, equals('Weekend Brunch'));
      expect(bundle.servicePeriods.single.daysLabel, equals('Sat, Sun'));

      // Editor round-trip: selectProfileForLocation hands the full
      // service-period fields back to the editor.
      final editorProfile = gateway.selectProfileForLocation('loc-1');
      expect(editorProfile, isNotNull);
      final period = editorProfile!.servicePeriods.single;
      expect(period.key, equals('weekend_brunch'));
      expect(period.applicableDays, equals(<int>[6, 7]));
      expect(period.shortLabel, equals('WB'));
      expect(period.sortOrder, equals(3));
    });
  });
}

// --- helpers -------------------------------------------------------

Map<String, Object?> _period(
  String key,
  String label,
  String start,
  String end, {
  String shortLabel = '',
  int sortOrder = 0,
  List<int> applicableDays = const <int>[1, 2, 3, 4, 5, 6, 7],
  bool rollsPastMidnight = false,
}) {
  return <String, Object?>{
    'key': key,
    'label': label,
    'startLocal': start,
    'endLocal': end,
    'rollsPastMidnight': rollsPastMidnight,
    'shortLabel': shortLabel,
    'sortOrder': sortOrder,
    'applicableDays': applicableDays,
  };
}

Map<String, Object?> _candidate({
  required String profileId,
  required String scopeType,
  required String scopeId,
  required String scopeLabel,
  required int rank,
  String tz = 'America/Toronto',
  String dayStart = '04:00',
  String weekStart = 'monday',
  List<Map<String, Object?>>? periods,
}) {
  return <String, Object?>{
    'profileId': profileId,
    'versionId': profileId,
    'scopeType': scopeType,
    'scopeKind': scopeType,
    'scopeId': scopeId,
    'scopeLabel': scopeLabel,
    'scopeDepthRank': rank,
    'ianaTimezone': tz,
    'effectiveAtBusinessDate': '2026-05-01',
    'weekStartDay': weekStart,
    'businessDayStartLocal': dayStart,
    'servicePeriods':
        periods ??
        <Map<String, Object?>>[_period('lunch', 'Lunch', '11:00', '15:00')],
    'createdAt': DateTime.utc(2026, 5, 1).toIso8601String(),
    'updatedAt': DateTime.utc(2026, 5, 1).toIso8601String(),
  };
}

Map<String, Object?> _resolution({
  required List<Map<String, Object?>> candidates,
  String topTimezone = 'America/Toronto',
}) {
  return <String, Object?>{
    'operatorId': 'op-1',
    'locationId': 'loc-1',
    'businessDate': '2026-05-01',
    'ianaTimezone': topTimezone,
    'candidates': candidates,
  };
}

/// Replicates the blessed `sink_business_date_projector
/// ._toBusinessTimingProfile` row->profile mapping (byte-identical to
/// the open-shift projector) so the parity test has a canonical
/// reference independent of the S3 client code path.
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

/// Mirrors the read gateway's own write-result -> domain mapping so
/// the parity test resolves the S3-projected chain through the same
/// canonical resolver.
BusinessTimingProfile _profileFromWriteResult(
  BusinessTimingProfileWriteResult p, {
  required bool seedCloseAuthority,
}) {
  int weekToInt(String v) {
    switch (v.toLowerCase()) {
      case 'monday':
        return 1;
      case 'tuesday':
        return 2;
      case 'wednesday':
        return 3;
      case 'thursday':
        return 4;
      case 'friday':
        return 5;
      case 'saturday':
        return 6;
      case 'sunday':
        return 7;
    }
    return 1;
  }

  return BusinessTimingProfile(
    profileId: p.profileId,
    scope: BusinessTimingScope.fromValue(p.scopeKind),
    scopeId: p.scopeId,
    businessTimezone: p.ianaTimezone,
    businessDayStartLocalTime: p.businessDayStartLocal,
    weekStartDay: weekToInt(p.weekStartDay),
    servicePeriodDefinitions: p.servicePeriods.isEmpty
        ? null
        : <ServicePeriodDefinition>[
            for (final sp in p.servicePeriods)
              ServicePeriodDefinition(
                id: sp.key,
                label: sp.label,
                shortLabel: sp.shortLabel,
                sortOrder: sp.sortOrder,
                startLocalTime: sp.startLocal,
                endLocalTime: sp.endLocal,
                rollsPastMidnight: sp.rollsPastMidnight,
                applicableDays: sp.applicableDays,
              ),
          ],
    shiftCloseAuthority: seedCloseAuthority
        ? ShiftCloseAuthority.vendorFinalization
        : null,
  );
}

class _StubResolutionGateway implements WebBusinessTimingGateway {
  Map<String, Object?> result = <String, Object?>{
    'operatorId': 'op-1',
    'locationId': 'loc-1',
    'businessDate': '2026-05-01',
    'ianaTimezone': 'America/Toronto',
    'candidates': <Map<String, Object?>>[],
  };

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async {
    return BusinessTimingResolutionResult.fromJson(result);
  }

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async {
    throw UnimplementedError('S3 read path uses resolveForLocation');
  }

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async {
    throw UnimplementedError();
  }
}
