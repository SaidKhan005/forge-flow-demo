// Phase 7.55b — LaborModel BOH sales-first architecture tests.
//
// Verifies:
// - modelBohHoursFromSales is the primary BOH formula
// - modelBohHours delegates to modelBohHoursFromSales
// - Both produce identical results for the same inputs
// - Schedule notifier BOH requirement matches for demo targets

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/screens/schedule_builder.dart';

void main() {
  group('LaborModel BOH sales-first formula', () {
    test('modelBohHoursFromSales(50400, 180) == 280', () {
      expect(LaborModel.modelBohHoursFromSales(50400, 180), equals(280));
    });

    test('modelBohHours(1200, 42, 180) == 280', () {
      expect(LaborModel.modelBohHours(1200, 42, 180), equals(280));
    });

    test('modelBohHours delegates to modelBohHoursFromSales', () {
      // For any covers + ppa + targetSPLH, both must agree
      const covers = 1200;
      const ppa = 42.0;
      const targetSPLH = 180.0;
      final fromSales =
          LaborModel.modelBohHoursFromSales(covers * ppa, targetSPLH);
      final fromCovers = LaborModel.modelBohHours(covers, ppa, targetSPLH);
      expect(fromCovers, equals(fromSales));
    });

    test('modelBohHoursFromSales returns 0 when targetSPLH is 0', () {
      expect(LaborModel.modelBohHoursFromSales(50000, 0), equals(0));
    });

    test('modelBohHoursFromSales rounds to nearest hour', () {
      // 10000 / 180 = 55.555... → 56
      expect(LaborModel.modelBohHoursFromSales(10000, 180), equals(56));
    });
  });

  group('Schedule notifier BOH uses sales-first path', () {
    test('requiredBohHours matches modelBohHoursFromSales for default covers',
        () {
      const targetCPLH = 4.58;
      const targetPPA = 42.0;
      const targetSPLH = 180.0;
      const covers = 1200;

      final notifier = ScheduleForecastNotifier(
        targetCPLH: targetCPLH,
        targetPPA: targetPPA,
        targetSPLH: targetSPLH,
        fohWage: 16.50,
        bohWage: 21.35,
      );

      final expectedSales = covers * targetPPA;
      final expectedBoh =
          LaborModel.modelBohHoursFromSales(expectedSales, targetSPLH);
      expect(notifier.requiredBohHours, equals(expectedBoh));

      notifier.dispose();
    });

    test('forecastedSales equals weeklyCovers * targetPPA', () {
      const targetPPA = 42.0;
      const covers = 1200;

      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.58,
        targetPPA: targetPPA,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );

      expect(notifier.forecastedSales, equals(covers * targetPPA));

      notifier.dispose();
    });

    test('adjustedDayViews carry forecastSales per day', () {
      final notifier = ScheduleForecastNotifier(
        targetCPLH: 4.58,
        targetPPA: 42.0,
        targetSPLH: 180.0,
        fohWage: 16.50,
        bohWage: 21.35,
      );

      final views = notifier.adjustedDayViews;
      for (final day in views) {
        // Each day should have forecastSales = covers * PPA
        expect(day.forecastSales, closeTo(day.forecastCovers * 42.0, 0.01));
        // BOH hours should match sales-first calculation
        expect(day.requiredBohHours,
            equals(LaborModel.modelBohHoursFromSales(day.forecastSales, 180.0)));
      }

      notifier.dispose();
    });
  });
}
