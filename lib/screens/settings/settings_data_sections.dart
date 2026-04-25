// Phase 7.55o.4 — Settings data-facing sections.
//
// Houses the restaurant hero, data status, mock replay, data
// management, audit-panel wrapper, and footer sections. Callbacks
// and state are supplied by SettingsScreen; the actions, dialogs,
// snackbars, and labels are unchanged from the pre-split file.

import 'package:flutter/material.dart';

import '../../data/baseline_manager_service.dart';
import '../../data/mock_integration_replay_seed.dart';
import '../../data/shift_service.dart';
import '../../models/app_data_status.dart';
import '../../theme/app_theme.dart';
import '../../widgets/data_alignment_audit_panel.dart';
import 'settings_shared_widgets.dart';

// ─── Hero ────────────────────────────────────────────────────────

class SettingsRestaurantHero extends StatelessWidget {
  final String name;
  const SettingsRestaurantHero({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.shimmer,
                AppColors.cardGlow,
                AppColors.backgroundMid,
              ],
            ),
            border: Border.all(color: AppColors.borderSubtle, width: 1),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 4, color: AppColors.sunset),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 18, 16),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.sunset.withValues(alpha: 0.14),
                            border: Border.all(
                                color: AppColors.sunset
                                    .withValues(alpha: 0.5)),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Icon(Icons.storefront_rounded,
                              size: 22, color: AppColors.sunset),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ACTIVE RESTAURANT',
                                  style: AppTextStyles.mono8(
                                      color: AppColors.textMuted)),
                              const SizedBox(height: 3),
                              Text(name,
                                  style: AppTextStyles.mono15(
                                      color: AppColors.textPrimary,
                                      weight: FontWeight.w700)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
// ─── Section wrappers ────────────────────────────────────────────

/// Data status card — wraps [_DataStatusTile] for dispatch from the
/// SettingsScreen shell.
class SettingsDataStatusSection extends StatelessWidget {
  final AppDataStatus? status;
  const SettingsDataStatusSection({super.key, required this.status});

  @override
  Widget build(BuildContext context) => _DataStatusTile(status: status);
}

/// Mock replay section — mock-date card plus Reset / Advance action
/// rows. Takes a [ValueGetter] for the mock date so the Advance
/// snackbar reads the value AFTER [onAfterWrite] has refreshed it,
/// preserving the pre-split behaviour.
class SettingsMockReplaySection extends StatelessWidget {
  final ValueGetter<String?> mockReplayDate;
  final Future<void> Function() onAfterWrite;
  const SettingsMockReplaySection({
    super.key,
    required this.mockReplayDate,
    required this.onAfterWrite,
  });

  @override
  Widget build(BuildContext context) {
    final date = mockReplayDate();
    return Column(
      children: [
        _SettingsMockReplayCard(mockReplayDate: date, formatDate: _formatDate),
        const SizedBox(height: 10),
        SettingsCard(
          children: [
            SettingsActionRow(
              icon: Icons.replay_rounded,
              label: 'Reset Mock Scenario',
              description:
                  'Reset to default scenario date (${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)})',
              onTap: () async {
                await ShiftService.instance.reseedDemo();
                await onAfterWrite();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Mock scenario reset to ${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)}.',
                        style: AppTextStyles.mono11(
                            color: AppColors.textPrimary),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
            const SettingsRowDivider(),
            SettingsActionRow(
              icon: Icons.skip_next_rounded,
              label: 'Advance Mock Day',
              description: 'Move mock business date forward one day',
              onTap: () async {
                await ShiftService.instance.advanceMockReplayDay();
                await onAfterWrite();
                if (context.mounted) {
                  final current = mockReplayDate();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Mock scenario advanced to ${current != null ? _formatDate(current) : "next day"}.',
                        style: AppTextStyles.mono11(
                            color: AppColors.textPrimary),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Data management section — Clear All Data + Reset Target Cycle.
/// Both actions confirm via dialog, then call [onAfterWrite] and
/// surface a snackbar. Behaviour is identical to the pre-split
/// shell's inline implementation.
class SettingsDataManagementSection extends StatelessWidget {
  final Future<void> Function() onAfterWrite;
  const SettingsDataManagementSection({
    super.key,
    required this.onAfterWrite,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      children: [
        SettingsActionRow(
          icon: Icons.delete_outline_rounded,
          label: 'Clear All Data',
          description:
              'Remove all operational data while keeping restaurant scope and connector settings.',
          tone: SettingsRowTone.danger,
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
                    child: Text(
                      'Cancel',
                      style: AppTextStyles.mono11(
                          color: AppColors.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      'Clear',
                      style: AppTextStyles.mono11(
                          color: AppColors.negative),
                    ),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await ShiftService.instance.clearAllData();
              await onAfterWrite();
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
        const SettingsRowDivider(),
        // 7.55q.9: admin/dev affordance — clears the manager override
        // + rebuilds the active 60-day cycle from the current
        // recommendation so the once-per-cycle rule can be tested
        // repeatedly without a real 60-day rollover.
        SettingsActionRow(
          icon: Icons.refresh_rounded,
          label: 'Reset Target Cycle (Admin)',
          description:
              'Clears manager override + rebuilds the active 60-day '
              'cycle from the current recommendation. For testing — '
              'skips the once-per-cycle rule.',
          tone: SettingsRowTone.admin,
          trailingBadge: 'ADMIN',
          onTap: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: AppColors.backgroundMid,
                title: Text(
                  'Reset target cycle?',
                  style:
                      AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
                content: Text(
                  'Clears the persisted manager override and the '
                  'active 60-day TargetCycle, then creates a fresh '
                  'recommended cycle. Use this to test the '
                  'once-per-cycle override rule repeatedly. '
                  'Closed shifts and week history are NOT affected.',
                  style: AppTextStyles.body13(
                      color: AppColors.textSecondary),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(
                      'Cancel',
                      style: AppTextStyles.mono11(
                          color: AppColors.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(
                      'Reset',
                      style: AppTextStyles.mono11(color: AppColors.sunset),
                    ),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await BaselineManagerService.instance.resetForAdminTest();
              await onAfterWrite();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Target cycle reset. Manager override is '
                      'available again.',
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
      ],
    );
  }
}

/// Audit panel wrapper. The shell previously rendered
/// [DataAlignmentAuditPanel] directly; keeping the wrapper makes the
/// Settings section surface symmetric with the other responsibilities.
class SettingsAuditSection extends StatelessWidget {
  const SettingsAuditSection({super.key});

  @override
  Widget build(BuildContext context) => const DataAlignmentAuditPanel();
}

// ─── Private helpers ─────────────────────────────────────────────

/// Formats an ISO date string as a human-readable label. Moved from
/// [_SettingsScreenState._formatDate] — used by the mock replay card
/// and its Reset / Advance snackbars.
String _formatDate(String isoDate) {
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

// ─── Private building blocks ─────────────────────────────────────

class _DataStatusTile extends StatelessWidget {
  final AppDataStatus? status;
  const _DataStatusTile({this.status});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) {
      return SettingsCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.sunset),
                ),
                const SizedBox(width: 10),
                Text('Loading…',
                    style: AppTextStyles.mono11(color: AppColors.textMuted)),
              ],
            ),
          ),
        ],
      );
    }

    final statusColor = switch (s.type) {
      AppDataStatusType.current => AppColors.positive,
      AppDataStatusType.historicalOnly => AppColors.sunsetDark,
      AppDataStatusType.stale => AppColors.warning,
      AppDataStatusType.failedImport => AppColors.negative,
      AppDataStatusType.noData => AppColors.textMuted,
    };

    return SettingsCard(
      accentColor: statusColor,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // Status pill — icon-style dot inside a tinted chip
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.14),
                      border: Border.all(
                          color: statusColor.withValues(alpha: 0.55),
                          width: 1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
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
                            style: AppTextStyles.mono10(color: statusColor)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(s.description,
                  style:
                      AppTextStyles.body13(color: AppColors.textSecondary)),
              if (s.latestImportTimestamp != null) ...[
                const SizedBox(height: 8),
                Container(height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.history_rounded,
                        size: 12, color: AppColors.textMuted),
                    const SizedBox(width: 6),
                    Text('Last import: ${s.latestImportTimestamp}',
                        style:
                            AppTextStyles.mono8(color: AppColors.textMuted)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
class _SettingsMockReplayCard extends StatelessWidget {
  final String? mockReplayDate;
  final String Function(String) formatDate;
  const _SettingsMockReplayCard({
    required this.mockReplayDate,
    required this.formatDate,
  });

  @override
  Widget build(BuildContext context) {
    final formatted =
        mockReplayDate != null ? formatDate(mockReplayDate!) : '...';
    // Split formatted date "Fri, Mar 27, 2026" into emphasis + meta parts
    // for hero display, while still rendering the full string verbatim
    // somewhere in the tree so existing widget tests stay green.
    return SettingsCard(
      accentColor: AppColors.sunsetDark,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.sunsetDark.withValues(alpha: 0.14),
                  border: Border.all(
                      color:
                          AppColors.sunsetDark.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(Icons.calendar_today_rounded,
                    size: 20, color: AppColors.sunsetDark),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Mock Business Date',
                        style: AppTextStyles.mono12(
                            color: AppColors.textPrimary)),
                    const SizedBox(height: 3),
                    Text(formatted,
                        style: AppTextStyles.mono14(
                            color: AppColors.sunsetDark,
                            weight: FontWeight.w700)),
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
// ─── Footer ──────────────────────────────────────────────────────

class SettingsFooter extends StatelessWidget {
  final String restaurantName;
  const SettingsFooter({super.key, required this.restaurantName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 1,
            color: AppColors.borderSubtle.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.bolt_rounded,
                  size: 12, color: AppColors.textMuted),
              const SizedBox(width: 6),
              Text(
                'Forge & Flow \u00b7 v1.0.0 \u00b7 $restaurantName',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}