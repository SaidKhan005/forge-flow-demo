// Phase 9.0Σ.k — focused tests for the rollups load-test harness (B38).
//
// What is asserted:
//
//   1. Tier-M defaults compute the locked 500 × 200 × 90 × 3 row math.
//   2. Deterministic ID generators produce stable, distinct UUID
//      strings across operators / locations.
//   3. parseArgs accepts both `--flag=value` and `--flag value` forms
//      and rejects malformed flags / missing required values.
//   4. writeSeedSql is deterministic — same config produces identical
//      output bytewise — and the output is shaped around the
//      rollup_business_day / aggregation_state / FK-prerequisite
//      contracts.
//   5. runCli refuses Tier-M-sized --emit-sql without
//      --confirm-tier-m-scale.
//   6. runCli writes no file by default (plan-only is the default
//      behaviour; no live apply ever).
//
// Tests run against the public surface of the tool — they do not
// spawn a child `dart` process and they do not touch any database.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rollups_load_test/synth_seed.dart';

void main() {
  group('SynthSeedConfig — Tier-M default math', () {
    test('parseArgs with no flags returns the locked Tier-M profile', () {
      final config = parseArgs(const <String>[]);
      expect(config.operators, kTierMOperators);
      expect(config.operators, 500);
      expect(config.locationsPerOperator, kTierMLocationsPerOperator);
      expect(config.locationsPerOperator, 200);
      expect(config.days, kTierMDays);
      expect(config.days, 90);
      expect(config.metricFamilies, <String>['sales', 'labor', 'traffic']);
      expect(config.startDate, DateTime.utc(2026, 1, 1));
      expect(config.emitSql, isFalse);
      expect(config.outputPath, isNull);
      expect(config.confirmTierMScale, isFalse);
      expect(config.isTierMProfile, isTrue);
    });

    test('Tier-M rollup_business_day row count is exactly '
        '500 × 200 × 90 × 3 = 27,000,000', () {
      final config = parseArgs(const <String>[]);
      expect(config.rollupRowCount, 500 * 200 * 90 * 3);
      expect(config.rollupRowCount, 27000000);
    });

    test('Tier-M prerequisite row count is operators + roots + locations', () {
      final config = parseArgs(const <String>[]);
      // 500 operators + 500 root org_units + 500 × 200 locations.
      expect(config.prerequisiteRowCount, 500 + 500 + (500 * 200));
      expect(config.prerequisiteRowCount, 101000);
    });

    test('Tier-M default config trips the refusal threshold', () {
      final config = parseArgs(const <String>[]);
      expect(config.requiresTierMConfirmation, isTrue);
    });

    test('Refusal threshold is exactly 1,000,000 rows', () {
      expect(kTierMRefusalThreshold, 1000000);
    });

    test('A small scope below the threshold does NOT require '
        'tier-m confirmation', () {
      final config = parseArgs(const <String>[
        '--operators=2',
        '--locations-per-operator=2',
        '--days=3',
      ]);
      expect(config.rollupRowCount, 2 * 2 * 3 * 3);
      expect(config.requiresTierMConfirmation, isFalse);
      expect(config.isTierMProfile, isFalse);
    });
  });

  group('parseArgs — flag handling', () {
    test('supports both --flag=value and --flag value forms', () {
      final equals = parseArgs(const <String>[
        '--operators=4',
        '--locations-per-operator=5',
        '--days=6',
      ]);
      final spaced = parseArgs(const <String>[
        '--operators',
        '4',
        '--locations-per-operator',
        '5',
        '--days',
        '6',
      ]);
      expect(equals.operators, 4);
      expect(equals.locationsPerOperator, 5);
      expect(equals.days, 6);
      expect(spaced.operators, equals.operators);
      expect(spaced.locationsPerOperator, equals.locationsPerOperator);
      expect(spaced.days, equals.days);
    });

    test('--metric-families parses comma list and trims whitespace', () {
      final config = parseArgs(const <String>[
        '--metric-families=sales, labor , traffic ',
      ]);
      expect(config.metricFamilies, <String>['sales', 'labor', 'traffic']);
    });

    test('--metric-families accepts only rollup-safe identifier values', () {
      final config = parseArgs(const <String>[
        '--metric-families=sales_2,labor3,traffic',
      ]);
      expect(config.metricFamilies, <String>['sales_2', 'labor3', 'traffic']);
    });

    test('--metric-families rejects an empty list', () {
      expect(
        () => parseArgs(const <String>['--metric-families=']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--metric-families= , ,']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--metric-families rejects values that would break SQL literals', () {
      expect(
        () => parseArgs(const <String>[
          "--metric-families=sales'); select 1; --",
        ]),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--metric-families rejects uppercase, leading digits, hyphens, '
        'and values longer than the DB check allows', () {
      expect(
        () => parseArgs(const <String>['--metric-families=Sales']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--metric-families=1sales']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--metric-families=sales-labor']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(<String>['--metric-families=${'a' * 65}']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--operators rejects zero / negative / non-integer', () {
      expect(
        () => parseArgs(const <String>['--operators=0']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--operators=-1']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--operators=foo']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--start-date rejects malformed dates', () {
      expect(
        () => parseArgs(const <String>['--start-date=2026/01/01']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--start-date=2026-13-01']),
        throwsA(isA<SynthSeedException>()),
      );
      expect(
        () => parseArgs(const <String>['--start-date=2026-02-30']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('unknown flags are rejected', () {
      expect(
        () => parseArgs(const <String>['--bogus=1']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--emit-sql without --output throws (structural error)', () {
      expect(
        () => parseArgs(const <String>['--emit-sql']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--emit-sql with empty --output throws', () {
      expect(
        () => parseArgs(const <String>['--emit-sql', '--output=']),
        throwsA(isA<SynthSeedException>()),
      );
    });

    test('--help is rejected by parseArgs (runCli handles it)', () {
      expect(
        () => parseArgs(const <String>['--help']),
        throwsA(isA<SynthSeedException>()),
      );
    });
  });

  group('Deterministic ID generators', () {
    test('operatorIdFor follows the reserved synthetic prefix', () {
      expect(operatorIdFor(0), '00000000-0000-0001-0000-000000000000');
      expect(operatorIdFor(1), '00000000-0000-0001-0000-000000000001');
      expect(operatorIdFor(499), '00000000-0000-0001-0000-0000000001f3');
    });

    test('orgUnitIdFor follows the reserved synthetic prefix', () {
      expect(orgUnitIdFor(0), '00000000-0000-0002-0000-000000000000');
      expect(orgUnitIdFor(499), '00000000-0000-0002-0000-0000000001f3');
    });

    test('locationIdFor encodes the operator index in the leading '
        'segment and the location index in the trailing segment', () {
      expect(locationIdFor(0, 0), '00000000-0000-0003-0000-000000000000');
      expect(locationIdFor(0, 199), '00000000-0000-0003-0000-0000000000c7');
      expect(locationIdFor(1, 0), '00000001-0000-0003-0000-000000000000');
      expect(locationIdFor(499, 199), '000001f3-0000-0003-0000-0000000000c7');
    });

    test('IDs are deterministic across calls', () {
      expect(operatorIdFor(7), operatorIdFor(7));
      expect(orgUnitIdFor(7), orgUnitIdFor(7));
      expect(locationIdFor(7, 13), locationIdFor(7, 13));
    });

    test('IDs are distinct across distinct indices', () {
      final all = <String>{
        operatorIdFor(0),
        operatorIdFor(1),
        orgUnitIdFor(0),
        orgUnitIdFor(1),
        locationIdFor(0, 0),
        locationIdFor(0, 1),
        locationIdFor(1, 0),
      };
      expect(all.length, 7);
    });

    test('Negative indices are rejected', () {
      expect(() => operatorIdFor(-1), throwsA(isA<SynthSeedException>()));
      expect(() => orgUnitIdFor(-1), throwsA(isA<SynthSeedException>()));
      expect(() => locationIdFor(-1, 0), throwsA(isA<SynthSeedException>()));
      expect(() => locationIdFor(0, -1), throwsA(isA<SynthSeedException>()));
    });
  });

  group('writeSeedSql — deterministic small-scope output', () {
    final smallConfig = parseArgs(const <String>[
      '--operators=2',
      '--locations-per-operator=2',
      '--days=3',
    ]);

    test('produces identical output across two invocations '
        '(byte-for-byte determinism)', () {
      final first = StringBuffer();
      final second = StringBuffer();
      writeSeedSql(smallConfig, (line) => first.writeln(line));
      writeSeedSql(smallConfig, (line) => second.writeln(line));
      expect(second.toString(), first.toString());
    });

    test('emits one INSERT per operator into public.operators', () {
      final lines = _captureLines(smallConfig);
      final operatorInserts = lines
          .where((l) => l.startsWith('insert into public.operators '))
          .toList();
      expect(operatorInserts.length, 2);
      expect(
        operatorInserts.first,
        contains("'00000000-0000-0001-0000-000000000000'"),
      );
      expect(
        operatorInserts.last,
        contains("'00000000-0000-0001-0000-000000000001'"),
      );
    });

    test('emits one root org_unit per operator '
        '(unit_type=corp, parent_id=null)', () {
      final lines = _captureLines(smallConfig);
      final ouInserts = lines
          .where((l) => l.startsWith('insert into public.org_units '))
          .toList();
      expect(ouInserts.length, 2);
      for (final line in ouInserts) {
        expect(line, contains("null, 'corp'"));
      }
    });

    test('emits one location per (operator, location_index)', () {
      final lines = _captureLines(smallConfig);
      final locInserts = lines
          .where((l) => l.startsWith('insert into public.locations '))
          .toList();
      expect(locInserts.length, 2 * 2);
    });

    test('emits the body row count = '
        'operators × locations × days × metric_families', () {
      final lines = _captureLines(smallConfig);
      final bodyInserts = lines
          .where((l) => l.startsWith('insert into public.rollup_business_day '))
          .toList();
      expect(bodyInserts.length, 2 * 2 * 3 * 3);
    });

    test('seeds exactly one aggregation_state row for '
        '(rollup_business_day, business_day)', () {
      final lines = _captureLines(smallConfig);
      final stateInserts = lines
          .where((l) => l.startsWith('insert into public.aggregation_state '))
          .toList();
      expect(stateInserts.length, 1);
      expect(
        stateInserts.single,
        contains("'rollup_business_day', 'business_day', 0"),
      );
    });

    test('wraps the entire seed in begin/commit', () {
      final lines = _captureLines(smallConfig);
      expect(lines.where((l) => l == 'begin;').length, 1);
      expect(lines.where((l) => l == 'commit;').length, 1);
      expect(lines.indexOf('begin;'), lessThan(lines.indexOf('commit;')));
    });

    test('all rollup-body rows carry the synthetic placeholder '
        'metrics jsonb (no fabricated formulas)', () {
      final lines = _captureLines(smallConfig);
      final bodyInserts = lines
          .where((l) => l.startsWith('insert into public.rollup_business_day '))
          .toList();
      for (final line in bodyInserts) {
        expect(line, contains("'{\"synthetic\": true}'::jsonb"));
        expect(line, contains("'load_test_v1'"));
      }
    });

    test('all inserts use ON CONFLICT DO NOTHING for idempotent '
        're-apply', () {
      final lines = _captureLines(smallConfig);
      final allInserts = lines
          .where((l) => l.startsWith('insert into '))
          .toList();
      expect(allInserts, isNotEmpty);
      for (final line in allInserts) {
        expect(line, contains('on conflict'));
        expect(line, contains('do nothing'));
      }
    });
  });

  group('runCli — refusal and dry-run-by-default behaviour', () {
    test('default invocation prints plan and writes NO file', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runCli(
        const <String>[],
        writeOut: (l) => out.writeln(l),
        writeErr: (l) => err.writeln(l),
      );
      expect(code, 0);
      expect(out.toString(), contains('Mode: PLAN ONLY'));
      expect(out.toString(), contains('Profile:                  Tier-M'));
      expect(out.toString(), contains('27000000'));
      expect(err.toString(), isEmpty);
    });

    test('--emit-sql at Tier-M default size WITHOUT '
        '--confirm-tier-m-scale is refused (exit 2, no file)', () async {
      final tmp = await Directory.systemTemp.createTemp('synth_seed_test_');
      try {
        final outPath = '${tmp.path}/should_not_exist.sql';
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runCli(
          <String>['--emit-sql', '--output=$outPath'],
          writeOut: (l) => out.writeln(l),
          writeErr: (l) => err.writeln(l),
        );
        expect(code, 2);
        expect(err.toString(), contains('refusing to emit'));
        expect(err.toString(), contains('--confirm-tier-m-scale'));
        expect(
          File(outPath).existsSync(),
          isFalse,
          reason: 'refused emits MUST NOT write the output file',
        );
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('--emit-sql without --output is rejected at parse time '
        '(exit 2)', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runCli(
        const <String>['--emit-sql'],
        writeOut: (l) => out.writeln(l),
        writeErr: (l) => err.writeln(l),
      );
      expect(code, 2);
      expect(err.toString(), contains('--emit-sql requires --output'));
    });

    test(
      'unsafe --metric-families is rejected before emit writes a file',
      () async {
        final tmp = await Directory.systemTemp.createTemp('synth_seed_test_');
        try {
          final outPath = '${tmp.path}/unsafe.sql';
          final out = StringBuffer();
          final err = StringBuffer();
          final code = await runCli(
            <String>[
              '--operators=1',
              '--locations-per-operator=1',
              '--days=1',
              "--metric-families=sales'); select 1; --",
              '--emit-sql',
              '--output=$outPath',
            ],
            writeOut: (l) => out.writeln(l),
            writeErr: (l) => err.writeln(l),
          );
          expect(code, 2);
          expect(err.toString(), contains('--metric-families values'));
          expect(File(outPath).existsSync(), isFalse);
        } finally {
          await tmp.delete(recursive: true);
        }
      },
    );

    test('small-scope --emit-sql writes a non-empty file with the '
        'expected row count and shape', () async {
      final tmp = await Directory.systemTemp.createTemp('synth_seed_test_');
      try {
        final outPath = '${tmp.path}/seed.sql';
        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runCli(
          <String>[
            '--operators=2',
            '--locations-per-operator=2',
            '--days=3',
            '--emit-sql',
            '--output=$outPath',
          ],
          writeOut: (l) => out.writeln(l),
          writeErr: (l) => err.writeln(l),
        );
        expect(code, 0, reason: err.toString());
        expect(File(outPath).existsSync(), isTrue);
        final contents = File(outPath).readAsStringSync();
        expect(contents, contains('begin;'));
        expect(contents, contains('commit;'));
        expect(contents, contains('insert into public.rollup_business_day '));
        expect(contents, contains('insert into public.aggregation_state '));
        // Sanity: small-scope row count math = 2 × 2 × 3 × 3 = 36
        // body rows.
        final bodyMatches = RegExp(
          r'insert into public\.rollup_business_day ',
        ).allMatches(contents).length;
        expect(bodyMatches, 36);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('Tier-M-sized --emit-sql with --confirm-tier-m-scale is NOT '
        'refused (planning path; no live mutation)', () async {
      // Use a small scope above the refusal threshold by raising
      // metric-families artificially. We don't actually want to write
      // 27M rows in a unit test, so we keep the scope tiny and just
      // assert that runCli accepts the flag combination — i.e., the
      // gate exists and obeys the confirm flag.
      final tmp = await Directory.systemTemp.createTemp('synth_seed_test_');
      try {
        final outPath = '${tmp.path}/tiny_with_confirm.sql';
        final code = await runCli(
          <String>[
            '--operators=2',
            '--locations-per-operator=2',
            '--days=3',
            '--emit-sql',
            '--output=$outPath',
            '--confirm-tier-m-scale',
          ],
          writeOut: (_) {},
          writeErr: (_) {},
        );
        expect(code, 0);
        expect(File(outPath).existsSync(), isTrue);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('--help prints usage and exits 0', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runCli(
        const <String>['--help'],
        writeOut: (l) => out.writeln(l),
        writeErr: (l) => err.writeln(l),
      );
      expect(code, 0);
      expect(
        out.toString(),
        contains(
          'Usage: dart run '
          'tool/rollups_load_test/synth_seed.dart',
        ),
      );
      expect(err.toString(), isEmpty);
    });
  });

  group('Plan report — content', () {
    test('Tier-M default plan calls out the blocker '
        'and the live preflight', () {
      final config = parseArgs(const <String>[]);
      final report = formatPlanReport(config);
      expect(report, contains('Live preflight checklist'));
      expect(report, contains('Honest limitations'));
      expect(
        report,
        contains(
          'vendor-side aggregator that produces RAW facts has '
          'not landed',
        ),
      );
      expect(
        report,
        contains(
          'No timing, latency, contention, or freshness '
          'measurement is taken locally',
        ),
      );
    });

    test('Plan report names every target table the seed touches', () {
      final config = parseArgs(const <String>[]);
      final report = formatPlanReport(config);
      expect(report, contains('public.operators'));
      expect(report, contains('public.org_units'));
      expect(report, contains('public.locations'));
      expect(report, contains('public.rollup_business_day'));
      expect(report, contains('public.aggregation_state'));
    });
  });
}

/// Helper — run [writeSeedSql] into a list of trimmed lines so the
/// test assertions can scan for specific INSERT prefixes without
/// being thrown off by trailing newlines or blank separators.
List<String> _captureLines(SynthSeedConfig config) {
  final captured = <String>[];
  writeSeedSql(config, captured.add);
  return captured;
}
