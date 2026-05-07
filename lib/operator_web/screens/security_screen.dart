// Phase 11W.6 - Operator Web Security screen.
//
// Web parity for the mobile Settings -> Security section. Mounted at
// the `/security` route in the operator-web shell. Renders three
// stacked sections per the parity contract `§ Security`:
//
//   * `Two-factor sign-in` - the actor's MFA factor inventory with
//     enroll, revoke, and cancel-pending-removal actions. Revoke
//     starts a 24-hour delayed-removal request per the
//     `team.users.reset_mfa` posture; the row flips to a
//     `Removal pending` chip + `Cancel removal` action while the
//     window is open. A `Lost access to your authenticator?` link
//     queues a recovery request via /v1/auth/mfa/recovery/request
//     so an operator who cannot sign in via their factor still has
//     a path to reset MFA via support escalation.
//   * `Password` - opens the change-password dialog. Submission
//     reverifies the current password server-side and surfaces the
//     contract's locked validation copy on policy / reuse / wrong-
//     password rejections.
//   * `Recent sign-in activity` - subset of `/v1/auth/audit-log`
//     filtered to `auth.session.*` + `auth.password.*` +
//     `auth.mfa.*` events, capped at the last 90 days. A small
//     filter strip narrows the displayed window to the last 7 / 30 /
//     90 days; the gateway always reads the full 90-day window so
//     the strip works locally without a re-fetch.
//
// Permission gating: every authenticated operator-web actor sees
// their own Security surface. Floor managers (`location_manager`)
// see only their own data; cross-team MFA reset is on `11W.1`
// Members or via `11A.14` support escalation. The screen does not
// gate on any permission key beyond "is the actor authenticated."

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../services/web_security_gateway.dart';
import '../widgets/operator_web_summary_strip.dart';
import '../../theme/app_theme.dart';
import 'change_password_dialog.dart';
import 'mfa_factor_dialog.dart';

/// Login-history filter window the strip exposes. Values are days.
enum SecurityHistoryWindow { last7Days, last30Days, last90Days }

extension _SecurityHistoryWindowLabel on SecurityHistoryWindow {
  Duration get duration {
    switch (this) {
      case SecurityHistoryWindow.last7Days:
        return const Duration(days: 7);
      case SecurityHistoryWindow.last30Days:
        return const Duration(days: 30);
      case SecurityHistoryWindow.last90Days:
        return const Duration(days: 90);
    }
  }

  String get label {
    switch (this) {
      case SecurityHistoryWindow.last7Days:
        return 'Last 7 days';
      case SecurityHistoryWindow.last30Days:
        return 'Last 30 days';
      case SecurityHistoryWindow.last90Days:
        return 'Last 90 days';
    }
  }

  String get filterKey {
    switch (this) {
      case SecurityHistoryWindow.last7Days:
        return 'last_7';
      case SecurityHistoryWindow.last30Days:
        return 'last_30';
      case SecurityHistoryWindow.last90Days:
        return 'last_90';
    }
  }
}

class SecurityScreen extends StatefulWidget {
  const SecurityScreen({
    super.key,
    required this.session,
    required this.gateway,
    this.now,
    this.idempotencyKeyFactory,
  });

  final OperatorWebSession session;
  final WebSecurityGateway gateway;

  /// Test seam for time-relative filtering. Production reads
  /// `DateTime.now()` on every filter pass.
  final DateTime Function()? now;

  /// Test seam for idempotency keys. Production mints a per-action
  /// key from the auth source uid + a sequence counter.
  final String Function()? idempotencyKeyFactory;

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  bool _loading = true;
  String? _loadError;

  List<WebSecurityMfaFactor> _factors = const <WebSecurityMfaFactor>[];
  List<WebSecurityMfaRemoval> _removals = const <WebSecurityMfaRemoval>[];
  List<WebSecurityLoginHistoryEntry> _loginHistory =
      const <WebSecurityLoginHistoryEntry>[];

  final Set<String> _busyFactorIds = <String>{};
  final Set<String> _busyRemovalIds = <String>{};
  bool _passwordChangedToast = false;
  int _loadGeneration = 0;
  int _idempotencySeq = 0;
  SecurityHistoryWindow _historyWindow = SecurityHistoryWindow.last90Days;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencySeq += 1;
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'op-web-security-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  DateTime _now() => widget.now?.call() ?? DateTime.now().toUtc();

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final factorsFuture = widget.gateway.listFactors();
      final historyFuture = widget.gateway.listLoginHistory();
      final results = await Future.wait<Object>([factorsFuture, historyFuture]);
      if (!mounted || generation != _loadGeneration) return;
      final factorsResult = results[0] as WebSecurityFactorsListed;
      final historyResult = results[1] as WebSecurityLoginHistoryListed;
      setState(() {
        _factors = factorsResult.factors;
        _removals = factorsResult.removalRequests;
        _loginHistory = historyResult.entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _loadError = _friendlyLoadError(error);
      });
    }
  }

  String _friendlyLoadError(Object error) {
    if (error is WebSecurityError) {
      return 'Could not load your security settings (${error.code}). '
          'Refresh the page or try again in a moment.';
    }
    return 'Could not load your security settings. Refresh the page or try '
        'again in a moment.';
  }

  Future<void> _onAddFactor() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => MfaFactorDialog(
        gateway: widget.gateway,
        operatorEmail: widget.session.email,
        idempotencyKeyFactory: _nextIdempotencyKey,
      ),
    );
    if (!mounted) return;
    if (result == true) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Authenticator app added.')));
    }
  }

  Future<void> _onRequestRecovery() async {
    final email = widget.session.email;
    if (email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No email is on file for this account. Contact Forge and Flow '
            'support directly to reset MFA.',
          ),
        ),
      );
      return;
    }
    final confirmed = await _confirm(
      title: 'Request authenticator recovery?',
      body:
          'We will email a recovery link to $email. Use this if you cannot '
          'sign in because you have lost access to every authenticator you '
          'enrolled. The link expires after 30 minutes.',
      cta: 'Send recovery link',
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.gateway.requestMfaRecovery(
        email: email,
        reason: 'self_service_settings',
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Recovery link sent to $email. Check your inbox in a few '
            'minutes.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    }
  }

  Future<void> _onRevokeFactor(WebSecurityMfaFactor factor) async {
    if (_busyFactorIds.contains(factor.factorId)) return;
    final confirmed = await _confirm(
      title: 'Remove this authenticator?',
      body:
          'For security, removal happens 24 hours after you confirm. You can '
          'cancel anytime during the wait by clicking Cancel removal on the '
          'factor row.',
      cta: 'Schedule removal',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busyFactorIds.add(factor.factorId));
    try {
      await widget.gateway.revokeFactor(
        factorId: factor.factorId,
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      setState(() => _busyFactorIds.remove(factor.factorId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Authenticator removal scheduled. It will be removed in 24 hours '
            'unless you cancel.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyFactorIds.remove(factor.factorId));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    }
  }

  Future<void> _onCancelRemoval(WebSecurityMfaRemoval removal) async {
    if (_busyRemovalIds.contains(removal.requestId)) return;
    setState(() => _busyRemovalIds.add(removal.requestId));
    try {
      await widget.gateway.cancelFactorRemoval(
        requestId: removal.requestId,
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      setState(() => _busyRemovalIds.remove(removal.requestId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Authenticator removal cancelled.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _busyRemovalIds.remove(removal.requestId));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    }
  }

  Future<void> _onChangePassword() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ChangePasswordDialog(
        gateway: widget.gateway,
        idempotencyKeyFactory: _nextIdempotencyKey,
      ),
    );
    if (!mounted) return;
    if (result == true) {
      setState(() => _passwordChangedToast = true);
      await _load();
    }
  }

  String _friendlyMutationError(Object error) {
    if (error is WebSecurityError) {
      return 'That action could not be completed (${error.code}). Try again '
          'in a moment.';
    }
    return 'That action could not be completed. Try again in a moment.';
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String cta,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('operator_web_security_confirm_dialog'),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            key: const Key('operator_web_security_confirm_dialog_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('operator_web_security_confirm_dialog_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(cta),
          ),
        ],
      ),
    );
    return result == true;
  }

  WebSecurityMfaRemoval? _pendingRemovalFor(String factorId) {
    for (final removal in _removals) {
      if (removal.factorId == factorId && removal.status == 'pending') {
        return removal;
      }
    }
    return null;
  }

  List<WebSecurityLoginHistoryEntry> _filteredHistory() {
    final cutoff = _now().toUtc().subtract(_historyWindow.duration);
    final filtered = _loginHistory
        .where((entry) => !entry.occurredAt.isBefore(cutoff))
        .toList(growable: false);
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('operator_web_security_loading'),
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
      return Center(
        key: const Key('operator_web_security_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Security could not load',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  _loadError!,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('operator_web_security_load_retry'),
                    onPressed: _load,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.sunsetDark,
                      side: const BorderSide(
                        color: AppColors.sunsetDark,
                        width: 1,
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final pendingRemovalCount = _removals
        .where((removal) => removal.status == 'pending')
        .length;
    final visibleHistory = _filteredHistory();
    return SingleChildScrollView(
      key: const Key('operator_web_security_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SecurityHeader(),
          const SizedBox(height: 18),
          OperatorWebSummaryStrip(
            key: const Key('operator_web_security_summary'),
            items: [
              OperatorWebSummaryItem(
                icon: Icons.verified_user_outlined,
                label: 'Authenticators',
                value: _factors.length.toString(),
                helper: 'enrolled for sign-in',
              ),
              OperatorWebSummaryItem(
                icon: Icons.schedule_outlined,
                label: 'Pending removals',
                value: pendingRemovalCount.toString(),
                helper: '24-hour safety window',
              ),
              OperatorWebSummaryItem(
                icon: Icons.password_outlined,
                label: 'Password',
                value: _passwordChangedToast ? 'Updated' : 'Ready',
                helper: 'change with current password',
              ),
              OperatorWebSummaryItem(
                icon: Icons.history_outlined,
                label: 'Activity shown',
                value: visibleHistory.length.toString(),
                helper: _historyWindow.label.toLowerCase(),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _MfaSection(
            factors: _factors,
            pendingRemovalFor: _pendingRemovalFor,
            busyFactorIds: _busyFactorIds,
            busyRemovalIds: _busyRemovalIds,
            onAdd: _onAddFactor,
            onRevoke: _onRevokeFactor,
            onCancelRemoval: _onCancelRemoval,
            onRequestRecovery: _onRequestRecovery,
          ),
          const SizedBox(height: 18),
          _PasswordSection(
            showSuccessToast: _passwordChangedToast,
            onChangePassword: _onChangePassword,
          ),
          const SizedBox(height: 18),
          _LoginHistorySection(
            entries: visibleHistory,
            window: _historyWindow,
            onWindowChanged: (next) => setState(() {
              _historyWindow = next;
            }),
          ),
        ],
      ),
    );
  }
}

class _SecurityHeader extends StatelessWidget {
  const _SecurityHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.shield_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 10),
            Text(
              'Sign-in security',
              style: AppTextStyles.display20(color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Protect your own sign-in with authenticator apps, password '
          'changes, and recent activity. Team-level controls live in Team '
          'members and Roles & permissions.',
          key: const Key('operator_web_security_subtitle'),
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _MfaSection extends StatelessWidget {
  const _MfaSection({
    required this.factors,
    required this.pendingRemovalFor,
    required this.busyFactorIds,
    required this.busyRemovalIds,
    required this.onAdd,
    required this.onRevoke,
    required this.onCancelRemoval,
    required this.onRequestRecovery,
  });

  final List<WebSecurityMfaFactor> factors;
  final WebSecurityMfaRemoval? Function(String factorId) pendingRemovalFor;
  final Set<String> busyFactorIds;
  final Set<String> busyRemovalIds;
  final VoidCallback onAdd;
  final Future<void> Function(WebSecurityMfaFactor factor) onRevoke;
  final Future<void> Function(WebSecurityMfaRemoval removal) onCancelRemoval;
  final VoidCallback onRequestRecovery;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_security_mfa_section'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Two-factor sign-in',
                        style: AppTextStyles.mono14(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('operator_web_security_mfa_add'),
                      onPressed: onAdd,
                      icon: const Icon(
                        Icons.add_moderator_outlined,
                        size: 16,
                        color: AppColors.sunsetDark,
                      ),
                      label: const Text('Add authenticator app'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.sunsetDark,
                        side: const BorderSide(
                          color: AppColors.sunsetDark,
                          width: 1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Two-factor sign-in means a one-time code is required at '
                  'every sign-in, in addition to your password. Removing an '
                  'authenticator takes 24 hours to complete; you can cancel '
                  'anytime during that window.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (factors.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                'No authenticator apps enrolled. Click Add authenticator app '
                'to set one up.',
                key: const Key('operator_web_security_mfa_empty'),
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else
            for (var i = 0; i < factors.length; i++) ...[
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.borderSubtle,
              ),
              _MfaFactorRow(
                factor: factors[i],
                pendingRemoval: pendingRemovalFor(factors[i].factorId),
                busyRevoke: busyFactorIds.contains(factors[i].factorId),
                busyCancelRemoval: () {
                  final pending = pendingRemovalFor(factors[i].factorId);
                  return pending != null &&
                      busyRemovalIds.contains(pending.requestId);
                }(),
                onRevoke: onRevoke,
                onCancelRemoval: onCancelRemoval,
              ),
            ],
          const Divider(height: 1, thickness: 1, color: AppColors.borderSubtle),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('operator_web_security_mfa_recovery_request'),
                onPressed: onRequestRecovery,
                icon: const Icon(
                  Icons.help_outline,
                  size: 16,
                  color: AppColors.sunsetDark,
                ),
                label: const Text('Lost access to your authenticator?'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  textStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaFactorRow extends StatelessWidget {
  const _MfaFactorRow({
    required this.factor,
    required this.pendingRemoval,
    required this.busyRevoke,
    required this.busyCancelRemoval,
    required this.onRevoke,
    required this.onCancelRemoval,
  });

  final WebSecurityMfaFactor factor;
  final WebSecurityMfaRemoval? pendingRemoval;
  final bool busyRevoke;
  final bool busyCancelRemoval;
  final Future<void> Function(WebSecurityMfaFactor factor) onRevoke;
  final Future<void> Function(WebSecurityMfaRemoval removal) onCancelRemoval;

  @override
  Widget build(BuildContext context) {
    final removal = pendingRemoval;
    return Container(
      key: Key('operator_web_security_mfa_factor_row_${factor.factorId}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.borderSubtle.withValues(alpha: 0.4),
              border: Border.all(color: AppColors.borderSubtle),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(
              Icons.shield_outlined,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _factorLabel(factor),
                      style: AppTextStyles.mono12(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    if (removal != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        key: Key(
                          'operator_web_security_mfa_factor_pending_chip_'
                          '${factor.factorId}',
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withValues(alpha: 0.15),
                          border: Border.all(
                            color: AppColors.warning.withValues(alpha: 0.5),
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          'Removal pending',
                          style: AppTextStyles.mono7(color: AppColors.warning),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  removal == null
                      ? 'Added ${_formatDate(factor.enrolledAt)}. '
                            '${_lastUsedLabel(factor)}.'
                      : 'Scheduled removal after '
                            '${_formatDate(removal.executeAfter)}.',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (removal == null)
            _RowButton(
              keyName:
                  'operator_web_security_mfa_factor_revoke_${factor.factorId}',
              label: 'Remove',
              busy: busyRevoke,
              negative: true,
              onPressed: factor.canRevoke ? () => onRevoke(factor) : null,
            )
          else
            _RowButton(
              keyName:
                  'operator_web_security_mfa_factor_cancel_removal_'
                  '${factor.factorId}',
              label: 'Cancel removal',
              busy: busyCancelRemoval,
              negative: false,
              onPressed: () => onCancelRemoval(removal),
            ),
        ],
      ),
    );
  }

  static String _factorLabel(WebSecurityMfaFactor factor) {
    switch (factor.factorType.toLowerCase()) {
      case 'totp':
      case 'authenticator_app':
        return 'Authenticator app';
      case 'sms':
        return 'Text message (SMS)';
    }
    return factor.factorType;
  }

  static String _lastUsedLabel(WebSecurityMfaFactor factor) {
    if (factor.lastUsedAt == null) return 'Not used yet';
    return 'Last used ${_formatDate(factor.lastUsedAt!)}';
  }
}

class _PasswordSection extends StatelessWidget {
  const _PasswordSection({
    required this.showSuccessToast,
    required this.onChangePassword,
  });

  final bool showSuccessToast;
  final VoidCallback onChangePassword;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_security_password_section'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Password',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('operator_web_security_password_change'),
                onPressed: onChangePassword,
                icon: const Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: AppColors.sunsetDark,
                ),
                label: const Text('Change password'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  side: const BorderSide(color: AppColors.sunsetDark, width: 1),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'A strong password is one of the simplest things you can do to '
            'keep your business data safe. We will ask for your current '
            'password to confirm it is you.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (showSuccessToast) ...[
            const SizedBox(height: 10),
            Container(
              key: const Key('operator_web_security_password_toast'),
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
                    'Password updated.',
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

class _LoginHistorySection extends StatelessWidget {
  const _LoginHistorySection({
    required this.entries,
    required this.window,
    required this.onWindowChanged,
  });

  final List<WebSecurityLoginHistoryEntry> entries;
  final SecurityHistoryWindow window;
  final ValueChanged<SecurityHistoryWindow> onWindowChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_security_login_history_section'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  'Sign-ins, password changes, and authenticator events from '
                  'your account, capped at the last 90 days. If you see an '
                  'event you do not recognise, change your password and '
                  'remove the authenticator right away.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final w in SecurityHistoryWindow.values)
                      _WindowChip(
                        keyName:
                            'operator_web_security_login_history_'
                            'filter_${w.filterKey}',
                        label: w.label,
                        selected: w == window,
                        onTap: () => onWindowChanged(w),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                'No sign-in activity in this window.',
                key: const Key('operator_web_security_login_history_empty'),
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else
            for (var i = 0; i < entries.length; i++) ...[
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.borderSubtle,
              ),
              _LoginHistoryRow(entry: entries[i]),
            ],
        ],
      ),
    );
  }
}

class _LoginHistoryRow extends StatelessWidget {
  const _LoginHistoryRow({required this.entry});

  final WebSecurityLoginHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final geo = _geoHint(entry);
    return Container(
      key: Key('operator_web_security_login_history_row_${entry.eventId}'),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.friendlyLabel,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  _metaLine(entry, geo),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _metaLine(WebSecurityLoginHistoryEntry entry, String? geo) {
    final parts = <String>[
      _formatDateTime(entry.occurredAt),
      if (entry.deviceLabel != null && entry.deviceLabel!.isNotEmpty)
        entry.deviceLabel!,
      if (geo != null) geo,
    ];
    return parts.join(' / ');
  }

  static String? _geoHint(WebSecurityLoginHistoryEntry entry) {
    final parts = <String>[];
    if (entry.geoCity != null && entry.geoCity!.isNotEmpty) {
      parts.add(entry.geoCity!);
    }
    if (entry.geoCountry != null && entry.geoCountry!.isNotEmpty) {
      parts.add(entry.geoCountry!);
    }
    return parts.isEmpty ? null : parts.join(', ');
  }
}

class _WindowChip extends StatelessWidget {
  const _WindowChip({
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

class _RowButton extends StatelessWidget {
  const _RowButton({
    required this.keyName,
    required this.label,
    required this.busy,
    required this.negative,
    required this.onPressed,
  });

  final String keyName;
  final String label;
  final bool busy;
  final bool negative;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.sunsetDark,
        ),
      );
    }
    return TextButton(
      key: Key(keyName),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(
        label,
        style: AppTextStyles.mono11(
          color: negative ? AppColors.negative : AppColors.sunsetDark,
        ),
      ),
    );
  }
}

const List<String> _kMonthShort = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _formatDate(DateTime when) {
  final utc = when.toUtc();
  return '${_kMonthShort[utc.month - 1]} ${utc.day}, ${utc.year}';
}

String _formatDateTime(DateTime when) {
  final utc = when.toUtc();
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  return '${_kMonthShort[utc.month - 1]} ${utc.day}, ${utc.year} $hh:$mm UTC';
}
