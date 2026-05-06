// Phase 11W.5 - Operator Web audit log demo gateway.
//
// In-memory implementation of [WebTeamAuditLogGateway] that the
// operator-web shell binds when `OPERATOR_WEB_DEMO_AUTH=true`. Reads
// the shared fixture set at [demo_team_fixtures.dart] so the
// `/audit-log` walkthrough sees the same operator + members set the
// `/members` walkthrough does.
//
// Mutations made during a walkthrough (CSV export writes its own
// `audit.export.requested` row) live on this instance only - page
// reload resets to the fixture defaults. Idempotency-key replays of
// the same export return the cached payload, mirroring the proxy
// `proxy_requests` UNIQUE-key replay semantics.

import 'dart:async';

import 'demo_team_fixtures.dart';
import 'web_team_audit_log_gateway.dart';

/// In-memory demo gateway. Constructs from the shared fixture set
/// declared in [demo_team_fixtures.dart].
class DemoWebTeamAuditLogGateway implements WebTeamAuditLogGateway {
  /// Defaults [actorUserId] to the demo owner so the walkthrough sees
  /// every fixture row (the proxy clamps to the calling user, but the
  /// fixture is owner-scoped). Tests pass an explicit id to pin which
  /// rows the gateway returns.
  DemoWebTeamAuditLogGateway({
    String? actorUserId,
    DateTime? clock,
  })  : _actorUserId = actorUserId ?? 'demo-user-owner',
        _clock = clock {
    for (final fixture in kDemoAuditLogEntriesFixture) {
      _entries.add(_entryFromFixture(fixture));
    }
    _entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  final String _actorUserId;

  /// Optional clock for tests so the time-window filter assertions
  /// stay deterministic. Falls back to `DateTime.now()` when null.
  final DateTime? _clock;

  final List<WebAuditLogEntry> _entries = <WebAuditLogEntry>[];

  /// Cached responses keyed by the screen-minted idempotency key, so
  /// a re-submission of the same export returns the original payload.
  final Map<String, WebAuditLogCsvExport> _idempotency =
      <String, WebAuditLogCsvExport>{};

  @override
  Future<WebAuditLogPage> listEntries(WebAuditLogQuery query) async {
    final filtered = _filtered(query).toList(growable: false);
    final start = decodeAuditLogCursor(query.cursor);
    final end = (start + query.limit).clamp(0, filtered.length);
    final pageEntries = filtered.sublist(start.clamp(0, filtered.length), end);
    final hasMore = end < filtered.length;
    return WebAuditLogPage(
      entries: List<WebAuditLogEntry>.unmodifiable(pageEntries),
      nextCursor: hasMore ? encodeAuditLogCursor(end) : null,
    );
  }

  @override
  Future<WebAuditLogCsvExport> exportCsv(
    WebAuditLogQuery query, {
    required String idempotencyKey,
  }) async {
    final cached = _idempotency[idempotencyKey];
    if (cached != null) return cached;
    final filtered = _filtered(query).toList(growable: false);
    final csv = renderAuditLogCsv(filtered);
    final filename =
        defaultAuditLogCsvFilename(_clock?.toUtc() ?? DateTime.now().toUtc());
    final result = WebAuditLogCsvExport(csv: csv, filename: filename);
    _idempotency[idempotencyKey] = result;
    // Per the parity contract: every export writes its own audit row
    // (`audit.export.requested`) so the export is itself audited. Demo
    // gateway appends to the in-memory ledger so the walkthrough's
    // post-export refresh shows the new row.
    final exportedAt = _clock?.toUtc() ?? DateTime.now().toUtc();
    _entries.insert(
      0,
      WebAuditLogEntry(
        entryId: 'demo-audit-export-$idempotencyKey',
        action: WebAuditLogActions.auditExportRequested,
        actorKind: WebAuditLogActorKind.teamMember,
        createdAt: exportedAt,
        actorUserId: _actorUserId,
        actorDisplayName: 'Sam Patel',
        actorEmail: 'sam.owner@demobistro.test',
        targetKind: 'audit_log_export',
        targetId: filename,
        payload: <String, Object?>{
          'row_count': filtered.length,
          'idempotency_key': idempotencyKey,
        },
      ),
    );
    return result;
  }

  Iterable<WebAuditLogEntry> _filtered(WebAuditLogQuery query) {
    Iterable<WebAuditLogEntry> rows = _entries;

    final from = _resolveFrom(query);
    final to = _resolveTo(query);
    if (from != null) {
      rows = rows.where((row) => !row.createdAt.toUtc().isBefore(from));
    }
    if (to != null) {
      rows = rows.where((row) => !row.createdAt.toUtc().isAfter(to));
    }

    if (query.actorUserIds.isNotEmpty) {
      final ids = Set<String>.from(query.actorUserIds);
      rows = rows.where(
        (row) => row.actorUserId != null && ids.contains(row.actorUserId),
      );
    }

    if (query.actions.isNotEmpty) {
      final actions = Set<String>.from(query.actions);
      rows = rows.where((row) => actions.contains(row.action));
    }

    if (query.actorKinds.isNotEmpty) {
      final kinds = Set<WebAuditLogActorKind>.from(query.actorKinds);
      rows = rows.where((row) => kinds.contains(row.actorKind));
    }

    final targetKind = query.targetKind?.trim();
    if (targetKind != null && targetKind.isNotEmpty) {
      final lower = targetKind.toLowerCase();
      rows = rows.where(
        (row) =>
            row.targetKind != null &&
            row.targetKind!.toLowerCase().contains(lower),
      );
    }

    final targetId = query.targetId?.trim();
    if (targetId != null && targetId.isNotEmpty) {
      final lower = targetId.toLowerCase();
      rows = rows.where(
        (row) =>
            row.targetId != null && row.targetId!.toLowerCase().contains(lower),
      );
    }

    return rows;
  }

  DateTime? _resolveFrom(WebAuditLogQuery query) {
    final now = _clock?.toUtc() ?? DateTime.now().toUtc();
    switch (query.timeWindow) {
      case WebAuditLogTimeWindow.last24h:
        return now.subtract(const Duration(hours: 24));
      case WebAuditLogTimeWindow.last7d:
        return now.subtract(const Duration(days: 7));
      case WebAuditLogTimeWindow.last30d:
        return now.subtract(const Duration(days: 30));
      case WebAuditLogTimeWindow.last90d:
        return now.subtract(const Duration(days: 90));
      case WebAuditLogTimeWindow.custom:
        return query.customFrom?.toUtc();
    }
  }

  DateTime? _resolveTo(WebAuditLogQuery query) {
    switch (query.timeWindow) {
      case WebAuditLogTimeWindow.last24h:
      case WebAuditLogTimeWindow.last7d:
      case WebAuditLogTimeWindow.last30d:
      case WebAuditLogTimeWindow.last90d:
        return null;
      case WebAuditLogTimeWindow.custom:
        return query.customTo?.toUtc();
    }
  }

  WebAuditLogEntry _entryFromFixture(DemoAuditLogEntryFixture fixture) {
    return WebAuditLogEntry(
      entryId: fixture.entryId,
      action: fixture.action,
      actorKind:
          webAuditLogActorKindFromWire(fixture.actorKind) ??
              WebAuditLogActorKind.teamMember,
      createdAt: DateTime.parse(fixture.createdAtIso).toUtc(),
      actorUserId: fixture.actorUserId,
      actorDisplayName: fixture.actorDisplayName,
      actorEmail: fixture.actorEmail,
      targetKind: fixture.targetKind,
      targetId: fixture.targetId,
      payload: Map<String, Object?>.from(fixture.payload),
      adminReason: fixture.adminReason,
    );
  }

  /// Returns every row currently in the in-memory ledger. Tests use
  /// this to assert that an export wrote its `audit.export.requested`
  /// row.
  List<WebAuditLogEntry> get debugEntries =>
      List<WebAuditLogEntry>.unmodifiable(_entries);
}
