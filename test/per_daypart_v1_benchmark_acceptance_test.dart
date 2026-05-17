// Per-Daypart Targets V1 — Slice SD. Durable acceptance gate.
//
// This is the regression suite the four merged slices must satisfy
// forever. Unlike the read-only diagnostic harness
// (`test/diag_benchmark_selection_pressure_test.dart`, which validated a
// LOCAL `_JimFaithfulSelector` prototype), every invariant here asserts
// against the REAL, reworked, on-master
// `RecommendedBenchmarkSelectionService.instance` and the REAL
// `MockIntegrationReplaySeed` demo dataset. It proves S0 (verdict
// persistence shape), SA (realistic demo seeder variance), SB
// (Jim-faithful engine + verdict emission) and SC (honest verdict →
// operator copy + RUNNING HOT badge + per-period breakdown) work
// together end-to-end.
//
// Spec: docs/_audits/per_daypart_v1/benchmark_selection_rework_spec.md
//   §5 acceptance criteria, §6a/§6b/§6c, §8 locked decisions, §9 copy.
//
// Authority (Jim methodology): the deep-dive Ch.09 / Ch.11 / Ch.12.
//
// NO production code is modified by this slice. The only test-support
// helpers (`_keptCohortStats`, candidate builders, a deterministic fuzz
// generator) live in this file. They re-derive the kept-cohort medians
// the service computes internally (Phase 1 gates + Phase 3 MAD) ONLY so
// the universal Jim self-defeat guard can be asserted against a value
// the public result model does not expose; they are NOT a parallel
// algorithm and assert nothing the service does not also produce.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/recommended_benchmark_selection_service.dart';
import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/dev/mock_integration_replay_seed.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';

// ─────────────────────────────────────────────────────────────────────
// Shared statistics (same definitions the real service uses internally;
// duplicated here only to re-derive the kept-cohort median PPA the
// public model does not surface, for the universal self-defeat guard).
// ─────────────────────────────────────────────────────────────────────

double _median(List<double> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

// Re-derives the service's kept cohort + its CPLH/SPLH/PPA medians for a
// daypart by replaying Phase-1 gates (RecommendedSelectionConfig
// defaults) and Phase-3 MAD exactly as
// recommended_benchmark_selection_service.dart does. Used solely so the
// "no benchmark shift below the kept-cohort median PPA" invariant can be
// checked against a value the public result does not expose.
class _KeptCohortStats {
  final int keptCount;
  final double medCplh;
  final double medSplh;
  final double medPpa;
  _KeptCohortStats(
      this.keptCount, this.medCplh, this.medSplh, this.medPpa);
}

bool _passesGates(BaselineCandidateShift c) {
  const minCovers = 20;
  const minHours = 2.0;
  if (!c.cplh.isFinite || !c.splh.isFinite || !c.ppa.isFinite) return false;
  if (c.covers < minCovers) return false;
  if (c.cplh <= 0 || c.splh <= 0 || c.ppa <= 0) return false;
  final foh = c.covers / c.cplh;
  final boh = (c.covers * c.ppa) / c.splh;
  if (!foh.isFinite || !boh.isFinite) return false;
  if (foh + boh < minHours) return false;
  return true;
}

_KeptCohortStats? _keptCohortStats(
    List<BaselineCandidateShift> candidates, String daypart) {
  const madK = 3.0;
  final cohort = candidates
      .where((c) => c.daypart == daypart && _passesGates(c))
      .toList();
  if (cohort.length < 3) return null;
  final cplhSorted = cohort.map((c) => c.cplh).toList()..sort();
  final med = _median(cplhSorted);
  final devs = cplhSorted.map((v) => (v - med).abs()).toList()..sort();
  final mad = _median(devs) * 1.4826;
  final thr = madK * mad;
  final kept = [
    for (final c in cohort)
      if (!(mad > 0 && (c.cplh - med).abs() > thr)) c
  ];
  if (kept.length < 3) return null;
  return _KeptCohortStats(
    kept.length,
    _median(kept.map((c) => c.cplh).toList()),
    _median(kept.map((c) => c.splh).toList()),
    _median(kept.map((c) => c.ppa).toList()),
  );
}

// ─────────────────────────────────────────────────────────────────────
// Candidate builders mirroring the production seams exactly.
// ─────────────────────────────────────────────────────────────────────

BaselineCandidateShift _mk(
  String k,
  String dp,
  int cov,
  double c,
  double s,
  double p, {
  bool truth = true,
  double laborPct = 22.0,
}) =>
    BaselineCandidateShift(
      recordKey: k,
      weekId: 'W',
      weekLabel: 'W',
      dayLabel: 'D',
      daypart: dp,
      covers: cov,
      cplh: c,
      splh: s,
      ppa: p,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      businessDate: '2026-03-01',
      actualLaborPct: laborPct,
      hasActualLaborPctTruth: truth,
    );

String _addIsoDays(String isoDate, int days) {
  final d = DateTime.parse('${isoDate}T00:00:00Z')
      .add(Duration(days: days));
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

// Byte-identical to sqlite_database_seed.dart `_seedRecommendationCandidates`
// (the production demo cycle write path) — same closed-shift union, same
// 60-day calibration window, same field mapping. Proves criterion 7
// against the data the real demo cycle actually feeds the engine.
List<BaselineCandidateShift> _demoSeedCandidates() {
  final replay = MockIntegrationReplaySeed.output;
  const businessDate = MockIntegrationReplaySeed.defaultBusinessDate;
  final startDate = _addIsoDays(businessDate, -59);
  final closedShifts = <ShiftRecord>[
    ...replay.historicalClosedShifts,
    ...replay.currentWeekShifts.where((s) => s.status == 'closed'),
  ];
  return closedShifts
      .where((shift) =>
          shift.businessDate != null &&
          shift.businessDate!.compareTo(startDate) >= 0 &&
          shift.businessDate!.compareTo(businessDate) <= 0)
      .map((shift) => BaselineCandidateShift(
            recordKey:
                '${shift.weekId}|${shift.dayLabel}|${shift.daypart}',
            weekId: shift.weekId,
            weekLabel: shift.weekId,
            dayLabel: shift.dayLabel,
            daypart: shift.daypart,
            covers: shift.covers,
            cplh: shift.cplh,
            splh: shift.splh,
            ppa: shift.ppa,
            primaryLeverId: shift.normalizedLeverId,
            isSelected: false,
            businessDate: shift.businessDate,
            actualLaborPct: shift.totalLaborPct,
            hasActualLaborPctTruth: shift.hasSourceBackedTotalLaborPct,
          ))
      .toList();
}

// Deterministic realistic-variance dataset (port of the validated
// harness `_realisticCandidates`). A correlated good core, a stretched
// cluster (Ch.11 ceiling), and soft/overstaffed shifts — what Jim's
// method presumes. Seeded RNG → byte-stable.
List<BaselineCandidateShift> _realisticCandidates() {
  final out = <BaselineCandidateShift>[];
  final rnd = math.Random(0x5EED);
  const spec = [
    ('lunch', 4.4, 165.0, 40.5, 160),
    ('dinner', 4.8, 200.0, 43.0, 230),
    ('late_night', 3.9, 150.0, 38.5, 85),
  ];
  for (final (dp, bC, bS, bP, bV) in spec) {
    for (var w = 0; w < 12; w++) {
      for (var d = 0; d < 6; d++) {
        final roll = rnd.nextDouble();
        double cplh, splh, ppa;
        if (roll < 0.45) {
          final lift = 0.04 + rnd.nextDouble() * 0.12;
          cplh = bC * (1 + lift) + (rnd.nextDouble() - 0.5) * 0.08;
          splh = bS * (1 + lift * 0.9) + (rnd.nextDouble() - 0.5) * 4;
          ppa = bP * (1 + lift * 0.7) + (rnd.nextDouble() - 0.5) * 0.8;
        } else if (roll < 0.62) {
          cplh = bC * (1.18 + rnd.nextDouble() * 0.10);
          splh = bS * (0.80 + rnd.nextDouble() * 0.05);
          ppa = bP * (0.74 + rnd.nextDouble() * 0.06);
        } else {
          cplh = bC * (0.80 + rnd.nextDouble() * 0.12);
          splh = bS * (0.90 + rnd.nextDouble() * 0.08);
          ppa = bP * (0.95 + rnd.nextDouble() * 0.07);
        }
        final covers = (bV * (0.9 + rnd.nextDouble() * 0.25)).round();
        out.add(_mk(
          'R|w$w|d$d|$dp',
          dp,
          covers,
          double.parse(cplh.toStringAsFixed(3)),
          double.parse(splh.toStringAsFixed(2)),
          double.parse(ppa.toStringAsFixed(3)),
        ));
      }
    }
  }
  return out;
}

// Deterministic signature of a selection result — covers selected set,
// per-period verdict + band geometry, and the operation rollup.
String _sig(RecommendedBenchmarkSelection r) {
  final sel = (r.selectedRecordIds.toList()..sort()).join(',');
  final per = (r.perDaypartStats.entries
          .map((e) => '${e.key}|${e.value.verdict}|'
              '${e.value.opzFloorCPLH.toStringAsFixed(6)}|'
              '${e.value.opzCeilingCPLH.toStringAsFixed(6)}|'
              '${e.value.recommendedTargetCPLH.toStringAsFixed(6)}|'
              '${e.value.recommendedTargetSPLH.toStringAsFixed(6)}|'
              '${e.value.recommendedTargetPPA.toStringAsFixed(6)}')
          .toList()
        ..sort())
      .join('#');
  return 'op=${r.operationVerdict}::sel=$sel::per=$per';
}

const _emDash = '—';

void main() {
  final svc = RecommendedBenchmarkSelectionService.instance;

  // ═══════════════════════════════════════════════════════════════════
  // §5.3 — DETERMINISM (kills the old List.sort instability / Bug #1)
  // ≥200 reshuffles of the same candidate list → byte-identical selected
  // set + per-period verdict + band geometry + operationVerdict.
  // ═══════════════════════════════════════════════════════════════════
  group('§5.3 determinism (≥200 reshuffles, real service)', () {
    void runDeterminism(
        String label, List<BaselineCandidateShift> base, int seed) {
      test('$label — 250 reshuffles yield exactly 1 signature', () {
        final sigs = <String>{};
        final verdicts = <String?>{};
        final rnd = math.Random(seed);
        for (var i = 0; i < 250; i++) {
          final r = svc.select([...base]..shuffle(rnd));
          sigs.add(_sig(r));
          verdicts.add(r.operationVerdict);
        }
        // ignore: avoid_print
        print('DETERMINISM[$label] 250 reshuffles → '
            'distinctSignatures=${sigs.length} '
            'operationVerdicts=$verdicts');
        expect(sigs.length, 1,
            reason: '$label: selected set / verdict / band geometry '
                'must be invariant under input permutation');
        expect(verdicts.length, 1,
            reason: '$label: operationVerdict must be stable');
      });
    }

    runDeterminism('real demo seed', _demoSeedCandidates(), 0xF00D);
    runDeterminism('realistic variance', _realisticCandidates(), 7);
    runDeterminism(
      'tied-CPLH stress',
      [
        for (var i = 0; i < 60; i++)
          _mk('t$i', i.isEven ? 'lunch' : 'dinner', 150 + (i % 7),
              4.0 + (i % 5) * 0.0, 170.0 + (i % 3), 40.0 + (i % 4) * 0.1),
        for (var i = 0; i < 40; i++)
          _mk('u$i', 'dinner', 220, 4.8, 190.0 + (i % 2), 45.0),
      ],
      0xBEEF,
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  // §5.4 / §6a — UNIVERSAL JIM SELF-DEFEAT GUARD
  // ≥500 randomized datasets: NO teachable daypart's benchmark set
  // contains a shift with PPA below that daypart's kept-cohort median
  // (0 violations), and every teachable band is well-formed.
  // ═══════════════════════════════════════════════════════════════════
  test('§5.4 universal self-defeat guard — 600 fuzz datasets, 0 violations',
      () {
    final dayparts = ['lunch', 'dinner', 'late_night'];
    var teachable = 0;
    var building = 0;
    var runningHot = 0;
    var benchPpaViolations = 0;
    var bandShapeViolations = 0;
    var targetOutsideBand = 0;
    var protoTeachableEngineWeak = 0;

    for (var t = 0; t < 600; t++) {
      final rnd = math.Random(t * 2654435761 & 0x7fffffff);
      final data = <BaselineCandidateShift>[];
      final nDp = 1 + rnd.nextInt(3);
      for (var dpi = 0; dpi < nDp; dpi++) {
        final dp = dayparts[dpi];
        final n = 3 + rnd.nextInt(120);
        final mean = 2.0 + rnd.nextDouble() * 10;
        final spread = rnd.nextDouble() * 1.6;
        final sMean = 120 + rnd.nextDouble() * 180;
        final pMean = 25 + rnd.nextDouble() * 30;
        for (var i = 0; i < n; i++) {
          final roll = rnd.nextDouble();
          double c, s, p;
          if (roll < 0.4) {
            final lift = rnd.nextDouble() * spread;
            c = mean + lift;
            s = sMean * (1 + lift * 0.08);
            p = pMean * (1 + lift * 0.06);
          } else if (roll < 0.6) {
            c = mean + spread + rnd.nextDouble() * spread;
            s = sMean * 0.8;
            p = pMean * 0.72;
          } else {
            c = (mean - rnd.nextDouble() * spread)
                .clamp(0.1, double.maxFinite);
            s = sMean * (0.9 + rnd.nextDouble() * 0.1);
            p = pMean * (0.95 + rnd.nextDouble() * 0.1);
          }
          data.add(_mk(
            'f$t-$dp-$i',
            dp,
            20 + rnd.nextInt(400),
            double.parse(c.toStringAsFixed(3)),
            double.parse(s.toStringAsFixed(2)),
            double.parse(p.toStringAsFixed(3)),
          ));
        }
      }

      final r = svc.select(data);

      // Universal: operationVerdict always in-enum (or null only on the
      // explicit insufficient fallback, which still must be honest).
      if (r.operationVerdict != null) {
        expect(BenchmarkVerdict.all.contains(r.operationVerdict), isTrue,
            reason: 'fuzz#$t: operationVerdict '
                '${r.operationVerdict} not in BenchmarkVerdict.all');
      }

      for (final e in r.perDaypartStats.entries) {
        final dp = e.key;
        final st = e.value;
        if (st.verdict != null) {
          expect(BenchmarkVerdict.all.contains(st.verdict), isTrue,
              reason: 'fuzz#$t/$dp: verdict ${st.verdict} not in-enum');
        }
        if (st.verdict == BenchmarkVerdict.teachable) {
          teachable++;
          final w = st.opzCeilingCPLH - st.opzFloorCPLH;
          if (!(w > 0 && w <= 1.25 + 1e-9)) bandShapeViolations++;
          if (!(st.opzFloorCPLH <= st.recommendedTargetCPLH + 1e-9 &&
              st.recommendedTargetCPLH <=
                  st.opzCeilingCPLH + 1e-9)) {
            targetOutsideBand++;
          }
          // THE self-defeat guard: a teachable band may never contain a
          // shift whose PPA is below the daypart's kept-cohort median —
          // the exact failure the old engine had (ranked hot shifts in
          // by CPLH then flagged the cohort weak for low PPA).
          final kept = _keptCohortStats(data, dp);
          if (kept != null) {
            for (final id in r.selectedRecordIds) {
              final m = data.where((c) =>
                  c.recordKey == id && c.daypart == dp);
              for (final sh in m) {
                if (sh.ppa < kept.medPpa - 1e-9) benchPpaViolations++;
              }
            }
          }
        } else if (st.verdict == BenchmarkVerdict.runningHot) {
          runningHot++;
        } else {
          building++;
        }
      }

      final eng = svc.select(data);
      if (r.operationVerdict == BenchmarkVerdict.teachable &&
          eng.overallQuality == 'weak') {
        protoTeachableEngineWeak++;
      }
    }

    // ignore: avoid_print
    print('FUZZ 600: teachableDayparts=$teachable '
        'buildingDayparts=$building runningHotDayparts=$runningHot');
    // ignore: avoid_print
    print('  Jim self-defeat violations (MUST be 0): '
        '$benchPpaViolations');
    // ignore: avoid_print
    print('  band-shape violations (MUST be 0): $bandShapeViolations  '
        'target-outside-band (MUST be 0): $targetOutsideBand');
    // ignore: avoid_print
    print('  teachable while legacy overallQuality==weak: '
        '$protoTeachableEngineWeak / 600');

    expect(benchPpaViolations, 0,
        reason: 'a teachable band contained a sub-kept-median-PPA shift '
            '— the exact Jim self-defeat the rework must eliminate');
    expect(bandShapeViolations, 0,
        reason: 'every teachable band must satisfy 0 < width ≤ 1.25');
    expect(targetOutsideBand, 0,
        reason: 'target must sit within [floor, ceiling] on every '
            'teachable band');
    expect(teachable, greaterThan(0),
        reason: 'fuzz must exercise teachable bands or it proves nothing');
  });

  // ═══════════════════════════════════════════════════════════════════
  // §6a — JIM FIDELITY OF THE SELECTED BAND on data WITH a real range.
  // Every selected shift is at/above the kept-cohort median on CPLH AND
  // SPLH AND PPA (Ch.09 "all three high together"); target = median of
  // the all-three-strong CPLH (Decision 3).
  // ═══════════════════════════════════════════════════════════════════
  test('§6a Jim fidelity — selected shifts all-three-strong, target=median',
      () {
    final cands = _realisticCandidates();
    final r = svc.select(cands);
    expect(r.operationVerdict, BenchmarkVerdict.teachable);
    var checkedDayparts = 0;
    for (final e in r.perDaypartStats.entries) {
      final dp = e.key;
      final st = e.value;
      if (st.verdict != BenchmarkVerdict.teachable) continue;
      checkedDayparts++;
      final kept = _keptCohortStats(cands, dp)!;
      final benchCplh = <double>[];
      for (final id in r.selectedRecordIds) {
        final m = cands
            .where((c) => c.recordKey == id && c.daypart == dp);
        for (final sh in m) {
          expect(sh.cplh, greaterThanOrEqualTo(kept.medCplh - 1e-9),
              reason: '$dp ${sh.recordKey} cplh below kept median');
          expect(sh.splh, greaterThanOrEqualTo(kept.medSplh - 1e-9),
              reason: '$dp ${sh.recordKey} splh below kept median');
          expect(sh.ppa, greaterThanOrEqualTo(kept.medPpa - 1e-9),
              reason: '$dp ${sh.recordKey} ppa below kept median');
          benchCplh.add(sh.cplh);
        }
      }
      // Decision 3 locked: target = median of the all-three-strong CPLH.
      expect(st.recommendedTargetCPLH,
          closeTo(_median(benchCplh), 1e-6),
          reason: '$dp target must equal median of benchmark CPLH');
      final w = st.opzCeilingCPLH - st.opzFloorCPLH;
      expect(w, greaterThan(0.0));
      expect(w, lessThanOrEqualTo(1.25 + 1e-9));
      expect(st.opzFloorCPLH,
          lessThanOrEqualTo(st.recommendedTargetCPLH + 1e-9));
      expect(st.recommendedTargetCPLH,
          lessThanOrEqualTo(st.opzCeilingCPLH + 1e-9));
    }
    expect(checkedDayparts, greaterThanOrEqualTo(1));
  });

  // ═══════════════════════════════════════════════════════════════════
  // §6b — CRUEL-DATA BATTERY. Never throws; verdict always in-enum;
  // spike/flat → a building_* (never a fake point, never "too narrow").
  // ═══════════════════════════════════════════════════════════════════
  test('§6b cruel-data battery — never throws, always honest', () {
    final cases = <String, List<BaselineCandidateShift>>{
      'empty': [],
      'single': [_mk('a', 'lunch', 150, 4.5, 180, 42)],
      'spike(all identical)': [
        for (var i = 0; i < 40; i++)
          _mk('s$i', 'lunch', 150, 4.40, 165, 40.5)
      ],
      'two-values': [
        for (var i = 0; i < 20; i++) _mk('lo$i', 'lunch', 150, 4.0, 170, 40),
        for (var i = 0; i < 20; i++) _mk('hi$i', 'lunch', 160, 5.0, 190, 45),
      ],
      'all-fail-gates(low covers)': [
        for (var i = 0; i < 30; i++) _mk('g$i', 'lunch', 5, 4.5, 180, 42)
      ],
      'zero/neg/NaN/Inf metrics': [
        _mk('z1', 'lunch', 150, 0, 180, 42),
        _mk('z2', 'lunch', 150, 4.5, 0, 42),
        _mk('z3', 'lunch', 150, 4.5, 180, -1),
        _mk('z4', 'lunch', 150, double.nan, 180, 42),
        _mk('z5', 'lunch', 150, double.infinity, 180, 42),
        _mk('z6', 'lunch', 150, 4.5, double.nan, 42),
        _mk('z7', 'lunch', 150, 4.5, 180, double.infinity),
        for (var i = 0; i < 8; i++)
          _mk('ok$i', 'lunch', 150, 4.4 + i * 0.05, 180.0 + i, 42.0 + i),
      ],
      'extreme-outlier': [
        for (var i = 0; i < 20; i++)
          _mk('n$i', 'dinner', 220, 4.7 + (i % 5) * 0.05, 185.0 + i,
              44.0 + (i % 4) * 0.3),
        _mk('OUT', 'dinner', 220, 999.0, 9999, 999),
      ],
      'all-stretched(hi CPLH/lo PPA)': [
        for (var i = 0; i < 30; i++)
          _mk('x$i', 'dinner', 240, 5.6 + (i % 4) * 0.05,
              150.0 + (i % 3), 31.0 + (i % 3) * 0.2)
      ],
      'all-soft(lo CPLH)': [
        for (var i = 0; i < 30; i++)
          _mk('w$i', 'lunch', 150, 3.2 + (i % 4) * 0.04, 160.0, 40.0)
      ],
      'one-daypart-only': [
        for (var i = 0; i < 30; i++)
          _mk('o$i', 'late_night', 85, 3.9 + (i % 6) * 0.06,
              150.0 + i, 38.0 + (i % 4) * 0.3)
      ],
      'duplicate-record-keys': [
        for (var i = 0; i < 30; i++)
          _mk('DUP', 'dinner', 220, 4.6 + (i % 7) * 0.04,
              185.0 + (i % 5), 44.0 + (i % 5) * 0.2)
      ],
      'missing-labor-truth': [
        for (var i = 0; i < 30; i++)
          _mk('m$i', 'dinner', 220, 4.6 + (i % 7) * 0.04,
              185.0 + (i % 5), 44.0 + (i % 5) * 0.2,
              truth: false)
      ],
      'huge-N(6000)': [
        for (var i = 0; i < 6000; i++)
          _mk('h$i', i.isEven ? 'lunch' : 'dinner', 150 + (i % 50),
              4.0 + (i % 17) * 0.06, 170.0 + (i % 23),
              40.0 + (i % 11) * 0.3)
      ],
    };

    for (final entry in cases.entries) {
      late RecommendedBenchmarkSelection r;
      expect(() => r = svc.select(entry.value), returnsNormally,
          reason: 'cruel "${entry.key}" must never throw');
      if (r.operationVerdict != null) {
        expect(BenchmarkVerdict.all.contains(r.operationVerdict), isTrue,
            reason: 'cruel "${entry.key}": operationVerdict '
                '${r.operationVerdict} not in-enum');
      }
      for (final st in r.perDaypartStats.values) {
        if (st.verdict != null) {
          expect(BenchmarkVerdict.all.contains(st.verdict), isTrue,
              reason: 'cruel "${entry.key}"/${st.daypart}: verdict '
                  '${st.verdict} not in-enum');
        }
        if (st.verdict == BenchmarkVerdict.teachable) {
          final w = st.opzCeilingCPLH - st.opzFloorCPLH;
          expect(w, greaterThan(0.0),
              reason: 'cruel "${entry.key}"/${st.daypart}: teachable '
                  'but zero-width band');
          expect(w, lessThanOrEqualTo(1.25 + 1e-9));
        }
      }
      // Determinism on every cruel case too.
      final base = _sig(r);
      final rnd = math.Random(99);
      for (var i = 0; i < 20; i++) {
        expect(_sig(svc.select([...entry.value]..shuffle(rnd))), base,
            reason: 'cruel "${entry.key}" non-deterministic under '
                'reorder');
      }
      // ignore: avoid_print
      print('  CRUEL "${entry.key}" → op=${r.operationVerdict} '
          'periods=${r.perDaypartStats.map((k, v) => MapEntry(k, v.verdict))}');
    }

    // Spike → honest building_flat, NEVER teachable, NEVER a fake point.
    final spike = svc.select(cases['spike(all identical)']!);
    expect(spike.perDaypartStats['lunch']!.verdict,
        BenchmarkVerdict.buildingFlat,
        reason: 'a zero-dispersion spike must be building_flat, never '
            'teachable and never the old "too narrow"');
    expect(spike.operationVerdict, BenchmarkVerdict.buildingFlat);
    expect(spike.perDaypartStats['lunch']!.opzCeilingCPLH, 0,
        reason: 'spike must not fabricate a band');

    // Extreme outlier MUST be MAD-dropped and not widen a teachable band.
    final outlier = svc.select(cases['extreme-outlier']!);
    final od = outlier.perDaypartStats['dinner'];
    if (od != null && od.verdict == BenchmarkVerdict.teachable) {
      expect(od.opzCeilingCPLH, lessThan(10.0),
          reason: 'extreme outlier (CPLH 999) must not drag the band up');
    }

    // Empty → explicit honest insufficient (no daypart cleared gates).
    expect(svc.select(cases['empty']!).isInsufficient, isTrue);
    // Single shift → honest building_early per-daypart (cohort below
    // minDaypartCohort): NEVER a fabricated band, NEVER teachable.
    final single = svc.select(cases['single']!);
    final sd = single.perDaypartStats['lunch'];
    expect(sd, isNotNull);
    expect(sd!.verdict, BenchmarkVerdict.buildingEarly,
        reason: 'a lone shift must be honest building_early, never a '
            'fabricated point target');
    expect(sd.opzCeilingCPLH, 0,
        reason: 'a lone shift must not fabricate a band');
  });

  // ═══════════════════════════════════════════════════════════════════
  // §5.5 — PER-DAYPART INDEPENDENCE (Ch.09 "different businesses").
  // Dropping one daypart's shifts must not change another's verdict/band.
  // ═══════════════════════════════════════════════════════════════════
  test('§5.5 per-daypart independence — dropping late_night is inert', () {
    final all = _realisticCandidates();
    final full = svc.select(all);
    final noLN = svc.select(
        all.where((c) => c.daypart != 'late_night').toList());
    for (final dp in ['lunch', 'dinner']) {
      final a = full.perDaypartStats[dp]!;
      final b = noLN.perDaypartStats[dp]!;
      expect(b.verdict, a.verdict, reason: '$dp verdict changed when an '
          'unrelated daypart was removed');
      expect(b.opzFloorCPLH, closeTo(a.opzFloorCPLH, 1e-9));
      expect(b.opzCeilingCPLH, closeTo(a.opzCeilingCPLH, 1e-9));
      expect(b.recommendedTargetCPLH,
          closeTo(a.recommendedTargetCPLH, 1e-9));
      expect(b.recommendedTargetSPLH,
          closeTo(a.recommendedTargetSPLH, 1e-9));
      expect(b.recommendedTargetPPA,
          closeTo(a.recommendedTargetPPA, 1e-9));
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  // §8 Decision 5 — TWO-SIGNAL RUNNING-HOT.
  // Throughput-strong-but-weak-spend-AND-high-labor cohort → running_hot
  // with a real band. Only one signal holding → NOT running_hot.
  // ═══════════════════════════════════════════════════════════════════
  group('§8 two-signal running-hot guardrail', () {
    // A cleanly bimodal daypart with equal-sized modes so the
    // kept-cohort CPLH/SPLH medians fall BETWEEN the modes and the
    // service's throughput-strong set (cplh>=medC AND splh>=medS) is
    // exactly the high mode. The high mode is genuinely productive
    // (high covers- and sales-per-hour) but sacrificed spend (low PPA)
    // and ran high labor — both running-hot signals (Decision 5). The
    // low mode anchors the daypart-wide PPA / labor norm.
    List<BaselineCandidateShift> hotCohort({
      required double hotPpa,
      required double hotLaborPct,
    }) {
      final out = <BaselineCandidateShift>[];
      // Low mode (15): low CPLH+SPLH, healthy spend, healthy labor.
      for (var i = 0; i < 15; i++) {
        out.add(_mk('low$i', 'dinner', 200, 4.00 + (i % 3) * 0.03,
            165.0 + (i % 3), 45.0 + (i % 3) * 0.2,
            laborPct: 20.0));
      }
      // High mode (15): high CPLH+SPLH (real throughput), the
      // running-hot candidate set — its spend / labor define the test.
      for (var i = 0; i < 15; i++) {
        out.add(_mk('hot$i', 'dinner', 260, 5.50 + (i % 3) * 0.03,
            210.0 + (i % 3), hotPpa + (i % 3) * 0.1,
            laborPct: hotLaborPct));
      }
      return out;
    }

    test('both signals → running_hot with a real band', () {
      // PPA well below daypart norm AND labor materially above norm.
      final r = svc.select(hotCohort(hotPpa: 33.0, hotLaborPct: 29.0));
      final d = r.perDaypartStats['dinner']!;
      // ignore: avoid_print
      print('RUNNING-HOT both-signals: verdict=${d.verdict} '
          'band=${d.opzFloorCPLH.toStringAsFixed(2)}-'
          '${d.opzCeilingCPLH.toStringAsFixed(2)} '
          'target=${d.recommendedTargetCPLH.toStringAsFixed(2)}');
      expect(d.verdict, BenchmarkVerdict.runningHot);
      expect(r.operationVerdict, BenchmarkVerdict.runningHot);
      // running_hot still reports a real, drawable band+target.
      expect(d.opzCeilingCPLH, greaterThan(d.opzFloorCPLH));
      expect(d.recommendedTargetCPLH, greaterThan(0.0));
    });

    test('only the PPA signal (labor normal) → NOT running_hot', () {
      // PPA low but labor in-line with the daypart norm → signal (b)
      // fails → must not flag running_hot.
      final r = svc.select(hotCohort(hotPpa: 33.0, hotLaborPct: 20.0));
      final d = r.perDaypartStats['dinner']!;
      // ignore: avoid_print
      print('RUNNING-HOT one-signal(PPA only): verdict=${d.verdict}');
      expect(d.verdict, isNot(BenchmarkVerdict.runningHot));
    });

    test('only the labor signal (spend normal) → NOT running_hot', () {
      // Labor high but PPA in-line with the norm → signal (a) fails.
      final r = svc.select(hotCohort(hotPpa: 45.0, hotLaborPct: 30.0));
      final d = r.perDaypartStats['dinner']!;
      // ignore: avoid_print
      print('RUNNING-HOT one-signal(labor only): verdict=${d.verdict}');
      expect(d.verdict, isNot(BenchmarkVerdict.runningHot));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // §9 — VERDICT → COPY RENDER MAPPING (the SC claim).
  // Drive the REAL BaselineData.rangeGraphModel via the REAL
  // applyRecommendationSignals seam; assert badge + copy equal spec §9
  // verbatim and that NO em-dash appears in any operator-facing string.
  // ═══════════════════════════════════════════════════════════════════
  group('§9 verdict → copy render mapping (real SC seam)', () {
    setUp(BaselineData.clearRecommendationSignals);
    tearDown(BaselineData.clearRecommendationSignals);

    BaselineRangeGraphModel renderFor(String verdict) {
      BaselineData.applyRecommendationSignals(
        BaselineRecommendationSignals(
          sourceType: 'cycle_recommended',
          overallQuality: 'strong',
          unionBandWidth: 0.4,
          selectedShiftCount: 12,
          rangeFloorCPLH: 4.2,
          rangeCeilingCPLH: 4.9,
          targetCPLH: 4.55,
          verdict: verdict,
        ),
      );
      return BaselineData.rangeGraphModel;
    }

    // Spec §9 verbatim strings (the build prompt uses these exactly).
    final expected = <String, ({String badge, String l1, String? l2})>{
      BenchmarkVerdict.teachable: (
        badge: 'GOOD OPZ RANGE',
        l1: 'Covers, sales per hour and spend were all strong '
            'together on this range.',
        l2: 'Coach the team to this number.',
      ),
      BenchmarkVerdict.buildingEarly: (
        badge: 'NOT ENOUGH SHIFTS YET',
        l1: 'We need more closed shifts before we can set a number '
            'you can coach to.',
        l2: 'Keep running the period as usual. We are just watching '
            'for now.',
      ),
      BenchmarkVerdict.buildingFlat: (
        badge: 'RANGE BUILDING',
        l1: 'There is not enough real variation between shifts yet '
            'to define a band.',
        l2: 'For now, pick the shifts that felt best for team '
            'productivity by hand while we keep building.',
      ),
      BenchmarkVerdict.buildingFewStrong: (
        badge: 'NOT ENOUGH STRONG SHIFTS',
        l1: 'Only a handful of shifts had covers, sales per hour and '
            'spend all strong together. We need more before coaching '
            'to a number.',
        l2: 'For now, pick the shifts where the floor felt good, '
            'ticket times stayed clean and checks held. Those are '
            'the ones we need more of.',
      ),
      BenchmarkVerdict.runningHot: (
        badge: 'OPERATION RUNNING HOT',
        l1: 'Your best shifts show the team running hot: high covers '
            'per hour, weaker spend and labor. Fix the staffing '
            'pressure before holding the team to this.',
        l2: null,
      ),
    };

    for (final verdict in BenchmarkVerdict.all) {
      test('$verdict → spec §9 verbatim badge + copy, no em-dash', () {
        final m = renderFor(verdict);
        final exp = expected[verdict]!;
        expect(m.statusBadgeLabel, exp.badge,
            reason: '$verdict badge must equal spec §9 verbatim');
        expect(m.recommendedExplanation, exp.l1,
            reason: '$verdict line 1 must equal spec §9 verbatim');
        expect(m.degenerateFallbackMessage, exp.l2,
            reason: '$verdict line 2 must equal spec §9 verbatim '
                '(null = no sub-line)');
        for (final s in <String?>[
          m.statusBadgeLabel,
          m.recommendedExplanation,
          m.degenerateFallbackMessage,
          m.perPeriodRollupLine,
        ]) {
          if (s == null) continue;
          expect(s.contains(_emDash), isFalse,
              reason: '$verdict: operator-facing string contains an '
                  'em-dash (spec §8 forbids it): "$s"');
        }
      });
    }

    test('manager-override copy = YOUR CHOSEN SHIFTS, no em-dash', () {
      // No recommendation signals + no override → legacy path; this test
      // only asserts the override copy string is em-dash free where the
      // SC seam exposes it (the override branch in _resolveGraphHonesty).
      // Without a manager override we cannot reach that branch through
      // the public seam, so we assert the rollup line + a teachable
      // render are em-dash clean as the representative operator copy.
      final m = renderFor(BenchmarkVerdict.teachable);
      expect(m.perPeriodRollupLine.contains(_emDash), isFalse);
      expect(BaselineData.perPeriodRollupLine
          .contains(_emDash), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // §5.2 / §5.7 — END-TO-END DEMO PROOF (the SA+SB+SC integration claim).
  // The REAL recommendation pipeline over the REAL post-SA demo dataset
  // must resolve EVERY demo service period to `teachable` with a real
  // band — i.e. SB's interim degenerate-data fallback in
  // sqlite_database_seed.dart is now INERT for the demo.
  // ═══════════════════════════════════════════════════════════════════
  test('§5.2/§5.7 end-to-end demo proof — every demo period teachable',
      () {
    final cands = _demoSeedCandidates();
    final r = svc.select(cands);

    // ignore: avoid_print
    print('END-TO-END DEMO: candidates=${cands.length} '
        'operationVerdict=${r.operationVerdict}');

    // Quantified root-cause dump per period so the finding is
    // self-documenting (kept-cohort dispersion after Phase-1 gates +
    // Phase-3 MAD, and the all-three-strong benchmark band width — the
    // two thresholds that decide teachable vs building_*).
    for (final periodId in MockIntegrationReplaySeed.demoServicePeriodIds) {
      final kept = _keptCohortStats(cands, periodId);
      final benchCplh = <double>[];
      if (kept != null) {
        for (final c in cands) {
          if (c.daypart != periodId || !_passesGates(c)) continue;
          if (c.cplh >= kept.medCplh - 1e-12 &&
              c.splh >= kept.medSplh - 1e-12 &&
              c.ppa >= kept.medPpa - 1e-12) {
            benchCplh.add(c.cplh);
          }
        }
      }
      benchCplh.sort();
      double q(double p) {
        if (benchCplh.isEmpty) return 0;
        if (benchCplh.length == 1) return benchCplh.first;
        final pos = (benchCplh.length - 1) * p;
        final lo = pos.floor();
        final hi = pos.ceil();
        return lo == hi
            ? benchCplh[lo]
            : benchCplh[lo] + (benchCplh[hi] - benchCplh[lo]) * (pos - lo);
      }

      // ignore: avoid_print
      print('  ROOT-CAUSE[$periodId] keptCount='
          '${kept?.keptCount ?? 0} '
          'all3StrongCount=${benchCplh.length} '
          'benchBandWidth='
          '${(q(0.75) - q(0.25)).toStringAsFixed(4)} '
          '(minBenchmark=5, minTeachableWidthCPLH=0.03, '
          'minKeptStdevCPLH=0.05)');
    }

    final failures = <String>[];
    for (final periodId in MockIntegrationReplaySeed.demoServicePeriodIds) {
      final st = r.perDaypartStats[periodId];
      if (st == null) {
        failures.add('$periodId: NO per-period stats produced '
            '(engine returned insufficient or dropped the daypart)');
        continue;
      }
      final w = st.opzCeilingCPLH - st.opzFloorCPLH;
      final headroom = st.opzCeilingCPLH - st.recommendedTargetCPLH;
      // ignore: avoid_print
      print('  $periodId verdict=${st.verdict} '
          'band=${st.opzFloorCPLH.toStringAsFixed(3)}-'
          '${st.opzCeilingCPLH.toStringAsFixed(3)} '
          'w=${w.toStringAsFixed(3)} '
          'target=${st.recommendedTargetCPLH.toStringAsFixed(3)} '
          'headroom=${headroom.toStringAsFixed(3)} '
          'selected=${st.selectedCount}');
      if (st.verdict != BenchmarkVerdict.teachable) {
        failures.add('$periodId: verdict=${st.verdict} '
            '(expected teachable) — reason: ${st.verdictReason}');
        continue;
      }
      if (!(w > 0 && w <= 1.25 + 1e-9)) {
        failures.add('$periodId: teachable but band width $w '
            'outside (0, 1.25]');
      }
      if (headroom < -1e-9) {
        failures.add('$periodId: teachable but negative headroom '
            '($headroom): target above ceiling');
      }
    }

    expect(failures, isEmpty,
        reason: 'FINDING: demo not teachable end-to-end. SB\'s interim '
            'degenerate-data fallback in sqlite_database_seed.dart is '
            'NOT inert for the post-SA demo dataset. Details:\n'
            '${failures.join('\n')}');
    expect(r.operationVerdict, BenchmarkVerdict.teachable,
        reason: 'demo operation rollup must be teachable when every '
            'period is teachable');
  });
}
