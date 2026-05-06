// Phase 11W.7 / Wave A2 - Operator Web My Account screen.
//
// "My account" is the operator-user-facing surface (sign-in identity,
// security, terms). Sibling to AccountScreen, which owns the
// business-identity surface (business name, logo, currency, locale,
// week-start, rollover hour).
//
// Four sections, all of them read-mostly at V1 per
// `project_v1_lean_scope_cut.md`:
//
//   * Profile   — display name, email, phone, business. Read-only.
//                 Phone edits route to the operator mobile app.
//   * MFA       — enrollment status (read off `session.mfaEnrolled`)
//                 + Enroll / View backup codes. Demo-mode enrolment
//                 is tracked locally; live wiring lands in
//                 `11W.0.live` against the existing Phase 9 MFA
//                 routes.
//   * Password  — Change password modal. Demo-mode submit shows a
//                 transient toast; live wiring lands in `11W.0.live`
//                 against the existing Phase 9 password rotation
//                 route.
//   * T&Cs      — accepted version + date + View current T&Cs in a
//                 read-only scrollable dialog.
//
// Backend reuse: every mutation is designed to flow through the
// existing Phase 9 auth tables and the existing audit log. No new
// proxy routes, no new permission keys, no new audit hooks.
// `11W.7` ships the surface; `11W.0.live` swaps the local-state
// stubs for real proxy calls (mirrors the gateway-follows-shell
// pattern Phase 11A used).
//
// Permission gate: keys off `session.roles`. Operator owners and
// admins get the full surface; location managers see Profile + T&Cs
// read-only and the MFA / Password buttons render disabled with
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

import '../account/operator_web_account_actions.dart';
import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';

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
  // Demo-mode MFA enrollment state. Initialised from
  // `session.mfaEnrolled` (the proxy's projection) and flipped
  // locally by the in-screen Enroll dialog. `11W.0.live` swaps the
  // local flip for a real proxy round-trip + a fresh session.
  late bool _mfaEnrolled;

  // Demo-mode toast under the Password section. Auto-clears after
  // [_kToastVisibleDuration] so the surface doesn't accumulate stale
  // confirmations across the operator's session.
  String? _passwordToast;
  Timer? _passwordToastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);

  // V1 hardcoded T&Cs acceptance metadata. The accepted version + date
  // come from the same fixture the onboarding T&Cs click-through wrote
  // against; on live wiring the proxy returns these in the
  // `tos_acceptances` row for the operator. Hardcoded here so the demo
  // + tests have a stable fixture; replaced by a real read-through in
  // `11W.0.live`.
  static const String _acceptedTosVersionLabel = 'v1.0';
  static const String _acceptedTosAcceptedOn = '2026-04-15';

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
    _mfaEnrolled = widget.session.mfaEnrolled;
  }

  @override
  void didUpdateWidget(covariant MyAccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync the demo-mode flag when the parent rebuilds with a new
    // session (e.g. role-switch in tests). Preserves a flip-from-false
    // → true that has happened in this widget's lifetime.
    if (widget.session.mfaEnrolled && !_mfaEnrolled) {
      _mfaEnrolled = true;
    }
  }

  @override
  void dispose() {
    _passwordToastTimer?.cancel();
    super.dispose();
  }

  bool get _canWriteAccount {
    final roles = widget.session.roles;
    return roles.contains('operator_owner') ||
        roles.contains('operator_admin') ||
        widget.session.permissions.contains('integrations.configure');
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
      setState(() => _mfaEnrolled = true);
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

  Future<void> _handleViewTos() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _ViewTosDialog(),
    );
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
                title: 'Account and business setup',
                subtitle:
                    'Manage your sign-in details, two-factor security, '
                    'password, and the terms you accepted when you joined '
                    'Forge & Flow. These settings cover your operator '
                    'account; per-location settings live on each location\'s '
                    'detail page (coming in a later slice).',
              ),
              const SizedBox(height: 18),
              _ProfileSection(
                session: widget.session,
                twoColumn: twoColumnProfile,
              ),
              const SizedBox(height: 14),
              _MfaSection(
                enrolled: _mfaEnrolled,
                canWrite: _canWriteAccount,
                readOnlyTooltip: _readOnlyTooltipMfa,
                onEnroll: _handleEnrollMfa,
                onViewBackupCodes: _handleViewBackupCodes,
              ),
              const SizedBox(height: 14),
              _PasswordSection(
                canWrite: _canWriteAccount,
                readOnlyTooltip: _readOnlyTooltipPassword,
                toastMessage: _passwordToast,
                onChangePassword: _handleChangePassword,
              ),
              const SizedBox(height: 14),
              _TosSection(
                acceptedVersionLabel: _acceptedTosVersionLabel,
                acceptedOn: _acceptedTosAcceptedOn,
                onViewTos: _handleViewTos,
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
    this.statusBadge,
  });

  final Key cardKey;
  final IconData icon;
  final String title;
  final String headerExplainer;
  final Widget child;
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
        ],
      ),
    );
  }
}

class _ProfileSection extends StatelessWidget {
  const _ProfileSection({required this.session, required this.twoColumn});

  final OperatorWebSession session;
  final bool twoColumn;

  @override
  Widget build(BuildContext context) {
    final phone = session.phone;
    final fields = <Widget>[
      _ProfileField(
        label: 'Display name',
        value: session.displayName.isEmpty ? 'Not on file' : session.displayName,
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
        value: session.businessName.isEmpty ? 'Not on file' : session.businessName,
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
    required this.enrolled,
    required this.canWrite,
    required this.readOnlyTooltip,
    required this.onEnroll,
    required this.onViewBackupCodes,
  });

  final bool enrolled;
  final bool canWrite;
  final String readOnlyTooltip;
  final VoidCallback onEnroll;
  final VoidCallback onViewBackupCodes;

  @override
  Widget build(BuildContext context) {
    final badge = _StatusBadge(
      key: const Key('account_section_mfa_badge'),
      label: enrolled ? 'MFA: Enrolled' : 'MFA: Not enrolled',
      color: enrolled ? AppColors.positive : AppColors.textMuted,
    );
    return _SectionCard(
      cardKey: const Key('account_section_mfa'),
      icon: Icons.shield_outlined,
      title: 'Two-factor sign-in',
      headerExplainer:
          'Two-factor sign-in (MFA) means a one-time code is required at '
          'every sign-in, in addition to your password. We strongly '
          'recommend keeping it on for every operator user.',
      statusBadge: badge,
      child: enrolled
          ? _ActionRow(
              actionKey: const Key('account_section_mfa_view_backup_codes'),
              header: 'View backup codes',
              body:
                  'Backup codes are one-time-use codes you can sign in with '
                  'if you lose your phone or authenticator app. Save them '
                  'somewhere safe.',
              buttonLabel: 'View backup codes',
              onPressed: onViewBackupCodes,
            )
          : _ActionRow(
              actionKey: const Key('account_section_mfa_enroll'),
              header: 'Turn on extra sign-in security',
              body:
                  'When you turn this on, you\'ll need a 6-digit code from '
                  'your phone every time you sign in from a new device. '
                  'We\'ll walk you through setup.',
              buttonLabel: 'Enroll MFA',
              onPressed: canWrite ? onEnroll : null,
              disabledTooltip: canWrite ? null : readOnlyTooltip,
            ),
    );
  }
}

class _PasswordSection extends StatelessWidget {
  const _PasswordSection({
    required this.canWrite,
    required this.readOnlyTooltip,
    required this.toastMessage,
    required this.onChangePassword,
  });

  final bool canWrite;
  final String readOnlyTooltip;
  final String? toastMessage;
  final VoidCallback onChangePassword;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      cardKey: const Key('account_section_password'),
      icon: Icons.lock_outline,
      title: 'Password',
      headerExplainer:
          'A strong password is one of the simplest things you can do to '
          'keep your business data safe. Mix letters, numbers, and a '
          'symbol, and don\'t reuse it from another site.',
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

class _TosSection extends StatelessWidget {
  const _TosSection({
    required this.acceptedVersionLabel,
    required this.acceptedOn,
    required this.onViewTos,
  });

  final String acceptedVersionLabel;
  final String acceptedOn;
  final VoidCallback onViewTos;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      cardKey: const Key('account_section_tos'),
      icon: Icons.gavel_outlined,
      title: 'Terms and conditions',
      headerExplainer:
          'These are the terms you agreed to when you signed in for the '
          'first time. They cover what data Forge & Flow reads from your '
          'systems, where we store it, and how to revoke access.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Accepted $acceptedVersionLabel on $acceptedOn',
            key: const Key('account_section_tos_accepted_line'),
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('account_section_tos_view'),
              onPressed: onViewTos,
              icon: const Icon(
                Icons.description_outlined,
                size: 16,
                color: AppColors.sunsetDark,
              ),
              label: const Text('View current T&Cs'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.sunsetDark,
                side: const BorderSide(color: AppColors.sunsetDark, width: 1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
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

class _ViewTosDialog extends StatelessWidget {
  const _ViewTosDialog();

  @override
  Widget build(BuildContext context) {
    final body = DemoOperatorWebAuthSource.kDemoTosVersion.bodyMarkdown;
    final version = DemoOperatorWebAuthSource.kDemoTosVersion.version;
    // Sized to fit inside the smallest tablet viewport (768×1024)
    // minus shell chrome (header 64 + 28 padding * 2) — capping at
    // ~80% of the viewport height keeps the dialog from clipping.
    final viewportHeight = MediaQuery.of(context).size.height;
    final dialogMaxHeight = (viewportHeight * 0.85).clamp(360.0, 600.0);
    return Dialog(
      key: const Key('view_tos_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: dialogMaxHeight),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Terms and conditions',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                'Version ${version.versionNumber} • effective '
                '${version.effectiveDate.toIso8601String().split('T').first}',
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.cardGlow,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    key: const Key('view_tos_dialog_scroll'),
                    child: SelectableText(
                      body,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('view_tos_dialog_close'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
