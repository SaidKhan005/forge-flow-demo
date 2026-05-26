// Phase 11A.14 - F&F Operations Console "Audit log" surface.
//
// Cross-operator audit-log review. Mounted in the admin shell at
// `/admin/audited-support-actions`. The shell passes the shared
// Operations operator context when one exists; the picker is only
// opened when the admin needs to choose or change operator.
//
// The rendered UX intentionally matches the operator-web audit log:
// scoped rows, row-derived filters, payload expansion, and CSV export
// gated on `admin.audit_log.export`.
//
// Authority:
//
//   * docs/contracts/team_roles_hierarchy_console_parity_contract.md
//     § Audit Log + § Security (admin paths) + § Audit-row shape +
//     § Idempotency keys.
//   * docs/contracts/auth_permission_key_catalog.md - the new
//     `admin.users.reset_mfa_factors` row mirrored in lockstep with
//     this slice.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../operator_web/services/web_team_audit_log_gateway.dart'
    as operator_audit;
import '../../operator_web/widgets/audit_log_row.dart'
    as operator_audit_widgets;
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../admin_visual_system.dart';
import '../services/admin_audit_chain_anchors_gateway.dart';
import '../services/audited_support_actions_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/admin_audit_log_integrity_badge.dart';
import 'operator_picker_screen.dart';

class AuditedSupportActionsAdminScreen extends StatefulWidget {
  const AuditedSupportActionsAdminScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    required this.pickedOperator,
    this.editingEnabled = true,
    this.canResetMfaFactors = false,
    this.canIssuePairedErasure = false,
    this.canViewAuditLog = true,
    this.canExportAuditLog = false,
    this.sessionsGateway,
    this.anchorsGateway,
    this.hierarchyScope,
    this.idempotencyKeyFactory,
    this.onCsvReady,
    this.copyToClipboard,
    this.onChangeOperator,
    this.onBackToBusinessAccounts,
    this.anchorBadgeClock,
  });

  final AuditedSupportActionsAdminGateway gateway;
  final String actorUserId;
  final OperatorPickerResult pickedOperator;

  /// Admin audit-integrity badge — READ-ONLY admin/cross-tenant
  /// audit-chain-anchor gateway for the selected operator. When null
  /// (demo / share-preview without a live anchor gateway wired, or any
  /// test that omits it) the badge renders the neutral "unknown" state
  /// and the screen still renders, exactly like the operator-web
  /// null-gateway fallback. Never crashes on a null gateway.
  final AdminAuditChainAnchorsGateway? anchorsGateway;

  /// Mirrors the 11A.12 / 11A.13 pattern: when false, every mutate
  /// affordance is hidden. The gateway also throws
  /// [AuditedSupportActionsForbiddenException] if a non-forge-admin
  /// call reaches the seam, so this is the user-facing layer of a
  /// two-layer defence.
  final bool editingEnabled;

  /// Legacy route flag retained for callers that still pass the old
  /// capability set. The audit-log UX no longer renders action
  /// controls.
  final bool canResetMfaFactors;

  /// Legacy route flag retained for callers that still pass the old
  /// capability set. The audit-log UX no longer renders action
  /// controls.
  final bool canIssuePairedErasure;

  /// Per the parity contract § Audit Log line 147: Audit-log viewing is
  /// gated on `admin.audit_log.view`.
  final bool canViewAuditLog;

  /// Per the parity contract § Audit Log line 147: CSV export is
  /// gated on `admin.audit_log.export`.
  final bool canExportAuditLog;

  /// Legacy route seam. Scope-tree loading happens in the route before
  /// this screen mounts; the audit-log view itself does not render
  /// sessions.
  final RolesHierarchySessionsAdminGateway? sessionsGateway;

  /// Scope selected from the business hierarchy workspace before the
  /// audit-log tile was opened.
  final AdminHierarchyScopeIntent? hierarchyScope;

  final String Function()? idempotencyKeyFactory;

  /// Same CSV handoff shape as the ops Audit Log screen. Admin always
  /// copies the CSV, and the route can add a browser download sink.
  final Future<void> Function(operator_audit.WebAuditLogCsvExport export)?
  onCsvReady;
  final Future<void> Function(String value)? copyToClipboard;

  /// Re-opens the operator picker. Wired by the route shell so the
  /// admin can switch operators without leaving the surface.
  final VoidCallback? onChangeOperator;
  final VoidCallback? onBackToBusinessAccounts;

  /// Admin audit-integrity badge — reference "now" for the badge's
  /// "last anchor N hours ago" age label. Widget tests pin this so the
  /// healthy-snapshot age label is deterministic; production leaves it
  /// null and the badge falls back to `DateTime.now()`.
  @visibleForTesting
  final DateTime Function()? anchorBadgeClock;

  @override
  State<AuditedSupportActionsAdminScreen> createState() =>
      _AuditedSupportActionsAdminScreenState();
}

class _AuditedSupportActionsAdminScreenState
    extends State<AuditedSupportActionsAdminScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  bool _exporting = false;
  String? _loadError;
  String? _exportMessage;

  /// Accumulated rows across pagination cursors. Each `Apply filters`
  /// or refresh resets this to the first page; `Load more` appends.
  List<AuditLogRow> _rows = const <AuditLogRow>[];
  String? _nextCursor;
  // Web parity (audit_log_screen.dart defaults to last30d): open on a
  // fixed window rather than the removed admin-only "Any time" state.
  AuditLogFilters _filters = const AuditLogFilters(
    timeWindow: AuditLogTimeWindow.last30d,
  );
  Set<String> _selectedActions = <String>{};
  Set<String> _selectedActors = <String>{};
  final Set<String> _expandedRowIds = <String>{};
  final Map<String, String> _actorPickerCatalog = <String, String>{};
  int _refreshGeneration = 0;

  /// Admin audit-integrity badge — most-recent anchor snapshot for the
  /// selected operator. Null while loading or when no gateway is wired
  /// (the badge renders the neutral "unknown" state in both cases).
  AdminAuditChainAnchorSnapshot? _anchorSnapshot;
  bool _anchorLoading = false;
  bool _anchorTransientError = false;

  /// Monotonic generation guard so a stale anchor read (after the
  /// operator changes) cannot overwrite a newer one.
  int _anchorGeneration = 0;

  int _idempotencyCounter = 0;

  String _nextIdempotencyKey(String operation) {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return '$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    if (widget.canViewAuditLog) {
      _refresh();
      _loadAnchorBadge();
    } else {
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(AuditedSupportActionsAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GAP B3 — when the upstream workspace pushes a new scope, re-seed
    // the in-screen picker selection so the banner stays consistent.
    // Admin audit-integrity badge — re-read when the selected operator
    // or the wired gateway changes so the badge follows the operator
    // the admin switched to.
    if (!widget.canViewAuditLog) {
      _refreshGeneration += 1;
      _anchorGeneration += 1;
      if (oldWidget.canViewAuditLog) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _loadError = null;
          _rows = const <AuditLogRow>[];
          _nextCursor = null;
          _expandedRowIds.clear();
          _anchorSnapshot = null;
          _anchorLoading = false;
          _anchorTransientError = false;
        });
      }
      return;
    }
    if (!oldWidget.canViewAuditLog) {
      unawaited(_refresh());
      _loadAnchorBadge();
      return;
    }
    if (oldWidget.pickedOperator.operatorId !=
            widget.pickedOperator.operatorId ||
        oldWidget.anchorsGateway != widget.anchorsGateway) {
      _loadAnchorBadge();
    }
    if (oldWidget.pickedOperator.operatorId !=
            widget.pickedOperator.operatorId ||
        oldWidget.gateway != widget.gateway ||
        oldWidget.hierarchyScope?.cacheKey != widget.hierarchyScope?.cacheKey) {
      unawaited(_refresh());
    }
  }

  /// Admin audit-integrity badge — loads the most-recent anchor for the
  /// selected operator. A null gateway leaves the snapshot null so the
  /// badge renders the neutral "unknown" state (never crashes). Any
  /// gateway error maps to the neutral "unavailable" state rather than
  /// "failed", so a transient proxy outage does not alarm the admin.
  Future<void> _loadAnchorBadge() async {
    if (!widget.canViewAuditLog) return;
    final gateway = widget.anchorsGateway;
    final generation = ++_anchorGeneration;
    if (gateway == null) {
      if (!mounted) return;
      setState(() {
        _anchorSnapshot = null;
        _anchorLoading = false;
        _anchorTransientError = false;
      });
      return;
    }
    setState(() {
      _anchorLoading = true;
      _anchorTransientError = false;
    });
    try {
      final snapshot = await gateway.latest(
        operatorId: widget.pickedOperator.operatorId,
      );
      if (!mounted || generation != _anchorGeneration) return;
      setState(() {
        _anchorSnapshot = snapshot;
        _anchorLoading = false;
        _anchorTransientError = false;
      });
    } catch (_) {
      if (!mounted || generation != _anchorGeneration) return;
      setState(() {
        _anchorSnapshot = const AdminAuditChainAnchorSnapshot(
          status: AdminAuditChainAnchorStatus.unknown,
        );
        _anchorLoading = false;
        _anchorTransientError = true;
      });
    }
  }

  Future<void> _refresh() async {
    if (!widget.canViewAuditLog) return;
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _loadError = null;
    });
    try {
      final operatorId = widget.pickedOperator.operatorId;
      final page = await widget.gateway.listAuditLog(
        operatorId: operatorId,
        filters: _effectiveFilters,
        scope: _selectedAuditLogScope,
      );
      if (generation != _refreshGeneration) return;
      if (!mounted) return;
      setState(() {
        _rows = page.rows;
        _nextCursor = page.nextCursor;
        _expandedRowIds.clear();
        _refreshActorCatalog(page.rows);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loadError = _friendlyLoadError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    final generation = _refreshGeneration;
    setState(() {
      _loadingMore = true;
    });
    try {
      final next = await widget.gateway.listAuditLog(
        operatorId: widget.pickedOperator.operatorId,
        filters: _effectiveFilters,
        cursor: cursor,
        scope: _selectedAuditLogScope,
      );
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _rows = <AuditLogRow>[..._rows, ...next.rows];
        _nextCursor = next.nextCursor;
        _loadingMore = false;
        _refreshActorCatalog(next.rows);
      });
    } catch (error) {
      if (!mounted || generation != _refreshGeneration) return;
      setState(() {
        _loadError = _friendlyLoadError(error);
        _loadingMore = false;
      });
    }
  }

  AuditLogFilters get _effectiveFilters => _filters.copyWith(
    actorUserId: null,
    actorUserIds: _selectedActors.toList(),
    actions: _selectedActions.toList(),
    targetKind: null,
    targetId: null,
    actorKinds: const <AuditActorKind>[],
  );

  AuditLogScope? get _selectedAuditLogScope {
    final scope = widget.hierarchyScope;
    if (scope == null) return null;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return AuditLogScope(
          scopeType: AuditLogScopeType.operatorWide,
          locationId: widget.pickedOperator.locationId,
        );
      case AdminHierarchyScopeType.orgUnit:
        return AuditLogScope(
          scopeType: AuditLogScopeType.orgUnit,
          orgUnitId: scope.orgUnitId,
          locationId: widget.pickedOperator.locationId,
        );
      case AdminHierarchyScopeType.location:
        return AuditLogScope(
          scopeType: AuditLogScopeType.location,
          locationFilter: scope.locationId,
          locationId: widget.pickedOperator.locationId,
        );
    }
  }

  void _refreshActorCatalog(List<AuditLogRow> rows) {
    for (final row in rows) {
      final actorId = row.actorUserId.trim();
      if (actorId.isEmpty) continue;
      final displayName = row.actorDisplayName.trim();
      final email = row.actorEmail.trim();
      _actorPickerCatalog[actorId] = displayName.isNotEmpty
          ? displayName
          : email.isNotEmpty
          ? email
          : actorId;
    }
  }

  void _toggleExpanded(String entryId) {
    setState(() {
      if (_expandedRowIds.contains(entryId)) {
        _expandedRowIds.remove(entryId);
      } else {
        _expandedRowIds.add(entryId);
      }
    });
  }

  operator_audit.WebAuditLogEntry _toOperatorAuditEntry(AuditLogRow row) {
    final actorName = row.actorDisplayName.trim();
    final actorEmail = row.actorEmail.trim();
    final targetKind = row.targetKind?.trim() ?? '';
    final targetId = row.targetId?.trim() ?? '';
    return operator_audit.WebAuditLogEntry(
      entryId: row.eventId,
      action: row.action,
      actorKind: _toOperatorActorKind(row.actorKind),
      createdAt: row.occurredAt,
      actorUserId: row.actorUserId.trim().isEmpty ? null : row.actorUserId,
      actorDisplayName: actorName.isEmpty ? null : actorName,
      actorEmail: actorEmail.isEmpty ? null : actorEmail,
      targetKind: targetKind.isEmpty ? null : targetKind,
      targetId: targetId.isEmpty ? null : targetId,
      payload: row.payload,
      adminReason: row.adminReason?.trim().isEmpty == true
          ? null
          : row.adminReason,
    );
  }

  operator_audit.WebAuditLogActorKind _toOperatorActorKind(
    AuditActorKind kind,
  ) {
    switch (kind) {
      case AuditActorKind.teamMember:
        return operator_audit.WebAuditLogActorKind.teamMember;
      case AuditActorKind.forgeAdmin:
        return operator_audit.WebAuditLogActorKind.forgeAdmin;
      case AuditActorKind.servicePrincipal:
        return operator_audit.WebAuditLogActorKind.servicePrincipal;
    }
  }

  static DateTime? _startOfDayUtc(DateTime? day) {
    if (day == null) return null;
    final local = day.toLocal();
    return DateTime(local.year, local.month, local.day).toUtc();
  }

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

  // --- Audit log actions -------------------------------------------------

  void _onTimeWindowChanged(AuditLogTimeWindow window) {
    if (window == AuditLogTimeWindow.customRange) {
      unawaited(_pickCustomRange());
      return;
    }
    setState(() {
      _filters = _filters.copyWith(
        timeWindow: window,
        customRangeFrom: null,
        customRangeTo: null,
      );
    });
    unawaited(_refresh());
  }

  void _onActionsChanged(Set<String> next) {
    setState(() => _selectedActions = next);
    unawaited(_refresh());
  }

  void _onActorsChanged(Set<String> next) {
    setState(() => _selectedActors = next);
    unawaited(_refresh());
  }

  Future<void> _pickCustomRange() async {
    final initialRange =
        (_filters.customRangeFrom != null && _filters.customRangeTo != null)
        ? DateTimeRange(
            start: _filters.customRangeFrom!.toLocal(),
            end: _filters.customRangeTo!.toLocal(),
          )
        : DateTimeRange(
            start: DateTime.now().subtract(const Duration(days: 30)),
            end: DateTime.now(),
          );
    final picked = await showOperatorWebDateRangeDialog(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialRange: initialRange,
      title: 'Choose audit log dates',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _filters = _filters.copyWith(
        timeWindow: AuditLogTimeWindow.customRange,
        customRangeFrom: _startOfDayUtc(picked.start),
        customRangeTo: _endOfDayUtc(picked.end),
      );
    });
    unawaited(_refresh());
  }

  Future<void> _onExportCsv() async {
    if (_exporting || !widget.canExportAuditLog) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
    });
    try {
      final export = await _buildCsvExport();
      final clipboard = widget.copyToClipboard ?? _defaultCopyToClipboard;
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
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = _friendlyExportError(error);
      });
    }
  }

  Future<operator_audit.WebAuditLogCsvExport> _buildCsvExport() async {
    final scope = _selectedAuditLogScope;
    final filename = operator_audit.defaultAuditLogCsvFilename(
      DateTime.now().toUtc(),
    );
    if (scope != null) {
      return _exportSelectedScopeCsv(scope, filename: filename);
    }
    final csv = await widget.gateway.exportAuditLogCsv(
      operatorId: widget.pickedOperator.operatorId,
      filters: _effectiveFilters,
      idempotencyKey: _nextIdempotencyKey('audit-log-export'),
      actorUserId: widget.actorUserId,
      actorIsForgeAdmin: widget.canExportAuditLog,
      adminReason: 'Audit log CSV export',
    );
    return operator_audit.WebAuditLogCsvExport(csv: csv, filename: filename);
  }

  String _friendlyLoadError(Object error) {
    if (error is AuditedSupportActionsForbiddenException) {
      return 'You do not have permission to view the audit log for this '
          'operator.';
    }
    if (error is AuditedSupportActionsGatewayError) {
      return 'Could not load the audit log (${error.errorCode}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load the audit log. Refresh the page or try again '
        'in a moment.';
  }

  String _friendlyExportError(Object error) {
    if (error is AuditedSupportActionsForbiddenException) return error.message;
    if (error is AuditedSupportActionsGatewayError) {
      return 'Could not export the audit log (${error.errorCode}). Try a '
          'narrower filter and try again.';
    }
    return 'Could not export the audit log. Try a narrower filter and '
        'try again.';
  }

  Future<operator_audit.WebAuditLogCsvExport> _exportSelectedScopeCsv(
    AuditLogScope scope, {
    required String filename,
  }) async {
    final entries = <operator_audit.WebAuditLogEntry>[];
    String? cursor;
    for (var page = 0; page < 50; page++) {
      final result = await widget.gateway.listAuditLog(
        operatorId: widget.pickedOperator.operatorId,
        filters: _effectiveFilters,
        cursor: cursor,
        scope: scope,
      );
      entries.addAll(result.rows.map(_toOperatorAuditEntry));
      cursor = result.nextCursor;
      if (cursor == null) break;
    }
    return operator_audit.WebAuditLogCsvExport(
      csv: operator_audit.renderAuditLogCsv(entries),
      filename: filename,
    );
  }

  Future<void> _defaultCopyToClipboard(String value) {
    return Clipboard.setData(ClipboardData(text: value));
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!widget.canViewAuditLog) {
      return const _AdminAuditLogForbiddenSurface(
        key: Key('admin_asa_audit_log_forbidden'),
      );
    }
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_audited_support_actions_screen'),
      maxContentWidth: 1120,
      padding: AdminVisualSystem.screenPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          OperatorWebScreenHeader(
            icon: Icons.fact_check_outlined,
            title: 'Audit log',
            subtitle:
                'Every change someone made to your team, your roles, your '
                'org tree, and your sign-in security shows up here. Use the '
                'filters to narrow down to a specific action or team member, '
                'then export the result to a CSV when you need a paper trail.',
            subtitleKey: const Key('admin_asa_audit_log_subtitle'),
            actions: _buildHeaderActions(),
          ),
          const SizedBox(height: 14),
          // Admin audit-integrity badge — "log is intact" chain-anchor
          // freshness for the selected operator. Fed by the optional
          // anchors gateway; a null gateway leaves the snapshot null so
          // the badge renders the neutral "unknown" state and the
          // screen still renders (never crashes).
          AdminAuditLogIntegrityBadge(
            snapshot: _anchorSnapshot,
            isLoading: _anchorLoading,
            transientError: _anchorTransientError,
            now: widget.anchorBadgeClock?.call(),
          ),
          const SizedBox(height: 18),
          _buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    if (!widget.canExportAuditLog) return const <Widget>[];
    return <Widget>[
      AdminActionButton(
        key: const Key('admin_asa_audit_log_export_button'),
        label: _exporting ? 'Exporting' : 'Export CSV',
        onPressed: _exporting ? null : _onExportCsv,
        icon: _exporting
            ? Icons.hourglass_empty_rounded
            : Icons.file_download_outlined,
      ),
    ];
  }

  Widget _buildBody() {
    // Outer frame is OperatorWebScreenBody (a SingleChildScrollView), so
    // this body returns a plain Column to avoid nesting a second scroll
    // view inside it.
    return Column(
      key: const Key('admin_asa_body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AdminAuditLogFilters(
          filters: _filters,
          selectedActions: _selectedActions,
          selectedActors: _selectedActors,
          actorCatalog: _actorPickerCatalog,
          onTimeWindowChanged: _onTimeWindowChanged,
          onCustomRangePick: _pickCustomRange,
          onActionsChanged: _onActionsChanged,
          onActorsChanged: _onActorsChanged,
        ),
        const SizedBox(height: 16),
        if (_exportMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              _exportMessage!,
              key: const Key('admin_asa_audit_log_export_message'),
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        if (_loading)
          const _AdminAuditLogLoading()
        else if (_loadError != null)
          _AdminAuditLogError(message: _loadError!, onRetry: _refresh)
        else if (_rows.isEmpty)
          const _AdminAuditLogEmpty()
        else
          _AdminAuditLogList(
            entries: _rows.map(_toOperatorAuditEntry).toList(growable: false),
            expandedEntryIds: _expandedRowIds,
            onToggleEntry: _toggleExpanded,
            hasMore: _nextCursor != null,
            loadingMore: _loadingMore,
            onLoadMore: _loadMore,
          ),
      ],
    );
  }
}

class _AdminAuditLogForbiddenSurface extends StatelessWidget {
  const _AdminAuditLogForbiddenSurface({super.key});

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

class _AdminAuditLogFilters extends StatelessWidget {
  const _AdminAuditLogFilters({
    required this.filters,
    required this.selectedActions,
    required this.selectedActors,
    required this.actorCatalog,
    required this.onTimeWindowChanged,
    required this.onCustomRangePick,
    required this.onActionsChanged,
    required this.onActorsChanged,
  });

  final AuditLogFilters filters;
  final Set<String> selectedActions;
  final Set<String> selectedActors;
  final Map<String, String> actorCatalog;
  final ValueChanged<AuditLogTimeWindow> onTimeWindowChanged;
  final Future<void> Function() onCustomRangePick;
  final ValueChanged<Set<String>> onActionsChanged;
  final ValueChanged<Set<String>> onActorsChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_filters'),
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
          _AdminTimeWindowChips(
            selected: filters.timeWindow ?? AuditLogTimeWindow.last30d,
            customFrom: filters.customRangeFrom,
            customTo: filters.customRangeTo,
            onChanged: onTimeWindowChanged,
            onPickCustom: onCustomRangePick,
          ),
          const SizedBox(height: 12),
          _AdminActionPicker(
            selected: selectedActions,
            onChanged: onActionsChanged,
          ),
          const SizedBox(height: 12),
          if (actorCatalog.isNotEmpty) ...[
            _AdminActorPicker(
              catalog: actorCatalog,
              selected: selectedActors,
              onChanged: onActorsChanged,
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _AdminTimeWindowChips extends StatelessWidget {
  const _AdminTimeWindowChips({
    required this.selected,
    required this.customFrom,
    required this.customTo,
    required this.onChanged,
    required this.onPickCustom,
  });

  final AuditLogTimeWindow selected;
  final DateTime? customFrom;
  final DateTime? customTo;
  final ValueChanged<AuditLogTimeWindow> onChanged;
  final Future<void> Function() onPickCustom;

  static const List<(AuditLogTimeWindow, String, String)> _options =
      <(AuditLogTimeWindow, String, String)>[
        (AuditLogTimeWindow.last24h, 'Last 24 hours', '24h'),
        (AuditLogTimeWindow.last7d, 'Last 7 days', '7d'),
        (AuditLogTimeWindow.last30d, 'Last 30 days', '30d'),
        (AuditLogTimeWindow.last90d, 'Last 90 days', '90d'),
      ];

  @override
  Widget build(BuildContext context) {
    final customLabel =
        (selected == AuditLogTimeWindow.customRange &&
            customFrom != null &&
            customTo != null)
        ? '${_fmt(customFrom!)} to ${_fmt(customTo!)}'
        : 'Custom range';
    return Wrap(
      key: const Key('admin_asa_filter_time_window'),
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final option in _options)
          _AdminChoiceChip(
            chipKey: Key('admin_asa_audit_log_time_window_${option.$3}'),
            label: option.$2,
            isActive: selected == option.$1,
            onTap: () => onChanged(option.$1),
          ),
        _AdminChoiceChip(
          chipKey: const Key('admin_asa_audit_log_time_window_custom'),
          label: customLabel,
          isActive: selected == AuditLogTimeWindow.customRange,
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

class _AdminActionPicker extends StatelessWidget {
  const _AdminActionPicker({required this.selected, required this.onChanged});

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
          key: const Key('admin_asa_filter_action'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final action in kAuditLogFilterableActions)
              _AdminChoiceChip(
                chipKey: Key(
                  'admin_asa_audit_log_action_${action.replaceAll('.', '_')}',
                ),
                label: humanizeAuditAction(action),
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

class _AdminActorPicker extends StatelessWidget {
  const _AdminActorPicker({
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
          'Team member',
          style: AppTextStyles.mono11(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        Wrap(
          key: const Key('admin_asa_filter_actor'),
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final entry in actors)
              _AdminChoiceChip(
                chipKey: Key('admin_asa_audit_log_actor_${entry.key}'),
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

class _AdminChoiceChip extends StatelessWidget {
  const _AdminChoiceChip({
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
    return OutlinedButton(
      key: chipKey,
      onPressed: onTap,
      style: AdminButtonStyles.filter(active: isActive),
      child: Text(
        label,
        style: AppTextStyles.mono11(
          color: isActive ? AppColors.sunsetDark : AppColors.textSecondary,
        ).copyWith(fontWeight: isActive ? FontWeight.w700 : FontWeight.w500),
      ),
    );
  }
}

/// GAP B3 — the in-screen audit-log scope picker. Renders the shared
/// [InheritanceTree] (the same widget the operator-web B8.b pane uses)
/// so F&F admins pick a business, region, district, or location by
/// tapping the tree instead of hand-typing operator_id / org_unit_id /
/// location_id. Pure UI over a route-built [InheritanceTreeNode]; no
/// proxy / gateway change.
class _AdminAuditLogList extends StatelessWidget {
  const _AdminAuditLogList({
    required this.entries,
    required this.expandedEntryIds,
    required this.onToggleEntry,
    required this.hasMore,
    required this.loadingMore,
    required this.onLoadMore,
  });

  final List<operator_audit.WebAuditLogEntry> entries;
  final Set<String> expandedEntryIds;
  final ValueChanged<String> onToggleEntry;
  final bool hasMore;
  final bool loadingMore;
  final Future<void> Function() onLoadMore;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_audit_log_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final entry in entries)
            KeyedSubtree(
              key: ValueKey('admin_asa_audit_row_${entry.entryId}'),
              child: operator_audit_widgets.AuditLogRow(
                entry: entry,
                expanded: expandedEntryIds.contains(entry.entryId),
                onTogglePayload: () => onToggleEntry(entry.entryId),
              ),
            ),
          if (hasMore)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Center(
                child: AdminActionButton(
                  key: const Key('admin_asa_audit_log_load_more'),
                  label: loadingMore ? 'Loading next page' : 'Load next page',
                  onPressed: loadingMore ? null : () => onLoadMore(),
                  icon: loadingMore
                      ? Icons.hourglass_empty_rounded
                      : Icons.expand_more_rounded,
                  role: AdminActionRole.quiet,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AdminAuditLogLoading extends StatelessWidget {
  const _AdminAuditLogLoading();

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('admin_asa_audit_log_loading'),
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

class _AdminAuditLogError extends StatelessWidget {
  const _AdminAuditLogError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_audit_log_error'),
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
          AdminActionButton(
            key: const Key('admin_asa_audit_log_retry'),
            label: 'Retry',
            onPressed: () => onRetry(),
            icon: Icons.refresh,
          ),
        ],
      ),
    );
  }
}

class _AdminAuditLogEmpty extends StatelessWidget {
  const _AdminAuditLogEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_audit_log_empty'),
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

// ---------------------------------------------------------------------
// Audit-log shared helpers
// ---------------------------------------------------------------------

/// Common action keys exposed in the audit-log filter chip group.
/// Mirrors the locked vocabulary the slice's writes emit plus the
/// canonical self-service actions seeded in the demo gateway. Defined
/// here so widget tests can pin the chip set against the contract's
/// "action ∈ enum (multi-select)" filter without hard-coding strings
/// in two places.
const List<String> kAuditLogFilterableActions =
    operator_audit.WebAuditLogActions.catalog;

/// Humanize a locked-vocabulary action key. Exposed for widget tests
/// so the parity contract's "action (humanized — ...)" pin can assert
/// the rendering directly.
@visibleForTesting
String humanizeAuditAction(String action) {
  return operator_audit.WebAuditLogActionLabels.labelFor(action);
}
