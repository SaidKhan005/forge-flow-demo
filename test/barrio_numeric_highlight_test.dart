// Visual-first pass rec #3: conservative number+unit tokenizer that
// powers the render-time numeric fact pop in the training cards.
//
// Covers: every positive pattern class named in the approved plan
// (temperatures, durations, percentages, explicit measurement units,
// ranges), the mandatory negatives (bare integers, years, chapter and
// step numbers, "4 C's", '3 pillars'), offset fidelity against the
// source string, and the blocked-range overlap rule that keeps term
// links and search highlights un-restyled.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_numeric_highlight.dart';

/// The matched substrings, in order, for [text].
List<String> _tokens(String text, {List<List<int>> blocked = const []}) {
  return [
    for (final m
        in BarrioNumericHighlight.matchesIn(text, blockedRanges: blocked))
      text.substring(m.start, m.end),
  ];
}

void main() {
  group('temperatures', () {
    test('bare letter with space: 165 F', () {
      expect(_tokens('Cook chicken to 165 F before serving.'), ['165 F']);
    });

    test('degrees word: 4 degrees C', () {
      expect(_tokens('Keep the fridge at 4 degrees C at all times.'),
          ['4 degrees C']);
    });

    test('degree symbol range: 40-140°F', () {
      expect(_tokens('The danger zone is 40-140°F for cooked food.'),
          ['40-140°F']);
    });

    test('spelled-out scale: 20 degrees Celsius', () {
      expect(_tokens('Store at 20 degrees Celsius or cooler.'),
          ['20 degrees Celsius']);
    });

    test('two-sided range: 71 degrees C - 80 degrees C', () {
      expect(_tokens('Serve espresso milk at 71 degrees C - 80 degrees C.'),
          ['71 degrees C', '80 degrees C']);
    });

    test('paired units: 165 degrees F (74 degrees C)', () {
      expect(_tokens('Poultry must reach 165 degrees F (74 degrees C).'),
          ['165 degrees F', '74 degrees C']);
    });
  });

  group('durations', () {
    test('seconds: 25 seconds', () {
      expect(_tokens('Wash hands for 25 seconds minimum.'), ['25 seconds']);
    });

    test('minutes: 2 minutes', () {
      expect(_tokens('Steep for 2 minutes, then serve.'), ['2 minutes']);
    });

    test('days: 30 days', () {
      expect(_tokens('The cycle locks for 30 days.'), ['30 days']);
    });

    test('to-range: 3 to 6 seconds is one token', () {
      expect(_tokens('The pour should take 3 to 6 seconds.'),
          ['3 to 6 seconds']);
    });

    test('tight abbreviation: 6hrs', () {
      expect(_tokens('The shift runs 6hrs on Saturdays.'), ['6hrs']);
    });

    test('hyphenated: 30-minute', () {
      expect(_tokens('Take your 30-minute unpaid break.'), ['30-minute']);
    });

    test('decimal weeks: 8.57 weeks', () {
      expect(_tokens('That is 8.57 weeks of coverage.'), ['8.57 weeks']);
    });
  });

  group('percentages', () {
    test('symbol: 5%', () {
      expect(_tokens('A 12oz beer with a 5% ABV counts as one drink.'),
          ['12oz', '5%']);
    });

    test('word: 40 percent', () {
      expect(_tokens('Spirits sit at 40 percent alcohol.'), ['40 percent']);
    });
  });

  group('measurements with explicit units', () {
    test('ml: 341 ml', () {
      expect(_tokens('A standard serving is 341 ml of beer.'), ['341 ml']);
    });

    test('kg: 2.5 kg', () {
      expect(_tokens('Thaw 24 hours for every 2.5 kg of poultry.'),
          ['24 hours', '2.5 kg']);
    });

    test('ppm: 200 ppm', () {
      expect(_tokens('Use quaternary ammonium at 200 ppm.'), ['200 ppm']);
    });

    test('tight oz: 20oz', () {
      expect(_tokens('The rib eye is a 20oz cut.'), ['20oz']);
    });

    test('cups and bars', () {
      expect(_tokens('Brew 2 cups at 9 bars of pressure.'),
          ['2 cups', '9 bars']);
    });
  });

  group('must-not-match negatives', () {
    test("name-like: the 4 C's of food safety", () {
      expect(_tokens("Remember the 4 C's of food safety."), isEmpty);
    });

    test('name-like: 3 pillars', () {
      expect(_tokens('Our service rests on 3 pillars.'), isEmpty);
    });

    test('years: 1915 and 2012', () {
      expect(
        _tokens('Constructed in 1915, it won the award in 2012.'),
        isEmpty,
      );
    });

    test('bare integer', () {
      expect(_tokens('Table 42 seats eight guests.'), isEmpty);
    });

    test('chapter and step numbers', () {
      expect(_tokens('Chapter 3 begins with Step 2 of the checklist.'),
          isEmpty);
    });

    test('multiplier: 1.5x minimum wage', () {
      expect(_tokens('Overtime is paid at 1.5x minimum wage.'), isEmpty);
    });

    test('lowercase bare letter is not a temperature', () {
      expect(_tokens('Order 3 c of stock.'), isEmpty);
    });

    test('word units need the whole word: 5 grams stays plain', () {
      expect(_tokens('Add 5 grams of salt.'), isEmpty);
    });

    test('no digits short-circuits', () {
      expect(_tokens('No numbers here at all.'), isEmpty);
    });
  });

  group('offsets and blocked ranges', () {
    test('offsets index the source string exactly', () {
      const text = 'Hold food above 60 degrees Celsius during service.';
      final matches = BarrioNumericHighlight.matchesIn(text);
      expect(matches, hasLength(1));
      expect(text.substring(matches.first.start, matches.first.end),
          '60 degrees Celsius');
    });

    test('a token overlapping a blocked range is dropped whole', () {
      const text = 'Cook to 165 F today.';
      // '165' claimed by a search highlight [8, 11).
      expect(_tokens(text, blocked: const [
        [8, 11]
      ]), isEmpty);
    });

    test('a token clear of blocked ranges still matches', () {
      const text = 'Cook to 165 F today.';
      expect(_tokens(text, blocked: const [
        [0, 4]
      ]), ['165 F']);
    });

    test('matches are sorted and non-overlapping', () {
      const text = 'Chill to 4 degrees C, hold 2 hours, sanitize at 200 ppm.';
      final matches = BarrioNumericHighlight.matchesIn(text);
      expect(
        [for (final m in matches) text.substring(m.start, m.end)],
        ['4 degrees C', '2 hours', '200 ppm'],
      );
      for (var i = 1; i < matches.length; i++) {
        expect(matches[i].start, greaterThanOrEqualTo(matches[i - 1].end));
      }
    });
  });
}
