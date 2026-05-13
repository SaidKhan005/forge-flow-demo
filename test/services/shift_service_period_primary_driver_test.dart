// Phase 10.5.3 — ShiftServicePeriodReadService.computePrimaryLeverId tests.
//
// Pins per-period driver semantics defined in
// `docs/contracts/phase_7_58_primary_driver_contract.md`,
// `docs/contracts/phase_7_61_driver_key_contract.md`, and the
// 10.5.3 acceptance criteria:
//
//   * Returned ids are lowercase canonical (R-STOR-1) — never
//     upper-snake, never `'on_model'`.
//   * Empty-candidate fallback is forbidden at the daypart scope:
//     when no axis exceeds its threshold the service returns `null`
//     instead of the legacy `'covers_down'` overclaim (7.58 F-2).
//   * Insufficient inputs (no profile, no forecast covers, no
//     evidence in bucket) degrade to null without calling the engine.
//   * The id minted when there IS a real signal goes through
//     `LaborModel.determineLever` — the read service does not
//     re-mint a key from a different formula (7.61 R-PROD-1).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';

const _service = ShiftServicePeriodReadService();

ActiveTargetProfile _profile({
  double targetCPLH = 4.58,
  double targetSPLH = 180.0,
  double targetPPA = 41.50,
  double fohWage = 16.50,
  double bohWage = 21.35,
}) {
  return ActiveTargetProfile.build(
    restaurantId: 'demo_restaurant_001',
    sourceType: 'system_baseline',
    targetCPLH: targetCPLH,
    targetSPLH: targetSPLH,
    targetPPA: targetPPA,
    fohWage: fohWage,
    bohWage: bohWage,
    opzFloorCPLH: 4.0,
    opzCeilingCPLH: 5.0,
    builtAt: '2026-05-03T00:00:00Z',
  );
}

ServicePeriodAccumulator _bucket({
  String id = 'lunch',
  int covers = 0,
  double sales = 0,
  int fohMinutes = 0,
  int bohMinutes = 0,
  double fohWageDollars = 0,
  double bohWageDollars = 0,
}) {
  return ServicePeriodAccumulator(
    servicePeriodId: id,
    covers: covers,
    sales: sales,
    fohMinutes: fohMinutes,
    bohMinutes: bohMinutes,
    fohWageDollars: fohWageDollars,
    bohWageDollars: bohWageDollars,
  );
}

void main() {
  group('ShiftServicePeriodReadService.computePrimaryLeverId', () {
    test('null profile → null (no inputs to mint a driver)', () {
      final id = _service.computePrimaryLeverId(
        bucket: _bucket(covers: 100, fohMinutes: 240, bohMinutes: 240),
        forecastCovers: 100,
        profile: null,
      );
      expect(id, isNull);
    });

    test('empty bucket → null (no in-period evidence)', () {
      final id = _service.computePrimaryLeverId(
        bucket: _bucket(),
        forecastCovers: 100,
        profile: _profile(),
      );
      expect(id, isNull);
    });

    test('zero forecast covers → null (denominator missing)', () {
      final id = _service.computePrimaryLeverId(
        bucket: _bucket(covers: 100, fohMinutes: 240, bohMinutes: 240),
        forecastCovers: 0,
        profile: _profile(),
      );
      expect(id, isNull);
    });

    test(
        'on-target inputs with non-empty bucket return null (no '
        'covers_down overclaim per 7.58 F-2)', () {
      // Covers exactly on forecast, every axis within its threshold:
      // no axis fires, so the service must NOT surface the legacy
      // `'covers_down'` empty-candidate fallback.
      final bucket = _bucket(
        covers: 100,
        sales: 4150.00, // PPA = 41.50
        fohMinutes: 240, // 4 hrs FOH
        bohMinutes: 240, // 4 hrs BOH
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      // Pick targets that match the bucket so no axis fires. SPLH is
      // BOH-only per 7.58, so target it against `bohSplh` (sales /
      // BOH hours), not `splh` (sales / total hours).
      final profile = _profile(
        targetCPLH: bucket.cplh,
        targetSPLH: bucket.bohSplh,
        targetPPA: bucket.ppa,
        fohWage: bucket.fohBlendedWage,
        bohWage: bucket.bohBlendedWage,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: profile,
      );
      expect(id, isNull,
          reason: 'on-target inputs must not surface covers_down');
    });

    test('covers below forecast by > 2% surfaces lowercase covers_down', () {
      // 80 actual vs 100 forecast = -20% > -2% threshold.
      final bucket = _bucket(
        covers: 80,
        sales: 80 * 41.50, // PPA on target
        fohMinutes: 240,
        bohMinutes: 240,
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh, // CPLH on target
          targetSPLH: bucket.bohSplh, // SPLH on target (BOH-only)
          targetPPA: bucket.ppa,
        ),
      );
      expect(id, equals('covers_down'));
      expect(id, isNot(equals('COVERS_DOWN')),
          reason: 'lowercase canonical per 7.61 R-STOR-1');
    });

    test('covers above forecast by > 2% surfaces covers_up', () {
      // 130 actual vs 100 forecast = +30%.
      final bucket = _bucket(
        covers: 130,
        sales: 130 * 41.50,
        fohMinutes: 240,
        bohMinutes: 240,
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh,
          targetSPLH: bucket.bohSplh,
          targetPPA: bucket.ppa,
        ),
      );
      expect(id, equals('covers_up'));
    });

    test('PPA above target by > 3% (with other axes on target) wins ppa_up',
        () {
      // Covers on forecast (delta = 0). PPA +10% from target. Pin
      // CPLH and SPLH on target so PPA is the only axis above its
      // threshold.
      final bucket = _bucket(
        covers: 100,
        sales: 100 * 45.65, // PPA = 45.65, target = 41.50, +10%
        fohMinutes: 240,
        bohMinutes: 240,
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh, // CPLH on target
          targetSPLH: bucket.bohSplh, // BOH-only SPLH on target
          targetPPA: 41.50,
        ),
      );
      expect(id, equals('ppa_up'));
    });

    test(
        'SPLH is BOH-only: a FOH-only-minutes period never mints '
        'splh_up / splh_down, even when sales / total hours diverges '
        'from targetSPLH', () {
      // FOH-only period (no BOH minutes). Sales-per-FOH-hour is
      // wildly above any reasonable BOH SPLH target — but SPLH is
      // BOH productivity per 7.58, so this axis must be skipped.
      // Push covers above forecast so a real signal fires and we can
      // assert it's covers_up, never splh_*. (If SPLH were not
      // skipped, splh_up's |delta| would dominate covers_up and win.)
      final bucket = _bucket(
        covers: 130, // +30% vs forecast 100
        sales: 130 * 41.50, // PPA on target
        fohMinutes: 240,
        bohMinutes: 0, // <-- key: no BOH minutes
        fohWageDollars: 240 * 16.50 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh, // CPLH on target
          targetSPLH: 180.0, // BOH SPLH target (irrelevant — skipped)
          targetPPA: bucket.ppa,
        ),
      );
      expect(id, equals('covers_up'),
          reason: 'covers axis must win; SPLH is skipped because no '
              'BOH minutes exist (FOH-only period)');
      expect(id, isNot(equals('splh_up')),
          reason: 'FOH-only period must not mint SPLH (BOH-only axis)');
      expect(id, isNot(equals('splh_down')),
          reason: 'FOH-only period must not mint SPLH (BOH-only axis)');
    });

    test(
        'SPLH axis fires off bohSplh, not the FOH-blended bucket.splh '
        '(uses the same convention as the whole-day path)', () {
      // BOH minutes present and BOH SPLH well above target. The
      // engine must consume `bucket.bohSplh` (sales / BOH hours),
      // not `bucket.splh` (sales / total hours).
      final bucket = _bucket(
        covers: 100,
        sales: 100 * 41.50, // PPA on target
        fohMinutes: 240, // 4 hrs FOH
        bohMinutes: 60, //  1 hr  BOH → bohSplh = $4150 / 1 = $4150
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 60 * 21.35 / 60,
      );
      // bucket.splh = $4150 / 5 hrs = $830 — substantially below
      // bucket.bohSplh = $4150. With targetSPLH = $830, the FOH-
      // weighted reading would be on target; the BOH-only reading
      // is wildly above and must mint splh_up.
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh, // CPLH on target
          targetSPLH: bucket.splh, // FOH-blended SPLH (a TRAP value)
          targetPPA: bucket.ppa,
        ),
      );
      expect(id, equals('splh_up'),
          reason: 'engine must read bohSplh, not the bucket.splh '
              'getter that mixes FOH minutes into the denominator');
    });

    test('returned id is always one of the 16 catalog ids when non-null',
        () {
      // Drive several deltas; verify each result is in the catalog
      // (lowercase canonical) and never `'on_model'`.
      const catalog = <String>{
        'covers_down', 'covers_up',
        'ppa_down', 'ppa_up',
        'cplh_down', 'cplh_up',
        'splh_down', 'splh_up',
        'foh_wage_down', 'foh_wage_up',
        'boh_wage_down', 'boh_wage_up',
        'foh_hours_over', 'foh_hours_under',
        'boh_hours_over', 'boh_hours_under',
      };
      // Mid-shift bucket with covers down only.
      final bucket = _bucket(
        covers: 70,
        sales: 70 * 41.50,
        fohMinutes: 240,
        bohMinutes: 240,
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh,
          targetSPLH: bucket.bohSplh,
          targetPPA: bucket.ppa,
        ),
      );
      expect(id, isNotNull);
      expect(catalog.contains(id), isTrue,
          reason: 'unknown id surfaced: $id');
      expect(id, isNot(equals('on_model')));
    });

    test('lookup of returned id resolves a real LeverCardData', () {
      // The chip surface routes through `LeverCards.lookup`; verify
      // the read service output is renderable by that path.
      final bucket = _bucket(
        covers: 70,
        sales: 70 * 41.50,
        fohMinutes: 240,
        bohMinutes: 240,
        fohWageDollars: 240 * 16.50 / 60,
        bohWageDollars: 240 * 21.35 / 60,
      );
      final id = _service.computePrimaryLeverId(
        bucket: bucket,
        forecastCovers: 100,
        profile: _profile(
          targetCPLH: bucket.cplh,
          targetSPLH: bucket.bohSplh,
          targetPPA: bucket.ppa,
        ),
      );
      final card = LeverCards.lookup(id);
      expect(card, isNotNull);
      expect(card!.id, equals(id));
    });
  });

  group('ShiftServicePeriodReadService.computePrimaryLevers', () {
    test('builds a per-period map with null for empty buckets', () {
      final buckets = <String, ServicePeriodAccumulator>{
        'lunch': _bucket(
          id: 'lunch',
          covers: 70,
          sales: 70 * 41.50,
          fohMinutes: 240,
          bohMinutes: 240,
          fohWageDollars: 240 * 16.50 / 60,
          bohWageDollars: 240 * 21.35 / 60,
        ),
        'dinner': _bucket(id: 'dinner'), // empty
        'late_night': _bucket(id: 'late_night'), // empty
      };
      final lunchBucket = buckets['lunch']!;
      final result = _service.computePrimaryLevers(
        buckets: buckets,
        forecastCoversByPeriod: const {
          'lunch': 100,
          'dinner': 80,
          'late_night': 30,
        },
        profile: _profile(
          targetCPLH: lunchBucket.cplh,
          targetSPLH: lunchBucket.bohSplh,
          targetPPA: lunchBucket.ppa,
        ),
      );
      expect(result['lunch'], equals('covers_down'));
      expect(result['dinner'], isNull);
      expect(result['late_night'], isNull);
    });

    test('missing forecast covers entry defaults to 0 → null per period',
        () {
      final buckets = <String, ServicePeriodAccumulator>{
        'lunch': _bucket(
          id: 'lunch',
          covers: 70,
          sales: 70 * 41.50,
          fohMinutes: 240,
          bohMinutes: 240,
          fohWageDollars: 240 * 16.50 / 60,
          bohWageDollars: 240 * 21.35 / 60,
        ),
      };
      final result = _service.computePrimaryLevers(
        buckets: buckets,
        forecastCoversByPeriod: const {}, // missing 'lunch'
        profile: _profile(),
      );
      expect(result['lunch'], isNull);
    });

    test('null profile collapses every period to null', () {
      final buckets = <String, ServicePeriodAccumulator>{
        'lunch': _bucket(
          id: 'lunch',
          covers: 70,
          sales: 70 * 41.50,
          fohMinutes: 240,
          bohMinutes: 240,
        ),
      };
      final result = _service.computePrimaryLevers(
        buckets: buckets,
        forecastCoversByPeriod: const {'lunch': 100},
        profile: null,
      );
      expect(result['lunch'], isNull);
    });
  });
}
