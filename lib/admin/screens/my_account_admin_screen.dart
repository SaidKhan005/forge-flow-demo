// Wave 2 W-4 — Admin "My Account" parity surface.
//
// The customer operator-web console has a full "My Account" surface
// (`lib/operator_web/screens/my_account_screen.dart`). The F&F-internal
// admin console was missing the equivalent parity surface — this slice
// closes that gap.
//
// Authority: `docs/_indices/WAVE_2_LEDGER.md` Lane W row W-4.
//
// Scope:
//   * Identity card — admin display name, email, admin role badge,
//     "Forge & Flow internal admin" scope label (HP #11 — admin console
//     is global / cross-operator so the notice degrades to a single
//     "Global / cross-operator" label rather than the
//     business/region/location triple).
//   * Security section — MFA status read off the JWT freshness stamp
//     (`AdminAuthSession.lastFreshAuthAt`). The admin gateway does not
//     expose MFA-enrollment mutations today, so this section renders
//     read-only with a note pointing the admin at the operator-web
//     sign-in flow for changes. This is intentional, per the W-4 brief:
//     no new admin auth/permission gate, no widened gateway surface.
//   * Active sessions — admin sessions today are not exposed through
//     a dedicated admin gateway, so this section renders a single
//     "current session" row + a "Sign out" CTA that routes through the
//     existing `AdminAuthSource.signOut()` path. Future slices can
//     light up a richer list once an admin sessions gateway exists.
//
// Permission posture:
//   * Both `super_admin` and `ff_support` see the same surface today.
//     Every section is read-only or read-only-plus-sign-out — no
//     mutation gate has been widened or introduced.
//
// Constraints honored:
//   * HP #2 demo-mode parity: no `kDemoMode` branch. The screen reads
//     `AdminAuthSession` regardless of writer mode.
//   * HP #11: cross-operator/admin-global label rendered in the
//     identity card so the operator always knows the effective scope.
//   * UX writing standard: every label, status, button reads as
//     training the user. Plain English, no engineering jargon, no
//     route-id leakage.
//   * No schema migration, no proxy ceiling raise, no new permission
//     key (CLAUDE.md R-2 ceiling-raise rule honored — no proxy work
//     in this slice).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_auth_gate.dart';

/// V1 Admin "My Account" screen. The admin shell renders this at
/// [kAdminMyAccountRouteId].
class MyAccountAdminScreen extends StatelessWidget {
  const MyAccountAdminScreen({
    super.key,
    required this.session,
    required this.authSource,
    this.now,
  });

  final AdminAuthSession session;

  /// Source the screen consults for sign-out and (in future slices) for
  /// session-level affordances. Sign-out routes through
  /// [AdminAuthSource.signOut].
  final AdminAuthSource authSource;

  /// Test seam for the freshness clock so widget tests can pin a
  /// deterministic "last signed in" relative label.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('admin_my_account_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _AdminAccountHeader(),
          const SizedBox(height: 18),
          _AdminIdentityCard(session: session),
          const SizedBox(height: 14),
          _AdminSecurityCard(
            session: session,
            now: now,
          ),
          const SizedBox(height: 14),
          _AdminActiveSessionsCard(
            session: session,
            onSignOut: () => authSource.signOut(),
            now: now,
          ),
        ],
      ),
    );
  }
}

// ─── Header + chrome ────────────────────────────────────────────────

class _AdminAccountHeader extends StatelessWidget {
  const _AdminAccountHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.person_outline,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'My account',
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

class _AdminAccountCard extends StatelessWidget {
  const _AdminAccountCard({
    required this.cardKey,
    required this.icon,
    required this.title,
    this.headerExplainer,
    required this.child,
  });

  final Key cardKey;
  final IconData icon;
  final String title;
  final String? headerExplainer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final explainer = headerExplainer;
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
            ],
          ),
          if (explainer != null) ...[
            const SizedBox(height: 6),
            Text(
              explainer,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _AdminAccountField extends StatelessWidget {
  const _AdminAccountField({
    required this.label,
    required this.value,
    this.helper,
    this.valueWidget,
  });

  final String label;
  final String value;
  final String? helper;

  /// Optional rich-content slot. When non-null it replaces the plain
  /// text [value]; the [value] still seeds copy testing in widget tests
  /// when this slot is null.
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    final helperText = helper;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 4),
          valueWidget ??
              Text(
                value,
                style: AppTextStyles.body14(color: AppColors.textPrimary),
              ),
          if (helperText != null) ...[
            const SizedBox(height: 4),
            Text(
              helperText,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Identity ───────────────────────────────────────────────────────

class _AdminIdentityCard extends StatelessWidget {
  const _AdminIdentityCard({required this.session});

  final AdminAuthSession session;

  @override
  Widget build(BuildContext context) {
    final displayName =
        session.displayName.isEmpty ? 'Not on file' : session.displayName;
    final email = session.email.isEmpty ? 'Not on file' : session.email;
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_identity_card'),
      icon: Icons.badge_outlined,
      title: 'Identity',
      headerExplainer:
          'Your sign-in details for the Forge & Flow admin console. '
          'These are read-only here — to update them, contact your '
          'Forge & Flow ecosystem admin.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AdminAccountField(label: 'Display name', value: displayName),
          _AdminAccountField(label: 'Email', value: email),
          _AdminAccountField(
            label: 'Role',
            value: _readableAdminRole(session.roles),
            valueWidget: Row(
              key: const Key('admin_my_account_role_badge'),
              children: [
                _AdminRoleChip(label: _readableAdminRole(session.roles)),
              ],
            ),
          ),
          _AdminAccountField(
            label: 'Scope',
            value: 'Global — cross-operator',
            helper:
                'Admin console access is global. You can see and support '
                'every business on Forge & Flow.',
          ),
        ],
      ),
    );
  }
}

String _readableAdminRole(List<String> roles) {
  if (roles.contains('super_admin')) return 'Ecosystem admin';
  if (roles.contains('ff_support')) return 'Support access';
  if (roles.isEmpty) return 'No role on file';
  return roles.first.replaceAll('_', ' ');
}

class _AdminRoleChip extends StatelessWidget {
  const _AdminRoleChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.chipLabel(color: AppColors.peacockDark),
      ),
    );
  }
}

// ─── Security ───────────────────────────────────────────────────────

class _AdminSecurityCard extends StatelessWidget {
  const _AdminSecurityCard({
    required this.session,
    this.now,
  });

  final AdminAuthSession session;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final lastFresh = session.lastFreshAuthAt;
    final mfaLabel = lastFresh == null ? 'Unknown' : 'On';
    final mfaHelper = lastFresh == null
        ? 'We could not confirm 2FA from this session. Sign in again from '
              'the admin sign-in page to refresh.'
        : 'Your last 2FA check happened ${_formatRelative(lastFresh, now)}.';
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_security_card'),
      icon: Icons.shield_outlined,
      title: 'Security',
      headerExplainer:
          '2FA is required for every Forge & Flow admin. Changes to your '
          '2FA factors happen from the admin sign-in page during your next '
          'sign-in.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AdminAccountField(
            label: 'Two-step verification',
            value: mfaLabel,
            valueWidget: Row(
              key: const Key('admin_my_account_mfa_status'),
              children: [
                _AdminStatusBadge(
                  label: mfaLabel,
                  color: lastFresh == null
                      ? AppColors.textMuted
                      : AppColors.positive,
                ),
              ],
            ),
            helper: mfaHelper,
          ),
          const SizedBox(height: 4),
          _AdminReadOnlyNote(
            key: const Key('admin_my_account_security_readonly_note'),
            icon: Icons.info_outline,
            message:
                'Changes to 2FA factors and password happen the next time '
                'you sign in to the admin console. Use the sign-in page '
                'to update them.',
          ),
        ],
      ),
    );
  }
}

class _AdminStatusBadge extends StatelessWidget {
  const _AdminStatusBadge({required this.label, required this.color});

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

class _AdminReadOnlyNote extends StatelessWidget {
  const _AdminReadOnlyNote({
    super.key,
    required this.icon,
    required this.message,
  });

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.06),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.sunsetDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Active sessions ────────────────────────────────────────────────

class _AdminActiveSessionsCard extends StatelessWidget {
  const _AdminActiveSessionsCard({
    required this.session,
    required this.onSignOut,
    this.now,
  });

  final AdminAuthSession session;
  final VoidCallback onSignOut;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final lastFresh = session.lastFreshAuthAt;
    final lastSignedInHelper = lastFresh == null
        ? 'Sign-in time is not available for this session.'
        : 'Signed in ${_formatRelative(lastFresh, now)}.';
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_active_sessions_card'),
      icon: Icons.devices_outlined,
      title: 'Active sessions',
      headerExplainer:
          'This is where you are currently signed in to the admin console. '
          'Use the sign-out button to end this session.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            key: const Key('admin_my_account_current_session_row'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.backgroundDeep,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.laptop_mac_outlined,
                  size: 18,
                  color: AppColors.sunsetDark,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'This admin console session',
                        style: AppTextStyles.mono15(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        lastSignedInHelper,
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                _AdminStatusBadge(
                  label: 'This device',
                  color: AppColors.positive,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                key: const Key('admin_my_account_sign_out_button'),
                onPressed: onSignOut,
                icon: const Icon(Icons.logout_outlined, size: 16),
                label: const Text('Sign out of this session'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  side: const BorderSide(color: AppColors.sunsetDark),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  textStyle: AppTextStyles.mono14(
                    color: AppColors.sunsetDark,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _AdminReadOnlyNote(
            key: const Key('admin_my_account_sessions_readonly_note'),
            icon: Icons.info_outline,
            message:
                'A list of every signed-in admin session is not available '
                'here yet. Reach out to a Forge & Flow ecosystem admin if '
                'you suspect a session needs to be revoked.',
          ),
        ],
      ),
    );
  }
}

// ─── Helpers ────────────────────────────────────────────────────────

String _formatRelative(DateTime instant, DateTime Function()? now) {
  final reference = (now?.call() ?? DateTime.now()).toUtc();
  final diff = reference.difference(instant.toUtc());
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) {
    final n = diff.inMinutes;
    return '$n minute${n == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final n = diff.inHours;
    return '$n hour${n == 1 ? '' : 's'} ago';
  }
  final days = diff.inDays;
  if (days < 7) return '$days day${days == 1 ? '' : 's'} ago';
  // Fall back to an absolute UTC stamp for older sessions so the
  // operator can read the exact instant.
  return 'on ${instant.toUtc().year}-${_twoDigits(instant.toUtc().month)}-'
      '${_twoDigits(instant.toUtc().day)}';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
