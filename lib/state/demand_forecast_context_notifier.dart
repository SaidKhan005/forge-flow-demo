import 'package:flutter/foundation.dart';
import '../domain/models/demand_forecast_context.dart';
import '../services/demand_forecast_context_service.dart';

/// App-wide notifier for the canonical [DemandForecastContext].
///
/// Loads on creation and exposes the current v2 context. Schedule, Shift, and
/// Audit consumers read [context] instead of `BaselineData.historicalWeeklyAvgCovers`.
class DemandForecastContextNotifier extends ChangeNotifier {
  DemandForecastContext _context = DemandForecastContext.unavailable;
  bool _disposed = false;

  DemandForecastContext get context => _context;

  /// The resolved rolling weekly forecast covers from the v2 context,
  /// or null if unavailable.
  int? get resolvedWeeklyForecastCovers =>
      _context.resolvedWeeklyForecastCovers;

  /// Transitional compatibility getter — returns [resolvedWeeklyForecastCovers].
  int? get historicalWeeklyAvgCovers => _context.historicalWeeklyAvgCovers;

  DemandForecastContextNotifier() {
    load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Loads or reloads the demand context from the repository.
  Future<void> load() async {
    _context =
        await DemandForecastContextService.instance.getCurrentContext();
    if (_disposed) return;
    notifyListeners();
  }
}