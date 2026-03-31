import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/app_data_status_service.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/shift_dashboard_notifier.dart';
import '../data/shift_service.dart';
import '../data/week_data_notifier.dart';
import '../models/app_data_status.dart';

class SettingsScreen extends StatefulWidget {
  /// Optional injected status for testability. When null, loads from service.
  final AppDataStatus? initialStatus;

  const SettingsScreen({super.key, this.initialStatus});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppDataStatus? _status;

  @override
  void initState() {
    super.initState();
    if (widget.initialStatus != null) {
      _status = widget.initialStatus;
    } else {
      _loadStatus();
    }
  }

  Future<void> _loadStatus() async {
    final status = await AppDataStatusService.instance.evaluate();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _refreshAppState() async {
    if (!context.mounted) return;
    try {
      context.read<RestaurantScopeNotifier>().refresh();
      context.read<ActiveTargetProfileNotifier>().refresh();
      context.read<WeekDataNotifier>().refresh();
      context.read<ShiftDashboardNotifier>().refresh();
    } catch (_) {
      // Providers may not be available in test injection mode
    }
    await _loadStatus();
  }

  @override
  Widget build(BuildContext context) {
    final restaurantDisplayName =
        context.watch<RestaurantScopeNotifier?>()?.restaurant?.displayName ??
            'Restaurant';
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Settings', style: AppTextStyles.display20()),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // Data status section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('DATA STATUS',
                style: AppTextStyles.mono8(color: AppColors.textMuted)),
          ),
          _DataStatusTile(status: _status),

          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 16),

          // Demo data section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('DEMO',
                style: AppTextStyles.mono8(color: AppColors.textMuted)),
          ),

          _SettingsTile(
            label: 'Load Demo Data',
            description: 'Reseed 9 closed shifts + 7-week history',
            onTap: () async {
              await ShiftService.instance.reseedDemo();
              await _refreshAppState();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Demo data loaded.',
                      style:
                          AppTextStyles.mono11(color: AppColors.textPrimary),
                    ),
                    backgroundColor: AppColors.backgroundMid,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
          ),

          Container(height: 1, color: AppColors.borderSubtle),

          _SettingsTile(
            label: 'Clear All Data',
            description:
                'Remove all operational data while keeping restaurant scope and connector settings.',
            labelColor: AppColors.negative,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: AppColors.backgroundMid,
                  title: Text(
                    'Clear all data?',
                    style:
                        AppTextStyles.mono14(color: AppColors.textPrimary),
                  ),
                  content: Text(
                    'This removes all operational data while keeping restaurant scope and connector settings. Cannot be undone.',
                    style: AppTextStyles.body13(
                        color: AppColors.textSecondary),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text('Cancel',
                          style: AppTextStyles.mono11(
                              color: AppColors.textSecondary)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text('Clear',
                          style: AppTextStyles.mono11(
                              color: AppColors.negative)),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await ShiftService.instance.clearAllData();
                await _refreshAppState();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'All operational data cleared.',
                        style: AppTextStyles.mono11(
                            color: AppColors.textPrimary),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
          ),

          const SizedBox(height: 32),

          // Version
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Forge & Flow \u00b7 v1.0.0 \u00b7 $restaurantDisplayName',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Data status tile ───────────────────────────────────────────────────────

class _DataStatusTile extends StatelessWidget {
  final AppDataStatus? status;
  const _DataStatusTile({this.status});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        color: AppColors.backgroundMid,
        child: Text('Loading...',
            style: AppTextStyles.mono11(color: AppColors.textMuted)),
      );
    }

    final statusColor = switch (s.type) {
      AppDataStatusType.current => AppColors.positive,
      AppDataStatusType.historicalOnly => AppColors.tealSoft,
      AppDataStatusType.stale => AppColors.warning,
      AppDataStatusType.failedImport => AppColors.negative,
      AppDataStatusType.noData => AppColors.textMuted,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      color: AppColors.backgroundMid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(s.label,
                  style: AppTextStyles.mono12(color: statusColor)),
            ],
          ),
          const SizedBox(height: 4),
          Text(s.description,
              style: AppTextStyles.body13(color: AppColors.textMuted)),
          if (s.latestImportTimestamp != null) ...[
            const SizedBox(height: 4),
            Text('Last import: ${s.latestImportTimestamp}',
                style: AppTextStyles.mono8(color: AppColors.textMuted)),
          ],
        ],
      ),
    );
  }
}

// ─── Settings tile ──────────────────────────────────────────────────────────

class _SettingsTile extends StatelessWidget {
  final String label;
  final String description;
  final Color? labelColor;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.label,
    required this.description,
    this.labelColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        color: AppColors.backgroundMid,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.mono12(
                        color: labelColor ?? AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style:
                        AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
