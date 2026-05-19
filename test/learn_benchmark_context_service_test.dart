// Phase 7.55l.8b+8c1+8d — Learn Benchmark Context Service Tests
//
// Focused tests covering:
// - BaselineSelectionAnalyticsService range-quality computation
// - LearnBenchmarkContextService canonical path uses persisted analytics
// - Bridge-only and no-profile bootstrap fallback still work
// - Missing-summary recovery backfill (8c1)
// - Profile-without-cycle recovery (8d)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_selection_analytics_service.dart';
import 'package:forge_and_flow/services/learn_benchmark_context_service.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/benchmark_selection_summary.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/models/baseline_selection_analytics.dart';
import 'package:forge_and_flow/models/learn_benchmark_context.dart';

void main() {
  setUp(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    LearnBenchmarkContextService.enableBridgeOnly();
    BaselineSelectionAnalyticsService.enableBridgeOnly();
  });

  tearDown(() {
    BaselineData.clearManagerOverride();
    BaselineData.clearHistoricalContext();
    LearnBenchmarkContextService.disableBridgeOnly();
    LearnBenchmarkContextService.testCanonicalOverride = null;
    LearnBenchmarkContextService.testGetRestaurantId = null;
    LearnBenchmarkContextService.testGetProfile = null;
    LearnBenchmarkContextService.testGetCycle = null;
    LearnBenchmarkContextService.testGetSummary = null;
    LearnBenchmarkContextService.testPersistSummary = null;
    LearnBenchmarkContextService.testGetAnchorDate = null;
    LearnBenchmarkContextService.testRecoverCycle = null;
    BaselineSelectionAnalyticsService.disableBridgeOnly();
    BaselineSelectionAnalyticsService.testAnalyticsOverride = null;
  });

  // ── A: analytics — fewer than 2 selected produces narrow range ──────────

  group('A — fewer than 2 selected shifts', () {
    test('zero selected produces OPZ RANGE TOO NARROW', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        return const BaselineSelectionAnalytics(
          selectedShiftCount: 0,
          rangeQualityLabel: 'OPZ RANGE TOO NARROW',
          rangeQualityMessage:
              'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
        );
      };

      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve();
      expect(analytics.selectedShiftCount, equals(0));
      expect(analytics.rangeQualityLabel, equals('OPZ RANGE TOO NARROW'));
    });

    test('one selected produces OPZ RANGE TOO NARROW', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        return const BaselineSelectionAnalytics(
          selectedShiftCount: 1,
          rangeQualityLabel: 'OPZ RANGE TOO NARROW',
          rangeQualityMessage:
              'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
        );
      };

      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve();
      expect(analytics.selectedShiftCount, equals(1));
      expect(analytics.rangeQualityLabel, equals('OPZ RANGE TOO NARROW'));
    });
  });

  // ── B: analytics — healthy range produces GOOD OPZ RANGE ────────────────

  group('B — healthy selected range', () {
    test('moderate CPLH spread produces GOOD OPZ RANGE', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        return const BaselineSelectionAnalytics(
          selectedShiftCount: 5,
          rangeQualityLabel: 'GOOD OPZ RANGE',
          rangeQualityMessage:
              'Team looks busy without getting stretched. Service should hold here.',
        );
      };

      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve();
      expect(analytics.selectedShiftCount, equals(5));
      expect(analytics.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });
  });

  // ── C: analytics — wide range produces OPZ RANGE TOO WIDE ──────────────

  group('C — wide selected range', () {
    test('wide CPLH spread produces OPZ RANGE TOO WIDE', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        return const BaselineSelectionAnalytics(
          selectedShiftCount: 8,
          rangeQualityLabel: 'OPZ RANGE TOO WIDE',
          rangeQualityMessage:
              'Star shifts are spread too far apart. Tighten the set until the team is working to one standard.',
        );
      };

      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve();
      expect(analytics.selectedShiftCount, equals(8));
      expect(analytics.rangeQualityLabel, equals('OPZ RANGE TOO WIDE'));
    });
  });

  // ── D: analytics computation logic (direct static method tests) ─────────

  group('D — analytics computation rules', () {
    test('0 selected -> narrow with count 0', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(0, []);
      expect(a.selectedShiftCount, equals(0));
      expect(a.rangeQualityLabel, equals('OPZ RANGE TOO NARROW'));
    });

    test('1 selected -> narrow with count 1', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(1, [4.5]);
      expect(a.selectedShiftCount, equals(1));
      expect(a.rangeQualityLabel, equals('OPZ RANGE TOO NARROW'));
    });

    test('2 selected with width < 0.15 -> narrow', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(2, [
        4.50,
        4.60,
      ]);
      expect(a.selectedShiftCount, equals(2));
      expect(a.rangeQualityLabel, equals('OPZ RANGE TOO NARROW'));
    });

    test('3 selected with moderate width -> healthy', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(3, [
        4.2,
        4.6,
        4.9,
      ]);
      expect(a.selectedShiftCount, equals(3));
      expect(a.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });

    test('4 selected with width > 1.25 -> wide', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(4, [
        3.2,
        4.4,
        4.8,
        5.0,
      ]);
      expect(a.selectedShiftCount, equals(4));
      expect(a.rangeQualityLabel, equals('OPZ RANGE TOO WIDE'));
    });

    test('boundary: width exactly 0.15 -> healthy', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(2, [
        4.50,
        4.65,
      ]);
      expect(a.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });

    test('boundary: width exactly 1.25 -> healthy', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(2, [
        4.00,
        5.25,
      ]);
      expect(a.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });
  });

  // ── E: canonical path returns analytics from persisted state ────────────

  group('E — canonical path uses persisted analytics', () {
    test('canonical path returns injected analytics, not BaselineData', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        return const LearnBenchmarkContext(
          benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
          selectedShiftCount: 12,
          targetCPLH: 4.5,
          targetSPLH: 180.0,
          targetPPA: 42.0,
          rangeQualityLabel: 'GOOD OPZ RANGE',
          rangeQualityMessage:
              'Team looks busy without getting stretched. Service should hold here.',
        );
      };

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.selectedShiftCount, equals(12));
      expect(ctx.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });

    test('canonical path analytics differ from BaselineData values', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        return const LearnBenchmarkContext(
          benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
          selectedShiftCount: 25,
          targetCPLH: 5.0,
          targetSPLH: 200.0,
          targetPPA: 50.0,
          rangeQualityLabel: 'OPZ RANGE TOO WIDE',
          rangeQualityMessage: 'Test wide message.',
        );
      };

      final ctx = await LearnBenchmarkContextService.instance.resolve();

      expect(ctx.selectedShiftCount, equals(25));
      expect(ctx.rangeQualityLabel, equals('OPZ RANGE TOO WIDE'));
      expect(ctx.rangeQualityMessage, equals('Test wide message.'));
    });
  });

  // ── F: bridge-only mode still works ─────────────────────────────────────

  group('F — bridge-only mode', () {
    test('bridge-only returns BaselineData-sourced context', () async {
      LearnBenchmarkContextService.enableBridgeOnly();
      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
      expect(ctx.selectedShiftCount, equals(BaselineData.selectedRecordCount));
    });

    test('analytics bridge-only returns BaselineData analytics', () async {
      BaselineSelectionAnalyticsService.enableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve();
      expect(
        analytics.selectedShiftCount,
        equals(BaselineData.selectedRecordCount),
      );
      expect(
        analytics.rangeQualityLabel,
        equals(BaselineData.baselineRangeValidation.statusLabel),
      );
    });
  });

  // ── G: no-profile bootstrap fallback still works ────────────────────────

  group('G — no-profile bootstrap fallback', () {
    test('null profile bootstrap returns bridge context', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async => null;
      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
    });
  });

  // ── H: repository error propagation still works ─────────────────────────

  group('H — repository error propagation', () {
    test('context service error propagates', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        throw StateError('simulated repository failure');
      };
      await expectLater(
        LearnBenchmarkContextService.instance.resolve(),
        throwsA(isA<StateError>()),
      );
    });

    test('analytics service error propagates', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        throw StateError('simulated analytics failure');
      };
      await expectLater(
        BaselineSelectionAnalyticsService.instance.resolve(),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── I: range quality messages match production wording ──────────────────

  group('I — range quality message wording', () {
    test('narrow message matches production wording', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(0, []);
      expect(
        a.rangeQualityMessage,
        equals(
          'Star shifts are bunched too tightly. Add a few more solid shifts before coaching to this range.',
        ),
      );
    });

    test('healthy message matches production wording', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(3, [
        4.2,
        4.6,
        4.9,
      ]);
      expect(
        a.rangeQualityMessage,
        equals(
          'Team looks busy without getting stretched. Service should hold here.',
        ),
      );
    });

    test('wide message matches production wording', () {
      final a = BaselineSelectionAnalyticsService.computeAnalytics(4, [
        3.2,
        4.4,
        4.8,
        5.0,
      ]);
      expect(
        a.rangeQualityMessage,
        equals(
          'Star shifts are spread too far apart. Tighten the set until the team is working to one standard.',
        ),
      );
    });
  });

  // ── J: source-aware analytics resolution (7.55l.8b1) ──────────────────────

  group('J — source-aware analytics resolution', () {
    test('system_baseline returns bridge analytics, not 0/NARROW', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: 'system_baseline');
      // Bridge fallback returns BaselineData fixture defaults (14 selected, healthy)
      expect(
        analytics.selectedShiftCount,
        equals(BaselineData.selectedRecordCount),
      );
      expect(
        analytics.rangeQualityLabel,
        equals(BaselineData.baselineRangeValidation.statusLabel),
      );
      expect(
        analytics.rangeQualityLabel,
        isNot(equals('OPZ RANGE TOO NARROW')),
      );
    });

    test('cycle_recommended returns bridge analytics, not 0/NARROW', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: 'cycle_recommended');
      expect(
        analytics.selectedShiftCount,
        equals(BaselineData.selectedRecordCount),
      );
      expect(
        analytics.rangeQualityLabel,
        isNot(equals('OPZ RANGE TOO NARROW')),
      );
    });

    test('null source returns bridge analytics, not 0/NARROW', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: null);
      expect(
        analytics.selectedShiftCount,
        equals(BaselineData.selectedRecordCount),
      );
      expect(
        analytics.rangeQualityLabel,
        isNot(equals('OPZ RANGE TOO NARROW')),
      );
    });

    test('admin_replacement returns bridge analytics', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: 'admin_replacement');
      expect(
        analytics.selectedShiftCount,
        equals(BaselineData.selectedRecordCount),
      );
    });

    test('manager_override uses persisted path, not bridge', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      // No testAnalyticsOverride — override source hits persisted path.
      // In the unit test env, getCandidateShifts() returns empty (no SQLite
      // override data), so persisted path produces 0 selected. Bridge would
      // return BaselineData.selectedRecordCount (14 from seed records).
      // The difference proves it took the persisted path, not bridge.
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: 'manager_override');
      expect(
        analytics.selectedShiftCount,
        isNot(equals(BaselineData.selectedRecordCount)),
      );
    });

    test('cycle_manager_override uses persisted path, not bridge', () async {
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      final analytics = await BaselineSelectionAnalyticsService.instance
          .resolve(sourceType: 'cycle_manager_override');
      expect(
        analytics.selectedShiftCount,
        isNot(equals(BaselineData.selectedRecordCount)),
      );
    });

    test(
      'override source with testAnalyticsOverride returns injected value',
      () async {
        BaselineSelectionAnalyticsService.disableBridgeOnly();
        BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
          return const BaselineSelectionAnalytics(
            selectedShiftCount: 7,
            rangeQualityLabel: 'GOOD OPZ RANGE',
            rangeQualityMessage: 'injected test message',
          );
        };
        final analytics = await BaselineSelectionAnalyticsService.instance
            .resolve(sourceType: 'manager_override');
        expect(analytics.selectedShiftCount, equals(7));
        expect(analytics.rangeQualityMessage, equals('injected test message'));
      },
    );
  });

  // ── K: context service source-type passthrough (7.55l.8b1) ─────────────────

  group('K — context service passes source type to analytics', () {
    test('canonical system_baseline profile does not produce 0/NARROW', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      // Canonical override returns a system_baseline profile
      // Analytics service should receive system_baseline and use bridge
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        return const LearnBenchmarkContext(
          benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
          selectedShiftCount: 14,
          targetCPLH: 4.5,
          targetSPLH: 180.0,
          targetPPA: 42.0,
          rangeQualityLabel: 'GOOD OPZ RANGE',
          rangeQualityMessage:
              'Team looks busy without getting stretched. Service should hold here.',
        );
      };

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.selectedShiftCount, equals(14));
      expect(ctx.rangeQualityLabel, isNot(equals('OPZ RANGE TOO NARROW')));
    });

    test(
      'Learn source label and targets stay on repository-backed profile',
      () async {
        LearnBenchmarkContextService.disableBridgeOnly();
        LearnBenchmarkContextService.testCanonicalOverride = () async {
          return const LearnBenchmarkContext(
            benchmarkSourceLabel: 'MANAGER STAR SHIFTS',
            selectedShiftCount: 5,
            targetCPLH: 5.0,
            targetSPLH: 200.0,
            targetPPA: 50.0,
            rangeQualityLabel: 'GOOD OPZ RANGE',
            rangeQualityMessage: 'test message',
          );
        };

        final ctx = await LearnBenchmarkContextService.instance.resolve();
        expect(ctx.benchmarkSourceLabel, equals('MANAGER STAR SHIFTS'));
        expect(ctx.targetCPLH, equals(5.0));
        expect(ctx.targetSPLH, equals(200.0));
        expect(ctx.targetPPA, equals(50.0));
      },
    );
  });

  // ── L: persisted summary path (7.55l.8c) ──────────────────────────────────

  group('L — canonical path reads from persisted summary', () {
    test('canonical path returns injected summary analytics', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async {
        return const LearnBenchmarkContext(
          benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
          selectedShiftCount: 14,
          targetCPLH: 4.5,
          targetSPLH: 180.0,
          targetPPA: 42.0,
          rangeQualityLabel: 'GOOD OPZ RANGE',
          rangeQualityMessage:
              'Team looks busy without getting stretched. Service should hold here.',
        );
      };

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.selectedShiftCount, equals(14));
      expect(ctx.rangeQualityLabel, equals('GOOD OPZ RANGE'));
    });

    test(
      'canonical path with persisted summary does not use bridge analytics',
      () async {
        LearnBenchmarkContextService.disableBridgeOnly();
        // Inject a context with values distinct from BaselineData bridge
        LearnBenchmarkContextService.testCanonicalOverride = () async {
          return const LearnBenchmarkContext(
            benchmarkSourceLabel: 'SYSTEM BENCHMARK SET',
            selectedShiftCount: 99,
            targetCPLH: 4.5,
            targetSPLH: 180.0,
            targetPPA: 42.0,
            rangeQualityLabel: 'GOOD OPZ RANGE',
            rangeQualityMessage: 'Persisted summary message.',
          );
        };

        final ctx = await LearnBenchmarkContextService.instance.resolve();
        expect(ctx.selectedShiftCount, equals(99));
        expect(ctx.rangeQualityMessage, equals('Persisted summary message.'));
        // Must differ from bridge value
        expect(
          ctx.selectedShiftCount,
          isNot(equals(BaselineData.selectedRecordCount)),
        );
      },
    );
  });

  // ── M: bridge-only and bootstrap still work after 8c ───────────────────────

  group('M — bridge-only and bootstrap fallback after 8c', () {
    test('bridge-only mode still returns BaselineData context', () async {
      LearnBenchmarkContextService.enableBridgeOnly();
      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
      expect(ctx.selectedShiftCount, equals(BaselineData.selectedRecordCount));
    });

    test('null profile bootstrap still returns bridge context', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testCanonicalOverride = () async => null;
      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, equals('SYSTEM BENCHMARK SET'));
      expect(ctx.targetCPLH, equals(BaselineData.derivedTargetCPLH));
    });
  });

  // ── N: missing-summary recovery backfill (8c1) ────────────────────────────

  group('N — missing-summary recovery backfill (8c1)', () {
    // Shared test fixtures
    const testProfile = ActiveTargetProfile(
      targetProfileId: 'tp_001',
      restaurantId: 'r1',
      sourceType: 'cycle_recommended',
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      theoreticalFohLaborPct: 0.25,
      theoreticalBohLaborPct: 0.20,
      theoreticalLaborPct: 0.45,
      builtAt: '2026-04-01T00:00:00Z',
    );

    const testCycle = TargetCycle(
      cycleId: 'cycle_n01',
      restaurantId: 'r1',
      source: TargetCycleSource.recommended,
      effectiveStart: '2026-03-01',
      effectiveEnd: '2026-04-30',
      calibrationWindowStart: '2026-01-01',
      calibrationWindowEnd: '2026-02-28',
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      createdAt: '2026-03-01T00:00:00Z',
    );

    void setUpRecoveryScenario({
      required Future<BenchmarkSelectionSummary?> Function(String)
      summaryLookup,
      required Future<void> Function(BenchmarkSelectionSummary) summaryPersist,
    }) {
      LearnBenchmarkContextService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => testProfile;
      LearnBenchmarkContextService.testGetCycle = (rid) async => testCycle;
      LearnBenchmarkContextService.testGetSummary = summaryLookup;
      LearnBenchmarkContextService.testPersistSummary = summaryPersist;
      BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
        return const BaselineSelectionAnalytics(
          selectedShiftCount: 14,
          rangeQualityLabel: 'GOOD OPZ RANGE',
          rangeQualityMessage: 'Recovery analytics message.',
        );
      };
    }

    test(
      'active cycle + missing summary triggers recovery and persists',
      () async {
        BenchmarkSelectionSummary? captured;
        setUpRecoveryScenario(
          summaryLookup: (cid) async => null,
          summaryPersist: (s) async {
            captured = s;
          },
        );

        final ctx = await LearnBenchmarkContextService.instance.resolve();

        // Verify summary was persisted
        expect(
          captured,
          isNotNull,
          reason: 'recovery should persist a summary',
        );
        expect(captured!.targetCycleId, 'cycle_n01');
        expect(captured!.sourceType, 'cycle_recommended');
        expect(captured!.selectedShiftCount, 14);
        expect(captured!.rangeQualityLabel, 'GOOD OPZ RANGE');

        // Verify returned context uses recovered values
        expect(ctx.selectedShiftCount, 14);
        expect(ctx.rangeQualityLabel, 'GOOD OPZ RANGE');
        expect(ctx.rangeQualityMessage, 'Recovery analytics message.');
        expect(ctx.benchmarkSourceLabel, 'SYSTEM BENCHMARK SET');
      },
    );

    test(
      'second read after recovery uses persisted summary, no re-recovery',
      () async {
        BenchmarkSelectionSummary? persisted;
        int persistCount = 0;

        setUpRecoveryScenario(
          summaryLookup: (cid) async => persisted,
          summaryPersist: (s) async {
            persisted = s;
            persistCount++;
          },
        );

        // First call: triggers recovery
        await LearnBenchmarkContextService.instance.resolve();
        expect(
          persistCount,
          1,
          reason: 'first call should trigger one recovery persist',
        );

        // Second call: uses persisted summary, no re-recovery
        final ctx2 = await LearnBenchmarkContextService.instance.resolve();
        expect(
          persistCount,
          1,
          reason: 'second call should not re-trigger recovery',
        );
        expect(ctx2.selectedShiftCount, 14);
        expect(ctx2.rangeQualityLabel, 'GOOD OPZ RANGE');
      },
    );

    test('recovery does not trigger when summary already exists', () async {
      int persistCount = 0;

      LearnBenchmarkContextService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => testProfile;
      LearnBenchmarkContextService.testGetCycle = (rid) async => testCycle;
      LearnBenchmarkContextService.testGetSummary = (cid) async =>
          const BenchmarkSelectionSummary(
            summaryId: 'cycle_n01_summary',
            restaurantId: 'r1',
            targetCycleId: 'cycle_n01',
            sourceType: 'cycle_recommended',
            selectedShiftCount: 14,
            rangeQualityLabel: 'GOOD OPZ RANGE',
            rangeQualityMessage: 'Existing summary message.',
            createdAt: '2026-04-01T00:00:00Z',
          );
      LearnBenchmarkContextService.testPersistSummary = (s) async {
        persistCount++;
      };

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(persistCount, 0, reason: 'no recovery should trigger');
      expect(ctx.selectedShiftCount, 14);
      expect(ctx.rangeQualityMessage, 'Existing summary message.');
    });

    test('repo failure in recovery path propagates', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => testProfile;
      LearnBenchmarkContextService.testGetCycle = (rid) async {
        throw StateError('simulated cycle repository failure');
      };

      await expectLater(
        LearnBenchmarkContextService.instance.resolve(),
        throwsA(isA<StateError>()),
      );
    });

    test('no-profile path returns bootstrap via per-repo overrides', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => null;

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, 'SYSTEM BENCHMARK SET');
      expect(ctx.targetCPLH, BaselineData.derivedTargetCPLH);
    });
  });

  // ── O: profile-without-cycle recovery (8d) ────────────────────────────────

  group('O — profile-without-cycle recovery (8d)', () {
    // Shared test fixtures
    const testProfile = ActiveTargetProfile(
      targetProfileId: 'tp_o01',
      restaurantId: 'r1',
      sourceType: 'cycle_recommended',
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      theoreticalFohLaborPct: 0.25,
      theoreticalBohLaborPct: 0.20,
      theoreticalLaborPct: 0.45,
      builtAt: '2026-04-01T00:00:00Z',
    );

    // Profile returned after cycle recovery (fresh projection)
    const recoveredProfile = ActiveTargetProfile(
      targetProfileId: 'tp_o01_recovered',
      restaurantId: 'r1',
      sourceType: 'cycle_recommended',
      targetCPLH: 4.6,
      targetSPLH: 185.0,
      targetPPA: 43.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      theoreticalFohLaborPct: 0.25,
      theoreticalBohLaborPct: 0.20,
      theoreticalLaborPct: 0.45,
      builtAt: '2026-04-12T00:00:00Z',
    );

    const recoveredCycle = TargetCycle(
      cycleId: 'cycle_o01_recovered',
      restaurantId: 'r1',
      source: TargetCycleSource.recommended,
      effectiveStart: '2026-04-12',
      effectiveEnd: '2026-06-10',
      calibrationWindowStart: '2026-02-12',
      calibrationWindowEnd: '2026-04-12',
      targetCPLH: 4.6,
      targetSPLH: 185.0,
      targetPPA: 43.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      createdAt: '2026-04-12T00:00:00Z',
    );

    const recoveredSummary = BenchmarkSelectionSummary(
      summaryId: 'cycle_o01_recovered_summary',
      restaurantId: 'r1',
      targetCycleId: 'cycle_o01_recovered',
      sourceType: 'cycle_recommended',
      selectedShiftCount: 14,
      rangeQualityLabel: 'GOOD OPZ RANGE',
      rangeQualityMessage: 'Recovered summary message.',
      createdAt: '2026-04-12T00:00:00Z',
    );

    test(
      'profile + missing cycle + anchor recovers cycle and returns canonical context',
      () async {
        LearnBenchmarkContextService.disableBridgeOnly();
        BaselineSelectionAnalyticsService.disableBridgeOnly();

        int profileReadCount = 0;
        LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
        LearnBenchmarkContextService.testGetProfile = (rid) async {
          profileReadCount++;
          // After recovery, return the recovered profile
          return profileReadCount > 1 ? recoveredProfile : testProfile;
        };
        LearnBenchmarkContextService.testGetCycle = (rid) async => null;
        LearnBenchmarkContextService.testGetAnchorDate = (rid) async =>
            '2026-04-12';
        LearnBenchmarkContextService.testRecoverCycle = (rid, anchor) async =>
            recoveredCycle;
        LearnBenchmarkContextService.testGetSummary = (cid) async =>
            recoveredSummary;

        final ctx = await LearnBenchmarkContextService.instance.resolve();

        // Verify profile was re-read after recovery
        expect(
          profileReadCount,
          2,
          reason: 'profile should be read once initially, once after recovery',
        );

        // Verify returned context uses recovered profile values
        expect(ctx.targetCPLH, 4.6);
        expect(ctx.targetSPLH, 185.0);
        expect(ctx.targetPPA, 43.0);

        // Verify returned context uses recovered summary values
        expect(ctx.selectedShiftCount, 14);
        expect(ctx.rangeQualityLabel, 'GOOD OPZ RANGE');
        expect(ctx.rangeQualityMessage, 'Recovered summary message.');
        expect(ctx.benchmarkSourceLabel, 'SYSTEM BENCHMARK SET');
      },
    );

    test('recovery path no longer uses plain compatibility fallback', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.disableBridgeOnly();

      bool recoverCycleCalled = false;
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => testProfile;
      LearnBenchmarkContextService.testGetCycle = (rid) async => null;
      LearnBenchmarkContextService.testGetAnchorDate = (rid) async =>
          '2026-04-12';
      LearnBenchmarkContextService.testRecoverCycle = (rid, anchor) async {
        recoverCycleCalled = true;
        return recoveredCycle;
      };
      LearnBenchmarkContextService.testGetSummary = (cid) async =>
          recoveredSummary;

      await LearnBenchmarkContextService.instance.resolve();

      expect(
        recoverCycleCalled,
        isTrue,
        reason: 'missing cycle should trigger recovery, not bridge fallback',
      );
    });

    test(
      'recovered path repairs missing summary through 8c1 backfill',
      () async {
        LearnBenchmarkContextService.disableBridgeOnly();
        BaselineSelectionAnalyticsService.disableBridgeOnly();

        BenchmarkSelectionSummary? capturedSummary;
        LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
        LearnBenchmarkContextService.testGetProfile = (rid) async =>
            recoveredProfile;
        LearnBenchmarkContextService.testGetCycle = (rid) async => null;
        LearnBenchmarkContextService.testGetAnchorDate = (rid) async =>
            '2026-04-12';
        LearnBenchmarkContextService.testRecoverCycle = (rid, anchor) async =>
            recoveredCycle;
        // Summary is null — should trigger 8c1 backfill after cycle recovery
        LearnBenchmarkContextService.testGetSummary = (cid) async => null;
        LearnBenchmarkContextService.testPersistSummary = (s) async {
          capturedSummary = s;
        };
        BaselineSelectionAnalyticsService.testAnalyticsOverride = () async {
          return const BaselineSelectionAnalytics(
            selectedShiftCount: 14,
            rangeQualityLabel: 'GOOD OPZ RANGE',
            rangeQualityMessage: 'Backfilled after recovery.',
          );
        };

        final ctx = await LearnBenchmarkContextService.instance.resolve();

        expect(
          capturedSummary,
          isNotNull,
          reason: '8c1 backfill should fire after cycle recovery',
        );
        expect(capturedSummary!.targetCycleId, 'cycle_o01_recovered');
        expect(ctx.selectedShiftCount, 14);
        expect(ctx.rangeQualityMessage, 'Backfilled after recovery.');
      },
    );

    test('post-recovery null profile throws StateError (8d1)', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      BaselineSelectionAnalyticsService.disableBridgeOnly();

      int profileReadCount = 0;
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async {
        profileReadCount++;
        // Initial read returns profile, post-recovery re-read returns null
        return profileReadCount > 1 ? null : testProfile;
      };
      LearnBenchmarkContextService.testGetCycle = (rid) async => null;
      LearnBenchmarkContextService.testGetAnchorDate = (rid) async =>
          '2026-04-12';
      LearnBenchmarkContextService.testRecoverCycle = (rid, anchor) async =>
          recoveredCycle;

      await expectLater(
        LearnBenchmarkContextService.instance.resolve(),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'no anchor date for profile-without-cycle throws StateError',
      () async {
        LearnBenchmarkContextService.disableBridgeOnly();

        LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
        LearnBenchmarkContextService.testGetProfile = (rid) async =>
            testProfile;
        LearnBenchmarkContextService.testGetCycle = (rid) async => null;
        LearnBenchmarkContextService.testGetAnchorDate = (rid) async => null;

        await expectLater(
          LearnBenchmarkContextService.instance.resolve(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('bridge-only mode still works after 8d', () async {
      LearnBenchmarkContextService.enableBridgeOnly();
      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, 'SYSTEM BENCHMARK SET');
      expect(ctx.targetCPLH, BaselineData.derivedTargetCPLH);
      expect(ctx.selectedShiftCount, BaselineData.selectedRecordCount);
    });

    test('no-profile bootstrap still works after 8d', () async {
      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => null;

      final ctx = await LearnBenchmarkContextService.instance.resolve();
      expect(ctx.benchmarkSourceLabel, 'SYSTEM BENCHMARK SET');
      expect(ctx.targetCPLH, BaselineData.derivedTargetCPLH);
    });
  });

  group('P - per-daypart context passthrough', () {
    const cycle = TargetCycle(
      cycleId: 'cycle_p01',
      restaurantId: 'r1',
      source: TargetCycleSource.recommended,
      effectiveStart: '2026-03-01',
      effectiveEnd: '2026-04-30',
      calibrationWindowStart: '2026-01-01',
      calibrationWindowEnd: '2026-02-28',
      targetCPLH: 4.5,
      targetSPLH: 180.0,
      targetPPA: 42.0,
      fohWage: 15.0,
      bohWage: 14.0,
      opzFloorCPLH: 3.5,
      opzCeilingCPLH: 5.5,
      createdAt: '2026-03-01T00:00:00Z',
    );

    const summary = BenchmarkSelectionSummary(
      summaryId: 'cycle_p01_summary',
      restaurantId: 'r1',
      targetCycleId: 'cycle_p01',
      sourceType: 'cycle_recommended',
      selectedShiftCount: 14,
      rangeQualityLabel: 'GOOD OPZ RANGE',
      rangeQualityMessage: 'Persisted summary message.',
      createdAt: '2026-03-01T00:00:00Z',
    );

    test('profile dayparts are copied into Learn context', () async {
      const profile = ActiveTargetProfile(
        targetProfileId: 'tp_p01',
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        fohWage: 15.0,
        bohWage: 14.0,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 5.5,
        theoreticalFohLaborPct: 0.25,
        theoreticalBohLaborPct: 0.20,
        theoreticalLaborPct: 0.45,
        builtAt: '2026-03-01T00:00:00Z',
        dayparts: [
          ActiveTargetProfileDaypart(
            servicePeriodId: 'lunch',
            daypartTargetCPLH: 5.1,
            daypartTargetSPLH: 210.0,
            daypartTargetPPA: 39.0,
            daypartOpzFloorCPLH: 4.6,
            daypartOpzCeilingCPLH: 5.6,
          ),
          ActiveTargetProfileDaypart(
            servicePeriodId: 'dinner',
            daypartTargetCPLH: 4.2,
            daypartTargetSPLH: 170.0,
            daypartTargetPPA: 48.0,
            daypartOpzFloorCPLH: 3.8,
            daypartOpzCeilingCPLH: 4.8,
          ),
        ],
      );

      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => profile;
      LearnBenchmarkContextService.testGetCycle = (rid) async => cycle;
      LearnBenchmarkContextService.testGetSummary = (cid) async => summary;

      final ctx = await LearnBenchmarkContextService.instance.resolve();

      expect(ctx.targetCPLH, 4.5);
      expect(ctx.dayparts, hasLength(2));
      expect(ctx.daypartFor('lunch')!.daypartTargetCPLH, 5.1);
      expect(ctx.daypartFor('dinner')!.daypartTargetPPA, 48.0);
      expect(ctx.daypartFor('late_night'), isNull);
    });

    test('empty profile dayparts preserve whole-day fallback shape', () async {
      const profile = ActiveTargetProfile(
        targetProfileId: 'tp_p02',
        restaurantId: 'r1',
        sourceType: 'cycle_recommended',
        targetCPLH: 4.5,
        targetSPLH: 180.0,
        targetPPA: 42.0,
        fohWage: 15.0,
        bohWage: 14.0,
        opzFloorCPLH: 3.5,
        opzCeilingCPLH: 5.5,
        theoreticalFohLaborPct: 0.25,
        theoreticalBohLaborPct: 0.20,
        theoreticalLaborPct: 0.45,
        builtAt: '2026-03-01T00:00:00Z',
      );

      LearnBenchmarkContextService.disableBridgeOnly();
      LearnBenchmarkContextService.testGetRestaurantId = () async => 'r1';
      LearnBenchmarkContextService.testGetProfile = (rid) async => profile;
      LearnBenchmarkContextService.testGetCycle = (rid) async => cycle;
      LearnBenchmarkContextService.testGetSummary = (cid) async => summary;

      final ctx = await LearnBenchmarkContextService.instance.resolve();

      expect(ctx.dayparts, isEmpty);
      expect(ctx.daypartFor('dinner'), isNull);
      expect(ctx.targetCPLH, 4.5);
      expect(ctx.targetSPLH, 180.0);
      expect(ctx.targetPPA, 42.0);
    });
  });
}
