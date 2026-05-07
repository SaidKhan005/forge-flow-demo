import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _op = '11111111-1111-1111-1111-111111111111';
const String _loc = '22222222-2222-2222-2222-222222222222';
const String _connection = '33333333-3333-3333-3333-333333333333';

void main() {
  group('FirstConnectionBackfillWindow', () {
    test('lastSixtyDays creates the bounded Doc 1 window', () {
      final now = DateTime.utc(2026, 5, 6, 12);
      final window = FirstConnectionBackfillWindow.lastSixtyDays(now);

      expect(window.windowStart, equals(DateTime.utc(2026, 3, 7, 12)));
      expect(window.windowEnd, equals(now));
      expect(
        window.windowEnd.difference(window.windowStart),
        equals(const Duration(days: 60)),
      );
    });

    test('rejects empty or over-wide windows', () {
      expect(
        () => FirstConnectionBackfillWindow(
          windowStart: DateTime.utc(2026, 5, 6),
          windowEnd: DateTime.utc(2026, 5, 6),
        ),
        throwsArgumentError,
      );
      expect(
        () => FirstConnectionBackfillWindow(
          windowStart: DateTime.utc(2026, 3, 1),
          windowEnd: DateTime.utc(2026, 5, 1, 0, 0, 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('FirstConnectionBackfillJob', () {
    test('fromRow parses wire values and normalizes timestamps to UTC', () {
      final job = FirstConnectionBackfillJob.fromRow(
        _row(
          category: 'labor',
          status: 'running',
          cursorToken: 'cursor-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 8),
          workerId: 'worker-a',
          claimedAt: DateTime.utc(2026, 5, 6, 12),
        ),
      );

      expect(job.jobId, equals('99999999-9999-9999-9999-999999999999'));
      expect(job.operatorId, equals(_op));
      expect(job.locationId, equals(_loc));
      expect(job.connectionId, equals(_connection));
      expect(job.vendorId, equals('adp_workforce_now'));
      expect(job.category, equals(IntegrationCategory.labor));
      expect(job.status, equals(FirstConnectionBackfillJobStatus.running));
      expect(job.status.wire, equals('running'));
      expect(job.cursorToken, equals('cursor-2'));
      expect(job.isActive, isTrue);
    });

    test('rejects blank identifiers, blank optional identifiers, and '
        'negative attempts', () {
      expect(() => _job(operatorId: ' '), throwsArgumentError);
      expect(() => _job(cursorToken: ''), throwsArgumentError);
      expect(() => _job(workerId: '  '), throwsArgumentError);
      expect(() => _job(attemptCount: -1), throwsArgumentError);
    });

    test('wire helpers reject unknown status and category values', () {
      expect(
        () => FirstConnectionBackfillJobStatusWire.fromWire('complete'),
        throwsArgumentError,
      );
      expect(
        () => FirstConnectionBackfillCategoryWire.fromWire('payroll'),
        throwsArgumentError,
      );
    });
  });

  // V1.F NEW coverage for the model layer.
  // Existing tests cover happy-path parse, the bounded window, and a
  // sample of validation failures. The tests below close P2 gaps:
  // status helpers, full wire round-trip, UTC normalization of mixed
  // inputs, and defensive failures on malformed driver rows.
  group('FirstConnectionBackfillWindow (NEW)', () {
    test(
      'normalizes non-UTC inputs to UTC at construction so downstream '
      'TIMESTAMPTZ binding always uses UTC',
      () {
        final localStart = DateTime(2026, 3, 7, 8);
        final localEnd = DateTime(2026, 5, 6, 8);
        final window = FirstConnectionBackfillWindow(
          windowStart: localStart,
          windowEnd: localEnd,
        );
        expect(window.windowStart.isUtc, isTrue);
        expect(window.windowEnd.isUtc, isTrue);
        expect(window.windowStart, equals(localStart.toUtc()));
        expect(window.windowEnd, equals(localEnd.toUtc()));
      },
    );

    test(
      'lastSixtyDays anchors the end at "now" and stretches start back '
      'exactly 60 days, regardless of input timezone',
      () {
        final localNow = DateTime(2026, 5, 6, 12);
        final window = FirstConnectionBackfillWindow.lastSixtyDays(localNow);
        expect(window.windowEnd, equals(localNow.toUtc()));
        expect(
          window.windowEnd.difference(window.windowStart),
          equals(const Duration(days: 60)),
        );
      },
    );
  });

  group('FirstConnectionBackfillJob (NEW)', () {
    test(
      'isActive returns true only for pending and running, false for '
      'succeeded and failed',
      () {
        for (final activeStatus in const <FirstConnectionBackfillJobStatus>[
          FirstConnectionBackfillJobStatus.pending,
          FirstConnectionBackfillJobStatus.running,
        ]) {
          final job = FirstConnectionBackfillJob.fromRow(
            _row(status: activeStatus.wire),
          );
          expect(
            job.isActive,
            isTrue,
            reason: '${activeStatus.wire} is active',
          );
        }
        for (final terminalStatus in const <FirstConnectionBackfillJobStatus>[
          FirstConnectionBackfillJobStatus.succeeded,
          FirstConnectionBackfillJobStatus.failed,
        ]) {
          final job = FirstConnectionBackfillJob.fromRow(
            _row(status: terminalStatus.wire),
          );
          expect(
            job.isActive,
            isFalse,
            reason: '${terminalStatus.wire} is terminal',
          );
        }
      },
    );

    test(
      'wire round-trips for every status and category enum value (no '
      'enum can drift from its string without the test catching it)',
      () {
        for (final status in FirstConnectionBackfillJobStatus.values) {
          final wire = status.wire;
          expect(
            FirstConnectionBackfillJobStatusWire.fromWire(wire),
            equals(status),
            reason: 'status round-trip: $wire',
          );
        }
        for (final category in IntegrationCategory.values) {
          final wire = category.backfillWire;
          expect(
            FirstConnectionBackfillCategoryWire.fromWire(wire),
            equals(category),
            reason: 'category round-trip: $wire',
          );
        }
      },
    );

    test(
      'fromRow throws when a required field is missing or has the wrong '
      'type so a malformed driver row never silently produces a half-built '
      'job',
      () {
        final missingJobId = _row()..['job_id'] = null;
        expect(
          () => FirstConnectionBackfillJob.fromRow(missingJobId),
          throwsA(isA<StateError>()),
        );
        final badTimestamp = _row()..['window_start'] = 12345;
        expect(
          () => FirstConnectionBackfillJob.fromRow(badTimestamp),
          throwsA(isA<StateError>()),
        );
        final badAttempt = _row()..['attempt_count'] = 'three';
        expect(
          () => FirstConnectionBackfillJob.fromRow(badAttempt),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'fromRow accepts ISO-8601 string timestamps from drivers that do '
      'not auto-coerce timestamptz, and normalizes them to UTC',
      () {
        final row = _row()
          ..['window_start'] = '2026-03-07T12:00:00Z'
          ..['window_end'] = '2026-05-06T12:00:00Z'
          ..['created_at'] = '2026-05-06T12:00:00Z'
          ..['updated_at'] = '2026-05-06T12:00:00Z'
          ..['claimed_at'] = '2026-05-06T11:30:00Z';
        final job = FirstConnectionBackfillJob.fromRow(row);
        expect(job.windowStart.isUtc, isTrue);
        expect(job.windowEnd.isUtc, isTrue);
        expect(job.claimedAt!.isUtc, isTrue);
        expect(job.windowStart, equals(DateTime.utc(2026, 3, 7, 12)));
      },
    );

    test(
      'normalizes non-UTC DateTime inputs in the model constructor so the '
      'parameter binding step always sees UTC even when callers pass local',
      () {
        final localCreatedAt = DateTime(2026, 5, 6, 8);
        final job = FirstConnectionBackfillJob(
          jobId: '99999999-9999-9999-9999-999999999999',
          operatorId: _op,
          locationId: _loc,
          connectionId: _connection,
          vendorId: 'square',
          category: IntegrationCategory.pos,
          windowStart: DateTime.utc(2026, 3, 7, 12),
          windowEnd: DateTime.utc(2026, 5, 6, 12),
          status: FirstConnectionBackfillJobStatus.pending,
          attemptCount: 0,
          createdAt: localCreatedAt,
          updatedAt: localCreatedAt,
        );
        expect(job.createdAt.isUtc, isTrue);
        expect(job.updatedAt.isUtc, isTrue);
        expect(job.createdAt, equals(localCreatedAt.toUtc()));
      },
    );
  });
}

FirstConnectionBackfillJob _job({
  String jobId = '99999999-9999-9999-9999-999999999999',
  String operatorId = _op,
  String locationId = _loc,
  String connectionId = _connection,
  String vendorId = 'square',
  IntegrationCategory category = IntegrationCategory.pos,
  String? cursorToken,
  String? workerId,
  int attemptCount = 0,
}) {
  return FirstConnectionBackfillJob(
    jobId: jobId,
    operatorId: operatorId,
    locationId: locationId,
    connectionId: connectionId,
    vendorId: vendorId,
    category: category,
    windowStart: DateTime.utc(2026, 3, 7, 12),
    windowEnd: DateTime.utc(2026, 5, 6, 12),
    status: FirstConnectionBackfillJobStatus.pending,
    cursorToken: cursorToken,
    attemptCount: attemptCount,
    workerId: workerId,
    createdAt: DateTime.utc(2026, 5, 6, 12),
    updatedAt: DateTime.utc(2026, 5, 6, 12),
  );
}

Map<String, Object?> _row({
  String category = 'pos',
  String status = 'pending',
  String? cursorToken,
  DateTime? lastModifiedSeen,
  String? workerId,
  DateTime? claimedAt,
}) {
  return <String, Object?>{
    'job_id': '99999999-9999-9999-9999-999999999999',
    'operator_id': _op,
    'location_id': _loc,
    'connection_id': _connection,
    'vendor_id': 'adp_workforce_now',
    'category': category,
    'window_start': DateTime.utc(2026, 3, 7, 12),
    'window_end': DateTime.utc(2026, 5, 6, 12),
    'status': status,
    'cursor_token': cursorToken,
    'last_modified_seen': lastModifiedSeen,
    'attempt_count': 1,
    'worker_id': workerId,
    'claimed_at': claimedAt,
    'completed_at': null,
    'last_error': null,
    'created_at': DateTime.utc(2026, 5, 6, 12),
    'updated_at': DateTime.utc(2026, 5, 6, 12),
  };
}
