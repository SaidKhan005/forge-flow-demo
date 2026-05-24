// Admin audit-integrity badge — "log is intact" chain-integrity badge
// for the admin Audit screen.
//
// Admin-side analogue of the operator-web `AuditLogIntegrityBadge`
// (`lib/operator_web/screens/audit_log_screen.dart`), scoped to the
// operator the F&F admin has selected. The daily 02:00 UTC sweep
// stamps an anchor row in `public.audit_chain_anchors`; this badge
// surfaces the most recent stamp's freshness so an admin can see, for
// the selected operator, whether that operator's audit log integrity
// is intact.
//
// Pure presentational widget: depends only on Flutter, the shared
// admin theme, and the [AdminAuditChainAnchorSnapshot] model. The
// server classifies the status (healthy / delayed / failed / unknown);
// this widget only renders it, so it can never drift from the proxy.
//
// States:
//   * Healthy - "Anchored at 02:00 UTC. Last anchor N hours ago."
//   * Delayed - "Anchor delayed. Last anchor was N hours ago."
//   * Failed  - "Anchor failed. F and F support is investigating."
//   * Unknown - "No anchor recorded yet." (when no gateway is wired,
//               the read failed, or no anchor row exists yet for the
//               selected operator)

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../services/admin_audit_chain_anchors_gateway.dart';

class AdminAuditLogIntegrityBadge extends StatelessWidget {
  const AdminAuditLogIntegrityBadge({
    super.key,
    required this.snapshot,
    required this.isLoading,
    required this.transientError,
    this.now,
  });

  /// The most-recent anchor snapshot for the selected operator. Null
  /// renders the neutral "unknown" state (no gateway wired yet, e.g.
  /// demo / share-preview without a live anchor gateway), exactly like
  /// the operator-web null-gateway fallback.
  final AdminAuditChainAnchorSnapshot? snapshot;

  /// True while the first read is in flight.
  final bool isLoading;

  /// True when the read failed (a transient proxy outage). Renders a
  /// neutral "unavailable" state, never "failed", so a blip does not
  /// alarm the admin.
  final bool transientError;

  /// Reference "now" for the age label. Tests pin this; production
  /// leaves it null and falls back to `DateTime.now()`.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final state = _resolveState();
    return Container(
      key: const Key('admin_audit_log_integrity_badge'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: state.background,
        border: Border.all(color: state.border, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(state.icon, size: 18, color: state.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  state.title,
                  key: Key(
                    'admin_audit_log_integrity_badge_${state.wireKey}_title',
                  ),
                  style: AppTextStyles.mono12(
                    color: state.foreground,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  state.body,
                  key: Key(
                    'admin_audit_log_integrity_badge_${state.wireKey}_body',
                  ),
                  style: AppTextStyles.body12(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _AdminBadgeStyle _resolveState() {
    if (isLoading) {
      return const _AdminBadgeStyle(
        wireKey: 'loading',
        title: 'Checking audit chain integrity',
        body: 'Loading the most recent anchor for the selected operator.',
        foreground: AppColors.sunsetDark,
        background: AppColors.backgroundSurface,
        border: AppColors.borderSubtle,
        icon: Icons.hourglass_top_outlined,
      );
    }
    final resolved = snapshot;
    if (resolved == null) {
      return const _AdminBadgeStyle(
        wireKey: 'unknown',
        title: 'Audit chain status unknown',
        body:
            'No anchor recorded yet. Daily anchoring runs at 02:00 UTC and '
            'this badge updates as soon as the first sweep lands.',
        foreground: AppColors.textSecondary,
        background: AppColors.backgroundSurface,
        border: AppColors.borderSubtle,
        icon: Icons.help_outline,
      );
    }
    final reference = (now ?? DateTime.now()).toUtc();
    final anchored = resolved.lastAnchorBlobAt ?? resolved.anchoredAt;
    final ageLabel = anchored == null
        ? null
        : _humanizeAge(reference.difference(anchored));
    switch (resolved.status) {
      case AdminAuditChainAnchorStatus.healthy:
        return _AdminBadgeStyle(
          wireKey: 'healthy',
          title: 'Audit chain healthy',
          body: ageLabel == null
              ? 'Anchored at 02:00 UTC daily.'
              : 'Anchored at 02:00 UTC. Last anchor $ageLabel ago.',
          foreground: const Color(0xFF1F7A4D),
          background: const Color(0xFFEBF7F0),
          border: const Color(0xFF1F7A4D),
          icon: Icons.verified_outlined,
        );
      case AdminAuditChainAnchorStatus.delayed:
        return _AdminBadgeStyle(
          wireKey: 'delayed',
          title: 'Audit chain delayed',
          body: ageLabel == null
              ? 'Anchor delayed past the daily 02:00 UTC cadence. F and F '
                    'support is monitoring this.'
              : 'Anchor delayed. Last anchor was $ageLabel ago. F and F '
                    'support is monitoring this.',
          foreground: const Color(0xFF8A5A00),
          background: const Color(0xFFFFF4DA),
          border: const Color(0xFFB58300),
          icon: Icons.schedule_outlined,
        );
      case AdminAuditChainAnchorStatus.failed:
        return const _AdminBadgeStyle(
          wireKey: 'failed',
          title: 'Audit chain anchor failed',
          body:
              'Anchor failed. F and F support is investigating. This '
              "operator's audit log entries are still being recorded; the "
              'daily evidence anchor is what is delayed.',
          foreground: Color(0xFFA8341B),
          background: Color(0xFFFCEEEA),
          border: Color(0xFFA8341B),
          icon: Icons.error_outline,
        );
      case AdminAuditChainAnchorStatus.unknown:
        final transient = transientError;
        return _AdminBadgeStyle(
          wireKey: 'unknown',
          title: transient
              ? 'Audit chain status unavailable'
              : 'Audit chain status unknown',
          body: transient
              ? 'Audit chain status could not load. Reload the screen to try '
                    'again. Daily anchoring runs at 02:00 UTC.'
              : 'No anchor recorded yet. Daily anchoring runs at 02:00 UTC '
                    'and this badge updates as soon as the first sweep lands.',
          foreground: AppColors.textSecondary,
          background: AppColors.backgroundSurface,
          border: AppColors.borderSubtle,
          icon: Icons.help_outline,
        );
    }
  }

  static String _humanizeAge(Duration age) {
    final seconds = age.inSeconds;
    if (seconds < 60) {
      return seconds <= 1 ? '1 second' : '$seconds seconds';
    }
    final minutes = age.inMinutes;
    if (minutes < 60) {
      return minutes == 1 ? '1 minute' : '$minutes minutes';
    }
    final hours = age.inHours;
    if (hours < 48) {
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    final days = age.inDays;
    return days == 1 ? '1 day' : '$days days';
  }
}

class _AdminBadgeStyle {
  const _AdminBadgeStyle({
    required this.wireKey,
    required this.title,
    required this.body,
    required this.foreground,
    required this.background,
    required this.border,
    required this.icon,
  });

  final String wireKey;
  final String title;
  final String body;
  final Color foreground;
  final Color background;
  final Color border;
  final IconData icon;
}
