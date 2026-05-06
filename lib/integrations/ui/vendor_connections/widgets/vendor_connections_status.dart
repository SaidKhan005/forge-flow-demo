// Phase 8.0 / Wave C1 — Status chrome (chip, badge, error remediation,
// banner, category icon) for the shared Vendor Connections widget
// tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.category, this.size = 44});

  final VendorCategory? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = switch (category) {
      VendorCategory.pos => Icons.point_of_sale_outlined,
      VendorCategory.reservation => Icons.event_seat_outlined,
      VendorCategory.labor => Icons.schedule_outlined,
      null => Icons.hub_outlined,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.peacock.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: AppColors.peacockDark, size: size * 0.48),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.42)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.chipLabel(color: color)),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, this.message});

  final VendorConnectionStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final tip = _tooltipFor(status, message);
    final color = _colorFor(context, status);
    final label = _labelFor(status);
    return Tooltip(
      message: tip,
      child: _StatusChip(
        key: Key('vendor_connections_status_$label'),
        label: label,
        color: color,
      ),
    );
  }

  String _labelFor(VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'connected';
      case VendorConnectionStatus.disconnected:
        return 'disconnected';
      case VendorConnectionStatus.error:
        return 'error';
    }
  }

  String _tooltipFor(VendorConnectionStatus status, String? message) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'Live data is flowing. Sync is healthy.';
      case VendorConnectionStatus.disconnected:
        return 'Sync is paused. Historical data stays. Click Reconnect to resume.';
      case VendorConnectionStatus.error:
        return message ??
            'Something is wrong. Most often the vendor revoked our access. '
                'Click Reconnect and sign back in.';
    }
  }

  Color _colorFor(BuildContext context, VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return AppColors.positive;
      case VendorConnectionStatus.disconnected:
        return AppColors.textMuted;
      case VendorConnectionStatus.error:
        return AppColors.negative;
    }
  }
}

class _ErrorRemediation extends StatelessWidget {
  const _ErrorRemediation({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: [
              const Icon(
                Icons.error_outline,
                size: 18,
                color: AppColors.negative,
              ),
              const SizedBox(width: 8),
              Text(
                'Vendor access needs attention',
                style: AppTextStyles.sectionTitle(color: AppColors.negative),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'The vendor may have revoked access or changed credentials. '
            'Historical data stays safe.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            'Reconnect with the current vendor account to resume sync and fill '
            'any missing window.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Vendor message: $message',
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
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
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.32)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
