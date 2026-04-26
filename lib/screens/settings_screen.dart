import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/advisor_corpus_admin_service.dart';
import '../services/advisor_model_config_service.dart';
import '../services/app_data_status_service.dart';
import '../state/app_refresh_coordinator.dart';
import '../state/restaurant_scope_notifier.dart';
import '../services/shift_service.dart';
import '../models/app_data_status.dart';
import '../theme/app_theme.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_advisor_corpus_section.dart';
import 'settings/settings_advisor_model_section.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';

class SettingsScreen extends StatefulWidget {
  /// Optional injected status for testability. When null, loads from service.
  final AppDataStatus? initialStatus;

  /// Optional injected mock replay date for testability.
  final String? initialMockDate;

  /// Optional injected advisor model config service for testability.
  /// When null, the dev-only `ADVISOR MODELS` section constructs its
  /// own service with default loaders. Tests pass a fake-backed service
  /// + force the section to render via [forceShowAdvisorModelSection].
  final AdvisorModelConfigService? advisorModelConfigService;

  /// Test-only override: when true, the `ADVISOR MODELS` section
  /// renders even outside `kDebugMode`. Production code never sets
  /// this; in release builds the section is gated by
  /// `advisorModelSectionEnabled`.
  final bool forceShowAdvisorModelSection;

  /// Optional injected advisor corpus admin service for testability.
  /// When null, the dev-only `ADVISOR CORPUS` section is hidden unless
  /// the test-only force flag below is set. Tests pass a service
  /// directly; debug builds wire one in their app shell to opt in.
  final AdvisorCorpusAdminService? advisorCorpusAdminService;

  /// Test-only override: when true, the `ADVISOR CORPUS` section
  /// renders even outside `kDebugMode`. Production code never sets
  /// this; in release builds the section is gated by
  /// `advisorCorpusSectionEnabled`.
  final bool forceShowAdvisorCorpusSection;

  const SettingsScreen({
    super.key,
    this.initialStatus,
    this.initialMockDate,
    this.advisorModelConfigService,
    this.forceShowAdvisorModelSection = false,
    this.advisorCorpusAdminService,
    this.forceShowAdvisorCorpusSection = false,
  });

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

          // ── ADVISOR MODELS (dev-only) ────────────────────────────────
          // Visibility:
          //   * forceShowAdvisorModelSection (test-only override), OR
          //   * kDebugMode AND a config service is explicitly wired.
          //
          // Production debug builds wire `advisorModelConfigService` in
          // their app shell to opt in. Tests must pass both the service
          // and (optionally) the force flag — this keeps the section
          // out of test scenarios that haven't initialized
          // SharedPreferences.
          if (widget.forceShowAdvisorModelSection ||
              (advisorModelSectionEnabled &&
                  widget.advisorModelConfigService != null))
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('ADVISOR MODELS'),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SettingsAdvisorModelSection(
                      service: widget.advisorModelConfigService ??
                          AdvisorModelConfigService(),
                    ),
                  ),
                ),
              ],
            ),

          // ── ADVISOR CORPUS (dev-only) ────────────────────────────────
          // Visibility:
          //   * forceShowAdvisorCorpusSection (test-only override), OR
          //   * kDebugMode AND a corpus admin service is explicitly
          //     wired.
          //
          // Local-only scaffold. Cloud apply remains blocked until the
          // 11a.11b prerequisites land. Tests pass both the service
          // and (optionally) the force flag — keeps this surface out
          // of every default Settings smoke test.
          if (widget.forceShowAdvisorCorpusSection ||
              (advisorCorpusSectionEnabled &&
                  widget.advisorCorpusAdminService != null))
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: StickySectionDelegate('ADVISOR CORPUS'),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SettingsAdvisorCorpusSection(
                      service: widget.advisorCorpusAdminService ??
                          AdvisorCorpusAdminService(),
                    ),
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
