// Phase 11W.7 / Wave A2 - Operator Web My Account screen.
//
// "My account" is the operator-user-facing surface (sign-in identity,
// security, MFA, and active sessions). Sibling to AccountScreen, which
// owns the business-identity surface (business name, logo, currency, locale,
// week-start, rollover hour).
//
// Four sections per Lane B9.2:
//
//   * Profile   — display name, email, phone, business. Read-only.
//                 Phone edits route to the operator mobile app.
//   * Security  — password change and sign-in audit-log entry point.
//   * MFA       — enrollment status (read off `session.mfaEnrolled`)
//                 + Enroll / View backup codes.
//   * Active Sessions — current and other device sessions with a
//                 "sign out all other sessions" action.
//
// Backend reuse: every mutation is designed to flow through the
// existing Phase 9 auth tables and the existing audit log. No new
// proxy routes, no new permission keys, no new audit hooks.
// `11W.7` ships the surface; `11W.0.live` swaps the local-state
// stubs for real proxy calls (mirrors the gateway-follows-shell
// pattern Phase 11A used).
//
// Permission gate: keys off `session.roles`. Operator owners and
// admins get the full security surface; location managers see Profile
// and Active Sessions and the MFA / Password buttons render disabled with
// tooltip copy ("Only operator admins can change MFA"). Mirrors the
// gate the Phase 9 proxy enforces server-side — the UI is the
// friendly-error layer.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label, button, status, confirmation, error message reads as
// if training the user. Plain English, no engineering jargon, 1-line
// "what this is" header + 1-2 sentence "what happens when you click"
// explainer on non-obvious actions.
//
// Layout note: the screen uses `SingleChildScrollView` + `Column`
// rather than a top-level `ListView`. Functionally equivalent for the
// operator (vertical scroll over the same four section cards), and
// every section's Element is built eagerly so widget tests can
// `find.byKey` against any section without first scrolling it into
// view. Sections that *do* live below the fold at the smallest tablet
// breakpoint still need `tester.ensureVisible` before tap because the
// hit-test boundary is the rendered viewport — eager build only fixes
// finder lookup, not hit testing.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../account/mfa_card_controller.dart';
import '../account/operator_web_account_actions.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/operator_web_url_launcher.dart';
import '../services/web_account_gateway.dart';

/// V1 My account screen. The router renders this at
/// `kOperatorWebNavMyAccount` once onboarding completes.
class MyAccountScreen extends StatefulWidget {
  const MyAccountScreen({super.key, required this.session, this.actions});

  final OperatorWebSession session;
  final OperatorWebAccountActions? actions;

  @override
  State<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends State<MyAccountScreen> {
  late MfaCardController _mfaController;

  // Demo-mode toast under the Password section. Auto-clears after
  // [_kToastVisibleDuration] so the surface doesn't accumulate stale
  // confirmations across the operator's session.
  String? _passwordToast;
  Timer? _passwordToastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);

  List<AccountActiveSessionEntry> _activeSessions =
      const <AccountActiveSessionEntry>[];
  bool _activeSessionsLoading = false;
  String? _activeSessionsError;
  bool _signingOutOtherSessions = false;

  // Layout breakpoint for the Profile section's 2-column wrap. Sized
  // so that:
  //   * inside the shell at 768px viewport (body column ≈ 548px) →
  //     single-column stack.
  //   * inside the shell at 1024px viewport (body column ≈ 804px) →
  //     2-column wrap.
  //   * standalone (widget tests rendering MyAccountScreen without the
  //     side nav) at 768px → single-column stack; at 1024px →
  //     2-column wrap.
  static const double _kProfileTwoColumnBreakpoint = 800;

  @override
  void initState() {
    super.initState();
    _mfaController = _buildMfaController();
    _mfaController.addListener(_onMfaControllerChanged);
    _mfaController.start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadActiveSessions();
    });
  }

  @override
  void didUpdateWidget(covariant MyAccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync the demo-mode flag when the parent rebuilds with a new
    // session (e.g. role-switch in tests). Preserves a flip-from-false
    // → true that has happened in this widget's lifetime.
    if (oldWidget.actions != widget.actions ||
        oldWidget.session.uid != widget.session.uid) {
      _mfaController.removeListener(_onMfaControllerChanged);
      _mfaController.dispose();
      _mfaController = _buildMfaController();
      _mfaController.addListener(_onMfaControllerChanged);
      _mfaController.start();
      _loadActiveSessions();
    } else {
      _mfaController.update(
        sessionMfaEnrolled: widget.session.mfaEnrolled,
        actions: widget.actions,
      );
    }
  }

  @override
  void dispose() {
    _passwordToastTimer?.cancel();
    _mfaController.removeListener(_onMfaControllerChanged);
    _mfaController.dispose();
    super.dispose();
  }

  MfaCardController _buildMfaController() {
    return MfaCardController(
      initialMfaEnrolled: widget.session.mfaEnrolled,
      actions: widget.actions,
      autoSync: true,
    );
  }

  void _onMfaControllerChanged() {
    if (!mounted) return;
    setState(() {});
  }

  bool get _canWriteAccount {
    final roles = widget.session.roles;
    return roles.contains('operator_owner') ||
        roles.contains('operator_admin') ||
        widget.session.permissions.contains(
          PermissionKeys.integrationsConfigure,
        );
  }

  String get _readOnlyTooltipMfa =>
      'Only operator admins can change MFA. If your role should include '
      'this, ask the operator owner on your account to update your role.';

  String get _readOnlyTooltipPassword =>
      'Only operator admins can change account passwords from the web '
      'console. Floor staff and location managers can rotate their own '
      'password from the operator mobile app under Settings → Security.';

  Future<void> _handleEnrollMfa() async {
    if (!_canWriteAccount) return;
    final actions = widget.actions;
    MfaEnrollmentArtifact? artifact;
    if (actions != null) {
      try {
        artifact = await actions.beginAccountMfaEnrollment(
          email: widget.session.email,
        );
      } catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start MFA enrollment: $error')),
        );
        return;
      }
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _MfaEnrollDialog(
        operatorEmail: widget.session.email,
        artifact: artifact,
        onConfirm: actions == null || artifact == null
            ? null
            : (code) => actions.confirmAccountMfaEnrollment(
                enrollmentId: artifact!.enrollmentId,
                oneTimeCode: code,
              ),
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      await _mfaController.markEnrollmentConfirmed();
    }
  }

  Future<void> _handleViewBackupCodes() async {
    // Backup codes are the operator's own MFA recovery artifact —
    // any role with MFA enrolled should be able to view them. Not
    // gated on `canWriteAccount`.
    await showDialog<void>(
      context: context,
      builder: (_) => const _BackupCodesDialog(),
    );
  }

  Future<void> _handleMfaPrimaryAction() async {
    switch (_mfaController.state.stage) {
      case MfaCardStage.notEnrolled:
        await _handleEnrollMfa();
      case MfaCardStage.enrolled:
        await _handleManageMfa();
      case MfaCardStage.removalRequested:
        await _handleCancelMfaRemoval();
      case MfaCardStage.removable:
        await _mfaController.turnOffAfterGrace();
    }
  }

  Future<void> _handleManageMfa() async {
    final choice = await showDialog<_MfaManageChoice>(
      context: context,
      builder: (_) =>
          _MfaManageDialog(canRequestRemoval: _canRequestMfaRemoval),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _MfaManageChoice.backupCodes:
        await _handleViewBackupCodes();
      case _MfaManageChoice.requestRemoval:
        await _handleRequestMfaRemoval();
    }
  }

  Future<void> _handleRequestMfaRemoval() async {
    if (!_canRequestMfaRemoval) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('account_section_mfa_request_removal_dialog'),
        title: const Text('Turn off 2FA?'),
        content: const Text(
          'We wait 24 hours before turning off 2FA so that if someone got '
          'into your account, you have time to stop them. You may be asked '
          'to sign in again before the request is accepted.',
        ),
        actions: [
          TextButton(
            key: const Key('account_section_mfa_request_removal_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep 2FA on'),
          ),
          FilledButton(
            key: const Key('account_section_mfa_request_removal_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.negative,
              foregroundColor: AppColors.backgroundSurface,
            ),
            child: const Text('Request removal'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _mfaController.requestRemoval();
  }

  Future<void> _handleCancelMfaRemoval() async {
    if (!_canWriteAccount) return;
    await _mfaController.cancelRemoval();
  }

  bool get _canRequestMfaRemoval {
    final mfaState = _mfaController.state;
    return _canWriteAccount &&
        mfaState.canRequestRemoval &&
        !mfaState.loading &&
        !mfaState.busy;
  }

  Future<void> _handleChangePassword() async {
    if (!_canWriteAccount) return;
    final actions = widget.actions;
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePasswordDialog(
        onSubmit: actions == null
            ? null
            : ({
                required String currentPassword,
                required String newPassword,
              }) => actions.changeAccountPassword(
                currentPassword: currentPassword,
                newPassword: newPassword,
              ),
      ),
    );
    if (!mounted) return;
    if (updated == true) {
      _passwordToastTimer?.cancel();
      setState(() => _passwordToast = 'Password updated');
      _passwordToastTimer = Timer(_kToastVisibleDuration, () {
        if (!mounted) return;
        setState(() => _passwordToast = null);
      });
    }
  }

  Future<void> _loadActiveSessions() async {
    final actions = widget.actions;
    if (actions == null) {
      setState(() {
        _activeSessions = const <AccountActiveSessionEntry>[];
        _activeSessionsLoading = false;
        _activeSessionsError = null;
      });
      return;
    }
    setState(() {
      _activeSessionsLoading = true;
      _activeSessionsError = null;
    });
    try {
      final listed = await actions.listAccountActiveSessions();
      if (!mounted) return;
      setState(() {
        _activeSessions = listed.sessions;
        _activeSessionsLoading = false;
      });
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _activeSessionsLoading = false;
        _activeSessionsError = _friendlyAccountSessionError(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _activeSessionsLoading = false;
        _activeSessionsError = 'Could not load active sessions: $error';
      });
    }
  }

  Future<void> _handleSignOutOtherSessions() async {
    final actions = widget.actions;
    if (actions == null || _signingOutOtherSessions) return;
    final currentId = actions.currentAccountSessionId;
    if (currentId == null || currentId.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Refresh this page before signing out other sessions.'),
        ),
      );
      return;
    }
    final otherSessionIds = _activeSessions
        .where((session) => session.sessionId != currentId)
        .map((session) => session.sessionId)
        .toList(growable: false);
    if (otherSessionIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other active sessions to sign out.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        key: const Key('account_active_sessions_confirm_dialog'),
        title: const Text('Sign out all other sessions?'),
        content: const Text(
          'This keeps this device signed in and signs out every other browser '
          'or device listed here. You may be asked to sign in again before '
          'the change goes through.',
        ),
        actions: [
          TextButton(
            key: const Key('account_active_sessions_confirm_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('account_active_sessions_confirm_submit'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out all other sessions'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _signingOutOtherSessions = true;
      _activeSessionsError = null;
    });
    try {
      final result = await actions.signOutOtherAccountSessions(
        sessionIds: otherSessionIds,
      );
      if (!mounted) return;
      setState(() {
        _activeSessions = _activeSessions
            .where((session) => session.sessionId == currentId)
            .toList(growable: false);
        _signingOutOtherSessions = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.revokedCount == 1
                ? 'Signed out 1 other session.'
                : 'Signed out ${result.revokedCount} other sessions.',
          ),
        ),
      );
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _signingOutOtherSessions = false;
        _activeSessionsError = _friendlyAccountSessionError(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _signingOutOtherSessions = false;
        _activeSessionsError = 'Could not sign out other sessions: $error';
      });
    }
  }

  String _friendlyAccountSessionError(OperatorWebProxyException error) {
    if (error.isMfaFreshnessRedirect) {
      return 'Please sign in again to continue. This protects your account '
          'before changing active sessions.';
    }
    return error.message;
  }

  Future<void> _handleOpenAuditLog() {
    return openOperatorWebRedirect('/audit-log');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumnProfile =
            constraints.maxWidth >= _kProfileTwoColumnBreakpoint;
        return SingleChildScrollView(
          key: const Key('operator_web_account_screen'),
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionHeader(
                icon: Icons.person_outline,
                title: 'My account',
                subtitle:
                    'Your profile, sign-in security, MFA, and active sessions '
                    'live here. Business-wide defaults stay on the Business '
                    'account tab.',
              ),
              const SizedBox(height: 18),
              _ProfileSection(
                session: widget.session,
                twoColumn: twoColumnProfile,
                onAuditLog: _handleOpenAuditLog,
              ),
              const SizedBox(height: 14),
              _SecuritySection(
                canWrite: _canWriteAccount,
                readOnlyTooltip: _readOnlyTooltipPassword,
                toastMessage: _passwordToast,
                onChangePassword: _handleChangePassword,
                onAuditLog: _handleOpenAuditLog,
              ),
              const SizedBox(height: 14),
              _MfaSection(
                state: _mfaController.state,
                canWrite: _canWriteAccount,
                readOnlyTooltip: _readOnlyTooltipMfa,
                onPrimaryAction: _handleMfaPrimaryAction,
                onAuditLog: _handleOpenAuditLog,
              ),
              const SizedBox(height: 14),
              _ActiveSessionsSection(
                sessions: _activeSessions,
                currentSessionId: widget.actions?.currentAccountSessionId,
                loading: _activeSessionsLoading,
                errorMessage: _activeSessionsError,
                signingOutOthers: _signingOutOtherSessions,
                onRetry: _loadActiveSessions,
                onSignOutOthers: _handleSignOutOtherSessions,
                onAuditLog: _handleOpenAuditLog,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Sections ───────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 22, color: AppColors.sunsetDark),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.headerExplainer,
    required this.child,
    required this.auditLinkKey,
    required this.onAuditLog,
    this.statusBadge,
  });

  final Key cardKey;
  final IconData icon;
  final String title;
  final String headerExplainer;
  final Widget child;
  final Key auditLinkKey;
  final VoidCallback onAuditLog;
  final Widget? statusBadge;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: cardKey,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.sunsetDark),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              if (statusBadge != null) statusBadge!,
            ],
          ),
          const SizedBox(height: 6),
          Text(
            headerExplainer,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          child,
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 10),
          TextButton.icon(
            key: auditLinkKey,
            onPressed: onAuditLog,
            icon: const Icon(Icons.history, size: 16),
            label: const Text('View audit log'),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.sunsetDark,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({
    required this.session,
    required this.twoColumn,
    required this.onAuditLog,
  });

  final OperatorWebSession session;
  final bool twoColumn;
  final VoidCallback onAuditLog;

  @override
  Widget build(BuildContext context) {
    final phone = session.phone;
    final fields = <Widget>[
      _ProfileField(
        label: 'Display name',
        value: session.displayName.isEmpty
            ? 'Not on file'
            : session.displayName,
      ),
      _ProfileField(
        label: 'Email',
        value: session.email.isEmpty ? 'Not on file' : session.email,
      ),
      _ProfileField(
        label: 'Phone',
        value: (phone == null || phone.isEmpty) ? 'Not on file' : phone,
        helper:
            'Phone changes happen in the operator mobile app under '
            'Settings, Account.',
      ),
      _ProfileField(
        label: 'Business',
        value: session.businessName.isEmpty
            ? 'Not on file'
            : session.businessName,
      ),
    ];
    return _SectionCard(
      cardKey: const Key('account_section_profile'),
      icon: Icons.badge_outlined,
      title: 'Profile',
      headerExplainer:
          'Display name and email come from your sign-in provider. To '
          'change either, ask Forge & Flow support to issue a new invite '
          'for the new email. Phone changes happen in the operator '
          'mobile app under Settings → Account.',
      auditLinkKey: const Key('account_section_profile_audit_log_link'),
      onAuditLog: onAuditLog,
      child: twoColumn
          ? Wrap(
              key: const Key('account_section_profile_two_column'),
              spacing: 24,
              runSpacing: 12,
              children: [
                for (final field in fields) SizedBox(width: 280, child: field),
              ],
            )
          : Column(
              key: const Key('account_section_profile_single_column'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  fields[i],
                  if (i != fields.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  const _ProfileField({required this.label, required this.value, this.helper});

  final String label;
  final String value;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono11(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        Text(value, style: AppTextStyles.body13(color: AppColors.textPrimary)),
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper!,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}

class _MfaSection extends StatelessWidget {
  const _MfaSection({
    required this.state,
    required this.canWrite,
    required this.readOnlyTooltip,
    required this.onPrimaryAction,
    required this.onAuditLog,
  });

  final MfaCardState state;
  final bool canWrite;
  final String readOnlyTooltip;
  final VoidCallback onPrimaryAction;
  final VoidCallback onAuditLog;

  @override
  Widget build(BuildContext context) {
    final badge = _StatusBadge(
      key: const Key('account_section_mfa_badge'),
      label: state.badgeLabel,
      color: _badgeColor(state.stage),
    );
    final canPress = _canPressPrimary;
    return _SectionCard(
      cardKey: const Key('account_section_mfa'),
      icon: Icons.shield_outlined,
      title: 'Two-factor sign-in',
      headerExplainer:
          'Two-factor sign-in (MFA) means a one-time code is required at '
          'every sign-in, in addition to your password. We strongly '
          'recommend keeping it on for every operator user.',
      statusBadge: badge,
      auditLinkKey: const Key('account_section_mfa_audit_log_link'),
      onAuditLog: onAuditLog,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.loading) ...[
            const LinearProgressIndicator(
              minHeight: 2,
              color: AppColors.sunsetDark,
              backgroundColor: AppColors.borderSubtle,
            ),
            const SizedBox(height: 10),
          ],
          _ActionRow(
            actionKey: Key(state.primaryActionKey),
            header: state.headline,
            body: state.body,
            buttonLabel: state.busy ? 'Working...' : state.primaryButtonLabel,
            onPressed: canPress && !state.busy ? onPrimaryAction : null,
            disabledTooltip: canPress ? null : readOnlyTooltip,
          ),
          if (state.errorMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              state.errorMessage!,
              key: const Key('account_section_mfa_error'),
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }

  bool get _canPressPrimary {
    if (state.stage == MfaCardStage.enrolled) return true;
    return canWrite;
  }

  static Color _badgeColor(MfaCardStage stage) {
    switch (stage) {
      case MfaCardStage.notEnrolled:
        return AppColors.textMuted;
      case MfaCardStage.enrolled:
        return AppColors.positive;
      case MfaCardStage.removalRequested:
        return AppColors.warning;
      case MfaCardStage.removable:
        return AppColors.negative;
    }
  }
}

class _SecuritySection extends StatelessWidget {
  const _SecuritySection({
    required this.canWrite,
    required this.readOnlyTooltip,
    required this.toastMessage,
    required this.onChangePassword,
    required this.onAuditLog,
  });

  final bool canWrite;
  final String readOnlyTooltip;
  final String? toastMessage;
  final VoidCallback onChangePassword;
  final VoidCallback onAuditLog;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      cardKey: const Key('account_section_security'),
      icon: Icons.lock_outline,
      title: 'Security',
      headerExplainer:
          'A strong password and recent sign-in history help protect your '
          'operator account. Password changes may ask you to sign in again.',
      auditLinkKey: const Key('account_section_security_audit_log_link'),
      onAuditLog: onAuditLog,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ActionRow(
            actionKey: const Key('account_section_password_change'),
            header: 'Change password',
            body:
                'You\'ll be asked for your current password, then your new '
                'password twice. Your new password must be at least 12 '
                'characters and not match one of your last five passwords.',
            buttonLabel: 'Change password',
            onPressed: canWrite ? onChangePassword : null,
            disabledTooltip: canWrite ? null : readOnlyTooltip,
          ),
          if (toastMessage != null) ...[
            const SizedBox(height: 10),
            Container(
              key: const Key('account_section_password_toast'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.positive.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.positive.withValues(alpha: 0.45),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: AppColors.positive,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    toastMessage!,
                    style: AppTextStyles.body13(color: AppColors.positive),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActiveSessionsSection extends StatelessWidget {
  const _ActiveSessionsSection({
    required this.sessions,
    required this.currentSessionId,
    required this.loading,
    required this.errorMessage,
    required this.signingOutOthers,
    required this.onRetry,
    required this.onSignOutOthers,
    required this.onAuditLog,
  });

  final List<AccountActiveSessionEntry> sessions;
  final String? currentSessionId;
  final bool loading;
  final String? errorMessage;
  final bool signingOutOthers;
  final VoidCallback onRetry;
  final VoidCallback onSignOutOthers;
  final VoidCallback onAuditLog;

  @override
  Widget build(BuildContext context) {
    final currentId = currentSessionId;
    final otherSessionCount = currentId == null
        ? 0
        : sessions.where((session) => session.sessionId != currentId).length;
    final canSignOutOthers =
        currentId != null &&
        otherSessionCount > 0 &&
        !loading &&
        !signingOutOthers;
    final signOutButton = OutlinedButton.icon(
      key: const Key('account_active_sessions_sign_out_others'),
      onPressed: canSignOutOthers ? onSignOutOthers : null,
      icon: signingOutOthers
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.logout, size: 16),
      label: Text(
        signingOutOthers ? 'Signing out...' : 'Sign out all other sessions',
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.sunsetDark,
        disabledForegroundColor: AppColors.textMuted,
        side: BorderSide(
          color: canSignOutOthers
              ? AppColors.sunsetDark
              : AppColors.borderSubtle,
          width: 1,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
    );
    return _SectionCard(
      cardKey: const Key('account_section_active_sessions'),
      icon: Icons.devices_other_outlined,
      title: 'Active Sessions',
      headerExplainer:
          'Review browsers and devices signed in to your operator account. '
          'This device stays signed in when you sign out the others.',
      statusBadge: _StatusBadge(
        key: const Key('account_active_sessions_count_badge'),
        label: '${sessions.length} active',
        color: AppColors.textMuted,
      ),
      auditLinkKey: const Key('account_section_active_sessions_audit_log_link'),
      onAuditLog: onAuditLog,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading)
            const _AccountInlineState(
              stateKey: Key('account_active_sessions_loading'),
              icon: Icons.sync,
              message: 'Loading active sessions...',
            )
          else if (errorMessage != null)
            _AccountInlineError(message: errorMessage!, onRetry: onRetry)
          else if (sessions.isEmpty)
            const _AccountInlineState(
              stateKey: Key('account_active_sessions_empty'),
              icon: Icons.devices_other_outlined,
              message: 'No active sessions are available for this account.',
            )
          else ...[
            for (var i = 0; i < sessions.length; i++) ...[
              _ActiveSessionRow(
                session: sessions[i],
                isCurrent: sessions[i].sessionId == currentSessionId,
              ),
              if (i != sessions.length - 1) const SizedBox(height: 10),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: canSignOutOthers
                  ? signOutButton
                  : Tooltip(
                      message: currentId == null
                          ? 'Refresh this page before signing out other sessions.'
                          : otherSessionCount == 0
                          ? 'Only other sessions can be signed out from here.'
                          : 'Finish the current session action first.',
                      child: signOutButton,
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActiveSessionRow extends StatelessWidget {
  const _ActiveSessionRow({required this.session, required this.isCurrent});

  final AccountActiveSessionEntry session;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final title =
        session.deviceLabel ??
        session.deviceFingerprint ??
        session.userAgent ??
        'Unknown device';
    final geo = [
      if (session.geoCity != null) session.geoCity,
      if (session.geoCountry != null) session.geoCountry,
    ].whereType<String>().join(', ');
    final lastActive = 'Last active ${_formatDateTime(session.lastActiveAt)}';
    final meta = geo.isEmpty ? lastActive : '$lastActive - $geo';
    return Container(
      key: Key('account_active_sessions_row_${session.sessionId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.computer, size: 18, color: AppColors.sunsetDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 8),
                      _StatusBadge(
                        key: Key(
                          'account_active_sessions_this_device_'
                          '${session.sessionId}',
                        ),
                        label: 'This device',
                        color: AppColors.positive,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  meta,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 3),
                Text(
                  'Started ${_formatDateTime(session.createdAt)}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${_two(local.month)}-${_two(local.day)} '
        '${_two(local.hour)}:${_two(local.minute)}';
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

class _AccountInlineState extends StatelessWidget {
  const _AccountInlineState({
    required this.stateKey,
    required this.icon,
    required this.message,
  });

  final Key stateKey;
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: stateKey,
      children: [
        Icon(icon, size: 16, color: AppColors.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            message,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _AccountInlineError extends StatelessWidget {
  const _AccountInlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('account_active_sessions_error'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.30),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
          TextButton(
            key: const Key('account_active_sessions_retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ─── Shared chrome ──────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.actionKey,
    required this.header,
    required this.body,
    required this.buttonLabel,
    required this.onPressed,
    this.disabledTooltip,
  });

  final Key actionKey;
  final String header;
  final String body;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final String? disabledTooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      height: 38,
      child: OutlinedButton(
        key: actionKey,
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.sunsetDark,
          disabledForegroundColor: AppColors.textMuted,
          side: BorderSide(
            color: onPressed == null
                ? AppColors.borderSubtle
                : AppColors.sunsetDark,
            width: 1,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: AppTextStyles.mono14(
            color: AppColors.sunsetDark,
            weight: FontWeight.w600,
          ),
        ),
        child: Text(buttonLabel),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(header, style: AppTextStyles.mono11(color: AppColors.sunsetDark)),
        const SizedBox(height: 4),
        Text(body, style: AppTextStyles.body13(color: AppColors.textPrimary)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: onPressed == null && disabledTooltip != null
              ? Tooltip(message: disabledTooltip!, child: button)
              : button,
        ),
      ],
    );
  }
}

// ─── Modals ─────────────────────────────────────────────────────────

enum _MfaManageChoice { backupCodes, requestRemoval }

class _MfaManageDialog extends StatelessWidget {
  const _MfaManageDialog({required this.canRequestRemoval});

  final bool canRequestRemoval;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('account_section_mfa_manage_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Manage 2FA',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                canRequestRemoval
                    ? 'Two-step verification is on. You can view backup '
                          'codes or request removal if you need to replace '
                          'your authenticator.'
                    : 'Two-step verification is on. You can view backup '
                          'codes now. Removal is available after this card '
                          'confirms your authenticator with the server.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('account_section_mfa_view_backup_codes'),
                onPressed: () =>
                    Navigator.of(context).pop(_MfaManageChoice.backupCodes),
                icon: const Icon(Icons.key_outlined, size: 16),
                label: const Text('View backup codes'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  side: const BorderSide(color: AppColors.sunsetDark),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('account_section_mfa_turn_off'),
                onPressed: canRequestRemoval
                    ? () => Navigator.of(
                        context,
                      ).pop(_MfaManageChoice.requestRemoval)
                    : null,
                icon: const Icon(Icons.shield_outlined, size: 16),
                label: const Text('Turn off 2FA'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.negative,
                  disabledForegroundColor: AppColors.textMuted,
                  side: BorderSide(
                    color: canRequestRemoval
                        ? AppColors.negative
                        : AppColors.borderSubtle,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key('account_section_mfa_manage_close'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MfaEnrollDialog extends StatefulWidget {
  const _MfaEnrollDialog({
    required this.operatorEmail,
    this.artifact,
    this.onConfirm,
  });

  final String operatorEmail;
  final MfaEnrollmentArtifact? artifact;
  final Future<void> Function(String code)? onConfirm;

  @override
  State<_MfaEnrollDialog> createState() => _MfaEnrollDialogState();
}

class _MfaEnrollDialogState extends State<_MfaEnrollDialog> {
  final _codeController = TextEditingController();
  String? _error;
  bool _submitting = false;

  // Demo otpauth URI mirrors the MfaEnrollmentScreen artifact so the
  // walkthrough fixtures stay consistent across the onboarding click
  // path and the post-onboarding Account screen. 11W.0.live swaps in
  // a real proxy enrollment id.
  static const String _demoQrUri =
      'otpauth://totp/Forge%20%26%20Flow:demo?'
      'secret=JBSWY3DPEHPK3PXP&issuer=Forge%20%26%20Flow';
  static const String _demoSharedSecret = 'JBSWY3DPEHPK3PXP';

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_submitting) return;
    final code = _codeController.text.trim();
    final liveConfirm = widget.onConfirm;
    if (liveConfirm == null && code != '123456') {
      setState(
        () => _error =
            'That code did not match. Codes refresh every 30 seconds. '
            'If your authenticator app shows a different code now, type '
            'the new one and try again.',
      );
      return;
    }
    if (liveConfirm != null) {
      setState(() {
        _submitting = true;
        _error = null;
      });
      try {
        await liveConfirm(code);
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = 'Could not verify that code: $error';
        });
        return;
      }
      if (!mounted) return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final email = widget.operatorEmail.isEmpty
        ? 'this account'
        : widget.operatorEmail;
    final qrUri = widget.artifact?.totpQrUri ?? _demoQrUri;
    final sharedSecret = widget.artifact?.totpSharedSecret ?? _demoSharedSecret;
    return Dialog(
      key: const Key('mfa_enroll_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Turn on two-factor sign-in',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Open your authenticator app, scan this code, then type the '
                '6-digit code it shows you below.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('mfa_enroll_dialog_qr'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      qrUri,
                      style: AppTextStyles.mono10(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          'Shared secret: ',
                          style: AppTextStyles.mono11(
                            color: AppColors.textMuted,
                          ),
                        ),
                        SelectableText(
                          sharedSecret,
                          style: AppTextStyles.mono12(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Issuer: Forge & Flow • Account: $email',
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('mfa_enroll_dialog_code_field'),
                controller: _codeController,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _confirm(),
                decoration: const InputDecoration(
                  labelText: '6-digit code',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('mfa_enroll_dialog_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('mfa_enroll_dialog_confirm'),
                    onPressed: _submitting ? null : _confirm,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunset,
                      foregroundColor: AppColors.backgroundSurface,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Verify and turn on'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackupCodesDialog extends StatelessWidget {
  const _BackupCodesDialog();

  // Demo backup codes — the proxy returns 10 single-use codes on
  // enrollment confirm; we surface the same shape so the walkthrough
  // copy is stable across the demo + live flows.
  static const List<String> _codes = <String>[
    '4QF8-7VPC',
    'KX2J-MN9R',
    'TR5Y-LQ8B',
    'WC3D-PE6H',
    'BG7N-SV4A',
    'ZH9F-DM1U',
    'YJ6X-CT2L',
    'NK4P-OW8E',
    'QS3R-IB7G',
    'AL5K-VU9X',
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('mfa_backup_codes_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Backup codes',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Save these somewhere safe. If you lose your phone, any one '
                'of these codes lets you sign in once.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('mfa_backup_codes_dialog_list'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final code in _codes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          code,
                          style: AppTextStyles.mono14(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('mfa_backup_codes_dialog_close'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({this.onSubmit});

  final Future<void> Function({
    required String currentPassword,
    required String newPassword,
  })?
  onSubmit;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_currentController.text.isEmpty) {
      setState(
        () => _error =
            'Type your current password first so we can confirm it\'s you.',
      );
      return;
    }
    if (_newController.text.length < 12) {
      setState(
        () => _error =
            'Use at least 12 characters for your new password. A short '
            'phrase from a song or book is easier to remember than a string '
            'of random characters.',
      );
      return;
    }
    if (_newController.text != _confirmController.text) {
      setState(
        () => _error =
            'The two new passwords didn\'t match. Type the same password in '
            'both fields and try again.',
      );
      return;
    }
    final submit = widget.onSubmit;
    if (submit != null) {
      setState(() {
        _submitting = true;
        _error = null;
      });
      try {
        await submit(
          currentPassword: _currentController.text,
          newPassword: _newController.text,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _error = 'Could not update the password: $error';
        });
        return;
      }
      if (!mounted) return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('change_password_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Change password',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'A strong password is one of the simplest things you can do '
                'to keep your business data safe. Mix letters, numbers, and '
                'a symbol, and don\'t reuse it from another site.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('change_password_dialog_current'),
                controller: _currentController,
                obscureText: true,
                autofocus: true,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('change_password_dialog_new'),
                controller: _newController,
                obscureText: true,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('change_password_dialog_confirm'),
                controller: _confirmController,
                obscureText: true,
                enabled: !_submitting,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('change_password_dialog_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('change_password_dialog_submit'),
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunset,
                      foregroundColor: AppColors.backgroundSurface,
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Update password'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
