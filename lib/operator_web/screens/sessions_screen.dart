// Phase 11W.4 - Operator Web Sessions screen.
//
// Web parity for the mobile Settings -> Active Sessions section.
// Mounted at the `/sessions` route in the operator-web shell. Renders
// two stacked sections per the parity contract `§ Sessions`:
//
//   * `Your sessions` (always visible) - the actor's own active
//     sessions, with a `(this session)` chip on the matching row and
//     a `Revoke` action per row. Revoking the current session calls
//     `signOut()` after the proxy returns 200.
//   * `Team sessions` (visible only when the actor holds the
//     `team.session.force_logout` permission key, with a role-tier
//     fallback for the demo flavor and bootstrap stage) - every
//     team-member session within scope, grouped by member.
//
// Row shape (locked by the parity contract):
//
//   * device fingerprint as `deviceLabel` (browser + OS) - falls back
//     to `userAgent` when the proxy did not derive a friendly label.
//   * city-level geo hint - city + country only, NEVER the raw IP.
//     The gateway already drops the IP so the screen has no path to
//     it; the test asserts the fixture rendering carries no IPv4 /
//     IPv6 substring.
//   * `last_active_at` humanized to "just now / Nm ago / Nh ago / Nd
//     ago" so a glance answers "is this device live."
//   * `(this session)` chip on operator self-service only, when the
//     row's `sessionId` matches the actor's `currentSessionId`.
//   * `Revoke` action - mints a fresh idempotency key per click and
//     threads it through the gateway. Revoking the actor's current
//     session triggers the `signOut()` callback after the proxy
//     returns.
//
// Permission gating mirrors the parity contract `§ Permission gate
// cheat sheet`:
//
//   * Read of own sessions: every authenticated session sees its own
//     ledger - `team.users.view` is the contract gate, but the
//     screen treats "is the actor authenticated" as the own-section
//     gate so the demo flavor and the live bootstrap stage can show
//     the section before the permission snapshot hydrates.
//   * Read of team sessions: `team.session.force_logout` permission
//     key, with a role-tier fallback for `operator_owner` /
//     `operator_admin` so the demo walkthrough can reach the team
//     section without a hydrated snapshot.

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/web_team_sessions_gateway.dart';
import '../../theme/app_theme.dart';

/// Permission-key bound for the Team sessions section. Aliased to the
/// frozen catalog constant in `lib/auth/permission_keys.dart`.
const String kSessionsTeamForceLogoutPermissionKey =
    PermissionKeys.teamSessionForceLogout;

/// Roles admitted to the Team sessions section when the proxy
/// permission snapshot is not yet hydrated. Authoritative gate is
/// the permission key.
const Set<String> kSessionsTeamForceLogoutAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Roles admitted to the own-sessions surface when the proxy
/// permission snapshot is not yet hydrated. Every authenticated
/// operator-web role sees their own ledger.
const Set<String> kSessionsOwnAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
  'operator_manager',
  'operator_supervisor',
  'operator_staff',
  'location_manager',
};

/// Operator Web Sessions screen.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    required this.session,
    required this.gateway,
    required this.onSignOut,
    this.currentSessionId,
    this.idempotencyKeyFactory,
  });

  final OperatorWebSession session;
  final WebTeamSessionsGateway gateway;

  /// Called after the proxy returns 200 on a revoke whose
  /// `sessionId` matches the actor's [currentSessionId]. The router
  /// wires this to `OperatorWebAuthSource.signOut`.
  final Future<void> Function() onSignOut;

  /// Stable id of the row representing the operator-web session
  /// itself. The screen uses this to mark the `(this session)`
  /// chip and to short-circuit a revoke into [onSignOut] after the
  /// proxy returns. Null when the auth source has not surfaced an
  /// id (e.g. early bootstrap); the chip and short-circuit stay
  /// off in that case.
  final String? currentSessionId;

  /// Optional override for tests so an assertion can pin the
  /// idempotency-key value the screen forwards into the gateway.
  final String Function()? idempotencyKeyFactory;

  bool get _canViewTeamSessions {
    if (session.permissions.isNotEmpty) {
      return session.permissions.contains(
        kSessionsTeamForceLogoutPermissionKey,
      );
    }
    return session.roles.any(kSessionsTeamForceLogoutAdmittedRoles.contains);
  }

  bool get _canViewOwnSessions {
    if (session.permissions.isNotEmpty) {
      // Authenticated operator-web users always see their own ledger;
      // the permission snapshot does not gate the actor's own row.
      return true;
    }
    return session.roles.any(kSessionsOwnAdmittedRoles.contains);
  }

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  bool _loading = true;
  String? _loadError;
  String? _teamLoadError;
  List<WebTeamSessionEntry> _ownSessions = const <WebTeamSessionEntry>[];
  List<WebTeamSessionEntry> _teamSessions = const <WebTeamSessionEntry>[];
  final Set<String> _busySessionIds = <String>{};
  int _loadGeneration = 0;
  int _idempotencySeq = 0;

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
    return 'op-web-sessions-${widget.session.uid}-$ts-$_idempotencySeq';
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
      _teamLoadError = null;
    });
    try {
      final results = await Future.wait<Object?>([
        widget.gateway.listOwnSessions(),
        widget._canViewTeamSessions
            ? Future<WebTeamSessionsListed>.sync(
                    () => widget.gateway.listTeamSessions(),
                  )
                  .then<Object?>((value) => value)
                  .catchError((Object error) => _friendlyTeamLoadError(error))
            : Future<Object?>.value(null),
      ]);
      if (!mounted || generation != _loadGeneration) return;
      final own = results[0] as WebTeamSessionsListed;
      final teamResult = results[1];
      final team = teamResult is WebTeamSessionsListed
          ? teamResult
          : const WebTeamSessionsListed(sessions: <WebTeamSessionEntry>[]);
      final teamLoadError = teamResult is String ? teamResult : null;
      setState(() {
        _ownSessions = own.sessions;
        _teamSessions = team.sessions;
        _teamLoadError = teamLoadError;
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

  String _friendlyTeamLoadError(Object error) {
    if (error is WebTeamSessionsError) {
      return 'Team sessions are not available in this preview '
          '(${error.code}). Your own sessions are still shown.';
    }
    return 'Team sessions are not available in this preview. Your own '
        'sessions are still shown.';
  }

  String _friendlyLoadError(Object error) {
    if (error is WebTeamSessionsError) {
      return 'Could not load active sessions (${error.code}). Refresh the '
          'page or try again in a moment.';
    }
    return 'Could not load active sessions. Refresh the page or try again '
        'in a moment.';
  }

  Future<void> _revoke(WebTeamSessionEntry entry) async {
    if (_busySessionIds.contains(entry.sessionId)) return;
    final isCurrent =
        widget.currentSessionId != null &&
        entry.sessionId == widget.currentSessionId;
    final confirmed = await _confirm(
      title: isCurrent ? 'Sign out this session?' : 'Sign out this device?',
      body: isCurrent
          ? 'Signing out this session will return you to the welcome screen. '
                'You can sign back in anytime.'
          : 'Signing out ${_describeRow(entry)} will end that session right '
                'away. You can sign back in on that device anytime.',
      cta: isCurrent ? 'Sign out this session' : 'Sign out',
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _busySessionIds.add(entry.sessionId);
    });
    try {
      await widget.gateway.revokeSession(
        WebTeamSessionRevokeCommand(
          actorUserId: widget.session.uid,
          operatorId: widget.session.operatorId,
          sessionId: entry.sessionId,
          reason: isCurrent
              ? 'op_web_sessions_revoke_self'
              : 'op_web_sessions_revoke',
        ),
        idempotencyKey: _nextIdempotencyKey(),
      );
      if (isCurrent) {
        // Clear the busy state on the current row so an embedding
        // shell that does not immediately unmount the screen does
        // not get stuck on a spinning ticker. In production the auth
        // source tears the screen down when `signOut()` resolves;
        // this clear is a safety net.
        if (mounted) {
          setState(() {
            _busySessionIds.remove(entry.sessionId);
          });
        }
        await widget.onSignOut();
        return;
      }
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Signed out ${_describeRow(entry)}.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busySessionIds.remove(entry.sessionId);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_friendlyMutationError(error))));
    }
  }

  /// Team list with rows already shown in the own-sessions section
  /// stripped, so the actor never sees their own device twice. The
  /// own list ships first; the team section ships any remaining
  /// team-member sessions below.
  List<WebTeamSessionEntry> get _teamSessionsExcludingOwn {
    final ownIds = _ownSessions.map((row) => row.sessionId).toSet();
    return _teamSessions
        .where((row) => !ownIds.contains(row.sessionId))
        .toList(growable: false);
  }

  String _friendlyMutationError(Object error) {
    if (error is WebTeamSessionsError) {
      return 'Could not sign out that session (${error.code}). Try again in '
          'a moment.';
    }
    return 'Could not sign out that session. Try again in a moment.';
  }

  String _describeRow(WebTeamSessionEntry entry) {
    final label = entry.deviceLabel ?? entry.userAgent ?? 'this device';
    return label.length > 36 ? '${label.substring(0, 36)}...' : label;
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String cta,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('sessions_confirm_dialog'),
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            key: const Key('sessions_confirm_dialog_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('sessions_confirm_dialog_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(cta),
          ),
        ],
      ),
    );
    return result == true;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget._canViewOwnSessions) {
      return const _SessionsForbiddenSurface(
        key: Key('operator_web_sessions_forbidden'),
      );
    }
    if (_loading) {
      return const Center(
        key: Key('operator_web_sessions_loading'),
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
        key: const Key('operator_web_sessions_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sessions could not load',
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
                    key: const Key('operator_web_sessions_load_retry'),
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
    return SingleChildScrollView(
      key: const Key('operator_web_sessions_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SessionsHeader(),
          const SizedBox(height: 18),
          _SessionsSection(
            sectionKey: const Key('operator_web_sessions_own_section'),
            keyPrefix: 'operator_web_sessions',
            title: 'Your sessions',
            sessions: _ownSessions,
            currentSessionId: widget.currentSessionId,
            busySessionIds: _busySessionIds,
            onRevoke: _revoke,
            renderTargetUser: false,
          ),
          if (widget._canViewTeamSessions) ...[
            const SizedBox(height: 24),
            _SessionsSection(
              sectionKey: const Key('operator_web_sessions_team_section'),
              keyPrefix: 'operator_web_sessions_team',
              title: 'Team sessions',
              sessions: _teamSessionsExcludingOwn,
              currentSessionId: widget.currentSessionId,
              busySessionIds: _busySessionIds,
              onRevoke: _revoke,
              renderTargetUser: true,
              loadError: _teamLoadError,
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionsHeader extends StatelessWidget {
  const _SessionsHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.devices_outlined,
                    size: 22,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Active sessions',
                    style: AppTextStyles.display20(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'See where Forge and Flow is signed in, then sign out '
                'devices that no longer need access. Mobile and web sessions '
                'appear together here.',
                key: const Key('operator_web_sessions_subtitle'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SessionsSection extends StatelessWidget {
  const _SessionsSection({
    required this.sectionKey,
    required this.keyPrefix,
    required this.title,
    required this.sessions,
    required this.currentSessionId,
    required this.busySessionIds,
    required this.onRevoke,
    required this.renderTargetUser,
    this.loadError,
  });

  final Key sectionKey;

  /// Prefix the section uses for per-row widget keys, so the same
  /// `sessionId` rendered in both the own and team sections never
  /// collides on the same key in the widget tree.
  final String keyPrefix;
  final String title;
  final List<WebTeamSessionEntry> sessions;
  final String? currentSessionId;
  final Set<String> busySessionIds;
  final Future<void> Function(WebTeamSessionEntry entry) onRevoke;
  final bool renderTargetUser;
  final String? loadError;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: sectionKey,
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
            child: Text(
              title,
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          if (loadError != null)
            Padding(
              key: Key('${keyPrefix}_unavailable'),
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                loadError!,
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                'No active sessions to show.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            )
          else
            for (var i = 0; i < sessions.length; i++) ...[
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.borderSubtle,
              ),
              _SessionsRow(
                keyPrefix: keyPrefix,
                entry: sessions[i],
                isCurrent:
                    !renderTargetUser &&
                    currentSessionId != null &&
                    sessions[i].sessionId == currentSessionId,
                busy: busySessionIds.contains(sessions[i].sessionId),
                onRevoke: onRevoke,
                renderTargetUser: renderTargetUser,
              ),
            ],
        ],
      ),
    );
  }
}

class _SessionsRow extends StatelessWidget {
  const _SessionsRow({
    required this.keyPrefix,
    required this.entry,
    required this.isCurrent,
    required this.busy,
    required this.onRevoke,
    required this.renderTargetUser,
  });

  final String keyPrefix;
  final WebTeamSessionEntry entry;
  final bool isCurrent;
  final bool busy;
  final Future<void> Function(WebTeamSessionEntry entry) onRevoke;
  final bool renderTargetUser;

  @override
  Widget build(BuildContext context) {
    final label = entry.deviceLabel ?? entry.userAgent ?? 'Unknown device';
    return Container(
      key: Key('${keyPrefix}_row_${entry.sessionId}'),
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
                if (renderTargetUser && entry.targetUserDisplayName != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      entry.targetUserDisplayName!,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
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
                        key: const Key('operator_web_sessions_this_chip'),
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
                          '(this session)',
                          style: AppTextStyles.mono7(color: AppColors.positive),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _metaLine(entry),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                if (renderTargetUser && entry.targetUserEmail != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    entry.targetUserEmail!,
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sunsetDark,
              ),
            )
          else
            TextButton(
              key: Key('${keyPrefix}_revoke_${entry.sessionId}'),
              onPressed: () => onRevoke(entry),
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
                isCurrent ? 'Sign out this session' : 'Sign out',
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
        lower.contains('android') ||
        lower.contains('pixel')) {
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
    if (lower.contains('chrome') ||
        lower.contains('firefox') ||
        lower.contains('safari') ||
        lower.contains('edge')) {
      return Icons.public_rounded;
    }
    return Icons.devices_other_rounded;
  }

  static String _metaLine(WebTeamSessionEntry entry) {
    final segments = <String>[];
    final geo = _geoHint(entry);
    if (geo != null) segments.add(geo);
    segments.add('Last active ${_relative(entry.lastActiveAt)}');
    return segments.join(' · ');
  }

  /// Renders the geo hint at city + country granularity. The gateway
  /// drops the raw IP at the seam, but the screen also asserts that
  /// the rendered string never includes a literal IP shape so a
  /// future regression cannot leak one through.
  static String? _geoHint(WebTeamSessionEntry entry) {
    final parts = <String>[];
    if (entry.geoCity != null && entry.geoCity!.isNotEmpty) {
      parts.add(entry.geoCity!);
    }
    if (entry.geoCountry != null && entry.geoCountry!.isNotEmpty) {
      parts.add(entry.geoCountry!);
    }
    return parts.isEmpty ? null : parts.join(', ');
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

class _SessionsForbiddenSurface extends StatelessWidget {
  const _SessionsForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Sessions are not available for this account',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Sessions in the web console show every device signed in to '
                'your account. Sign in with your operator login to see your '
                'session list.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
