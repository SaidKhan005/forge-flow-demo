// Phase 11W.5 - Operator Web Audit Log screen.
//
// Web parity for the mobile Settings -> Audit Log section. Mounted at
// the `/audit-log` route in the operator-web shell. Renders the
// operator's audit_logs ledger with the locked filter set + cursor
// pagination + row rendering documented in the parity contract
// `§ Audit Log (11W.5 + 11A.14 Audit log tab)`:
//
//   * Filter set (locked):
//       actor       - multi-select user picker (the demo gateway
//                     applies this client-side; the live route will
//                     forward it once the proxy widens).
//       action      - multi-select catalog of canonical action
//                     strings (e.g. team.users.invite).
//       target_kind / target_id  - free-text contains filter.
//       time_window - 24h / 7d / 30d / 90d / custom date range.
//
//   * Pagination: cursor-based, 200 rows / page, sorted by
//                 created_at DESC.
//
//   * Row rendering: created_at in operator-local timezone, actor
//                    (display_name + email + actor_kind chip),
//                    action humanized via WebAuditLogActionLabels,
//                    target (target_kind + target_id with copy
//                    button), View payload toggle.
//
//   * CSV export: gated on `team.audit_log.export`. Pages through
//                 every matching row, hands the rendered CSV body to
//                 the clipboard (operator pastes into a CSV file or
//                 spreadsheet). Demo mode also writes its own
//                 audit.export.requested row so the export-is-
//                 audited rule renders in the walkthrough.
//
// Permission gating mirrors `§ Permission gate cheat sheet`. The
// screen prefers `OperatorWebSession.permissions` (live) when present;
// it falls back to a role-tier set so the demo flavor + bootstrap
// stage of live mode still render.
//
// Wiring honesty: the screen reads through [WebTeamAuditLogGateway]
// which the router binds to either the `package:http` live impl or
// the in-memory demo impl. No dart:io, no sqflite. CSV download is
// surfaced via clipboard (web-safe) + a screen-level callback so
// `11W.5.live` can swap in a Blob-anchor download path without
// touching the screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/permission_keys.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_audit_chain_anchors_gateway_provider.dart';
import '../services/web_audit_log_hierarchy_gateway.dart';
import '../services/web_team_audit_log_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../widgets/audit_log_row.dart';
import '../../theme/app_theme.dart';

/// Permission-key bound for the Audit Log read surface. Live source
/// hydrates from `/v1/auth/permissions/snapshot`. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kAuditLogViewPermissionKey = PermissionKeys.teamAuditLogView;

/// Permission-key bound for the CSV export action. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kAuditLogExportPermissionKey = PermissionKeys.teamAuditLogExport;

/// Roles admitted to the Audit Log read surface when the proxy
/// permission snapshot is not yet hydrated. Authoritative gate is the
/// permission key.
///
/// G7d (spec §2.B/§3): v2 catalog constants. Phantom
/// `'operator_admin'` dropped (folded into `operator_owner`); v1
/// soft-deleted `'operator_manager'` mapped to its v2 constant
/// `roleOperatorGeneralManager` (map, don't drop — migration-window
/// robustness). `location_manager` kept (REAL v2 role).
const Set<String> kAuditLogViewAdmittedRoles = <String>{
  PermissionKeys.roleOperatorOwner,
  PermissionKeys.roleOperatorGeneralManager,
  PermissionKeys.roleLocationManager,
};

/// Roles admitted to the CSV export action when the snapshot is
/// empty. Authoritative gate is `team.audit_log.export`.
///
/// G7d (spec §2.B/§3): phantom `'operator_admin'` dropped.
const Set<String> kAuditLogExportAdmittedRoles = <String>{
  PermissionKeys.roleOperatorOwner,
};

/// Per-page size pinned by the parity contract (Performance Framework).
const int kAuditLogPageSize = 200;

/// Operator Web Audit Log screen.
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.idempotencyKeyFactory,
    this.onCsvReady,
    this.copyToClipboard,
    this.chainAnchorGateway,
    this.chainAnchorClock,
    this.hierarchyGateway,
    this.teamHierarchyGateway,
    this.hierarchyPaneClock,
    this.selectedHierarchyScopeType,
    this.selectedHierarchyOrgUnitId,
    this.selectedHierarchyLocationId,
    this.selectedHierarchyScopeLabel,
  });

  final OperatorWebSession session;
  final WebTeamAuditLogGateway gateway;

  /// Lane B B8.b — hierarchy-filtered audit-log gateway. Optional so
  /// router builds that have not yet wired the gateway (or screens
  /// constructed in isolation by widget tests) keep rendering the
  /// legacy unfiltered surface; when both this and
  /// [teamHierarchyGateway] are non-null the screen renders the
  /// [AuditLogHierarchyFilterPane] sibling alongside the existing
  /// filters.
  final WebAuditLogHierarchyGateway? hierarchyGateway;

  /// Lane B B8.b — team hierarchy gateway used to fetch the
  /// org-unit + location tree the hierarchy pane visualizes. Paired
  /// with [hierarchyGateway] — both required for the pane to render
  /// so the parent screen does not show a half-wired surface.
  final WebTeamHierarchyGateway? teamHierarchyGateway;

  /// Optional clock override for the hierarchy pane (tests pin it so
  /// the default time window is deterministic).
  final DateTime Function()? hierarchyPaneClock;

  /// Scope selected by the Operator Web shell's top dropdown. When
  /// this points at a region/district/location and the hierarchy
  /// gateway is wired, the main audit list reads the scoped gateway
  /// instead of rendering a second hierarchy picker inside the page.
  final WebAuditLogHierarchyScopeType? selectedHierarchyScopeType;
  final String? selectedHierarchyOrgUnitId;
  final String? selectedHierarchyLocationId;
  final String? selectedHierarchyScopeLabel;

  /// Operator Web W4.B - optional gateway driving the chain integrity
  /// badge. When null the badge falls back to the unknown state with
  /// a neutral helper string so the rest of the screen keeps working
  /// (e.g. demo flavors that have not wired the provider yet).
  final OperatorWebAuditChainAnchorsGateway? chainAnchorGateway;

  /// Override for `DateTime.now()` used to compute the "N hours ago"
  /// helper string on the badge. Tests pin the clock so the rendered
  /// helper is deterministic.
  final DateTime Function()? chainAnchorClock;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway on
  /// CSV export.
  final String Function()? idempotencyKeyFactory;

  /// Optional sink the router can wire to a Blob-anchor download in
  /// `11W.5.live`. The screen always copies the CSV body to the
  /// clipboard so the operator has a reliable fallback even when the
  /// router does not provide a downloader.
  final Future<void> Function(WebAuditLogCsvExport export)? onCsvReady;

  /// Override for the clipboard call so tests can pin the CSV body
  /// without reaching into the platform plugin.
  final Future<void> Function(String value)? copyToClipboard;

  bool get _canView {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kAuditLogViewPermissionKey);
    }
    return session.roles.any(kAuditLogViewAdmittedRoles.contains);
  }

  bool get _canExport {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(kAuditLogExportPermissionKey);
    }
    return session.roles.any(kAuditLogExportAdmittedRoles.contains);
  }

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  WebAuditLogQuery _query = const WebAuditLogQuery(
    timeWindow: WebAuditLogTimeWindow.last30d,
    limit: kAuditLogPageSize,
  );

  bool _loading = true;
  bool _loadingMore = false;
  bool _exporting = false;
  String? _loadError;
  String? _exportMessage;
  List<WebAuditLogEntry> _entries = const <WebAuditLogEntry>[];
  String? _nextCursor;
  final Set<String> _expandedEntryIds = <String>{};
  int _refreshGeneration = 0;
  int _idempotencySeq = 0;

  /// Optional client-side action filter the demo gateway applies on
  /// top of the gateway query. Multi-select drives both the `actions`
  /// query field and the `event_kind` query the live route uses for
  /// the coarse server-side bucket.
  Set<String> _selectedActions = <String>{};

  /// Optional actor filter the demo gateway applies client-side. Live
  /// route ignores it for now (proxy clamps to caller).
  Set<String> _selectedActors = <String>{};

  /// Source of unique actors for the picker, derived from the latest
  /// page of results. Refreshes on each load so newly-surfaced actors
  /// show up after a filter change.
  final Map<String, String> _actorPickerCatalog = <String, String>{};

  /// Operator Web W4.B - latest snapshot of the chain anchor health.
  /// Null while the badge is loading. The screen renders an unknown
  /// state when no gateway is wired or when the proxy returns an
  /// error so a transient outage stays neutral.
  OperatorWebAuditChainAnchorSnapshot? _chainAnchorSnapshot;
  bool _chainAnchorLoading = false;
  bool _chainAnchorTransientError = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadChainAnchor();
  }

  @override
  void didUpdateWidget(covariant AuditLogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.hierarchyGateway != widget.hierarchyGateway ||
        oldWidget.selectedHierarchyScopeType !=
            widget.selectedHierarchyScopeType ||
        oldWidget.selectedHierarchyOrgUnitId !=
            widget.selectedHierarchyOrgUnitId ||
        oldWidget.selectedHierarchyLocationId !=
            widget.selectedHierarchyLocationId) {
      unawaited(_refresh());
    }
  }

  Future<void> _loadChainAnchor() async {
    final gateway = widget.chainAnchorGateway;
    if (gateway == null) return;
    setState(() {
      _chainAnchorLoading = true;
      _chainAnchorTransientError = false;
    });
    try {
      final snapshot = await gateway.latest();
      if (!mounted) return;
      setState(() {
        _chainAnchorSnapshot = snapshot;
        _chainAnchorLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _chainAnchorSnapshot = const OperatorWebAuditChainAnchorSnapshot(
          status: OperatorWebAuditChainAnchorStatus.unknown,
        );
        _chainAnchorLoading = false;
        _chainAnchorTransientError = true;
      });
    }
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-audit-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  bool get _usesSelectedHierarchyScope {
    final type = widget.selectedHierarchyScopeType;
    return widget.hierarchyGateway != null &&
        type != null &&
        type != WebAuditLogHierarchyScopeType.operatorWide;
  }

  WebAuditLogHierarchyListCommand _hierarchyCommand({
    String? cursor,
    int? limit,
  }) {
    final query = _query.copyWith(
      actions: _selectedActions.toList(),
      actorUserIds: _selectedActors.toList(),
    );
    return WebAuditLogHierarchyListCommand(
      scopeType:
          widget.selectedHierarchyScopeType ??
          WebAuditLogHierarchyScopeType.operatorWide,
      orgUnitId: widget.selectedHierarchyOrgUnitId,
      locationFilter: widget.selectedHierarchyLocationId,
      from: _resolveFrom(query),
      to: _resolveTo(query),
      actorUserId: query.actorUserIds.length == 1
          ? query.actorUserIds.single
          : null,
      action: query.actions.length == 1 ? query.actions.single : null,
      limit: limit ?? query.limit,
      beforeId: cursor,
    );
  }

  WebAuditLogPage _pageFromHierarchyResult(
    WebAuditLogHierarchyListResult result,
  ) {
    final entries = result.rows
        .map(_entryFromHierarchyRow)
        .where((entry) {
          final query = _query.copyWith(
            actions: _selectedActions.toList(),
            actorUserIds: _selectedActors.toList(),
          );
          if (query.actions.isNotEmpty &&
              !query.actions.contains(entry.action)) {
            return false;
          }
          if (query.actorUserIds.isNotEmpty &&
              !query.actorUserIds.contains(entry.actorUserId)) {
            return false;
          }
          final targetKind = query.targetKind?.trim().toLowerCase();
          if (targetKind != null && targetKind.isNotEmpty) {
            final value = entry.targetKind?.toLowerCase() ?? '';
            if (!value.contains(targetKind)) return false;
          }
          final targetId = query.targetId?.trim().toLowerCase();
          if (targetId != null && targetId.isNotEmpty) {
            final value = entry.targetId?.toLowerCase() ?? '';
            if (!value.contains(targetId)) return false;
          }
          return true;
        })
        .toList(growable: false);
    return WebAuditLogPage(entries: entries, nextCursor: result.nextCursor);
  }

  WebAuditLogEntry _entryFromHierarchyRow(WebAuditLogHierarchyRow row) {
    final actorKind =
        webAuditLogActorKindFromWire(row.actorKind) ??
        WebAuditLogActorKind.teamMember;
    final actorLabel = row.actorPrincipalId ?? row.actorUserId;
    return WebAuditLogEntry(
      entryId: row.id,
      action: row.action,
      actorKind: actorKind,
      createdAt: row.occurredAt,
      actorUserId: row.actorUserId,
      actorDisplayName: actorLabel,
      targetKind: row.targetKind,
      targetId: row.targetId,
      payload: row.payload,
      adminReason: row.adminReason,
    );
  }

  DateTime? _resolveFrom(WebAuditLogQuery query) {
    final now = (widget.hierarchyPaneClock ?? DateTime.now)().toUtc();
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

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _loadError = null;
    });
    try {
      final query = _query.copyWith(
        cursor: null,
        actions: _selectedActions.toList(),
        actorUserIds: _selectedActors.toList(),
      );
      final page = _usesSelectedHierarchyScope
          ? _pageFromHierarchyResult(
              await widget.hierarchyGateway!.listByHierarchy(
                _hierarchyCommand(limit: query.limit),
              ),
            )
          : await widget.gateway.listEntries(query);
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _entries = page.entries;
        _nextCursor = page.nextCursor;
        _loading = false;
        _expandedEntryIds.clear();
        _refreshActorCatalog(page.entries);
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _nextCursor == null) return;
    final generation = _refreshGeneration;
    setState(() {
      _loadingMore = true;
    });
    try {
      final query = _query.copyWith(
        cursor: _nextCursor,
        actions: _selectedActions.toList(),
        actorUserIds: _selectedActors.toList(),
      );
      final page = _usesSelectedHierarchyScope
          ? _pageFromHierarchyResult(
              await widget.hierarchyGateway!.listByHierarchy(
                _hierarchyCommand(cursor: _nextCursor, limit: query.limit),
              ),
            )
          : await widget.gateway.listEntries(query);
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _entries = List<WebAuditLogEntry>.unmodifiable(<WebAuditLogEntry>[
          ..._entries,
          ...page.entries,
        ]);
        _nextCursor = page.nextCursor;
        _loadingMore = false;
        _refreshActorCatalog(page.entries);
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loadingMore = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  Future<void> _exportCsv() async {
    if (_exporting || !widget._canExport) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final export = _usesSelectedHierarchyScope
          ? await _exportSelectedHierarchyScopeCsv()
          : await widget.gateway.exportCsv(
              _query.copyWith(
                cursor: null,
                actions: _selectedActions.toList(),
                actorUserIds: _selectedActors.toList(),
              ),
              idempotencyKey: _nextIdempotencyKey(),
            );
      final clipboard = widget.copyToClipboard ?? _defaultCopy;
      await clipboard(export.csv);
      final downloader = widget.onCsvReady;
      if (downloader != null) {
        await downloader(export);
      }
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = downloader == null
            ? 'Copied audit log CSV to your clipboard. Paste it into a '
                  'spreadsheet to save the export.'
            : 'Downloaded audit log CSV and copied it to your clipboard.';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Audit log CSV ready (${export.filename}).')),
      );
      // The export wrote its own audit.export.requested row server-side,
      // so refresh the page so it surfaces at the top of the ledger.
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = _friendlyExportError(error);
      });
    }
  }

  Future<WebAuditLogCsvExport> _exportSelectedHierarchyScopeCsv() async {
    final gateway = widget.hierarchyGateway!;
    final entries = <WebAuditLogEntry>[];
    String? cursor;
    for (var page = 0; page < 50; page++) {
      final result = await gateway.listByHierarchy(
        _hierarchyCommand(cursor: cursor, limit: kAuditLogPageSize),
      );
      final converted = _pageFromHierarchyResult(result);
      entries.addAll(converted.entries);
      cursor = result.nextCursor;
      if (cursor == null) break;
    }
    final filename = defaultAuditLogCsvFilename(
      (widget.hierarchyPaneClock ?? DateTime.now)(),
    );
    return WebAuditLogCsvExport(
      csv: renderAuditLogCsv(entries),
      filename: filename,
    );
  }

  void _refreshActorCatalog(List<WebAuditLogEntry> entries) {
    for (final row in entries) {
      final id = row.actorUserId;
      if (id == null) continue;
      _actorPickerCatalog[id] = row.actorDisplayName ?? row.actorEmail ?? id;
    }
  }

  void _toggleExpanded(String entryId) {
    setState(() {
      if (_expandedEntryIds.contains(entryId)) {
        _expandedEntryIds.remove(entryId);
      } else {
        _expandedEntryIds.add(entryId);
      }
    });
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamAuditLogError) {
      if (error.isForbidden) {
        return 'You do not have permission to view the audit log for this '
            'operator.';
      }
      return 'Could not load the audit log (${error.code}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load the audit log. Refresh the page or try again '
        'in a moment.';
  }

  String _friendlyExportError(Object error) {
    if (error is WebTeamAuditLogError) {
      return 'Could not export the audit log (${error.code}). Try a '
          'narrower filter and try again.';
    }
    return 'Could not export the audit log. Try a narrower filter and '
        'try again.';
  }

  Future<void> _defaultCopy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
  }

  /// Build a local-day start (00:00:00) from the picked date and then
  /// convert to UTC. Going local->UTC last is intentional: in
  /// timezones west of UTC, building a UTC midnight then comparing
  /// against `created_at` would chop off the early hours of the local
  /// day. Mirrors the mobile audit-log section.
  static DateTime? _startOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(local.year, local.month, local.day).toUtc();
  }

  /// Treats the picked end day as inclusive: builds the local
  /// 23:59:59.999 of the picked date and converts to UTC.
  static DateTime? _endOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(
      local.year,
      local.month,
      local.day,
      23,
      59,
      59,
      999,
    ).toUtc();
  }

  Future<void> _pickCustomRange() async {
    final initialRange = (_query.customFrom != null && _query.customTo != null)
        ? DateTimeRange(
            start: _query.customFrom!.toLocal(),
            end: _query.customTo!.toLocal(),
          )
        : DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 30)),
            end: DateTime.now(),
          );
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: initialRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _query = _query.copyWith(
        timeWindow: WebAuditLogTimeWindow.custom,
        customFrom: _startOfDayUtc(picked.start),
        customTo: _endOfDayUtc(picked.end),
      );
    });
    unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._canView) {
      return const _AuditLogForbiddenSurface(
        key: Key('operator_web_audit_log_forbidden'),
      );
    }
    return SingleChildScrollView(
      key: const Key('operator_web_audit_log_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _AuditLogHeader(
            canExport: widget._canExport,
            exporting: _exporting,
            onExport: _exportCsv,
          ),
          const SizedBox(height: 14),
          AuditLogIntegrityBadge(
            snapshot: _chainAnchorSnapshot,
            isLoading: _chainAnchorLoading,
            transientError: _chainAnchorTransientError,
            now: widget.chainAnchorClock?.call(),
          ),
          const SizedBox(height: 18),
          _AuditLogFilters(
            query: _query,
            selectedActions: _selectedActions,
            selectedActors: _selectedActors,
            actorCatalog: _actorPickerCatalog,
            onTimeWindowChanged: (window) {
              if (window == WebAuditLogTimeWindow.custom) {
                unawaited(_pickCustomRange());
                return;
              }
              setState(() {
                _query = _query.copyWith(
                  timeWindow: window,
                  customFrom: null,
                  customTo: null,
                );
              });
              unawaited(_refresh());
            },
            onCustomRangePick: _pickCustomRange,
            onActionsChanged: (next) {
              setState(() => _selectedActions = next);
              unawaited(_refresh());
            },
            onActorsChanged: (next) {
              setState(() => _selectedActors = next);
              unawaited(_refresh());
            },
            onTargetKindChanged: (value) {
              setState(() {
                _query = _query.copyWith(targetKind: value);
              });
              unawaited(_refresh());
            },
            onTargetIdChanged: (value) {
              setState(() {
                _query = _query.copyWith(targetId: value);
              });
              unawaited(_refresh());
            },
          ),
          const SizedBox(height: 16),
          if (_exportMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _exportMessage!,
                key: const Key('operator_web_audit_log_export_message'),
                style: AppTextStyles.body12(color: AppColors.textPrimary),
              ),
            ),
          if (_loading)
            const _AuditLogLoading()
          else if (_loadError != null)
            _AuditLogError(message: _loadError!, onRetry: _refresh)
          else if (_entries.isEmpty)
            const _AuditLogEmpty()
          else
            _AuditLogList(
              entries: _entries,
              expandedEntryIds: _expandedEntryIds,
              onToggleEntry: _toggleExpanded,
              hasMore: _nextCursor != null,
              loadingMore: _loadingMore,
              onLoadMore: _loadMore,
            ),
        ],
      ),
    );
  }
}

class _AuditLogHeader extends StatelessWidget {
  const _AuditLogHeader({
    required this.canExport,
    required this.exporting,
    required this.onExport,
  });

  final bool canExport;
  final bool exporting;
  final Future<void> Function() onExport;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Icon(
          Icons.fact_check_outlined,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Audit log',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Every change someone made to your team, your roles, your '
                'org tree, and your sign-in security shows up here. Use the '
                'filters to narrow down to a specific action or actor, then '
                'export the result to a CSV when you need a paper trail.',
                key: const Key('operator_web_audit_log_subtitle'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        if (canExport) ...[
          const SizedBox(width: 16),
          OutlinedButton.icon(
            key: const Key('operator_web_audit_log_export_button'),
            onPressed: exporting ? null : () => onExport(),
            icon: exporting
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sunsetDark,
                    ),
                  )
                : const Icon(Icons.file_download_outlined, size: 16),
            label: Text(exporting ? 'Exporting' : 'Export CSV'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              side: const BorderSide(color: AppColors.sunsetDark, width: 1),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ],
    );
  }
}

class _AuditLogFilters extends StatelessWidget {
  const _AuditLogFilters({
    required this.query,
    required this.selectedActions,
    required this.selectedActors,
    required this.actorCatalog,
    required this.onTimeWindowChanged,
    required this.onCustomRangePick,
    required this.onActionsChanged,
    required this.onActorsChanged,
    required this.onTargetKindChanged,
    required this.onTargetIdChanged,
  });

  final WebAuditLogQuery query;
  final Set<String> selectedActions;
  final Set<String> selectedActors;
  final Map<String, String> actorCatalog;
  final ValueChanged<WebAuditLogTimeWindow> onTimeWindowChanged;
  final Future<void> Function() onCustomRangePick;
  final ValueChanged<Set<String>> onActionsChanged;
  final ValueChanged<Set<String>> onActorsChanged;
  final ValueChanged<String?> onTargetKindChanged;
  final ValueChanged<String?> onTargetIdChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_filters'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Filters',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          _TimeWindowChips(
            selected: query.timeWindow,
            customFrom: query.customFrom,
            customTo: query.customTo,
            onChanged: onTimeWindowChanged,
            onPickCustom: onCustomRangePick,
          ),
          const SizedBox(height: 12),
          _ActionPicker(selected: selectedActions, onChanged: onActionsChanged),
          const SizedBox(height: 12),
          if (actorCatalog.isNotEmpty) ...[
            _ActorPicker(
              catalog: actorCatalog,
              selected: selectedActors,
              onChanged: onActorsChanged,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: _TextFilterField(
                  fieldKey: const Key(
                    'operator_web_audit_log_filter_target_kind',
                  ),
                  label: 'Target kind',
                  hint: 'team_user, role, session, org_unit',
                  value: query.targetKind,
                  onChanged: onTargetKindChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TextFilterField(
                  fieldKey: const Key(
                    'operator_web_audit_log_filter_target_id',
                  ),
                  label: 'Target id',
                  hint: 'paste a uuid or stable id',
                  value: query.targetId,
                  onChanged: onTargetIdChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimeWindowChips extends StatelessWidget {
  const _TimeWindowChips({
    required this.selected,
    required this.customFrom,
    required this.customTo,
    required this.onChanged,
    required this.onPickCustom,
  });

  final WebAuditLogTimeWindow selected;
  final DateTime? customFrom;
  final DateTime? customTo;
  final ValueChanged<WebAuditLogTimeWindow> onChanged;
  final Future<void> Function() onPickCustom;

  static const List<(WebAuditLogTimeWindow, String, String)> _options =
      <(WebAuditLogTimeWindow, String, String)>[
        (WebAuditLogTimeWindow.last24h, 'Last 24 hours', '24h'),
        (WebAuditLogTimeWindow.last7d, 'Last 7 days', '7d'),
        (WebAuditLogTimeWindow.last30d, 'Last 30 days', '30d'),
        (WebAuditLogTimeWindow.last90d, 'Last 90 days', '90d'),
      ];

  @override
  Widget build(BuildContext context) {
    final customLabel =
        (selected == WebAuditLogTimeWindow.custom &&
            customFrom != null &&
            customTo != null)
        ? '${_fmt(customFrom!)} to ${_fmt(customTo!)}'
        : 'Custom range';
    return Wrap(
      key: const Key('operator_web_audit_log_filter_time_window'),
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final option in _options)
          _ChoiceChip(
            chipKey: Key('operator_web_audit_log_time_window_${option.$3}'),
            label: option.$2,
            isActive: selected == option.$1,
            onTap: () => onChanged(option.$1),
          ),
        _ChoiceChip(
          chipKey: const Key('operator_web_audit_log_time_window_custom'),
          label: customLabel,
          isActive: selected == WebAuditLogTimeWindow.custom,
          onTap: () => onPickCustom(),
        ),
      ],
    );
  }

  static String _fmt(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _ActionPicker extends StatelessWidget {
  const _ActionPicker({required this.selected, required this.onChanged});

  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Action',
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('operator_web_audit_log_filter_action'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final action in WebAuditLogActions.catalog)
              _ChoiceChip(
                chipKey: Key(
                  'operator_web_audit_log_action_${action.replaceAll('.', '_')}',
                ),
                label: WebAuditLogActionLabels.labelFor(action),
                isActive: selected.contains(action),
                onTap: () {
                  final next = Set<String>.from(selected);
                  if (next.contains(action)) {
                    next.remove(action);
                  } else {
                    next.add(action);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _ActorPicker extends StatelessWidget {
  const _ActorPicker({
    required this.catalog,
    required this.selected,
    required this.onChanged,
  });

  final Map<String, String> catalog;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final actors = catalog.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Actor',
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('operator_web_audit_log_filter_actor'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final entry in actors)
              _ChoiceChip(
                chipKey: Key('operator_web_audit_log_actor_${entry.key}'),
                label: entry.value,
                isActive: selected.contains(entry.key),
                onTap: () {
                  final next = Set<String>.from(selected);
                  if (next.contains(entry.key)) {
                    next.remove(entry.key);
                  } else {
                    next.add(entry.key);
                  }
                  onChanged(next);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _TextFilterField extends StatefulWidget {
  const _TextFilterField({
    required this.fieldKey,
    required this.label,
    required this.hint,
    required this.value,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final String hint;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  State<_TextFilterField> createState() => _TextFilterFieldState();
}

class _TextFilterFieldState extends State<_TextFilterField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value ?? '');
  }

  @override
  void didUpdateWidget(covariant _TextFilterField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.value ?? '') != _controller.text) {
      _controller.text = widget.value ?? '';
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.label,
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        TextField(
          key: widget.fieldKey,
          controller: _controller,
          onSubmitted: (raw) {
            final trimmed = raw.trim();
            widget.onChanged(trimmed.isEmpty ? null : trimmed);
          },
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      ],
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({
    required this.chipKey,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: chipKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.sunset.withValues(alpha: 0.18)
              : AppColors.backgroundMid,
          border: Border.all(
            color: isActive
                ? AppColors.sunset.withValues(alpha: 0.5)
                : AppColors.borderSubtle,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: AppTextStyles.mono11(
            color: isActive ? AppColors.sunsetDark : AppColors.textSecondary,
          ).copyWith(fontWeight: isActive ? FontWeight.w700 : FontWeight.w500),
        ),
      ),
    );
  }
}

class _AuditLogList extends StatelessWidget {
  const _AuditLogList({
    required this.entries,
    required this.expandedEntryIds,
    required this.onToggleEntry,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<WebAuditLogEntry> entries;
  final Set<String> expandedEntryIds;
  final ValueChanged<String> onToggleEntry;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in entries)
            AuditLogRow(
              key: ValueKey('operator_web_audit_log_entry_${entry.entryId}'),
              entry: entry,
              expanded: expandedEntryIds.contains(entry.entryId),
              onTogglePayload: () => onToggleEntry(entry.entryId),
            ),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Center(
                child: TextButton.icon(
                  key: const Key('operator_web_audit_log_load_more'),
                  onPressed: loadingMore ? null : () => onLoadMore(),
                  icon: loadingMore
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.sunsetDark,
                          ),
                        )
                      : const Icon(Icons.expand_more_rounded, size: 16),
                  label: Text(
                    loadingMore ? 'Loading next page' : 'Load next page',
                    style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AuditLogLoading extends StatelessWidget {
  const _AuditLogLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('operator_web_audit_log_loading'),
      child: const Padding(
        padding: EdgeInsets.all(28),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _AuditLogError extends StatelessWidget {
  const _AuditLogError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_error'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Audit log could not load',
            style: AppTextStyles.mono14(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('operator_web_audit_log_retry'),
            onPressed: () => onRetry(),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              side: const BorderSide(color: AppColors.sunsetDark, width: 1),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _AuditLogEmpty extends StatelessWidget {
  const _AuditLogEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_audit_log_empty'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'No audit log entries match the current filters.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }
}

class _AuditLogForbiddenSurface extends StatelessWidget {
  const _AuditLogForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Audit log is not available for this account',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'The Audit Log shows every change someone made to your '
                'team, your roles, and your sign-in security. Operator '
                'owners and managers see it from the web console; line '
                'staff stay on the mobile app.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Operator Web W4.B - chain integrity badge rendered above the
/// filter strip on the Audit Log screen. Mirrors the F&F Ops Console
/// chain-integrity rendering in `lib/admin/screens/health_admin_screen.dart`
/// but scoped to one operator: the daily 02:00 UTC sweep stamps an
/// anchor row in `audit_chain_anchors`; this badge surfaces the most
/// recent stamp's freshness so operators can see whether their own
/// audit log integrity is intact.
///
/// States:
///   * Healthy - "Anchored at 02:00 UTC. Last anchor N hours ago."
///   * Delayed - "Anchor delayed - last anchor was N hours ago."
///   * Failed  - "Anchor failed - F and F support is investigating."
///   * Unknown - "No anchor recorded yet - daily anchoring runs at
///                02:00 UTC." (when no gateway is wired or when no
///                anchor row exists for the operator)
class AuditLogIntegrityBadge extends StatelessWidget {
  const AuditLogIntegrityBadge({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.transientError,
    this.now,
  });

  final OperatorWebAuditChainAnchorSnapshot? snapshot;
  final bool isLoading;
  final bool transientError;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final state = _resolveState();
    return Container(
      key: const Key('operator_web_audit_log_integrity_badge'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: state.background,
        border: Border.all(color: state.border, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(state.icon, size: 18, color: state.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  state.title,
                  key: Key(
                    'operator_web_audit_log_integrity_badge_${state.wireKey}_title',
                  ),
                  style: AppTextStyles.mono12(
                    color: state.foreground,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  state.body,
                  key: Key(
                    'operator_web_audit_log_integrity_badge_${state.wireKey}_body',
                  ),
                  style: AppTextStyles.body12(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _BadgeStyle _resolveState() {
    if (isLoading) {
      return const _BadgeStyle(
        wireKey: 'loading',
        title: 'Checking audit chain integrity',
        body: 'Loading the most recent anchor for your operator.',
        foreground: AppColors.sunsetDark,
        background: AppColors.backgroundSurface,
        border: AppColors.borderSubtle,
        icon: Icons.hourglass_top_outlined,
      );
    }
    final resolved = snapshot;
    if (resolved == null) {
      return const _BadgeStyle(
        wireKey: 'unknown',
        title: 'Audit chain status unknown',
        body:
            'No anchor recorded yet. Daily anchoring runs at 02:00 UTC and '
            'this badge updates as soon as the first sweep lands.',
        foreground: AppColors.textSecondary,
        background: AppColors.backgroundSurface,
        border: AppColors.borderSubtle,
        icon: Icons.help_outline,
      );
    }
    final reference = (now ?? DateTime.now()).toUtc();
    final anchored = resolved.lastAnchorBlobAt ?? resolved.anchoredAt;
    final ageLabel = anchored == null
        ? null
        : _humanizeAge(reference.difference(anchored));
    switch (resolved.status) {
      case OperatorWebAuditChainAnchorStatus.healthy:
        return _BadgeStyle(
          wireKey: 'healthy',
          title: 'Audit chain healthy',
          body: ageLabel == null
              ? 'Anchored at 02:00 UTC daily.'
              : 'Anchored at 02:00 UTC. Last anchor $ageLabel ago.',
          foreground: const Color(0xFF1F7A4D),
          background: const Color(0xFFEBF7F0),
          border: const Color(0xFF1F7A4D),
          icon: Icons.verified_outlined,
        );
      case OperatorWebAuditChainAnchorStatus.delayed:
        return _BadgeStyle(
          wireKey: 'delayed',
          title: 'Audit chain delayed',
          body: ageLabel == null
              ? 'Anchor delayed past the daily 02:00 UTC cadence. F and F '
                    'support is monitoring this.'
              : 'Anchor delayed. Last anchor was $ageLabel ago. F and F '
                    'support is monitoring this.',
          foreground: const Color(0xFF8A5A00),
          background: const Color(0xFFFFF4DA),
          border: const Color(0xFFB58300),
          icon: Icons.schedule_outlined,
        );
      case OperatorWebAuditChainAnchorStatus.failed:
        return const _BadgeStyle(
          wireKey: 'failed',
          title: 'Audit chain anchor failed',
          body:
              'Anchor failed. F and F support is investigating. Your audit '
              'log entries are still being recorded; the daily evidence '
              'anchor is what is delayed.',
          foreground: Color(0xFFA8341B),
          background: Color(0xFFFCEEEA),
          border: Color(0xFFA8341B),
          icon: Icons.error_outline,
        );
      case OperatorWebAuditChainAnchorStatus.unknown:
        final transient = transientError;
        return _BadgeStyle(
          wireKey: 'unknown',
          title: transient
              ? 'Audit chain status unavailable'
              : 'Audit chain status unknown',
          body: transient
              ? 'Audit chain status could not load. Refresh the page to try '
                    'again. Daily anchoring runs at 02:00 UTC.'
              : 'No anchor recorded yet. Daily anchoring runs at 02:00 UTC '
                    'and this badge updates as soon as the first sweep lands.',
          foreground: AppColors.textSecondary,
          background: AppColors.backgroundSurface,
          border: AppColors.borderSubtle,
          icon: Icons.help_outline,
        );
    }
  }

  static String _humanizeAge(Duration age) {
    final seconds = age.inSeconds;
    if (seconds < 60) {
      return seconds <= 1 ? '1 second' : '$seconds seconds';
    }
    final minutes = age.inMinutes;
    if (minutes < 60) {
      return minutes == 1 ? '1 minute' : '$minutes minutes';
    }
    final hours = age.inHours;
    if (hours < 48) {
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    final days = age.inDays;
    return days == 1 ? '1 day' : '$days days';
  }
}

class _BadgeStyle {
  const _BadgeStyle({
    required this.wireKey,
    required this.title,
    required this.body,
    required this.foreground,
    required this.background,
    required this.border,
    required this.icon,
  });

  final String wireKey;
  final String title;
  final String body;
  final Color foreground;
  final Color background;
  final Color border;
  final IconData icon;
}
