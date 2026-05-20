// Per-Daypart Targets V1 (SF): Benchmark screen honesty single-source
// regression.
//
// Authority: this slice's prompt; `docs/_audits/per_daypart_v1/
// benchmark_selection_rework_spec.md` §9 (verbatim operator copy);
// CLAUDE.md (single source of truth, no parallel honesty path).
//
// Operator-reproduced defect this guards: on a real device the whole-day
// Benchmark card rendered the OLD copy ("Team looks busy without getting
// stretched. Service should hold here.") and OLD states (`OPZ RANGE TOO
// NARROW`, `RANGE UNCONFIRMED`, `RANGE TOO WIDE TO TEACH`, "let more
// shifts close … will settle"). Root cause: the canonical screen path
// `BenchmarkTrackerReadService._buildGraph` called a private STALE
// `_resolveHonesty` resolver that ignored the per-period/operation
// verdict, while a previous slice (SC) had already moved the approved
// verdict-driven copy into `BaselineData._resolveGraphHonesty`
// (consumed by the bridge `rangeGraphModel`). The two paths diverged.
//
// SF fix: `_buildGraph` now delegates its honesty/copy/state/button
// fields to the SAME single source via the additive public
// `BaselineData.resolveGraphHonesty()`; the stale `_resolveHonesty` +
// `_GraphHonesty` were deleted. This test asserts the REAL SCREEN SEAM
// (`BenchmarkTrackerReadService.instance.load()`, canonical path,
// cold-booted fresh DB) returns the verbatim §9 approved copy for the
// demo and for every driven verdict, that it never contains an
// em-dash, and that it equals what `BaselineData.rangeGraphModel`
// returns (single-source parity, so the screen and the bridge cannot
// diverge again).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forge_and_flow/domain/models/recommended_benchmark_selection.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/baseline_authority_service.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/services/benchmark_tracker_read_service.dart';
import 'package:forge_and_flow/services/target_cycle_service.dart';

import '_test_helpers/cold_boot_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('sf_screen_honesty_');
    BenchmarkTrackerReadService.disableBridgeOnly();
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    BaselineData.clearRecommendationSignals();
    // Bucket 4d (audit 2026-05-20): reset cold-boot overrides via
    // `addTearDown` so the override can't leak between tests
    // (PR #1091 bug shape). The `set` happens below in `coldBoot()`.
    addTearDown(resetColdBootOverrides);
  });

  tearDown(() async {
    BenchmarkTrackerReadService.disableBridgeOnly();
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    BaselineData.clearRecommendationSignals();
    await SqliteDatabase.instance.close();
    if (await tmpDir.exists()) {
      await tmpDir.delete(recursive: true);
    }
  });

  // True cold boot: a fresh DB file path runs `_onCreate` -> the
  // today-anchored demo seed end-to-end (the first-install path the
  // operator's device exercises).
  Future<void> coldBoot(String injectedToday) async {
    SqliteDatabase.debugColdBootTodayOverride = injectedToday;
    await SqliteDatabase.instance.useDatabasePath(
      p.join(tmpDir.path, 'cold_$injectedToday.db'),
    );
    await SqliteDatabase.instance.database; // first access -> _onCreate
  }

  // The em-dash guard the spec mandates: no operator-facing string the
  // screen renders may contain U+2014.
  void expectNoEmDash(String? s) {
    if (s == null) return;
    expect(s.contains('—'), isFalse,
        reason: 'operator-facing string must not contain an em-dash: "$s"');
  }

  // Asserts the model the REAL SCREEN seam returns carries exactly the
  // expected §9 honesty fields, has no em-dash anywhere, AND is
  // identical to what the bridge `BaselineData.rangeGraphModel`
  // returns (single-source parity: they read the same resolver).
  void expectScreenHonesty(
    BaselineRangeGraphModel screen, {
    required String badge,
    required String explanation,
    required String? sub,
    required String tier,
    required bool isDegenerate,
  }) {
    expect(screen.statusBadgeLabel, badge);
    expect(screen.recommendedExplanation, explanation);
    expect(screen.degenerateFallbackMessage, sub);
    expect(screen.qualityTier, tier);
    expect(screen.isDegenerate, isDegenerate);

    expectNoEmDash(screen.statusBadgeLabel);
    expectNoEmDash(screen.recommendedExplanation);
    expectNoEmDash(screen.degenerateFallbackMessage);
    expectNoEmDash(screen.perPeriodRollupLine);

    // Single-source parity: the screen seam and the bridge must agree
    // bit-for-bit on every honesty field: there is exactly ONE
    // verdict-driven resolver behind both now.
    final bridge = BaselineData.rangeGraphModel;
    expect(screen.statusBadgeLabel, bridge.statusBadgeLabel);
    expect(screen.recommendedExplanation, bridge.recommendedExplanation);
    expect(screen.degenerateFallbackMessage,
        bridge.degenerateFallbackMessage);
    expect(screen.qualityTier, bridge.qualityTier);
    expect(screen.isDegenerate, bridge.isDegenerate);
    expect(screen.buttonEmphasis, bridge.buttonEmphasis);
    expect(screen.perPeriodRollupLine, bridge.perPeriodRollupLine);
  }

  // Loads the canonical screen view through a cold-booted demo DB, then
  // applies [signals] (the SAME `BaselineData.applyRecommendationSignals`
  // signal path SC uses) so `_buildGraph` resolves honesty for that
  // verdict. `load()` -> `_loadCanonical` does NOT mutate signal/override
  // state, so the injected verdict is what the screen reads.
  Future<BaselineRangeGraphModel> screenModelForSignals(
      BaselineRecommendationSignals signals) async {
    BaselineData.applyRecommendationSignals(signals);
    final view = await BenchmarkTrackerReadService.instance.load();
    return view.rangeGraphModel;
  }

  BaselineRecommendationSignals signalsWithVerdict(String? verdict) =>
      BaselineRecommendationSignals(
        sourceType: verdict == null
            ? 'cycle_recommended_insufficient'
            : 'cycle_recommended',
        overallQuality: 'adequate',
        unionBandWidth: 0.50,
        selectedShiftCount: 8,
        rangeFloorCPLH: 4.2,
        rangeCeilingCPLH: 4.7,
        targetCPLH: 4.5,
        verdict: verdict,
      );

  test(
      'REAL screen seam (cold-boot demo + every driven verdict + manager '
      'override) renders verbatim §9 copy, no em-dash, single-source '
      'parity with the bridge', () async {
    // Far-from-default deterministic "today" so the demo seed is
    // unambiguous regardless of wall clock. Post-SA.1 the default demo
    // is teachable end-to-end.
    //
    // Single cold boot, sequential sections: the repository singletons'
    // DAO handle is bound to the live DB once (a documented test-harness
    // artifact, see per_daypart_v1_demo_seed_perloc_..._test.dart), so
    // the SE-test pattern of one cold boot per file is followed instead
    // of re-cold-booting between cases.
    const injectedToday = '2026-09-04';
    await coldBoot(injectedToday);

    // == A. Cold-boot demo, hydrated exactly as production bootstrap
    //       does (`forge_flow_bootstrap.dart` ->
    //       `hydrateBenchmarkHonestyFromActiveCycle`). The screen reads
    //       the demo's real verdict-driven state: verbatim §9
    //       "teachable", NOT the old "Team looks busy" line.
    await TargetCycleService.instance
        .hydrateBenchmarkHonestyFromActiveCycle(DemoScope.restaurantId);

    final demoView = await BenchmarkTrackerReadService.instance.load();
    final demo = demoView.rangeGraphModel;

    expectScreenHonesty(
      demo,
      badge: 'GOOD OPZ RANGE',
      explanation:
          'Covers, sales per hour and spend were all strong '
          'together on this range.',
      sub: 'Coach the team to this number.',
      tier: 'good',
      isDegenerate: false,
    );

    // Explicit negative guards on the exact stale literals the defect
    // showed on-device.
    expect(demo.recommendedExplanation.contains('Team looks busy'),
        isFalse);
    expect(demo.recommendedExplanation.contains('Service should hold'),
        isFalse);
    expect(demo.statusBadgeLabel, isNot('OPZ RANGE TOO NARROW'));
    expect(demo.statusBadgeLabel, isNot('OPZ RANGE TOO WIDE'));
    expect(demo.statusBadgeLabel, isNot('RANGE UNCERTAIN'));
    expect(demo.statusBadgeLabel, isNot('RANGE UNCONFIRMED'));
    expect(demo.statusBadgeLabel, isNot('RANGE TOO WIDE TO TEACH'));

    // == B. Every driven verdict maps through the REAL screen seam to
    //       its verbatim §9 badge + copy, with single-source parity.
    expectScreenHonesty(
      await screenModelForSignals(
          signalsWithVerdict(BenchmarkVerdict.teachable)),
      badge: 'GOOD OPZ RANGE',
      explanation:
          'Covers, sales per hour and spend were all strong '
          'together on this range.',
      sub: 'Coach the team to this number.',
      tier: 'good',
      isDegenerate: false,
    );

    expectScreenHonesty(
      await screenModelForSignals(
          signalsWithVerdict(BenchmarkVerdict.buildingEarly)),
      badge: 'NOT ENOUGH SHIFTS YET',
      explanation:
          'We need more closed shifts before we can set a number '
          'you can coach to.',
      sub: 'Keep running the period as usual. We are just watching '
          'for now.',
      tier: 'building',
      isDegenerate: true,
    );

    expectScreenHonesty(
      await screenModelForSignals(
          signalsWithVerdict(BenchmarkVerdict.buildingFlat)),
      badge: 'RANGE BUILDING',
      explanation:
          'There is not enough real variation between shifts yet '
          'to define a band.',
      sub: 'For now, pick the shifts that felt best for team '
          'productivity by hand while we keep building.',
      tier: 'building',
      isDegenerate: true,
    );

    expectScreenHonesty(
      await screenModelForSignals(
          signalsWithVerdict(BenchmarkVerdict.buildingFewStrong)),
      badge: 'NOT ENOUGH STRONG SHIFTS',
      explanation:
          'Only a handful of shifts had covers, sales per hour and '
          'spend all strong together. We need more before coaching '
          'to a number.',
      sub: 'For now, pick the shifts where the floor felt good, '
          'ticket times stayed clean and checks held. Those are '
          'the ones we need more of.',
      tier: 'building',
      isDegenerate: true,
    );

    expectScreenHonesty(
      await screenModelForSignals(
          signalsWithVerdict(BenchmarkVerdict.runningHot)),
      badge: 'OPERATION RUNNING HOT',
      explanation:
          'Your best shifts show the team running hot: high covers '
          'per hour, weaker spend and labor. Fix the staffing '
          'pressure before holding the team to this.',
      sub: null,
      tier: 'running_hot',
      isDegenerate: true,
    );

    // no verdict (legacy / insufficient): honest NOT ENOUGH SHIFTS
    // YET, never the old "will settle" promise.
    final legacy = await screenModelForSignals(signalsWithVerdict(null));
    expectScreenHonesty(
      legacy,
      badge: 'NOT ENOUGH SHIFTS YET',
      explanation:
          'We need more closed shifts before we can set a number '
          'you can coach to.',
      sub: 'Keep running the period as usual. We are just watching '
          'for now.',
      tier: 'building',
      isDegenerate: true,
    );
    expect(legacy.recommendedExplanation.contains('will settle'), isFalse);
    expect(legacy.recommendedExplanation.contains('let more shifts close'),
        isFalse);

    // == C. Manager override: verbatim §9 YOUR CHOSEN SHIFTS through
    //       the REAL screen seam. Drive it through the SAME canonical
    //       override flow the app uses (`saveSelection` -> persisted
    //       selection + `primeManagerOverride` ->
    //       `BaselineData.applyManagerOverride` +
    //       `applyManagerOverrideCycle`), not just an in-memory poke,
    //       so both geometry AND honesty take the real override path.
    final allCandidates =
        await BaselineManagerService.instance.getCandidateShifts();
    final pickedKeys =
        allCandidates.take(2).map((c) => c.recordKey).toSet();
    final pickedCplh = allCandidates
        .where((c) => pickedKeys.contains(c.recordKey))
        .map((c) => c.cplh)
        .toList();
    await BaselineManagerService.instance.saveSelection(pickedKeys);

    final ovView = await BenchmarkTrackerReadService.instance.load();
    final ov = ovView.rangeGraphModel;

    expect(ov.statusBadgeLabel, 'YOUR CHOSEN SHIFTS');
    expect(
        ov.recommendedExplanation,
        'You are coaching to a hand-picked set of shifts. Make sure '
        'they represent good shifts.');
    expect(ov.degenerateFallbackMessage, isNull);
    expectNoEmDash(ov.recommendedExplanation);
    expectNoEmDash(ov.statusBadgeLabel);

    final ovBridge = BaselineData.rangeGraphModel;
    expect(ov.statusBadgeLabel, ovBridge.statusBadgeLabel);
    expect(ov.recommendedExplanation, ovBridge.recommendedExplanation);
    expect(
        ov.degenerateFallbackMessage, ovBridge.degenerateFallbackMessage);

    // Override geometry preserved EXACTLY: the canonical path keeps
    // computing the active range from the (now persisted) selected
    // candidates' CPLH min/max, NOT the cycle floor/ceiling, NOT the
    // honesty source. Only honesty/copy/state switched to the single
    // source; geometry is untouched by SF.
    expect(pickedCplh, isNotEmpty);
    final selMin = pickedCplh.reduce((a, b) => a < b ? a : b);
    final selMax = pickedCplh.reduce((a, b) => a > b ? a : b);
    expect(ov.activeRangeStartCPLH, closeTo(selMin, 1e-9));
    expect(ov.activeRangeEndCPLH, closeTo(selMax, 1e-9));
    expect(ov.rangeLabel, 'STAR SHIFT RANGE');
  });
}
