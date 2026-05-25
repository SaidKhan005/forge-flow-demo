// Admin "My Account" parity surface (started Wave 2 W-4).
//
// The customer operator-web console has a full "My Account" surface
// (`lib/operator_web/screens/my_account_screen.dart`). The F&F-internal
// admin console mirrors it card-for-card. The original W-4 slice landed
// the Identity + read-only Security posture; later fix-first slices
// lit up the full self-service surface this header now describes.
//
// Authority: `docs/_indices/WAVE_2_LEDGER.md` Lane W row W-4.
//
// Scope (current FULL self-service surface):
//   * Identity card — admin display name, email, admin role badge, and
//     a "Global: cross-operator" scope label (HP #11 — the admin
//     console is global / cross-operator so the scope notice degrades
//     to a single label rather than the business/region/location
//     triple). With an `AdminAccountGateway` wired, "Edit identity"
//     lets the admin change their display name or sign-in email
//     (an email change forces a re-sign-in).
//   * Security card — change password (current + new x2, routed through
//     the gateway) plus a "Recent sign-in activity" list with 7/30/90
//     day filters, read from the self-scoped audit-log route. Degrades
//     to a disabled/disconnected state when no gateway is wired.
//   * Two-factor sign-in card — with an `AdminSecurityGateway` wired,
//     the full self-service flow: enroll an authenticator (begin +
//     confirm), "lost your authenticator?" recovery, a 24-hour delayed
//     "Turn off two-factor sign-in" request, and cancel of a pending
//     removal. When the proxy demands a fresh step-up, the card surfaces
//     an actionable "Sign in again" remedy (the admin re-auth path)
//     instead of a dead error message; every OTHER gateway error keeps
//     the fail-closed red toast. Without a gateway it degrades to the
//     read-only "changes at next sign-in" note.
//   * Active sessions card — "Manage active sessions here" opens a popup
//     that, with an `AdminSessionsGateway` wired, lists every signed-in
//     admin session with per-session sign-out and sign-out-everywhere;
//     local sign-out always routes through `AdminAuthSource.signOut()`.
//   * Audit log card — "View audit log" navigates to the full account
//     audit-log page when the shell wires `onOpenAuditLog`.
//
// Permission posture:
//   * Both `super_admin` and `ff_support` see the same surface. Every
//     gateway is null-degradable, so older fixtures and builds without
//     a wired gateway render the legacy read-only posture.
//
// Constraints honored:
//   * HP #2 demo-mode parity: no `kDemoMode` branch. The screen reads
//     `AdminAuthSession` regardless of writer mode.
//   * HP #11: cross-operator/admin-global label rendered in the
//     identity card so the operator always knows the effective scope.
//   * UX writing standard: every label, status, button reads as
//     training the user. Plain English, no engineering jargon, no
//     route-id leakage, no em-dash punctuation in operator-facing copy.
//   * Security-sensitive changes fail closed: any gateway error leaves
//     the prior state intact; only a freshness/step-up error is given
//     the actionable "Sign in again" remedy.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';
import '../admin_button_styles.dart';
import '../admin_auth_gate.dart';
import '../services/admin_account_gateway.dart';
import '../services/admin_security_gateway.dart';
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
    this.securityGateway,
    this.now,
    this.onOpenAuditLog,
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

  /// Audit fix-first #7 (cross-surface parity finding G4) — when
  /// non-null, the Security card renders the working self-service
  /// surface: MFA factor status + enroll/confirm, "lost your
  /// authenticator?" recovery, and password change. Null (older test
  /// fixtures that predate this slice) degrades to the legacy
  /// read-only posture so existing widget tests keep passing.
  final AdminSecurityGateway? securityGateway;

  /// Test seam for the freshness clock so widget tests can pin a
  /// deterministic "last signed in" relative label.
  final DateTime Function()? now;

  /// When non-null, the "Audit log" card's "View audit log" button
  /// navigates to the full account Audit log page. The admin shell
  /// wires this through AdminRouteHandoff; a screen mounted without a
  /// shell (older widget tests) leaves it null and the button disabled.
  final VoidCallback? onOpenAuditLog;

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

  // G70: mint ONE caller-stable idempotency key for the logical
  // "save identity" action, at dialog-construction time. Mirrors how
  // the sibling password / recovery / MFA-confirm dialogs receive a
  // stable `widget.idempotencyKey` from `_handleChangePassword` /
  // `_handleRecovery` / `_handleEnroll`. Each distinct edit attempt
  // (one dialog open) gets a distinct key; a retry of the same
  // unchanged save reuses it so the proxy `proxy_requests` UNIQUE
  // guard collapses the duplicate (email change forces sign-out — the
  // same HIGH case G60 flagged for operator-web, fixed by #855).
  static String _mintIdentityIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = math.Random.secure().nextInt(0x7fffffff).toRadixString(36);
    return 'admin-self-profile-$ts-$r';
  }

  Future<void> _handleEditIdentity() async {
    final gateway = widget.accountGateway;
    if (gateway == null) return;
    final result = await showDialog<_AdminEditIdentityResult>(
      context: context,
      builder: (_) => _AdminEditIdentityDialog(
        gateway: gateway,
        currentDisplayName: _effectiveDisplayName,
        currentEmail: _effectiveEmail,
        idempotencyKey: _mintIdentityIdempotencyKey(),
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
    // Mirror the operator-web My account screen card-for-card:
    // Identity -> Security (password + recent sign-in activity) ->
    // Two-factor sign-in -> Active sessions -> Audit log. The
    // LayoutBuilder drives the identity card's 2-column wrap at the
    // same 800px breakpoint the ops Profile card uses.
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumnProfile = constraints.maxWidth >= 800;
        return OperatorWebScreenBody(
          scrollKey: const Key('admin_my_account_screen'),
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _AdminAccountHeader(),
              const SizedBox(height: 18),
              _AdminIdentityCard(
                session: widget.session,
                twoColumn: twoColumnProfile,
                displayNameOverride: _displayNameOverride,
                emailOverride: _emailOverride,
                onEditIdentity: widget.accountGateway == null
                    ? null
                    : _handleEditIdentity,
                identityToast: _identityToast,
              ),
              const SizedBox(height: 14),
              _AdminSecurityCard(
                gateway: widget.securityGateway,
                now: widget.now,
              ),
              const SizedBox(height: 14),
              _AdminTwoFactorCard(
                session: widget.session,
                gateway: widget.securityGateway,
                now: widget.now,
                onSignInAgain: () => widget.authSource.signOut(),
              ),
              const SizedBox(height: 14),
              _AdminActiveSessionsCard(
                session: widget.session,
                onSignOut: () => widget.authSource.signOut(),
                gateway: widget.sessionsGateway,
                now: widget.now,
              ),
              const SizedBox(height: 14),
              _AdminAuditLogCard(onOpenAuditLog: widget.onOpenAuditLog),
            ],
          ),
        );
      },
    );
  }
}

// ─── Header + chrome ────────────────────────────────────────────────

class _AdminAccountHeader extends StatelessWidget {
  const _AdminAccountHeader();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebScreenHeader(
      icon: Icons.person_outline,
      title: 'My account',
    );
  }
}

class _AdminAccountCard extends StatelessWidget {
  const _AdminAccountCard({
    required this.cardKey,
    required this.title,
    this.headerExplainer,
    this.statusBadge,
    required this.child,
  });

  final Key cardKey;
  final String title;
  final String? headerExplainer;

  /// Optional status pill rendered in the card header trailing slot,
  /// beside the info button. Mirrors the operator-web `_SectionCard`
  /// `statusBadge` (e.g. the two-factor "On" / "Not set up" pill so the
  /// status reads in the header exactly like the ops My account cards).
  final Widget? statusBadge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final explainer = headerExplainer;
    final help = explainer == null
        ? null
        : OperatorWebInfoButton(
            title: title,
            tooltip: title,
            body: Text(
              explainer,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
    final Widget? trailing;
    if (help == null && statusBadge == null) {
      trailing = null;
    } else if (statusBadge == null) {
      trailing = help;
    } else if (help == null) {
      trailing = statusBadge;
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[help, const SizedBox(width: 8), statusBadge!],
      );
    }
    return OperatorWebPanel(
      key: cardKey,
      title: title,
      trailing: trailing,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: child,
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
    // Field chrome matches the operator-web `_ProfileField`: a muted
    // mono11 label over a body13 value. Inter-field spacing is managed
    // by the parent card (no built-in padding) so the identity card can
    // stack or 2-column-wrap exactly like the ops Profile card.
    final helperText = helper;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono11(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        valueWidget ??
            Text(
              value,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
        if (helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            helperText,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

// ─── Identity ───────────────────────────────────────────────────────

class _AdminIdentityCard extends StatelessWidget {
  const _AdminIdentityCard({
    required this.session,
    required this.twoColumn,
    this.displayNameOverride,
    this.emailOverride,
    this.onEditIdentity,
    this.identityToast,
  });

  final AdminAuthSession session;

  /// When true (wide viewport, at the same 800px breakpoint the ops
  /// Profile card uses), the identity fields wrap into two columns so
  /// the card reads exactly like the operator-web Profile card.
  final bool twoColumn;

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
    final displayName = resolvedDisplay.isEmpty
        ? 'Not on file'
        : resolvedDisplay;
    final email = resolvedEmail.isEmpty ? 'Not on file' : resolvedEmail;
    final explainer = onEditIdentity == null
        ? 'Your sign-in details for the Forge & Flow admin console. '
              'These are read-only here. To update them, contact your '
              'Forge & Flow ecosystem admin.'
        : 'Your sign-in details for the Forge & Flow admin console. '
              'Use Edit identity to change your display name or sign-in '
              'email. Changing your email signs you out.';
    final fields = <Widget>[
      _AdminAccountField(label: 'Display name', value: displayName),
      _AdminAccountField(label: 'Email', value: email),
      _AdminAccountField(
        label: 'Role',
        value: _readableAdminRole(session.roles),
        valueWidget: Row(
          key: const Key('admin_my_account_role_badge'),
          children: [_AdminRoleChip(label: _readableAdminRole(session.roles))],
        ),
      ),
      _AdminAccountField(
        label: 'Scope',
        value: 'Global: cross-operator',
        helper:
            'Admin console access is global. You can see and support '
            'every business on Forge & Flow.',
      ),
    ];
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_identity_card'),
      title: 'Identity',
      headerExplainer: explainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (twoColumn)
            Wrap(
              key: const Key('admin_my_account_identity_two_column'),
              spacing: 24,
              runSpacing: 14,
              children: [
                for (final field in fields) SizedBox(width: 280, child: field),
              ],
            )
          else
            Column(
              key: const Key('admin_my_account_identity_single_column'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < fields.length; i++) ...[
                  fields[i],
                  if (i != fields.length - 1) const SizedBox(height: 14),
                ],
              ],
            ),
          if (onEditIdentity != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 38,
                child: OutlinedButton.icon(
                  key: const Key('admin_my_account_identity_edit'),
                  onPressed: onEditIdentity,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit identity'),
                  style: AdminButtonStyles.secondary(
                    minHeight: 38,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                ),
              ),
            ),
          ],
          if (identityToast != null) ...[
            const SizedBox(height: 10),
            _AdminConfirmToast(
              toastKey: const Key('admin_my_account_identity_toast'),
              message: identityToast!,
            ),
          ],
        ],
      ),
    );
  }
}

String _readableAdminRole(List<String> roles) {
  if (roles.contains(PermissionKeys.roleSuperAdmin)) return 'Ecosystem admin';
  if (roles.contains(PermissionKeys.roleFfSupport)) return 'Support access';
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

// ─── Two-factor sign-in ─────────────────────────────────────────────

/// MFA as its own card, mirroring the operator-web My account layout
/// (a dedicated "Two-factor sign-in" card with the status pill in the
/// card header). With a [gateway] it renders the working self-service
/// surface (enroll / recover); without one it degrades to the
/// read-only "changes at next sign-in" posture.
class _AdminTwoFactorCard extends StatefulWidget {
  const _AdminTwoFactorCard({
    required this.session,
    required this.onSignInAgain,
    this.gateway,
    this.now,
  });

  final AdminAuthSession session;
  final AdminSecurityGateway? gateway;
  final DateTime Function()? now;

  /// Invoked by the actionable freshness remedy's "Sign in again"
  /// button. Defaults (at the call site) to the admin re-auth path
  /// (`AdminAuthSource.signOut()`), mirroring operator-web's freshness
  /// gate: a real control the admin can act on, not a dead message.
  final VoidCallback onSignInAgain;

  @override
  State<_AdminTwoFactorCard> createState() => _AdminTwoFactorCardState();
}

class _AdminTwoFactorCardState extends State<_AdminTwoFactorCard> {
  bool _loading = false;
  String? _loadError;
  AdminSecurityFactorsListed? _factors;

  // Auto-clearing confirmation toast. [_toastIsError] flips the toast
  // to the negative (red) tone so a fail-closed gateway error can never
  // be mistaken for a success confirmation.
  String? _toast;
  bool _toastIsError = false;
  Timer? _toastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);

  // Sticky (no auto-clear) actionable freshness remedy. Set only when a
  // gateway error reports `requiresFreshSignIn`; cleared when the admin
  // taps "Sign in again" (which signs them out) or starts another
  // action. Mirrors operator-web's freshness gate: an actionable
  // control, not a dead message that auto-fades.
  bool _showFreshnessRemedy = false;

  // Stable idempotency keys: one key per logical user action, reused on
  // every retry of that SAME action so the proxy `proxy_requests`
  // UNIQUE replay returns the original 2xx (no fresh-key-per-call bug).
  int _idempotencyCounter = 0;

  @override
  void initState() {
    super.initState();
    if (widget.gateway != null) {
      unawaited(_loadFactors());
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
    final r = math.Random.secure().nextInt(0x7fffffff).toRadixString(36);
    return 'admin-my-account-2fa-$action-$ts-$r-$_idempotencyCounter';
  }

  void _showToast(String message) =>
      _showToastInternal(message, isError: false);

  /// Negative (red) toast for a fail-closed gateway error.
  void _showErrorToast(String message) =>
      _showToastInternal(message, isError: true);

  void _showToastInternal(String message, {required bool isError}) {
    _toastTimer?.cancel();
    setState(() {
      _toast = message;
      _toastIsError = isError;
      // Any new toast (success or a non-freshness error) supersedes a
      // stale freshness remedy so the card never shows both.
      _showFreshnessRemedy = false;
    });
    _toastTimer = Timer(_kToastVisibleDuration, () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  /// Routes a gateway error to the right surface. A freshness/step-up
  /// error (`AdminSecurityGatewayError.requiresFreshSignIn`) shows the
  /// actionable "Sign in again" remedy; every OTHER error keeps the
  /// existing fail-closed red toast. Fail-closed behavior is unchanged
  /// either way: the caller has already left the prior state intact.
  void _handleGatewayError(Object error) {
    if (error is AdminSecurityGatewayError && error.requiresFreshSignIn) {
      _toastTimer?.cancel();
      setState(() {
        _toast = null;
        _showFreshnessRemedy = true;
      });
      return;
    }
    _showErrorToast(_friendly(error));
  }

  DateTime _now() => (widget.now?.call() ?? DateTime.now()).toUtc();

  String _friendly(Object error) {
    if (error is AdminSecurityGatewayError) {
      // Mirror operator-web's freshness gate: a "sign in again" remedy
      // rather than a generic error when the proxy demands a fresh
      // step-up before a security-sensitive change.
      if (error.requiresFreshSignIn) {
        return 'Please sign in again before changing two-factor sign-in. '
            'This protects your account settings.';
      }
      if (error.statusCode == 408) {
        return 'The admin console timed out reaching the security service. '
            'Try again in a moment.';
      }
      if (error.message.trim().isNotEmpty) return error.message.trim();
    }
    return 'We could not complete that security action. Try again in a '
        'moment.';
  }

  Future<void> _loadFactors() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final listed = await gateway.listFactors();
      if (!mounted) return;
      setState(() {
        _factors = listed;
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

  Future<void> _handleEnroll() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final email = widget.session.email.trim();
    if (email.isEmpty) {
      _showToast(
        'We need an account email on file before you can set up an '
        'authenticator. Update your identity first.',
      );
      return;
    }
    // One stable key for the whole enroll -> confirm action chain.
    final actionKey = _mintIdempotencyKey('enroll');
    AdminSecurityTotpEnrollment enrollment;
    try {
      enrollment = await gateway.beginTotpEnrollment(
        userEmail: email,
        idempotencyKey: actionKey,
      );
    } catch (error) {
      if (!mounted) return;
      _handleGatewayError(error);
      return;
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _AdminEnrollMfaDialog(
        gateway: gateway,
        enrollment: enrollment,
        confirmIdempotencyKey: actionKey,
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      _showToast('Authenticator app added. Two-factor sign-in is now on.');
      await _loadFactors();
    }
  }

  Future<void> _handleRecovery() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final email = widget.session.email.trim();
    final requested = await showDialog<bool>(
      context: context,
      builder: (_) => _AdminMfaRecoveryDialog(
        gateway: gateway,
        seededEmail: email,
        idempotencyKey: _mintIdempotencyKey('recovery'),
      ),
    );
    if (!mounted) return;
    if (requested == true) {
      _showToast(
        'Recovery requested. Check the email on file for the next step.',
      );
    }
  }

  /// Schedules a 24-hour delayed removal of the enrolled authenticator,
  /// mirroring operator-web's manage -> confirm -> request flow. Fails
  /// closed: on any gateway error we show the red error/toast and leave
  /// the factor enrolled.
  Future<void> _handleRequestRemoval(AdminSecurityMfaFactor factor) async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const _AdminTurnOffMfaDialog(),
    );
    if (!mounted || confirmed != true) return;
    // One stable key per logical request action, reused on retry so the
    // proxy idempotency replay returns the original outcome.
    final key = _mintIdempotencyKey('revoke');
    try {
      await gateway.requestFactorRemoval(
        factorId: factor.factorId,
        idempotencyKey: key,
      );
    } catch (error) {
      if (!mounted) return;
      _handleGatewayError(error);
      return;
    }
    if (!mounted) return;
    await _loadFactors();
    if (!mounted) return;
    _showToast(
      'Two-factor sign-in will turn off after a 24-hour wait. You can '
      'cancel any time before then.',
    );
  }

  /// Cancels the pending removal so two-factor sign-in stays on. Fails
  /// closed: on any gateway error we show the red error/toast and leave
  /// the pending request in place.
  Future<void> _handleCancelRemoval(AdminSecurityMfaRemoval removal) async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final key = _mintIdempotencyKey('cancel-removal');
    try {
      await gateway.cancelFactorRemoval(
        requestId: removal.requestId,
        idempotencyKey: key,
      );
    } catch (error) {
      if (!mounted) return;
      _handleGatewayError(error);
      return;
    }
    if (!mounted) return;
    await _loadFactors();
    if (!mounted) return;
    _showToast('Removal cancelled. Two-factor sign-in stays on.');
  }

  @override
  Widget build(BuildContext context) {
    final lastFresh = widget.session.lastFreshAuthAt;
    final hasGateway = widget.gateway != null;
    final factors = _factors;
    final enrolled = factors?.hasEnrolledFactor ?? false;
    final String mfaLabel;
    final Color mfaColor;
    if (!hasGateway) {
      mfaLabel = lastFresh == null ? 'Unknown' : 'On';
      mfaColor = lastFresh == null ? AppColors.textMuted : AppColors.positive;
    } else if (factors == null) {
      mfaLabel = lastFresh == null ? 'Unknown' : 'Checking...';
      mfaColor = AppColors.textMuted;
    } else {
      mfaLabel = enrolled ? 'On' : 'Not set up';
      mfaColor = enrolled ? AppColors.positive : AppColors.sunsetDark;
    }
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_two_factor_card'),
      title: 'Two-factor sign-in',
      headerExplainer:
          'Two-factor sign-in means a one-time code is required at every '
          'sign-in, in addition to your password. We require it for every '
          'Forge & Flow admin.',
      statusBadge: _AdminStatusBadge(
        key: const Key('admin_my_account_mfa_status'),
        label: mfaLabel,
        color: mfaColor,
      ),
      child: hasGateway ? _buildLive(factors, enrolled) : _buildReadOnly(),
    );
  }

  Widget _buildLive(AdminSecurityFactorsListed? factors, bool enrolled) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loading && factors == null) ...[
          const LinearProgressIndicator(
            minHeight: 2,
            color: AppColors.sunsetDark,
            backgroundColor: AppColors.borderSubtle,
          ),
          const SizedBox(height: 10),
        ],
        if (_loadError != null) ...[
          _AdminInlineError(
            key: const Key('admin_my_account_security_load_error'),
            message: _loadError!,
            onRetry: _loading ? null : _loadFactors,
          ),
          const SizedBox(height: 10),
        ],
        if (factors != null && !enrolled)
          _AdminActionRow(
            actionKey: const Key('admin_my_account_mfa_enroll_button'),
            header: 'Set up your authenticator app',
            body:
                'Add an authenticator app so every sign-in asks for a '
                'one-time code in addition to your password. Some sensitive '
                'admin actions stay locked until you do.',
            buttonLabel: 'Set up authenticator app',
            onPressed: _handleEnroll,
          ),
        if (factors != null && enrolled) ..._buildEnrolled(factors),
        if (_showFreshnessRemedy) ...[
          const SizedBox(height: 10),
          _AdminFreshnessRemedy(onSignInAgain: widget.onSignInAgain),
        ],
        if (_toast != null) ...[
          const SizedBox(height: 10),
          if (_toastIsError)
            _AdminDialogError(
              key: const Key('admin_my_account_two_factor_toast'),
              message: _toast!,
            )
          else
            _AdminConfirmToast(
              toastKey: const Key('admin_my_account_two_factor_toast'),
              message: _toast!,
            ),
        ],
      ],
    );
  }

  /// Enrolled-state body. Always offers recovery; adds either the
  /// "Turn off two-factor sign-in" action (no pending removal) or the
  /// pending/scheduled state + "Cancel removal" (a removal is in
  /// flight). Mirrors operator-web's enrolled -> removalRequested
  /// stages on the simpler admin card.
  List<Widget> _buildEnrolled(AdminSecurityFactorsListed factors) {
    final pending = factors.pendingRemoval;
    final primaryFactor = factors.factors.first;
    return <Widget>[
      _AdminActionRow(
        actionKey: const Key('admin_my_account_mfa_recovery_button'),
        header: 'Two-factor sign-in is on',
        body:
            'An authenticator app is protecting your account. If you lose '
            'access to it, start recovery and we will email the account '
            'on file with the next step.',
        buttonLabel: 'Lost your authenticator?',
        onPressed: _handleRecovery,
      ),
      const SizedBox(height: 16),
      if (pending == null)
        _AdminActionRow(
          actionKey: const Key('admin_my_account_mfa_turn_off_button'),
          header: 'Turn off two-factor sign-in',
          body:
              'We wait 24 hours before turning off two-factor sign-in so '
              'that if someone got into your account, you have time to '
              'stop them. You may be asked to sign in again first.',
          buttonLabel: 'Turn off two-factor sign-in',
          onPressed: () => _handleRequestRemoval(primaryFactor),
        )
      else
        _AdminMfaRemovalPending(
          executeAfter: pending.executeAfter,
          now: _now(),
          onCancel: () => _handleCancelRemoval(pending),
        ),
    ];
  }

  Widget _buildReadOnly() {
    return _AdminReadOnlyNote(
      key: const Key('admin_my_account_two_factor_readonly_note'),
      icon: Icons.info_outline,
      message:
          'Changes to two-factor sign-in happen the next time you sign in to '
          'the admin console. Use the sign-in page to update them.',
    );
  }
}

// ─── Security (password + recent sign-in activity) ──────────────────

/// The "Security" card: change password + recent sign-in activity,
/// mirroring the operator-web My account Security card. The activity
/// list reuses the self-scoped `GET /v1/auth/audit-log` route via
/// [AdminSecurityGateway.listSignInHistory].
class _AdminSecurityCard extends StatefulWidget {
  const _AdminSecurityCard({this.gateway, this.now});

  final AdminSecurityGateway? gateway;
  final DateTime Function()? now;

  @override
  State<_AdminSecurityCard> createState() => _AdminSecurityCardState();
}

class _AdminSecurityCardState extends State<_AdminSecurityCard> {
  String? _passwordToast;
  Timer? _passwordToastTimer;
  static const Duration _kToastVisibleDuration = Duration(seconds: 4);
  int _idempotencyCounter = 0;

  List<AdminSecurityAuditEntry> _history = const <AdminSecurityAuditEntry>[];
  bool _historyLoading = false;
  String? _historyError;
  int _historyGeneration = 0;
  _AdminHistoryWindow _historyWindow = _AdminHistoryWindow.last90Days;

  @override
  void initState() {
    super.initState();
    if (widget.gateway != null) {
      unawaited(_loadHistory());
    }
  }

  @override
  void dispose() {
    _passwordToastTimer?.cancel();
    super.dispose();
  }

  String _mintIdempotencyKey(String action) {
    _idempotencyCounter += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
    final r = math.Random.secure().nextInt(0x7fffffff).toRadixString(36);
    return 'admin-my-account-security-$action-$ts-$r-$_idempotencyCounter';
  }

  DateTime _now() => (widget.now?.call() ?? DateTime.now()).toUtc();

  Future<void> _handleChangePassword() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _AdminChangePasswordDialog(
        gateway: gateway,
        idempotencyKey: _mintIdempotencyKey('password'),
      ),
    );
    if (!mounted) return;
    if (changed == true) {
      _passwordToastTimer?.cancel();
      setState(() => _passwordToast = 'Password updated.');
      _passwordToastTimer = Timer(_kToastVisibleDuration, () {
        if (!mounted) return;
        setState(() => _passwordToast = null);
      });
    }
  }

  Future<void> _loadHistory() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final generation = ++_historyGeneration;
    setState(() {
      _historyLoading = true;
      _historyError = null;
    });
    try {
      final listed = await gateway.listSignInHistory();
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _history = listed.entries;
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _historyGeneration) return;
      setState(() {
        _historyLoading = false;
        _historyError =
            'Could not load recent sign-in activity. Refresh this section or '
            'try again in a moment.';
      });
    }
  }

  List<AdminSecurityAuditEntry> _filteredHistory() {
    final cutoff = _now().subtract(_historyWindow.duration);
    return _history
        .where((e) => !e.occurredAt.toUtc().isBefore(cutoff))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final hasGateway = widget.gateway != null;
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_security_card'),
      title: 'Security',
      headerExplainer:
          'A strong password and recent sign-in activity help protect your '
          'admin account. Password changes may ask you to sign in again.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AdminActionRow(
            actionKey: const Key('admin_my_account_change_password_button'),
            header: 'Change password',
            body:
                'You will be asked for your current password, then your new '
                'password twice. Use at least 12 characters with a number '
                'and a symbol.',
            buttonLabel: 'Change password',
            onPressed: hasGateway ? _handleChangePassword : null,
            tooltip: hasGateway
                ? null
                : 'Connect your admin account to change your password from '
                      'here.',
          ),
          if (_passwordToast != null) ...[
            const SizedBox(height: 10),
            _AdminConfirmToast(
              toastKey: const Key('admin_my_account_password_toast'),
              message: _passwordToast!,
            ),
          ],
          const SizedBox(height: 14),
          const Divider(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 14),
          _AdminLoginHistorySection(
            hasGateway: hasGateway,
            entries: _filteredHistory(),
            loading: _historyLoading,
            errorMessage: _historyError,
            window: _historyWindow,
            onWindowChanged: (next) => setState(() => _historyWindow = next),
            onRetry: _loadHistory,
          ),
        ],
      ),
    );
  }
}

// ─── Shared action row + recent sign-in activity ────────────────────

/// Header + explainer + outlined action button, mirroring the
/// operator-web `_ActionRow` so the admin Security / Two-factor cards
/// present their primary actions identically.
class _AdminActionRow extends StatelessWidget {
  const _AdminActionRow({
    required this.actionKey,
    required this.header,
    required this.body,
    required this.buttonLabel,
    required this.onPressed,
    this.tooltip,
  });

  final Key actionKey;
  final String header;
  final String body;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      height: 38,
      child: OutlinedButton(
        key: actionKey,
        onPressed: onPressed,
        style: AdminButtonStyles.secondary(
          minHeight: 38,
          borderColor: onPressed == null
              ? AppColors.borderSubtle
              : AppColors.sunsetDark,
          padding: const EdgeInsets.symmetric(horizontal: 16),
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
          child: tooltip == null
              ? button
              : Tooltip(message: tooltip!, child: button),
        ),
      ],
    );
  }
}

/// Pending two-factor removal state. Mirrors operator-web's
/// `removalRequested` stage: a "turns off in" countdown headline, the
/// 24-hour-wait explainer, the scheduled UTC date, and a "Cancel
/// removal" action that keeps two-factor sign-in on.
class _AdminMfaRemovalPending extends StatelessWidget {
  const _AdminMfaRemovalPending({
    required this.executeAfter,
    required this.now,
    required this.onCancel,
  });

  final DateTime executeAfter;
  final DateTime now;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final remaining = _formatRemaining(executeAfter, now);
    return Container(
      key: const Key('admin_my_account_mfa_removal_pending'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.06),
        border: Border.all(
          color: AppColors.sunset.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Turning off two-factor sign-in',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 4),
          Text(
            'Two-factor sign-in turns off in $remaining unless you cancel. '
            'We wait 24 hours so that if someone got into your account, you '
            'have time to stop them.',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'Scheduled for ${_formatAdminAuditStamp(executeAfter)}',
            key: const Key('admin_my_account_mfa_removal_scheduled'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 38,
              child: OutlinedButton(
                key: const Key('admin_my_account_mfa_cancel_removal_button'),
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  side: const BorderSide(color: AppColors.sunsetDark, width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: AppTextStyles.mono14(
                    color: AppColors.sunsetDark,
                    weight: FontWeight.w600,
                  ),
                ),
                child: const Text('Cancel removal'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatRemaining(DateTime executeAfter, DateTime now) {
    final remaining = executeAfter.toUtc().difference(now.toUtc());
    if (remaining.inMicroseconds <= 0) return 'less than a minute';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    final roundedMinutes = remaining.inMinutes < 1 ? 1 : remaining.inMinutes;
    return '${roundedMinutes}m';
  }
}

/// Time window for the recent sign-in activity filter. Mirrors the
/// operator-web `_SecurityHistoryWindow`.
enum _AdminHistoryWindow { last7Days, last30Days, last90Days }

extension _AdminHistoryWindowMeta on _AdminHistoryWindow {
  Duration get duration {
    switch (this) {
      case _AdminHistoryWindow.last7Days:
        return const Duration(days: 7);
      case _AdminHistoryWindow.last30Days:
        return const Duration(days: 30);
      case _AdminHistoryWindow.last90Days:
        return const Duration(days: 90);
    }
  }

  String get label {
    switch (this) {
      case _AdminHistoryWindow.last7Days:
        return 'Last 7 days';
      case _AdminHistoryWindow.last30Days:
        return 'Last 30 days';
      case _AdminHistoryWindow.last90Days:
        return 'Last 90 days';
    }
  }

  String get filterKey {
    switch (this) {
      case _AdminHistoryWindow.last7Days:
        return 'last_7';
      case _AdminHistoryWindow.last30Days:
        return 'last_30';
      case _AdminHistoryWindow.last90Days:
        return 'last_90';
    }
  }
}

/// Recent sign-in activity list, mirroring the operator-web
/// `_LoginHistorySection` (title + explainer + 7/30/90 filter chips +
/// rows / loading / empty / error states).
class _AdminLoginHistorySection extends StatelessWidget {
  const _AdminLoginHistorySection({
    required this.hasGateway,
    required this.entries,
    required this.loading,
    required this.errorMessage,
    required this.window,
    required this.onWindowChanged,
    required this.onRetry,
  });

  final bool hasGateway;
  final List<AdminSecurityAuditEntry> entries;
  final bool loading;
  final String? errorMessage;
  final _AdminHistoryWindow window;
  final ValueChanged<_AdminHistoryWindow> onWindowChanged;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('admin_my_account_login_history_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recent sign-in activity',
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Sign-ins, password changes, and authenticator events on your '
          'admin account, capped at the last 90 days. If you see something '
          'you do not recognise, change your password and review your '
          'authenticators.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final w in _AdminHistoryWindow.values)
              _AdminWindowChip(
                keyName: 'admin_my_account_login_history_filter_${w.filterKey}',
                label: w.label,
                selected: w == window,
                onTap: () => onWindowChanged(w),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!hasGateway)
          const _AdminInlineState(
            stateKey: Key('admin_my_account_login_history_disconnected'),
            icon: Icons.history,
            message:
                'Recent sign-in activity will appear here once your admin '
                'account is connected.',
          )
        else if (loading)
          const _AdminInlineState(
            stateKey: Key('admin_my_account_login_history_loading'),
            icon: Icons.sync,
            message: 'Loading recent sign-in activity...',
          )
        else if (errorMessage != null)
          _AdminInlineError(
            key: const Key('admin_my_account_login_history_error'),
            message: errorMessage!,
            onRetry: onRetry,
          )
        else if (entries.isEmpty)
          const _AdminInlineState(
            stateKey: Key('admin_my_account_login_history_empty'),
            icon: Icons.history,
            message: 'No sign-in activity in this window.',
          )
        else
          for (var i = 0; i < entries.length; i++) ...[
            _AdminLoginHistoryRow(entry: entries[i]),
            if (i != entries.length - 1) const SizedBox(height: 10),
          ],
      ],
    );
  }
}

class _AdminWindowChip extends StatelessWidget {
  const _AdminWindowChip({
    required this.keyName,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String keyName;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      key: Key(keyName),
      label: Text(label),
      selected: selected,
      labelStyle: AppTextStyles.mono11(
        color: selected ? AppColors.sunsetDark : AppColors.textSecondary,
      ),
      selectedColor: AppColors.sunset.withValues(alpha: 0.15),
      backgroundColor: AppColors.backgroundSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(
          color: selected ? AppColors.sunsetDark : AppColors.borderSubtle,
          width: 1,
        ),
      ),
      onSelected: (_) => onTap(),
    );
  }
}

class _AdminLoginHistoryRow extends StatelessWidget {
  const _AdminLoginHistoryRow({required this.entry});

  final AdminSecurityAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_my_account_login_history_row_${entry.eventId}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.history, size: 18, color: AppColors.sunsetDark),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.friendlyLabel,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 3),
                Text(
                  _metaLine(entry),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _metaLine(AdminSecurityAuditEntry entry) {
    final geo = <String>[
      if (entry.geoCity != null && entry.geoCity!.isNotEmpty) entry.geoCity!,
      if (entry.geoCountry != null && entry.geoCountry!.isNotEmpty)
        entry.geoCountry!,
    ].join(', ');
    final parts = <String>[
      _formatAdminAuditStamp(entry.occurredAt),
      if (entry.deviceLabel != null && entry.deviceLabel!.isNotEmpty)
        entry.deviceLabel!,
      if (geo.isNotEmpty) geo,
    ];
    return parts.join(' / ');
  }
}

/// Inline icon + message row for loading / empty / disconnected
/// states. Mirrors the operator-web `_AccountInlineState`.
class _AdminInlineState extends StatelessWidget {
  const _AdminInlineState({
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

String _formatAdminAuditStamp(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year}-${_twoDigits(utc.month)}-${_twoDigits(utc.day)} '
      '${_twoDigits(utc.hour)}:${_twoDigits(utc.minute)} UTC';
}

class _AdminInlineError extends StatelessWidget {
  const _AdminInlineError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
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
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
          if (onRetry != null)
            TextButton(
              key: const Key('admin_my_account_security_retry'),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

class _AdminStatusBadge extends StatelessWidget {
  const _AdminStatusBadge({
    super.key,
    required this.label,
    required this.color,
  });

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

/// Actionable freshness remedy for the Two-factor card. When the proxy
/// demands a fresh step-up before a security-sensitive change, the card
/// swaps the dead red error message for this: a negative-tone box with
/// plain-English copy and a real "Sign in again" button that routes
/// through the admin re-auth path. Mirrors operator-web's freshness
/// gate (an actionable control, not a message the admin cannot act on).
class _AdminFreshnessRemedy extends StatelessWidget {
  const _AdminFreshnessRemedy({required this.onSignInAgain});

  final VoidCallback onSignInAgain;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_my_account_two_factor_freshness_remedy'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.lock_clock_outlined,
                size: 16,
                color: AppColors.negative,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Please sign in again before changing two-factor sign-in. '
                  'This protects your account settings.',
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 38,
              child: OutlinedButton.icon(
                key: const Key('admin_my_account_two_factor_sign_in_again'),
                onPressed: onSignInAgain,
                icon: const Icon(Icons.login, size: 16),
                label: const Text('Sign in again'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.negative,
                  side: const BorderSide(color: AppColors.negative, width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  textStyle: AppTextStyles.mono14(
                    color: AppColors.negative,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Positive (green) confirmation toast shared by the Identity and
/// Security cards. Mirrors the operator-web My account success toast
/// (a check icon + body13 positive copy in a tinted rounded box).
class _AdminConfirmToast extends StatelessWidget {
  const _AdminConfirmToast({required this.toastKey, required this.message});

  final Key toastKey;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: toastKey,
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
              message,
              style: AppTextStyles.body13(color: AppColors.positive),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Active sessions ────────────────────────────────────────────────

/// The "Active sessions" card. Mirrors the operator-web My account
/// card: a minimal card whose "Manage active sessions here" button
/// opens a popup that lists every signed-in admin session with
/// per-session sign-out plus sign-out-everywhere. (Operator chose the
/// ops popup pattern; the admin-only richer controls live inside it.)
class _AdminActiveSessionsCard extends StatelessWidget {
  const _AdminActiveSessionsCard({
    required this.session,
    required this.onSignOut,
    this.gateway,
    this.now,
  });

  final AdminAuthSession session;
  final VoidCallback onSignOut;
  final AdminSessionsGateway? gateway;
  final DateTime Function()? now;

  Future<void> _openManageDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => _AdminActiveSessionsDialog(
        session: session,
        onSignOut: onSignOut,
        gateway: gateway,
        now: now,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_active_sessions_card'),
      title: 'Active sessions',
      headerExplainer:
          'Review browsers and devices signed in to your admin account. '
          'This device stays signed in when you sign out the others.',
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('admin_my_account_active_sessions_manage'),
          onPressed: () => _openManageDialog(context),
          icon: const Icon(Icons.devices_other_outlined, size: 16),
          label: const Text('Manage active sessions here'),
          style: AdminButtonStyles.text.copyWith(
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 0, vertical: 8),
            ),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            alignment: Alignment.centerLeft,
          ),
        ),
      ),
    );
  }
}

/// The active-sessions management popup. Holds the session list +
/// per-session revoke + sign-out-everywhere + local sign-out, all
/// inside the shared [OperatorWebDialog] chrome (ops popup parity).
class _AdminActiveSessionsDialog extends StatefulWidget {
  const _AdminActiveSessionsDialog({
    required this.session,
    required this.onSignOut,
    this.gateway,
    this.now,
  });

  final AdminAuthSession session;
  final VoidCallback onSignOut;
  final AdminSessionsGateway? gateway;
  final DateTime Function()? now;

  @override
  State<_AdminActiveSessionsDialog> createState() =>
      _AdminActiveSessionsDialogState();
}

class _AdminActiveSessionsDialogState
    extends State<_AdminActiveSessionsDialog> {
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
    final r = math.Random.secure().nextInt(0x7fffffff).toRadixString(36);
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
        _sessions = listed.where((s) => s.isActive).toList(growable: false);
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
      // tokens are revoked server-side. Close the popup, then route
      // through the local sign-out so the gate returns to the sign-in
      // card immediately.
      Navigator.of(context).pop();
      widget.onSignOut();
    } catch (error) {
      if (!mounted) return;
      setState(() => _signingOutEverywhere = false);
      _showToast(_friendly(error));
    }
  }

  void _handleLocalSignOut() {
    Navigator.of(context).pop();
    widget.onSignOut();
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
    final hasGateway = widget.gateway != null;
    return OperatorWebDialog(
      key: const Key('admin_my_account_active_sessions_dialog'),
      title: 'Active sessions',
      icon: Icons.devices_other_outlined,
      maxWidth: 560,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_my_account_active_sessions_dialog_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          key: const Key('admin_my_account_sign_out_button'),
          onPressed: _handleLocalSignOut,
          icon: const Icon(Icons.logout_outlined, size: 16),
          label: const Text('Sign out of this session'),
          style: AdminButtonStyles.secondary(),
        ),
        if (hasGateway)
          OutlinedButton.icon(
            key: const Key('admin_my_account_sign_out_everywhere_button'),
            onPressed: _signingOutEverywhere ? null : _signOutEverywhere,
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
            style: AdminButtonStyles.secondary(
              foregroundColor: AppColors.negative,
              borderColor: AppColors.negative,
            ),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCurrentSessionRow(),
          if (hasGateway) ...[
            const SizedBox(height: 12),
            _buildSessionsList(),
          ] else ...[
            const SizedBox(height: 12),
            _AdminReadOnlyNote(
              key: const Key('admin_my_account_sessions_readonly_note'),
              icon: Icons.info_outline,
              message:
                  'A list of every signed-in admin session is not available '
                  'here yet. Reach out to a Forge & Flow ecosystem admin if '
                  'you suspect a session needs to be revoked.',
            ),
          ],
          if (_toast != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('admin_my_account_sessions_toast'),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                      style: AppTextStyles.body13(color: AppColors.peacockDark),
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

  Widget _buildCurrentSessionRow() {
    final lastFresh = widget.session.lastFreshAuthAt;
    final lastSignedInHelper = lastFresh == null
        ? 'Sign-in time is not available for this session.'
        : 'Signed in ${_formatRelative(lastFresh, widget.now)}.';
    return Container(
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
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          _AdminStatusBadge(label: 'This device', color: AppColors.positive),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: SingleChildScrollView(
        child: Column(
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
        ),
      ),
    );
  }
}

// ─── Audit log ──────────────────────────────────────────────────────

/// The "Audit log" card, mirroring the operator-web My account Audit
/// log card: a "View audit log" button. On admin the button navigates
/// (via [MyAccountAdminScreen.onOpenAuditLog]) to the existing
/// "Security, audit, and sessions" surface, where the admin picks a
/// business and reviews its audit history, active sessions, and
/// support actions. The admin's OWN sign-in / password / two-factor
/// history lives in the Security card's "Recent sign-in activity"
/// above, so this card is a jump-off to the business audit, not a
/// second copy of the personal history.
class _AdminAuditLogCard extends StatelessWidget {
  const _AdminAuditLogCard({this.onOpenAuditLog});

  /// When non-null, the button navigates to the full Audit log page.
  /// Null (a screen mounted without a shell, e.g. older widget tests)
  /// renders the button disabled.
  final VoidCallback? onOpenAuditLog;

  @override
  Widget build(BuildContext context) {
    return _AdminAccountCard(
      cardKey: const Key('admin_my_account_audit_log_card'),
      title: 'Audit log',
      headerExplainer:
          'Open the audit log to review the full change history for a '
          'business you choose. Your own sign-in history is in Security, '
          'under Recent sign-in activity.',
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          height: 38,
          child: OutlinedButton.icon(
            key: const Key('admin_my_account_audit_log_link'),
            onPressed: onOpenAuditLog,
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: const Text('View audit log'),
            style: AdminButtonStyles.secondary(
              minHeight: 38,
              borderColor: onOpenAuditLog == null
                  ? AppColors.borderSubtle
                  : AppColors.sunsetDark,
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
          ),
        ),
      ),
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
    final subtitle = whereParts.isEmpty
        ? lastSeen
        : '$lastSeen · ${whereParts.join(', ')}';
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
              key: Key('admin_my_account_session_revoke_${entry.sessionId}'),
              onPressed: revoking ? null : onRevoke,
              style: AdminButtonStyles.secondary(
                foregroundColor: AppColors.negative,
                borderColor: AppColors.negative,
                minWidth: 0,
                minHeight: 32,
                padding: const EdgeInsets.symmetric(horizontal: 12),
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
    required this.idempotencyKey,
  });

  final AdminAccountGateway gateway;
  final String currentDisplayName;
  final String currentEmail;

  /// G70: caller-stable idempotency key for the logical "save
  /// identity" action. Minted once by `_handleEditIdentity` when the
  /// dialog is created and reused across every retry of `_handleSave`
  /// so a timeout/5xx-then-retap cannot apply the same identity PATCH
  /// twice. Mirrors the stable `widget.idempotencyKey` threaded by the
  /// sibling password / recovery / MFA-confirm dialogs in this file.
  final String idempotencyKey;

  @override
  State<_AdminEditIdentityDialog> createState() =>
      _AdminEditIdentityDialogState();
}

class _AdminEditIdentityDialogState extends State<_AdminEditIdentityDialog> {
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
      _trimmedEmail().toLowerCase() != widget.currentEmail.trim().toLowerCase();
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
        // G70: reuse the caller-stable key. The failure path below
        // keeps the dialog open so a re-tap re-runs `_handleSave`;
        // reusing `widget.idempotencyKey` (not a fresh mint) lets the
        // proxy `proxy_requests` UNIQUE guard collapse the retry.
        idempotencyKey: widget.idempotencyKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(_AdminEditIdentityResult(patched: patched));
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

  @override
  Widget build(BuildContext context) {
    // UX parity: route this dialog through the shared [OperatorWebDialog]
    // chrome (Playfair display20 title, hairline border + soft shadow, and
    // a persistent top-right close affordance) so the admin Edit-identity
    // popup matches the operator-web gold standard. Fields, validation,
    // and save/cancel logic are unchanged; only the surrounding chrome
    // and the dropped hand-rolled title row are different.
    return OperatorWebDialog(
      key: const Key('admin_edit_identity_dialog'),
      title: 'Edit your identity',
      maxWidth: 480,
      onClose: _submitting ? () {} : null,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_edit_identity_cancel'),
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_edit_identity_save'),
          onPressed: _canSave ? _handleSave : null,
          child: Text(_submitting ? 'Saving...' : 'Save changes'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Update your admin display name and sign-in email. '
            'Changing your email signs you out so you can sign back '
            'in with the new address.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Text(
            'Display name',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
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
          Text(
            'Email',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('admin_edit_identity_email_field'),
            controller: _emailController,
            enabled: !_submitting,
            keyboardType: TextInputType.emailAddress,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
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
                      'admin_edit_identity_email_confirm_checkbox',
                    ),
                    value: _confirmEmailChange,
                    onChanged: _submitting
                        ? null
                        : (v) =>
                              setState(() => _confirmEmailChange = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      'Confirm you want to change your sign-in email.',
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
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
        ],
      ),
    );
  }
}

// ─── Security dialogs (G4) ──────────────────────────────────────────

/// Enroll-an-authenticator dialog. The begin call already ran (so a
/// retried confirm replays the SAME caller-stable key); this dialog
/// only collects the 6-digit code and confirms.
class _AdminEnrollMfaDialog extends StatefulWidget {
  const _AdminEnrollMfaDialog({
    required this.gateway,
    required this.enrollment,
    required this.confirmIdempotencyKey,
  });

  final AdminSecurityGateway gateway;
  final AdminSecurityTotpEnrollment enrollment;
  final String confirmIdempotencyKey;

  @override
  State<_AdminEnrollMfaDialog> createState() => _AdminEnrollMfaDialogState();
}

class _AdminEnrollMfaDialogState extends State<_AdminEnrollMfaDialog> {
  final TextEditingController _codeController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _codeController.addListener(() {
      if (!mounted) return;
      setState(() {
        if (_error != null) _error = null;
      });
    });
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  String get _code => _codeController.text.trim();
  bool get _canSubmit => !_submitting && _code.length == 6;

  Future<void> _confirm() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.gateway.confirmTotpEnrollment(
        factorId: widget.enrollment.factorId,
        oneTimeCode: _code,
        idempotencyKey: widget.confirmIdempotencyKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error =
            error is AdminSecurityGatewayError &&
                error.message.trim().isNotEmpty
            ? error.message.trim()
            : 'That code did not match. Try the next one your app shows.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_enroll_mfa_dialog'),
      title: 'Set up your authenticator app',
      icon: Icons.security_outlined,
      maxWidth: 540,
      actions: [
        TextButton(
          key: const Key('admin_enroll_mfa_cancel'),
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_enroll_mfa_confirm'),
          onPressed: _canSubmit ? _confirm : null,
          child: Text(_submitting ? 'Confirming...' : 'Confirm'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Open your authenticator app, add a new account, and either '
              'scan the QR code below or paste the secret. Then enter the '
              '6-digit code your app shows.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            Center(
              child: Container(
                key: const Key('admin_enroll_mfa_qr'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: QrImageView(
                  data: widget.enrollment.otpAuthUrl,
                  version: QrVersions.auto,
                  size: 148,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Setup link',
              style: AppTextStyles.mono11(color: AppColors.sunsetDark),
            ),
            const SizedBox(height: 4),
            SelectableText(
              widget.enrollment.otpAuthUrl,
              key: const Key('admin_enroll_mfa_otpauth'),
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Text(
              'Secret',
              style: AppTextStyles.mono11(color: AppColors.sunsetDark),
            ),
            const SizedBox(height: 4),
            SelectableText(
              widget.enrollment.secretBase32,
              key: const Key('admin_enroll_mfa_secret'),
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 16),
            Text(
              '6-digit code',
              style: AppTextStyles.mono11(color: AppColors.sunsetDark),
            ),
            const SizedBox(height: 4),
            TextField(
              key: const Key('admin_enroll_mfa_code_field'),
              controller: _codeController,
              enabled: !_submitting,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              _AdminDialogError(
                key: const Key('admin_enroll_mfa_error'),
                message: _error!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Change-password dialog. One stable idempotency key per submit
/// action, threaded through unchanged.
class _AdminChangePasswordDialog extends StatefulWidget {
  const _AdminChangePasswordDialog({
    required this.gateway,
    required this.idempotencyKey,
  });

  final AdminSecurityGateway gateway;
  final String idempotencyKey;

  @override
  State<_AdminChangePasswordDialog> createState() =>
      _AdminChangePasswordDialogState();
}

class _AdminChangePasswordDialogState
    extends State<_AdminChangePasswordDialog> {
  final TextEditingController _currentController = TextEditingController();
  final TextEditingController _newController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final c in [_currentController, _newController, _confirmController]) {
      c.addListener(() {
        if (!mounted) return;
        setState(() {
          if (_error != null) _error = null;
        });
      });
    }
  }

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  bool get _canSubmit =>
      !_submitting &&
      _currentController.text.isNotEmpty &&
      _newController.text.length >= 12 &&
      _newController.text == _confirmController.text;

  static String _rejectionCopy(String code) {
    switch (code) {
      case 'too_short':
        return 'Password must be at least 12 characters with one number '
            'and one symbol.';
      case 'reused':
        return 'Choose a password you have not used before.';
      case 'breached':
      case 'hibp_match':
        return 'That password has appeared in a known breach. Choose a '
            'different one.';
      default:
        return 'That password does not meet the policy ($code).';
    }
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.gateway.changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
        idempotencyKey: widget.idempotencyKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        if (error is AdminSecurityGatewayError) {
          if (error.rejections.isNotEmpty) {
            _error = error.rejections.map(_rejectionCopy).join(' ');
          } else if (error.message.trim().isNotEmpty) {
            _error = error.message.trim();
          } else {
            _error = 'We could not change your password. Try again.';
          }
        } else {
          _error = 'We could not change your password. Try again.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_change_password_dialog'),
      title: 'Change your password',
      icon: Icons.lock_reset_outlined,
      maxWidth: 540,
      actions: [
        TextButton(
          key: const Key('admin_change_password_cancel'),
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_change_password_save'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(_submitting ? 'Saving...' : 'Change password'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter your current password, then choose a new one. Use at '
            'least 12 characters with a number and a symbol.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          _PasswordField(
            fieldKey: const Key('admin_change_password_current'),
            label: 'Current password',
            controller: _currentController,
            enabled: !_submitting,
          ),
          const SizedBox(height: 12),
          _PasswordField(
            fieldKey: const Key('admin_change_password_new'),
            label: 'New password',
            controller: _newController,
            enabled: !_submitting,
          ),
          const SizedBox(height: 12),
          _PasswordField(
            fieldKey: const Key('admin_change_password_confirm'),
            label: 'Confirm new password',
            controller: _confirmController,
            enabled: !_submitting,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            _AdminDialogError(
              key: const Key('admin_change_password_error'),
              message: _error!,
            ),
          ],
        ],
      ),
    );
  }
}

/// Lost-authenticator recovery dialog. Runs unauthenticated server-
/// side (the proxy route does not require a bearer); the gateway still
/// threads a stable Idempotency-Key so a retried submit does not
/// multiply the recovery queue.
class _AdminMfaRecoveryDialog extends StatefulWidget {
  const _AdminMfaRecoveryDialog({
    required this.gateway,
    required this.seededEmail,
    required this.idempotencyKey,
  });

  final AdminSecurityGateway gateway;
  final String seededEmail;
  final String idempotencyKey;

  @override
  State<_AdminMfaRecoveryDialog> createState() =>
      _AdminMfaRecoveryDialogState();
}

class _AdminMfaRecoveryDialogState extends State<_AdminMfaRecoveryDialog> {
  late final TextEditingController _emailController;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.seededEmail);
    _emailController.addListener(() {
      if (!mounted) return;
      setState(() {
        if (_error != null) _error = null;
      });
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  String get _email => _emailController.text.trim();
  bool get _canSubmit => !_submitting && _email.contains('@');

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.gateway.requestMfaRecovery(
        email: _email,
        reason: 'admin_lost_authenticator',
        idempotencyKey: widget.idempotencyKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error =
            error is AdminSecurityGatewayError &&
                error.message.trim().isNotEmpty
            ? error.message.trim()
            : 'We could not start recovery. Try again in a moment.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_mfa_recovery_dialog'),
      title: 'Lost your authenticator?',
      icon: Icons.help_outline,
      maxWidth: 540,
      actions: [
        TextButton(
          key: const Key('admin_mfa_recovery_cancel'),
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_mfa_recovery_submit'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(_submitting ? 'Requesting...' : 'Request recovery'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'If you can no longer get codes from your authenticator app, '
            'we will email the account on file with the next step. A '
            'Forge & Flow ecosystem admin reviews every recovery '
            'request.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Text(
            'Account email',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 4),
          TextField(
            key: const Key('admin_mfa_recovery_email_field'),
            controller: _emailController,
            enabled: !_submitting,
            keyboardType: TextInputType.emailAddress,
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            _AdminDialogError(
              key: const Key('admin_mfa_recovery_error'),
              message: _error!,
            ),
          ],
        ],
      ),
    );
  }
}

/// Confirm dialog for turning off two-factor sign-in. Mirrors the
/// operator-web `_handleRequestMfaRemoval` confirm copy + flow: we wait
/// 24 hours, and the admin may be asked to sign in again. Pops `true`
/// to proceed with scheduling the delayed removal, `false`/null to keep
/// two-factor sign-in on.
class _AdminTurnOffMfaDialog extends StatelessWidget {
  const _AdminTurnOffMfaDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('admin_mfa_turn_off_dialog'),
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
                'Turn off two-factor sign-in?',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'We wait 24 hours before turning off two-factor sign-in so '
                'that if someone got into your account, you have time to '
                'stop them. You may be asked to sign in again before the '
                'request is accepted.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 18),
              // Wrap (not Row) so the longer "Keep two-factor sign-in
              // on" + "Request removal" labels flow to a second line on
              // a narrow dialog instead of overflowing.
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('admin_mfa_turn_off_cancel'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Keep two-factor sign-in on'),
                  ),
                  FilledButton(
                    key: const Key('admin_mfa_turn_off_confirm'),
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.negative,
                      foregroundColor: AppColors.backgroundSurface,
                    ),
                    child: const Text('Request removal'),
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

class _PasswordField extends StatelessWidget {
  const _PasswordField({
    required this.fieldKey,
    required this.label,
    required this.controller,
    required this.enabled,
  });

  final Key fieldKey;
  final String label;
  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono11(color: AppColors.sunsetDark)),
        const SizedBox(height: 4),
        TextField(
          key: fieldKey,
          controller: controller,
          enabled: enabled,
          obscureText: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }
}

class _AdminDialogError extends StatelessWidget {
  const _AdminDialogError({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.negative),
      ),
    );
  }
}
