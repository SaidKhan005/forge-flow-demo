// Phase 11A.14 - F&F Operations Console "Audit log" surface.
//
// Cross-operator audit-log review. Mounted in the admin shell at
// `/admin/audited-support-actions`. The shell passes the shared
// Operations operator context when one exists; the picker is only
// opened when the admin needs to choose or change operator.
//
// The rendered UX intentionally matches the operator-web audit log:
// cursor-paginated rows, row-derived filters, payload expansion, and
// CSV export gated on `admin.audit_log.export`.
//
// Authority:
//
//   * docs/contracts/team_roles_hierarchy_console_parity_contract.md
//     § Audit Log + § Security (admin paths) + § Audit-row shape +
//     § Idempotency keys.
//   * docs/contracts/auth_permission_key_catalog.md - the new
//     `admin.users.reset_mfa_factors` row mirrored in lockstep with
//     this slice.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../domain/models/inheritance_tree_node.dart';
import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../../widgets/inheritance_tree.dart';
import '../admin_route_handoff.dart';
import '../admin_button_styles.dart';
import '../services/admin_audit_chain_anchors_gateway.dart';
import '../services/audited_support_actions_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_audit_log_integrity_badge.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import 'operator_picker_screen.dart';

class AdminAuditLogCsvExport {
  const AdminAuditLogCsvExport({required this.csv, required this.filename});

  final String csv;
  final String filename;
}

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
    this.onChangeOperator,
    this.onBackToBusinessAccounts,
    this.anchorBadgeClock,
    this.onCsvReady,
    this.copyToClipboard,
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

  final Future<void> Function(AdminAuditLogCsvExport export)? onCsvReady;
  final Future<void> Function(String value)? copyToClipboard;

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
  final Map<String, String> _actorPickerCatalog = <String, String>{};
  final Set<String> _expandedEntryIds = <String>{};
  // Web parity (audit_log_screen.dart defaults to last30d): open on a
  // fixed window rather than the removed admin-only "Any time" state.
  AuditLogFilters _filters = const AuditLogFilters(
    timeWindow: AuditLogTimeWindow.last30d,
  );
  int _refreshGeneration = 0;

  /// GAP B3 — the scope the admin selected in the in-screen
  /// [InheritanceTree] picker (when [AuditedSupportActionsAdminScreen.
  /// auditScopeRootNode] is supplied). Seeded from the upstream
  /// workspace scope so the banner stays consistent before the admin
  /// touches the tree. The audit-log read stays operator-wide — the
  /// gateway exposes no scoped aggregate route yet — so this only
  /// drives the scope banner copy, identical to the prior read-only
  /// banner behaviour.
  AdminHierarchyScopeIntent? _activeScope;

  /// Admin audit-integrity badge — most-recent anchor snapshot for the
  /// selected operator. Null while loading or when no gateway is wired
  /// (the badge renders the neutral "unknown" state in both cases).
  AdminAuditChainAnchorSnapshot? _anchorSnapshot;
  bool _anchorLoading = false;
  bool _anchorTransientError = false;

  /// Monotonic generation guard so a stale anchor read (after the
  /// operator changes) cannot overwrite a newer one.
  int _anchorGeneration = 0;

  void _onAuditScopeNodeTap(InheritanceTreeNode node) {
    final operatorId = widget.pickedOperator.operatorId;
    final operatorName = widget.pickedOperator.operatorBusinessName;
    final AdminHierarchyScopeIntent next;
    switch (node.scopeKind) {
      case InheritanceTreeScopeKind.business:
        next = AdminHierarchyScopeIntent.business(
          operatorId: operatorId,
          operatorName: operatorName,
        );
        break;
      case InheritanceTreeScopeKind.orgUnit:
        next = AdminHierarchyScopeIntent.orgUnit(
          operatorId: operatorId,
          orgUnitId: node.scopeId,
          operatorName: operatorName,
          orgUnitName: node.displayName,
        );
        break;
      case InheritanceTreeScopeKind.location:
        next = AdminHierarchyScopeIntent.location(
          operatorId: operatorId,
          locationId: node.scopeId,
          operatorName: operatorName,
          locationName: node.displayName,
        );
        break;
    }
    setState(() => _activeScope = next);
  }

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
    _activeScope = widget.hierarchyScope;
    _refresh();
    _loadAnchorBadge();
  }

  @override
  void didUpdateWidget(AuditedSupportActionsAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // GAP B3 — when the upstream workspace pushes a new scope, re-seed
    // the in-screen picker selection so the banner stays consistent.
    if (oldWidget.hierarchyScope != widget.hierarchyScope) {
      _activeScope = widget.hierarchyScope;
    }
    // Admin audit-integrity badge — re-read when the selected operator
    // or the wired gateway changes so the badge follows the operator
    // the admin switched to.
    if (oldWidget.pickedOperator.operatorId !=
            widget.pickedOperator.operatorId ||
        oldWidget.anchorsGateway != widget.anchorsGateway) {
      _loadAnchorBadge();
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

  Future<void> _refresh() async {
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
        filters: _filters,
      );
      if (generation != _refreshGeneration) return;
      if (!mounted) return;
      setState(() {
        _rows = page.rows;
        _nextCursor = page.nextCursor;
        _loading = false;
        _expandedEntryIds.clear();
        _refreshActorCatalog(page.rows);
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

  void _refreshActorCatalog(List<AuditLogRow> rows) {
    for (final row in rows) {
      final id = row.actorUserId.trim();
      if (id.isEmpty) continue;
      final label = row.actorDisplayName.trim().isNotEmpty
          ? row.actorDisplayName.trim()
          : row.actorEmail.trim().isNotEmpty
          ? row.actorEmail.trim()
          : id;
      _actorPickerCatalog[id] = label;
    }
  }

  void _toggleExpanded(String eventId) {
    setState(() {
      if (_expandedEntryIds.contains(eventId)) {
        _expandedEntryIds.remove(eventId);
      } else {
        _expandedEntryIds.add(eventId);
      }
    });
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _loadingMore) return;
    setState(() {
      _loadingMore = true;
      _actionError = null;
    });
    try {
      final next = await widget.gateway.listAuditLog(
        operatorId: widget.pickedOperator.operatorId,
        filters: _filters,
        cursor: cursor,
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
        _actionError = error.message;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.toString();
        _loadingMore = false;
      });
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  // --- Audit log actions -------------------------------------------------

  Future<void> _onApplyFilters(AuditLogFilters next) async {
    setState(() => _filters = next);
    await _refresh();
  }

  Future<void> _onExportCsv() async {
    if (_exporting || !(widget.editingEnabled && widget.canExportAuditLog)) {
      return;
    }
    final reason = await _promptAdminReason('Export the filtered audit log');
    if (reason == null) return;
    setState(() {
      _exporting = true;
      _exportMessage = null;
      _actionError = null;
    });
    try {
      final csv = await widget.gateway.exportAuditLogCsv(
        operatorId: widget.pickedOperator.operatorId,
        filters: _filters,
        idempotencyKey: _nextIdempotencyKey('audit-log-export'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      );
      final export = AdminAuditLogCsvExport(
        csv: csv,
        filename: defaultAdminAuditLogCsvFilename(DateTime.now().toUtc()),
      );
      final copy = widget.copyToClipboard ?? _defaultCopy;
      await copy(export.csv);
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
        _exportMessage = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _exporting = false;
        _exportMessage = 'Could not export the audit log. Try again.';
      });
    }
  }

  Future<void> _defaultCopy(String value) async {
    await Clipboard.setData(ClipboardData(text: value));
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
            icon: Icons.security_outlined,
            title: 'Audit log',
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
          if (_actionError != null)
            _ErrorBanner(
              key: const Key('admin_asa_action_error'),
              message: _actionError!,
            ),
          _buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    final children = <Widget>[];
    if (widget.onBackToBusinessAccounts != null) {
      children.add(
        AdminBusinessAccountsBackButton(
          onPressed: widget.onBackToBusinessAccounts,
        ),
      );
    }
    if (widget.onChangeOperator != null) {
      children.add(
        OutlinedButton.icon(
          key: const Key('admin_asa_change_operator'),
          onPressed: widget.onChangeOperator,
          style: AdminButtonStyles.secondary(),
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Change operator'),
        ),
      );
    }
    return children;
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_asa_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _AuditLogErrorPanel(message: _loadError!, onRetry: _refresh);
    }
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
        if (widget.auditScopeRootNode != null) ...<Widget>[
          _AuditScopePickerCard(
            rootNode: widget.auditScopeRootNode!,
            onNodeTap: _onAuditScopeNodeTap,
          ),
          const SizedBox(height: 16),
        ],
        if (_activeScope != null) ...<Widget>[
          _SecurityHierarchyScopeBanner(scope: _activeScope!),
          const SizedBox(height: 16),
        ],
        _AuditLogCard(
          rows: _rows,
          nextCursor: _nextCursor,
          loadingMore: _loadingMore,
          exporting: _exporting,
          exportMessage: _exportMessage,
          filters: _filters,
          actorCatalog: _actorPickerCatalog,
          expandedEntryIds: _expandedEntryIds,
          canExport: widget.editingEnabled && widget.canExportAuditLog,
          onApplyFilters: _onApplyFilters,
          onToggleRow: _toggleExpanded,
          onLoadMore: _loadMore,
          onExportCsv: _onExportCsv,
        ),
      ],
    );
  }
}

/// GAP B3 — the in-screen audit-log scope picker. Renders the shared
/// [InheritanceTree] (the same widget the operator-web B8.b pane uses)
/// so F&F admins pick a business, region, district, or location by
/// tapping the tree instead of hand-typing operator_id / org_unit_id /
/// location_id. Pure UI over a route-built [InheritanceTreeNode]; no
/// proxy / gateway change.
class _AuditScopePickerCard extends StatelessWidget {
  const _AuditScopePickerCard({
    required this.rootNode,
    required this.onNodeTap,
  });

  final InheritanceTreeNode rootNode;
  final ValueChanged<InheritanceTreeNode> onNodeTap;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_asa_audit_scope_picker'),
      title: 'Audit log filter',
      subtitle: 'Pick a business, region, district, or location in the tree.',
      child: InheritanceTree(
        rootNode: rootNode,
        onNodeTap: onNodeTap,
        annotationBuilder: (context, node) => const SizedBox.shrink(),
      ),
    );
  }
}

class _SecurityHierarchyScopeBanner extends StatelessWidget {
  const _SecurityHierarchyScopeBanner({required this.scope});

  final AdminHierarchyScopeIntent scope;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_scope_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.62),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            scope.isLocationScope
                ? scopeIcon(kind: ScopeEntityKind.location)
                : scope.isOrgUnitScope
                ? scopeIcon(kind: ScopeEntityKind.orgUnit)
                : scopeIcon(kind: ScopeEntityKind.business),
            size: 16,
            color: AppColors.peacock,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text(
                      '${scope.scopeType.label}: ${scope.displayLabel}',
                      key: const Key('admin_asa_scope_label'),
                      style: AppTextStyles.body13(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w700),
                    ),
                    _SecurityScopePill(label: scope.inheritanceLabel),
                    if (scope.effectiveValueLabel != null)
                      _SecurityScopePill(
                        label: 'Effective: ${scope.effectiveValueLabel}',
                      ),
                    if (scope.allowedActionsLabel != null)
                      _SecurityScopePill(label: scope.allowedActionsLabel!),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SecurityScopePill extends StatelessWidget {
  const _SecurityScopePill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono11(color: AppColors.textSecondary),
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
    required this.exporting,
    required this.exportMessage,
    required this.filters,
    required this.actorCatalog,
    required this.expandedEntryIds,
    required this.canExport,
    required this.onApplyFilters,
    required this.onToggleRow,
    required this.onLoadMore,
    required this.onExportCsv,
  });

  final List<AuditLogRow> rows;
  final String? nextCursor;
  final bool loadingMore;
  final bool exporting;
  final String? exportMessage;
  final AuditLogFilters filters;
  final Map<String, String> actorCatalog;
  final Set<String> expandedEntryIds;
  final bool canExport;
  final ValueChanged<AuditLogFilters> onApplyFilters;
  final ValueChanged<String> onToggleRow;
  final VoidCallback onLoadMore;
  final VoidCallback onExportCsv;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_asa_audit_log'),
      title: 'Audit log',
      trailing: _exportButton(),
      subtitle:
          'Cursor-paginated rows scoped to this operator. Sorted newest '
          'first. Filters and the CSV export are audit-logged. Times are '
          'shown in your browser local timezone.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _children(),
      ),
    );
  }

  Widget? _exportButton() {
    if (!canExport) return null;
    return FilledButton.icon(
      key: const Key('admin_asa_audit_log_export'),
      onPressed: exporting ? null : onExportCsv,
      style: AdminButtonStyles.primary,
      icon: exporting
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Icon(Icons.file_download_outlined, size: 16),
      label: Text(exporting ? 'Exporting' : 'Export CSV'),
    );
  }

  List<Widget> _children() {
    return <Widget>[
      _FiltersBar(
        filters: filters,
        actorCatalog: actorCatalog,
        onApply: onApplyFilters,
      ),
      const SizedBox(height: 12),
      if (exportMessage != null) _exportMessage(),
      if (rows.isEmpty) _emptyState() else ..._rowTiles(),
      if (nextCursor != null) _loadMoreButton(),
    ];
  }

  Widget _exportMessage() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        exportMessage!,
        key: const Key('admin_asa_audit_log_export_message'),
        style: AppTextStyles.body12(color: AppColors.textPrimary),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      key: const Key('admin_asa_audit_log_empty'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'No audit log entries match the current filters.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }

  Iterable<Widget> _rowTiles() {
    return rows.map(
      (row) => _AuditRowTile(
        key: Key('admin_asa_audit_row_${row.eventId}'),
        row: row,
        expanded: expandedEntryIds.contains(row.eventId),
        onTogglePayload: () => onToggleRow(row.eventId),
      ),
    );
  }

  Widget _loadMoreButton() {
    return Padding(
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
          label: Text(loadingMore ? 'Loading next page' : 'Load next page'),
        ),
      ),
    );
  }
}

class _FiltersBar extends StatefulWidget {
  const _FiltersBar({
    required this.filters,
    required this.actorCatalog,
    required this.onApply,
  });

  final AuditLogFilters filters;
  final Map<String, String> actorCatalog;
  final ValueChanged<AuditLogFilters> onApply;

  @override
  State<_FiltersBar> createState() => _FiltersBarState();
}

class _FiltersBarState extends State<_FiltersBar> {
  late AuditLogFilters _draft = widget.filters;

  @override
  void didUpdateWidget(covariant _FiltersBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.filters, widget.filters)) {
      _draft = widget.filters;
    }
  }

  void _setFilters(AuditLogFilters next) {
    setState(() => _draft = next);
    widget.onApply(next);
  }

  Future<void> _pickCustomRange() async {
    final initialRange =
        _draft.customRangeFrom != null && _draft.customRangeTo != null
        ? DateTimeRange(
            start: _draft.customRangeFrom!.toLocal(),
            end: _draft.customRangeTo!.toLocal(),
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
    _setFilters(
      _draft.copyWith(
        timeWindow: AuditLogTimeWindow.customRange,
        customRangeFrom: _startOfDayUtc(picked.start),
        customRangeTo: _endOfDayUtc(picked.end),
      ),
    );
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

  Set<String> get _selectedActors => _draft.effectiveActorUserIds.toSet();
  Set<String> get _selectedActions => _draft.actions.toSet();

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
          _AdminAuditTimeWindowChips(
            selected: _draft.timeWindow ?? AuditLogTimeWindow.last30d,
            customFrom: _draft.customRangeFrom,
            customTo: _draft.customRangeTo,
            onChanged: (window) {
              _setFilters(
                _draft.copyWith(
                  timeWindow: window,
                  customRangeFrom: null,
                  customRangeTo: null,
                ),
              );
            },
            onPickCustom: _pickCustomRange,
          ),
          const SizedBox(height: 12),
          _AdminAuditActionPicker(
            selected: _selectedActions,
            onChanged: (next) =>
                _setFilters(_draft.copyWith(actions: next.toList())),
          ),
          if (widget.actorCatalog.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _AdminAuditActorPicker(
              catalog: widget.actorCatalog,
              selected: _selectedActors,
              onChanged: (next) =>
                  _setFilters(_draft.copyWith(actorUserIds: next.toList())),
            ),
          ],
        ],
      ),
    );
  }
}

class _AdminAuditTimeWindowChips extends StatelessWidget {
  const _AdminAuditTimeWindowChips({
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
        selected == AuditLogTimeWindow.customRange &&
            customFrom != null &&
            customTo != null
        ? '${_fmt(customFrom!)} to ${_fmt(customTo!)}'
        : 'Custom range';
    return Wrap(
      key: const Key('admin_asa_filter_time_window'),
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final option in _options)
          _AdminAuditChoiceChip(
            chipKey: Key('admin_asa_filter_time_window_${option.$3}'),
            label: option.$2,
            isActive: selected == option.$1,
            onTap: () => onChanged(option.$1),
          ),
        _AdminAuditChoiceChip(
          chipKey: const Key('admin_asa_filter_time_window_custom'),
          label: customLabel,
          isActive: selected == AuditLogTimeWindow.customRange,
          onTap: onPickCustom,
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

class _AdminAuditActionPicker extends StatelessWidget {
  const _AdminAuditActionPicker({
    required this.selected,
    required this.onChanged,
  });

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
              _AdminAuditChoiceChip(
                chipKey: Key('admin_asa_filter_action_$action'),
                tooltip: action,
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

class _AdminAuditActorPicker extends StatelessWidget {
  const _AdminAuditActorPicker({
    required this.catalog,
    required this.selected,
    required this.onChanged,
  });

  final Map<String, String> catalog;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    final actors = catalog.entries.toList(growable: false)
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
            for (final actor in actors)
              _AdminAuditChoiceChip(
                chipKey: Key('admin_asa_filter_actor_${actor.key}'),
                label: actor.value,
                isActive: selected.contains(actor.key),
                onTap: () {
                  final next = Set<String>.from(selected);
                  if (next.contains(actor.key)) {
                    next.remove(actor.key);
                  } else {
                    next.add(actor.key);
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

class _AdminAuditChoiceChip extends StatelessWidget {
  const _AdminAuditChoiceChip({
    required this.chipKey,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.tooltip,
  });

  final Key chipKey;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      key: chipKey,
      tooltip: tooltip,
      selected: isActive,
      label: Text(label),
      visualDensity: VisualDensity.compact,
      onSelected: (_) => onTap(),
    );
  }
}

/// Common action keys exposed in the audit-log filter chip group.
/// Mirrors the locked vocabulary the slice's writes emit plus the
/// canonical self-service actions seeded in the demo gateway. Defined
/// here so widget tests can pin the chip set against the contract's
/// "action ∈ enum (multi-select)" filter without hard-coding strings
/// in two places.
const List<String> kAuditLogFilterableActions = <String>[
  'team.users.invite',
  'team.users.deactivate',
  'team.users.reactivate',
  'team.users.soft_delete',
  'team.users.reset_password',
  'team.users.reset_mfa',
  'team.roles.create_custom',
  'team.roles.assign',
  'team.roles.revoke',
  'team.session.force_logout',
  'team.org_unit.move',
  'auth.user.signed_in',
  'auth.session_revoked',
  'auth.password_changed',
  'auth.mfa_totp_enrolled',
  'auth.mfa_factor_removed',
  'audit.export.requested',
];

class _AuditRowTile extends StatelessWidget {
  const _AuditRowTile({
    super.key,
    required this.row,
    required this.expanded,
    required this.onTogglePayload,
  });

  final AuditLogRow row;
  final bool expanded;
  final VoidCallback onTogglePayload;

  Future<void> _copyTargetId() async {
    final targetId = row.targetId;
    if (targetId == null || targetId.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: targetId));
  }

  Future<void> _copyTargetIdFrom(BuildContext context) async {
    final targetId = row.targetId;
    if (targetId == null || targetId.trim().isEmpty) return;
    await _copyTargetId();
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Copied $targetId to clipboard.')));
  }

  @override
  Widget build(BuildContext context) {
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
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _auditActorKindChipBg(row.actorKind),
                    border: Border.all(
                      color: _auditActorKindChipFg(
                        row.actorKind,
                      ).withValues(alpha: 0.5),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text(
                    _auditActorKindChipLabel(row.actorKind),
                    style: AppTextStyles.mono7(
                      color: _auditActorKindChipFg(row.actorKind),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _auditActorIdentityLabel(row),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            if (row.targetId != null && row.targetId!.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  if (row.targetKind != null) ...[
                    Text(
                      '${row.targetKind}:',
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      row.targetId!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono11(color: AppColors.textPrimary),
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
                    onPressed: () => _copyTargetIdFrom(context),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              formatAuditTimestamp(row.occurredAt),
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            if (row.adminReason != null && row.adminReason!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Admin reason: ${row.adminReason}',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: Key('admin_asa_audit_row_payload_toggle_${row.eventId}'),
                onPressed: onTogglePayload,
                child: Text(expanded ? 'Hide payload' : 'View payload'),
              ),
            ),
            if (expanded)
              Container(
                key: Key('admin_asa_audit_row_payload_${row.eventId}'),
                margin: const EdgeInsets.only(top: 4),
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.backgroundMid,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SelectableText(
                  formatPayload(row.payload),
                  style: AppTextStyles.mono11(color: AppColors.textPrimary),
                ),
              ),
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
  switch (action) {
    case 'team.users.invite':
      return 'Invited team member';
    case 'team.users.deactivate':
      return 'Suspended team member';
    case 'team.users.reactivate':
      return 'Reactivated team member';
    case 'team.users.soft_delete':
      return 'Soft-deleted team member';
    case 'team.users.reset_password':
      return 'Sent password reset email';
    case 'team.users.reset_mfa':
      return 'Reset two-factor sign-in';
    case 'team.roles.create_custom':
      return 'Created custom role';
    case 'team.roles.assign':
      return 'Assigned role';
    case 'team.roles.revoke':
      return 'Revoked role grant';
    case 'team.org_unit.move':
      return 'Moved an org unit';
    case 'team.session.force_logout':
      return 'Signed out a team member session';
    case 'auth.user.signed_in':
    case 'auth.signed_in':
      return 'Sign-in';
    case 'auth.session_revoked':
      return 'Session revoked';
    case 'auth.all_sessions_revoked':
      return 'Signed out of all devices';
    case 'auth.user.password_changed':
    case 'auth.password_changed':
      return 'Password changed';
    case 'auth.password_reset_requested':
      return 'Password reset requested';
    case 'auth.password_reset_confirmed':
      return 'Password reset completed';
    case 'auth.mfa_totp_enrolled':
      return 'Two-factor sign-in enabled';
    case 'auth.mfa_totp_enroll_failed':
      return 'Two-factor sign-in setup failed';
    case 'auth.user.mfa_factor_removed':
    case 'auth.mfa_factor_removed':
      return 'Two-factor sign-in disabled';
    case 'auth.user.mfa_recovery_requested':
    case 'auth.mfa_recovery_requested':
      return 'Two-factor sign-in recovery requested';
    case 'auth.role_grant_created':
      return 'Role grant added';
    case 'auth.role_grant_revoked':
      return 'Role grant revoked';
    case 'auth.custom_role_created':
      return 'Custom role created';
    case 'auth.custom_role_updated':
      return 'Custom role updated';
    case 'auth.custom_role_deleted':
      return 'Custom role deleted';
    case 'auth.invite_created':
      return 'Invite created';
    case 'auth.invite_revoked':
    case 'invite.cancel':
      return 'Invite cancelled';
    case 'auth.invite_accepted':
      return 'Invite accepted';
    case 'auth.user_suspended':
      return 'User suspended';
    case 'auth.user_reactivated':
      return 'User reactivated';
    case 'auth.user_soft_deleted':
      return 'User soft-deleted';
    case 'admin.session.force_logout':
      return 'Forced session logout';
    case 'admin.users.reset_mfa_factors':
      return 'Reset member two-factor sign-in';
    case 'admin.users.reset_password':
      return 'Initiated password reset';
    case 'admin.users.erasure.requested':
      return 'Requested erasure';
    case 'admin.users.erasure.confirmed':
      return 'Confirmed erasure';
    case 'audit.export.requested':
      return 'Exported audit log';
    case 'auth.password.change':
      return 'Password changed';
    case 'auth.mfa.enroll':
      return 'Two-factor sign-in enabled';
    default:
      final tail = action.contains('.')
          ? action.substring(action.lastIndexOf('.') + 1)
          : action;
      if (tail.isEmpty) return action;
      final words = tail.split('_');
      final first = words.first;
      final head = first.isEmpty
          ? ''
          : first.substring(0, 1).toUpperCase() + first.substring(1);
      final rest = words.skip(1).join(' ');
      return rest.isEmpty ? head : '$head $rest';
  }
}

String _auditActorIdentityLabel(AuditLogRow row) {
  final name = row.actorDisplayName.trim().isEmpty
      ? row.actorUserId
      : row.actorDisplayName.trim();
  final email = row.actorEmail.trim();
  if (email.isEmpty || email == name) return name;
  return '$name • $email';
}

String _auditActorKindChipLabel(AuditActorKind kind) {
  switch (kind) {
    case AuditActorKind.teamMember:
      return 'team';
    case AuditActorKind.forgeAdmin:
      return 'F&F admin';
    case AuditActorKind.servicePrincipal:
      return 'service';
  }
}

Color _auditActorKindChipFg(AuditActorKind kind) {
  switch (kind) {
    case AuditActorKind.teamMember:
      return AppColors.sunsetDark;
    case AuditActorKind.forgeAdmin:
      return AppColors.negative;
    case AuditActorKind.servicePrincipal:
      return AppColors.textSecondary;
  }
}

Color _auditActorKindChipBg(AuditActorKind kind) {
  switch (kind) {
    case AuditActorKind.teamMember:
      return AppColors.sunset.withValues(alpha: 0.15);
    case AuditActorKind.forgeAdmin:
      return AppColors.negative.withValues(alpha: 0.15);
    case AuditActorKind.servicePrincipal:
      return AppColors.borderSubtle.withValues(alpha: 0.5);
  }
}

/// Format an audit `occurred_at` timestamp for display. The contract
/// pins operator-local timezone (`phase_7_55_time_boundary_contract.md`);
/// without a per-operator tz lookup at this layer the surface falls
/// back to the browser's local timezone, which is the closest
/// approximation available client-side. Mirrors operator web's compact
/// `yyyy-MM-dd HH:mm` rendering.
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
/// Exposed for widget tests so the "View payload" pin can assert
/// against the rendered JSON directly.
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

class _AuditLogErrorPanel extends StatelessWidget {
  const _AuditLogErrorPanel({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_asa_load_error'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 18, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: () => onRetry(), child: const Text('Retry')),
        ],
      ),
    );
  }
}

String defaultAdminAuditLogCsvFilename(DateTime now) {
  final utc = now.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  return 'forge_flow_audit_log_$y$m${d}_$hh${mm}_utc.csv';
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
