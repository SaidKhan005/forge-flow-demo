import 'package:flutter/foundation.dart';
import '../domain/models/demand_forecast_context.dart';
import 'demand_forecast_context_service.dart';

/// App-wide notifier for the canonical [DemandForecastContext].
///
/// Loads on creation and exposes the current context. Schedule, Shift, and
/// Audit consumers read [context] instead of `BaselineData.historicalWeeklyAvgCovers`.
class DemandForecastContextNotifier extends ChangeNotifier {
  DemandForecastContext _context = DemandForecastContext.unavailable;

  DemandForecastContext get context => _context;

  /// The weekly average covers from the canonical context, or null if unavailable.
  int? get historicalWeeklyAvgCovers => _context.historicalWeeklyAvgCovers;

  DemandForecastContextNotifier() {
    load();
  }

  /// Loads or reloads the demand context from the repository.
  Future<void> load() async {
    _context =
        await DemandForecastContextService.instance.getCurrentContext();
    notifyListeners();
  }
}
