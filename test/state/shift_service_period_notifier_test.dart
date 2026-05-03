// Phase 10.5.3 — ShiftServicePeriodNotifier tests.
//
// Pins notifier-side semantics for per-period primary driver:
//   * `primaryLeverIdFor` returns the lowercase canonical id (or
//     null) supplied to the test-only constructor.
//   * `primaryLeverCardFor` resolves through `LeverCards.lookup` and
//     surfaces null for the `on_model` sentinel / unknown id /
//     missing entry — never falls through to a real card.
//   * `forecastCoversByPeriodFromSnapshots` sums forecast covers per
//     defined period and drops snapshots whose `daypart` doesn't
//     match a known period id.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/app_defaults.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';

ServicePeriodAccumulator _bucket(String id) =>
    ServicePeriodAccumulator(servicePeriodId: id);

OpenShiftSnapshot _snap({
  String dayLabel = 'Mon',
  required String daypart,
  required int forecastCovers,
  String status = 'open',
  String businessDate = '2026-05-04',
}) {
  return OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W18',
    dayLabel: dayLabel,
    daypart: daypart,
    status: status,
    businessDate: businessDate,
    forecastCovers: forecastCovers,
    currentCovers: 0,
    scheduledFohHours: 0,
    scheduledBohHours: 0,
    currentPPA: 0,
    currentCPLH: 0,
    currentSPLH: 0,
    blendedWage: 0,
    updatedAt: '2026-05-04T12:00:00',
  );
}

void main() {
  group('ShiftServicePeriodNotifier.primaryLeverIdFor / Card', () {
    test('returns the id supplied to fromBuckets', () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {
          'lunch': _bucket('lunch'),
          'dinner': _bucket('dinner'),
          'late_night': _bucket('late_night'),
        },
        primaryLeverIds: const {
          'lunch': 'covers_down',
          'dinner': 'ppa_up',
          'late_night': null,
        },
        iana: 'America/St_Johns',
      );

      expect(notifier.primaryLeverIdFor('lunch'), equals('covers_down'));
      expect(notifier.primaryLeverIdFor('dinner'), equals('ppa_up'));
      expect(notifier.primaryLeverIdFor('late_night'), isNull);
    });

    test('returns null for unknown / unset period ids', () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {'lunch': _bucket('lunch')},
        iana: 'America/St_Johns',
      );
      expect(notifier.primaryLeverIdFor('lunch'), isNull);
      expect(notifier.primaryLeverIdFor('does_not_exist'), isNull);
    });

    test('primaryLeverCardFor resolves real cards via LeverCards.lookup',
        () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {'lunch': _bucket('lunch')},
        primaryLeverIds: const {'lunch': 'covers_down'},
        iana: 'America/St_Johns',
      );
      final card = notifier.primaryLeverCardFor('lunch');
      expect(card, isNotNull);
      expect(card!.id, equals('covers_down'));
      expect(card.shortLabel, equals('COVERS'));
    });

    test(
        'primaryLeverCardFor returns null for the on_model sentinel '
        '(no fall-through to coversDown per 7.58 F-1)', () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {'lunch': _bucket('lunch')},
        // Engine never returns this for closed rows; sentinel stored
        // in any storage form must lookup to null.
        primaryLeverIds: const {'lunch': 'on_model'},
        iana: 'America/St_Johns',
      );
      expect(notifier.primaryLeverCardFor('lunch'), isNull);
    });

    test('primaryLeverCardFor returns null for an unknown id', () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {'lunch': _bucket('lunch')},
        primaryLeverIds: const {'lunch': 'definitely_not_a_lever'},
        iana: 'America/St_Johns',
      );
      expect(notifier.primaryLeverCardFor('lunch'), isNull);
    });

    test(
        'lookup is case-insensitive: upper-snake is not the canonical '
        'storage form here but must still resolve to the real card '
        '(R-STOR-5)', () {
      final notifier = ShiftServicePeriodNotifier.fromBuckets(
        buckets: {'lunch': _bucket('lunch')},
        primaryLeverIds: const {'lunch': 'COVERS_DOWN'},
        iana: 'America/St_Johns',
      );
      final card = notifier.primaryLeverCardFor('lunch');
      expect(card, isNotNull);
      expect(card!.id, equals('covers_down'));
    });
  });

  group('forecastCoversByPeriodFromSnapshots', () {
    final defs = ServicePeriodDefinitionResolver.demoDefinitions;

    test('sums forecast covers per period across snapshots', () {
      final result = forecastCoversByPeriodFromSnapshots(
        snapshots: [
          _snap(daypart: 'lunch', forecastCovers: 60),
          _snap(daypart: 'lunch', forecastCovers: 40),
          _snap(daypart: 'dinner', forecastCovers: 120),
          _snap(daypart: 'late_night', forecastCovers: 25),
        ],
        definitions: defs,
      );
      expect(result['lunch'], equals(100));
      expect(result['dinner'], equals(120));
      expect(result['late_night'], equals(25));
    });

    test('returns zero entries for periods with no snapshots', () {
      final result = forecastCoversByPeriodFromSnapshots(
        snapshots: [
          _snap(daypart: 'lunch', forecastCovers: 80),
        ],
        definitions: defs,
      );
      expect(result['lunch'], equals(80));
      expect(result['dinner'], equals(0));
      expect(result['late_night'], equals(0));
    });

    test('drops snapshots whose daypart is not a defined period', () {
      final result = forecastCoversByPeriodFromSnapshots(
        snapshots: [
          _snap(daypart: 'lunch', forecastCovers: 50),
          _snap(daypart: 'breakfast', forecastCovers: 999),
        ],
        definitions: defs,
      );
      expect(result['lunch'], equals(50));
      expect(result.containsKey('breakfast'), isFalse);
    });

    test('returns the right shape when no snapshots are provided', () {
      final result = forecastCoversByPeriodFromSnapshots(
        snapshots: const [],
        definitions: defs,
      );
      expect(result.keys, containsAll(['lunch', 'dinner', 'late_night']));
      for (final v in result.values) {
        expect(v, equals(0));
      }
    });
  });

  group('LeverCards integration smoke', () {
    test('every catalog id resolves to a renderable card', () {
      // Belt-and-suspenders for the chip surface: every id the read
      // service can mint must be looked-up-able.
      const ids = <String>[
        'covers_down', 'covers_up',
        'ppa_down', 'ppa_up',
        'cplh_down', 'cplh_up',
        'splh_down', 'splh_up',
        'foh_wage_down', 'foh_wage_up',
        'boh_wage_down', 'boh_wage_up',
        'foh_hours_over', 'foh_hours_under',
        'boh_hours_over', 'boh_hours_under',
      ];
      for (final id in ids) {
        expect(LeverCards.lookup(id), isNotNull, reason: id);
      }
      expect(LeverCards.lookup('on_model'), isNull);
      expect(LeverCards.lookup(null), isNull);
      expect(LeverCards.lookup(''), isNull);
    });
  });

  group('LeverCards.metricDirectionGlyph — chip arrow source', () {
    // The chip arrow is the raw metric direction, derived from the
    // id suffix. It is independent of `LeverCardData.direction`
    // (favorable / unfavorable); a favorable metric can still move
    // down (e.g. `foh_wage_down` is favorable but its metric arrow
    // is ↓).

    test('_up suffix → ↑', () {
      expect(LeverCards.metricDirectionGlyph('covers_up'), equals('↑'));
      expect(LeverCards.metricDirectionGlyph('ppa_up'), equals('↑'));
      expect(LeverCards.metricDirectionGlyph('cplh_up'), equals('↑'));
      expect(LeverCards.metricDirectionGlyph('splh_up'), equals('↑'));
      expect(LeverCards.metricDirectionGlyph('foh_wage_up'), equals('↑'));
      expect(LeverCards.metricDirectionGlyph('boh_wage_up'), equals('↑'));
    });

    test('_down suffix → ↓', () {
      expect(LeverCards.metricDirectionGlyph('covers_down'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('ppa_down'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('cplh_down'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('splh_down'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('foh_wage_down'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('boh_wage_down'), equals('↓'));
    });

    test('_over / _under suffixes for the hours-flex axes', () {
      expect(
          LeverCards.metricDirectionGlyph('foh_hours_over'), equals('↑'));
      expect(
          LeverCards.metricDirectionGlyph('boh_hours_over'), equals('↑'));
      expect(
          LeverCards.metricDirectionGlyph('foh_hours_under'), equals('↓'));
      expect(
          LeverCards.metricDirectionGlyph('boh_hours_under'), equals('↓'));
    });

    test(
        'arrow for foh_wage_down is ↓ even though the lever is '
        'favorable (chip arrow MUST NOT echo LeverDirection)', () {
      // Regression pin: the chip used to render `LeverDirection ==
      // favorable ? ↑ : ↓`, which painted the *favorable* lever
      // `foh_wage_down` as ↑ — visually contradicting the metric
      // movement. The fix derives the arrow from the id suffix.
      final card = LeverCards.lookup('foh_wage_down')!;
      expect(card.direction, equals(LeverDirection.favorable));
      expect(card.isFavorable, isTrue);
      expect(LeverCards.metricDirectionGlyph(card.id), equals('↓'),
          reason: 'metric movement is down, even though favorable');
    });

    test(
        'arrow for foh_wage_up is ↑ even though the lever is '
        'unfavorable (chip arrow MUST NOT echo LeverDirection)', () {
      final card = LeverCards.lookup('foh_wage_up')!;
      expect(card.direction, equals(LeverDirection.unfavorable));
      expect(card.isFavorable, isFalse);
      expect(LeverCards.metricDirectionGlyph(card.id), equals('↑'),
          reason: 'metric movement is up, even though unfavorable');
    });

    test('case-insensitive: storage form upper-snake also resolves', () {
      expect(LeverCards.metricDirectionGlyph('COVERS_DOWN'), equals('↓'));
      expect(LeverCards.metricDirectionGlyph('PPA_UP'), equals('↑'));
    });

    test('null / empty / sentinel / unknown → null glyph', () {
      expect(LeverCards.metricDirectionGlyph(null), isNull);
      expect(LeverCards.metricDirectionGlyph(''), isNull);
      expect(LeverCards.metricDirectionGlyph('on_model'), isNull);
      expect(LeverCards.metricDirectionGlyph('not_a_lever_id'), isNull);
    });

    test(
        'unknown id with a valid-looking suffix returns null (catalog '
        'membership gates the helper, not the suffix alone)', () {
      // Regression pin: an unknown id like `not_catalog_up` would
      // match the `_up` suffix branch if the helper trusted suffix
      // shape alone. Renderers MUST see null here so the chip
      // surfaces the "NO PATTERN YET" degraded state rather than an
      // arrow that implies a real catalog id.
      expect(LeverCards.metricDirectionGlyph('not_catalog_up'), isNull);
      expect(LeverCards.metricDirectionGlyph('not_catalog_down'), isNull);
      expect(LeverCards.metricDirectionGlyph('mystery_over'), isNull);
      expect(LeverCards.metricDirectionGlyph('mystery_under'), isNull);
      // Catalog membership also rules out the upper-snake sentinel.
      expect(LeverCards.metricDirectionGlyph('ON_MODEL'), isNull);
    });
  });
}
