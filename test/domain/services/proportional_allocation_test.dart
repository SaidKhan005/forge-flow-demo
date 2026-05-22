// Unit tests for lib/domain/services/proportional_allocation.dart.
//
// All functions are pure Dart with no I/O dependencies, so no mocking
// or Flutter framework is required.  Uses flutter_test for consistency
// with the rest of the test suite.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/proportional_allocation.dart';

void main() {
  // ── allocateLargestRemainderInt ──────────────────────────────────────────

  group('allocateLargestRemainderInt', () {
    test('zero weights → all zeros (degenerate)', () {
      final result = allocateLargestRemainderInt(10, [0, 0, 0]);
      expect(result, [0, 0, 0]);
    });

    test('empty weight list → empty result', () {
      final result = allocateLargestRemainderInt(10, []);
      expect(result, isEmpty);
    });

    test('single slot → all assigned to it', () {
      final result = allocateLargestRemainderInt(7, [5]);
      expect(result, [7]);
    });

    test('total 0 → all zeros', () {
      final result = allocateLargestRemainderInt(0, [3, 3, 4]);
      expect(result, [0, 0, 0]);
      expect(result.fold(0, (s, v) => s + v), 0);
    });

    test('equal weights [1,1,1] with total 10 → sum == 10', () {
      final result = allocateLargestRemainderInt(10, [1, 1, 1]);
      expect(result.fold(0, (s, v) => s + v), 10);
    });

    test('equal weights [2,2,2] with total 10 → each slot gets 3 or 4, sum == 10', () {
      final result = allocateLargestRemainderInt(10, [2, 2, 2]);
      expect(result.fold(0, (s, v) => s + v), 10);
    });

    test('unequal weights — example 1: [1,2,3] total 10 → sum == 10', () {
      final result = allocateLargestRemainderInt(10, [1, 2, 3]);
      expect(result.fold(0, (s, v) => s + v), 10);
    });

    test('unequal weights — example 2: [3,7] total 100 → sum == 100', () {
      final result = allocateLargestRemainderInt(100, [3, 7]);
      expect(result.fold(0, (s, v) => s + v), 100);
    });

    test('unequal weights — example 3: [5,3,2,1] total 37 → sum == 37', () {
      final result = allocateLargestRemainderInt(37, [5, 3, 2, 1]);
      expect(result.fold(0, (s, v) => s + v), 37);
    });

    test('no slot receives a negative value', () {
      final result = allocateLargestRemainderInt(7, [1, 2, 3]);
      for (final v in result) {
        expect(v, greaterThanOrEqualTo(0));
      }
    });
  });

  // ── allocateLargestRemainderByDouble ─────────────────────────────────────

  group('allocateLargestRemainderByDouble', () {
    test('zero shares → all zeros (degenerate)', () {
      final result = allocateLargestRemainderByDouble(10, [0.0, 0.0]);
      expect(result, [0, 0]);
    });

    test('empty share list → empty result', () {
      final result = allocateLargestRemainderByDouble(10, []);
      expect(result, isEmpty);
    });

    test('single share → all assigned to it', () {
      final result = allocateLargestRemainderByDouble(9, [1.0]);
      expect(result, [9]);
    });

    test('total 0 → all zeros', () {
      final result = allocateLargestRemainderByDouble(0, [1.0, 2.0, 3.0]);
      expect(result.fold(0, (s, v) => s + v), 0);
    });

    test('equal shares → sum == total', () {
      final result = allocateLargestRemainderByDouble(10, [1.0, 1.0, 1.0]);
      expect(result.fold(0, (s, v) => s + v), 10);
    });

    test('unequal double shares [1.5, 2.5, 6.0] total 20 → sum == 20', () {
      final result = allocateLargestRemainderByDouble(20, [1.5, 2.5, 6.0]);
      expect(result.fold(0, (s, v) => s + v), 20);
    });

    test('fractional shares that are hard to split [1.1, 2.2, 3.3] total 13 → sum == 13', () {
      final result = allocateLargestRemainderByDouble(13, [1.1, 2.2, 3.3]);
      expect(result.fold(0, (s, v) => s + v), 13);
    });
  });

  // ── allocateProportionalDoubles ──────────────────────────────────────────

  group('allocateProportionalDoubles', () {
    test('zero weights → all zeros', () {
      final result = allocateProportionalDoubles(100.0, [0, 0]);
      expect(result, [0.0, 0.0]);
    });

    test('total 0 → all zeros', () {
      final result = allocateProportionalDoubles(0.0, [1, 2, 3]);
      expect(result, [0.0, 0.0, 0.0]);
    });

    test('single slot → receives whole total', () {
      final result = allocateProportionalDoubles(42.5, [1]);
      expect(result, hasLength(1));
      expect(result[0], closeTo(42.5, 1e-9));
    });

    test('equal weights → each gets total/n, sum ≈ total', () {
      final result = allocateProportionalDoubles(30.0, [1, 1, 1]);
      expect(result.fold(0.0, (s, v) => s + v), closeTo(30.0, 1e-9));
      for (final v in result) {
        expect(v, closeTo(10.0, 1e-9));
      }
    });

    test('[1,3] weights, total 10.0 → sum ≈ 10.0', () {
      final result = allocateProportionalDoubles(10.0, [1, 3]);
      expect(result.fold(0.0, (s, v) => s + v), closeTo(10.0, 1e-9));
    });

    test('[2,3,5] weights, total 100.0 → proportions are correct and sum ≈ 100.0', () {
      final result = allocateProportionalDoubles(100.0, [2, 3, 5]);
      expect(result.fold(0.0, (s, v) => s + v), closeTo(100.0, 1e-9));
      expect(result[0], closeTo(20.0, 1e-6));
      expect(result[1], closeTo(30.0, 1e-6));
      // Last slot absorbs rounding remainder; should also be ~50.0
      expect(result[2], closeTo(50.0, 1e-6));
    });
  });

  // ── largestRemainderCore ─────────────────────────────────────────────────

  group('largestRemainderCore', () {
    test('sum of result == total for [3.3, 3.3, 3.4] total 10', () {
      final result = largestRemainderCore(10, [3.3, 3.3, 3.4]);
      expect(result.fold(0, (s, v) => s + v), 10);
    });

    test('single element → equals total', () {
      final result = largestRemainderCore(7, [7.0]);
      expect(result, [7]);
    });

    test('all zeros fractional with total 0 → all zeros', () {
      final result = largestRemainderCore(0, [0.0, 0.0]);
      expect(result, [0, 0]);
    });

    test('larger example: 5 slots, total 17, sum == 17', () {
      // fractional values: each slot gets 3.4
      final result = largestRemainderCore(17, [3.4, 3.4, 3.4, 3.4, 3.4]);
      expect(result.fold(0, (s, v) => s + v), 17);
    });

    test('fractional values that do not divide evenly', () {
      // total=7, 3 slots → floors [2,2,2], remainder 1 → 1 extra slot
      final result = largestRemainderCore(7, [7 / 3, 7 / 3, 7 / 3]);
      expect(result.fold(0, (s, v) => s + v), 7);
    });

    test('remainder distributed to slot with largest fractional part', () {
      // fractionals: [1.9, 1.1] → floors [1,1], remainder 1 goes to idx 0
      final result = largestRemainderCore(3, [1.9, 1.1]);
      expect(result[0], 2);
      expect(result[1], 1);
    });
  });
}
