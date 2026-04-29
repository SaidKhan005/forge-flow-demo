import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_data_status.dart';
import '../services/advisor_corpus_admin_service.dart';
import '../services/advisor_model_config_service.dart';
import '../services/app_data_status_service.dart';
import '../services/shift_service.dart';
import '../services/team/team_invite_form_controller.dart';
import '../services/team/team_scope_visibility_policy.dart';
import '../services/team/team_users_list_controller.dart';
import '../state/app_refresh_coordinator.dart';
import '../state/restaurant_scope_notifier.dart';
import '../theme/app_theme.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_advisor_corpus_section.dart';
import 'settings/settings_advisor_model_section.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';
import 'team/team_settings_entrypoint.dart';
import 'team/team_settings_section.dart';

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

  /// Team Settings actor snapshot. Production passes this once the
  /// Phase 9 permission snapshot bridge carries role + location scope.
  /// Null means the Team tab stays hidden.
  final TeamScopeActor? teamActor;

  /// Test/dev hooks for the Team settings surface. Production leaves
  /// these null until the proxy endpoints bind to the controllers.
  final TeamUsersListController? teamUsersListController;
  final TeamInviteFormController? teamInviteFormController;
  final List<TeamUserListItem> teamUsers;
  final List<TeamRoleOption> teamRoleOptions;
  final List<TeamLocationOption> teamLocationOptions;
  final TeamInviteSubmitter? onTeamInviteSubmitted;

  /// Test-only override: when true, renders Team with an owner-shaped
  /// actor even when no runtime actor snapshot is installed.
  final bool forceShowTeamSection;

  const SettingsScreen({
    super.key,
    this.initialStatus,
    this.initialMockDate,
    this.advisorModelConfigService,
    this.forceShowAdvisorModelSection = false,
    this.advisorCorpusAdminService,
    this.forceShowAdvisorCorpusSection = false,
    this.teamActor,
    this.teamUsersListController,
    this.teamInviteFormController,
    this.teamUsers = const <TeamUserListItem>[],
    this.teamRoleOptions = TeamSettingsSection.defaultRoleOptions,
    this.teamLocationOptions = const <TeamLocationOption>[],
    this.onTeamInviteSubmitted,
    this.forceShowTeamSection = false,
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
      // Coordinator may not be in scope during widget tests.
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
      // Coordinator may not be in scope during widget tests.
    }
    await _loadStatus();
    await _loadMockDate();
  }

  @override
  Widget build(BuildContext context) {
    final restaurant = context.watch<RestaurantScopeNotifier?>()?.restaurant;
    final restaurantDisplayName = restaurant?.displayName ?? 'Restaurant';
    final showAdvisorModels =
        widget.forceShowAdvisorModelSection ||
        (advisorModelSectionEnabled &&
            widget.advisorModelConfigService != null);
    final showAdvisorCorpus =
        widget.forceShowAdvisorCorpusSection ||
        (advisorCorpusSectionEnabled &&
            widget.advisorCorpusAdminService != null);
    final effectiveTeamActor =
        widget.teamActor ?? (widget.forceShowTeamSection ? _debugTeamActor : null);
    final showTeam =
        effectiveTeamActor != null &&
        (widget.forceShowTeamSection ||
            TeamScopeVisibilityPolicy.canSeeTeamNav(effectiveTeamActor));
    final tabs = <_SettingsTabSpec>[
      ..._baseSettingsTabs,
      if (showTeam) _teamSettingsTab,
      _developerSettingsTab,
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundDeep,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          titleSpacing: 4,
          title: Row(
            children: [
              ClipOval(
                child: Image.asset(
                  'assets/images/forge_flow_splash_icon.png',
                  width: 26,
                  height: 26,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 10),
              Text('Settings', style: AppTextStyles.display20()),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: _SettingsTabBar(tabs: tabs),
          ),
        ),
        body: TabBarView(
          children: [
            _SettingsTabScrollView(
              tabId: 'data',
              slivers: [
                _restaurantHeroSliver(restaurantDisplayName),
                _settingsSection(
                  title: 'DATA STATUS',
                  child: SettingsDataStatusSection(status: _status),
                ),
                _settingsSection(
                  title: 'DATA MANAGEMENT',
                  child: SettingsDataManagementSection(
                    onAfterWrite: _refreshAfterWrite,
                  ),
                ),
                _settingsSection(
                  title: 'MOCK REPLAY',
                  child: SettingsMockReplaySection(
                    mockReplayDate: () => _mockReplayDate,
                    onAfterWrite: _refreshAfterWrite,
                  ),
                ),
                _settingsFooterSliver(restaurantDisplayName),
              ],
            ),
            _SettingsTabScrollView(
              tabId: 'authority',
              slivers: [
                _restaurantHeroSliver(restaurantDisplayName),
                if (restaurant != null)
                  _settingsSection(
                    title: 'TIMING AUTHORITY',
                    child: TimingAuthoritySection(
                      restaurantId: restaurant.restaurantId,
                    ),
                  ),
                _settingsSection(
                  title: 'WAGE AUTHORITY',
                  child: WageAuthoritySection(onChanged: _refreshAppState),
                ),
                _settingsFooterSliver(restaurantDisplayName),
              ],
            ),
            if (showTeam)
              _SettingsTabScrollView(
                tabId: 'team',
                slivers: [
                  _restaurantHeroSliver(restaurantDisplayName),
                  _settingsSection(
                    title: 'TEAM',
                    child: TeamSettingsEntrypoint(
                      actor: effectiveTeamActor,
                      child: TeamSettingsSection(
                        actor: effectiveTeamActor,
                        users: widget.teamUsers,
                        roleOptions: widget.teamRoleOptions,
                        locationOptions: widget.teamLocationOptions,
                        usersController: widget.teamUsersListController,
                        inviteFormController: widget.teamInviteFormController,
                        onInviteSubmitted: widget.onTeamInviteSubmitted,
                      ),
                    ),
                  ),
                  _settingsFooterSliver(restaurantDisplayName),
                ],
              ),
            _SettingsTabScrollView(
              tabId: 'developer',
              slivers: [
                _restaurantHeroSliver(restaurantDisplayName),
                _settingsSection(
                  title: 'AUDIT',
                  child: const SettingsAuditSection(),
                ),
                if (showAdvisorModels)
                  _settingsSection(
                    title: 'ADVISOR MODELS',
                    child: SettingsAdvisorModelSection(
                      service:
                          widget.advisorModelConfigService ??
                          AdvisorModelConfigService(),
                    ),
                  ),
                if (showAdvisorCorpus)
                  _settingsSection(
                    title: 'ADVISOR CORPUS',
                    child: SettingsAdvisorCorpusSection(
                      service:
                          widget.advisorCorpusAdminService ??
                          AdvisorCorpusAdminService(),
                    ),
                  ),
                _settingsFooterSliver(restaurantDisplayName),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

const List<_SettingsTabSpec> _baseSettingsTabs = [
  _SettingsTabSpec(id: 'data', label: 'Data', icon: Icons.storage_rounded),
  _SettingsTabSpec(
    id: 'authority',
    label: 'Authority',
    icon: Icons.tune_rounded,
  ),
];

const _SettingsTabSpec _teamSettingsTab = _SettingsTabSpec(
  id: 'team',
  label: 'Team',
  icon: Icons.group_outlined,
);

const _SettingsTabSpec _developerSettingsTab = _SettingsTabSpec(
  id: 'developer',
  label: 'Developer',
  icon: Icons.terminal_rounded,
);

const TeamScopeActor _debugTeamActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'debug-operator',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.users.invite',
    'team.users.update',
    'team.roles.assign',
  },
);

class _SettingsTabSpec {
  final String id;
  final String label;
  final IconData icon;

  const _SettingsTabSpec({
    required this.id,
    required this.label,
    required this.icon,
  });
}

class _SettingsTabBar extends StatelessWidget {
  final List<_SettingsTabSpec> tabs;

  const _SettingsTabBar({required this.tabs});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      height: 44,
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: TabBar(
        isScrollable: false,
        labelStyle: AppTextStyles.mono12(color: AppColors.backgroundSurface),
        unselectedLabelStyle: AppTextStyles.mono12(color: AppColors.textMuted),
        labelColor: AppColors.backgroundSurface,
        unselectedLabelColor: AppColors.textMuted,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: const EdgeInsets.all(3),
        indicator: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.sunset, AppColors.sunsetDark],
          ),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: AppColors.sunset.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.all(Colors.transparent),
        tabs: [
          for (final tab in tabs)
            Tab(
              key: Key('settings_tab_${tab.id}'),
              height: 38,
              child: _SettingsTabLabel(tab: tab),
            ),
        ],
      ),
    );
  }
}

class _SettingsTabLabel extends StatelessWidget {
  final _SettingsTabSpec tab;

  const _SettingsTabLabel({required this.tab});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(tab.icon, size: 16),
        const SizedBox(width: 6),
        Flexible(
          child: Text(tab.label, overflow: TextOverflow.ellipsis, maxLines: 1),
        ),
      ],
    );
  }
}

class _SettingsTabScrollView extends StatelessWidget {
  final String tabId;
  final List<Widget> slivers;

  const _SettingsTabScrollView({required this.tabId, required this.slivers});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: PageStorageKey<String>('settings_${tabId}_scroll'),
      cacheExtent: 9999,
      slivers: slivers,
    );
  }
}

Widget _restaurantHeroSliver(String restaurantDisplayName) {
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SettingsRestaurantHero(name: restaurantDisplayName),
    ),
  );
}

Widget _settingsSection({required String title, required Widget child}) {
  return SliverMainAxisGroup(
    slivers: [
      SliverPersistentHeader(
        pinned: true,
        delegate: StickySectionDelegate(title),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: child,
        ),
      ),
    ],
  );
}

Widget _settingsFooterSliver(String restaurantDisplayName) {
  return SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
      child: SettingsFooter(restaurantName: restaurantDisplayName),
    ),
  );
}
