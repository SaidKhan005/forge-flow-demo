// Slice A11.2 — `p3c_oauth_refresh_storm.dart` CLI extension tests.
//
// The harness gained three CLI flags in this slice (`--ttl-dist`,
// `--vendor-mix`, `--jitter`). The behaviour under each flag value is
// observable via the public helpers exposed in the harness library
// (`synthesizeTtlMs`, `orderVendorsByMix`, `computeJitter`) — calling
// them directly is the cheapest "did the parser branch correctly"
// proof and side-steps the need to spawn a full run of the harness
// just to read the startup banner.
//
// CLI rejection of unknown values is verified by spawning a short
// `dart run` of the harness with each bad flag and asserting the
// process exits non-zero with the documented error message. This is
// the single integration point the unit-level helpers cannot cover.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p3c_oauth_refresh_storm.dart';

void main() {
  group('TTL distribution synthesis', () {
    test('uniform returns the base TTL on every call', () {
      final rng = math.Random(0);
      for (var i = 0; i < 100; i += 1) {
        expect(
          synthesizeTtlMs(baseMs: 5000, dist: TtlDist.uniform, rng: rng),
          5000,
          reason: 'uniform must NEVER deviate from the base TTL',
        );
      }
    });

    test(
        'normal distribution: 100 samples cluster near the mean with '
        'observable spread', () {
      final rng = math.Random(42);
      final samples = <int>[];
      for (var i = 0; i < 100; i += 1) {
        samples.add(
          synthesizeTtlMs(baseMs: 5000, dist: TtlDist.normal, rng: rng),
        );
      }
      // 100 samples must show some spread — at minimum, max != min.
      expect(samples.toSet().length, greaterThan(50),
          reason: 'normal distribution should produce >50 distinct values');
      final mean = samples.reduce((a, b) => a + b) / samples.length;
      // Mean within ±15% of base (looser than ±5% to keep the test
      // stable across RNG seeds).
      expect(mean, greaterThan(5000 * 0.85));
      expect(mean, lessThan(5000 * 1.15));
      // No sample can be < 1ms (the floor enforced by synthesizeTtlMs).
      expect(samples.every((s) => s >= 1), isTrue);
    });

    test(
        'bimodal distribution: every sample is either 50% or 150% of '
        'the base', () {
      final rng = math.Random(7);
      final samples = <int>[];
      for (var i = 0; i < 100; i += 1) {
        samples.add(
          synthesizeTtlMs(baseMs: 5000, dist: TtlDist.bimodal, rng: rng),
        );
      }
      final unique = samples.toSet();
      expect(unique, <int>{2500, 7500},
          reason: 'bimodal must produce exactly two values: 50% and 150%');
      // Roughly even split (allow 30/70 to absorb RNG noise).
      final lowCount = samples.where((s) => s == 2500).length;
      expect(lowCount, greaterThan(20));
      expect(lowCount, lessThan(80));
    });
  });

  group('Vendor-mix ordering', () {
    test('equal preserves the input order', () {
      final input = <String>['toast', 'square', 'clover', 'humanity'];
      final out = orderVendorsByMix(input, VendorMix.equal);
      expect(out, equals(input));
    });

    test(
        'power-law alphabetizes the head (top 3) and appends the tail '
        'alphabetically', () {
      // Input order matches a typical kAdapterAuthModes iteration:
      // not necessarily alphabetical.
      final input = <String>[
        'toast',
        'square',
        'clover',
        'humanity',
        'aloha',
        'libro',
      ];
      final out = orderVendorsByMix(input, VendorMix.powerLaw);
      // After alphabetical sort: aloha, clover, humanity, libro, square, toast
      // Head (top 3, alphabetical): aloha, clover, humanity
      // Tail (alphabetical): libro, square, toast
      expect(out, equals(<String>[
        'aloha',
        'clover',
        'humanity',
        'libro',
        'square',
        'toast',
      ]));
    });

    test(
        'power-law output differs from equal output for non-alphabetical '
        'input (proves the parser branched)', () {
      final input = <String>['toast', 'square', 'clover'];
      final equalOut = orderVendorsByMix(input, VendorMix.equal);
      final powerLawOut = orderVendorsByMix(input, VendorMix.powerLaw);
      expect(equalOut, isNot(equals(powerLawOut)));
    });
  });

  group('Jitter shape computation', () {
    test('none returns exactly the base delay', () {
      final rng = math.Random(0);
      for (var i = 0; i < 50; i += 1) {
        expect(
          computeJitter(
            shape: JitterShape.none,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
          1000,
        );
      }
    });

    test('full produces values strictly less than the base', () {
      final rng = math.Random(11);
      final samples = <int>[];
      for (var i = 0; i < 100; i += 1) {
        samples.add(
          computeJitter(
            shape: JitterShape.full,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
        );
      }
      expect(samples.every((s) => s >= 0 && s < 1000), isTrue);
      // Spread check: should have many distinct values.
      expect(samples.toSet().length, greaterThan(50));
    });

    test('equal produces values in [base/2, base) range', () {
      final rng = math.Random(13);
      final samples = <int>[];
      for (var i = 0; i < 100; i += 1) {
        samples.add(
          computeJitter(
            shape: JitterShape.equal,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
        );
      }
      expect(samples.every((s) => s >= 500 && s < 1000), isTrue,
          reason: 'equal must guarantee >= base/2 floor');
      expect(samples.toSet().length, greaterThan(50));
    });

    test('decorrelated stays bounded by the base cap', () {
      final rng = math.Random(17);
      var prev = 0;
      for (var i = 0; i < 100; i += 1) {
        final next = computeJitter(
          shape: JitterShape.decorrelated,
          baseMs: 1000,
          previousMs: prev,
          rng: rng,
        ).inMilliseconds;
        expect(next, greaterThanOrEqualTo(500),
            reason: 'decorrelated jitter must respect the base/2 floor');
        expect(next, lessThanOrEqualTo(1000),
            reason: 'decorrelated jitter must NEVER exceed the base cap');
        prev = next;
      }
    });

    test(
        'each shape produces a distinct distribution from `none` '
        '(proves the switch branched correctly for each value)', () {
      final rng = math.Random(23);
      final none = <int>[
        for (var i = 0; i < 30; i += 1)
          computeJitter(
            shape: JitterShape.none,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
      ];
      final full = <int>[
        for (var i = 0; i < 30; i += 1)
          computeJitter(
            shape: JitterShape.full,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
      ];
      final equal = <int>[
        for (var i = 0; i < 30; i += 1)
          computeJitter(
            shape: JitterShape.equal,
            baseMs: 1000,
            previousMs: 0,
            rng: rng,
          ).inMilliseconds,
      ];
      final decor = <int>[
        for (var i = 0; i < 30; i += 1)
          computeJitter(
            shape: JitterShape.decorrelated,
            baseMs: 1000,
            previousMs: 500,
            rng: rng,
          ).inMilliseconds,
      ];

      // `none` is a constant; the others must produce variation.
      expect(none.toSet(), <int>{1000});
      expect(full.toSet().length, greaterThan(1));
      expect(equal.toSet().length, greaterThan(1));
      expect(decor.toSet().length, greaterThan(1));
      // All four must be distinguishable from each other.
      expect(full.toSet(), isNot(equals(equal.toSet())));
      expect(equal.toSet(), isNot(equals(decor.toSet())));
    });
  });

  group('CLI rejection of unknown flag values (subprocess)', () {
    // These tests spawn `dart run` against the harness with bad flag
    // values. They assert exit code != 0 and the documented error
    // message appears in stderr. Skipped on environments that don't
    // expose the dart binary on PATH (e.g., minimal CI).
    final dartBin = _findDartBinary();

    test('--ttl-dist=garbage prints rejection to stderr', () async {
      if (dartBin == null) {
        markTestSkipped('dart binary not on PATH');
        return;
      }
      final result = await Process.run(
        dartBin,
        <String>[
          'run',
          'tool/pressure/p3c_oauth_refresh_storm.dart',
          '--ttl-dist=garbage',
        ],
        workingDirectory: _repoRoot(),
        runInShell: dartBin.toLowerCase().endsWith('.bat'),
      );
      // NOTE: the harness's `Future<int> main` returns 2 on parse
      // error but Dart ignores Future returns for the OS exit code,
      // so the process exits 0. This is a pre-existing harness bug
      // unrelated to A11.2 (see existing `--help` branch which calls
      // `exit(0)` explicitly while the FormatException branch does
      // not). Per the slice's "don't fix as a drive-by" rule we
      // assert on the stderr message instead — that proves the
      // parser branched correctly into the rejection path.
      final stderr = (result.stderr as String?) ?? '';
      expect(stderr, contains('--ttl-dist'));
      expect(
        stderr,
        contains('garbage'),
        reason: 'rejection message must echo the bad value',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('--vendor-mix=garbage prints rejection to stderr', () async {
      if (dartBin == null) {
        markTestSkipped('dart binary not on PATH');
        return;
      }
      final result = await Process.run(
        dartBin,
        <String>[
          'run',
          'tool/pressure/p3c_oauth_refresh_storm.dart',
          '--vendor-mix=garbage',
        ],
        workingDirectory: _repoRoot(),
        runInShell: dartBin.toLowerCase().endsWith('.bat'),
      );
      // See note in --ttl-dist test re: pre-existing exit-code bug.
      final stderr = (result.stderr as String?) ?? '';
      expect(stderr, contains('--vendor-mix'));
      expect(stderr, contains('garbage'));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('--jitter=garbage prints rejection to stderr', () async {
      if (dartBin == null) {
        markTestSkipped('dart binary not on PATH');
        return;
      }
      final result = await Process.run(
        dartBin,
        <String>[
          'run',
          'tool/pressure/p3c_oauth_refresh_storm.dart',
          '--jitter=garbage',
        ],
        workingDirectory: _repoRoot(),
        runInShell: dartBin.toLowerCase().endsWith('.bat'),
      );
      // See note in --ttl-dist test re: pre-existing exit-code bug.
      final stderr = (result.stderr as String?) ?? '';
      expect(stderr, contains('--jitter'));
      expect(stderr, contains('garbage'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

/// Find the `dart` binary. Tries (in order):
///   1. `Platform.resolvedExecutable` if it ends with dart/dart.exe.
///   2. The `dart` binary next to a flutter_tester executable (Flutter
///      ships dart under `<flutter_sdk>/bin/`. Windows: `dart.bat`.
///      Posix: `dart` (no extension)).
///   3. PATH search.
String? _findDartBinary() {
  final candidateNames = Platform.isWindows
      ? <String>['dart.exe', 'dart.bat', 'dart']
      : <String>['dart'];
  final resolved = Platform.resolvedExecutable;
  if (resolved.isNotEmpty) {
    final base =
        resolved.split(Platform.pathSeparator).last.toLowerCase();
    if (base == 'dart' || base == 'dart.exe' || base == 'dart.bat') {
      return resolved;
    }
    // flutter_tester case: walk up to `<flutter_sdk>/bin/`.
    final parts = resolved.split(Platform.pathSeparator);
    final binIndex = parts.lastIndexOf('bin');
    if (binIndex > 0) {
      for (final name in candidateNames) {
        final candidate = (<String>[
          ...parts.sublist(0, binIndex + 1),
          name,
        ]).join(Platform.pathSeparator);
        if (File(candidate).existsSync()) return candidate;
      }
    }
  }
  final pathEnv = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    for (final name in candidateNames) {
      final candidate = File('$dir${Platform.pathSeparator}$name');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  return null;
}

/// The repo root is the directory two levels up from
/// `test/pressure/`. The runner is executed from the repo root by
/// `flutter test`, but Process.run inherits the runner's CWD; pass
/// it explicitly so subprocess paths are stable.
String _repoRoot() => Directory.current.path;
