// ─── WeekDataNotifier — shared WTD state ──────────────────────────────────────
// Single in-memory owner of the current week's WeekData.
// Loaded once at app start via ShiftDataSource; notifies listeners on change.
//
// Consumed by VarianceBanner (sticky header on ShiftDashboard) and
// _ThisWeekTab (VarianceReport) — both see the same object with no re-fetching.
//
// Phase 10a.0 — `subscribeRealtime(Stream<RealtimeEvent>)` plugs the
// notifier into the realtime push channel. When a frame arrives with
// topic `rollup.invalidate.variance_week`, the notifier refreshes its
// week data so the UI reflects the new state without the user having
// to pull-to-refresh. Other topics are ignored.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/week_data.dart';
import '../services/realtime/realtime_event.dart';
import '../services/shift_data_source.dart';

/// Topic the variance week projection invalidates on. Matches the
/// `rollup.invalidate.*` namespace in
/// `docs/contracts/event_outbox_contract.md`.
const String varianceWeekInvalidateTopic = 'rollup.invalidate.variance_week';

class WeekDataNotifier extends ChangeNotifier {
  final ShiftDataSource _source;

  WeekData? _weekData;
  bool _isLoading = true;
  StreamSubscription<RealtimeEvent>? _realtimeSubscription;
  bool _disposed = false;

  WeekDataNotifier(this._source) {
    _load();
  }

  WeekData? get weekData  => _weekData;
  bool       get isLoading => _isLoading;

  Future<void> refresh() async {
    if (_disposed) return;
    _isLoading = true;
    notifyListeners();
    _weekData = await _source.getWeekToDate();
    if (_disposed) return;
    _isLoading = false;
    notifyListeners();
  }

  /// Phase 10a.0 — wire the notifier to a realtime event stream. When
  /// a frame on the `rollup.invalidate.variance_week` topic arrives,
  /// the notifier calls [refresh]. Idempotent: a second call cancels
  /// the previous subscription so callers can re-bind on tenant
  /// context change without leaking.
  void subscribeRealtime(Stream<RealtimeEvent> events) {
    _realtimeSubscription?.cancel();
    _realtimeSubscription = events.listen((event) {
      if (event.topic == varianceWeekInvalidateTopic) {
        unawaited(refresh());
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _realtimeSubscription?.cancel();
    _realtimeSubscription = null;
    super.dispose();
  }

  Future<void> _load() async {
    _weekData = await _source.getWeekToDate();
    if (_disposed) return;
    _isLoading = false;
    notifyListeners();
  }
}