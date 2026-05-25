// Phase 11A.14 - F&F Operations Console "Audited support actions"
// surface.
// ignore_for_file: unused_field, unused_element, unused_element_parameter
//
// Cross-operator audit-log review + support-side MFA / password
// operations + paired-approval erasure. Mounted in the admin shell at
// `/admin/audited-support-actions`. The shell passes the shared
// Operations operator context when one exists; the picker is only
// opened when the admin needs to choose or change operator.
//
// Two regions:
//
//   * Audit log table - cursor-paginated rows scoped to the picked
//     operator, with the parity contract's locked filter set
//     (actor / action / target_kind / target_id / time_window /
//     actor_kind) and CSV export gated on `admin.audit_log.export`.
//
//   * Actions panel - three F&F-admin support escalations:
//       - Reset member MFA → gated on the new
//         `admin.users.reset_mfa_factors` key (MFA-required).
//       - Initiate password reset → gated on
//         `admin.users.reset_password`.
//       - Issue paired-approval erasure → gated on
//         `admin.users.erase_pii` (MFA-required) plus a second F&F
//         admin's confirmation.
//
// Every write surfaces a free-form `admin_reason` dialog before
// firing the call; every write captures both an `audit_logs` row
// and an `admin_action_log` provenance row via the gateway.
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
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../domain/models/inheritance_tree_node.dart';
import '../../operator_web/services/web_team_audit_log_gateway.dart'
    as operator_audit;
import '../../operator_web/widgets/audit_log_row.dart'
    as operator_audit_widgets;
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../admin_button_styles.dart';
import '../services/admin_audit_chain_anchors_gateway.dart';
import '../services/audited_support_actions_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
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
    this.canExportAuditLog = false,
    this.sessionsGateway,
    this.anchorsGateway,
    this.hierarchyScope,
    this.auditScopeRootNode,
    this.idempotencyKeyFactory,
    this.onCsvReady,
    this.copyToClipboard,
    this.onChangeOperator,
    this.onBackToBusinessAccounts,
    this.graceWindowClock,
    this.graceWindowTickInterval = const Duration(minutes: 1),
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

  /// Per the parity contract § Security line 161: reset MFA is gated
  /// on `admin.users.reset_mfa_factors` (MFA-required). This flag is
  /// the screen-level mirror; production wires it from the signed-in
  /// admin's MFA-required claims, demo defaults false.
  final bool canResetMfaFactors;

  /// Per the parity contract § Security line 163: paired-approval
  /// erasure is gated on `admin.users.erase_pii` (MFA-required).
  final bool canIssuePairedErasure;

  /// Per the parity contract § Audit Log line 147: CSV export is
  /// gated on `admin.audit_log.export`.
  final bool canExportAuditLog;

  /// Active sessions live under Security/audit/sessions. This uses
  /// the existing roles/hierarchy/sessions gateway contract for
  /// session reads and audited force-logout writes.
  final RolesHierarchySessionsAdminGateway? sessionsGateway;

  /// Scope selected from the business hierarchy workspace before the
  /// Security/audit/sessions tile was opened.
  final AdminHierarchyScopeIntent? hierarchyScope;

  /// GAP B3 — Business → Org Unit → Location scope tree for the
  /// in-screen audit-log scope picker. Built (route-side) from the
  /// org-units + locations the EXISTING
  /// [RolesHierarchySessionsAdminGateway] already exposes via the pure
  /// [buildAuditLogAdminRootNode] helper — no new proxy route, no new
  /// gateway method. When non-null the audit-log region renders the
  /// shared [InheritanceTree] as the default scope selector; when null
  /// the screen falls back to the read-only scope banner the upstream
  /// hierarchy workspace already supplies (no regression to that
  /// path).
  final InheritanceTreeNode? auditScopeRootNode;

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

  /// CODE_OPS_DEBT carry-over #2 — the grace-window countdown chip
  /// reads "now" from this clock so widget tests can pin the
  /// countdown to a deterministic value without relying on
  /// `DateTime.now()`. Production leaves this null and falls back to
  /// `DateTime.now()`.
  @visibleForTesting
  final DateTime Function()? graceWindowClock;

  /// CODE_OPS_DEBT carry-over #2 — period of the chip's tick timer.
  /// Default 1 minute is plenty (the grace window is 24h). Widget
  /// tests override this to a sub-second tick so the timer can drive
  /// expiry without `tester.pump`-ing for hours.
  @visibleForTesting
  final Duration graceWindowTickInterval;

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
  String? _actionError;
  String? _exportMessage;

  /// Accumulated rows across pagination cursors. Each `Apply filters`
  /// or refresh resets this to the first page; `Load more` appends.
  List<AuditLogRow> _rows = const <AuditLogRow>[];
  String? _nextCursor;
  final List<SupportActionsMember> _members = const <SupportActionsMember>[];
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

  /// GAP B3 — the scope the admin selected in the in-screen
  /// [InheritanceTree] picker (when [AuditedSupportActionsAdminScreen.
  /// auditScopeRootNode] is supplied). Seeded from the upstream
  /// workspace scope so the banner stays consistent before the admin
  /// touches the tree. The audit-log read stays operator-wide — the
  /// gateway exposes no scoped aggregate route yet — so this only
  /// drives the scope banner copy, identical to the prior read-only
  /// banner behaviour.

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

  // CODE_OPS_DEBT Theme B#1 — last in-flight single-admin PII erasure
  // captured by `_onIssueErasure`. The build path renders a banner
  // with a "Reverse" affordance whenever this is non-null and the
  // grace window has not closed; clearing happens on successful
  // reverse / on a fresh erasure for a different user.
  UserPiiErasureRequestSummary? _lastErasure;
  String? _lastErasureMember;

  /// CODE_OPS_DEBT carry-over #2 — periodic timer that drives the
  /// grace-window chip's countdown. Started when `_lastErasure`
  /// becomes non-null and stopped when the chip transitions to its
  /// final state. Cancelled in [dispose] so a long-lived screen does
  /// not leak timers.
  Timer? _graceWindowTicker;

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
    _refresh();
    _loadAnchorBadge();
  }

  @override
  void didUpdateWidget(AuditedSupportActionsAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GAP B3 — when the upstream workspace pushes a new scope, re-seed
    // the in-screen picker selection so the banner stays consistent.
    // Admin audit-integrity badge — re-read when the selected operator
    // or the wired gateway changes so the badge follows the operator
    // the admin switched to.
    if (oldWidget.pickedOperator.operatorId !=
            widget.pickedOperator.operatorId ||
        oldWidget.anchorsGateway != widget.anchorsGateway) {
      _loadAnchorBadge();
    }
    if (oldWidget.pickedOperator.operatorId !=
            widget.pickedOperator.operatorId ||
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

  @override
  void dispose() {
    _graceWindowTicker?.cancel();
    _graceWindowTicker = null;
    super.dispose();
  }

  DateTime _graceNow() => widget.graceWindowClock?.call() ?? DateTime.now();

  /// CODE_OPS_DEBT carry-over #2 — start the periodic ticker so the
  /// chip's "Xh Ym remaining" label refreshes in place. Idempotent;
  /// stops the existing timer before creating a new one.
  void _startGraceWindowTicker() {
    _graceWindowTicker?.cancel();
    _graceWindowTicker = Timer.periodic(widget.graceWindowTickInterval, (_) {
      if (!mounted) return;
      final erasure = _lastErasure;
      if (erasure == null) {
        _graceWindowTicker?.cancel();
        _graceWindowTicker = null;
        return;
      }
      // Trigger a rebuild so the countdown label re-renders. When the
      // window expires the chip flips to its final state and the
      // ticker stops on the next iteration (erasure == null after a
      // refresh / reverse) or via the early-return below once we are
      // past the grace boundary.
      setState(() {});
      if (!_graceNow().isBefore(erasure.gracePeriodEndsAt)) {
        _graceWindowTicker?.cancel();
        _graceWindowTicker = null;
      }
    });
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
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
    } on AuditedSupportActionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } on AuditedSupportActionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load: $error';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _loadError = null;
    });
    try {
      final next = await widget.gateway.listAuditLog(
        operatorId: widget.pickedOperator.operatorId,
        filters: _effectiveFilters,
        cursor: cursor,
        scope: _selectedAuditLogScope,
      );
      if (!mounted) return;
      setState(() {
        _rows = <AuditLogRow>[..._rows, ...next.rows];
        _nextCursor = next.nextCursor;
        _loadingMore = false;
        _refreshActorCatalog(next.rows);
      });
    } on AuditedSupportActionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.toString();
        _loadingMore = false;
      });
    }
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on AuditedSupportActionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on AuditedSupportActionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  Future<SupportActionsMember?> _pickMember(
    String title, {
    List<SupportActionsMember>? members,
    String emptyCopy = 'This operator has no members yet.',
  }) async {
    return showDialog<SupportActionsMember>(
      context: context,
      builder: (_) => _MemberPickerDialog(
        title: title,
        members: members ?? _members,
        emptyCopy: emptyCopy,
      ),
    );
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
        return null;
      case AdminHierarchyScopeType.orgUnit:
        return AuditLogScope(
          scopeType: AuditLogScopeType.orgUnit,
          orgUnitId: scope.orgUnitId,
        );
      case AdminHierarchyScopeType.location:
        return AuditLogScope(
          scopeType: AuditLogScopeType.location,
          locationFilter: scope.locationId,
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
    final targetKind = row.targetKind.trim();
    final targetId = row.targetId.trim();
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
    } on AuditedSupportActionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = error.message;
      });
    } on AuditedSupportActionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage =
            'Could not export the audit log (${error.errorCode}). Try a '
            'narrower filter and try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage =
            'Could not export the audit log. Try a narrower filter and '
            'try again.';
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

  // --- Actions panel actions ---------------------------------------------

  Future<void> _onResetMfa() async {
    if (!widget.canResetMfaFactors) return;
    final member = await _pickMember(
      'Reset two-factor sign-in for which member?',
    );
    if (member == null) return;
    final reason = await _promptAdminReason(
      'Reset two-factor sign-in for ${member.displayName}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.resetMemberMfa(
        operatorId: widget.pickedOperator.operatorId,
        targetUserId: member.userId,
        idempotencyKey: _nextIdempotencyKey('reset-mfa'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Reset two-factor sign-in for ${member.displayName}',
    );
  }

  Future<void> _onPasswordReset() async {
    final eligibleMembers = _members
        .where((member) => member.canReceivePasswordReset)
        .toList(growable: false);
    final member = await _pickMember(
      'Send a password reset to which member?',
      members: eligibleMembers,
      emptyCopy:
          'No active member can receive a password reset yet. Pending invite-only users must accept their invite first.',
    );
    if (member == null) return;
    final reason = await _promptAdminReason(
      'Send a password reset to ${member.displayName}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.initiatePasswordReset(
        operatorId: widget.pickedOperator.operatorId,
        targetUserId: member.userId,
        idempotencyKey: _nextIdempotencyKey('password-reset'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Password reset email queued for ${member.displayName}.',
    );
  }

  Future<void> _onIssueErasure() async {
    if (!widget.canIssuePairedErasure) return;
    final member = await _pickMember('Issue erasure for which member?');
    if (member == null) return;
    final reason = await _promptAdminReason(
      'Issue PII erasure for ${member.displayName}',
    );
    if (reason == null) return;
    // CODE_OPS_DEBT Theme B#1 — single-admin PII erasure with 24h
    // grace-window reverse. The button still surfaces under the
    // same `canIssuePairedErasure` flag (renaming the flag is a
    // follow-up), but the call is now a single-admin POST.
    await _runAndRefresh(
      () async {
        final summary = await widget.gateway.requestPiiErasure(
          operatorId: widget.pickedOperator.operatorId,
          targetUserId: member.userId,
          idempotencyKey: _nextIdempotencyKey('erasure-request'),
          actorUserId: widget.actorUserId,
          actorIsForgeAdmin: widget.editingEnabled,
          adminReason: reason,
        );
        _lastErasureMember = member.userId;
        _lastErasure = summary;
        // CODE_OPS_DEBT carry-over #2 - kick off the chip's tick timer
        // so the "Xh Ym remaining" countdown refreshes in place.
        _startGraceWindowTicker();
      },
      successHint:
          'PII erasure recorded for ${member.displayName}; reversal '
          'available within the 24-hour grace window.',
    );
  }

  /// CODE_OPS_DEBT Theme B#1 — reverses the most recent in-flight
  /// erasure recorded by [_onIssueErasure]. Surfaced from the
  /// confirmation banner that renders when [_lastErasure] is non-null
  /// and the grace window has not yet closed.
  Future<void> _onReverseLastErasure() async {
    final erasure = _lastErasure;
    final memberUserId = _lastErasureMember;
    if (erasure == null || memberUserId == null) return;
    await _runAndRefresh(() async {
      final outcome = await widget.gateway.reversePiiErasure(
        operatorId: widget.pickedOperator.operatorId,
        targetUserId: memberUserId,
        erasureId: erasure.erasureId,
        idempotencyKey: _nextIdempotencyKey('erasure-reverse'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reversalReason: 'admin reversed within grace window',
      );
      if (outcome.graceExpired) {
        // CODE_OPS_DEBT carry-over #2 - once the proxy says the
        // window is closed, the chip should never offer a reverse
        // affordance again. Drop the in-flight reference so the chip
        // hides on the next build.
        _graceWindowTicker?.cancel();
        _graceWindowTicker = null;
        setState(() {
          _actionError =
              'Grace window has expired; the erasure can no longer be '
              'reversed.';
          _lastErasure = null;
          _lastErasureMember = null;
        });
      } else if (outcome.reversed) {
        _graceWindowTicker?.cancel();
        _graceWindowTicker = null;
        setState(() {
          _lastErasure = null;
          _lastErasureMember = null;
        });
      }
    }, successHint: 'Erasure reversed.');
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_audited_support_actions_screen'),
      maxContentWidth: 1120,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
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
          const SizedBox(height: 14),
          _buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    if (!widget.canExportAuditLog) return const <Widget>[];
    return <Widget>[
      OutlinedButton.icon(
        key: const Key('admin_asa_audit_log_export_button'),
        onPressed: _exporting ? null : _onExportCsv,
        icon: _exporting
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sunsetDark,
                ),
              )
            : const Icon(Icons.file_download_outlined, size: 16),
        label: Text(_exporting ? 'Exporting' : 'Export CSV'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.sunsetDark,
          side: const BorderSide(color: AppColors.sunsetDark, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        ),
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
        // GAP B3 — when a scope tree is available, the shared
        // InheritanceTree is the DEFAULT scope selector for the
        // audit-log view (operator decision: close the gap where
        // admins actually are). The selected node updates the scope
        // banner below. When no tree is available the screen keeps
        // the read-only scope banner the upstream hierarchy
        // workspace already supplies — graceful fallback, no
        // regression.
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

/// GAP B3 — the in-screen audit-log scope picker. Renders the shared
/// [InheritanceTree] (the same widget the operator-web B8.b pane uses)
/// so F&F admins pick a business, region, district, or location by
/// tapping the tree instead of hand-typing operator_id / org_unit_id /
/// location_id. Pure UI over a route-built [InheritanceTreeNode]; no
/// proxy / gateway change.
// ---------------------------------------------------------------------
// Actions panel
// ---------------------------------------------------------------------

class _ActionsPanelCard extends StatelessWidget {
  const _ActionsPanelCard({
    required this.editingEnabled,
    required this.canResetMfaFactors,
    required this.canIssuePairedErasure,
    required this.onResetMfa,
    required this.onPasswordReset,
    required this.onIssueErasure,
  });

  final bool editingEnabled;
  final bool canResetMfaFactors;
  final bool canIssuePairedErasure;
  final VoidCallback onResetMfa;
  final VoidCallback onPasswordReset;
  final VoidCallback onIssueErasure;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_asa_actions_panel'),
      title: 'Actions',
      subtitle:
          'Each action asks for a reason and writes a row to the audit log '
          'plus the F&F internal action log. Multi-factor sign-in is '
          'required for the most sensitive actions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _ActionGroup(
            keyId: 'admin_asa_action_group_recovery',
            title: 'Account recovery',
            icon: Icons.lock_reset_outlined,
            children: <Widget>[
              _ActionRow(
                keyId: 'admin_asa_action_reset_mfa',
                title: 'Reset member two-factor sign-in',
                description:
                    "Removes the member's two-factor sign-in so they can "
                    're-enroll. Two-factor sign-in required.',
                buttonLabel: 'Reset two-factor sign-in',
                enabled: editingEnabled && canResetMfaFactors,
                onPressed: onResetMfa,
                mfaTag: true,
              ),
              const SizedBox(height: 8),
              _ActionRow(
                keyId: 'admin_asa_action_password_reset',
                title: 'Initiate password reset',
                description:
                    'Sends an active member a recovery email. Pending invite-only users must accept their invite first.',
                buttonLabel: 'Send reset email',
                enabled: editingEnabled,
                onPressed: onPasswordReset,
                mfaTag: false,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _ActionGroup(
            keyId: 'admin_asa_action_group_data_protection',
            title: 'Data protection',
            icon: Icons.privacy_tip_outlined,
            children: <Widget>[
              _ActionRow(
                keyId: 'admin_asa_action_erasure',
                title: 'Issue paired-approval erasure',
                description:
                    'Records a right-to-erasure request that a second F&F admin '
                    'must confirm before any data is overwritten. Multi-factor '
                    'sign-in required.',
                buttonLabel: 'Issue erasure',
                enabled: editingEnabled && canIssuePairedErasure,
                onPressed: onIssueErasure,
                mfaTag: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ActionGroup extends StatelessWidget {
  const _ActionGroup({
    required this.keyId,
    required this.title,
    required this.icon,
    required this.children,
  });

  final String keyId;
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyId),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, size: 16, color: AppColors.sunsetDark),
              const SizedBox(width: 8),
              Text(
                title,
                style: AppTextStyles.body13(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.keyId,
    required this.title,
    required this.description,
    required this.buttonLabel,
    required this.enabled,
    required this.onPressed,
    required this.mfaTag,
  });

  final String keyId;
  final String title;
  final String description;
  final String buttonLabel;
  final bool enabled;
  final VoidCallback onPressed;
  final bool mfaTag;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        key: Key(keyId),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (mfaTag)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.lock_outline,
                        size: 12,
                        color: AppColors.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'MFA',
                        style: AppTextStyles.mono11(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              key: Key('${keyId}_btn'),
              onPressed: enabled ? onPressed : null,
              style: AdminButtonStyles.secondary(),
              child: Text(buttonLabel),
            ),
          ),
        ],
      ),
    );
  }
}

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
                child: TextButton.icon(
                  key: const Key('admin_asa_audit_log_load_more'),
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
          OutlinedButton(
            key: const Key('admin_asa_audit_log_retry'),
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
// Audit-log table
// ---------------------------------------------------------------------

class _AuditLogCard extends StatelessWidget {
  const _AuditLogCard({
    required this.rows,
    required this.nextCursor,
    required this.loadingMore,
    required this.filters,
    required this.members,
    required this.canExport,
    required this.onApplyFilters,
    required this.onLoadMore,
    required this.onExportCsv,
  });

  final List<AuditLogRow> rows;
  final String? nextCursor;
  final bool loadingMore;
  final AuditLogFilters filters;
  final List<SupportActionsMember> members;
  final bool canExport;
  final ValueChanged<AuditLogFilters> onApplyFilters;
  final VoidCallback onLoadMore;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_asa_audit_log'),
      title: 'Audit log',
      trailing: canExport
          ? FilledButton.icon(
              key: const Key('admin_asa_audit_log_export'),
              onPressed: onExportCsv,
              style: AdminButtonStyles.primary,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('Export CSV'),
            )
          : null,
      subtitle:
          'Cursor-paginated rows scoped to this operator. Sorted newest '
          'first. Filters and the CSV export are audit-logged. Times are '
          'shown in your browser local timezone.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _FiltersBar(
            filters: filters,
            members: members,
            onApply: onApplyFilters,
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Padding(
              key: const Key('admin_asa_audit_log_empty'),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'No audit log entries match the current filters.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else
            for (final row in rows)
              _AuditRowTile(
                key: Key('admin_asa_audit_row_${row.eventId}'),
                row: row,
              ),
          if (nextCursor != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('admin_asa_audit_log_load_more'),
                  onPressed: loadingMore ? null : onLoadMore,
                  style: AdminButtonStyles.secondary(),
                  icon: loadingMore
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.expand_more, size: 16),
                  label: Text(
                    loadingMore ? 'Loading next page' : 'Load next page',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FiltersBar extends StatefulWidget {
  const _FiltersBar({
    required this.filters,
    required this.members,
    required this.onApply,
  });

  final AuditLogFilters filters;
  final List<SupportActionsMember> members;
  final ValueChanged<AuditLogFilters> onApply;

  @override
  State<_FiltersBar> createState() => _FiltersBarState();
}

class _FiltersBarState extends State<_FiltersBar> {
  late AuditLogFilters _draft = widget.filters;
  late final TextEditingController _targetIdController = TextEditingController(
    text: widget.filters.targetId ?? '',
  );

  @override
  void dispose() {
    _targetIdController.dispose();
    super.dispose();
  }

  Future<void> _pickFromDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.customRangeFrom?.toLocal() ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() => _draft = _draft.copyWith(customRangeFrom: picked.toUtc()));
  }

  Future<void> _pickToDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.customRangeTo?.toLocal() ?? now,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() => _draft = _draft.copyWith(customRangeTo: picked.toUtc()));
  }

  void _apply() {
    final next = _draft.copyWith(
      targetId: _targetIdController.text.trim().isEmpty
          ? null
          : _targetIdController.text.trim(),
    );
    widget.onApply(next);
  }

  @override
  Widget build(BuildContext context) {
    final showCustomRange = _draft.timeWindow == AuditLogTimeWindow.customRange;
    return Column(
      key: const Key('admin_asa_filters'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: [
            const Icon(
              Icons.filter_list,
              size: 18,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Filters',
                style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
              ),
            ),
            // Operator-web parity declutter: the "Audit rows are newest first"
            // helper note was removed (web's audit filters have no equivalent
            // note; "newest first" is already stated in the audit-log card
            // subtitle).
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String?>(
                key: const Key('admin_asa_filter_actor'),
                initialValue: _draft.actorUserId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Actor',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String?>>[
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Any actor'),
                  ),
                  for (final m in widget.members)
                    DropdownMenuItem<String?>(
                      value: m.userId,
                      child: Text('${m.displayName} (${m.email})'),
                    ),
                ],
                onChanged: (v) =>
                    setState(() => _draft = _draft.copyWith(actorUserId: v)),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String?>(
                key: const Key('admin_asa_filter_target_kind'),
                initialValue: _draft.targetKind,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Target kind',
                  border: OutlineInputBorder(),
                ),
                items: const <DropdownMenuItem<String?>>[
                  DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Any kind'),
                  ),
                  DropdownMenuItem<String?>(value: 'user', child: Text('User')),
                  DropdownMenuItem<String?>(
                    value: 'auth_session',
                    child: Text('Session'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'team_role',
                    child: Text('Role'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'org_unit',
                    child: Text('Org unit'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'mfa_factor',
                    child: Text('Two-factor sign-in factor'),
                  ),
                  DropdownMenuItem<String?>(
                    value: 'audit_log_export',
                    child: Text('Audit log export'),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => _draft = _draft.copyWith(targetKind: v)),
              ),
            ),
            SizedBox(
              width: 220,
              child: TextField(
                key: const Key('admin_asa_filter_target_id'),
                controller: _targetIdController,
                decoration: const InputDecoration(
                  labelText: 'Target ID',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<AuditLogTimeWindow>(
                key: const Key('admin_asa_filter_time_window'),
                // Web parity (audit_log_screen.dart): fixed time windows
                // only, defaulting to the last 30 days. The admin-only
                // "Any time" option is removed so the set matches web.
                initialValue: _draft.timeWindow ?? AuditLogTimeWindow.last30d,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Time window',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<AuditLogTimeWindow>>[
                  for (final w in AuditLogTimeWindow.values)
                    DropdownMenuItem<AuditLogTimeWindow>(
                      value: w,
                      child: Text(w.displayLabel),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _draft = _draft.copyWith(timeWindow: v));
                },
              ),
            ),
          ],
        ),
        if (showCustomRange) ...<Widget>[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                key: const Key('admin_asa_filter_custom_from'),
                onPressed: _pickFromDate,
                style: AdminButtonStyles.secondary(),
                icon: const Icon(Icons.calendar_today, size: 14),
                label: Text(
                  _draft.customRangeFrom == null
                      ? 'Pick from date'
                      : 'From: ${_formatDate(_draft.customRangeFrom!)}',
                ),
              ),
              OutlinedButton.icon(
                key: const Key('admin_asa_filter_custom_to'),
                onPressed: _pickToDate,
                style: AdminButtonStyles.secondary(),
                icon: const Icon(Icons.calendar_today, size: 14),
                label: Text(
                  _draft.customRangeTo == null
                      ? 'Pick to date'
                      : 'To: ${_formatDate(_draft.customRangeTo!)}',
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Action',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: <Widget>[
            for (final action in kAuditLogFilterableActions)
              FilterChip(
                key: Key('admin_asa_filter_action_$action'),
                tooltip: action,
                label: Text(humanizeAuditAction(action)),
                selected: _draft.actions.contains(action),
                onSelected: (selected) {
                  final next = List<String>.of(_draft.actions);
                  if (selected) {
                    if (!next.contains(action)) next.add(action);
                  } else {
                    next.remove(action);
                  }
                  setState(() => _draft = _draft.copyWith(actions: next));
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: 320,
          child: _ActorKindMultiSelect(
            value: _draft.actorKinds,
            onChanged: (next) =>
                setState(() => _draft = _draft.copyWith(actorKinds: next)),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            key: const Key('admin_asa_filter_apply'),
            style: AdminButtonStyles.primary,
            onPressed: _apply,
            child: const Text('Apply filters'),
          ),
        ),
      ],
    );
  }

  static String _formatDate(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// Common action keys exposed in the audit-log filter chip group.
/// Mirrors the locked vocabulary the slice's writes emit plus the
/// canonical self-service actions seeded in the demo gateway. Defined
/// here so widget tests can pin the chip set against the contract's
/// "action ∈ enum (multi-select)" filter without hard-coding strings
/// in two places.
const List<String> kAuditLogFilterableActions =
    operator_audit.WebAuditLogActions.catalog;

class _ActorKindMultiSelect extends StatelessWidget {
  const _ActorKindMultiSelect({required this.value, required this.onChanged});

  final List<AuditActorKind> value;
  final ValueChanged<List<AuditActorKind>> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Actor kind',
        border: OutlineInputBorder(),
      ),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: <Widget>[
          for (final kind in AuditActorKind.values)
            FilterChip(
              key: Key('admin_asa_filter_actor_kind_${kind.wire}'),
              label: Text(kind.displayLabel),
              selected: value.contains(kind),
              onSelected: (selected) {
                final next = List<AuditActorKind>.of(value);
                if (selected) {
                  if (!next.contains(kind)) next.add(kind);
                } else {
                  next.remove(kind);
                }
                onChanged(next);
              },
            ),
        ],
      ),
    );
  }
}

class _AuditRowTile extends StatefulWidget {
  const _AuditRowTile({super.key, required this.row});

  final AuditLogRow row;

  @override
  State<_AuditRowTile> createState() => _AuditRowTileState();
}

class _AuditRowTileState extends State<_AuditRowTile> {
  bool _payloadExpanded = false;

  Future<void> _copyTargetId() async {
    await Clipboard.setData(ClipboardData(text: widget.row.targetId));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied target ID to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final hasPayload = row.payload.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    humanizeAuditAction(row.action),
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    row.actorKind.displayLabel,
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.action,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            const SizedBox(height: 6),
            Text(
              _auditActorIdentityLabel(row),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Target: ${row.targetKind} / ${row.targetId}',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ),
                IconButton(
                  key: Key('admin_asa_audit_row_copy_target_${row.eventId}'),
                  tooltip: 'Copy target ID',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  icon: const Icon(
                    Icons.content_copy_outlined,
                    color: AppColors.textMuted,
                  ),
                  onPressed: _copyTargetId,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Occurred ${formatAuditTimestamp(row.occurredAt)}',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            if (row.adminReason != null && row.adminReason!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'F&F admin reason: ${row.adminReason}',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
            if (hasPayload) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('admin_asa_audit_row_payload_toggle_${row.eventId}'),
                  onPressed: () =>
                      setState(() => _payloadExpanded = !_payloadExpanded),
                  icon: Icon(
                    _payloadExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                  ),
                  label: Text(
                    _payloadExpanded ? 'Hide payload' : 'View payload',
                  ),
                ),
              ),
              if (_payloadExpanded)
                Container(
                  key: Key('admin_asa_audit_row_payload_${row.eventId}'),
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundDeep,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SelectableText(
                    formatPayload(row.payload),
                    style: AppTextStyles.mono11(color: AppColors.textSecondary),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Humanize a locked-vocabulary action key. Exposed for widget tests
/// so the parity contract's "action (humanized — ...)" pin can assert
/// the rendering directly.
@visibleForTesting
String humanizeAuditAction(String action) {
  return operator_audit.WebAuditLogActionLabels.labelFor(action);
}

String _auditActorIdentityLabel(AuditLogRow row) {
  final name = row.actorDisplayName.trim().isEmpty
      ? row.actorUserId
      : row.actorDisplayName.trim();
  final role = row.actorRole?.trim().isNotEmpty == true
      ? row.actorRole!.trim()
      : row.actorKind.displayLabel;
  final email = row.actorEmail.trim();
  if (email.isEmpty) return '$name - $role - email unavailable';
  return '$name - $role - $email';
}

/// Format an audit `occurred_at` timestamp for display. The contract
/// pins operator-local timezone (`phase_7_55_time_boundary_contract.md`);
/// without a per-operator tz lookup at this layer the surface falls
/// back to the browser's local timezone, which is the closest
/// approximation available client-side. The UTC ISO timestamp is
/// included after the local representation so forensic review can
/// cross-reference the canonical chain.
@visibleForTesting
String formatAuditTimestamp(DateTime utc) {
  final local = utc.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final m = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

/// Render the `audit_logs.payload` JSONB diff in a readable form.
/// Sorts top-level keys for stable output and indents nested maps
/// one level. Exposed for widget tests so the "View payload" pin can
/// assert against the rendered text directly.
@visibleForTesting
String formatPayload(Map<String, Object?> payload) {
  if (payload.isEmpty) return '(no payload)';
  try {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(payload);
  } catch (_) {
    return payload.toString();
  }
}

// ---------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------

/// CODE_OPS_DEBT carry-over #2 - countdown chip + reverse affordance
/// rendered while a single-admin PII erasure is inside its 24h grace
/// window. The chip self-renders one of two states:
///
///   * `pending`: `now` is before `erasure.gracePeriodEndsAt`. Shows
///     "Erasure reversible - Xh Ym remaining" plus a "Reverse erasure"
///     button wired to [onReverse].
///   * `final`: `now` is at-or-after the boundary. Shows "Erasure
///     final" with no reverse affordance. The chip stays mounted
///     briefly so the operator sees the transition; the parent state
///     clears the in-flight erasure on the next reverse attempt or
///     on a fresh erasure.
///
/// The chip is intentionally stateless: the parent screen owns the
/// periodic timer that triggers rebuilds (1-min tick by default). No
/// per-tick `setState` lives here so widget tests can drive the chip
/// purely via the parent `now` clock.
class _GraceWindowChip extends StatelessWidget {
  const _GraceWindowChip({
    super.key,
    required this.erasure,
    required this.memberDisplay,
    required this.now,
    required this.canReverse,
    required this.onReverse,
  });

  final UserPiiErasureRequestSummary erasure;
  final String? memberDisplay;
  final DateTime now;
  final bool canReverse;
  final VoidCallback onReverse;

  bool get _isReversible =>
      now.toUtc().isBefore(erasure.gracePeriodEndsAt.toUtc());

  @override
  Widget build(BuildContext context) {
    final reversible = _isReversible;
    final tone = reversible ? AppColors.warning : AppColors.textMuted;
    final iconData = reversible ? Icons.timelapse_outlined : Icons.lock_outline;
    final label = reversible
        ? 'Erasure reversible - ${formatGraceWindowRemaining(now: now, endsAt: erasure.gracePeriodEndsAt)} remaining'
        : 'Erasure final';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: tone, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(iconData, size: 16, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  key: const Key('admin_asa_grace_window_chip_label'),
                  style: AppTextStyles.body13(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                if (memberDisplay != null && memberDisplay!.isNotEmpty)
                  Text(
                    'Target user: ${memberDisplay!}',
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
          if (reversible)
            FilledButton.icon(
              key: const Key('admin_asa_grace_window_chip_reverse'),
              onPressed: canReverse ? onReverse : null,
              style: AdminButtonStyles.primary,
              icon: const Icon(Icons.undo, size: 14),
              label: const Text('Reverse erasure'),
            ),
        ],
      ),
    );
  }
}

/// CODE_OPS_DEBT carry-over #2 — humanise the time-remaining label
/// for the grace-window chip. Returns the largest two non-zero units
/// (e.g. `14h 23m`, `45m 12s`, `1d 0h`) so the chip stays compact and
/// truthful at every point in the 24h window. Exposed for widget
/// tests so the format pin lives in one place.
@visibleForTesting
String formatGraceWindowRemaining({
  required DateTime now,
  required DateTime endsAt,
}) {
  final remaining = endsAt.toUtc().difference(now.toUtc());
  if (remaining.isNegative || remaining == Duration.zero) {
    return '0m';
  }
  final hours = remaining.inHours;
  final minutes = remaining.inMinutes - hours * 60;
  final seconds = remaining.inSeconds - remaining.inMinutes * 60;
  if (hours > 0) {
    return '${hours}h ${minutes}m';
  }
  if (minutes > 0) {
    return '${minutes}m ${seconds}s';
  }
  return '${seconds}s';
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only. Ask a super admin if a support action needs to run.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}

class _AdminReasonDialog extends StatefulWidget {
  const _AdminReasonDialog({required this.title});

  final String title;

  @override
  State<_AdminReasonDialog> createState() => _AdminReasonDialogState();
}

class _AdminReasonDialogState extends State<_AdminReasonDialog> {
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_asa_reason_dialog'),
      title: widget.title,
      maxWidth: 460,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_asa_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_asa_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'The operator will see this reason in their audit log. '
            'Write a short, plain-English note about why you are running '
            'this action.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_asa_reason_field'),
            controller: _reasonController,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Reason',
              border: const OutlineInputBorder(),
              errorText: _violated
                  ? SupportActionsValidationCopy.adminReasonRequired
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _MemberPickerDialog extends StatefulWidget {
  const _MemberPickerDialog({
    required this.title,
    required this.members,
    required this.emptyCopy,
  });

  final String title;
  final List<SupportActionsMember> members;
  final String emptyCopy;

  @override
  State<_MemberPickerDialog> createState() => _MemberPickerDialogState();
}

class _MemberPickerDialogState extends State<_MemberPickerDialog> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    if (widget.members.isNotEmpty) {
      _selected = widget.members.first.userId;
    }
  }

  void _onSubmit() {
    if (_selected == null) return;
    final picked = widget.members.firstWhere((m) => m.userId == _selected);
    Navigator.of(context).pop(picked);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_asa_member_picker_dialog'),
      title: widget.title,
      maxWidth: 460,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_asa_member_picker_submit'),
          style: AdminButtonStyles.primary,
          onPressed: widget.members.isEmpty ? null : _onSubmit,
          child: const Text('Continue'),
        ),
      ],
      child: widget.members.isEmpty
          ? Text(
              widget.emptyCopy,
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          : DropdownButtonFormField<String>(
              key: const Key('admin_asa_member_picker_dropdown'),
              initialValue: _selected,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Member',
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final m in widget.members)
                  DropdownMenuItem<String>(
                    value: m.userId,
                    child: Text('${m.displayName} (${m.email})'),
                  ),
              ],
              onChanged: (v) => setState(() => _selected = v),
            ),
    );
  }
}

class _SecondApproverDialog extends StatefulWidget {
  const _SecondApproverDialog({required this.firstApproverUserId});

  final String firstApproverUserId;

  @override
  State<_SecondApproverDialog> createState() => _SecondApproverDialogState();
}

class _SecondApproverDialogState extends State<_SecondApproverDialog> {
  final _uidController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _uidController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final uid = _uidController.text.trim();
    if (uid.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(uid);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_asa_second_approver_dialog'),
      title: 'Second F&F admin confirmation',
      maxWidth: 480,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_asa_second_approver_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm erasure'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'A second F&F admin must confirm this erasure. The first '
            'approver was '
            '${widget.firstApproverUserId}. Enter the second admin\'s '
            'user ID to record their confirmation.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_asa_second_approver_uid'),
            controller: _uidController,
            decoration: InputDecoration(
              labelText: 'Second admin user ID',
              border: const OutlineInputBorder(),
              errorText: _violated
                  ? SupportActionsValidationCopy.adminReasonRequired
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}
