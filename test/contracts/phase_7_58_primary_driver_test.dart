// Phase 7.58.0 — Primary Driver Contract Test
//
// Pins the rules from docs/contracts/phase_7_58_primary_driver_contract.md
// that the audit pass must keep true:
//
//   * Engine output discipline — `LaborModel.determineLever` never returns
//     'on_model' (R6); the empty-candidate path returns the neutral
//     'balanced' sentinel — NOT a phantom 'covers_down' (R10, revised
//     per the Metric Honesty Doctrine: no phantom drivers);
//     output is always lowercase snake_case (R15).
//   * Lever id catalogue alignment — every priority-order id has a matching
//     `LeverCardData` entry, and every `LeverCardData` entry corresponds to
//     a known engine id (R5).
//   * Storage form — `ShiftRecord.primaryLever` carries the upper-snake form
//     and `ShiftRecord.normalizedLeverId` returns the lowercase id used for
//     renderer lookup (R16, R17).
//   * Closed-row driver equality — for ≥10 fixture scenarios the displayed
//     `ProjectionDaypartRow.driverLabel` equals the engine-derived lever id
//     after the contract's case-and-underscore normalisation (R1 + R18 + R32).
//   * Open / projected row purity — non-closed rows surface
//     `'Not yet available'` even when their stored `primaryLever` carries a
//     real lever id (R30, locked in by 7.58.5).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/variance_week_projection_row.dart';
import 'package:forge_and_flow/services/labor_model.dart';
import 'package:forge_and_flow/services/variance_week_projection_read_service.dart';

// ── Fixture targets ─────────────────────────────────────────────────────────

const _tCPLH = 4.58;
const _tSPLH = 180.0;
const _tPPA = 41.50;
const _fohWage = 16.50;
const _bohWage = 21.35;

// ── Helpers ─────────────────────────────────────────────────────────────────

String _engineLever({
  int actualCovers = 1200,
  int forecastCovers = 1200,
  double? avgCPLH,
  double? avgPPA,
  double? avgSPLH,
  double? avgFohWage,
  double? avgBohWage,
}) {
  return LaborModel.determineLever(
    actualCovers: actualCovers,
    forecastCovers: forecastCovers,
    avgCPLH: avgCPLH ?? _tCPLH,
    avgPPA: avgPPA ?? _tPPA,
    targetCPLH: _tCPLH,
    targetPPA: _tPPA,
    avgSPLH: avgSPLH ?? _tSPLH,
    targetSPLH: _tSPLH,
    avgFohBlendedWage: avgFohWage ?? _fohWage,
    targetFohWage: _fohWage,
    avgBohBlendedWage: avgBohWage ?? _bohWage,
    targetBohWage: _bohWage,
  );
}

ShiftRecord _closedShift({
  String dayLabel = 'Mon',
  String daypart = 'lunch',
  required String engineLever,
}) {
  return ShiftRecord(
    weekId: '2026-W13',
    dayLabel: dayLabel,
    daypart: daypart,
    status: 'closed',
    covers: 120,
    forecastCovers: 130,
    ppa: _tPPA,
    cplh: _tCPLH,
    splh: _tSPLH,
    fohHours: 28,
    bohHours: 12,
    primaryLever: engineLever.toUpperCase(),
    businessDate: '2026-03-24',
    targetCPLH: _tCPLH,
    targetSPLH: _tSPLH,
    targetPPA: _tPPA,
    targetFohWage: _fohWage,
    targetBohWage: _bohWage,
    theoreticalFohLaborPct: 8.63,
    theoreticalBohLaborPct: 11.86,
  );
}

String _displayedLeverIdFromLabel(String driverLabel) =>
    driverLabel.toLowerCase().replaceAll(' ', '_');

// ── Tests ───────────────────────────────────────────────────────────────────

void main() {
  const service = VarianceWeekProjectionReadService();

  group('Engine output discipline (R6, R10, R15)', () {
    test('determineLever never returns on_model under any axis combination',
        () {
      final scenarios = <Map<String, dynamic>>[
        {'actualCovers': 1200, 'forecastCovers': 1200},
        {'actualCovers': 1140, 'forecastCovers': 1200},
        {'actualCovers': 1260, 'forecastCovers': 1200},
        {'avgPPA': _tPPA * 0.95},
        {'avgPPA': _tPPA * 1.08},
        {'avgCPLH': _tCPLH * 0.90},
        {'avgCPLH': _tCPLH * 1.10},
        {'avgSPLH': _tSPLH * 0.90},
        {'avgSPLH': _tSPLH * 1.10},
        {'avgFohWage': _fohWage * 1.10},
        {'avgFohWage': _fohWage * 0.90},
        {'avgBohWage': _bohWage * 1.10},
        {'avgBohWage': _bohWage * 0.90},
      ];
      for (final s in scenarios) {
        final lever = _engineLever(
          actualCovers: (s['actualCovers'] as int?) ?? 1200,
          forecastCovers: (s['forecastCovers'] as int?) ?? 1200,
          avgCPLH: s['avgCPLH'] as double?,
          avgPPA: s['avgPPA'] as double?,
          avgSPLH: s['avgSPLH'] as double?,
          avgFohWage: s['avgFohWage'] as double?,
          avgBohWage: s['avgBohWage'] as double?,
        );
        expect(lever, isNot(equals('on_model')),
            reason:
                'R6 — determineLever must never return on_model; input: $s');
      }
    });

    test('empty-candidate path returns the neutral balanced sentinel', () {
      final lever = _engineLever();
      expect(lever, equals(LaborModel.balancedLeverId),
          reason:
              'R10 (revised) — empty-candidate path returns the neutral '
              '`balanced` sentinel, NOT a phantom covers_down. The legacy '
              'covers_down fallback violated the Metric Honesty Doctrine '
              '(every washed-below-threshold period showed a phantom red '
              'COVERS driver).');
      expect(lever, isNot(equals('covers_down')),
          reason: 'No phantom COVERS driver on the no-deviation path.');
      // The sentinel must resolve to a non-null neutral card so renderers
      // never fall through to a real driver card.
      final card = LeverCards.lookup(lever);
      expect(card, isNotNull);
      expect(card!.isNeutral, isTrue);
    });

    test('output id is always lowercase snake_case', () {
      final ids = <String>[
        _engineLever(actualCovers: 1200, forecastCovers: 1200),
        _engineLever(actualCovers: 1140, forecastCovers: 1200),
        _engineLever(actualCovers: 1260, forecastCovers: 1200),
        _engineLever(avgPPA: _tPPA * 1.08),
        _engineLever(avgCPLH: _tCPLH * 1.10),
        _engineLever(avgSPLH: _tSPLH * 0.90),
        _engineLever(avgFohWage: _fohWage * 1.10),
        _engineLever(avgBohWage: _bohWage * 0.90),
      ];
      for (final id in ids) {
        expect(id, equals(id.toLowerCase()),
            reason: 'R15 — engine output must be lowercase');
        expect(id.contains(' '), isFalse,
            reason: 'R15 — engine output must use snake_case (no spaces)');
      }
    });
  });

  group('Lever id catalogue alignment (R5)', () {
    const engineIds = <String>{
      'covers_down', 'covers_up',
      'ppa_down', 'ppa_up',
      'cplh_down', 'cplh_up',
      'splh_down', 'splh_up',
      'foh_wage_down', 'foh_wage_up',
      'boh_wage_down', 'boh_wage_up',
      'foh_hours_over', 'foh_hours_under',
      'boh_hours_over', 'boh_hours_under',
    };

    test('LeverCards.all has 16 entries', () {
      expect(LeverCards.all.length, equals(16));
    });

    test('every engine lever id has a matching LeverCardData entry', () {
      final cardIds = LeverCards.all.map((c) => c.id).toSet();
      for (final id in engineIds) {
        expect(cardIds, contains(id),
            reason: 'R5 — engine id "$id" must have a matching LeverCardData');
      }
    });

    test('every LeverCards.all id is a known engine lever id', () {
      for (final card in LeverCards.all) {
        expect(engineIds, contains(card.id),
            reason:
                'R5 — LeverCards.all entry "${card.id}" must match an engine id');
      }
    });
  });

  group('Storage form discipline (R16, R17)', () {
    test('ShiftRecord.normalizedLeverId lowercases the upper-snake form', () {
      final shift = _closedShift(engineLever: 'covers_down');
      expect(shift.primaryLever, equals('COVERS_DOWN'),
          reason: 'R16 — storage layer persists upper-snake form');
      expect(shift.normalizedLeverId, equals('covers_down'),
          reason: 'R17 — normalizedLeverId returns lowercase for lookup');
    });

    test('on_model sentinel round-trips through normalizedLeverId', () {
      final shift = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Tue',
        daypart: 'lunch',
        status: 'open',
        covers: 0,
        forecastCovers: 110,
        ppa: 0,
        cplh: 0,
        splh: 0,
        fohHours: 0,
        bohHours: 0,
        primaryLever: 'ON_MODEL',
      );
      expect(shift.normalizedLeverId, equals('on_model'),
          reason:
              'R17 — sentinel placeholder normalises identically to engine ids');
    });
  });

  group('Closed-row driver equality (R1, R18, R32)', () {
    // The audit's primary assertion: for closed rows, the displayed
    // driver label MUST equal the engine-derived lever id, after the
    // contract's underscore-to-space and case folding.
    final scenarios = <Map<String, dynamic>>[
      {'name': 'covers_down', 'actualCovers': 1140, 'forecastCovers': 1200},
      {'name': 'covers_up', 'actualCovers': 1260, 'forecastCovers': 1200},
      {'name': 'ppa_down', 'avgPPA': _tPPA * 0.95},
      {'name': 'ppa_up', 'avgPPA': _tPPA * 1.08},
      {'name': 'cplh_down', 'avgCPLH': _tCPLH * 0.90},
      {'name': 'cplh_up', 'avgCPLH': _tCPLH * 1.10},
      {'name': 'splh_down', 'avgSPLH': _tSPLH * 0.90},
      {'name': 'splh_up', 'avgSPLH': _tSPLH * 1.10},
      {'name': 'foh_wage_up', 'avgFohWage': _fohWage * 1.10},
      {'name': 'foh_wage_down', 'avgFohWage': _fohWage * 0.90},
      {'name': 'boh_wage_up', 'avgBohWage': _bohWage * 1.10},
      {'name': 'boh_wage_down', 'avgBohWage': _bohWage * 0.90},
    ];

    for (final s in scenarios) {
      test('closed row driver label matches engine for ${s['name']}', () {
        final engineLever = _engineLever(
          actualCovers: (s['actualCovers'] as int?) ?? 1200,
          forecastCovers: (s['forecastCovers'] as int?) ?? 1200,
          avgCPLH: s['avgCPLH'] as double?,
          avgPPA: s['avgPPA'] as double?,
          avgSPLH: s['avgSPLH'] as double?,
          avgFohWage: s['avgFohWage'] as double?,
          avgBohWage: s['avgBohWage'] as double?,
        );
        expect(engineLever, equals(s['name']),
            reason:
                'fixture sanity — engine output should match the named scenario');

        final shift = _closedShift(engineLever: engineLever);
        final projection = service.build([shift]);
        final daypart = projection.dayRows.first.children.first;

        expect(daypart.status, equals(RowStatus.closed));
        expect(_displayedLeverIdFromLabel(daypart.driverLabel),
            equals(engineLever),
            reason:
                'R1 + R18 — closed-row displayed lever must equal engine output');
      });
    }
  });

  group('Open / projected row purity (R30 — 7.58.5 lift)', () {
    test('open row driver is "Not yet available" even when storage carries a real lever',
        () {
      // Defensive: simulating a regression where an open row's stored
      // primaryLever is a real lever id (the pre-7.58.5 carry-forward
      // bug). The read service must still return "Not yet available".
      final open = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Tue',
        daypart: 'lunch',
        status: 'open',
        covers: 0,
        forecastCovers: 110,
        ppa: 0,
        cplh: 0,
        splh: 0,
        fohHours: 0,
        bohHours: 0,
        primaryLever: 'COVERS_DOWN',
        businessDate: '2026-03-25',
      );
      final projection = service.build([open]);
      expect(projection.dayRows.first.children.first.driverLabel,
          equals('Not yet available'),
          reason:
              'R30 — open rows must not surface inherited / fabricated levers');
    });

    test('projected row driver is "Not yet available"', () {
      final projected = ShiftRecord(
        weekId: '2026-W13',
        dayLabel: 'Sat',
        daypart: 'dinner',
        status: 'projected',
        covers: 110,
        forecastCovers: 110,
        ppa: 0,
        cplh: 0,
        splh: 0,
        fohHours: 24,
        bohHours: 10,
        primaryLever: 'ON_MODEL',
      );
      final projection = service.build([projected]);
      expect(projection.dayRows.first.children.first.driverLabel,
          equals('Not yet available'));
    });
  });
}
