// Phase 11A.14 - F&F Operations Console "Audited support actions"
// surface.
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

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/audited_support_actions_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
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
    this.idempotencyKeyFactory,
    this.onChangeOperator,
    this.graceWindowClock,
    this.graceWindowTickInterval = const Duration(minutes: 1),
  });

  final AuditedSupportActionsAdminGateway gateway;
  final String actorUserId;
  final OperatorPickerResult pickedOperator;

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

  final String Function()? idempotencyKeyFactory;

  /// Re-opens the operator picker. Wired by the route shell so the
  /// admin can switch operators without leaving the surface.
  final VoidCallback? onChangeOperator;

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

  @override
  State<AuditedSupportActionsAdminScreen> createState() =>
      _AuditedSupportActionsAdminScreenState();
}

class _AuditedSupportActionsAdminScreenState
    extends State<AuditedSupportActionsAdminScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _loadError;
  String? _actionError;

  /// Accumulated rows across pagination cursors. Each `Apply filters`
  /// or refresh resets this to the first page; `Load more` appends.
  List<AuditLogRow> _rows = const <AuditLogRow>[];
  String? _nextCursor;
  List<SupportActionsMember> _members = const <SupportActionsMember>[];
  AuditLogFilters _filters = AuditLogFilters.empty;
  int _refreshGeneration = 0;

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
      final results = await Future.wait<Object>([
        widget.gateway.listAuditLog(operatorId: operatorId, filters: _filters),
        widget.gateway.listMembers(operatorId: operatorId),
      ]);
      if (generation != _refreshGeneration) return;
      final page = results[0] as AuditLogPage;
      final members = results[1] as List<SupportActionsMember>;
      if (!mounted) return;
      setState(() {
        _rows = page.rows;
        _nextCursor = page.nextCursor;
        _members = members;
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

  Future<SupportActionsMember?> _pickMember(String title) async {
    return showDialog<SupportActionsMember>(
      context: context,
      builder: (_) => _MemberPickerDialog(title: title, members: _members),
    );
  }

  // --- Audit log actions -------------------------------------------------

  Future<void> _onApplyFilters(AuditLogFilters next) async {
    setState(() => _filters = next);
    await _refresh();
  }

  Future<void> _onExportCsv() async {
    final reason = await _promptAdminReason('Export the filtered audit log');
    if (reason == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.exportAuditLogCsv(
        operatorId: widget.pickedOperator.operatorId,
        filters: _filters,
        idempotencyKey: _nextIdempotencyKey('audit-log-export'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      );
    }, successHint: 'Export queued. Audit row written.');
  }

  // --- Actions panel actions ---------------------------------------------

  Future<void> _onResetMfa() async {
    if (!widget.canResetMfaFactors) return;
    final member = await _pickMember('Reset MFA for which member?');
    if (member == null) return;
    final reason = await _promptAdminReason(
      'Reset MFA for ${member.displayName}',
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
      successHint: 'Reset MFA for ${member.displayName}',
    );
  }

  Future<void> _onPasswordReset() async {
    final member = await _pickMember('Send a password reset to which member?');
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
    await _runAndRefresh(() async {
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
      // CODE_OPS_DEBT carry-over #2 — kick off the chip's tick timer
      // so the "Xh Ym remaining" countdown refreshes in place.
      _startGraceWindowTicker();
    },
        successHint:
            'PII erasure recorded for ${member.displayName}; reversal '
            'available within the 24-hour grace window.');
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
    return Container(
      key: const Key('admin_audited_support_actions_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AdminPageHeader(
              title: 'Audit & support',
              subtitle:
                  '${widget.pickedOperator.operatorBusinessName}: audit '
                  'history and gated support actions.',
              trailing: _buildHeaderActions(),
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(key: Key('admin_asa_readonly_banner')),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_asa_action_error'),
                message: _actionError!,
              ),
            if (_lastErasure != null)
              _GraceWindowChip(
                key: const Key('admin_asa_grace_window_chip'),
                erasure: _lastErasure!,
                memberDisplay: _lastErasureMember,
                now: _graceNow(),
                canReverse: widget.editingEnabled,
                onReverse: _onReverseLastErasure,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget? _buildHeaderActions() {
    final children = <Widget>[];
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
    if (children.isEmpty) return null;
    return Wrap(spacing: 8, runSpacing: 8, children: children);
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
      return _ErrorBanner(
        key: const Key('admin_asa_load_error'),
        message: _loadError!,
      );
    }
    return SingleChildScrollView(
      key: const Key('admin_asa_body'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _SupportAuditSummaryStrip(
            rows: _rows,
            members: _members,
            hasMoreRows: _nextCursor != null,
          ),
          const SizedBox(height: 16),
          _AuditLogCard(
            rows: _rows,
            nextCursor: _nextCursor,
            loadingMore: _loadingMore,
            filters: _filters,
            members: _members,
            canExport: widget.editingEnabled && widget.canExportAuditLog,
            onApplyFilters: _onApplyFilters,
            onLoadMore: _loadMore,
            onExportCsv: _onExportCsv,
          ),
          const SizedBox(height: 16),
          _ActionsPanelCard(
            editingEnabled: widget.editingEnabled,
            canResetMfaFactors: widget.canResetMfaFactors,
            canIssuePairedErasure: widget.canIssuePairedErasure,
            onResetMfa: _onResetMfa,
            onPasswordReset: _onPasswordReset,
            onIssueErasure: _onIssueErasure,
          ),
        ],
      ),
    );
  }
}

class _SupportAuditSummaryStrip extends StatelessWidget {
  const _SupportAuditSummaryStrip({
    required this.rows,
    required this.members,
    required this.hasMoreRows,
  });

  final List<AuditLogRow> rows;
  final List<SupportActionsMember> members;
  final bool hasMoreRows;

  @override
  Widget build(BuildContext context) {
    final forgeAdminRows = rows
        .where((row) => row.actorKind == AuditActorKind.forgeAdmin)
        .length;
    return AdminStatStrip(
      items: <AdminStatItem>[
        AdminStatItem(
          label: 'Visible audit rows',
          value: rows.length.toString(),
          icon: Icons.history_outlined,
          tone: AppColors.peacock,
        ),
        AdminStatItem(
          label: 'Support actions',
          value: forgeAdminRows.toString(),
          icon: Icons.support_agent_outlined,
          tone: AppColors.sunset,
        ),
        AdminStatItem(
          label: 'Team members',
          value: members.length.toString(),
          icon: Icons.people_alt_outlined,
          tone: AppColors.ocean,
        ),
        AdminStatItem(
          label: 'More rows',
          value: hasMoreRows ? 'Yes' : 'No',
          icon: Icons.expand_more,
          tone: hasMoreRows ? AppColors.warning : AppColors.positive,
        ),
      ],
    );
  }
}

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
    return AdminCard(
      child: Column(
        key: const Key('admin_asa_actions_panel'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Actions',
            style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'Each action asks for a reason and writes a row to the audit log '
            'plus the F&F internal action log. Multi-factor sign-in is '
            'required for the most sensitive actions.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          _ActionRow(
            keyId: 'admin_asa_action_reset_mfa',
            title: 'Reset member MFA',
            description:
                'Removes the member\'s MFA factors so they can re-enroll. '
                'Multi-factor sign-in required.',
            buttonLabel: 'Reset MFA',
            enabled: editingEnabled && canResetMfaFactors,
            onPressed: onResetMfa,
            mfaTag: true,
          ),
          const SizedBox(height: 8),
          _ActionRow(
            keyId: 'admin_asa_action_password_reset',
            title: 'Initiate password reset',
            description:
                'Sends the member a recovery email to set a new password.',
            buttonLabel: 'Send reset email',
            enabled: editingEnabled,
            onPressed: onPasswordReset,
            mfaTag: false,
          ),
          const SizedBox(height: 8),
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
    return AdminCard(
      child: Column(
        key: const Key('admin_asa_audit_log'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Audit log',
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              if (canExport)
                FilledButton.icon(
                  key: const Key('admin_asa_audit_log_export'),
                  onPressed: onExportCsv,
                  style: AdminButtonStyles.primary,
                  icon: const Icon(Icons.download, size: 16),
                  label: const Text('Export CSV'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Cursor-paginated rows scoped to this operator. Sorted newest '
            'first. Filters and the CSV export are audit-logged. Times are '
            'shown in your browser local timezone.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
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
                'No audit rows match the current filters.',
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
                    loadingMore ? 'Loading more rows...' : 'Load more rows',
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
            Text(
              'Audit rows are newest first',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
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
                    child: Text('MFA factor'),
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
              child: DropdownButtonFormField<AuditLogTimeWindow?>(
                key: const Key('admin_asa_filter_time_window'),
                initialValue: _draft.timeWindow,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Time window',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<AuditLogTimeWindow?>>[
                  const DropdownMenuItem<AuditLogTimeWindow?>(
                    value: null,
                    child: Text('Any time'),
                  ),
                  for (final w in AuditLogTimeWindow.values)
                    DropdownMenuItem<AuditLogTimeWindow?>(
                      value: w,
                      child: Text(w.displayLabel),
                    ),
                ],
                onChanged: (v) =>
                    setState(() => _draft = _draft.copyWith(timeWindow: v)),
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
const List<String> kAuditLogFilterableActions = <String>[
  'team.users.invite',
  'team.users.deactivate',
  'team.users.reactivate',
  'team.users.soft_delete',
  'team.roles.create_custom',
  'team.roles.delete_custom',
  'team.roles.edit_seeded',
  'team.org_unit.move',
  'team.location.move',
  'team.session.force_logout',
  'auth.password.change',
  'auth.mfa.enroll',
  'admin.session.force_logout',
  'admin.users.reset_mfa_factors',
  'admin.users.reset_password',
  'admin.users.erasure.requested',
  'admin.users.erasure.confirmed',
  'audit.export.requested',
];

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
              '${row.actorDisplayName} (${row.actorEmail})',
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
  switch (action) {
    case 'team.users.invite':
      return 'Invited team member';
    case 'team.users.deactivate':
      return 'Deactivated team member';
    case 'team.users.reactivate':
      return 'Reactivated team member';
    case 'team.users.soft_delete':
      return 'Soft-deleted team member';
    case 'team.roles.create_custom':
      return 'Created custom role';
    case 'team.roles.delete_custom':
      return 'Deleted custom role';
    case 'team.roles.edit_seeded':
      return 'Edited seeded role permissions';
    case 'team.org_unit.move':
      return 'Moved org unit';
    case 'team.location.move':
      return 'Moved location';
    case 'admin.session.force_logout':
      return 'Forced session logout';
    case 'admin.users.reset_mfa_factors':
      return 'Reset member MFA';
    case 'admin.users.reset_password':
      return 'Initiated password reset';
    case 'admin.users.erasure.requested':
      return 'Requested erasure';
    case 'admin.users.erasure.confirmed':
      return 'Confirmed erasure';
    case 'audit.export.requested':
      return 'Exported audit log';
    case 'auth.password.change':
      return 'Changed password';
    case 'auth.mfa.enroll':
      return 'Enrolled MFA factor';
    default:
      return action;
  }
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
  return '$y-$m-$d $hh:$mm local (UTC ${utc.toUtc().toIso8601String()})';
}

/// Render the `audit_logs.payload` JSONB diff in a readable form.
/// Sorts top-level keys for stable output and indents nested maps
/// one level. Exposed for widget tests so the "View payload" pin can
/// assert against the rendered text directly.
@visibleForTesting
String formatPayload(Map<String, Object?> payload) {
  if (payload.isEmpty) return '(empty payload)';
  final keys = payload.keys.toList()..sort();
  final buf = StringBuffer();
  for (final key in keys) {
    final value = payload[key];
    if (value is Map) {
      buf.writeln('$key:');
      final nested = (value).cast<String, Object?>();
      final nestedKeys = nested.keys.toList()..sort();
      for (final nk in nestedKeys) {
        buf.writeln('  $nk: ${nested[nk]}');
      }
    } else {
      buf.writeln('$key: $value');
    }
  }
  return buf.toString().trimRight();
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
    final iconData =
        reversible ? Icons.timelapse_outlined : Icons.lock_outline;
    final label = reversible
        ? 'Erasure reversible - ${formatGraceWindowRemaining(
            now: now,
            endsAt: erasure.gracePeriodEndsAt,
          )} remaining'
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
                  style: AppTextStyles.body13(color: AppColors.textPrimary)
                      .copyWith(fontWeight: FontWeight.w600),
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
    return AlertDialog(
      key: const Key('admin_asa_reason_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(widget.title, style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 460,
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
      ),
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
    );
  }
}

class _MemberPickerDialog extends StatefulWidget {
  const _MemberPickerDialog({required this.title, required this.members});

  final String title;
  final List<SupportActionsMember> members;

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
    return AlertDialog(
      key: const Key('admin_asa_member_picker_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(widget.title, style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 460,
        child: widget.members.isEmpty
            ? Text(
                'This operator has no members yet.',
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
      ),
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
    return AlertDialog(
      key: const Key('admin_asa_second_approver_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Second F&F admin confirmation',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 480,
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
      ),
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
    );
  }
}
