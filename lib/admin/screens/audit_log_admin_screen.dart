// Lane B B8 — F&F admin audit log screen with hierarchy filtering.
//
// Single-screen admin surface that lists rows from `public.audit_logs`
// filtered by:
//
//   * Scope (business-wide, org_unit subtree, or single location).
//   * Time range (`from`/`to` UTC timestamps).
//   * Actor user_id (optional UUID filter).
//   * Action string (optional, e.g. `auth.password_changed`).
//
// The screen reads through [AuditLogAdminGateway]; production binds
// [HttpAuditLogAdminGateway] which posts to the B8 proxy route
// (`GET /v1/admin/auth/audit-log/hierarchy`). Demo / widget-test
// builds use [InMemoryAuditLogAdminGateway]. No `kDemoMode` carve-out
// on the reader path — the screen renders identically against either
// gateway.
//
// Scope picker:
//   * If the caller supplies a [rootNode] (Business → Org Unit →
//     Location tree), the screen renders the shared [InheritanceTree]
//     widget for visualization AND a paired radio + dropdown for
//     scope selection. Tapping a row in the tree updates the
//     dropdown.
//   * If no [rootNode] is supplied (admin shell has not yet wired an
//     OrgUnits gateway), the screen falls back to scope_type +
//     org_unit_id / location_id text fields. This is an honest
//     follow-up — the slice spec calls for the tree as the picker,
//     and a future slice can wire the org_units admin gateway.
//
// admin_reason is required for every read. The screen surfaces a
// text field at the top; the gateway carries the value to the proxy
// in the `admin_reason` header. CLAUDE.md "Proxy & API Conventions"
// posture.
//
// Plain English copy throughout per `project_ux_writing_standard.md`.

import 'package:flutter/material.dart';

import '../../domain/models/inheritance_tree_node.dart';
import '../../services/auth/actor_kind_label_catalog.dart';
import '../../theme/app_theme.dart';
import '../../widgets/inheritance_tree.dart';
import '../services/audit_log_admin_gateway.dart';

class AuditLogAdminScreen extends StatefulWidget {
  const AuditLogAdminScreen({
    super.key,
    required this.gateway,
    this.rootNode,
    this.initialAdminReason = '',
    this.initialOperatorId,
    this.initialLocationId,
    this.clock,
  });

  /// Read gateway. Production: HTTP backed. Demo / tests: in-memory.
  final AuditLogAdminGateway gateway;

  /// Optional Business → Org Unit → Location tree. When non-null the
  /// screen renders the shared [InheritanceTree] as the scope picker.
  /// When null the screen falls back to text-field scope inputs.
  final InheritanceTreeNode? rootNode;

  /// Optional admin_reason pre-fill (e.g. when the screen is opened
  /// from a deep-link with a support-ticket id baked in).
  final String initialAdminReason;

  /// Optional operator_id pre-fill. When the admin shell already knows
  /// which operator the support session is anchored on, threading it
  /// here saves a UUID copy/paste.
  final String? initialOperatorId;

  /// Optional location_id pre-fill (paired with [initialOperatorId]
  /// for tenant-transaction anchoring).
  final String? initialLocationId;

  /// Optional clock override for deterministic widget tests.
  final DateTime Function()? clock;

  @override
  State<AuditLogAdminScreen> createState() => _AuditLogAdminScreenState();
}

class _AuditLogAdminScreenState extends State<AuditLogAdminScreen> {
  late final TextEditingController _adminReasonController;
  late final TextEditingController _operatorIdController;
  late final TextEditingController _locationIdController;
  late final TextEditingController _orgUnitIdController;
  late final TextEditingController _locationFilterController;
  late final TextEditingController _actorUserIdController;
  late final TextEditingController _actionController;
  late final TextEditingController _fromController;
  late final TextEditingController _toController;

  AuditLogAdminScopeType _scopeType = AuditLogAdminScopeType.operatorWide;
  bool _loading = false;
  String? _loadError;
  List<AuditLogAdminRow> _rows = const <AuditLogAdminRow>[];
  String? _nextCursor;

  @override
  void initState() {
    super.initState();
    final now = (widget.clock ?? DateTime.now)().toUtc();
    final defaultTo = now;
    final defaultFrom = defaultTo.subtract(const Duration(days: 7));
    _adminReasonController =
        TextEditingController(text: widget.initialAdminReason);
    _operatorIdController =
        TextEditingController(text: widget.initialOperatorId ?? '');
    _locationIdController =
        TextEditingController(text: widget.initialLocationId ?? '');
    _orgUnitIdController = TextEditingController();
    _locationFilterController = TextEditingController();
    _actorUserIdController = TextEditingController();
    _actionController = TextEditingController();
    _fromController = TextEditingController(text: defaultFrom.toIso8601String());
    _toController = TextEditingController(text: defaultTo.toIso8601String());
  }

  @override
  void dispose() {
    _adminReasonController.dispose();
    _operatorIdController.dispose();
    _locationIdController.dispose();
    _orgUnitIdController.dispose();
    _locationFilterController.dispose();
    _actorUserIdController.dispose();
    _actionController.dispose();
    _fromController.dispose();
    _toController.dispose();
    super.dispose();
  }

  Future<void> _runQuery({String? cursor}) async {
    final reason = _adminReasonController.text.trim();
    if (reason.isEmpty) {
      setState(() {
        _loadError =
            'Add a reason for this audit log read before running the '
            'filter. Every admin read is logged.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final result = await widget.gateway.listByHierarchy(
        AuditLogAdminListCommand(
          adminReason: reason,
          scopeType: _scopeType,
          operatorId: _nonEmpty(_operatorIdController.text),
          locationId: _nonEmpty(_locationIdController.text),
          orgUnitId: _scopeType == AuditLogAdminScopeType.orgUnit
              ? _nonEmpty(_orgUnitIdController.text)
              : null,
          locationFilter: _scopeType == AuditLogAdminScopeType.location
              ? _nonEmpty(_locationFilterController.text)
              : null,
          from: _parseIso(_fromController.text),
          to: _parseIso(_toController.text),
          actorUserId: _nonEmpty(_actorUserIdController.text),
          action: _nonEmpty(_actionController.text),
          beforeId: cursor,
        ),
      );
      if (!mounted) return;
      setState(() {
        _rows = result.rows;
        _nextCursor = result.nextCursor;
        _loading = false;
      });
    } on AuditLogAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not read the audit log: $error';
        _loading = false;
      });
    }
  }

  void _onTreeNodeTap(InheritanceTreeNode node) {
    setState(() {
      switch (node.scopeKind) {
        case InheritanceTreeScopeKind.business:
          _scopeType = AuditLogAdminScopeType.operatorWide;
          _orgUnitIdController.clear();
          _locationFilterController.clear();
          break;
        case InheritanceTreeScopeKind.orgUnit:
          _scopeType = AuditLogAdminScopeType.orgUnit;
          _orgUnitIdController.text = node.scopeId;
          _locationFilterController.clear();
          break;
        case InheritanceTreeScopeKind.location:
          _scopeType = AuditLogAdminScopeType.location;
          _locationFilterController.text = node.scopeId;
          _orgUnitIdController.clear();
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_audit_log_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildHeader(),
            const SizedBox(height: 14),
            _buildAdminReasonField(),
            const SizedBox(height: 12),
            if (widget.rootNode != null) ...<Widget>[
              _buildSubsectionTitle('Scope'),
              const SizedBox(height: 6),
              InheritanceTree(
                rootNode: widget.rootNode!,
                onNodeTap: _onTreeNodeTap,
                annotationBuilder: (context, node) =>
                    const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
            ],
            _buildScopeRow(),
            const SizedBox(height: 12),
            _buildTimeRangeRow(),
            const SizedBox(height: 12),
            _buildFilterRow(),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                ElevatedButton(
                  key: const Key('admin_audit_log_run_button'),
                  onPressed: _loading ? null : () => _runQuery(),
                  child: Text(_loading ? 'Loading…' : 'Run filter'),
                ),
                const SizedBox(width: 12),
                if (_nextCursor != null && !_loading)
                  TextButton(
                    key: const Key('admin_audit_log_next_button'),
                    onPressed: () => _runQuery(cursor: _nextCursor),
                    child: const Text('Load older rows'),
                  ),
              ],
            ),
            if (_loadError != null) ...<Widget>[
              const SizedBox(height: 12),
              _ErrorBanner(message: _loadError!),
            ],
            const SizedBox(height: 12),
            Expanded(child: _buildResults()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          'Audit log',
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'Browse the hash-chained audit log scoped to a business, a '
          'region or district, or a single location. Every read is '
          'logged with the reason you provide.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildSubsectionTitle(String label) {
    return Text(
      label,
      style: AppTextStyles.body13(color: AppColors.textSecondary)
          .copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _buildAdminReasonField() {
    return TextField(
      key: const Key('admin_audit_log_admin_reason'),
      controller: _adminReasonController,
      decoration: const InputDecoration(
        labelText: 'Reason for reading the audit log',
        hintText:
            'e.g. "Support ticket #4821 — verifying password change history"',
      ),
    );
  }

  Widget _buildScopeRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          flex: 1,
          child: DropdownButtonFormField<AuditLogAdminScopeType>(
            key: const Key('admin_audit_log_scope_type'),
            initialValue: _scopeType,
            decoration: const InputDecoration(labelText: 'Scope'),
            items: const <DropdownMenuItem<AuditLogAdminScopeType>>[
              DropdownMenuItem(
                value: AuditLogAdminScopeType.operatorWide,
                child: Text('Whole business'),
              ),
              DropdownMenuItem(
                value: AuditLogAdminScopeType.orgUnit,
                child: Text('Region / district'),
              ),
              DropdownMenuItem(
                value: AuditLogAdminScopeType.location,
                child: Text('Single location'),
              ),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _scopeType = value);
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 1,
          child: TextField(
            key: const Key('admin_audit_log_operator_id'),
            controller: _operatorIdController,
            decoration: const InputDecoration(
              labelText: 'Operator ID',
              hintText: 'uuid; optional when token already scoped',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 1,
          child: TextField(
            key: const Key('admin_audit_log_location_id'),
            controller: _locationIdController,
            decoration: const InputDecoration(
              labelText: 'Location ID',
              hintText: 'uuid; optional when token already scoped',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTimeRangeRow() {
    return Row(
      children: <Widget>[
        Expanded(
          child: TextField(
            key: const Key('admin_audit_log_from'),
            controller: _fromController,
            decoration: const InputDecoration(
              labelText: 'From (UTC ISO 8601)',
              hintText: '2026-05-06T00:00:00Z',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const Key('admin_audit_log_to'),
            controller: _toController,
            decoration: const InputDecoration(
              labelText: 'To (UTC ISO 8601)',
              hintText: '2026-05-13T00:00:00Z',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterRow() {
    final showOrgUnit = _scopeType == AuditLogAdminScopeType.orgUnit;
    final showLocationFilter =
        _scopeType == AuditLogAdminScopeType.location;
    return Row(
      children: <Widget>[
        if (showOrgUnit)
          Expanded(
            child: TextField(
              key: const Key('admin_audit_log_org_unit_id'),
              controller: _orgUnitIdController,
              decoration: const InputDecoration(
                labelText: 'Org unit ID',
                hintText: 'uuid for the region / district to filter by',
              ),
            ),
          ),
        if (showLocationFilter)
          Expanded(
            child: TextField(
              key: const Key('admin_audit_log_location_filter'),
              controller: _locationFilterController,
              decoration: const InputDecoration(
                labelText: 'Location filter',
                hintText: 'uuid for the location to filter by',
              ),
            ),
          ),
        if (showOrgUnit || showLocationFilter) const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const Key('admin_audit_log_actor_user_id'),
            controller: _actorUserIdController,
            decoration: const InputDecoration(
              labelText: 'Actor user ID',
              hintText: 'optional uuid',
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: TextField(
            key: const Key('admin_audit_log_action'),
            controller: _actionController,
            decoration: const InputDecoration(
              labelText: 'Action',
              hintText: 'optional, e.g. auth.password_changed',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(
        key: Key('admin_audit_log_loading'),
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
    if (_rows.isEmpty) {
      return Center(
        key: const Key('admin_audit_log_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'No audit log rows match this filter yet. Adjust the '
              'scope, time range, or actor / action filters and try '
              'again.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      key: const Key('admin_audit_log_list'),
      itemCount: _rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final row = _rows[index];
        return _AuditLogRowTile(row: row);
      },
    );
  }
}

class _AuditLogRowTile extends StatelessWidget {
  const _AuditLogRowTile({required this.row});

  final AuditLogAdminRow row;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_audit_log_row_${row.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  row.action,
                  style: AppTextStyles.body13(color: AppColors.textPrimary)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                row.occurredAt.toIso8601String(),
                style:
                    AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Actor: ${_actorLabel(row)} • Target: ${_targetLabel(row)}',
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          if (row.locationId != null)
            Text(
              'Location: ${row.locationId}',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          if (row.adminReason != null && row.adminReason!.isNotEmpty)
            Text(
              'Admin reason: ${row.adminReason}',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
        ],
      ),
    );
  }

  static String _actorLabel(AuditLogAdminRow row) {
    // Wave 2 AC-1 - raw actor_kind enum strings ("user", "forge_admin",
    // "service_principal", "system", ...) are translated to plain
    // English via the shared catalog so the admin row reads like UX
    // copy instead of a wire-format dump.
    final label = ActorKindLabelCatalog.labelFor(row.actorKind);
    if (row.actorUserId != null) return '$label ${row.actorUserId}';
    if (row.actorPrincipalId != null) {
      return '$label ${row.actorPrincipalId}';
    }
    return label;
  }

  static String _targetLabel(AuditLogAdminRow row) {
    if (row.targetKind == null && row.targetId == null) return '—';
    return '${row.targetKind ?? '?'} ${row.targetId ?? ''}'.trim();
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_audit_log_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
    );
  }
}

String? _nonEmpty(String raw) {
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _parseIso(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  try {
    return DateTime.parse(trimmed).toUtc();
  } catch (_) {
    return null;
  }
}
