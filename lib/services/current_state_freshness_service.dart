/// Shared freshness evaluation for current-state surfaces.
///
/// Pure evaluation function: takes a source timestamp and wall clock,
/// returns a resolved [CurrentStateFreshness]. No database access, no
/// state, no singleton.
///
/// Threshold constants are defined here as the single source for freshness
/// windows. Later surfaces (Variance) can call [evaluate] with wider
/// windows without changing this class.
///
/// The [refreshing] state is never returned by [evaluate] -- it is set by
/// the notifier before calling the async load, then replaced by the
/// evaluation result after the load completes.
library;

import '../models/current_state_freshness.dart';

class CurrentStateFreshnessService {
  const CurrentStateFreshnessService();

  /// Shift live window: data updated within this many minutes is treated
  /// as [FreshnessState.live].
  static const shiftLiveWindowMinutes = 5;

  /// Shift stale threshold: data older than this many minutes is treated
  /// as [FreshnessState.stale]. Between [shiftLiveWindowMinutes] and this
  /// value is [FreshnessState.updated].
  static const shiftStaleThresholdMinutes = 120;

  /// Evaluates freshness from a persisted source timestamp.
  ///
  /// [updatedAt] is the most recent data timestamp from the source surface
  /// (e.g. `OpenShiftSnapshot.updatedAt`). Null yields [FreshnessState.stale].
  ///
  /// [now] is the current time, injectable for deterministic testing.
  /// In production, pass `DateTime.now().toUtc()` since persisted timestamps
  /// are UTC (normalized by 7.55n.6).
  ///
  /// [liveWindowMinutes] and [staleThresholdMinutes] define the state
  /// boundaries. Defaults are Shift thresholds. Future surfaces can pass
  /// wider windows.
  CurrentStateFreshness evaluate({
    required DateTime? updatedAt,
    required DateTime now,
    int liveWindowMinutes = shiftLiveWindowMinutes,
    int staleThresholdMinutes = shiftStaleThresholdMinutes,
  }) {
    if (updatedAt == null) {
      return CurrentStateFreshness(
        state: FreshnessState.stale,
        evaluatedAt: now,
      );
    }

    final age = now.difference(updatedAt);

    if (age.inMinutes < liveWindowMinutes) {
      return CurrentStateFreshness(
        state: FreshnessState.live,
        updatedAt: updatedAt,
        evaluatedAt: now,
      );
    }

    if (age.inMinutes < staleThresholdMinutes) {
      return CurrentStateFreshness(
        state: FreshnessState.updated,
        updatedAt: updatedAt,
        evaluatedAt: now,
      );
    }

    return CurrentStateFreshness(
      state: FreshnessState.stale,
      updatedAt: updatedAt,
      evaluatedAt: now,
    );
  }
}
