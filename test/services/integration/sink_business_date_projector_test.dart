// Per-Daypart Targets V1 — Slice 7b option (b) helper unit tests.
//
// Pins the Slice 7b helper API surface BEFORE the bulk-application
// slice (7b.2) refactors the remaining 19 vendor sinks. Coverage:
//
//   A. Sub-hour cutoff honored — profile chain returns a candidate with
//      `business_day_start_local_time = '04:30'`. Closes Gap 46.
//   B. Hierarchy precedence honored — operator + org_unit + location
//      candidates returned in resolver-precedence order; the location
//      override wins. Closes Gap 47.
//   C. Empty profile chain falls back to `'04:00'` (operator-locked
//      fallback per `docs/_audits/per_daypart_v1/slice_7b_research_2026_05_15.md`).
//   D. Coarse-seed mismatch triggers the bounded re-resolve loop —
//      operator changes the cutoff overnight on the same calendar date
//      the instant lands on, the helper re-resolves once and converges.
//   E. Empty `restaurantTimezone` falls back to `'UTC'` (Libro pattern;
//      combined with `'04:00'` fallback projects identically to the
//      legacy `(timezone='UTC', business_day_rollover_hour=4)` shape).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/sink_business_date_projector.dart';
import 'package:timezone/data/latest.dart' as tzdata;

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void main() {
  setUpAll(() {
    // The IANA converter consumed by SinkBusinessDateProjector needs the
    // tz database initialised before its first use. Mirrors the setup
    // pattern in `business_timing_profiles_repository_test.dart`.
    tzdata.initializeTimeZones();
  });

  group('SinkBusinessDateProjector — A. sub-hour cutoff (Gap 46)', () {
    test(
      'profile chain with business_day_start_local_time = 04:30 honors '
      'the sub-hour cutoff — 04:15 local Wed projects to PRIOR business_date',
      () async {
        // Wed 2026-05-13 04:15 EDT (UTC-4) = Wed 2026-05-13 08:15 UTC.
        // local 04:15 < cutoff 04:30 → business_date = Tue 2026-05-12.
        // Under the LEGACY integer-hour path
        // (`business_day_rollover_hour = 4`), the predicate
        // `local.hour 4 < rollover 4` is false → would have returned
        // Wed 2026-05-13. Slice 7b option (b) closes that truncation.
        final pool = _FakeProfilesPool()
          ..seedProfiles(
            operatorId: _opA,
            locationId: _locA,
            timezone: 'America/Toronto',
            rows: <_FakeProfileRow>[
              _FakeProfileRow.location(
                businessDayStartLocalTime: '04:30:00',
              ),
            ],
          );
        final projector = _projectorOver(pool);

        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 8, 15),
        );

        expect(
          _isoDate(result),
          '2026-05-12',
          reason: '04:15 local Wed with 04:30 cutoff belongs to PRIOR '
              'business_date — sub-hour cutoff truncation closed.',
        );
      },
    );

    test(
      'profile chain with business_day_start_local_time = 04:30 — 04:45 '
      'local Wed stays on SAME business_date (predicate is strict)',
      () async {
        // Wed 2026-05-13 04:45 EDT = Wed 2026-05-13 08:45 UTC.
        // local 04:45 ≥ cutoff 04:30 → business_date = Wed 2026-05-13.
        final pool = _FakeProfilesPool()
          ..seedProfiles(
            operatorId: _opA,
            locationId: _locA,
            timezone: 'America/Toronto',
            rows: <_FakeProfileRow>[
              _FakeProfileRow.location(
                businessDayStartLocalTime: '04:30:00',
              ),
            ],
          );
        final projector = _projectorOver(pool);

        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 8, 45),
        );

        expect(_isoDate(result), '2026-05-13');
      },
    );
  });

  group('SinkBusinessDateProjector — B. hierarchy precedence (Gap 47)', () {
    test(
      'operator + org_unit + location candidates — location override '
      'wins per the resolver inheritance order',
      () async {
        // Wed 2026-05-13 03:30 EDT = Wed 2026-05-13 07:30 UTC.
        // - operator default cutoff = '02:00' → would project to Wed.
        // - org_unit cutoff         = '03:00' → would project to Wed.
        // - location override       = '04:00' → projects to Tue.
        // Resolver picks location → result = Tue 2026-05-12.
        final pool = _FakeProfilesPool()
          ..seedProfiles(
            operatorId: _opA,
            locationId: _locA,
            timezone: 'America/Toronto',
            rows: <_FakeProfileRow>[
              _FakeProfileRow.operatorDefault(
                businessDayStartLocalTime: '02:00:00',
              ),
              _FakeProfileRow.orgUnit(
                businessDayStartLocalTime: '03:00:00',
              ),
              _FakeProfileRow.location(
                businessDayStartLocalTime: '04:00:00',
              ),
            ],
          );
        final projector = _projectorOver(pool);

        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 7, 30),
        );

        expect(
          _isoDate(result),
          '2026-05-12',
          reason: 'location override (04:00) must win over org_unit '
              '(03:00) and operator default (02:00) per HP #11.',
        );
      },
    );
  });

  group('SinkBusinessDateProjector — C. empty-chain fallback', () {
    test(
      'profile chain returns no candidates → falls back to 04:00 cutoff '
      '(operator-locked default per Slice 7b research, 2026-05-15)',
      () async {
        // Wed 2026-05-13 03:30 EDT = Wed 2026-05-13 07:30 UTC.
        // local 03:30 < fallback cutoff 04:00 → Tue 2026-05-12.
        // Empty profile chain returns no candidates; helper falls back
        // to '04:00' (NOT OpenTable's '0' and NOT the SQL trigger's
        // coalesce(…, 0)). Matches Libro's historical Dart fallback.
        final pool = _FakeProfilesPool();
        // No seed — the candidate query returns []; helper falls back.
        final projector = _projectorOver(pool);

        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 7, 30),
        );

        expect(_isoDate(result), '2026-05-12');
      },
    );
  });

  group('SinkBusinessDateProjector — D. bounded re-resolve loop', () {
    test(
      'profile cutoff change overnight → coarse seed lands on the wrong '
      'side; helper re-resolves ONCE and converges',
      () async {
        // Setup:
        //   - For coarse seed = '2026-05-13' (Wed local calendar date),
        //     the location profile carries cutoff '04:00'.
        //   - For coarse seed = '2026-05-12' (Tue local calendar date),
        //     the location profile carries cutoff '02:00' — operator
        //     "tightened" the cutoff overnight.
        //   - Instant: 2026-05-13 07:30 UTC = Wed 03:30 EDT.
        //
        // Coarse seed in restaurant tz = '2026-05-13' (Wed). First
        // lookup returns cutoff '04:00' → resolves to '2026-05-12'
        // (Tue). The helper detects the seed changed and re-resolves
        // with seed '2026-05-12', getting cutoff '02:00' → resolves to
        // '2026-05-13' (Wed) (because local 03:30 ≥ '02:00').
        //
        // The bounded loop trusts the second resolution. This locks in
        // the contract that the helper MUST re-resolve once when the
        // seed flips, and MUST NOT loop indefinitely.
        final pool = _FakeProfilesPool()
          ..seedProfilesByDate(
            operatorId: _opA,
            locationId: _locA,
            timezone: 'America/Toronto',
            byDate: <String, List<_FakeProfileRow>>{
              '2026-05-13': <_FakeProfileRow>[
                _FakeProfileRow.location(
                  businessDayStartLocalTime: '04:00:00',
                ),
              ],
              '2026-05-12': <_FakeProfileRow>[
                _FakeProfileRow.location(
                  businessDayStartLocalTime: '02:00:00',
                ),
              ],
            },
          );
        final projector = _projectorOver(pool);

        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 7, 30),
        );

        // After re-resolve: 03:30 EDT on Wed under cutoff '02:00' is
        // ≥ 02:00 → Wed 2026-05-13.
        expect(_isoDate(result), '2026-05-13');
        // Two lookups exactly: bounded loop, not infinite.
        expect(
          pool.candidateLookupCount,
          2,
          reason: 'helper must re-resolve EXACTLY ONCE on seed mismatch',
        );
      },
    );

    test(
      'profile chain stable across seeds → only ONE lookup (no spurious '
      're-resolve when the first resolution matches the coarse seed)',
      () async {
        final pool = _FakeProfilesPool()
          ..seedProfiles(
            operatorId: _opA,
            locationId: _locA,
            timezone: 'America/Toronto',
            rows: <_FakeProfileRow>[
              _FakeProfileRow.location(
                businessDayStartLocalTime: '04:00:00',
              ),
            ],
          );
        final projector = _projectorOver(pool);

        // 12:00 EDT on Wed — clearly past any cutoff; coarse seed
        // matches resolution.
        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: 'America/Toronto',
          instantUtc: DateTime.utc(2026, 5, 13, 16, 0),
        );

        expect(_isoDate(result), '2026-05-13');
        expect(pool.candidateLookupCount, 1);
      },
    );
  });

  group('SinkBusinessDateProjector — E. empty timezone fallback', () {
    test(
      'empty restaurantTimezone falls back to UTC — combined with empty '
      'profile chain projects identically to legacy (UTC, 4) Libro path',
      () async {
        final pool = _FakeProfilesPool();
        // No seed → empty candidates → fallback cutoff '04:00'.
        final projector = _projectorOver(pool);

        // 2026-06-15 03:00 UTC; under empty timezone, projector falls
        // back to UTC. local 03:00 < cutoff 04:00 → Sun 2026-06-14.
        final result = await projector.projectBusinessDate(
          operatorId: _opA,
          locationId: _locA,
          restaurantTimezone: '',
          instantUtc: DateTime.utc(2026, 6, 15, 3, 0),
        );

        expect(_isoDate(result), '2026-06-14');
      },
    );
  });
}

// ─── Helpers ────────────────────────────────────────────────────────

SinkBusinessDateProjector _projectorOver(_FakeProfilesPool pool) {
  final wrapper = TenantTransactionWrapper(pool);
  final repo = BusinessTimingProfilesRepository(wrapper);
  return SinkBusinessDateProjector(profilesRepository: repo);
}

String _isoDate(DateTime value) {
  final utc = value.toUtc();
  final yyyy = utc.year.toString().padLeft(4, '0');
  final mm = utc.month.toString().padLeft(2, '0');
  final dd = utc.day.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd';
}

// ─── Test doubles ───────────────────────────────────────────────────
//
// `BusinessTimingProfilesRepository.listCandidateProfilesForLocation`
// runs one big SQL query against `business_timing_profiles` joined to
// `org_units` and `locations`. The fake matches that SQL by header
// string and returns canned rows in the exact column shape the
// repository expects (see `_profileColumns` + `_periodJson` in the
// repository source).

class _FakeProfileRow {
  _FakeProfileRow({
    required this.scopeType,
    required this.scopeId,
    required this.businessDayStartLocalTime,
  });

  // Hard-coded for the helper unit tests — the resolver requires
  // non-null values but the tests don't vary them.
  final int weekStartDay = 1;
  final String closeAuthority = 'app_local_cutoff_fallback';

  factory _FakeProfileRow.operatorDefault({
    required String businessDayStartLocalTime,
  }) {
    return _FakeProfileRow(
      scopeType: 'operator',
      scopeId: '00000000-0000-4000-8000-000000000001',
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
  }

  factory _FakeProfileRow.orgUnit({
    required String businessDayStartLocalTime,
  }) {
    return _FakeProfileRow(
      scopeType: 'org_unit',
      scopeId: '00000000-0000-4000-8000-000000000002',
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
  }

  factory _FakeProfileRow.location({
    required String businessDayStartLocalTime,
  }) {
    return _FakeProfileRow(
      scopeType: 'location',
      scopeId: '00000000-0000-4000-8000-000000000003',
      businessDayStartLocalTime: businessDayStartLocalTime,
    );
  }

  final String scopeType;
  final String scopeId;
  final String businessDayStartLocalTime;

  PostgresRow toRow({required String locationTimezone}) {
    return <String, Object?>{
      'profile_id': '00000000-0000-4000-8000-${scopeId.substring(scopeId.length - 12)}',
      'operator_id': '11111111-1111-4111-8111-111111111111',
      'scope_type': scopeType,
      'scope_id': scopeId,
      'display_name': null,
      'business_day_start_local_time': businessDayStartLocalTime,
      'week_start_day': weekStartDay,
      'close_authority': closeAuthority,
      'local_close_fallback_time': null,
      'effective_from_business_date': '2026-01-01',
      'effective_until_business_date': null,
      'supersedes_profile_id': null,
      'created_by': null,
      'updated_by': null,
      'created_at': DateTime.utc(2026, 1, 1),
      'updated_at': DateTime.utc(2026, 1, 1),
      'location_timezone': locationTimezone,
      // Exactly one service period so the resolver's required service-
      // period set is non-empty (and it does NOT overlap the cutoff).
      'service_periods': <Map<String, Object?>>[
        <String, Object?>{
          'service_period_id':
              '99999999-9999-4999-8999-999999999999',
          'operator_id': '11111111-1111-4111-8111-111111111111',
          'profile_id':
              '00000000-0000-4000-8000-${scopeId.substring(scopeId.length - 12)}',
          'service_period_key': 'lunch',
          'label': 'Lunch',
          'short_label': 'L',
          'sort_order': 1,
          'start_local_time': '11:00',
          'end_local_time': '15:00',
          'rolls_past_midnight': false,
          'applicable_weekdays': <int>[1, 2, 3, 4, 5, 6, 7],
        },
      ],
    };
  }
}

class _FakeProfilesPool implements PostgresPool {
  final Map<String, List<_FakeProfileRow>> _profilesByKey =
      <String, List<_FakeProfileRow>>{};
  final Map<String, Map<String, List<_FakeProfileRow>>> _profilesByDate =
      <String, Map<String, List<_FakeProfileRow>>>{};
  final Map<String, String> _timezones = <String, String>{};
  int candidateLookupCount = 0;

  void seedProfiles({
    required String operatorId,
    required String locationId,
    required String timezone,
    required List<_FakeProfileRow> rows,
  }) {
    final key = '$operatorId|$locationId';
    _profilesByKey[key] = rows;
    _timezones[key] = timezone;
  }

  void seedProfilesByDate({
    required String operatorId,
    required String locationId,
    required String timezone,
    required Map<String, List<_FakeProfileRow>> byDate,
  }) {
    final key = '$operatorId|$locationId';
    _profilesByDate[key] = byDate;
    _timezones[key] = timezone;
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _FakeTx(this);
  }
}

class _FakeTx implements PostgresTransaction {
  _FakeTx(this.pool);

  final _FakeProfilesPool pool;

  @override
  Future<List<PostgresRow>> query(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}) async {
    if (sql.contains('select set_config')) {
      // Tenant SET LOCAL — no rows expected.
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.business_timing_profiles p')) {
      pool.candidateLookupCount += 1;
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final businessDate = parameters['business_date'] as String;
      final key = '$operatorId|$locationId';
      final tz = pool._timezones[key] ?? 'UTC';

      // Date-keyed seed wins when present (Group D). Otherwise fall
      // back to the static seed (Groups A–C).
      final byDate = pool._profilesByDate[key];
      final List<_FakeProfileRow> rows;
      if (byDate != null) {
        rows = byDate[businessDate] ?? const <_FakeProfileRow>[];
      } else {
        rows = pool._profilesByKey[key] ?? const <_FakeProfileRow>[];
      }
      return <PostgresRow>[
        for (final row in rows) row.toRow(locationTimezone: tz),
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql,
    {PostgresParameters parameters = const <String, Object?>{}}) async {
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
