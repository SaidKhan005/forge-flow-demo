import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/app_data_status_service.dart';
import '../data/app_refresh_coordinator.dart';
import '../data/baseline_manager_service.dart';
import '../data/mock_integration_replay_seed.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/restaurant_timing_config_read_service.dart';
import '../data/shift_service.dart';
import '../data/wage_standard_context_service.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/wage_role_row.dart';
import '../domain/models/wage_standard_context.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import '../models/app_data_status.dart';
import '../widgets/data_alignment_audit_panel.dart';
import '../widgets/sticky_section_delegate.dart';

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

  /// Full refresh after actions that do NOT fire the runtime invalidation
  /// bus (e.g., wage changes). Target cascade handles current-state.
  Future<void> _refreshAppState() async {
    if (!context.mounted) return;
    try {
      context.read<AppRefreshCoordinator>().refreshAll();
    } catch (_) {
      // Coordinator may not be in scope during widget tests
    }
    await _loadStatus();
    await _loadMockDate();
  }

  /// Refresh after writes that fire the runtime invalidation bus.
  /// The bus already refreshed current-state surfaces (week, shift).
  /// This refreshes supporting surfaces and local labels only.
  Future<void> _refreshAfterWrite() async {
    if (!context.mounted) return;
    try {
      context.read<AppRefreshCoordinator>().refreshAfterWrite();
    } catch (_) {
      // Coordinator may not be in scope during widget tests
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
    final restaurant = context.watch<RestaurantScopeNotifier?>()?.restaurant;
    final restaurantDisplayName = restaurant?.displayName ?? 'Restaurant';
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
      body: CustomScrollView(
        cacheExtent: 9999,
        slivers: [
          // ── Restaurant hero ──────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _SettingsRestaurantHero(name: restaurantDisplayName),
            ),
          ),

          // ── DATA STATUS ──────────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('DATA STATUS'),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _DataStatusTile(status: _status),
                ),
              ),
            ],
          ),

          // ── MOCK REPLAY ──────────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('MOCK REPLAY'),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SettingsMockReplayCard(
                    mockReplayDate: _mockReplayDate,
                    formatDate: _formatDate,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: _SettingsCard(
                    children: [
                      _SettingsActionRow(
                        icon: Icons.replay_rounded,
                        label: 'Reset Mock Scenario',
                        description:
                            'Reset to default scenario date (${_formatDate(MockIntegrationReplaySeed.defaultBusinessDate)})',
                        onTap: () async {
                          await ShiftService.instance.reseedDemo();
                          await _refreshAfterWrite();
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
                      const _SettingsRowDivider(),
                      _SettingsActionRow(
                        icon: Icons.skip_next_rounded,
                        label: 'Advance Mock Day',
                        description: 'Move mock business date forward one day',
                        onTap: () async {
                          await ShiftService.instance.advanceMockReplayDay();
                          await _refreshAfterWrite();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Mock scenario advanced to ${_mockReplayDate != null ? _formatDate(_mockReplayDate!) : "next day"}.',
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
                ),
              ),
            ],
          ),

          // ── DATA MANAGEMENT ──────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('DATA MANAGEMENT'),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SettingsCard(
                    children: [
                      _SettingsActionRow(
                        icon: Icons.delete_outline_rounded,
                        label: 'Clear All Data',
                        description:
                            'Remove all operational data while keeping restaurant scope and connector settings.',
                        tone: _SettingsRowTone.danger,
                        onTap: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppColors.backgroundMid,
                              title: Text(
                                'Clear all data?',
                                style: AppTextStyles.mono14(
                                    color: AppColors.textPrimary),
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
                            await _refreshAfterWrite();
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
                      const _SettingsRowDivider(),
                      // 7.55q.9: admin/dev affordance — clears the manager override
                      // + rebuilds the active 60-day cycle from the current
                      // recommendation so the once-per-cycle rule can be tested
                      // repeatedly without a real 60-day rollover.
                      _SettingsActionRow(
                        icon: Icons.refresh_rounded,
                        label: 'Reset Target Cycle (Admin)',
                        description:
                            'Clears manager override + rebuilds the active 60-day '
                            'cycle from the current recommendation. For testing — '
                            'skips the once-per-cycle rule.',
                        tone: _SettingsRowTone.admin,
                        trailingBadge: 'ADMIN',
                        onTap: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: AppColors.backgroundMid,
                              title: Text(
                                'Reset target cycle?',
                                style: AppTextStyles.mono14(
                                    color: AppColors.textPrimary),
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
                                  child: Text('Cancel',
                                      style: AppTextStyles.mono11(
                                          color: AppColors.textSecondary)),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(ctx).pop(true),
                                  child: Text('Reset',
                                      style: AppTextStyles.mono11(
                                          color: AppColors.sunset)),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await BaselineManagerService.instance.resetForAdminTest();
                            await _refreshAfterWrite();
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
                  ),
                ),
              ),
            ],
          ),

          // ── TIMING AUTHORITY ─────────────────────────────────────────
          if (restaurant != null)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('TIMING AUTHORITY'),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _TimingAuthoritySection(restaurantId: restaurant.restaurantId),
                  ),
                ),
              ],
            ),

          // ── WAGE AUTHORITY ───────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('WAGE AUTHORITY'),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _WageAuthoritySection(onChanged: _refreshAppState),
                ),
              ),
            ],
          ),

          // ── AUDIT ────────────────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('AUDIT'),
              ),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: DataAlignmentAuditPanel(),
                ),
              ),
            ],
          ),

          // ── Footer ───────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
              child: _SettingsFooter(restaurantName: restaurantDisplayName),
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
      return _SettingsCard(
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

    return _SettingsCard(
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

// ─── Settings shared UI primitives ────────────────────────────────────────
// Card surfaces, section headers, action rows, and the restaurant hero
// shared by every section in Settings. Keeps the visual language
// consistent with the wage-mix card system.

class _SettingsRestaurantHero extends StatelessWidget {
  final String name;
  const _SettingsRestaurantHero({required this.name});

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

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  // Optional accent stripe color along the left edge. Used by status card.
  final Color? accentColor;
  const _SettingsCard({required this.children, this.accentColor});

  @override
  Widget build(BuildContext context) {
    final accent = accentColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (accent != null)
                Container(
                  width: 3,
                  color: accent,
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsRowDivider extends StatelessWidget {
  const _SettingsRowDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      height: 1,
      color: AppColors.borderSubtle.withValues(alpha: 0.6),
    );
  }
}

enum _SettingsRowTone { neutral, danger, admin }

class _SettingsActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final _SettingsRowTone tone;
  final String? trailingBadge;

  const _SettingsActionRow({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.tone = _SettingsRowTone.neutral,
    this.trailingBadge,
  });

  Color get _accentColor {
    switch (tone) {
      case _SettingsRowTone.danger:
        return AppColors.negative;
      case _SettingsRowTone.admin:
        return AppColors.sunset;
      case _SettingsRowTone.neutral:
        return AppColors.textPrimary;
    }
  }

  Color get _iconBgColor {
    switch (tone) {
      case _SettingsRowTone.danger:
        return AppColors.negative.withValues(alpha: 0.12);
      case _SettingsRowTone.admin:
        return AppColors.sunset.withValues(alpha: 0.12);
      case _SettingsRowTone.neutral:
        return AppColors.borderSubtle.withValues(alpha: 0.4);
    }
  }

  Color get _iconBorderColor {
    switch (tone) {
      case _SettingsRowTone.danger:
        return AppColors.negative.withValues(alpha: 0.5);
      case _SettingsRowTone.admin:
        return AppColors.sunset.withValues(alpha: 0.5);
      case _SettingsRowTone.neutral:
        return AppColors.borderSubtle;
    }
  }

  Color get _iconFgColor {
    switch (tone) {
      case _SettingsRowTone.danger:
        return AppColors.negative;
      case _SettingsRowTone.admin:
        return AppColors.sunset;
      case _SettingsRowTone.neutral:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Leading icon tile
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _iconBgColor,
                border: Border.all(color: _iconBorderColor, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(icon, size: 18, color: _iconFgColor),
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
                          style: AppTextStyles.mono12(
                              color: _accentColor,
                              weight: FontWeight.w600),
                        ),
                      ),
                      if (trailingBadge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.sunset.withValues(alpha: 0.15),
                            border: Border.all(
                                color: AppColors.sunset
                                    .withValues(alpha: 0.5),
                                width: 1),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(trailingBadge!,
                              style:
                                  AppTextStyles.mono7(color: AppColors.sunset)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(description,
                      style:
                          AppTextStyles.body13(color: AppColors.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right,
                size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
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
    return _SettingsCard(
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

class _SettingsFooter extends StatelessWidget {
  final String restaurantName;
  const _SettingsFooter({required this.restaurantName});

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

// ─── Wage authority section (7.55p.5f1a — whole-mix editor) ───────────────
//
// Read-only summary panel in Settings. A single `Edit Wage Mix` button
// opens a full-screen editor where the user fills the entire fallback
// wage mix in one pass (FOH + BOH + Management inline together) and
// saves once. The editor persists through the same
// `WageRoleRow -> WageStandardContextService -> ActiveTargetProfile`
// authority seam used by Benchmark, Variance, and Shift downstream
// consumers.

class _TimingAuthoritySection extends StatelessWidget {
  final String restaurantId;
  const _TimingAuthoritySection({required this.restaurantId});

  static String _formatTime(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return hhmm;
    final hour24 = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour24 == null || minute == null) return hhmm;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    return '$hour12:${minute.toString().padLeft(2, '0')} $amPm';
  }

  static String _formatWeekStart(int weekStartDay) {
    const names = {
      DateTime.monday: 'Monday',
      DateTime.tuesday: 'Tuesday',
      DateTime.wednesday: 'Wednesday',
      DateTime.thursday: 'Thursday',
      DateTime.friday: 'Friday',
      DateTime.saturday: 'Saturday',
      DateTime.sunday: 'Sunday',
    };
    return names[weekStartDay] ?? 'Day $weekStartDay';
  }

  static String _formatApplicableDays(List<int> days) {
    const shortNames = {
      1: 'Mon',
      2: 'Tue',
      3: 'Wed',
      4: 'Thu',
      5: 'Fri',
      6: 'Sat',
      7: 'Sun',
    };
    if (days.length == 7) return 'Daily';
    if (_sameDays(days, const [1, 2, 3, 4, 5])) return 'Mon–Fri';
    if (_sameDays(days, const [5, 6])) return 'Fri–Sat';
    return days.map((d) => shortNames[d] ?? '$d').join(', ');
  }

  static bool _sameDays(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _formatShiftCloseRule(RestaurantTimingConfig config) {
    switch (config.shiftCloseAuthority) {
      case ShiftCloseAuthority.vendorFinalization:
        return 'Vendor finalization';
      case ShiftCloseAuthority.appLocalCutoffFallback:
        final cutoff =
            config.localCloseFallback ?? config.businessDayStartLocalTime;
        return 'Local cutoff fallback (${_formatTime(cutoff)})';
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RestaurantTimingConfig?>(
      future:
          RestaurantTimingConfigReadService.instance.getTimingConfig(restaurantId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return _SettingsCard(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Text(
                  'Loading timing settings…',
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ],
          );
        }

        final config = snapshot.data;
        if (config == null) {
          return _SettingsCard(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Text(
                  'Timing settings are not available yet for this restaurant.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ),
            ],
          );
        }

        final periods = config.servicePeriodDefinitions;
        return _SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.sunset.withValues(alpha: 0.12),
                          border: Border.all(
                            color: AppColors.sunset.withValues(alpha: 0.45),
                            width: 1,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          'ACTIVE TIMING',
                          style:
                              AppTextStyles.mono10(color: AppColors.sunsetDark),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Restaurant-local timing controls the business date, week start, and service buckets. Timezone is visible here now; full timezone editing stays in the deeper time-boundary lane.',
                    style: AppTextStyles.body13(
                        color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  _TimingValueRow(
                    label: 'Timezone',
                    value: config.businessTimezone,
                  ),
                  const _SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Business Day Starts',
                    value: _formatTime(config.businessDayStartLocalTime),
                  ),
                  const _SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Week Starts',
                    value: _formatWeekStart(config.weekStartDay),
                  ),
                  const _SettingsRowDivider(),
                  _TimingValueRow(
                    label: 'Shift Close Rule',
                    value: _formatShiftCloseRule(config),
                  ),
                  if (periods.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'SERVICE PERIODS',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < periods.length; i++) ...[
                      if (i > 0) const _SettingsRowDivider(),
                      _TimingValueRow(
                        label: periods[i].label,
                        value:
                            '${_formatApplicableDays(periods[i].applicableDays)} · ${_formatTime(periods[i].startLocalTime)}–${_formatTime(periods[i].endLocalTime)}',
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimingValueRow extends StatelessWidget {
  final String label;
  final String value;
  const _TimingValueRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _WageAuthoritySection extends StatefulWidget {
  final VoidCallback onChanged;
  const _WageAuthoritySection({required this.onChanged});

  @override
  State<_WageAuthoritySection> createState() => _WageAuthoritySectionState();
}

class _WageAuthoritySectionState extends State<_WageAuthoritySection> {
  WageStandardContext? _wageCtx;
  List<WageRoleRow> _rows = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      _wageCtx =
          await WageStandardContextService.instance.resolve(restaurantId);
      _rows =
          await SqliteWageRoleRowRepository.instance.getRows(restaurantId);
    } catch (_) {}
    if (mounted) setState(() => _isLoading = false);
  }

  /// Applies one whole-mix edit result from [_WageMixEditorScreen]:
  /// upserts every row the editor still contains, deletes any existing
  /// rows the editor removed, then syncs the active profile once.
  ///
  /// This preserves the existing authority seam — every row still
  /// flows through `SqliteWageRoleRowRepository.upsertRow` and the
  /// profile push still happens through
  /// [WageStandardContextService.syncWagesToActiveProfile]. No
  /// UI-only wage truth path is introduced.
  Future<void> _applyMixEdit(_WageMixEditResult result) async {
    for (final row in result.rowsToPersist) {
      await SqliteWageRoleRowRepository.instance.upsertRow(row);
    }
    for (final id in result.idsToDelete) {
      await SqliteWageRoleRowRepository.instance.deleteRow(id);
    }
    await WageStandardContextService.instance.syncWagesToActiveProfile();
    await _load();
    widget.onChanged();
  }

  Future<void> _openMixEditor() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    if (!mounted) return;

    final result = await Navigator.of(context).push<_WageMixEditResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _WageMixEditorScreen(
          restaurantId: restaurantId,
          initialRows: _rows,
        ),
      ),
    );
    if (result != null) {
      await _applyMixEdit(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.all(16),
        color: AppColors.backgroundMid,
        child: Text('Loading...',
            style: AppTextStyles.mono11(color: AppColors.textMuted)),
      );
    }

    final w = _wageCtx;
    final summary = WageStandardContextService.summarizeMix(_rows);
    return Container(
      color: AppColors.backgroundMid,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Resolved wages card — headline numbers at a glance ───────────
          _WageMixSectionCard(
            children: [
              _WageMixStatRow(
                label: 'SOURCE',
                value: w?.source.displayLabel ?? '—',
              ),
              const _WageMixDivider(),
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'FOH WAGE',
                      value: w?.fohWage != null
                          ? '\$${w!.fohWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'BOH WAGE',
                      value: w?.bohWage != null
                          ? '\$${w!.bohWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'BLENDED',
                      value: w?.referenceBlendedWage != null
                          ? '\$${w!.referenceBlendedWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Mix summary card — totals ────────────────────────────────
          _WageMixSectionCard(
            title: 'MIX SUMMARY',
            children: [
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'TOTAL HOURS/WK',
                      value:
                          '${summary.totalWeightedHours.toStringAsFixed(0)} h',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'WEEKLY COST',
                      value: '\$${summary.totalHourlyCost.toStringAsFixed(0)}',
                    ),
                  ),
                ],
              ),
              if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text: 'Needs at least one FOH role AND one BOH role to '
                      'resolve as App Configured. Currently using Config '
                      'Default.',
                ),
              ],
              if (summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text:
                      'No roles configured — wages resolve from Config Default.',
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Read-only grouped display of the current mix ──────────────
          _WageMixBucketCard(
            header: 'FRONT OF HOUSE',
            rows: summary.fohRows,
          ),
          const SizedBox(height: 10),
          _WageMixBucketCard(
            header: 'BACK OF HOUSE',
            rows: summary.bohRows,
          ),
          const SizedBox(height: 10),
          _WageMixBucketCard(
            header: 'MANAGEMENT',
            rows: summary.managerRows,
            helper: 'Management rows contribute to reference blended only.',
          ),

          const SizedBox(height: 16),

          // ── Single whole-mix edit action (primary button) ────────────
          _WageMixPrimaryButton(
            icon: Icons.edit_outlined,
            label: 'Edit Wage Mix',
            onTap: _openMixEditor,
          ),
        ],
      ),
    );
  }
}

// ─── Whole-mix editor result (7.55p.5f1a) ───────────────────────────────

/// Diff computed by [_WageMixEditorScreen.Save] vs the initial persisted
/// rows. The Settings section applies this diff in one pass through the
/// existing wage-authority seam.
class _WageMixEditResult {
  final List<WageRoleRow> rowsToPersist;
  final List<int> idsToDelete;
  const _WageMixEditResult({
    required this.rowsToPersist,
    required this.idsToDelete,
  });
}

// ─── Whole-mix editor screen (7.55p.5f1a) ───────────────────────────────
//
// The user enters the entire FOH + BOH + Management mix inline here and
// saves once. Previously each bucket had its own "+ Add role" button
// that opened a separate dialog per row — which is not a whole-mix
// interaction. This screen keeps all three buckets editable on one
// surface and persists in a single save pass.

class _WageMixEditorScreen extends StatefulWidget {
  final String restaurantId;
  final List<WageRoleRow> initialRows;

  const _WageMixEditorScreen({
    required this.restaurantId,
    required this.initialRows,
  });

  @override
  State<_WageMixEditorScreen> createState() => _WageMixEditorScreenState();
}

class _WageMixEditorScreenState extends State<_WageMixEditorScreen> {
  /// Draft editor rows. Order is preserved within each bucket.
  final List<_EditorRow> _drafts = [];

  @override
  void initState() {
    super.initState();
    for (final r in widget.initialRows) {
      _drafts.add(_EditorRow.fromPersisted(r));
    }
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  void _addRow(String bucket) {
    setState(() {
      _drafts.add(_EditorRow.blank(bucket));
    });
  }

  void _removeRow(_EditorRow row) {
    setState(() {
      row.dispose();
      _drafts.remove(row);
    });
  }

  /// Builds the save diff: valid drafts become upsert rows; any
  /// persisted id that is no longer in the draft list gets deleted.
  _WageMixEditResult _buildResult() {
    final persist = <WageRoleRow>[];
    final keptIds = <int>{};
    for (final d in _drafts) {
      final row = d.toRowOrNull(widget.restaurantId);
      if (row != null) {
        persist.add(row);
        if (d.persistedId != null) {
          keptIds.add(d.persistedId!);
        }
      }
    }
    final deletes = widget.initialRows
        .where((r) => r.id != null && !keptIds.contains(r.id))
        .map((r) => r.id!)
        .toList();
    return _WageMixEditResult(
      rowsToPersist: persist,
      idsToDelete: deletes,
    );
  }

  List<_EditorRow> _forBucket(String b) =>
      _drafts.where((d) => d.bucket == b).toList();

  /// Live snapshot of the current draft rows as persisted rows for
  /// totals / warning preview. Drafts with invalid inputs are skipped.
  List<WageRoleRow> _liveRows() {
    return _drafts
        .map((d) => d.toRowOrNull(widget.restaurantId))
        .whereType<WageRoleRow>()
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final summary =
        WageStandardContextService.summarizeMix(_liveRows());
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Edit Wage Mix', style: AppTextStyles.display20()),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      // Primary Save action is pinned to the bottom so it's always reachable
      // regardless of how far the user has scrolled.
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.backgroundDeep,
            border: Border(
              top: BorderSide(color: AppColors.borderSubtle, width: 1),
            ),
          ),
          child: _WageMixPrimaryButton(
            icon: Icons.check_rounded,
            label: 'Save Wage Mix',
            onTap: () => Navigator.of(context).pop(_buildResult()),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
          // Hint so users understand the flow before they see the fields
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text(
              'Add every role you staff. Rate is per hour, Hours is per week.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),

          _editorBucket(
            header: 'FRONT OF HOUSE',
            bucket: 'foh',
            addLabel: 'Add FOH role',
          ),
          const SizedBox(height: 12),
          _editorBucket(
            header: 'BACK OF HOUSE',
            bucket: 'boh',
            addLabel: 'Add BOH role',
          ),
          const SizedBox(height: 12),
          _editorBucket(
            header: 'MANAGEMENT',
            bucket: 'manager',
            addLabel: 'Add Management role',
            helper: 'Management rows contribute to reference blended only.',
          ),

          const SizedBox(height: 16),

          // Live mix summary inside the editor so the user can see the
          // consequence of their in-flight edits before saving.
          _WageMixSectionCard(
            title: 'MIX SUMMARY',
            children: [
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'TOTAL HOURS/WK',
                      value:
                          '${summary.totalWeightedHours.toStringAsFixed(0)} h',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'WEEKLY COST',
                      value: '\$${summary.totalHourlyCost.toStringAsFixed(0)}',
                    ),
                  ),
                ],
              ),
              if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text: 'Will fall back to Config Default on save. Add at '
                      'least one FOH row AND one BOH row for App Configured.',
                ),
              ],
              if (summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text:
                      'No rows — wages will stay on Config Default until you '
                      'add at least one FOH row and one BOH row.',
                ),
              ],
            ],
          ),

          ],
        ),
      ),
    );
  }

  Widget _editorBucket({
    required String header,
    required String bucket,
    required String addLabel,
    String? helper,
  }) {
    final rows = _forBucket(bucket);
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip with role count pill
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  color: AppColors.sunset,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(header,
                      style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${rows.length}',
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(helper,
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Text('No roles yet.',
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            ),
          for (int i = 0; i < rows.length; i++) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(10, i == 0 ? 10 : 6, 10, 4),
              child: _editorRowTile(rows[i]),
            ),
          ],
          // Add-row button
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: _WageMixSecondaryButton(
              icon: Icons.add_rounded,
              label: addLabel,
              onTap: () => _addRow(bucket),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorRowTile(_EditorRow row) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.5),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Role name row + remove
          Row(
            children: [
              Expanded(
                child: _labeledField(
                  label: 'ROLE',
                  child: TextField(
                    key: row.nameKey,
                    controller: row.nameCtrl,
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Server',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              IconButton(
                key: row.removeKey,
                tooltip: 'Remove role',
                icon: Icon(Icons.delete_outline,
                    size: 18, color: AppColors.textMuted),
                onPressed: () => _removeRow(row),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 6),
          // Rate + Hours row
          Row(
            children: [
              Expanded(
                child: _labeledField(
                  label: 'RATE \$/HR',
                  child: TextField(
                    key: row.rateKey,
                    controller: row.rateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
                      isDense: true,
                      prefixText: '\$',
                      prefixStyle: AppTextStyles.mono12(
                          color: AppColors.textSecondary),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _labeledField(
                  label: 'HOURS/WK',
                  child: TextField(
                    key: row.hoursKey,
                    controller: row.hoursCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
                      isDense: true,
                      suffixText: 'h',
                      suffixStyle: AppTextStyles.mono12(
                          color: AppColors.textSecondary),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _labeledField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

/// Editable draft state for one row in the whole-mix editor.
///
/// Owns its own text controllers so in-flight edits do not race with
/// SetState rebuilds. `persistedId` is the SQLite id for rows that
/// already exist — `null` for new rows the user added in this editor.
class _EditorRow {
  final int? persistedId;
  final String bucket;
  final TextEditingController nameCtrl;
  final TextEditingController rateCtrl;
  final TextEditingController hoursCtrl;
  final Key nameKey;
  final Key rateKey;
  final Key hoursKey;
  final Key removeKey;

  _EditorRow._({
    required this.persistedId,
    required this.bucket,
    required this.nameCtrl,
    required this.rateCtrl,
    required this.hoursCtrl,
  })  : nameKey = UniqueKey(),
        rateKey = UniqueKey(),
        hoursKey = UniqueKey(),
        removeKey = UniqueKey();

  factory _EditorRow.blank(String bucket) {
    return _EditorRow._(
      persistedId: null,
      bucket: bucket,
      nameCtrl: TextEditingController(),
      rateCtrl: TextEditingController(),
      hoursCtrl: TextEditingController(),
    );
  }

  factory _EditorRow.fromPersisted(WageRoleRow r) {
    return _EditorRow._(
      persistedId: r.id,
      bucket: r.laborBucket,
      nameCtrl: TextEditingController(text: r.roleName),
      rateCtrl: TextEditingController(text: r.hourlyRate.toStringAsFixed(2)),
      hoursCtrl:
          TextEditingController(text: r.weightedHours.toStringAsFixed(0)),
    );
  }

  /// Converts this draft into a persistable `WageRoleRow`, or null if
  /// the user has not filled it in enough to be valid.
  WageRoleRow? toRowOrNull(String restaurantId) {
    final name = nameCtrl.text.trim();
    final rate = double.tryParse(rateCtrl.text.trim());
    final hours = double.tryParse(hoursCtrl.text.trim());
    if (name.isEmpty) return null;
    if (rate == null || rate < 0) return null;
    if (hours == null || hours < 0) return null;
    return WageRoleRow(
      id: persistedId,
      restaurantId: restaurantId,
      roleName: name,
      laborBucket: bucket,
      hourlyRate: rate,
      weightedHours: hours,
    );
  }

  void dispose() {
    nameCtrl.dispose();
    rateCtrl.dispose();
    hoursCtrl.dispose();
  }
}

// ─── Wage mix shared UI primitives ────────────────────────────────────────
// Card surfaces, stat pills, warning bands, and button shells shared by
// both the Settings summary panel and the full-screen editor so the
// read-only view and the edit view feel like one UI.

class _WageMixSectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _WageMixSectionCard({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(title!,
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    );
  }
}

class _WageMixStat extends StatelessWidget {
  final String label;
  final String value;
  const _WageMixStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(value,
            style: AppTextStyles.mono14(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _WageMixStatRow extends StatelessWidget {
  final String label;
  final String value;
  const _WageMixStatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.mono8(color: AppColors.textMuted)),
        ),
        Text(value,
            style: AppTextStyles.mono12(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _WageMixDivider extends StatelessWidget {
  const _WageMixDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(height: 1, color: AppColors.borderSubtle),
    );
  }
}

class _WageMixWarningBand extends StatelessWidget {
  final String text;
  const _WageMixWarningBand({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.warning, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: AppTextStyles.body13(color: AppColors.warning)),
          ),
        ],
      ),
    );
  }
}

class _WageMixBucketCard extends StatelessWidget {
  final String header;
  final List<WageRoleRow> rows;
  final String? helper;
  const _WageMixBucketCard({
    required this.header,
    required this.rows,
    this.helper,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(width: 3, height: 14, color: AppColors.sunset),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(header,
                      style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${rows.length}',
                      style: AppTextStyles.mono10(color: AppColors.textMuted)),
                ),
              ],
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(helper!,
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text('No roles yet.',
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                children: [
                  for (int i = 0; i < rows.length; i++) ...[
                    if (i > 0)
                      Container(
                        height: 1,
                        color: AppColors.borderSubtle.withValues(alpha: 0.5),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: Text(rows[i].roleName,
                                style: AppTextStyles.mono12(
                                    color: AppColors.textPrimary)),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '\$${rows[i].hourlyRate.toStringAsFixed(2)}',
                              style: AppTextStyles.mono12(
                                  color: AppColors.textPrimary),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${rows[i].weightedHours.toStringAsFixed(0)} h',
                              style: AppTextStyles.mono11(
                                  color: AppColors.textSecondary),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _WageMixPrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WageMixPrimaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.sunset, AppColors.sunsetDark],
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppColors.backgroundDeep),
            const SizedBox(width: 10),
            Text(label,
                style: AppTextStyles.mono14(
                    color: AppColors.backgroundDeep,
                    weight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _WageMixSecondaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WageMixSecondaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
              color: AppColors.sunset.withValues(alpha: 0.6), width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: AppColors.sunset),
            const SizedBox(width: 8),
            Text(label,
                style: AppTextStyles.mono12(color: AppColors.sunset)),
          ],
        ),
      ),
    );
  }
}
