import 'integration_adapter_common.dart';

const Duration kFirstConnectionBackfillMaxWindow = Duration(days: 60);

enum FirstConnectionBackfillJobStatus { pending, running, succeeded, failed }

extension FirstConnectionBackfillJobStatusWire
    on FirstConnectionBackfillJobStatus {
  String get wire {
    switch (this) {
      case FirstConnectionBackfillJobStatus.pending:
        return 'pending';
      case FirstConnectionBackfillJobStatus.running:
        return 'running';
      case FirstConnectionBackfillJobStatus.succeeded:
        return 'succeeded';
      case FirstConnectionBackfillJobStatus.failed:
        return 'failed';
    }
  }

  static FirstConnectionBackfillJobStatus fromWire(String value) {
    for (final status in FirstConnectionBackfillJobStatus.values) {
      if (status.wire == value) return status;
    }
    throw ArgumentError.value(
      value,
      'value',
      'unknown first connection backfill job status',
    );
  }
}

extension FirstConnectionBackfillCategoryWire on IntegrationCategory {
  String get backfillWire {
    switch (this) {
      case IntegrationCategory.pos:
        return 'pos';
      case IntegrationCategory.labor:
        return 'labor';
      case IntegrationCategory.reservation:
        return 'reservation';
    }
  }

  static IntegrationCategory fromWire(String value) {
    switch (value) {
      case 'pos':
        return IntegrationCategory.pos;
      case 'labor':
        return IntegrationCategory.labor;
      case 'reservation':
        return IntegrationCategory.reservation;
    }
    throw ArgumentError.value(value, 'value', 'unknown integration category');
  }
}

class FirstConnectionBackfillWindow {
  FirstConnectionBackfillWindow({
    required DateTime windowStart,
    required DateTime windowEnd,
  }) : windowStart = windowStart.toUtc(),
       windowEnd = windowEnd.toUtc() {
    _validateWindow(this.windowStart, this.windowEnd);
  }

  factory FirstConnectionBackfillWindow.lastSixtyDays(DateTime now) {
    final end = now.toUtc();
    return FirstConnectionBackfillWindow(
      windowStart: end.subtract(kFirstConnectionBackfillMaxWindow),
      windowEnd: end,
    );
  }

  final DateTime windowStart;
  final DateTime windowEnd;
}

class FirstConnectionBackfillJob {
  FirstConnectionBackfillJob({
    required this.jobId,
    required this.operatorId,
    required this.locationId,
    required this.connectionId,
    required this.vendorId,
    required this.category,
    required DateTime windowStart,
    required DateTime windowEnd,
    required this.status,
    this.cursorToken,
    DateTime? lastModifiedSeen,
    required this.attemptCount,
    this.workerId,
    DateTime? claimedAt,
    DateTime? completedAt,
    this.lastError,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) : windowStart = windowStart.toUtc(),
       windowEnd = windowEnd.toUtc(),
       lastModifiedSeen = lastModifiedSeen?.toUtc(),
       claimedAt = claimedAt?.toUtc(),
       completedAt = completedAt?.toUtc(),
       createdAt = createdAt.toUtc(),
       updatedAt = updatedAt.toUtc() {
    _requireNonBlank('jobId', jobId);
    _requireNonBlank('operatorId', operatorId);
    _requireNonBlank('locationId', locationId);
    _requireNonBlank('connectionId', connectionId);
    _requireNonBlank('vendorId', vendorId);
    if (cursorToken != null && cursorToken!.trim().isEmpty) {
      throw ArgumentError.value(
        cursorToken,
        'cursorToken',
        'must be null or non-blank',
      );
    }
    if (workerId != null && workerId!.trim().isEmpty) {
      throw ArgumentError.value(
        workerId,
        'workerId',
        'must be null or non-blank',
      );
    }
    if (attemptCount < 0) {
      throw ArgumentError.value(
        attemptCount,
        'attemptCount',
        'must not be negative',
      );
    }
    _validateWindow(this.windowStart, this.windowEnd);
  }

  factory FirstConnectionBackfillJob.fromRow(Map<String, Object?> row) {
    return FirstConnectionBackfillJob(
      jobId: _string(row, 'job_id'),
      operatorId: _string(row, 'operator_id'),
      locationId: _string(row, 'location_id'),
      connectionId: _string(row, 'connection_id'),
      vendorId: _string(row, 'vendor_id'),
      category: FirstConnectionBackfillCategoryWire.fromWire(
        _string(row, 'category'),
      ),
      windowStart: _dateTime(row, 'window_start'),
      windowEnd: _dateTime(row, 'window_end'),
      status: FirstConnectionBackfillJobStatusWire.fromWire(
        _string(row, 'status'),
      ),
      cursorToken: _nullableString(row, 'cursor_token'),
      lastModifiedSeen: _nullableDateTime(row, 'last_modified_seen'),
      attemptCount: _int(row, 'attempt_count'),
      workerId: _nullableString(row, 'worker_id'),
      claimedAt: _nullableDateTime(row, 'claimed_at'),
      completedAt: _nullableDateTime(row, 'completed_at'),
      lastError: _nullableString(row, 'last_error'),
      createdAt: _dateTime(row, 'created_at'),
      updatedAt: _dateTime(row, 'updated_at'),
    );
  }

  final String jobId;
  final String operatorId;
  final String locationId;
  final String connectionId;
  final String vendorId;
  final IntegrationCategory category;
  final DateTime windowStart;
  final DateTime windowEnd;
  final FirstConnectionBackfillJobStatus status;
  final String? cursorToken;
  final DateTime? lastModifiedSeen;
  final int attemptCount;
  final String? workerId;
  final DateTime? claimedAt;
  final DateTime? completedAt;
  final String? lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive =>
      status == FirstConnectionBackfillJobStatus.pending ||
      status == FirstConnectionBackfillJobStatus.running;
}

void _validateWindow(DateTime windowStart, DateTime windowEnd) {
  if (!windowEnd.isAfter(windowStart)) {
    throw ArgumentError.value(
      windowEnd,
      'windowEnd',
      'must be after windowStart',
    );
  }
  if (windowEnd.difference(windowStart) > kFirstConnectionBackfillMaxWindow) {
    throw ArgumentError.value(
      windowEnd,
      'windowEnd',
      'must be within the bounded 60-day first-backfill window',
    );
  }
}

void _requireNonBlank(String name, String value) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, name, 'must be non-blank');
  }
}

String _string(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw StateError('first backfill job row has malformed $key');
}

String? _nullableString(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value == null) return null;
  if (value is String && value.trim().isNotEmpty) return value;
  throw StateError('first backfill job row has malformed $key');
}

DateTime _dateTime(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is DateTime) return value.toUtc();
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  throw StateError('first backfill job row has malformed $key');
}

DateTime? _nullableDateTime(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String && value.trim().isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  throw StateError('first backfill job row has malformed $key');
}

int _int(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is int) return value;
  if (value is num && value % 1 == 0) return value.toInt();
  throw StateError('first backfill job row has malformed $key');
}
