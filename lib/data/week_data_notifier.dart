// ─── WeekDataNotifier — shared WTD state ──────────────────────────────────────
// Single in-memory owner of the current week's WeekData.
// Loaded once at app start via ShiftDataSource; notifies listeners on change.
//
// Consumed by VarianceBanner (sticky header on ShiftDashboard) and
// _ThisWeekTab (VarianceReport) — both see the same object with no re-fetching.

import 'package:flutter/foundation.dart';
import '../models/week_data.dart';
import 'shift_data_source.dart';

class WeekDataNotifier extends ChangeNotifier {
  final ShiftDataSource _source;

  WeekData? _weekData;
  bool _isLoading = true;

  WeekDataNotifier(this._source) {
    _load();
  }

  WeekData? get weekData  => _weekData;
  bool       get isLoading => _isLoading;

  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();
    _weekData = await _source.getWeekToDate();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> _load() async {
    _weekData = await _source.getWeekToDate();
    _isLoading = false;
    notifyListeners();
  }
}
