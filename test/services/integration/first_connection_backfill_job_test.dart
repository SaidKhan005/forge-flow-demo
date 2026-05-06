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
