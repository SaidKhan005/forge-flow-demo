import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_data_status_service.dart';
import '../data/app_refresh_coordinator.dart';
import '../data/restaurant_scope_notifier.dart';
import '../data/shift_service.dart';
import '../models/app_data_status.dart';
import '../theme/app_theme.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';

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
              child: SettingsRestaurantHero(name: restaurantDisplayName),
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
                  child: SettingsDataStatusSection(status: _status),
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
                  child: SettingsMockReplaySection(
                    mockReplayDate: () => _mockReplayDate,
                    onAfterWrite: _refreshAfterWrite,
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
                  child: SettingsDataManagementSection(
                    onAfterWrite: _refreshAfterWrite,
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
                    child: TimingAuthoritySection(
                      restaurantId: restaurant.restaurantId,
                    ),
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
                  child: WageAuthoritySection(onChanged: _refreshAppState),
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
                  child: SettingsAuditSection(),
                ),
              ),
            ],
          ),

          // ── Footer ───────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
              child: SettingsFooter(restaurantName: restaurantDisplayName),
            ),
          ),
        ],
      ),
    );
  }
}
