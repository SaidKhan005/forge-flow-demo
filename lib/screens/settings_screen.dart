import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/active_target_profile_notifier.dart';
import '../data/app_data_status_service.dart';
import '../data/mock_integration_replay_seed.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/schedule_distribution_weights_notifier.dart';
import '../data/shift_dashboard_notifier.dart';
import '../data/shift_service.dart';
import '../data/week_data_notifier.dart';
import '../models/app_data_status.dart';
import '../widgets/data_alignment_audit_panel.dart';

class SettingsScreen extends StatefulWidget {
  /// Optional injected status for testability. When null, loads from service.
  final AppDataStatus? initialStatus;

  /// Optional injected mock replay date for testability.
  final String? initialMockDate;

  const SettingsScreen({super.key, this.initialStatus, this.initialMockDate});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppDataStatus? _status;
  String? _mockReplayDate;

  @override
  void initState() {
    super.initState();
    if (widget.initialStatus != null) {
      _status = widget.initialStatus;
    } else {
      _loadStatus();
    }
    if (widget.initialMockDate != null) {
      _mockReplayDate = widget.initialMockDate;
    } else {
      _loadMockDate();
    }
  }

  Future<void> _loadStatus() async {
    final status = await AppDataStatusService.instance.evaluate();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _loadMockDate() async {
    final date = await ShiftService.instance.getMockReplayBusinessDate();
    if (mounted) setState(() => _mockReplayDate = date);
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
    try {
      context.read<ScheduleDistributionWeightsNotifier>().load();
    } catch (_) {
      // ScheduleDistributionWeightsNotifier may not be in scope
    }
    await _loadStatus();
    await _loadMockDate();
  }

  /// Formats an ISO date string as a human-readable label.
  static String _formatDate(String isoDate) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final parts = isoDate.split('-');
    if (parts.length != 3) return isoDate;
    final y = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    final d = int.tryParse(parts[2]);
    if (y == null || m == null || d == null) return isoDate;
    final dt = DateTime(y, m, d);
    return '${weekdays[dt.weekday - 1]}, ${months[m - 1]} $d, $y';
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

          // Mock business date display
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: AppColors.backgroundMid,
            child: Row(
              children: [
                Text('Mock Business Date',
                    style: AppTextStyles.mono12(
                        color: AppColors.textPrimary)),
                const Spacer(),
                Text(
                  _mockReplayDate != null
                      ? _formatDate(_mockReplayDate!)
                      : '...',
                  style: AppTextStyles.mono11(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),

          Container(height: 1, color: AppColors.borderSubtle),

          _SettingsTile(
            label: 'Reset Mock Scenario',
            description:
                'Reset to default scenario date (${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)})',
            onTap: () async {
              await ShiftService.instance.reseedDemo();
              await _refreshAppState();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Mock scenario reset to ${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)}.',
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
            label: 'Advance Mock Day',
            description: 'Move mock business date forward one day',
            onTap: () async {
              await ShiftService.instance.advanceMockReplayDay();
              await _refreshAppState();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Mock scenario advanced to ${_mockReplayDate != null ? _formatDate(_mockReplayDate!) : "next day"}.',
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

          const SizedBox(height: 16),

          // Audit section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('AUDIT',
                style: AppTextStyles.mono8(color: AppColors.textMuted)),
          ),
          const DataAlignmentAuditPanel(),

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
      AppDataStatusType.historicalOnly => AppColors.sunsetDark,
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
