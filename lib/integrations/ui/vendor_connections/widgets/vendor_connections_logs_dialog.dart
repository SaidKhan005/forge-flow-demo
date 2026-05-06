// Phase 8.0 / Wave C1 — Sync-logs dialog for the shared Vendor
// Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable.

part of '../vendor_connections_widget.dart';

class _SyncLogsDialog extends StatelessWidget {
  const _SyncLogsDialog({required this.row, required this.entries});

  final VendorConnectionRow row;
  final List<VendorSyncLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_logs_dialog'),
      title: Text('Activity for ${row.displayName}'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: entries.isEmpty
            ? const _DialogNotice(
                icon: Icons.info_outline,
                title: 'No activity yet',
                body: 'This connection has not recorded a sync event yet.',
                color: AppColors.peacockDark,
              )
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final color = _eventColor(entry.eventKind);
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      border: Border.all(color: AppColors.borderSubtle),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_eventIcon(entry.eventKind), color: color),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _eventLabel(entry.eventKind),
                                style: AppTextStyles.sectionTitle(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                adminHumanDateTime(entry.occurredAt),
                                style: AppTextStyles.body12(
                                  color: AppColors.textSecondary,
                                  style: FontStyle.normal,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _logBody(entry),
                                style: AppTextStyles.body13(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_logs_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  String _logBody(VendorSyncLogEntry entry) {
    if (entry.errorMessage != null) return entry.errorMessage!;
    if (entry.recordsCount != null) {
      return '${entry.recordsCount} vendor records were processed.';
    }
    return 'The vendor connection recorded this activity.';
  }

  String _eventLabel(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return 'Sync completed';
      case 'poll_error':
        return 'Sync failed';
      case 'rate_limit_retry':
        return 'Vendor asked us to slow down';
      case 'sanity_drop':
        return 'Record skipped for safety';
      default:
        return eventKind
            .split('_')
            .where((part) => part.isNotEmpty)
            .map(
              (part) =>
                  '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
            )
            .join(' ');
    }
  }

  IconData _eventIcon(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return Icons.check_circle_outline;
      case 'poll_error':
        return Icons.error_outline;
      case 'rate_limit_retry':
        return Icons.hourglass_bottom_outlined;
      case 'sanity_drop':
        return Icons.rule_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Color _eventColor(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return AppColors.positive;
      case 'poll_error':
        return AppColors.negative;
      case 'rate_limit_retry':
        return AppColors.warning;
      case 'sanity_drop':
        return AppColors.peacockDark;
      default:
        return AppColors.textMuted;
    }
  }
}
