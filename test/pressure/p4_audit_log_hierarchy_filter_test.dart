// Lane B B8 — p4_audit_log_hierarchy_filter unit tests.
//
// Pins the bucketing math + recorder accumulation contract so a
// `/health` consumer reading the snapshot sees stable
// `audit_log_hierarchy_filter_p95_ms{operator_id, location_count}`
// values across releases.

import 'package:flutter_test/flutter_test.dart';
import '../../tool/pressure/p4_audit_log_hierarchy_filter.dart';

void main() {
  group('auditLogHierarchyLocationCountBucket', () {
    test('zero maps to bucket "0"', () {
      expect(auditLogHierarchyLocationCountBucket(0), '0');
    });

    test('one maps to bucket "1"', () {
      expect(auditLogHierarchyLocationCountBucket(1), '1');
    });

    test('three maps to bucket "4" (rounds up to the next boundary)', () {
      expect(auditLogHierarchyLocationCountBucket(3), '4');
    });

    test('eight maps to bucket "8" (exact boundary)', () {
      expect(auditLogHierarchyLocationCountBucket(8), '8');
    });

    test('nine maps to bucket "16"', () {
      expect(auditLogHierarchyLocationCountBucket(9), '16');
    });

    test('above the largest boundary maps to "256+"', () {
      expect(auditLogHierarchyLocationCountBucket(257), '256+');
      expect(auditLogHierarchyLocationCountBucket(10000), '256+');
    });

    test('negative inputs map to bucket "0" (defensive)', () {
      expect(auditLogHierarchyLocationCountBucket(-1), '0');
    });
  });

  group('AuditLogHierarchyLatencyRecorder', () {
    test('record + snapshot produces one bucket per (operator_id, '
        'location_count_bucket)', () {
      final recorder = AuditLogHierarchyLatencyRecorder();
      recorder.record(
        operatorId: 'op-1',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 10),
      );
      recorder.record(
        operatorId: 'op-1',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 20),
      );
      recorder.record(
        operatorId: 'op-1',
        locationCount: 4,
        elapsed: const Duration(milliseconds: 100),
      );
      recorder.record(
        operatorId: 'op-2',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 5),
      );
      final snap = recorder.snapshot();
      expect(snap, hasLength(3));
      final op1Bucket1 = snap.firstWhere(
        (b) => b.operatorId == 'op-1' && b.locationCountBucket == '1',
      );
      expect(op1Bucket1.count, 2);
      // p50 of {10, 20} → 15 (linear interpolation).
      expect(op1Bucket1.p50Ms, inInclusiveRange(10, 20));
      expect(op1Bucket1.maxMs, 20);
    });

    test('p95 computed via linear interpolation matches the inclusive '
        'definition (rank = 0.95 * (n - 1))', () {
      final recorder = AuditLogHierarchyLatencyRecorder();
      // 11 samples: [0, 10, 20, ..., 100]. With n=11, rank_at_p95 =
      // 0.95 * 10 = 9.5, so p95 = lerp(sorted[9]=90, sorted[10]=100,
      // 0.5) = 95.
      for (var i = 0; i <= 100; i += 10) {
        recorder.record(
          operatorId: 'op-1',
          locationCount: 1,
          elapsed: Duration(milliseconds: i),
        );
      }
      final snap = recorder.snapshot();
      final bucket = snap.firstWhere(
        (b) => b.operatorId == 'op-1' && b.locationCountBucket == '1',
      );
      expect(bucket.count, 11);
      expect(bucket.p95Ms, 95);
      expect(bucket.maxMs, 100);
    });

    test('rolling window drops the oldest sample when capacity is '
        'exceeded', () {
      final recorder = AuditLogHierarchyLatencyRecorder(
        retainSamplesPerBucket: 3,
      );
      // 4 samples land; the first (oldest) is dropped so the snapshot
      // sees only [200, 300, 400].
      for (final ms in <int>[100, 200, 300, 400]) {
        recorder.record(
          operatorId: 'op-1',
          locationCount: 1,
          elapsed: Duration(milliseconds: ms),
        );
      }
      final snap = recorder.snapshot();
      final bucket = snap.single;
      expect(bucket.count, 3);
      expect(bucket.maxMs, 400);
      expect(bucket.p50Ms, 300);
    });

    test('snapshot omits buckets with zero observations after clear()',
        () {
      final recorder = AuditLogHierarchyLatencyRecorder();
      recorder.record(
        operatorId: 'op-1',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 10),
      );
      expect(recorder.snapshot(), hasLength(1));
      recorder.clear();
      expect(recorder.snapshot(), isEmpty);
    });

    test('snapshot ordering: by operator, then bucket ascending; "256+" '
        'lands at the end', () {
      final recorder = AuditLogHierarchyLatencyRecorder();
      recorder.record(
        operatorId: 'op-1',
        locationCount: 300,
        elapsed: const Duration(milliseconds: 1),
      );
      recorder.record(
        operatorId: 'op-1',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 1),
      );
      recorder.record(
        operatorId: 'op-2',
        locationCount: 1,
        elapsed: const Duration(milliseconds: 1),
      );
      final snap = recorder.snapshot();
      expect(snap.map((b) => b.operatorId).toList(),
          <String>['op-1', 'op-1', 'op-2']);
      expect(snap.map((b) => b.locationCountBucket).toList(),
          <String>['1', '256+', '1']);
    });

    test('retainSamplesPerBucket must be positive', () {
      expect(
        () => AuditLogHierarchyLatencyRecorder(retainSamplesPerBucket: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => AuditLogHierarchyLatencyRecorder(retainSamplesPerBucket: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('clock seam returns the injected clock', () {
      final fixed = DateTime.utc(2026, 5, 13, 12);
      final recorder = AuditLogHierarchyLatencyRecorder(clock: () => fixed);
      expect(recorder.now(), fixed);
    });

    test('snapshot toJson shape is stable across releases', () {
      final recorder = AuditLogHierarchyLatencyRecorder();
      recorder.record(
        operatorId: 'op-1',
        locationCount: 4,
        elapsed: const Duration(milliseconds: 50),
      );
      final json = recorder.snapshot().single.toJson();
      expect(json.keys.toSet(), <String>{
        'operator_id',
        'location_count_bucket',
        'count',
        'p50_ms',
        'p95_ms',
        'max_ms',
      });
    });
  });
}
