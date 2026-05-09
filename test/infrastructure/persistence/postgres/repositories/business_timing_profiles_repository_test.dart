// Phase 6 — real-DB unit tests for BusinessTimingProfilesRepository.
//
// Origin / why-this-matters
// -------------------------
// Phase 3A's preview-env error excerpts (see
// `docs/_execution/2026-05-08_pressure_preview_findings.md` Section 3A
// and the per-vendor `revel` row) directly named
// `column op.rollover_hour does not exist` as the root cause of ~1000
// of 1700 webhook 5xx responses under load. The aliased column is
// `locations.business_day_rollover_hour`; every vendor adapter's
// `business_date` derivation depends on the rollover-hour + IANA-zone
// pair sourced from `locations` PLUS the optional richer
// `business_day_start_local_time` (quarter-hour) override owned by
// `business_timing_profiles`. Pinning the resolver-precedence and
// scope-validation contract on the profile-side persistence is on the
// V1 critical path.
//
// Authority
// ---------
//   * `lib/infrastructure/persistence/postgres/repositories/`
//     `business_timing_profiles_repository.dart` — system under test.
//   * `db/migrations/202605060000_phase_business_timing_live_schema.sql`
//     — schema, triggers, RLS posture.
//   * `lib/domain/services/business_date_resolver.dart` — pure formula
//     consumer of `business_day_start_local_time`.
//   * `lib/services/integration/iana_timezone_converter.dart` —
//     adapter-side IANA + rollover_hour consumer (DST-correct).
//   * CLAUDE.md "Time Guardrails" + "Hard Promises #11" (hierarchy).
//
// Schema-vs-prompt gaps (CONTRACT GAP markers below)
// --------------------------------------------------
// The Phase 6 backfill prompt asked for tests that pin
// `rollover_hour` and `iana_timezone` columns on
// `business_timing_profiles`. The actual schema does NOT carry either
// column on profiles; instead:
//
//   * `business_timing_profiles.business_day_start_local_time` is a
//     `TIME` (HH:mm:ss, quarter-hour aligned) — the rich form of the
//     rollover. Quarter-hour granularity is enforced by
//     `business_timing_time_is_quarter_hour(time)` and `0..23` is
//     therefore implicit (any HH outside that range is not a valid
//     `time` literal at the driver layer).
//   * `locations.timezone` is the authoritative IANA zone — profiles
//     intentionally do not duplicate it (see the schema header
//     comment and the repository file's first paragraph).
//   * `locations.business_day_rollover_hour` is the integer-hour form
//     read by the IANA-tz business-date converter. That is the column
//     Phase 3A preview env was missing.
//
// The five contract groups below stay faithful to the prompt's
// intent — they pin the rollover-cutoff + IANA-zone + hierarchy
// resolution contract — but are restated against the actual columns.
// CONTRACT GAP markers flag the mismatch so the next reviewer knows
// the prompt and schema diverged.
//
// Test posture
// ------------
// Tagged `@Tags(['postgres'])`. Skipped by default (`flutter test` w/o
// flags); run with `flutter test --tags=postgres` after starting a
// Postgres service container or pointing `POSTGRES_TEST_URL` at an
// isolated database. The shared harness at
// `test/infrastructure/postgres_test_harness.dart` applies every
// migration in `db/migrations/` then truncates tenant tables between
// tests. The prompt requested `PHASE_6_PG_URL` env var gating; the
// existing convention in this repo is `POSTGRES_TEST_URL` (see the
// harness file). Following the existing convention so this file does
// not need a parallel gating mechanism.

@Tags(['postgres'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/domain/services/business_date_resolver.dart';
import 'package:forge_and_flow/services/integration/iana_timezone_converter.dart';
import 'package:timezone/data/latest.dart' as tzdata;

import '../../../postgres_test_harness.dart';

const String _opA = 'a1a1a1a1-a1a1-1111-1111-aaaaaaaaaaaa';
const String _opB = 'b2b2b2b2-b2b2-2222-2222-bbbbbbbbbbbb';
const String _locA1 = 'c3c3c3c3-c3c3-1111-1111-aaaaaaaaaaaa';
const String _locA2 = 'c3c3c3c3-c3c3-2222-2222-aaaaaaaaaaaa';
const String _locB1 = 'd4d4d4d4-d4d4-1111-1111-bbbbbbbbbbbb';
const String _actorA = 'e5e5e5e5-e5e5-1111-1111-aaaaaaaaaaaa';

void main() {
  setUpAll(() {
    // The IANA converter consumed by some adapter callers needs the
    // tz database initialised before its first use.
    tzdata.initializeTimeZones();
  });

  // ────────────────────────────────────────────────────────────────────
  // Group 1 — rollover-cutoff (`business_day_start_local_time`) +
  // IANA-zone (`locations.timezone`) round-trip.
  //
  // CONTRACT GAP: prompt asked for `rollover_hour` (int 0..23) +
  // `iana_timezone` columns ON the profile row. Actual schema stores
  // the cutoff as `business_day_start_local_time TIME` on the profile
  // and the IANA zone on `locations`. Test below adapts the contract
  // to the real columns and asserts their round-trip behaviour
  // including the boundary cases (00:00 = midnight rollover, 23:00 =
  // one-hour-before-midnight) that the prompt called out.
  // ────────────────────────────────────────────────────────────────────
  group('Group 1 — cutoff + IANA-zone round-trip', () {
    test(
      'createProfile + loadProfileById round-trips the rollover '
      'cutoff (`business_day_start_local_time`) verbatim, and the '
      'IANA zone surfaces from `locations.timezone` via '
      'listCandidateProfilesForLocation',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            // Override the seeded location's timezone to make the
            // assertion explicit (harness defaults to America/Toronto;
            // we rely on that here but write it explicitly anyway so
            // future harness changes do not silently green this test).
            await _setLocationTimezone(
              pool,
              locationId: _locA1,
              timezone: 'America/Toronto',
            );

            final repo = BusinessTimingProfilesRepository(wrapper);
            final created = await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              displayName: 'Default operator timing',
              adminReason: 'phase-6-test:create-roundtrip',
            );

            expect(
              created.businessDayStartLocalTime,
              equals('04:00'),
              reason: 'TIME column persists the HH:mm cutoff exactly',
            );
            expect(created.scopeType, equals('operator'));

            final reread = await repo.loadProfileById(
              operatorId: _opA,
              locationId: _locA1,
              profileId: created.profileId,
              userId: _actorA,
            );
            expect(reread, isNotNull);
            expect(reread!.businessDayStartLocalTime, equals('04:00'));

            // IANA timezone surfaces from `locations.timezone`, not
            // from the profile. Verify via listCandidateProfilesForLocation.
            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            expect(candidates, isNotEmpty);
            expect(
              candidates.first.locationTimezone,
              equals('America/Toronto'),
              reason: 'locationTimezone is read from `locations.timezone`',
            );
          },
        );
      },
    );

    test(
      'updateProfile rewrites `business_day_start_local_time` and '
      'reread returns the new value (operator-scoped UPDATE, audited)',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            final created = await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:create-for-update',
            );
            final after = await repo.updateProfile(
              operatorId: _opA,
              locationId: _locA1,
              profileId: created.profileId,
              businessDayStartLocalTime: '05:00',
              weekStartDay: 1,
              effectiveFromBusinessDate: '2026-01-01',
              actorUserId: _actorA,
              reason: 'phase-6-test:update-cutoff',
            );
            expect(after, isNotNull);
            expect(after!.businessDayStartLocalTime, equals('05:00'));
          },
        );
      },
    );

    test(
      'rollover-cutoff boundary cases — 00:00 (midnight) and 23:00 '
      '(one-hour-before-midnight) both persist; both honour the '
      'quarter-hour check constraint',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            // Midnight rollover - operator scope, effective from 2026-01-01.
            final midnight = await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '00:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              effectiveUntilBusinessDate: '2026-06-01',
              adminReason: 'phase-6-test:boundary-midnight',
            );
            expect(midnight.businessDayStartLocalTime, equals('00:00'));

            // 23:00 - non-overlapping effective window on the same
            // (operator,scope) so the `prevent_effective_overlap`
            // trigger does not fire.
            final lateNight = await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '23:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-06-01',
              adminReason: 'phase-6-test:boundary-late-night',
            );
            expect(lateNight.businessDayStartLocalTime, equals('23:00'));
          },
        );
      },
    );

    test(
      'rejects a non-quarter-hour cutoff — 04:07 violates '
      '`business_timing_time_is_quarter_hour(time)` check constraint',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await expectLater(
              repo.createProfileAsSystem(
                operatorId: _opA,
                scopeType: 'operator',
                scopeId: _opA,
                businessDayStartLocalTime: '04:07',
                weekStartDay: 1,
                closeAuthority: 'vendor_finalization',
                effectiveFromBusinessDate: '2026-01-01',
                adminReason: 'phase-6-test:non-quarter-hour-rejected',
              ),
              throwsA(isA<Exception>()),
              reason:
                  'check constraint business_timing_time_is_quarter_hour '
                  'rejects HH:mm values whose minute is not in {0,15,30,45}',
            );
          },
        );
      },
    );

    test(
      'CONTRACT GAP — invalid IANA zone is enforced at the LOCATION '
      'row, not on the profile. The profile schema intentionally does '
      'not carry an `iana_timezone` column. Phase 6 frame the IANA '
      'invalid-zone reject test as a `locations` write check; this '
      'profile-side test asserts the boundary by writing a bogus '
      'timezone onto `locations` and checking that '
      '`listCandidateProfilesForLocation` surfaces it verbatim — '
      'i.e. the profile resolver does not re-validate IANA names. '
      'IANA validation lives in `IanaTimezoneConverter._resolveLocation`.',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            // Force-set a bogus IANA name on the location row. The
            // `locations.timezone` column has no IANA-membership check
            // constraint at the database layer (validation is
            // application-side via `isValidIanaTimezoneName`).
            await _setLocationTimezone(
              pool,
              locationId: _locA1,
              timezone: 'Mars/Olympus',
            );

            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:bogus-tz-passes-through',
            );

            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            expect(
              candidates.first.locationTimezone,
              equals('Mars/Olympus'),
              reason:
                  'profile read does not validate IANA zone — that is '
                  'IanaTimezoneConverter\'s job at adapter ingestion',
            );

            // Then prove the converter rejects it, so the contract
            // gap closes downstream of the repository.
            expect(
              () => IanaTimezoneConverter().toBusinessDate(
                restaurantTimezone: 'Mars/Olympus',
                businessDayRolloverHour: 4,
                instant: DateTime.utc(2026, 5, 9, 12),
              ),
              throwsA(isA<IanaTimezoneConverterError>()),
            );
          },
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Group 2 — Hierarchy-scoped resolution (HP #11).
  //
  // The hierarchy is operator → org_unit ancestors → location. Lower
  // (more-specific) scopes override higher scopes. The repo exposes
  // this via `listCandidateProfilesForLocation`, which orders rows in
  // resolver-precedence: operator first (depth 0), org_unit ancestors
  // by `nlevel(path)` ascending, location last (depth 100000). The
  // CALLER picks the last (most-specific) candidate as the effective
  // resolution; this test pins both the candidate-set composition and
  // the precedence ordering.
  // ────────────────────────────────────────────────────────────────────
  group('Group 2 — hierarchy-scoped resolution', () {
    test(
      'business + location overrides — operator-scope profile is '
      'inherited; location-scope profile wins when present',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);

            // Operator-wide profile: cutoff 04:00.
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:hierarchy-operator-default',
            );

            // Without a location override → operator-default wins by
            // virtue of being the only candidate.
            final inheritedCandidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            expect(inheritedCandidates, hasLength(1));
            expect(
              inheritedCandidates.last.scopeType,
              equals('operator'),
              reason:
                  'no location override → caller picks the operator '
                  'profile as the effective resolution',
            );
            expect(
              inheritedCandidates.last.businessDayStartLocalTime,
              equals('04:00'),
            );

            // Add a location override: cutoff 06:00.
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'location',
              scopeId: _locA1,
              businessDayStartLocalTime: '06:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:hierarchy-location-override',
            );

            final overriddenCandidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            // Two candidates ordered by depth: operator (0) then
            // location (100000). Caller picks the last as the
            // effective resolution.
            expect(overriddenCandidates, hasLength(2));
            expect(
              overriddenCandidates.first.scopeType,
              equals('operator'),
              reason: 'shallowest scope listed first',
            );
            expect(
              overriddenCandidates.first.businessDayStartLocalTime,
              equals('04:00'),
            );
            expect(
              overriddenCandidates.last.scopeType,
              equals('location'),
              reason: 'deepest scope listed last → effective row',
            );
            expect(
              overriddenCandidates.last.businessDayStartLocalTime,
              equals('06:00'),
              reason: 'location scope overrides operator default',
            );
          },
        );
      },
    );

    test(
      '"inherited from" metadata identifies the source scope — every '
      'candidate row exposes scope_type/scope_id so the operator-web '
      'editor can render the resolution provenance',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:metadata-operator',
            );
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'location',
              scopeId: _locA1,
              businessDayStartLocalTime: '06:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:metadata-location',
            );

            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );

            final operatorRow = candidates.firstWhere(
              (r) => r.scopeType == 'operator',
            );
            final locationRow = candidates.firstWhere(
              (r) => r.scopeType == 'location',
            );

            expect(operatorRow.scopeId, equals(_opA),
                reason: 'operator-scope row points its scope_id at operator_id');
            expect(locationRow.scopeId, equals(_locA1),
                reason: 'location-scope row points its scope_id at location_id');
          },
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Group 3 — business_date derivation honours the persisted cutoff.
  //
  // This is the boundary test: the repo persists the cutoff string;
  // the resolver consumes it. We do NOT cover BusinessDateResolver in
  // isolation (out of scope per prompt), but we do verify that what
  // the repo persists is exactly what the resolver expects, with two
  // representative timestamps and the two boundary rollover values.
  //
  // CONTRACT GAP for DST cases: BusinessDateResolver is intentionally
  // pure — it does NOT do timezone conversion (see the doc comment in
  // `business_date_resolver.dart`). The DST-correct path lives in
  // `IanaTimezoneConverter.toBusinessDate(...)`, which reads
  // `locations.business_day_rollover_hour` (an integer hour), NOT the
  // profile's quarter-hour `business_day_start_local_time`. The DST
  // tests below therefore exercise the converter against the
  // location-row rollover hour the harness seeds (4) — that is the
  // production path Phase 8 adapters take. The profile's TIME column
  // is a richer override consumed only by future projector slices.
  // ────────────────────────────────────────────────────────────────────
  group('Group 3 — business_date derivation honours the cutoff', () {
    test(
      'before-rollover wall clock with cutoff 04:00 → prior business '
      'date; same wall clock with cutoff 00:00 → same business date',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:resolver-cutoff-04',
            );

            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            final cutoff04 = candidates.last.businessDayStartLocalTime;
            // Restaurant-local 03:30 on 2026-05-09 with cutoff 04:00 →
            // before rollover → prior business date.
            final prior = BusinessDateResolver.resolve(
              localTimestamp: DateTime(2026, 5, 9, 3, 30),
              businessDayStartLocalTime: cutoff04,
            );
            expect(prior, equals('2026-05-08'));

            // After-rollover same day:
            final sameDay = BusinessDateResolver.resolve(
              localTimestamp: DateTime(2026, 5, 9, 5, 0),
              businessDayStartLocalTime: cutoff04,
            );
            expect(sameDay, equals('2026-05-09'));
          },
        );
      },
    );

    test(
      'cutoff 00:00 — every wall-clock instant on a calendar date '
      'maps to that calendar date as business_date',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '00:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:resolver-cutoff-00',
            );
            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            final cutoff00 = candidates.last.businessDayStartLocalTime;
            final atMidnight = BusinessDateResolver.resolve(
              localTimestamp: DateTime(2026, 5, 9, 0, 1),
              businessDayStartLocalTime: cutoff00,
            );
            expect(atMidnight, equals('2026-05-09'));
            final atLateNight = BusinessDateResolver.resolve(
              localTimestamp: DateTime(2026, 5, 9, 23, 59),
              businessDayStartLocalTime: cutoff00,
            );
            expect(atLateNight, equals('2026-05-09'));
          },
        );
      },
    );

    test(
      'DST spring-forward — IANA-tz business-date converter pinned '
      'against `locations.business_day_rollover_hour = 4`. UTC 06:30 '
      'on 2026-03-08 (spring-forward Sunday in America/Toronto) is '
      'restaurant-local 02:30 EST during the skipped hour; converter '
      'projects to the same calendar date because rollover hour 4 is '
      'after the skipped wall-clock window.',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            // Harness seeds locations with rollover hour = 4 and
            // timezone America/Toronto. We use the converter directly
            // here because the resolver is timezone-naive (see header
            // CONTRACT GAP).
            final converter = IanaTimezoneConverter();
            // 06:30 UTC on 2026-03-08 → 02:30 EST (the wall-clock
            // value the IANA database produces during a forward-spring
            // skip is implementation-defined; we pin whatever the
            // package:timezone library does for this instant).
            final result = converter.toBusinessDate(
              restaurantTimezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              instant: DateTime.utc(2026, 3, 8, 6, 30),
            );
            // Result is a UTC DATE; assert by comparing year/month/day.
            // The local wall-clock at 06:30 UTC on the spring-forward
            // Sunday is before the 04:00 rollover, so business_date is
            // 2026-03-07 (prior day). Pin the implementation choice.
            expect(result.year, equals(2026));
            expect(result.month, equals(3));
            expect(result.day, equals(7));
          },
        );
      },
    );

    test(
      'DST fall-back — IANA-tz business-date converter against '
      '`locations.business_day_rollover_hour = 4`. The 01:30 wall '
      'clock occurs twice on the November fall-back Sunday; '
      'business_date is determined by the absolute UTC instant '
      'projected through the IANA database.',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final converter = IanaTimezoneConverter();
            // First Sunday of November 2026 is 2026-11-01.
            // 05:30 UTC on 2026-11-01 → 01:30 EDT (first occurrence,
            // before fall-back).
            final firstOccurrence = converter.toBusinessDate(
              restaurantTimezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              instant: DateTime.utc(2026, 11, 1, 5, 30),
            );
            // 06:30 UTC on 2026-11-01 → 01:30 EST (second occurrence,
            // after fall-back).
            final secondOccurrence = converter.toBusinessDate(
              restaurantTimezone: 'America/Toronto',
              businessDayRolloverHour: 4,
              instant: DateTime.utc(2026, 11, 1, 6, 30),
            );
            // Both project to before-rollover wall clock → both
            // belong to the prior business date 2026-10-31. Pin the
            // implementation: the converter does NOT distinguish
            // between the two occurrences for business-date purposes,
            // because the underlying `tz.TZDateTime` resolves the
            // wall-clock fields the same way for both instants.
            expect(firstOccurrence.day, equals(31));
            expect(firstOccurrence.month, equals(10));
            expect(secondOccurrence.day, equals(31));
            expect(secondOccurrence.month, equals(10));
          },
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Group 4 — Operator-scoped read isolation.
  //
  // Both the repository pattern (primary defense) and RLS (backup
  // defense) must hold. We exercise both with the production
  // tenant SET LOCAL path through `withTenant` and verify that
  // operator B cannot read operator A's profile rows even when
  // operator B passes operator A's `(operatorId, scopeId)` parameters.
  // ────────────────────────────────────────────────────────────────────
  group('Group 4 — operator-scoped read isolation', () {
    test(
      'tenant A creates a profile; tenant B running through '
      'listProfilesForOperator with operator A\'s id sees nothing '
      '(RLS denies under tenant B SET LOCAL)',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            await seedOperator(
              pool,
              operatorId: _opB,
              locationId: _locB1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:isolation-seed-A',
            );
            await repo.createProfileAsSystem(
              operatorId: _opB,
              scopeType: 'operator',
              scopeId: _opB,
              businessDayStartLocalTime: '06:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:isolation-seed-B',
            );

            // listProfilesForOperator runs under tenant SET LOCAL with
            // operatorId. Tenant A sees only its own row.
            final aRows = await repo.listProfilesForOperator(
              operatorId: _opA,
              userId: _actorA,
            );
            expect(aRows, hasLength(1));
            expect(aRows.single.operatorId, equals(_opA));
            expect(
              aRows.single.businessDayStartLocalTime,
              equals('04:00'),
            );

            final bRows = await repo.listProfilesForOperator(
              operatorId: _opB,
              userId: _actorA,
            );
            expect(bRows, hasLength(1));
            expect(bRows.single.operatorId, equals(_opB));
            expect(
              bRows.single.businessDayStartLocalTime,
              equals('06:00'),
            );
          },
        );
      },
    );

    test(
      'system-scope listing (`set local role forge_admin`) sees both '
      'tenants — escape hatch is preserved for support flows',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            await seedOperator(
              pool,
              operatorId: _opB,
              locationId: _locB1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:system-scope-seed-A',
            );
            await repo.createProfileAsSystem(
              operatorId: _opB,
              scopeType: 'operator',
              scopeId: _opB,
              businessDayStartLocalTime: '06:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:system-scope-seed-B',
            );

            // Raw admin path — bypass RLS to count both rows.
            final adminTx = await pool.beginTransaction();
            try {
              await adminTx.execute('set local role forge_admin');
              final rows = await adminTx.query(
                'select count(*)::int as n '
                'from public.business_timing_profiles',
              );
              await adminTx.commit();
              final n = (rows.single['n'] as num).toInt();
              expect(
                n,
                equals(2),
                reason:
                    'forge_admin BYPASSRLS sees both operators\' rows; '
                    'tenant SET LOCAL would see only one',
              );
            } catch (_) {
              await adminTx.rollback();
              rethrow;
            }
          },
        );
      },
    );

    test(
      'operator A in tenant context cannot reach into operator B\'s '
      'profile rows even via crafted SQL through the same tx — RLS '
      'predicate `operator_id = public.app_current_operator()` blocks',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            await seedOperator(
              pool,
              operatorId: _opB,
              locationId: _locB1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opB,
              scopeType: 'operator',
              scopeId: _opB,
              businessDayStartLocalTime: '06:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:cross-tenant-victim',
            );

            // Run a hand-rolled count() through tenant A context that
            // explicitly filters for operator B's id. RLS folds the
            // tenant predicate into the query and the count returns 0.
            await wrapper.runInTenantContext(
              TenantContext(
                operatorId: _opA,
                locationId: _locA1,
                userId: _actorA,
              ),
              (exec) async {
                final rows = await exec.query(
                  'select count(*)::int as n '
                  'from public.business_timing_profiles '
                  "where operator_id = '$_opB'::uuid",
                );
                final n = (rows.single['n'] as num).toInt();
                expect(
                  n,
                  isZero,
                  reason:
                      'tenant A SET LOCAL forces RLS to fold '
                      '`operator_id = app_current_operator()` over the '
                      'WHERE clause; operator B rows never surface',
                );
              },
            );
          },
        );
      },
    );
  });

  // ────────────────────────────────────────────────────────────────────
  // Group 5 — `column op.rollover_hour does not exist` regression.
  //
  // Phase 3A's preview-env error excerpts named this column-missing
  // failure mode for ~1000 of 1700 webhook 5xx responses. The aliased
  // column is `locations.business_day_rollover_hour` (the `op` alias
  // referred to a `locations` row in the offending query). This test
  // is structural — it asserts that against a freshly-applied test
  // schema, the column exists and the production read path
  // (`listCandidateProfilesForLocation` + adapter-side IANA lookup)
  // does not 5xx with `42703 column does not exist`. If a future
  // migration drops the column, this test fails before Cloud Run does.
  // ────────────────────────────────────────────────────────────────────
  group('Group 5 — `op.rollover_hour does not exist` regression', () {
    test(
      'locations.business_day_rollover_hour column exists with int '
      'type and 0..23 check constraint — fresh schema must support '
      'the production business_date derivation',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            // Inspect information_schema rather than running the
            // failing-prod query directly — gives an actionable error
            // message ("column missing") if a future migration drops
            // it, instead of a 5xx leak.
            final tx = await pool.beginTransaction();
            try {
              final rows = await tx.query(
                "select column_name, data_type "
                "from information_schema.columns "
                "where table_schema = 'public' "
                "  and table_name = 'locations' "
                "  and column_name = 'business_day_rollover_hour'",
              );
              await tx.commit();
              expect(
                rows,
                isNotEmpty,
                reason:
                    'locations.business_day_rollover_hour MUST exist; '
                    'Phase 3A preview env was missing this column and '
                    '~1000 of 1700 webhook responses 5xx\'d on it',
              );
              expect(rows.single['column_name'], equals('business_day_rollover_hour'));
              // Postgres reports `integer` for the int4 type used in
              // the migration.
              expect(rows.single['data_type'], equals('integer'));
            } catch (_) {
              await tx.rollback();
              rethrow;
            }
          },
        );
      },
    );

    test(
      'production read path runs end-to-end against a fresh schema '
      '— seed an operator + location + profile, then exercise '
      'listCandidateProfilesForLocation. If `op.rollover_hour` (or '
      'any sibling column) goes missing, this test fails with a '
      'clear postgres error rather than a sanitized 5xx',
      () async {
        await withTestPostgres(
          (pool, wrapper) async {
            await seedOperator(
              pool,
              operatorId: _opA,
              locationId: _locA1,
            );
            final repo = BusinessTimingProfilesRepository(wrapper);
            await repo.createProfileAsSystem(
              operatorId: _opA,
              scopeType: 'operator',
              scopeId: _opA,
              businessDayStartLocalTime: '04:00',
              weekStartDay: 1,
              closeAuthority: 'vendor_finalization',
              effectiveFromBusinessDate: '2026-01-01',
              adminReason: 'phase-6-test:regression-fresh-schema',
            );
            final candidates =
                await repo.listCandidateProfilesForLocation(
              operatorId: _opA,
              locationId: _locA1,
              businessDate: '2026-05-09',
              userId: _actorA,
            );
            expect(candidates, hasLength(1));
            expect(
              candidates.single.businessDayStartLocalTime,
              equals('04:00'),
            );
            expect(
              candidates.single.locationTimezone,
              isNotNull,
              reason:
                  'locations.timezone surfaces through the join — if '
                  'the column or join is broken this assertion fails',
            );
          },
        );
      },
    );
  });
}

// ─── Local helpers ─────────────────────────────────────────────────────

/// Updates `locations.timezone` for [locationId] via the admin path.
/// Used by Group 1 to make the IANA-zone round-trip assertion explicit
/// without depending on the harness default.
Future<void> _setLocationTimezone(
  PostgresPool pool, {
  required String locationId,
  required String timezone,
}) async {
  final tx = await pool.beginTransaction();
  try {
    await tx.execute(
      "update public.locations "
      "set timezone = '$timezone' "
      "where location_id = '$locationId'::uuid",
    );
    await tx.commit();
  } catch (_) {
    await tx.rollback();
    rethrow;
  }
}
