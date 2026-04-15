import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/shift_record.dart';

void main() {
  group('ShiftRecord source-backed labor truth', () {
    test('total labor dollars prefer stored total pct before config fallback',
        () {
      const record = ShiftRecord(
        weekId: '2026-W15',
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'closed',
        covers: 100,
        forecastCovers: 100,
        ppa: 40,
        cplh: 5,
        splh: 200,
        fohHours: 10,
        bohHours: 12,
        primaryLever: 'ON_MODEL',
        storedTotalLaborPct: 25.0,
      );

      expect(record.actualSales, equals(4000));
      expect(record.totalLaborDollar, closeTo(1000.0, 0.001));
      expect(record.totalLaborPct, closeTo(25.0, 0.001));
    });

    test('component labor dollars prefer stored component pct before config fallback',
        () {
      const record = ShiftRecord(
        weekId: '2026-W15',
        dayLabel: 'Mon',
        daypart: 'dinner',
        status: 'closed',
        covers: 80,
        forecastCovers: 80,
        ppa: 50,
        cplh: 4,
        splh: 180,
        fohHours: 9,
        bohHours: 11,
        primaryLever: 'ON_MODEL',
        storedFohLaborPct: 8.0,
        storedBohLaborPct: 10.0,
      );

      expect(record.actualSales, equals(4000));
      expect(record.fohLaborDollar, closeTo(320.0, 0.001));
      expect(record.bohLaborDollar, closeTo(400.0, 0.001));
      expect(record.totalLaborDollar, closeTo(720.0, 0.001));
      expect(record.totalLaborPct, closeTo(18.0, 0.001));
    });

    test('missing source-backed labor facts degrade honestly to 0', () {
      const record = ShiftRecord(
        weekId: '2026-W15',
        dayLabel: 'Tue',
        daypart: 'lunch',
        status: 'closed',
        covers: 90,
        forecastCovers: 90,
        ppa: 40,
        cplh: 5,
        splh: 180,
        fohHours: 8,
        bohHours: 10,
        primaryLever: 'ON_MODEL',
      );

      expect(record.fohLaborDollar, equals(0));
      expect(record.bohLaborDollar, equals(0));
      expect(record.totalLaborDollar, equals(0));
      expect(record.totalLaborPct, equals(0));
      expect(record.blendedWage, equals(0));
    });
  });
}
