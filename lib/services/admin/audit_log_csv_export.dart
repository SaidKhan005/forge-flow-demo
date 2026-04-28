// Phase 9.9 - Audit log CSV export.
//
// Every export emits a `admin.audit_log.export` audit event of its
// own per the locked decision. The pattern is:
//
//   final result = AuditLogCsvExport.export(
//     rows: rows,
//     actorUserId: actor.userId,
//     filters: filters,
//     now: DateTime.now,
//   );
//   await auditSink.record(result.exportEvent);
//   return result.csvBody;
//
// The proxy uses [AuditLogCsvExport] inside a forge_admin BYPASSRLS
// transaction (the same audit log holds the per-tenant audit rows
// AND the export-meta event; both write through service_role
// INSERT-only).
//
// CSV encoding follows RFC 4180: comma separator, CRLF row
// terminator, double-quoted fields when they contain commas,
// double-quotes, or line breaks; embedded double-quotes escaped as
// `""`. The header row matches the column order in [AuditLogRow.toJson].

import '../auth/brute_force_telemetry.dart';

class AuditLogRow {
  const AuditLogRow({
    required this.eventId,
    required this.occurredAt,
    required this.eventType,
    this.actorUserId,
    this.targetUserId,
    this.operatorId,
    this.locationId,
    this.ip,
    this.userAgent,
    this.geoCountry,
    this.requestId,
    this.payload = const <String, Object?>{},
  });

  final String eventId;
  final DateTime occurredAt;
  final String eventType;
  final String? actorUserId;
  final String? targetUserId;
  final String? operatorId;
  final String? locationId;
  final String? ip;
  final String? userAgent;
  final String? geoCountry;
  final String? requestId;
  final Map<String, Object?> payload;
}

class AuditLogExportFilters {
  const AuditLogExportFilters({
    this.operatorId,
    this.actorUserId,
    this.eventType,
    this.fromInclusive,
    this.toExclusive,
  });

  final String? operatorId;
  final String? actorUserId;
  final String? eventType;
  final DateTime? fromInclusive;
  final DateTime? toExclusive;

  Map<String, Object?> toAuditPayload() => <String, Object?>{
    if (operatorId != null) 'operator_id': operatorId,
    if (actorUserId != null) 'actor_user_id': actorUserId,
    if (eventType != null) 'event_type': eventType,
    if (fromInclusive != null)
      'from_inclusive': fromInclusive!.toUtc().toIso8601String(),
    if (toExclusive != null)
      'to_exclusive': toExclusive!.toUtc().toIso8601String(),
  };
}

class AuditLogExportResult {
  const AuditLogExportResult({
    required this.csvBody,
    required this.rowCount,
    required this.exportEvent,
  });

  final String csvBody;
  final int rowCount;

  /// The `admin.audit_log.export` event the proxy must persist
  /// before / alongside returning the CSV body. Captures the actor,
  /// the filter set, the row count, and the request_id (if the
  /// proxy passed one).
  final BruteForceTelemetryEvent exportEvent;
}

abstract class AuditLogCsvExport {
  AuditLogCsvExport._();

  static const String _header =
      'event_id,occurred_at,event_type,actor_user_id,target_user_id,'
      'operator_id,location_id,ip,user_agent,geo_country,request_id,payload';

  /// Encodes [rows] as CSV and returns a bundle that includes the
  /// audit event the proxy must record.
  static AuditLogExportResult export({
    required Iterable<AuditLogRow> rows,
    required String actorUserId,
    required String? actorOperatorId,
    required AuditLogExportFilters filters,
    required DateTime now,
    String? requestId,
  }) {
    final buffer = StringBuffer()..writeln(_header);
    var count = 0;
    for (final row in rows) {
      buffer.writeln(_encodeRow(row));
      count += 1;
    }
    final exportEvent = BruteForceTelemetryEvent(
      eventType: 'admin.audit_log.export',
      occurredAt: now.toUtc(),
      actorUserId: actorUserId,
      operatorId: actorOperatorId,
      requestId: requestId,
      payload: <String, Object?>{
        'row_count': count,
        'filters': filters.toAuditPayload(),
      },
    );
    return AuditLogExportResult(
      csvBody: buffer.toString(),
      rowCount: count,
      exportEvent: exportEvent,
    );
  }

  static String _encodeRow(AuditLogRow row) {
    return <String>[
      _csvField(row.eventId),
      _csvField(row.occurredAt.toUtc().toIso8601String()),
      _csvField(row.eventType),
      _csvField(row.actorUserId),
      _csvField(row.targetUserId),
      _csvField(row.operatorId),
      _csvField(row.locationId),
      _csvField(row.ip),
      _csvField(row.userAgent),
      _csvField(row.geoCountry),
      _csvField(row.requestId),
      _csvField(_payloadToJson(row.payload)),
    ].join(',');
  }

  static String _csvField(Object? value) {
    if (value == null) return '';
    final s = value.toString();
    if (s.isEmpty) return '';
    final mustQuote = s.contains(',') ||
        s.contains('"') ||
        s.contains('\n') ||
        s.contains('\r');
    if (!mustQuote) return s;
    final escaped = s.replaceAll('"', '""');
    return '"$escaped"';
  }

  static String _payloadToJson(Map<String, Object?> payload) {
    if (payload.isEmpty) return '';
    // Flat sorted-key JSON for determinism — auditors typically
    // grep this column, so canonical ordering helps.
    final keys = payload.keys.toList()..sort();
    final entries = <String>[];
    for (final key in keys) {
      entries.add('"$key":${_jsonEncodeValue(payload[key])}');
    }
    return '{${entries.join(',')}}';
  }

  static String _jsonEncodeValue(Object? value) {
    if (value == null) return 'null';
    if (value is num || value is bool) return value.toString();
    if (value is List) {
      final items = value.map(_jsonEncodeValue).join(',');
      return '[$items]';
    }
    if (value is Map) {
      final mapped = <String>[];
      final keys = value.keys.toList()..sort();
      for (final key in keys) {
        mapped.add('"$key":${_jsonEncodeValue(value[key])}');
      }
      return '{${mapped.join(',')}}';
    }
    final s = value.toString();
    final escaped = s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }
}
