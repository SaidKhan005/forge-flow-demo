import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../auth/auth_session.dart';
import '../models/app_data_status.dart';
import '../services/advisor_corpus_admin_service.dart';
import '../services/advisor_model_config_service.dart';
import '../services/app_data_status_service.dart';
import '../services/auth/account_info_gateway.dart';
import '../services/auth/auth_operations_gateway.dart';
import '../services/auth/password_change_gateway.dart';
import '../services/mfa/mfa_operations_gateway.dart';
import '../services/shift_service.dart';
import '../services/team/team_invite_form_controller.dart';
import '../services/team/team_scope_visibility_policy.dart';
import '../services/team/team_users_list_controller.dart';
import '../state/app_refresh_coordinator.dart';
import '../state/auth_session_notifier.dart';
import '../state/restaurant_scope_notifier.dart';
import '../theme/app_theme.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_active_sessions_section.dart';
import 'settings/settings_advisor_corpus_section.dart';
import 'settings/settings_audit_log_section.dart';
import 'settings/settings_advisor_model_section.dart';
import 'settings/settings_custom_roles_section.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_mfa_section.dart';
import 'settings/settings_org_hierarchy_section.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';
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
  final List<TeamOrgUnitOption> teamOrgUnitOptions;
  final List<TeamOrgUnitEntry> teamOrgUnits;
  final List<TeamOrgLocationEntry> teamOrgLocations;
  final TeamOrgHierarchyLoadState teamOrgHierarchyLoadState;

  /// Phase 9.UX.4 — when the live gateway resolves after navigation
  /// or a create/move callback updates state, the open Settings route
  /// has no rebuild trigger from the plain list snapshots above. The
  /// listenables bridge that gap. Plain lists stay as the seed value
  /// so widget tests without a listenable can still render.
  final ValueListenable<List<TeamOrgUnitEntry>>? teamOrgUnitsListenable;
  final ValueListenable<List<TeamOrgLocationEntry>>? teamOrgLocationsListenable;
  final ValueListenable<List<TeamOrgUnitOption>>? teamOrgUnitOptionsListenable;
  final ValueListenable<TeamOrgHierarchyLoadState>?
  teamOrgHierarchyLoadStateListenable;
  final TeamOrgUnitCreateRequester? onTeamOrgUnitCreate;
  final TeamLocationOrgUnitMoveRequester? onTeamLocationMove;
  final List<TeamPendingInviteListItem> teamPendingInvites;
  final TeamInviteSubmitter? onTeamInviteSubmitted;
  final TeamInviteRevoker? onTeamInviteRevoked;
  final TeamUserActionHandler? onTeamUserAction;
  final TeamDataRetryRequester? onTeamDataRetry;
  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final TeamSettingsDataLoadState teamDataLoadState;
  final ValueListenable<List<TeamRoleOption>>? teamRoleOptionsListenable;
  final ValueListenable<List<TeamUserListItem>>? teamUsersListenable;
  final ValueListenable<List<TeamPendingInviteListItem>>?
  teamPendingInvitesListenable;
  final ValueListenable<TeamSettingsDataLoadState>? teamDataLoadStateListenable;
  final MfaOperationsGateway? mfaOperationsGateway;
  final MfaActorContext? mfaActor;

  /// Phase 9.UX.5 — self-service Active Sessions surface in the
  /// Account tab. Production passes the proxy-backed gateway; demo /
  /// preview shells set [allowDemoActiveSessionsFallback] so the
  /// walkthrough click path completes without a backend.
  final AuthOperationsGateway? authOperationsGateway;
  final ActiveSessionsActor? activeSessionsActor;
  final bool allowDemoActiveSessionsFallback;

  /// Phase 9.UX.6 — self-service Audit Log surface in the Account
  /// tab. Reuses [authOperationsGateway] when null. The actor falls
  /// back to the auth session notifier in scope.
  final AuditLogActor? auditLogActor;
  final bool allowDemoAuditLogFallback;

  /// Phase 9.UX.2 — operator role catalog (seeded + custom). Seed
  /// snapshot used for first paint; the listenable bridge updates the
  /// open Settings route when the live gateway resolves or a save
  /// callback mutates the catalog.
  final List<TeamRoleCatalogEntry> teamRoleCatalog;
  final ValueListenable<List<TeamRoleCatalogEntry>>? teamRoleCatalogListenable;
  final SettingsRoleCreateRequester? onTeamRoleCreate;
  final SettingsRolePatchRequester? onTeamRolePatch;
  final SettingsRoleDeleteRequester? onTeamRoleDelete;

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
    this.teamOrgUnitOptions = const <TeamOrgUnitOption>[],
    this.teamOrgUnits = const <TeamOrgUnitEntry>[],
    this.teamOrgLocations = const <TeamOrgLocationEntry>[],
    this.teamOrgHierarchyLoadState = TeamOrgHierarchyLoadState.ready,
    this.teamOrgUnitsListenable,
    this.teamOrgLocationsListenable,
    this.teamOrgUnitOptionsListenable,
    this.teamOrgHierarchyLoadStateListenable,
    this.onTeamOrgUnitCreate,
    this.onTeamLocationMove,
    this.teamPendingInvites = const <TeamPendingInviteListItem>[],
    this.onTeamInviteSubmitted,
    this.onTeamInviteRevoked,
    this.onTeamUserAction,
    this.onTeamDataRetry,
    this.accountInfoGateway,
    this.passwordChangeGateway,
    this.teamDataLoadState = TeamSettingsDataLoadState.ready,
    this.teamRoleOptionsListenable,
    this.teamUsersListenable,
    this.teamPendingInvitesListenable,
    this.teamDataLoadStateListenable,
    this.mfaOperationsGateway,
    this.mfaActor,
    this.authOperationsGateway,
    this.activeSessionsActor,
    this.allowDemoActiveSessionsFallback = false,
    this.auditLogActor,
    this.allowDemoAuditLogFallback = false,
    this.teamRoleCatalog = const <TeamRoleCatalogEntry>[],
    this.teamRoleCatalogListenable,
    this.onTeamRoleCreate,
    this.onTeamRolePatch,
    this.onTeamRoleDelete,
    this.forceShowTeamSection = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppDataStatus? _status;
  String? _mockReplayDate;
  int _manualRefreshGeneration = 0;
  bool _manualRefreshing = false;

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

  Future<void> _handlePullToRefresh() async {
    if (_manualRefreshing) return;
    setState(() {
      _manualRefreshing = true;
      _manualRefreshGeneration += 1;
    });
    try {
      await _refreshAppState();
      await widget.onTeamDataRetry?.call();
    } finally {
      if (mounted) setState(() => _manualRefreshing = false);
    }
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
    final authNotifier = context.watch<AuthSessionNotifier?>();
    final session = authNotifier?.session;
    final showAccount = session != null;
    final showAdvisorModels =
        widget.forceShowAdvisorModelSection ||
        (advisorModelSectionEnabled &&
            widget.advisorModelConfigService != null);
    final showAdvisorCorpus =
        widget.forceShowAdvisorCorpusSection ||
        (advisorCorpusSectionEnabled &&
            widget.advisorCorpusAdminService != null);
    final effectiveTeamActor =
        widget.teamActor ??
        (widget.forceShowTeamSection ? _debugTeamActor : null);
    final showTeam =
        effectiveTeamActor != null &&
        (widget.forceShowTeamSection ||
            TeamScopeVisibilityPolicy.canSeeTeamNav(effectiveTeamActor));
    // Non-admin signed-in users see only the Account tab. Admin tier
    // (operator_owner / operator_manager / super_admin / ff_support)
    // sees the rest. The gate is opt-in: a null teamActor (e.g.
    // demo / unauth flows or pre-Phase-9 test setups) keeps admin
    // tabs visible. Once the Phase 9 permission snapshot bridge
    // populates teamActor in production, non-admin roles will
    // collapse to Account-only automatically.
    final showAdminTabs =
        !showAccount ||
        effectiveTeamActor == null ||
        _isAdminTier(effectiveTeamActor);
    final tabs = <_SettingsTabSpec>[
      if (showAccount) _accountSettingsTab,
      if (showTeam) _teamSettingsTab,
      if (showAdminTabs) _authoritySettingsTab,
      if (showAdminTabs) _dataSettingsTab,
      if (showAdminTabs) _developerSettingsTab,
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
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Text('Settings', style: AppTextStyles.display20()),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.close, size: 28),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: TabBarView(
          children: [
            if (showAccount)
              _SettingsTabScrollView(
                tabId: 'account',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  _settingsSection(
                    title: 'Two-factor security',
                    child: SettingsMfaSection(
                      gateway: widget.mfaOperationsGateway,
                      actor:
                          widget.mfaActor ??
                          _mfaActorForSession(
                            session,
                            restaurant?.restaurantId,
                          ),
                    ),
                  ),
                  _settingsSection(
                    title: 'Account',
                    child: SettingsAccountSection(
                      accountInfoGateway: widget.accountInfoGateway,
                      passwordChangeGateway: widget.passwordChangeGateway,
                      refreshGeneration: _manualRefreshGeneration,
                    ),
                  ),
                  _settingsSection(
                    title: 'Active sessions',
                    child: SettingsActiveSessionsSection(
                      gateway: widget.authOperationsGateway,
                      actor:
                          widget.activeSessionsActor ??
                          _activeSessionsActorForSession(
                            session,
                            authNotifier?.activeSessionId,
                          ),
                      allowDemoGatewayFallback:
                          widget.allowDemoActiveSessionsFallback,
                      refreshGeneration: _manualRefreshGeneration,
                      onSignOutAllDevices: () async {
                        await authNotifier?.signOutAllSessions();
                      },
                    ),
                  ),
                  _settingsSection(
                    title: 'Audit log',
                    child: SettingsAuditLogSection(
                      gateway: widget.authOperationsGateway,
                      actor:
                          widget.auditLogActor ??
                          _auditLogActorForSession(session),
                      allowDemoGatewayFallback:
                          widget.allowDemoAuditLogFallback,
                      refreshGeneration: _manualRefreshGeneration,
                    ),
                  ),
                ],
              ),
            if (showTeam)
              _SettingsTabScrollView(
                tabId: 'team',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  SliverToBoxAdapter(
                    child: _TeamSettingsLiveDataScope(
                      roleOptions: widget.teamRoleOptions,
                      roleOptionsListenable: widget.teamRoleOptionsListenable,
                      users: widget.teamUsers,
                      usersListenable: widget.teamUsersListenable,
                      pendingInvites: widget.teamPendingInvites,
                      pendingInvitesListenable:
                          widget.teamPendingInvitesListenable,
                      dataLoadState: widget.teamDataLoadState,
                      dataLoadStateListenable:
                          widget.teamDataLoadStateListenable,
                      builder:
                          (roleOptions, users, pendingInvites, dataLoadState) =>
                              _OrgUnitOptionsListenableScope(
                                seed: widget.teamOrgUnitOptions,
                                listenable: widget.teamOrgUnitOptionsListenable,
                                builder: (orgUnitOptions) =>
                                    _RoleCatalogToOptionsScope(
                                      fallback: roleOptions,
                                      catalogSeed: widget.teamRoleCatalog,
                                      catalogListenable:
                                          widget.teamRoleCatalogListenable,
                                      builder:
                                          (
                                            effectiveRoleOptions,
                                            effectiveRoleCatalog,
                                          ) => TeamSettingsSection(
                                            actor: effectiveTeamActor,
                                            users: users,
                                            roleOptions: effectiveRoleOptions,
                                            roleCatalog: effectiveRoleCatalog
                                                    .isEmpty
                                                ? widget.teamRoleCatalog
                                                : effectiveRoleCatalog,
                                            locationOptions:
                                                widget.teamLocationOptions,
                                            orgUnitOptions: orgUnitOptions,
                                            pendingInvites: pendingInvites,
                                            dataLoadState: dataLoadState,
                                            usersController:
                                                widget.teamUsersListController,
                                            inviteFormController:
                                                widget.teamInviteFormController,
                                            onInviteSubmitted:
                                                widget.onTeamInviteSubmitted,
                                            onInviteRevoked:
                                                widget.onTeamInviteRevoked,
                                            onUserAction:
                                                widget.onTeamUserAction,
                                            onDataRetry: widget.onTeamDataRetry,
                                          ),
                                    ),
                              ),
                    ),
                  ),
                  _settingsSection(
                    title: 'Org Hierarchy',
                    child: _OrgHierarchyListenableScope(
                      seedOrgUnits: widget.teamOrgUnits,
                      seedLocations: widget.teamOrgLocations,
                      orgUnitsListenable: widget.teamOrgUnitsListenable,
                      orgLocationsListenable: widget.teamOrgLocationsListenable,
                      loadState: widget.teamOrgHierarchyLoadState,
                      loadStateListenable:
                          widget.teamOrgHierarchyLoadStateListenable,
                      builder: (orgUnits, locations, loadState) =>
                          SettingsOrgHierarchySection(
                            actor: effectiveTeamActor,
                            orgUnits: orgUnits,
                            locations: locations,
                            loadState: loadState,
                            onCreateOrgUnit: widget.onTeamOrgUnitCreate,
                            onMoveLocation: widget.onTeamLocationMove,
                          ),
                    ),
                  ),
                  _settingsSection(
                    title: 'Roles',
                    child: _RoleCatalogListenableScope(
                      seed: widget.teamRoleCatalog,
                      listenable: widget.teamRoleCatalogListenable,
                      builder: (catalog) => SettingsCustomRolesSection(
                        actor: effectiveTeamActor,
                        roleCatalog: catalog,
                        onCreateRole: widget.onTeamRoleCreate,
                        onPatchRole: widget.onTeamRolePatch,
                        onDeleteRole: widget.onTeamRoleDelete,
                      ),
                    ),
                  ),
                ],
              ),
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'authority',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  if (restaurant == null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 24,
                        ),
                        child: _SettingsEmptyNotice(
                          icon: Icons.storefront_outlined,
                          title: 'No restaurant selected',
                          description:
                              'Pick a restaurant to configure timing and wage authority.',
                        ),
                      ),
                    ),
                  if (restaurant != null)
                    _settingsSection(
                      title: 'Timing authority',
                      child: TimingAuthoritySection(
                        restaurantId: restaurant.restaurantId,
                      ),
                    ),
                  _settingsSection(
                    title: 'Wage authority',
                    child: WageAuthoritySection(onChanged: _refreshAppState),
                  ),
                ],
              ),
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'data',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  _settingsSection(
                    title: 'Data status',
                    child: SettingsDataStatusSection(status: _status),
                  ),
                  _settingsSection(
                    title: 'Data management',
                    child: SettingsDataManagementSection(
                      onAfterWrite: _refreshAfterWrite,
                    ),
                  ),
                  if (kDebugMode)
                    _settingsSection(
                      title: 'Mock replay',
                      child: SettingsMockReplaySection(
                        mockReplayDate: () => _mockReplayDate,
                        onAfterWrite: _refreshAfterWrite,
                      ),
                    ),
                ],
              ),
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'developer',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  _settingsSection(
                    title: 'Audit',
                    child: const SettingsAuditSection(),
                  ),
                  if (showAdvisorModels)
                    _settingsSection(
                      title: 'Advisor models',
                      child: SettingsAdvisorModelSection(
                        service:
                            widget.advisorModelConfigService ??
                            AdvisorModelConfigService(),
                      ),
                    ),
                  if (showAdvisorCorpus)
                    _settingsSection(
                      title: 'Advisor corpus',
                      child: SettingsAdvisorCorpusSection(
                        service:
                            widget.advisorCorpusAdminService ??
                            AdvisorCorpusAdminService(),
                      ),
                    ),
                ],
              ),
          ],
        ),
        bottomNavigationBar: tabs.length >= 2
            ? _SettingsBottomNav(tabs: tabs)
            : null,
      ),
    );
  }
}

/// Tabs other than Account are only visible to admin-tier roles.
/// Operator owners, operator managers, super_admin, and ff_support
/// qualify. operator_supervisor / operator_staff / null actors do not.
bool _isAdminTier(TeamScopeActor? actor) {
  if (actor == null) return false;
  return actor.actorRoles.contains('operator_owner') ||
      actor.actorRoles.contains('operator_manager') ||
      actor.actorRoles.contains('super_admin') ||
      actor.actorRoles.contains('ff_support');
}

ActiveSessionsActor _activeSessionsActorForSession(
  AuthSession session,
  String? activeSessionId,
) {
  return ActiveSessionsActor(
    actorUserId: session.userId,
    operatorId: session.operatorId,
    locationId: session.locationId,
    currentSessionId: activeSessionId,
  );
}

AuditLogActor _auditLogActorForSession(AuthSession session) {
  return AuditLogActor(
    actorUserId: session.userId,
    operatorId: session.operatorId,
    locationId: session.locationId,
  );
}

MfaActorContext _mfaActorForSession(
  AuthSession session,
  String? notificationRestaurantId,
) {
  return MfaActorContext(
    actorUserId: session.userId,
    operatorId: session.operatorId,
    locationId: session.locationId,
    userEmail: _mfaEmailForSession(session),
    authorizationIdToken: session.firebaseIdToken,
    notificationRestaurantId: notificationRestaurantId,
  );
}

String _mfaEmailForSession(AuthSession session) {
  final token = session.firebaseIdToken;
  final parts = token.split('.');
  if (parts.length < 2) return session.userId;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final json = jsonDecode(payload);
    if (json is Map) {
      final email = json['email'];
      if (email is String && email.trim().isNotEmpty) return email.trim();
    }
  } catch (_) {
    // Token verification happens server-side. This local decode is only for
    // the authenticator app label, so malformed payloads fall back quietly.
  }
  return session.userId;
}

const _SettingsTabSpec _accountSettingsTab = _SettingsTabSpec(
  id: 'account',
  label: 'Account',
  icon: Icons.person_outline,
);

const _SettingsTabSpec _teamSettingsTab = _SettingsTabSpec(
  id: 'team',
  label: 'Team',
  icon: Icons.group_outlined,
);

const _SettingsTabSpec _authoritySettingsTab = _SettingsTabSpec(
  id: 'authority',
  label: 'Authority',
  icon: Icons.tune_rounded,
);

const _SettingsTabSpec _dataSettingsTab = _SettingsTabSpec(
  id: 'data',
  label: 'Data',
  icon: Icons.storage_rounded,
);

const _SettingsTabSpec _developerSettingsTab = _SettingsTabSpec(
  id: 'developer',
  label: 'Dev',
  icon: Icons.terminal_rounded,
);

const TeamScopeActor _debugTeamActor = TeamScopeActor(
  actorRoles: <String>{'operator_owner'},
  actorOperatorId: 'debug-operator',
  actorAssignedLocationIds: <String>{},
  actorPermissions: <String>{
    'team.users.view',
    'team.users.invite',
    'team.users.deactivate',
    'team.users.reactivate',
    'team.users.soft_delete',
    'team.users.reset_password',
    'team.users.reset_mfa',
    'team.roles.view',
    'team.roles.create_custom',
    'team.roles.assign',
    'team.roles.revoke',
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

class _TeamSettingsLiveDataScope extends StatelessWidget {
  const _TeamSettingsLiveDataScope({
    required this.roleOptions,
    required this.users,
    required this.pendingInvites,
    required this.dataLoadState,
    required this.builder,
    this.roleOptionsListenable,
    this.usersListenable,
    this.pendingInvitesListenable,
    this.dataLoadStateListenable,
  });

  final List<TeamRoleOption> roleOptions;
  final List<TeamUserListItem> users;
  final List<TeamPendingInviteListItem> pendingInvites;
  final TeamSettingsDataLoadState dataLoadState;
  final ValueListenable<List<TeamRoleOption>>? roleOptionsListenable;
  final ValueListenable<List<TeamUserListItem>>? usersListenable;
  final ValueListenable<List<TeamPendingInviteListItem>>?
  pendingInvitesListenable;
  final ValueListenable<TeamSettingsDataLoadState>? dataLoadStateListenable;
  final Widget Function(
    List<TeamRoleOption> roleOptions,
    List<TeamUserListItem> users,
    List<TeamPendingInviteListItem> pendingInvites,
    TeamSettingsDataLoadState dataLoadState,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    Widget withLoadState(
      List<TeamRoleOption> roleValue,
      List<TeamUserListItem> userValue,
      List<TeamPendingInviteListItem> inviteValue,
    ) {
      final listenable = dataLoadStateListenable;
      if (listenable == null) {
        return builder(roleValue, userValue, inviteValue, dataLoadState);
      }
      return ValueListenableBuilder<TeamSettingsDataLoadState>(
        valueListenable: listenable,
        builder: (context, loadState, _) =>
            builder(roleValue, userValue, inviteValue, loadState),
      );
    }

    Widget withInvites(
      List<TeamRoleOption> roleValue,
      List<TeamUserListItem> userValue,
    ) {
      final listenable = pendingInvitesListenable;
      if (listenable == null) {
        return withLoadState(roleValue, userValue, pendingInvites);
      }
      return ValueListenableBuilder<List<TeamPendingInviteListItem>>(
        valueListenable: listenable,
        builder: (context, inviteValue, _) =>
            withLoadState(roleValue, userValue, inviteValue),
      );
    }

    Widget withUsers(List<TeamRoleOption> roleValue) {
      final listenable = usersListenable;
      if (listenable == null) return withInvites(roleValue, users);
      return ValueListenableBuilder<List<TeamUserListItem>>(
        valueListenable: listenable,
        builder: (context, userValue, _) => withInvites(roleValue, userValue),
      );
    }

    final listenable = roleOptionsListenable;
    if (listenable == null) return withUsers(roleOptions);
    return ValueListenableBuilder<List<TeamRoleOption>>(
      valueListenable: listenable,
      builder: (context, roleValue, _) {
        return withUsers(roleValue);
      },
    );
  }
}

class _OrgUnitOptionsListenableScope extends StatelessWidget {
  const _OrgUnitOptionsListenableScope({
    required this.seed,
    required this.listenable,
    required this.builder,
  });

  final List<TeamOrgUnitOption> seed;
  final ValueListenable<List<TeamOrgUnitOption>>? listenable;
  final Widget Function(List<TeamOrgUnitOption> orgUnitOptions) builder;

  @override
  Widget build(BuildContext context) {
    final l = listenable;
    if (l == null) return builder(seed);
    return ValueListenableBuilder<List<TeamOrgUnitOption>>(
      valueListenable: l,
      builder: (context, value, _) => builder(value),
    );
  }
}

class _RoleCatalogListenableScope extends StatelessWidget {
  const _RoleCatalogListenableScope({
    required this.seed,
    required this.listenable,
    required this.builder,
  });

  final List<TeamRoleCatalogEntry> seed;
  final ValueListenable<List<TeamRoleCatalogEntry>>? listenable;
  final Widget Function(List<TeamRoleCatalogEntry> catalog) builder;

  @override
  Widget build(BuildContext context) {
    final l = listenable;
    if (l == null) return builder(seed);
    return ValueListenableBuilder<List<TeamRoleCatalogEntry>>(
      valueListenable: l,
      builder: (context, value, _) => builder(value),
    );
  }
}

/// Phase 9.UX.2 — bridges the role catalog into
/// [TeamSettingsSection.roleOptions]. When the catalog has entries,
/// it is the source of truth for invite + role-grant role pickers
/// (a custom role created on the Roles surface must be grantable
/// without reopening Settings, per slice acceptance). When empty, the
/// adapter falls back to whatever [_TeamSettingsLiveDataScope] passed
/// in — keeping the legacy `teamRoleOptions` /
/// `teamRoleOptionsListenable` wiring intact for app shells that have
/// not yet plumbed the catalog listenable.
class _RoleCatalogToOptionsScope extends StatelessWidget {
  const _RoleCatalogToOptionsScope({
    required this.fallback,
    required this.catalogSeed,
    required this.catalogListenable,
    required this.builder,
  });

  final List<TeamRoleOption> fallback;
  final List<TeamRoleCatalogEntry> catalogSeed;
  final ValueListenable<List<TeamRoleCatalogEntry>>? catalogListenable;
  final Widget Function(
    List<TeamRoleOption> options,
    List<TeamRoleCatalogEntry> catalog,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    Widget resolve(List<TeamRoleCatalogEntry> catalog) {
      if (catalog.isEmpty) return builder(fallback, catalog);
      return builder(_optionsFromCatalog(catalog), catalog);
    }

    final l = catalogListenable;
    if (l == null) return resolve(catalogSeed);
    return ValueListenableBuilder<List<TeamRoleCatalogEntry>>(
      valueListenable: l,
      builder: (context, value, _) => resolve(value),
    );
  }

  static List<TeamRoleOption> _optionsFromCatalog(
    List<TeamRoleCatalogEntry> catalog,
  ) {
    return List<TeamRoleOption>.unmodifiable(
      catalog.map(
        (entry) =>
            TeamRoleOption(roleId: entry.roleId, label: entry.displayName),
      ),
    );
  }
}

class _OrgHierarchyListenableScope extends StatelessWidget {
  const _OrgHierarchyListenableScope({
    required this.seedOrgUnits,
    required this.seedLocations,
    required this.orgUnitsListenable,
    required this.orgLocationsListenable,
    required this.loadState,
    required this.loadStateListenable,
    required this.builder,
  });

  final List<TeamOrgUnitEntry> seedOrgUnits;
  final List<TeamOrgLocationEntry> seedLocations;
  final ValueListenable<List<TeamOrgUnitEntry>>? orgUnitsListenable;
  final ValueListenable<List<TeamOrgLocationEntry>>? orgLocationsListenable;
  final TeamOrgHierarchyLoadState loadState;
  final ValueListenable<TeamOrgHierarchyLoadState>? loadStateListenable;
  final Widget Function(
    List<TeamOrgUnitEntry> orgUnits,
    List<TeamOrgLocationEntry> locations,
    TeamOrgHierarchyLoadState loadState,
  )
  builder;

  @override
  Widget build(BuildContext context) {
    Widget withLoadState(
      List<TeamOrgUnitEntry> units,
      List<TeamOrgLocationEntry> locations,
    ) {
      final l = loadStateListenable;
      if (l == null) return builder(units, locations, loadState);
      return ValueListenableBuilder<TeamOrgHierarchyLoadState>(
        valueListenable: l,
        builder: (context, value, _) => builder(units, locations, value),
      );
    }

    Widget withLocations(List<TeamOrgUnitEntry> units) {
      final l = orgLocationsListenable;
      if (l == null) return withLoadState(units, seedLocations);
      return ValueListenableBuilder<List<TeamOrgLocationEntry>>(
        valueListenable: l,
        builder: (context, value, _) => withLoadState(units, value),
      );
    }

    final units = orgUnitsListenable;
    if (units == null) return withLocations(seedOrgUnits);
    return ValueListenableBuilder<List<TeamOrgUnitEntry>>(
      valueListenable: units,
      builder: (context, value, _) => withLocations(value),
    );
  }
}

class _SettingsBottomNav extends StatelessWidget {
  final List<_SettingsTabSpec> tabs;

  const _SettingsBottomNav({required this.tabs});

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.borderSubtle, width: 1),
            ),
          ),
          child: BottomNavigationBar(
            currentIndex: controller.index,
            onTap: controller.animateTo,
            backgroundColor: AppColors.backgroundDeep,
            selectedItemColor: AppColors.sunsetDark,
            unselectedItemColor: AppColors.textMuted,
            type: BottomNavigationBarType.fixed,
            elevation: 0,
            selectedLabelStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.5,
            ),
            items: [
              for (final tab in tabs)
                BottomNavigationBarItem(
                  icon: KeyedSubtree(
                    key: Key('settings_tab_${tab.id}'),
                    child: Icon(tab.icon, size: 22),
                  ),
                  label: tab.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsTabScrollView extends StatelessWidget {
  final String tabId;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;

  const _SettingsTabScrollView({
    required this.tabId,
    required this.slivers,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator.adaptive(
      onRefresh: onRefresh ?? () async {},
      child: CustomScrollView(
        key: PageStorageKey<String>('settings_${tabId}_scroll'),
        cacheExtent: 9999,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }
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

class _SettingsEmptyNotice extends StatelessWidget {
  const _SettingsEmptyNotice({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.4),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: AppColors.sunsetDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
