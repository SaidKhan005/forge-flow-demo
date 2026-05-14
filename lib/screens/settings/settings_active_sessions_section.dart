// Phase 9.UX.5 — Settings → Account → Active Sessions section.
//
// Self-service viewer over `AuthOperationsGateway.listActiveSessions`.
// Operators can review their own auth_sessions ledger, revoke a single
// device, or sign out everywhere. The current session marker is set
// client-side from `AuthSessionNotifier.activeSessionId`; revokes and
// sign-out-all run through the proxy seam so RLS / refresh-token
// revocation stays consistent.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

/// Snapshot the section needs about the signed-in actor so it can
/// scope `listActiveSessions` and tag the local row as "this device".
class ActiveSessionsActor {
  const ActiveSessionsActor({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.currentSessionId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;

  /// `auth_sessions.session_id` for the row this Flutter client owns,
  /// so the UI can tag it and disable the revoke action against it.
  /// Null in tests / cold-start before the ledger write resolves.
  final String? currentSessionId;

  @override
  bool operator ==(Object other) {
    return other is ActiveSessionsActor &&
        other.actorUserId == actorUserId &&
        other.operatorId == operatorId &&
        other.locationId == locationId &&
        other.currentSessionId == currentSessionId;
  }

  @override
  int get hashCode =>
      Object.hash(actorUserId, operatorId, locationId, currentSessionId);
}

/// Stable demo fixtures (kDemoMode) so the walkthrough can show
/// multiple devices without staging. Three rows: this device + two
/// other devices the operator has presumably signed in on.
class DemoAuthSessionsFixtures {
  const DemoAuthSessionsFixtures._();

  static const String currentSessionId = 'demo-session-current';
  static const String tabletSessionId = 'demo-session-tablet';
  static const String backOfHouseSessionId = 'demo-session-boh';

  static List<AuthSessionSummary> seed() {
    final now = DateTime.utc(2026, 4, 30, 14, 22);
    return <AuthSessionSummary>[
      AuthSessionSummary(
        sessionId: currentSessionId,
        deviceLabel: 'Forge & Flow app - iOS',
        userAgent: 'Forge&Flow/1.0 (iPhone; iOS 18.1)',
        ip: '203.0.113.42',
        geoCountry: 'CA',
        createdAt: now.subtract(const Duration(hours: 2)),
        lastSeenAt: now.subtract(const Duration(minutes: 1)),
      ),
      AuthSessionSummary(
        sessionId: tabletSessionId,
        deviceLabel: 'Safari - iPad',
        userAgent: 'Mozilla/5.0 (iPad; CPU OS 18_1) Safari/605.1.15',
        ip: '203.0.113.7',
        geoCountry: 'CA',
        createdAt: now.subtract(const Duration(days: 1, hours: 4)),
        lastSeenAt: now.subtract(const Duration(hours: 5)),
      ),
      AuthSessionSummary(
        sessionId: backOfHouseSessionId,
        deviceLabel: 'Chrome - Windows',
        userAgent: 'Mozilla/5.0 (Windows NT 10.0) Chrome/124.0',
        ip: '198.51.100.18',
        geoCountry: 'CA',
        createdAt: now.subtract(const Duration(days: 6, hours: 2)),
        lastSeenAt: now.subtract(const Duration(days: 2, hours: 3)),
      ),
    ];
  }
}

/// In-memory `AuthOperationsGateway` for kDemoMode. Only implements
/// the three Active Sessions methods; other Team/Org calls throw so
/// callers don't accidentally route demo mutations through it.
class DemoActiveSessionsGateway extends ScaffoldFailingAuthOperationsGateway {
  DemoActiveSessionsGateway({List<AuthSessionSummary>? seed})
    : _sessions = List<AuthSessionSummary>.of(
        seed ?? DemoAuthSessionsFixtures.seed(),
      );

  final List<AuthSessionSummary> _sessions;

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(_sessions),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    final removed = _sessions.length;
    _sessions.removeWhere((s) => s.sessionId == command.sessionId);
    return AuthSessionRevoked(revoked: _sessions.length < removed);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    final count = _sessions.length;
    _sessions.clear();
    return AuthAllSessionsRevoked(revokedCount: count);
  }
}

class SettingsActiveSessionsSection extends StatefulWidget {
  const SettingsActiveSessionsSection({
    super.key,
    this.gateway,
    this.actor,
    this.allowDemoGatewayFallback = false,
    this.refreshGeneration = 0,
    this.onSignOutAllDevices,
    this.viewOnly = false,
  });

  final AuthOperationsGateway? gateway;
  final ActiveSessionsActor? actor;

  /// In demo / preview shells where no proxy is wired, opting in to
  /// the demo fixture lets the walkthrough click path complete.
  final bool allowDemoGatewayFallback;
  final int refreshGeneration;

  /// W3.A — when true, the mobile mirror hides every revoke / sign-out
  /// affordance. Operators still see their session list with last-
  /// active timestamps; mutations move to the Operator Web console.
  final bool viewOnly;

  /// Callback the Account-tab shell wires to
  /// `AuthSessionNotifier.signOutAllSessions()` so the notifier state
  /// transitions to unauthenticated and refresh-token revocation
  /// follows. The section calls this *after* the gateway sign-out-all
  /// returns so any refresh-token / Firebase revocation kicks the
  /// local device too.
  final Future<void> Function()? onSignOutAllDevices;

  @override
  State<SettingsActiveSessionsSection> createState() =>
      _SettingsActiveSessionsSectionState();
}

class _SettingsActiveSessionsSectionState
    extends State<SettingsActiveSessionsSection> {
  AuthOperationsGateway? _gateway;
  ActiveSessionsActor? _actor;

  bool _loading = true;
  bool _signingOutAll = false;
  String? _errorMessage;
  List<AuthSessionSummary> _sessions = const <AuthSessionSummary>[];
  final Set<String> _revokingSessionIds = <String>{};

  @override
  void initState() {
    super.initState();
    _bindActorAndGateway();
    _refresh();
  }

  @override
  void didUpdateWidget(SettingsActiveSessionsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.actor != widget.actor) {
      _bindActorAndGateway();
      _refresh();
    } else if (oldWidget.refreshGeneration != widget.refreshGeneration) {
      _refresh();
    }
  }

  void _bindActorAndGateway() {
    AuthOperationsGateway? gateway = widget.gateway;
    if (gateway == null && widget.allowDemoGatewayFallback) {
      gateway = DemoActiveSessionsGateway();
    }
    _gateway = gateway;
    _actor = widget.actor ?? _actorFromContext();
  }

  ActiveSessionsActor? _actorFromContext() {
    AuthSessionNotifier? notifier;
    try {
      notifier = context.read<AuthSessionNotifier>();
    } catch (_) {
      return null;
    }
    final session = notifier.session;
    if (session == null) return null;
    return ActiveSessionsActor(
      actorUserId: session.userId,
      operatorId: session.operatorId,
      locationId: session.locationId,
      currentSessionId: notifier.activeSessionId,
    );
  }

  Future<void> _refresh() async {
    final gateway = _gateway;
    final actor = _actor;
    if (gateway == null || actor == null) {
      setState(() {
        _loading = false;
        _sessions = const <AuthSessionSummary>[];
        _errorMessage = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final result = await gateway.listActiveSessions(
        AuthActiveSessionsListCommand(
          actorUserId: actor.actorUserId,
          operatorId: actor.operatorId,
          locationId: actor.locationId,
        ),
      );
      if (!mounted) return;
      setState(() {
        _sessions = result.sessions;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = _activeSessionsLoadMessage(error);
      });
    }
  }

  Future<void> _revoke(AuthSessionSummary summary) async {
    final gateway = _gateway;
    final actor = _actor;
    if (gateway == null || actor == null) return;
    if (_revokingSessionIds.contains(summary.sessionId)) return;
    setState(() {
      _revokingSessionIds.add(summary.sessionId);
      _errorMessage = null;
    });
    try {
      await gateway.revokeSession(
        AuthSessionRevokeCommand(
          actorUserId: actor.actorUserId,
          operatorId: actor.operatorId,
          locationId: actor.locationId,
          sessionId: summary.sessionId,
          reason: 'user_revoked_active_session',
        ),
      );
      if (!mounted) return;
      setState(() {
        _sessions = _sessions
            .where((s) => s.sessionId != summary.sessionId)
            .toList(growable: false);
        _revokingSessionIds.remove(summary.sessionId);
      });
      _showSnackBar('Sign-out request sent to ${_describeRow(summary)}.');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _revokingSessionIds.remove(summary.sessionId);
        _errorMessage = 'Could not revoke that session. Please try again.';
      });
    }
  }

  Future<void> _signOutAllDevices() async {
    final gateway = _gateway;
    final actor = _actor;
    if (gateway == null || actor == null) return;
    if (_signingOutAll) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundMid,
        title: Text(
          'Sign out everywhere?',
          style: AppTextStyles.mono14(color: AppColors.textPrimary),
        ),
        content: Text(
          'This signs you out of every device. You will be returned to the '
          'sign-in screen.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              'Cancel',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'Sign out everywhere',
              style: AppTextStyles.mono11(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _signingOutAll = true;
      _errorMessage = null;
    });
    try {
      await gateway.signOutAll(
        AuthAllSessionsRevokeCommand(
          actorUserId: actor.actorUserId,
          operatorId: actor.operatorId,
          locationId: actor.locationId,
          reason: 'user_signed_out_all_sessions',
        ),
      );
      // Hand control back to the AuthSessionNotifier so the local
      // device is signed out too and refresh-token revocation runs.
      // Do this BEFORE the synchronous setState below so the route
      // does not rebuild against stale state after the notifier
      // tears down the auth shell.
      final callback = widget.onSignOutAllDevices;
      if (callback != null) {
        unawaited(callback());
      }
      if (!mounted) return;
      setState(() {
        _sessions = const <AuthSessionSummary>[];
        _signingOutAll = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _signingOutAll = false;
        _errorMessage = 'Could not sign out of all devices. Please try again.';
      });
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: AppTextStyles.mono11(color: AppColors.textPrimary),
        ),
        backgroundColor: AppColors.backgroundMid,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final actor = _actor;
    if (actor == null) {
      return _emptyCard(
        message:
            "Active sessions become available once you're signed in to your account.",
      );
    }
    if (_loading) return const _ActiveSessionsLoadingCard();
    if (_errorMessage != null && _sessions.isEmpty) {
      return _ActiveSessionsErrorCard(
        message: _errorMessage!,
        onRetry: _refresh,
      );
    }
    if (_sessions.isEmpty) {
      return _emptyCard(
        message:
            'No active sessions are recorded yet. Signing in on this device will appear here.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          children: [
            const _ActiveSessionsHeader(),
            const SettingsRowDivider(),
            for (var i = 0; i < _sessions.length; i++) ...[
              _ActiveSessionRow(
                summary: _sessions[i],
                isCurrent:
                    actor.currentSessionId != null &&
                    _sessions[i].sessionId == actor.currentSessionId,
                isRevoking: _revokingSessionIds.contains(
                  _sessions[i].sessionId,
                ),
                onRevoke: widget.viewOnly ? null : () => _revoke(_sessions[i]),
                viewOnly: widget.viewOnly,
              ),
              if (i != _sessions.length - 1) const SettingsRowDivider(),
            ],
            if (_errorMessage != null) ...[
              const SettingsRowDivider(),
              _ActiveSessionsInlineError(message: _errorMessage!),
            ],
          ],
        ),
        if (!widget.viewOnly) ...[
          const SizedBox(height: 10),
          SettingsCard(
            children: [
              SettingsActionRow(
                key: const Key('active_sessions_sign_out_everywhere'),
                icon: Icons.phonelink_lock_rounded,
                label: _signingOutAll
                    ? 'Signing out of all devices'
                    : 'Sign out of all devices',
                description:
                    'Signs out every active session for your account. You will need '
                    'to sign in again on every device.',
                tone: SettingsRowTone.danger,
                onTap: _signingOutAll ? () {} : _signOutAllDevices,
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _emptyCard({required String message}) {
    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.devices_other_rounded,
                size: 20,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _describeRow(AuthSessionSummary summary) {
    final label = summary.deviceLabel ?? summary.userAgent ?? 'this device';
    return label.length > 36 ? '${label.substring(0, 36)}...' : label;
  }
}

/// U-7 MO-7d (debug.md:300) — the parent settings tab now renders the
/// sticky "Active sessions" title, so the section's own header drops the
/// duplicate text and keeps only the device icon plus the one-line
/// description ("Devices currently signed in to your account.").
class _ActiveSessionsHeader extends StatelessWidget {
  const _ActiveSessionsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.12),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.4),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(
              Icons.devices_rounded,
              size: 19,
              color: AppColors.sunsetDark,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Devices currently signed in to your account.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActiveSessionRow extends StatelessWidget {
  const _ActiveSessionRow({
    required this.summary,
    required this.isCurrent,
    required this.isRevoking,
    required this.onRevoke,
    this.viewOnly = false,
  });

  final AuthSessionSummary summary;
  final bool isCurrent;
  final bool isRevoking;
  final VoidCallback? onRevoke;
  final bool viewOnly;

  @override
  Widget build(BuildContext context) {
    final label =
        summary.deviceLabel ?? summary.userAgent ?? 'Unrecognised device';
    return Padding(
      key: Key('active_sessions_row_${summary.sessionId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.borderSubtle.withValues(alpha: 0.4),
              border: Border.all(color: AppColors.borderSubtle),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              _iconForLabel(label),
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
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 8),
                      Container(
                        key: const Key('active_sessions_current_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.positive.withValues(alpha: 0.15),
                          border: Border.all(
                            color: AppColors.positive.withValues(alpha: 0.5),
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          'This device',
                          style: AppTextStyles.mono7(color: AppColors.positive),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _metaLine(summary),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                if (summary.userAgent != null &&
                    summary.userAgent != summary.deviceLabel) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary.userAgent!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isCurrent)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Current',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            )
          else if (viewOnly || onRevoke == null)
            const SizedBox.shrink()
          else if (isRevoking)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              key: Key('active_sessions_revoke_${summary.sessionId}'),
              onPressed: onRevoke,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                'Sign out',
                style: AppTextStyles.mono11(color: AppColors.negative),
              ),
            ),
        ],
      ),
    );
  }

  static IconData _iconForLabel(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('iphone') ||
        lower.contains('ios') ||
        lower.contains('android')) {
      return Icons.smartphone_rounded;
    }
    if (lower.contains('ipad') || lower.contains('tablet')) {
      return Icons.tablet_mac_rounded;
    }
    if (lower.contains('mac') || lower.contains('apple')) {
      return Icons.laptop_mac_rounded;
    }
    if (lower.contains('windows') || lower.contains('linux')) {
      return Icons.desktop_windows_rounded;
    }
    return Icons.devices_other_rounded;
  }

  // U-7 MO-7e (debug.md:301) — mobile rows show "when and what device"
  // only. IP + geo are intentionally dropped from the meta line; the
  // device label/icon already identify "what" and `lastSeenAt` covers
  // "when". `_approximateLocation` was removed alongside the IP segment.
  static String _metaLine(AuthSessionSummary summary) {
    return 'Last active ${_relative(summary.lastSeenAt)}';
  }

  static String _relative(DateTime when) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(when.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final weeks = (diff.inDays / 7).floor();
    if (weeks < 5) return '${weeks}w ago';
    final months = (diff.inDays / 30).floor();
    return '${months}mo ago';
  }
}

String _activeSessionsLoadMessage(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('status: 401') || text.contains('status: 403')) {
    return 'You do not have access to view active sessions.';
  }
  if (text.contains('status: 404') || text.contains('not found')) {
    return 'Active sessions are unavailable in this build.';
  }
  if (text.contains('transport_error') || text.contains('status: null')) {
    return 'Could not reach the proxy. Check connection and retry.';
  }
  return "We couldn't load your active sessions. Please try again.";
}

class _ActiveSessionsLoadingCard extends StatelessWidget {
  const _ActiveSessionsLoadingCard();

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        Padding(
          key: const Key('active_sessions_loading'),
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Loading active sessions',
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActiveSessionsErrorCard extends StatelessWidget {
  const _ActiveSessionsErrorCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        Padding(
          key: const Key('active_sessions_error'),
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active sessions',
                      style: AppTextStyles.mono12(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      message,
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      key: const Key('active_sessions_retry'),
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ActiveSessionsInlineError extends StatelessWidget {
  const _ActiveSessionsInlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('active_sessions_inline_error'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.negative,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
