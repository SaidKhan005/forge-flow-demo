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

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../admin_auth_gate.dart';
import '../services/admin_account_gateway.dart';
import '../services/admin_sessions_gateway.dart';

/// V1 Admin "My Account" screen. The admin shell renders this at
/// [kAdminMyAccountRouteId].
class MyAccountAdminScreen extends StatefulWidget {
  const MyAccountAdminScreen({
    super.key,
    required this.session,
    required this.authSource,
    this.accountGateway,
    this.sessionsGateway,
    this.now,
  });

  final AdminAuthSession session;

  /// Source the screen consults for sign-out and (in future slices) for
  /// session-level affordances. Sign-out routes through
  /// [AdminAuthSource.signOut].
  final AdminAuthSource authSource;

  /// Wave 2 W-3 — when non-null, the Identity card renders an "Edit
  /// identity" button. Null means the gateway is not wired (e.g.
  /// older test fixtures), so the section stays read-only — mirrors
  /// the original W-4 posture.
  final AdminAccountGateway? accountGateway;

  /// Audit fix-first #2 (G2) — when non-null, the Active Sessions
  /// card renders the real list + per-row revoke + sign-out-everywhere
  /// surface. Null (older test fixtures that predate this slice)
  /// degrades to the legacy single-session + local sign-out posture
  /// so existing widget tests keep passing.
  final AdminSessionsGateway? sessionsGateway;

  /// Test seam for the freshness clock so widget tests can pin a
  /// deterministic "last signed in" relative label.
  final DateTime Function()? now;

  @override
  State<MyAccountAdminScreen> createState() => _MyAccountAdminScreenState();
}

class _MyAccountAdminScreenState extends State<MyAccountAdminScreen> {
  // Local override that survives until the next sign-in. The
  // `AdminAuthSession` carried by the admit decision is read-only;
  // when the admin edits their identity here we surface the new
  // values from this state so the UI updates without waiting for a
  // re-sign-in cycle.
  String? _displayNameOverride;
  String? _emailOverride;

  // Auto-clearing confirmation toast.
  String? _identityToast;
  Timer? _identityToastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);

  @override
  void dispose() {
    _identityToastTimer?.cancel();
    super.dispose();
  }

  String get _effectiveDisplayName =>
      _displayNameOverride ?? widget.session.displayName;
  String get _effectiveEmail => _emailOverride ?? widget.session.email;

  Future<void> _handleEditIdentity() async {
    final gateway = widget.accountGateway;
    if (gateway == null) return;
    final result = await showDialog<_AdminEditIdentityResult>(
      context: context,
      builder: (_) => _AdminEditIdentityDialog(
        gateway: gateway,
        currentDisplayName: _effectiveDisplayName,
        currentEmail: _effectiveEmail,
      ),
    );
    if (!mounted || result == null) return;
    _identityToastTimer?.cancel();
    setState(() {
      _displayNameOverride = result.patched.displayName;
      _emailOverride = result.patched.email;
      _identityToast = result.patched.emailChanged
          ? 'Profile saved. Sign in again with your new email.'
          : 'Profile updated.';
    });
    _identityToastTimer = Timer(_kToastVisibleDuration, () {
      if (!mounted) return;
      setState(() => _identityToast = null);
    });
    // The proxy revoked refresh tokens server-side; the next ID-token
    // refresh will fail and the existing freshness redirect path
    // forces the admin back to sign-in. No additional client-side
    // sign-out call is needed here.
  }

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
          _AdminIdentityCard(
            session: widget.session,
            displayNameOverride: _displayNameOverride,
            emailOverride: _emailOverride,
            onEditIdentity:
                widget.accountGateway == null ? null : _handleEditIdentity,
            identityToast: _identityToast,
          ),
          const SizedBox(height: 14),
          _AdminSecurityCard(
            session: widget.session,
            now: widget.now,
          ),
          const SizedBox(height: 14),
          _AdminActiveSessionsCard(
            session: widget.session,
            onSignOut: () => widget.authSource.signOut(),
            gateway: widget.sessionsGateway,
            now: widget.now,
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
  const _AdminIdentityCard({
    required this.session,
    this.displayNameOverride,
    this.emailOverride,
    this.onEditIdentity,
    this.identityToast,
  });

  final AdminAuthSession session;

  /// Wave 2 W-3 — local override after a successful self-edit so the
  /// UI reflects the new values without waiting for a re-sign-in.
  final String? displayNameOverride;
  final String? emailOverride;

  /// When non-null, renders an "Edit identity" button. Null = read-
  /// only posture (older fixtures or builds without the gateway).
  final VoidCallback? onEditIdentity;

  /// Auto-clearing confirmation toast.
  final String? identityToast;

  @override
  Widget build(BuildContext context) {
    final resolvedDisplay = displayNameOverride ?? session.displayName;
    final resolvedEmail = emailOverride ?? session.email;
    final displayName =
        resolvedDisplay.isEmpty ? 'Not on file' : resolvedDisplay;
    final email = resolvedEmail.isEmpty ? 'Not on file' : resolvedEmail;
    final explainer = onEditIdentity == null
        ? 'Your sign-in details for the Forge & Flow admin console. '
              'These are read-only here — to update them, contact your '
              'Forge & Flow ecosystem admin.'
        : 'Your sign-in details for the Forge & Flow admin console. '
              'Use Edit identity to change your display name or sign-in '
              'email. Changing your email signs you out.';
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_identity_card'),
      icon: Icons.badge_outlined,
      title: 'Identity',
      headerExplainer: explainer,
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
          if (onEditIdentity != null) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  key: const Key('admin_my_account_identity_edit'),
                  onPressed: onEditIdentity,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit identity'),
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
          ],
          if (identityToast != null) ...[
            const SizedBox(height: 10),
            Container(
              key: const Key('admin_my_account_identity_toast'),
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
                  Expanded(
                    child: Text(
                      identityToast!,
                      style: AppTextStyles.body13(color: AppColors.positive),
                    ),
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
        ? 'We could not confirm two-factor sign-in from this session. Sign '
              'in again from the admin sign-in page to refresh.'
        : 'Your last two-factor sign-in check happened '
              '${_formatRelative(lastFresh, now)}.';
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_security_card'),
      icon: Icons.shield_outlined,
      title: 'Security',
      headerExplainer:
          'Two-factor sign-in is required for every Forge & Flow admin. '
          'Changes to your two-factor sign-in factors happen from the '
          'admin sign-in page during your next sign-in.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AdminAccountField(
            label: 'Two-factor sign-in',
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
                'Changes to two-factor sign-in factors and password happen '
                'the next time you sign in to the admin console. Use the '
                'sign-in page to update them.',
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

class _AdminActiveSessionsCard extends StatefulWidget {
  const _AdminActiveSessionsCard({
    required this.session,
    required this.onSignOut,
    this.gateway,
    this.now,
  });

  final AdminAuthSession session;
  final VoidCallback onSignOut;

  /// Audit fix-first #2 (G2). When non-null, the card loads the
  /// admin's own session list and offers per-row revoke +
  /// sign-out-everywhere. Null degrades to the legacy single-session
  /// + local sign-out posture.
  final AdminSessionsGateway? gateway;
  final DateTime Function()? now;

  @override
  State<_AdminActiveSessionsCard> createState() =>
      _AdminActiveSessionsCardState();
}

class _AdminActiveSessionsCardState extends State<_AdminActiveSessionsCard> {
  bool _loading = false;
  String? _loadError;
  List<AdminSessionEntry>? _sessions;
  final Set<String> _revoking = <String>{};
  bool _signingOutEverywhere = false;
  String? _toast;
  Timer? _toastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);
  int _idempotencyCounter = 0;

  @override
  void initState() {
    super.initState();
    if (widget.gateway != null) {
      unawaited(_loadSessions());
    }
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    super.dispose();
  }

  String _mintIdempotencyKey(String action) {
    _idempotencyCounter += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = math.Random.secure().nextInt(1 << 32).toRadixString(36);
    return 'admin-my-account-sessions-$action-$ts-$r-$_idempotencyCounter';
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(_kToastVisibleDuration, () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  Future<void> _loadSessions() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final listed = await gateway.listOwnSessions();
      if (!mounted) return;
      setState(() {
        _sessions =
            listed.where((s) => s.isActive).toList(growable: false);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = _friendly(error);
      });
    }
  }

  Future<void> _revokeSession(AdminSessionEntry entry) async {
    final gateway = widget.gateway;
    if (gateway == null || _revoking.contains(entry.sessionId)) return;
    setState(() => _revoking.add(entry.sessionId));
    try {
      await gateway.revokeSession(
        sessionId: entry.sessionId,
        reason: 'admin_revoked_from_my_account',
        idempotencyKey: _mintIdempotencyKey('revoke'),
      );
      if (!mounted) return;
      _showToast('That session has been signed out.');
      await _loadSessions();
    } catch (error) {
      if (!mounted) return;
      _showToast(_friendly(error));
    } finally {
      if (mounted) {
        setState(() => _revoking.remove(entry.sessionId));
      }
    }
  }

  Future<void> _signOutEverywhere() async {
    final gateway = widget.gateway;
    if (gateway == null || _signingOutEverywhere) return;
    setState(() => _signingOutEverywhere = true);
    try {
      await gateway.signOutEverywhere(
        reason: 'admin_signed_out_all_sessions',
        idempotencyKey: _mintIdempotencyKey('sign-out-all'),
      );
      if (!mounted) return;
      // Every session (including this one) + the Firebase refresh
      // tokens are revoked server-side. Route through the local
      // sign-out so the gate returns to the sign-in card immediately.
      widget.onSignOut();
    } catch (error) {
      if (!mounted) return;
      setState(() => _signingOutEverywhere = false);
      _showToast(_friendly(error));
    }
  }

  String _friendly(Object error) {
    if (error is AdminSessionsGatewayError) {
      if (error.statusCode == 408) {
        return 'The admin console timed out reaching the session service. '
            'Try again in a moment.';
      }
      return 'We could not complete that session action. Try again in a '
          'moment.';
    }
    return 'We could not complete that session action. Try again in a '
        'moment.';
  }

  @override
  Widget build(BuildContext context) {
    final lastFresh = widget.session.lastFreshAuthAt;
    final lastSignedInHelper = lastFresh == null
        ? 'Sign-in time is not available for this session.'
        : 'Signed in ${_formatRelative(lastFresh, widget.now)}.';
    final hasGateway = widget.gateway != null;
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_active_sessions_card'),
      icon: Icons.devices_outlined,
      title: 'Active sessions',
      headerExplainer: hasGateway
          ? 'Every place you are currently signed in to the admin console. '
                'Sign out a single session, or sign out everywhere if you '
                'think your account is at risk.'
          : 'This is where you are currently signed in to the admin '
                'console. Use the sign-out button to end this session.',
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
          if (hasGateway) ...[
            const SizedBox(height: 14),
            _buildSessionsList(),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 40,
              child: OutlinedButton.icon(
                key: const Key('admin_my_account_sign_out_button'),
                onPressed: widget.onSignOut,
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
          if (hasGateway) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 40,
                child: OutlinedButton.icon(
                  key: const Key('admin_my_account_sign_out_everywhere_button'),
                  onPressed:
                      _signingOutEverywhere ? null : _signOutEverywhere,
                  icon: _signingOutEverywhere
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shield_moon_outlined, size: 16),
                  label: Text(
                    _signingOutEverywhere
                        ? 'Signing out everywhere...'
                        : 'Sign out everywhere',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.negative,
                    side: const BorderSide(color: AppColors.negative),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    textStyle: AppTextStyles.mono14(
                      color: AppColors.negative,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            if (_toast != null) ...[
              const SizedBox(height: 10),
              Container(
                key: const Key('admin_my_account_sessions_toast'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.peacock.withValues(alpha: 0.10),
                  border: Border.all(
                    color: AppColors.peacock.withValues(alpha: 0.45),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppColors.peacockDark,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _toast!,
                        style: AppTextStyles.body13(
                          color: AppColors.peacockDark,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ] else ...[
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
        ],
      ),
    );
  }

  Widget _buildSessionsList() {
    if (_loading && _sessions == null) {
      return const Padding(
        key: Key('admin_my_account_sessions_loading'),
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_loadError != null) {
      return Container(
        key: const Key('admin_my_account_sessions_load_error'),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.negative.withValues(alpha: 0.08),
          border: Border.all(
            color: AppColors.negative.withValues(alpha: 0.35),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.error_outline,
              size: 16,
              color: AppColors.negative,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _loadError!,
                style: AppTextStyles.body13(color: AppColors.negative),
              ),
            ),
            TextButton(
              key: const Key('admin_my_account_sessions_retry'),
              onPressed: _loading ? null : _loadSessions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final sessions = _sessions ?? const <AdminSessionEntry>[];
    if (sessions.isEmpty) {
      return Text(
        key: const Key('admin_my_account_sessions_empty'),
        'No other active admin sessions.',
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      );
    }
    return Column(
      key: const Key('admin_my_account_sessions_list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in sessions) ...[
          _AdminSessionRow(
            entry: entry,
            now: widget.now,
            revoking: _revoking.contains(entry.sessionId),
            onRevoke: () => _revokeSession(entry),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _AdminSessionRow extends StatelessWidget {
  const _AdminSessionRow({
    required this.entry,
    required this.revoking,
    required this.onRevoke,
    this.now,
  });

  final AdminSessionEntry entry;
  final bool revoking;
  final VoidCallback onRevoke;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final device = entry.deviceLabel ?? entry.userAgent ?? 'Unknown device';
    final whereParts = <String>[
      if (entry.geoCountry != null) entry.geoCountry!,
    ];
    final lastSeen = 'Last active ${_formatRelative(entry.lastSeenAt, now)}';
    final subtitle =
        whereParts.isEmpty ? lastSeen : '$lastSeen · ${whereParts.join(', ')}';
    return Container(
      key: Key('admin_my_account_session_row_${entry.sessionId}'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.devices_other_outlined,
            size: 16,
            color: AppColors.sunsetDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: OutlinedButton(
              key: Key(
                'admin_my_account_session_revoke_${entry.sessionId}',
              ),
              onPressed: revoking ? null : onRevoke,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.negative,
                side: const BorderSide(color: AppColors.negative),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                textStyle: AppTextStyles.mono11(color: AppColors.negative),
              ),
              child: revoking
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sign out'),
            ),
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

// ─── Edit identity dialog (W-3) ─────────────────────────────────────

class _AdminEditIdentityResult {
  const _AdminEditIdentityResult({required this.patched});

  final AdminAccountProfilePatched patched;
}

class _AdminEditIdentityDialog extends StatefulWidget {
  const _AdminEditIdentityDialog({
    required this.gateway,
    required this.currentDisplayName,
    required this.currentEmail,
  });

  final AdminAccountGateway gateway;
  final String currentDisplayName;
  final String currentEmail;

  @override
  State<_AdminEditIdentityDialog> createState() =>
      _AdminEditIdentityDialogState();
}

class _AdminEditIdentityDialogState
    extends State<_AdminEditIdentityDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _emailController;
  bool _confirmEmailChange = false;
  bool _submitting = false;
  String? _topLevelError;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(
      text: widget.currentDisplayName,
    );
    _emailController = TextEditingController(text: widget.currentEmail);
    _displayNameController.addListener(_onFieldChanged);
    _emailController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (!mounted) return;
    setState(() {
      if (_topLevelError != null) _topLevelError = null;
    });
  }

  String _trimmedDisplayName() => _displayNameController.text.trim();
  String _trimmedEmail() => _emailController.text.trim();

  bool get _displayNameChanged =>
      _trimmedDisplayName() != widget.currentDisplayName.trim();
  bool get _emailChanged =>
      _trimmedEmail().toLowerCase() !=
      widget.currentEmail.trim().toLowerCase();
  bool get _hasChange => _displayNameChanged || _emailChanged;

  bool get _canSave {
    if (_submitting || !_hasChange) return false;
    if (_emailChanged && !_confirmEmailChange) return false;
    if (_emailChanged && !_looksLikeEmail(_trimmedEmail())) return false;
    if (_displayNameChanged && _trimmedDisplayName().isEmpty) return false;
    return true;
  }

  static bool _looksLikeEmail(String value) {
    if (value.contains(' ')) return false;
    final atIndex = value.indexOf('@');
    if (atIndex <= 0 || atIndex == value.length - 1) return false;
    if (value.indexOf('@', atIndex + 1) != -1) return false;
    final domain = value.substring(atIndex + 1);
    if (!domain.contains('.')) return false;
    if (domain.startsWith('.') || domain.endsWith('.')) return false;
    return true;
  }

  Future<void> _handleSave() async {
    if (!_canSave) return;
    setState(() {
      _submitting = true;
      _topLevelError = null;
    });
    try {
      final patched = await widget.gateway.patchSelfProfile(
        displayName: _displayNameChanged ? _trimmedDisplayName() : null,
        email: _emailChanged ? _trimmedEmail() : null,
        idempotencyKey: _mintIdempotencyKey(),
      );
      if (!mounted) return;
      Navigator.of(context)
          .pop(_AdminEditIdentityResult(patched: patched));
    } on AdminAccountGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _topLevelError = _friendly(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _topLevelError = 'Could not save your profile: $error';
      });
    }
  }

  String _friendly(AdminAccountGatewayError error) {
    switch (error.errorCode) {
      case 'invalid_email':
        return 'Enter a valid email address.';
      case 'no_profile_fields':
        return 'Change a field before saving, or cancel to keep your '
            'profile as is.';
      default:
        return error.message;
    }
  }

  static String _mintIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = math.Random.secure().nextInt(1 << 32).toRadixString(36);
    return 'admin-self-profile-$ts-$r';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('admin_edit_identity_dialog'),
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
                'Edit your identity',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Update your admin display name and sign-in email. '
                'Changing your email signs you out so you can sign back '
                'in with the new address.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              Text('Display name',
                  style: AppTextStyles.mono11(color: AppColors.sunsetDark)),
              const SizedBox(height: 4),
              TextField(
                key: const Key('admin_edit_identity_display_name_field'),
                controller: _displayNameController,
                enabled: !_submitting,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Text('Email',
                  style: AppTextStyles.mono11(color: AppColors.sunsetDark)),
              const SizedBox(height: 4),
              TextField(
                key: const Key('admin_edit_identity_email_field'),
                controller: _emailController,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                inputFormatters: [
                  FilteringTextInputFormatter.deny(RegExp(r'\s')),
                ],
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              if (_emailChanged) ...[
                const SizedBox(height: 10),
                Container(
                  key: const Key('admin_edit_identity_email_confirm_box'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.sunset.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.sunset.withValues(alpha: 0.40),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Checkbox(
                        key: const Key(
                            'admin_edit_identity_email_confirm_checkbox'),
                        value: _confirmEmailChange,
                        onChanged: _submitting
                            ? null
                            : (v) => setState(
                                () => _confirmEmailChange = v ?? false),
                      ),
                      Expanded(
                        child: Text(
                          'Confirm you want to change your sign-in email.',
                          style: AppTextStyles.body13(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_topLevelError != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const Key('admin_edit_identity_error'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.negative.withValues(alpha: 0.30),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _topLevelError!,
                    style: AppTextStyles.body13(color: AppColors.negative),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('admin_edit_identity_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('admin_edit_identity_save'),
                    onPressed: _canSave ? _handleSave : null,
                    child: Text(_submitting ? 'Saving...' : 'Save changes'),
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

