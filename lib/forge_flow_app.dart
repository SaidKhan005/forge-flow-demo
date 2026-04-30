import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth/auth_session.dart';
import 'auth/permission_effect.dart';
import 'services/advisor_corpus_admin_service.dart';
import 'services/advisor_model_config_service.dart';
import 'services/auth/auth_operations_gateway.dart';
import 'services/auth/password_change_gateway.dart';
import 'services/auth/proxy_permission_snapshot_loader.dart';
import 'services/business_date_authority_service.dart';
import 'services/mfa/mfa_operations_gateway.dart';
import 'services/mfa/mfa_recovery_request_gateway.dart';
import 'services/shift_data_source.dart';
import 'services/team/team_scope_visibility_policy.dart';
import 'state/active_target_profile_notifier.dart';
import 'state/app_refresh_coordinator.dart';
import 'state/app_runtime_invalidation_bus.dart';
import 'state/auth_session_notifier.dart';
import 'state/demand_forecast_context_notifier.dart';
import 'state/permission_context.dart';
import 'state/restaurant_scope_notifier.dart';
import 'services/auth/account_info_gateway.dart';
import 'state/schedule_distribution_weights_notifier.dart';
import 'state/shift_dashboard_notifier.dart';
import 'state/week_data_notifier.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'screens/baseline_tracker.dart';
import 'screens/auth/auth_permission_context_bridge.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/notifications_screen.dart';
import 'screens/schedule_builder.dart';
import 'screens/settings_screen.dart';
import 'screens/shift_dashboard.dart';
import 'screens/team/team_settings_section.dart';
import 'screens/variance_report.dart';
import 'services/current_state_boundary_monitor.dart';
import 'theme/app_theme.dart';

/// Shared Forge & Flow runtime that can run standalone or inside Barrio.
class ForgeFlowApp extends StatelessWidget {
  const ForgeFlowApp({
    super.key,
    this.requireAuth = false,
    this.permissionContextLoader,
    this.authOperationsGateway,
    this.accountInfoGateway,
    this.passwordChangeGateway,
    this.mfaOperationsGateway,
    this.mfaRecoveryRequestGateway,
  });

  final bool requireAuth;
  final PermissionContextLoader? permissionContextLoader;
  final AuthOperationsGateway? authOperationsGateway;
  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;
  final MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;

  @override
  Widget build(BuildContext context) {
    final shell = AppShell(
      permissionContextLoader: permissionContextLoader,
      authOperationsGateway: authOperationsGateway,
      accountInfoGateway: accountInfoGateway,
      passwordChangeGateway: passwordChangeGateway,
      mfaOperationsGateway: mfaOperationsGateway,
    );
    return ForgeFlowScope(
      child: MaterialApp(
        title: 'Forge & Flow',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: requireAuth
            ? AuthGate(
                mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
                authenticatedChild: AuthPermissionContextBridge(
                  permissionContextLoader: permissionContextLoader,
                  child: shell,
                ),
              )
            : shell,
      ),
    );
  }
}

class ForgeFlowScope extends StatelessWidget {
  final Widget child;

  const ForgeFlowScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RestaurantScopeNotifier>(
          create: (_) => RestaurantScopeNotifier(),
        ),
        Provider<ShiftDataSource>(create: (_) => const LiveShiftDataSource()),
        ChangeNotifierProvider<ActiveTargetProfileNotifier>(
          create: (_) => ActiveTargetProfileNotifier(),
        ),
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (ctx) => WeekDataNotifier(ctx.read<ShiftDataSource>()),
        ),
        ChangeNotifierProvider<ShiftDashboardNotifier>(
          create: (_) => ShiftDashboardNotifier(),
        ),
        // Phase 7.55i.1 — canonical demand forecast context from closed shifts.
        // Loads on creation; Schedule/Shift/Audit read .context for demand.
        ChangeNotifierProvider<DemandForecastContextNotifier>(
          create: (_) => DemandForecastContextNotifier(),
        ),
        // Phase 7.55e.4 — runtime distribution weights from closed shifts.
        // Loads on creation; Schedule reads .weights when building its notifier.
        ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>(
          create: (_) {
            final notifier = ScheduleDistributionWeightsNotifier(
              scopeRepo: SqliteRestaurantScopeRepository.instance,
              weekRepo: SqliteWeekRecordRepository.instance,
              shiftRepo: SqliteShiftRecordRepository.instance,
            );
            notifier
                .load(); // fire-and-forget; Schedule uses fallback until ready
            return notifier;
          },
        ),
        // Phase 7.55p.4b — runtime invalidation bus.
        // Singleton ChangeNotifier that fires when ShiftService write
        // paths complete. Exposed here so ProxyProvider2 can react.
        ChangeNotifierProvider<AppRuntimeInvalidationBus>.value(
          value: AppRuntimeInvalidationBus.instance,
        ),
        // Phase 7.55p.4a+4b — central refresh / invalidation policy.
        // ProxyProvider2: when EITHER ActiveTargetProfileNotifier changes
        // OR the runtime invalidation bus fires, the coordinator refreshes
        // current-state surfaces (week, shift) through one shared rule.
        ProxyProvider2<
          ActiveTargetProfileNotifier,
          AppRuntimeInvalidationBus,
          AppRefreshCoordinator
        >(
          create: (ctx) => AppRefreshCoordinator(
            restaurantScope: ctx.read<RestaurantScopeNotifier>(),
            activeTarget: ctx.read<ActiveTargetProfileNotifier>(),
            weekData: ctx.read<WeekDataNotifier>(),
            shiftDashboard: ctx.read<ShiftDashboardNotifier>(),
            demandForecast: ctx.read<DemandForecastContextNotifier>(),
            scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
          ),
          update: (ctx, targetNotifier, bus, previous) {
            previous!.refreshCurrentStateSurfaces();
            return previous;
          },
        ),
      ],
      child: child,
    );
  }
}

class AppShell extends StatefulWidget {
  final bool embeddedInBarrio;
  final PermissionContextLoader? permissionContextLoader;
  final AuthOperationsGateway? authOperationsGateway;
  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;

  /// Test-only: override business-date resolution for the boundary
  /// monitor. When provided, the monitor uses this resolver instead
  /// of [BusinessDateAuthorityService].
  @visibleForTesting
  final Future<String?> Function(DateTime)? testBusinessDateResolver;

  const AppShell({
    super.key,
    this.embeddedInBarrio = false,
    this.permissionContextLoader,
    this.authOperationsGateway,
    this.accountInfoGateway,
    this.passwordChangeGateway,
    this.mfaOperationsGateway,
    this.testBusinessDateResolver,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  List<TeamRoleOption> _teamRoleOptions =
      TeamSettingsSection.defaultRoleOptions;
  late final ValueNotifier<List<TeamRoleOption>> _teamRoleOptionsListenable =
      ValueNotifier<List<TeamRoleOption>>(_teamRoleOptions);
  List<TeamUserListItem> _teamUsers = const <TeamUserListItem>[];
  late final ValueNotifier<List<TeamUserListItem>> _teamUsersListenable =
      ValueNotifier<List<TeamUserListItem>>(_teamUsers);
  List<TeamPendingInviteListItem> _teamPendingInvites =
      const <TeamPendingInviteListItem>[];
  late final ValueNotifier<List<TeamPendingInviteListItem>>
  _teamPendingInvitesListenable =
      ValueNotifier<List<TeamPendingInviteListItem>>(_teamPendingInvites);
  TeamSettingsDataLoadState _teamDataLoadState =
      TeamSettingsDataLoadState.unavailable;
  late final ValueNotifier<TeamSettingsDataLoadState>
  _teamDataLoadStateListenable = ValueNotifier<TeamSettingsDataLoadState>(
    _teamDataLoadState,
  );
  Map<String, String> _teamRoleIdsByKey = const <String, String>{};
  String? _teamRolesLoadedFor;
  String? _teamRolesLoadingFor;
  String? _teamDataLoadedFor;
  String? _teamDataLoadingFor;

  /// Tracks whether the app has been backgrounded at least once.
  /// Prevents the cold-start `resumed` callback from triggering a
  /// duplicate refresh — notifiers already load in their constructors.
  bool _hasBeenBackgrounded = false;

  /// Phase 7.55n.10: foreground-only business-date boundary monitor.
  /// Detects boundary changes while the app stays open and routes
  /// refresh through the shared coordinator seam.
  CurrentStateBoundaryMonitor? _boundaryMonitor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize boundary monitor after first frame when providers
    // are available in the widget tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBoundaryMonitor();
    });
  }

  /// Creates and starts the boundary monitor.
  ///
  /// Uses [widget.testBusinessDateResolver] when provided (tests),
  /// otherwise falls back to production
  /// [BusinessDateAuthorityService.resolveBusinessDate].
  void _initBoundaryMonitor() {
    if (!mounted) return;
    _boundaryMonitor = CurrentStateBoundaryMonitor(
      resolveBusinessDate:
          widget.testBusinessDateResolver ??
          BusinessDateAuthorityService.instance.resolveBusinessDate,
      onBoundaryChanged: () {
        if (mounted) {
          context.read<AppRefreshCoordinator>().refreshCurrentStateSurfaces();
        }
      },
    );
    _boundaryMonitor!.start();
  }

  @override
  void dispose() {
    _boundaryMonitor?.stop();
    _teamRoleOptionsListenable.dispose();
    _teamUsersListenable.dispose();
    _teamPendingInvitesListenable.dispose();
    _teamDataLoadStateListenable.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Phase 7.55n.9 + 7.55n.9a + 7.55n.10: revalidate current-state
  /// surfaces on app resume after real backgrounding, and manage the
  /// boundary monitor lifecycle.
  ///
  /// Routes through the shared [AppRefreshCoordinator] seam so the
  /// definition of "current-state surfaces" stays centralized.
  ///
  /// Guard logic:
  /// - `_hasBeenBackgrounded` is set to `true` on `paused`
  /// - `resumed` only refreshes when the flag is `true` (real background)
  /// - the flag is reset to `false` on each `resumed` so a later
  ///   `inactive -> resumed` (e.g., phone call overlay) does not
  ///   false-positive
  ///
  /// Boundary monitor lifecycle:
  /// - stopped on `paused` (no checking while backgrounded)
  /// - re-seeded and restarted on `resumed` after real backgrounding;
  ///   the re-seed picks up the current business date so the monitor
  ///   does not duplicate the refresh already handled by the resume
  ///   path (7.55n.9)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasBeenBackgrounded) {
      _hasBeenBackgrounded = false;
      context.read<AppRefreshCoordinator>().refreshCurrentStateSurfaces();
      // Re-seed and restart boundary monitor after resume refresh.
      // The re-seed picks up the current business date so the monitor
      // does not detect a "change" that the resume path already handled.
      _boundaryMonitor?.start();
    } else if (state == AppLifecycleState.resumed) {
      // resumed without prior paused — no-op (cold start or inactive)
    }
    if (state == AppLifecycleState.paused) {
      _hasBeenBackgrounded = true;
      _boundaryMonitor?.stop();
    }
  }

  void _navigateTo(int index) {
    setState(() => _selectedIndex = index);
  }

  Future<void> _openSettings(BuildContext context) async {
    // In debug builds, wire the dev-only Settings sections by passing
    // their respective services:
    //   * `AdvisorModelConfigService` powers the ADVISOR MODELS section
    //     (override editing + Anthropic online check).
    //   * `AdvisorCorpusAdminService` powers the ADVISOR CORPUS section
    //     (local-only Markdown preview + 11a.11b cloud-blocked
    //     affordance).
    // In release builds both stay hidden because `SettingsScreen` only
    // renders each section when both `kDebugMode` and the matching
    // service instance are present.
    final advisorConfig = kDebugMode ? AdvisorModelConfigService() : null;
    final corpusAdmin = kDebugMode ? AdvisorCorpusAdminService() : null;
    final authNotifier = context.read<AuthSessionNotifier>();
    final session = authNotifier.session;
    final restaurant = context.read<RestaurantScopeNotifier>().restaurant;
    final navigator = Navigator.of(context);
    final teamActor = await _teamActorForSettings(context, session);
    if (!mounted) return;
    if (session != null &&
        teamActor != null &&
        TeamScopeVisibilityPolicy.canSeeTeamNav(teamActor)) {
      unawaited(_loadTeamRoleOptionsIfNeeded(session));
      unawaited(_loadTeamDataIfNeeded(session));
    }
    navigator.push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          advisorModelConfigService: advisorConfig,
          advisorCorpusAdminService: corpusAdmin,
          teamActor: teamActor,
          teamRoleOptions: _teamRoleOptions,
          teamRoleOptionsListenable: _teamRoleOptionsListenable,
          teamLocationOptions: session == null
              ? const <TeamLocationOption>[]
              : <TeamLocationOption>[
                  TeamLocationOption(
                    locationId: session.locationId,
                    label: restaurant?.displayName ?? 'Current location',
                  ),
                ],
          teamUsers: _teamUsers,
          teamUsersListenable: _teamUsersListenable,
          teamPendingInvites: _teamPendingInvites,
          teamPendingInvitesListenable: _teamPendingInvitesListenable,
          teamDataLoadState: _teamDataLoadState,
          teamDataLoadStateListenable: _teamDataLoadStateListenable,
          onTeamInviteSubmitted: _teamInviteSubmitter(session),
          onTeamInviteRevoked: _teamInviteRevoker(session),
          onTeamUserAction: _teamUserActionHandler(session),
          passwordChangeGateway: widget.passwordChangeGateway,
          accountInfoGateway: widget.accountInfoGateway,
          mfaOperationsGateway: widget.mfaOperationsGateway,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  Future<TeamScopeActor?> _teamActorForSettings(
    BuildContext context,
    AuthSession? session,
  ) async {
    if (session == null) return null;
    var permissionContext = _permissionContextFromContext(context);
    final loader = widget.permissionContextLoader;
    if (permissionContext == null && loader != null) {
      try {
        permissionContext = await loader.load(session);
      } catch (error) {
        debugPrint('Settings permission snapshot load failed: $error');
      }
    }
    return _teamActorFromSession(
      session,
      _allowedPermissions(permissionContext),
    );
  }

  PermissionContext? _permissionContextFromContext(BuildContext context) {
    try {
      return Provider.of<PermissionContext>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  Set<String> _allowedPermissions(PermissionContext? permissionContext) {
    if (permissionContext == null) return const <String>{};
    return permissionContext.snapshot.entries.entries
        .where((entry) => entry.value == PermissionEffect.allow)
        .map((entry) => entry.key)
        .toSet();
  }

  TeamScopeActor _teamActorFromSession(
    AuthSession session,
    Set<String> permissions,
  ) {
    final roles = session.roles.toSet();
    if (!roles.contains('super_admin') &&
        !roles.contains('ff_support') &&
        !roles.contains('operator_owner') &&
        !roles.contains('operator_manager')) {
      if (permissions.contains('team.roles.create_custom') ||
          permissions.contains('team.users.soft_delete')) {
        roles.add('operator_owner');
      } else if (permissions.contains('team.users.view')) {
        roles.add('operator_manager');
      }
    }
    final isOperatorWide =
        roles.contains('operator_owner') ||
        roles.contains('super_admin') ||
        roles.contains('ff_support');
    return TeamScopeActor(
      actorRoles: roles,
      actorOperatorId: session.operatorId,
      actorAssignedLocationIds: isOperatorWide
          ? const <String>{}
          : <String>{session.locationId},
      actorPermissions: permissions,
    );
  }

  Future<void> _loadTeamRoleOptionsIfNeeded(AuthSession session) async {
    final gateway = widget.authOperationsGateway;
    if (gateway == null) return;
    final key = '${session.userId}|${session.operatorId}|${session.locationId}';
    if (_teamRolesLoadedFor == key) return;
    if (_teamRolesLoadingFor == key) return;
    _teamRolesLoadingFor = key;
    try {
      final listed = await gateway.listRoles(
        TeamRoleCatalogListCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
        ),
      );
      if (!mounted) return;
      final roles = listed.roles;
      if (roles.isEmpty) return;
      final nextOptions = roles
          .map(
            (role) =>
                TeamRoleOption(roleId: role.roleId, label: role.displayName),
          )
          .toList(growable: false);
      final nextRoleIdsByKey = <String, String>{
        for (final role in roles) role.roleKey: role.roleId,
      };
      setState(() {
        _teamRolesLoadedFor = key;
        _teamRoleOptions = nextOptions;
        _teamRoleIdsByKey = nextRoleIdsByKey;
      });
      _teamRoleOptionsListenable.value = nextOptions;
    } catch (error) {
      debugPrint('Team role catalog load failed: $error');
    } finally {
      if (_teamRolesLoadingFor == key) _teamRolesLoadingFor = null;
    }
  }

  Future<void> _loadTeamDataIfNeeded(
    AuthSession session, {
    bool force = false,
  }) async {
    final gateway = widget.authOperationsGateway;
    if (gateway == null) {
      _publishTeamDataLoadState(TeamSettingsDataLoadState.ready);
      return;
    }
    final key = '${session.userId}|${session.operatorId}|${session.locationId}';
    if (!force && _teamDataLoadedFor == key) {
      _publishTeamDataLoadState(TeamSettingsDataLoadState.ready);
      return;
    }
    if (_teamDataLoadingFor == key) {
      _publishTeamDataLoadState(
        TeamSettingsDataLoadState(
          loading: true,
          loaded: _teamDataLoadedFor == key,
        ),
      );
      return;
    }
    _teamDataLoadingFor = key;
    _publishTeamDataLoadState(
      TeamSettingsDataLoadState(
        loading: true,
        loaded: _teamDataLoadedFor == key,
      ),
    );
    try {
      final users = await gateway.listUsers(
        TeamUserListCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
        ),
      );
      final invites = await gateway.listInvites(
        TeamInviteListCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
        ),
      );
      if (!mounted) return;
      final nextUsers = users.users
          .map(_teamUserFromEntry)
          .toList(growable: false);
      final nextInvites = invites.invites
          .map(_teamInviteFromEntry)
          .toList(growable: false);
      setState(() {
        _teamDataLoadedFor = key;
        _teamUsers = nextUsers;
        _teamPendingInvites = nextInvites;
      });
      _teamUsersListenable.value = nextUsers;
      _teamPendingInvitesListenable.value = nextInvites;
      _publishTeamDataLoadState(TeamSettingsDataLoadState.ready);
    } catch (error) {
      debugPrint('Team data load failed: $error');
      if (mounted) {
        _publishTeamDataLoadState(
          TeamSettingsDataLoadState(loaded: _teamDataLoadedFor == key),
        );
      }
    } finally {
      if (_teamDataLoadingFor == key) _teamDataLoadingFor = null;
    }
  }

  void _publishTeamDataLoadState(TeamSettingsDataLoadState next) {
    if (_teamDataLoadState.loading == next.loading &&
        _teamDataLoadState.loaded == next.loaded) {
      return;
    }
    _teamDataLoadState = next;
    _teamDataLoadStateListenable.value = next;
  }

  TeamUserListItem _teamUserFromEntry(TeamUserListEntry entry) {
    return TeamUserListItem(
      userId: entry.userId,
      email: entry.email,
      displayName: entry.displayName,
      roleId: entry.roleId,
      roleLabel: entry.roleLabel,
      status: entry.status,
      locationId: entry.locationId,
      locationLabel: entry.locationLabel,
      mfaEnrolled: entry.mfaEnrolled,
      mfaRemovalPending: entry.mfaRemovalPending,
      mfaRemovalRequestId: entry.mfaRemovalRequestId,
      userRoleId: entry.userRoleId,
      lastActiveAt: entry.lastActiveAt,
    );
  }

  TeamPendingInviteListItem _teamInviteFromEntry(TeamInviteListEntry entry) {
    return TeamPendingInviteListItem(
      inviteId: entry.inviteId,
      email: entry.email,
      roleId: entry.roleId,
      roleLabel: entry.roleLabel,
      scopeType: entry.scopeType,
      locationId: entry.locationId,
      locationLabel: entry.locationLabel,
      expiresAt: entry.expiresAt,
    );
  }

  TeamInviteSubmitter? _teamInviteSubmitter(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (payload) async {
      final email = payload['email'];
      final roleIdOrKey = payload['role_id'];
      final scopeType = payload['scope_type'];
      final targetLocationId = payload['location_id'];
      final targetOrgUnitId = payload['org_unit_id'];
      if (email is! String || roleIdOrKey is! String || scopeType is! String) {
        throw StateError('Invite form payload was incomplete.');
      }
      final resolvedRoleId = _teamRoleIdsByKey[roleIdOrKey] ?? roleIdOrKey;
      if (resolvedRoleId.startsWith('operator_')) {
        throw StateError('Team role catalog is still loading. Try again.');
      }
      final created = await gateway.createInvite(
        TeamInviteCreateCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          email: email,
          roleId: resolvedRoleId,
          scopeType: scopeType,
          targetLocationId: targetLocationId is String
              ? targetLocationId
              : null,
          targetOrgUnitId: targetOrgUnitId is String ? targetOrgUnitId : null,
        ),
      );
      unawaited(_loadTeamDataIfNeeded(session, force: true));
      return created;
    };
  }

  TeamInviteRevoker? _teamInviteRevoker(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (inviteId) async {
      await gateway.revokeInvite(
        TeamInviteRevokeCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          inviteId: inviteId,
        ),
      );
      unawaited(_loadTeamDataIfNeeded(session, force: true));
    };
  }

  TeamUserActionHandler? _teamUserActionHandler(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (request) async {
      switch (request.action) {
        case TeamUserAction.suspend:
          await gateway.suspendUser(_teamUserStatusCommand(session, request));
        case TeamUserAction.reactivate:
          await gateway.reactivateUser(
            _teamUserStatusCommand(session, request),
          );
        case TeamUserAction.softDelete:
          await gateway.softDeleteUser(
            _teamUserStatusCommand(session, request),
          );
        case TeamUserAction.resetPassword:
          await gateway.requestPasswordReset(
            TeamPasswordResetCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              targetUserId: request.user.userId,
            ),
          );
        case TeamUserAction.resetMfa:
          await gateway.requestMfaReset(
            TeamMfaResetCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              targetUserId: request.user.userId,
              stepUpProofId: session.firebaseIdToken,
            ),
          );
        case TeamUserAction.cancelMfaRemoval:
          final requestId = request.user.mfaRemovalRequestId;
          if (requestId == null || requestId.isEmpty) {
            throw StateError('Team MFA removal request id was missing.');
          }
          await gateway.cancelMfaRemoval(
            TeamMfaRemovalCancelCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              targetUserId: request.user.userId,
              requestId: requestId,
            ),
          );
        case TeamUserAction.createRoleGrant:
          final roleId = request.roleId;
          final scopeType = request.scopeType;
          if (roleId == null || scopeType == null) {
            throw StateError('Team role action was incomplete.');
          }
          final replaceId = request.replaceUserRoleId;
          if (replaceId != null && replaceId.isNotEmpty) {
            await gateway.revokeRoleGrant(
              TeamRoleGrantRevokeCommand(
                actorUserId: session.userId,
                operatorId: session.operatorId,
                locationId: session.locationId,
                userRoleId: replaceId,
                targetUserId: request.user.userId,
                reason: request.reason,
              ),
            );
          }
          await gateway.createRoleGrant(
            TeamRoleGrantCreateCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              targetUserId: request.user.userId,
              roleId: roleId,
              scopeType: scopeType,
              targetLocationId: request.locationId,
              reason: request.reason,
            ),
          );
        case TeamUserAction.revokeRoleGrant:
          final userRoleId =
              request.replaceUserRoleId ?? request.user.userRoleId;
          if (userRoleId == null || userRoleId.isEmpty) {
            throw StateError('Team role revoke was missing a grant id.');
          }
          await gateway.revokeRoleGrant(
            TeamRoleGrantRevokeCommand(
              actorUserId: session.userId,
              operatorId: session.operatorId,
              locationId: session.locationId,
              userRoleId: userRoleId,
              targetUserId: request.user.userId,
              reason: request.reason,
            ),
          );
      }
      unawaited(_loadTeamDataIfNeeded(session, force: true));
    };
  }

  TeamUserStatusCommand _teamUserStatusCommand(
    AuthSession session,
    TeamUserActionRequest request,
  ) {
    return TeamUserStatusCommand(
      actorUserId: session.userId,
      operatorId: session.operatorId,
      locationId: session.locationId,
      targetUserId: request.user.userId,
      reason: request.reason ?? 'settings_team_action',
    );
  }

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NotificationsScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // App-shell rebuild now driven by persisted active-target authority,
    // not BaselineData.revision.
    final revision = context.watch<ActiveTargetProfileNotifier>().revision;

    final embeddedAppBar = AppBar(
      backgroundColor: AppColors.backgroundDeep,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      title: const Text('Forge & Flow'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        IconButton(
          icon: const Icon(
            Icons.notifications_none_outlined,
            size: 26,
            color: AppColors.textMuted,
          ),
          onPressed: () => _openNotifications(context),
        ),
        IconButton(
          icon: const Icon(
            Icons.settings_outlined,
            size: 26,
            color: AppColors.textMuted,
          ),
          onPressed: () => _openSettings(context),
        ),
      ],
    );

    // Premium app shell header — icons live in their own pill buttons so
    // they read as actionable, separated by a soft border line at the
    // bottom from the underlying screen content.
    final standaloneAppBar = PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.backgroundDeep,
              AppColors.backgroundDeep.withValues(alpha: 0.85),
            ],
          ),
          border: Border(
            bottom: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
            child: Row(
              children: [
                const Spacer(),
                _AppShellIconButton(
                  icon: Icons.notifications_none_outlined,
                  tooltip: 'Notifications',
                  onTap: () => _openNotifications(context),
                ),
                const SizedBox(width: 8),
                _AppShellIconButton(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onTap: () => _openSettings(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: widget.embeddedInBarrio ? embeddedAppBar : standaloneAppBar,
      body: SafeArea(
        top: !widget.embeddedInBarrio,
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            KeyedSubtree(
              key: ValueKey('shift-$revision'),
              child: ShiftDashboard(onVarianceTap: () => _navigateTo(1)),
            ),
            KeyedSubtree(
              key: ValueKey('variance-$revision'),
              child: const VarianceReport(),
            ),
            KeyedSubtree(
              key: ValueKey('schedule-$revision'),
              child: const ScheduleBuilder(),
            ),
            KeyedSubtree(
              key: ValueKey('baseline-$revision'),
              child: const BaselineTracker(),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _AppBottomNav(
        selectedIndex: _selectedIndex,
        onTap: _navigateTo,
      ),
    );
  }
}

class _AppBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _AppBottomNav({required this.selectedIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: onTap,
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart, size: 22),
            label: 'Shift',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart, size: 22),
            label: 'Variance',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today, size: 22),
            label: 'Plan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history, size: 22),
            label: 'Benchmark',
          ),
        ],
      ),
    );
  }
}

// ─── App shell icon button ───────────────────────────────────────────────
// Pill-style icon button used in the standalone app bar so settings and
// notifications read as their own affordances rather than tiny hint icons.

class _AppShellIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _AppShellIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.backgroundMid.withValues(alpha: 0.7),
            border: Border.all(
              color: AppColors.borderSubtle.withValues(alpha: 0.7),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Icon(icon, size: 24, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
