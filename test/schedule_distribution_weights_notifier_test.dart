// Phase 7.55e.4 — ScheduleDistributionWeightsNotifier unit tests.
//
// Validates runtime loading of distribution weights from closed ShiftRecords
// through injected fake repositories.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_scope_repository.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/domain/repositories/week_record_repository.dart';
import 'package:forge_and_flow/domain/services/distribution_weight_builder.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_record.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────────

class FakeRestaurantScopeRepository implements RestaurantScopeRepository {
  @override
  Future<String> getActiveRestaurantId() async => 'test_restaurant';

  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async =>
      RestaurantLocation(
        restaurantId: 'test_restaurant',
        displayName: 'Test',
        businessTimezone: 'America/Chicago',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
}

class FakeWeekRecordRepository implements WeekRecordRepository {
  final List<WeekRecord> _weeks;
  FakeWeekRecordRepository(this._weeks);

  @override
  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async => _weeks;

  @override
  Future<int> upsertWeekRecord(WeekRecord record) async => 1;
}

class FakeShiftRecordRepository implements ShiftRecordRepository {
  final List<ShiftRecord> _shifts;
  FakeShiftRecordRepository(this._shifts);

  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
          String restaurantId, String weekId) async =>
      _shifts.where((s) => s.weekId == weekId).toList();

  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
          String restaurantId, List<String> weekIds) async =>
      _shifts
          .where((s) => s.isClosed && weekIds.contains(s.weekId))
          .toList();

  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
          String restaurantId, String startDate, String endDate) async =>
      _shifts
          .where((s) =>
              s.isClosed &&
              s.businessDate != null &&
              s.businessDate!.compareTo(startDate) >= 0 &&
              s.businessDate!.compareTo(endDate) <= 0)
          .toList();

  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async {
    String? latest;
    for (final s in _shifts) {
      if (s.isClosed && s.businessDate != null) {
        if (latest == null || s.businessDate!.compareTo(latest) > 0) {
          latest = s.businessDate;
        }
      }
    }
    return latest;
  }

  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 1;
}

class ThrowingShiftRecordRepository implements ShiftRecordRepository {
  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
          String restaurantId, String weekId) async =>
      throw Exception('DB error');

  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
          String restaurantId, List<String> weekIds) async =>
      throw Exception('DB error');

  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
          String restaurantId, String startDate, String endDate) async =>
      throw Exception('DB error');

  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      throw Exception('DB error');

  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async =>
      throw Exception('DB error');
}

// ── Helpers ────────────────────────────────────────────────────────────────────

WeekRecord _weekRecord(String weekId) => WeekRecord(
      restaurantId: 'test_restaurant',
      weekId: weekId,
      weekLabel: weekId,
      totalCovers: 700,
      forecastCovers: 700,
      totalFohHours: 140,
      totalBohHours: 70,
      avgPPA: 40.0,
      avgCPLH: 5.0,
      theoreticalLaborPct: 25.0,
      actualLaborPct: 26.0,
      dollarGap: 200.0,
      primaryLeverId: 'none',
      shiftsCompleted: 14,
      blendedFohWage: 15.0,
      blendedBohWage: 18.0,
    );

ShiftRecord _shift({
  required String weekId,
  required String dayLabel,
  required String daypart,
  int covers = 100,
}) =>
    ShiftRecord(
      weekId: weekId,
      dayLabel: dayLabel,
      daypart: daypart,
      status: 'closed',
      covers: covers,
      forecastCovers: covers,
      fohHours: 20,
      bohHours: 10,
      ppa: 40.0,
      cplh: 5.0,
      splh: 180.0,
      primaryLever: 'none',
    );

/// Generate [weekCount] weeks of closed shifts across all 7 days with
/// lunch+dinner dayparts.
List<ShiftRecord> _generateShifts({int weekCount = 3}) {
  final shifts = <ShiftRecord>[];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  for (var w = 1; w <= weekCount; w++) {
    final weekId = '2026-W${w.toString().padLeft(2, '0')}';
    for (final day in days) {
      shifts.add(_shift(weekId: weekId, dayLabel: day, daypart: 'lunch'));
      shifts.add(_shift(weekId: weekId, dayLabel: day, daypart: 'dinner'));
    }
  }
  return shifts;
}

List<WeekRecord> _generateWeeks(int count) =>
    List.generate(count, (i) => _weekRecord('2026-W${(i + 1).toString().padLeft(2, '0')}'));

ScheduleDistributionWeightsNotifier _buildNotifier({
  List<WeekRecord>? weeks,
  List<ShiftRecord>? shifts,
  ShiftRecordRepository? shiftRepo,
}) {
  return ScheduleDistributionWeightsNotifier(
    scopeRepo: FakeRestaurantScopeRepository(),
    weekRepo: FakeWeekRecordRepository(weeks ?? []),
    shiftRepo: shiftRepo ?? FakeShiftRecordRepository(shifts ?? []),
  );
}

void main() {
  // ── A. Notifier loading ──────────────────────────────────────────────────

  group('A — notifier loads weights from recent weekIds', () {
    test('loads available weights from 3 weeks of closed shifts', () async {
      final weeks = _generateWeeks(3);
      final shifts = _generateShifts(weekCount: 3);
      final notifier = _buildNotifier(weeks: weeks, shifts: shifts);

      await notifier.load();

      expect(notifier.hasLoaded, isTrue);
      expect(notifier.isLoading, isFalse);
      expect(notifier.weights, isNotNull);
      expect(notifier.weights!.isAvailable, isTrue);
      // 3 weeks × 7 days = 21 business days (>= 14 threshold)
      expect(notifier.weights!.closedBusinessDayCount, 21);
    });

    test('takes at most 8 recent weekIds', () async {
      // 10 weeks available but only 8 should be used
      final weeks = _generateWeeks(10);
      final shifts = _generateShifts(weekCount: 10);
      final notifier = _buildNotifier(weeks: weeks, shifts: shifts);

      await notifier.load();

      expect(notifier.weights, isNotNull);
      expect(notifier.weights!.isAvailable, isTrue);
      // 8 weeks × 7 days = 56 business days
      expect(notifier.weights!.closedBusinessDayCount, 56);
    });

    test('returns unavailable when week history is empty', () async {
      final notifier = _buildNotifier(weeks: [], shifts: []);

      await notifier.load();

      expect(notifier.hasLoaded, isTrue);
      expect(notifier.weights, isNull);
    });

    test('returns unavailable when insufficient closed business days', () async {
      // 1 week = 7 business days, below 14 threshold
      final weeks = _generateWeeks(1);
      final shifts = _generateShifts(weekCount: 1);
      final notifier = _buildNotifier(weeks: weeks, shifts: shifts);

      await notifier.load();

      expect(notifier.hasLoaded, isTrue);
      expect(notifier.weights, isNotNull);
      expect(notifier.weights!.isAvailable, isFalse);
    });

    test('returns null weights instead of throwing when repo fails', () async {
      final weeks = _generateWeeks(3);
      final notifier = _buildNotifier(
        weeks: weeks,
        shiftRepo: ThrowingShiftRecordRepository(),
      );

      await notifier.load();

      expect(notifier.hasLoaded, isTrue);
      expect(notifier.isLoading, isFalse);
      expect(notifier.weights, isNull);
      // No exception escaped
    });
  });

  // ── B. ScheduleForecastNotifier.updateDistributionWeights ────────────────

  group('B — updateDistributionWeights', () {
    ScheduleForecastNotifier makeNotifier({
      ScheduleDistributionWeights? distributionWeights,
      int initialCovers = 1200,
    }) {
      return ScheduleForecastNotifier(
        targetCPLH: 5.0,
        targetPPA: 40.0,
        targetSPLH: 180.0,
        fohWage: 15.0,
        bohWage: 18.0,
        historicalWeeklyAvgCovers: initialCovers,
        distributionWeights: distributionWeights,
      );
    }

    ScheduleDistributionWeights availableWeights() {
      // Build weights with uneven day distribution
      final shifts = <ShiftRecord>[];
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      final coversByDay = {
        'Mon': 80, 'Tue': 90, 'Wed': 100, 'Thu': 120,
        'Fri': 160, 'Sat': 180, 'Sun': 70,
      };
      for (var w = 1; w <= 3; w++) {
        final weekId = '2026-W${w.toString().padLeft(2, '0')}';
        for (final day in days) {
          shifts.add(_shift(
            weekId: weekId, dayLabel: day, daypart: 'lunch',
            covers: (coversByDay[day]! * 0.4).round(),
          ));
          shifts.add(_shift(
            weekId: weekId, dayLabel: day, daypart: 'dinner',
            covers: (coversByDay[day]! * 0.6).round(),
          ));
        }
      }
      return DistributionWeightBuilder.fromClosedShifts(shifts);
    }

    test('rebuilds day/daypart rows without changing weekly covers', () {
      final notifier = makeNotifier();
      final coversBefore = notifier.weeklyCovers;
      final dayViewsBefore = notifier.adjustedDayViews;
      expect(coversBefore, 1200);

      final weights = availableWeights();
      notifier.updateDistributionWeights(weights);

      // Weekly covers unchanged
      expect(notifier.weeklyCovers, coversBefore);
      // Day views still exist
      expect(notifier.adjustedDayViews.length, 7);
      // Sum of day covers still equals weekly
      final daySum = notifier.adjustedDayViews
          .fold<int>(0, (s, d) => s + d.forecastCovers);
      expect(daySum, coversBefore);

      // Day distribution changed (weights are uneven)
      final newFriCovers = notifier.adjustedDayViews
          .firstWhere((d) => d.day == 'Fri').forecastCovers;
      final oldFriCovers = dayViewsBefore
          .firstWhere((d) => d.day == 'Fri').forecastCovers;
      // With uneven weights, Friday should differ from default allocation
      expect(newFriCovers, isNot(equals(oldFriCovers)));
    });

    test('preserves covers and provenance when weights arrive', () {
      final notifier = makeNotifier(initialCovers: 1500);
      expect(notifier.weeklyCovers, 1500);
      final sourceBefore = notifier.coversSource;

      final weights = availableWeights();
      notifier.updateDistributionWeights(weights);

      // Covers and provenance preserved
      expect(notifier.weeklyCovers, 1500);
      expect(notifier.coversSource, sourceBefore);
      // Day sum still matches
      final daySum = notifier.adjustedDayViews
          .fold<int>(0, (s, d) => s + d.forecastCovers);
      expect(daySum, 1500);
    });

    test('target updates still work after distribution weights are set', () {
      final weights = availableWeights();
      final notifier = makeNotifier(distributionWeights: weights);
      final coversBefore = notifier.weeklyCovers;

      // Update targets — should rebuild plan with same covers and weights
      notifier.updateTargets(ActiveTargetProfile(
        targetProfileId: 'tp_test',
        restaurantId: 'test',
        sourceType: 'system_baseline',
        targetCPLH: 6.0,
        targetPPA: 42.0,
        targetSPLH: 200.0,
        fohWage: 16.0,
        bohWage: 19.0,
        opzFloorCPLH: 4.0,
        opzCeilingCPLH: 8.0,
        theoreticalLaborPct: 24.0,
        theoreticalFohLaborPct: 12.0,
        theoreticalBohLaborPct: 12.0,
        builtAt: '2026-01-01T00:00:00Z',
      ));

      // Covers unchanged, but hours recalculated with new targets
      expect(notifier.weeklyCovers, coversBefore);
      expect(notifier.adjustedDayViews.length, 7);
    });
  });
}
