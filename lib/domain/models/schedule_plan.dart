/// Immutable weekly planning contract combining demand forecast and target profile.
///
/// SchedulePlan is the single authority for Schedule planning math.
/// It combines two sibling outputs of the 60-day baseline process:
///   1. Demand Forecast Context (forecast covers from POS 60-day history)
///   2. Active Target Profile (CPLH, SPLH, PPA, wages, OPZ, theoretical standards)
///
/// Architecture:
///   forecast covers = 60-day total covers / (60 / 7)
///   forecast sales = forecast covers * target PPA
///   required FOH hours = forecast covers / target CPLH
///   required BOH hours = forecast sales / target SPLH
///   FOH labor dollars = required FOH hours * FOH wage
///   BOH labor dollars = required BOH hours * BOH wage
///   total labor dollars = FOH + BOH labor dollars
///   theoretical labor % = total labor dollars / forecast sales * 100
///   target blended wage = total labor dollars / total required hours
library;

import '../models/schedule_forecast_demand.dart';

/// Immutable day-level planning values within a weekly [SchedulePlan].
class ScheduleDayPlan {
  final String day;
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;

  const ScheduleDayPlan({
    required this.day,
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
  });
}

/// Weekly-level planning values.
class SchedulePlan {
  final int forecastCovers;
  final double forecastSales;
  final int requiredFohHours;
  final int requiredBohHours;
  final double theoreticalFohLaborDollars;
  final double theoreticalBohLaborDollars;
  final double theoreticalLaborPct;
  final double targetBlendedWage;
  final ForecastDemandSource coversSource;
  final ForecastDemandSource salesSource;
  final List<ScheduleDayPlan> dayPlans;

  double get theoreticalTotalLaborDollars =>
      theoreticalFohLaborDollars + theoreticalBohLaborDollars;

  int get totalRequiredHours => requiredFohHours + requiredBohHours;

  SchedulePlan({
    required this.forecastCovers,
    required this.forecastSales,
    required this.requiredFohHours,
    required this.requiredBohHours,
    required this.theoreticalFohLaborDollars,
    required this.theoreticalBohLaborDollars,
    required this.theoreticalLaborPct,
    required this.targetBlendedWage,
    required this.coversSource,
    required this.salesSource,
    List<ScheduleDayPlan> dayPlans = const [],
  }) : dayPlans = List.unmodifiable(dayPlans);

  /// Human-readable label for the forecast covers source.
  String get coversSourceLabel {
    switch (coversSource) {
      case ForecastDemandSource.appDerivedFromHistoricalAverage:
        return '60-day weekly average';
      case ForecastDemandSource.appDerivedFromCoversAndPpa:
        return 'Derived from covers';
      case ForecastDemandSource.appDerivedFromReservationAndWalkInModel:
        return 'Reservation + walk-in model';
      case ForecastDemandSource.demoFallback:
        return 'Demo fallback';
      case ForecastDemandSource.unavailable:
        return 'Unavailable';
    }
  }
}
