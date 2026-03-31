// Phase 5 â€” BaselineManagerService unit tests.
//
// Uses the real SQLite database (sqflite_common_ffi on desktop).
// reseedDemo() is called before each test for a clean, reproducible state.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/database_helper.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    await DatabaseHelper.instance.reseedDemo();
  });

  // â”€â”€ A: getCandidateShifts returns closed shifts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” getCandidateShifts', () {
    test('returns only closed shifts from all seeded weeks', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);
      // All record keys follow the '${weekId}|${dayLabel}|${daypart}' format
      for (final c in candidates) {
        expect(c.recordKey, contains('|'));
        expect(c.weekId, isNotEmpty);
        expect(c.dayLabel, isNotEmpty);
        expect(c.daypart, isNotEmpty);
      }
    });

    test('candidates are sorted: daypart order, then cplh DESC', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      const daypartOrder = <String, int>{
        'lunch': 0,
        'dinner': 1,
        'late_night': 2,
      };

      for (int i = 0; i < candidates.length - 1; i++) {
        final a = candidates[i];
        final b = candidates[i + 1];
        final dpA = daypartOrder[a.daypart] ?? 99;
        final dpB = daypartOrder[b.daypart] ?? 99;
        // Daypart order must be non-decreasing
        expect(dpA, lessThanOrEqualTo(dpB),
            reason:
                'Expected ${a.daypart} â‰¤ ${b.daypart} at index $i');
        if (dpA == dpB) {
          // Within same daypart: CPLH must be non-increasing
          expect(a.cplh, greaterThanOrEqualTo(b.cplh),
              reason:
                  'Expected CPLH ${a.cplh} â‰¥ ${b.cplh} at index $i within ${a.daypart}');
        }
      }
    });

    test('isSelected reflects persisted baseline_selected_records', () async {
      // Seed: pick a known closed shift key and persist it
      final allCandidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(allCandidates, isNotEmpty);
      final first = allCandidates.first;

      await DatabaseHelper.instance
          .replaceBaselineSelectedRecordKeys({first.recordKey});

      // Re-fetch â€” isSelected should now be true for that key only
      final refreshed =
          await BaselineManagerService.instance.getCandidateShifts();
      final found = refreshed.firstWhere((c) => c.recordKey == first.recordKey);
      expect(found.isSelected, isTrue);

      // All others are false
      final others =
          refreshed.where((c) => c.recordKey != first.recordKey).toList();
      for (final c in others) {
        expect(c.isSelected, isFalse,
            reason: '${c.recordKey} should not be selected');
      }
    });
  });

  // â”€â”€ B: saveSelection persists and applies override â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” saveSelection', () {
    test('persists selected keys to DB and applies override', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates.length, greaterThanOrEqualTo(2));

      final selectedKeys = {candidates[0].recordKey, candidates[1].recordKey};
      await BaselineManagerService.instance.saveSelection(selectedKeys);

      // DB reflects new selection
      final stored =
          await DatabaseHelper.instance.getBaselineSelectedRecordKeys();
      expect(stored, equals(selectedKeys));

      // BaselineData has a runtime override
      expect(BaselineData.hasManagerOverride, isTrue);
    });

    test('clearing selection calls clearManagerOverride', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      // First set something
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});
      expect(BaselineData.hasManagerOverride, isTrue);

      // Now save an empty set
      await BaselineManagerService.instance.saveSelection({});
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });

  // â”€â”€ C: primeManagerOverride restores override from DB â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('C â€” primeManagerOverride', () {
    test('applies override when selected keys exist in DB', () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      // Persist a selection directly
      await DatabaseHelper.instance
          .replaceBaselineSelectedRecordKeys({candidates[0].recordKey});

      // Clear in-memory state, then prime
      BaselineData.clearManagerOverride();
      expect(BaselineData.hasManagerOverride, isFalse);

      await BaselineManagerService.instance.primeManagerOverride();
      expect(BaselineData.hasManagerOverride, isTrue);
    });

    test('calls clearManagerOverride when no keys are selected', () async {
      // Ensure DB has no selections
      await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});

      // Apply an override first
      BaselineData.applyManagerOverride([
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.5, splh: 180.0, ppa: 42.0, covers: 180)
      ]);
      expect(BaselineData.hasManagerOverride, isTrue);

      await BaselineManagerService.instance.primeManagerOverride();
      expect(BaselineData.hasManagerOverride, isFalse);
    });
  });

  // â”€â”€ D: derived target reflects selected candidates â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('D â€” derived target after saveSelection', () {
    test('BaselineData.derivedTargetCPLH is avg CPLH of selected candidates',
        () async {
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      // Pick 3 candidates with known CPLH values
      final pick = candidates.take(3).toList();
      final expectedCplh =
          pick.fold(0.0, (s, c) => s + c.cplh) / pick.length;

      await BaselineManagerService.instance
          .saveSelection(pick.map((c) => c.recordKey).toSet());

      expect(BaselineData.derivedTargetCPLH, closeTo(expectedCplh, 0.001));
    });
  });

  // â”€â”€ E: revision increments on save â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('E â€” revision notifier', () {
    test('revision increments after saveSelection', () async {
      final before = BaselineData.revision.value;
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);

      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      expect(BaselineData.revision.value, greaterThan(before));
    });
  });

  // â”€â”€ F: late-night records participate in override logic â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('F â€” late-night override support', () {
    test('applyManagerOverride accepts late_night DaypartBaseline records',
        () {
      // Prove the override path handles late_night daypart without filtering
      final mixed = [
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.5, splh: 180, ppa: 42, covers: 170,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'dinner', cplh: 4.3, splh: 177, ppa: 43, covers: 228,
            isSelected: true),
        const DaypartBaseline(
            daypart: 'late_night', cplh: 4.8, splh: 181, ppa: 37, covers: 90,
            isSelected: true),
      ];

      BaselineData.applyManagerOverride(mixed);

      expect(BaselineData.hasManagerOverride, isTrue);
      expect(BaselineData.selectedRecordCount, equals(3));
      expect(
        BaselineData.records.any((r) => r.daypart == 'late_night'),
        isTrue,
        reason: 'late_night records must not be filtered out by override',
      );

      // Derived target includes late_night CPLH
      final expectedCplh = (4.5 + 4.3 + 4.8) / 3;
      expect(BaselineData.derivedTargetCPLH, closeTo(expectedCplh, 0.001));

      BaselineData.clearManagerOverride();
    });

    test('applyHistoricalContext accepts late_night records', () {
      final context = [
        const DaypartBaseline(
            daypart: 'lunch', cplh: 4.0, splh: 174, ppa: 40, covers: 155),
        const DaypartBaseline(
            daypart: 'late_night', cplh: 3.6, splh: 171, ppa: 34, covers: 71),
      ];

      BaselineData.applyHistoricalContext(context);

      expect(
        BaselineData.historicalContextRecords.any((r) => r.daypart == 'late_night'),
        isTrue,
        reason: 'late_night records must participate in historical context',
      );
      expect(BaselineData.historicalTotalCoversTracked, equals(155 + 71));

      BaselineData.clearHistoricalContext();
    });
  });
}
