import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth/auth_session.dart';
import 'auth/permission_effect.dart';
import 'domain/models/restaurant_location.dart';
import 'services/advisor_corpus_admin_service.dart';
import 'services/advisor_model_config_service.dart';
import 'services/auth/auth_operations_gateway.dart';
import 'services/auth/password_change_gateway.dart';
import 'services/auth/password_reset_deep_link_source.dart';
import 'services/auth/password_reset_gateway.dart';
import 'services/auth/proxy_permission_snapshot_loader.dart';
import 'services/boundary_event_outbox.dart';
import 'services/business_date_authority_service.dart';
import 'services/sqlite_boundary_event_outbox.dart';
import 'services/mfa/mfa_operations_gateway.dart';
import 'services/mfa/mfa_recovery_request_gateway.dart';
import 'services/shift_data_source.dart';
import 'services/team/team_scope_visibility_policy.dart';
import 'state/active_target_profile_notifier.dart';
import 'state/app_refresh_coordinator.dart';
import 'state/app_runtime_invalidation_bus.dart';
import 'state/auth_session_notifier.dart';
import 'state/demand_forecast_context_notifier.dart';
import 'state/last_synced_timestamps_notifier.dart';
import 'state/permission_context.dart';
import 'state/realtime_event_bus.dart';
import 'state/restaurant_scope_notifier.dart';
import 'services/auth/account_info_gateway.dart';
import 'state/schedule_distribution_weights_notifier.dart';
import 'state/shift_dashboard_notifier.dart';
import 'state/shift_service_period_notifier.dart';
import 'state/week_data_notifier.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'screens/baseline_tracker.dart';
import 'screens/auth/auth_permission_context_bridge.dart';
import 'screens/auth/auth_gate.dart';
import 'screens/notifications_screen.dart';
import 'services/realtime/realtime_event.dart';
import 'services/realtime/realtime_subscription.dart';
import 'widgets/peer_edit_toast.dart';
import 'screens/schedule_builder.dart';
import 'screens/settings/settings_custom_roles_section.dart';
import 'screens/settings/settings_org_hierarchy_section.dart';
import 'screens/settings_screen.dart';
import 'screens/shift_dashboard.dart';
import 'screens/team/team_settings_section.dart';
import 'screens/variance_report.dart';
import 'state/boundary_monitor_supervisor.dart';
import 'theme/app_theme.dart';
import 'widgets/sync_state_badge.dart';

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
    this.passwordResetGateway,
    this.passwordResetDeepLinkSource,
  });

  final bool requireAuth;
  final PermissionContextLoader? permissionContextLoader;
  final AuthOperationsGateway? authOperationsGateway;
  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;
  final MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;
  final PasswordResetGateway? passwordResetGateway;
  final PasswordResetDeepLinkSource? passwordResetDeepLinkSource;

  @override
  Widget build(BuildContext context) {
    final shell = AppShell(
      permissionContextLoader: permissionContextLoader,
      authOperationsGateway: authOperationsGateway,
      accountInfoGateway: accountInfoGateway,
      passwordChangeGateway: passwordChangeGateway,
      mfaOperationsGateway: mfaOperationsGateway,
    );
    final Widget homeContent = requireAuth
        ? AuthGate(
            mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
            passwordResetGateway: passwordResetGateway,
            passwordResetDeepLinkSource: passwordResetDeepLinkSource,
            authenticatedChild: AuthPermissionContextBridge(
              permissionContextLoader: permissionContextLoader,
              child: shell,
            ),
          )
        : shell;
    return ForgeFlowScope(
      child: MaterialApp(
        title: 'Forge & Flow',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        // Phase 10a.UX.1 — wrap the home content in (a) the realtime
        // producer wiring that pipes 10a.UX.0's shared
        // [RealtimeSubscription.events] into the
        // [RealtimeEventBus] (and clears the freshness map on
        // sign-out / operator change), and (b) a shell-level
        // [PeerEditToast] so a shared-state frame surfaces a
        // SnackBar across every route. The subscription itself is
        // owned by the bootstrap layer (10a.UX.0); this widget
        // consumes it via Provider so both lanes share one socket.
        home: _RealtimeProducerWiring(
          child: _PeerEditToastShellHost(child: homeContent),
        ),
      ),
    );
  }
}

/// Phase 10a.UX.1 — internal host that mounts the shell-level
/// [PeerEditToast] using the [RealtimeEventBus] from the enclosing
/// [ForgeFlowScope] Provider. Splitting this out of `build` lets the
/// MaterialApp `home` route stay readable and keeps the bus lookup
/// inside the Provider tree.
class _PeerEditToastShellHost extends StatelessWidget {
  const _PeerEditToastShellHost({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bus = context.read<RealtimeEventBus>();
    return PeerEditToast(events: bus.events, child: child);
  }
}

/// Phase 10a.UX.1 — shell-level realtime consumer. Reads the
/// shared `Provider<RealtimeSubscription?>` introduced by sibling
/// lane 10a.UX.0 in [bootstrapAndRunApp] and pipes its `events`
/// stream into the [RealtimeEventBus] so the toast and freshness
/// surfaces consume live frames from the **same** subscription
/// instance the badge reads `connectionState` from.
///
/// Auth-driven lifecycle is owned by 10a.UX.0's
/// [RealtimeAuthBridge] (which calls `setTenantContext` /
/// `clearTenantContext` on the shared subscription). This widget
/// carries the freshness-clear concern that's specific to UX.1:
/// when the auth session leaves [AuthSessionAuthenticated] (hard
/// sign-out) or transitions to a different operator id, the in-
/// memory [LastSyncedTimestampsNotifier] map is cleared so the
/// prior operator's per-table timestamps cannot leak. Token-
/// refresh blips (transient Loading / MfaChallenge while the
/// operator id is unchanged) preserve the freshness rows.
///
/// The widget renders [child] unchanged — it's a side-effect host
/// that lives inside the Provider tree so it can read the bus, the
/// shared subscription, and the auth notifier.
class _RealtimeProducerWiring extends StatefulWidget {
  const _RealtimeProducerWiring({required this.child});

  final Widget child;

  @override
  State<_RealtimeProducerWiring> createState() =>
      _RealtimeProducerWiringState();
}

class _RealtimeProducerWiringState extends State<_RealtimeProducerWiring> {
  StreamSubscription<RealtimeEvent>? _eventsPipe;
  AuthSessionNotifier? _watchedAuthNotifier;
  String? _appliedOperatorId;

  @override
  void initState() {
    super.initState();
    // The bus, the shared subscription, and the auth notifier come
    // from the surrounding Provider tree, which is only readable
    // after the first frame builds. Wire on the post-frame callback
    // so `context.read` resolves cleanly for both production builds
    // and widget tests.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _wireEventsPipe();
      _wireAuthListener();
      _applyCurrentSession();
    });
  }

  void _wireEventsPipe() {
    final subscription = _resolveSubscription();
    if (subscription == null) {
      // No shared subscription in the tree (demo / no-Firebase
      // shells, widget tests that bypass bootstrap). The bus stays
      // without a producer, which matches the pre-realtime-config
      // behaviour.
      return;
    }
    final bus = context.read<RealtimeEventBus>();
    _eventsPipe = subscription.events.listen(bus.publish);
  }

  void _wireAuthListener() {
    final notifier = _resolveAuthNotifier();
    if (notifier == null) {
      // No AuthSessionNotifier in the tree (Barrio embeds, isolated
      // widget tests). Without it we have no signal for sign-out
      // freshness clears; the rest of the surfaces still function.
      return;
    }
    _watchedAuthNotifier = notifier;
    notifier.addListener(_onAuthSessionChange);
  }

  void _onAuthSessionChange() {
    if (!mounted) return;
    _applyCurrentSession();
  }

  void _applyCurrentSession() {
    final notifier = _watchedAuthNotifier;
    if (notifier == null) return;
    final state = notifier.state;
    if (state is AuthSessionAuthenticated) {
      final session = state.session;
      // Defensive: an Authenticated → Authenticated transition with
      // a different operator (e.g. an SSO session swap that skips
      // Unauthenticated) must not let the prior tenant's freshness
      // rows linger. The Unauthenticated path also clears freshness;
      // this catches the no-intervening-Unauthenticated case.
      if (_appliedOperatorId != null &&
          _appliedOperatorId != session.operatorId) {
        _clearFreshness();
      }
      _appliedOperatorId = session.operatorId;
    } else if (state is AuthSessionUnauthenticated) {
      // Hard sign-out: clear the in-memory freshness map so the next
      // operator (or even this operator glancing at Settings while
      // signed out) does not see the prior session's per-table
      // timestamps. Loading and MfaChallenge are transient — preserve
      // freshness across them so a token-refresh blip doesn't wipe
      // valid rows.
      _appliedOperatorId = null;
      _clearFreshness();
    }
    // Loading / MfaChallenge: leave freshness alone.
  }

  /// Drop every freshness row from
  /// [LastSyncedTimestampsNotifier]. Tolerant of a missing Provider
  /// (Barrio embeds, isolated widget tests) — those call sites have
  /// no notifier to clear and the call is a no-op.
  void _clearFreshness() {
    if (!mounted) return;
    final freshness = _resolveFreshnessNotifier();
    freshness?.clear();
  }

  RealtimeSubscription? _resolveSubscription() {
    try {
      return Provider.of<RealtimeSubscription?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  AuthSessionNotifier? _resolveAuthNotifier() {
    try {
      return Provider.of<AuthSessionNotifier>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  LastSyncedTimestampsNotifier? _resolveFreshnessNotifier() {
    try {
      return Provider.of<LastSyncedTimestampsNotifier>(
        context,
        listen: false,
      );
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  void dispose() {
    _eventsPipe?.cancel();
    _eventsPipe = null;
    _watchedAuthNotifier?.removeListener(_onAuthSessionChange);
    _watchedAuthNotifier = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
        // Phase 10.5.2 — per-service-period accumulator surface for the
        // Shift daypart lens and Variance daypart lens.
        ChangeNotifierProvider<ShiftServicePeriodNotifier>(
          create: (_) => ShiftServicePeriodNotifier(),
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
        // Phase 10a.UX.1 — shell-level RealtimeEventBus seam. The
        // bus is the join point between sibling lane 10a.UX.0's
        // RealtimeSubscription instance (producer) and the Phase
        // 10a.UX.1 surfaces (consumers: PeerEditToast wrapping the
        // home, LastSyncedTimestampsNotifier feeding Settings → Data
        // → Data freshness). Today the bus has no producer; UX.0
        // pipes `subscription.events.listen(bus.publish)` when the
        // live subscription lands.
        Provider<RealtimeEventBus>(
          create: (_) => RealtimeEventBus(),
          dispose: (_, bus) => bus.dispose(),
        ),
        // Phase 10a.UX.1 — per-table last-sync timestamps. Auto-
        // subscribes to the RealtimeEventBus once on creation; the
        // `update` callback is a no-op because the bus instance is
        // stable across rebuilds.
        ChangeNotifierProxyProvider<
          RealtimeEventBus,
          LastSyncedTimestampsNotifier
        >(
          create: (_) => LastSyncedTimestampsNotifier(),
          update: (_, bus, previous) {
            final notifier = previous ?? LastSyncedTimestampsNotifier();
            notifier.subscribeRealtime(bus.events);
            return notifier;
          },
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
            shiftServicePeriod: ctx.read<ShiftServicePeriodNotifier>(),
            demandForecast: ctx.read<DemandForecastContextNotifier>(),
            scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
          ),
          update: (ctx, targetNotifier, bus, previous) {
            final coordinator = previous!;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              coordinator.refreshCurrentStateSurfaces();
            });
            return coordinator;
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

  /// Test-only: override the boundary durable backlog adapter.
  /// Production wires [SqliteBoundaryEventOutbox]; widget tests can
  /// pass `null` (no persistence) or an in-memory fake.
  @visibleForTesting
  final BoundaryEventOutbox? testBoundaryEventOutbox;

  /// Test-only flag: when true, do not wire the default
  /// [SqliteBoundaryEventOutbox] in production. Lets widget tests
  /// that don't initialize SQLite opt out cleanly.
  @visibleForTesting
  final bool testDisableDefaultBoundaryEventOutbox;

  /// Phase 10a.UX.0 — bridge connection-state stream that feeds the
  /// app-bar [SyncStateBadge]. Production wires
  /// `RealtimeSubscription.connectionState` here once the subscription
  /// is mounted; until then (and in widget tests that don't exercise
  /// the badge) leaving this `null` keeps the badge hidden.
  final Stream<RealtimeConnectionState>? realtimeConnectionState;

  /// Phase 10a.UX.0 — initial connection state used by the badge's
  /// [StreamBuilder] until the stream emits its first value. Defaults
  /// to [RealtimeConnectionState.idle] so the badge stays hidden on
  /// first frame.
  final RealtimeConnectionState realtimeInitialConnectionState;

  const AppShell({
    super.key,
    this.embeddedInBarrio = false,
    this.permissionContextLoader,
    this.authOperationsGateway,
    this.accountInfoGateway,
    this.passwordChangeGateway,
    this.mfaOperationsGateway,
    this.testBusinessDateResolver,
    this.testBoundaryEventOutbox,
    this.testDisableDefaultBoundaryEventOutbox = false,
    this.realtimeConnectionState,
    this.realtimeInitialConnectionState = RealtimeConnectionState.idle,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;
  final Set<int> _visitedTabIndices = <int>{0};
  List<TeamRoleOption> _teamRoleOptions =
      TeamSettingsSection.defaultRoleOptions;
  late final ValueNotifier<List<TeamRoleOption>> _teamRoleOptionsListenable =
      ValueNotifier<List<TeamRoleOption>>(_teamRoleOptions);
  List<TeamRoleCatalogEntry> _teamRoleCatalog = const <TeamRoleCatalogEntry>[];
  late final ValueNotifier<List<TeamRoleCatalogEntry>>
  _teamRoleCatalogListenable = ValueNotifier<List<TeamRoleCatalogEntry>>(
    _teamRoleCatalog,
  );
  TeamRoleCatalogLoadState _teamRoleCatalogLoadState =
      TeamRoleCatalogLoadState.unavailable;
  late final ValueNotifier<TeamRoleCatalogLoadState>
  _teamRoleCatalogLoadStateListenable = ValueNotifier<TeamRoleCatalogLoadState>(
    _teamRoleCatalogLoadState,
  );
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
  // Phase 9.UX.4 — operator org hierarchy state. Cached per
  // `(user, operator, location)` key so the Settings → Team tab
  // can render the tree without a round-trip on every open.
  List<TeamOrgUnitEntry> _teamOrgUnits = const <TeamOrgUnitEntry>[];
  List<TeamOrgLocationEntry> _teamOrgLocations = const <TeamOrgLocationEntry>[];
  // Listenables bridge the async load/create/move callbacks back to
  // the open Settings route — passing only `_teamOrgUnits` /
  // `_teamOrgLocations` snapshots leaves the hierarchy stale when the
  // gateway resolves after navigation.
  late final ValueNotifier<List<TeamOrgUnitEntry>> _teamOrgUnitsListenable =
      ValueNotifier<List<TeamOrgUnitEntry>>(_teamOrgUnits);
  late final ValueNotifier<List<TeamOrgLocationEntry>>
  _teamOrgLocationsListenable = ValueNotifier<List<TeamOrgLocationEntry>>(
    _teamOrgLocations,
  );
  late final ValueNotifier<List<TeamOrgUnitOption>>
  _teamOrgUnitOptionsListenable = ValueNotifier<List<TeamOrgUnitOption>>(
    const <TeamOrgUnitOption>[],
  );
  TeamOrgHierarchyLoadState _teamOrgHierarchyLoadState =
      TeamOrgHierarchyLoadState.unavailable;
  late final ValueNotifier<TeamOrgHierarchyLoadState>
  _teamOrgHierarchyLoadStateListenable =
      ValueNotifier<TeamOrgHierarchyLoadState>(_teamOrgHierarchyLoadState);
  String? _teamOrgHierarchyLoadedFor;
  String? _teamOrgHierarchyLoadingFor;

  /// Tracks whether the app has been backgrounded at least once.
  /// Prevents the cold-start `resumed` callback from triggering a
  /// duplicate refresh — notifiers already load in their constructors.
  bool _hasBeenBackgrounded = false;

  /// Foreground-only business-date boundary supervisor. Spawns one
  /// `CurrentStateBoundaryMonitor` per accessible `RestaurantLocation`
  /// so multi-location operators get independent restaurant-local
  /// boundary clocks (Time Boundary Contract Rule 1).
  BoundaryMonitorSupervisor? _boundarySupervisor;
  RestaurantScopeNotifier? _scopeListenedFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize boundary supervisor after first frame when providers
    // are available in the widget tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBoundarySupervisor();
    });
  }

  /// Creates and starts the boundary supervisor, then subscribes to
  /// [RestaurantScopeNotifier] so monitor membership tracks the
  /// currently accessible locations.
  ///
  /// Uses [widget.testBusinessDateResolver] when provided (tests),
  /// otherwise falls back to production
  /// [BusinessDateAuthorityService.resolveBusinessDate].
  ///
  /// HARD-H — durable backlog wiring uses [SqliteBoundaryEventOutbox]
  /// in production: the Flutter app cannot reach Postgres directly
  /// (Hard Promise #7 in CLAUDE.md — "F&F holds all provider keys
  /// server-side"), so the per-device boundary backlog persists
  /// locally. The boundary monitor's purpose is local UI refresh, so
  /// per-device durability is sufficient — the persisted rows do not
  /// need to fan out to Pub/Sub or other consumers. A killed /
  /// backgrounded app mid-fire leaves an undelivered row that
  /// [BoundaryMonitorSupervisor.drainBacklog] replays on the next
  /// foreground start (and on resume-after-background).
  ///
  /// The server-side analogue ([PostgresBoundaryEventOutbox], wraps
  /// `event_outbox`) is exercised by the live-binding test and used
  /// by future server-side supervisors.
  void _initBoundarySupervisor() {
    if (!mounted) return;
    final BoundaryEventOutbox? outbox;
    if (widget.testBoundaryEventOutbox != null) {
      outbox = widget.testBoundaryEventOutbox;
    } else if (widget.testDisableDefaultBoundaryEventOutbox) {
      outbox = null;
    } else {
      outbox = SqliteBoundaryEventOutbox();
    }
    _boundarySupervisor = BoundaryMonitorSupervisor(
      resolveBusinessDate:
          widget.testBusinessDateResolver ??
          BusinessDateAuthorityService.instance.resolveBusinessDate,
      onBoundaryChanged: () {
        if (mounted) {
          context.read<AppRefreshCoordinator>().refreshCurrentStateSurfaces(
            allowInitialRefresh: true,
          );
        }
      },
      eventOutbox: outbox,
    );
    final scope = context.read<RestaurantScopeNotifier>();
    scope.addListener(_syncSupervisorToScope);
    _scopeListenedFor = scope;
    _syncSupervisorToScope();
    _boundarySupervisor!.start();
    // Replay any rollover events the previous foreground session
    // persisted but did not mark delivered (e.g. crash mid-fire).
    unawaited(_boundarySupervisor!.drainBacklog());
  }

  /// Resolves the bootstrap-provided realtime subscription so the
  /// app-bar [SyncStateBadge] can read its connection-state stream.
  /// Returns `null` when the provider is not in the tree (existing
  /// widget tests, demo paths) so the badge stays hidden.
  ///
  /// The auth-to-realtime bridge that drives `setTenantContext` /
  /// `clearTenantContext` lives ABOVE this shell at bootstrap level
  /// ([RealtimeAuthBridge]) so popping the embedded F&F destination
  /// inside Barrio cannot leave a stale operator channel alive
  /// across a later sign-out.
  RealtimeSubscription? _resolveRealtimeSubscription() {
    try {
      return Provider.of<RealtimeSubscription?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Mirrors the active locations from [RestaurantScopeNotifier] into
  /// the supervisor. Today the notifier exposes a single active
  /// restaurant; multi-location wiring lands in a later phase.
  void _syncSupervisorToScope() {
    final supervisor = _boundarySupervisor;
    if (supervisor == null || !mounted) return;
    final restaurant = context.read<RestaurantScopeNotifier>().restaurant;
    supervisor.syncTo(
      restaurant != null
          ? <RestaurantLocation>[restaurant]
          : const <RestaurantLocation>[],
    );
  }

  @override
  void dispose() {
    _scopeListenedFor?.removeListener(_syncSupervisorToScope);
    _scopeListenedFor = null;
    _boundarySupervisor?.dispose();
    _teamRoleOptionsListenable.dispose();
    _teamRoleCatalogListenable.dispose();
    _teamRoleCatalogLoadStateListenable.dispose();
    _teamUsersListenable.dispose();
    _teamPendingInvitesListenable.dispose();
    _teamDataLoadStateListenable.dispose();
    _teamOrgUnitsListenable.dispose();
    _teamOrgLocationsListenable.dispose();
    _teamOrgUnitOptionsListenable.dispose();
    _teamOrgHierarchyLoadStateListenable.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Phase 7.55n.9 + 7.55n.9a + 7.55n.10: revalidate current-state
  /// surfaces on app resume after real backgrounding, and manage the
  /// boundary supervisor lifecycle.
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
  /// Boundary supervisor lifecycle:
  /// - stopped on `paused` (no checking while backgrounded)
  /// - re-seeded and restarted on `resumed` after real backgrounding;
  ///   the re-seed picks up the current business date so the monitors
  ///   do not duplicate the refresh already handled by the resume
  ///   path (7.55n.9)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasBeenBackgrounded) {
      _hasBeenBackgrounded = false;
      context.read<AppRefreshCoordinator>().refreshCurrentStateSurfaces();
      // Re-seed and restart boundary monitors after resume refresh.
      // The re-seed picks up the current business date so the monitors
      // do not detect a "change" that the resume path already handled.
      _boundarySupervisor?.start();
      // HARD-H — drain any rollover events the previous foreground
      // session persisted but did not mark delivered before the user
      // backgrounded / killed the app. No-op until the proxy adapter
      // for `EventOutboxRepository` lands; see comment on
      // `_initBoundarySupervisor`.
      final supervisor = _boundarySupervisor;
      if (supervisor != null) {
        unawaited(supervisor.drainBacklog());
      }
    } else if (state == AppLifecycleState.resumed) {
      // resumed without prior paused — no-op (cold start or inactive)
    }
    if (state == AppLifecycleState.paused) {
      _hasBeenBackgrounded = true;
      _boundarySupervisor?.stop();
    }
  }

  void _navigateTo(int index) {
    if (index == _selectedIndex && _visitedTabIndices.contains(index)) {
      return;
    }
    setState(() {
      _selectedIndex = index;
      _visitedTabIndices.add(index);
    });
  }

  Widget _buildTab(int index, Object revision) {
    if (!_visitedTabIndices.contains(index)) {
      return const SizedBox.shrink();
    }
    return switch (index) {
      0 => KeyedSubtree(
        key: ValueKey('shift-$revision'),
        child: ShiftDashboard(onVarianceTap: () => _navigateTo(1)),
      ),
      1 => KeyedSubtree(
        key: ValueKey('variance-$revision'),
        child: const VarianceReport(),
      ),
      2 => KeyedSubtree(
        key: ValueKey('schedule-$revision'),
        child: const ScheduleBuilder(),
      ),
      3 => KeyedSubtree(
        key: ValueKey('baseline-$revision'),
        child: const BaselineTracker(),
      ),
      _ => const SizedBox.shrink(),
    };
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
      unawaited(_loadOrgHierarchyIfNeeded(session));
    }
    final routeState = _TeamSettingsRouteStateMirror.capture(this);
    try {
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => SettingsScreen(
            advisorModelConfigService: advisorConfig,
            advisorCorpusAdminService: corpusAdmin,
            teamActor: teamActor,
            teamRoleOptions: routeState.teamRoleOptions.value,
            teamRoleOptionsListenable: routeState.teamRoleOptions,
            teamRoleCatalog: routeState.teamRoleCatalog.value,
            teamRoleCatalogListenable: routeState.teamRoleCatalog,
            teamRoleCatalogLoadState: routeState.teamRoleCatalogLoadState.value,
            teamRoleCatalogLoadStateListenable:
                routeState.teamRoleCatalogLoadState,
            teamLocationOptions: session == null
                ? const <TeamLocationOption>[]
                : <TeamLocationOption>[
                    TeamLocationOption(
                      locationId: session.locationId,
                      label: restaurant?.displayName ?? 'Current location',
                    ),
                  ],
            teamOrgUnitOptions: routeState.teamOrgUnitOptions.value,
            teamOrgUnits: routeState.teamOrgUnits.value,
            teamOrgLocations: routeState.teamOrgLocations.value,
            teamOrgUnitsListenable: routeState.teamOrgUnits,
            teamOrgLocationsListenable: routeState.teamOrgLocations,
            teamOrgUnitOptionsListenable: routeState.teamOrgUnitOptions,
            teamOrgHierarchyLoadState:
                routeState.teamOrgHierarchyLoadState.value,
            teamOrgHierarchyLoadStateListenable:
                routeState.teamOrgHierarchyLoadState,
            onTeamOrgUnitCreate: _teamOrgUnitCreateRequester(session),
            onTeamLocationMove: _teamLocationMoveRequester(session),
            teamUsers: routeState.teamUsers.value,
            teamUsersListenable: routeState.teamUsers,
            teamPendingInvites: routeState.teamPendingInvites.value,
            teamPendingInvitesListenable: routeState.teamPendingInvites,
            teamDataLoadState: routeState.teamDataLoadState.value,
            teamDataLoadStateListenable: routeState.teamDataLoadState,
            onTeamInviteSubmitted: _teamInviteSubmitter(session),
            onTeamInviteRevoked: _teamInviteRevoker(session),
            onTeamUserAction: _teamUserActionHandler(session),
            onTeamDataRetry: _teamDataRetryRequester(session),
            onTeamRoleCreate: _teamRoleCreateRequester(session),
            onTeamRolePatch: _teamRolePatchRequester(session),
            onTeamRoleDelete: _teamRoleDeleteRequester(session),
            passwordChangeGateway: widget.passwordChangeGateway,
            accountInfoGateway: widget.accountInfoGateway,
            mfaOperationsGateway: widget.mfaOperationsGateway,
            // Phase 9.UX.5 - Active Sessions in Account tab. Demo /
            // unauth shells fall back to the in-memory fixture so the
            // walkthrough can show multiple devices without a backend.
            authOperationsGateway: widget.authOperationsGateway,
            allowDemoActiveSessionsFallback:
                widget.authOperationsGateway == null,
            // Phase 9.UX.6 - Audit Log in Account tab. Same fallback
            // rule as Active Sessions: when no live gateway is wired,
            // use the in-memory fixture so the walkthrough can render
            // demo events without a backend.
            allowDemoAuditLogFallback: widget.authOperationsGateway == null,
          ),
          fullscreenDialog: true,
        ),
      );
    } finally {
      routeState.dispose();
    }
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

  Future<void> _loadTeamRoleOptionsIfNeeded(
    AuthSession session, {
    bool force = false,
  }) async {
    final gateway = widget.authOperationsGateway;
    if (gateway == null) {
      _publishTeamRoleCatalogLoadState(TeamRoleCatalogLoadState.ready);
      return;
    }
    final key = '${session.userId}|${session.operatorId}|${session.locationId}';
    if (!force && _teamRolesLoadedFor == key) {
      _publishTeamRoleCatalogLoadState(TeamRoleCatalogLoadState.ready);
      return;
    }
    if (_teamRolesLoadingFor == key) {
      _publishTeamRoleCatalogLoadState(
        TeamRoleCatalogLoadState(
          loading: true,
          loaded: _teamRolesLoadedFor == key,
        ),
      );
      return;
    }
    _teamRolesLoadingFor = key;
    _publishTeamRoleCatalogLoadState(
      TeamRoleCatalogLoadState(
        loading: true,
        loaded: _teamRolesLoadedFor == key,
      ),
    );
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
      _publishTeamRoleCatalog(roles, loadedKey: key);
      _publishTeamRoleCatalogLoadState(TeamRoleCatalogLoadState.ready);
    } catch (error) {
      debugPrint('Team role catalog load failed: $error');
      _publishTeamRoleCatalogLoadState(
        TeamRoleCatalogLoadState(
          loaded: _teamRolesLoadedFor == key,
          errorMessage: _teamRoleCatalogLoadMessage(error),
        ),
      );
    } finally {
      if (_teamRolesLoadingFor == key) _teamRolesLoadingFor = null;
    }
  }

  void _publishTeamRoleCatalogLoadState(TeamRoleCatalogLoadState next) {
    if (!mounted) return;
    final current = _teamRoleCatalogLoadState;
    if (current.loading == next.loading &&
        current.loaded == next.loaded &&
        current.errorMessage == next.errorMessage) {
      return;
    }
    _teamRoleCatalogLoadState = next;
    _teamRoleCatalogLoadStateListenable.value = next;
  }

  String _teamRoleCatalogLoadMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('status: 404') || text.contains('not found')) {
      return 'Role route not found. Rebuild with the staging proxy.';
    }
    if (text.contains('status: 401')) {
      return 'Sign in again before loading roles.';
    }
    if (text.contains('status: 403')) {
      return 'You do not have access to role management.';
    }
    if (text.contains('timeout')) {
      return 'Role catalog timed out before the proxy responded. Retry.';
    }
    if (text.contains('transport_error') || text.contains('status: null')) {
      return 'Could not reach the proxy. Check connection and retry.';
    }
    return 'Could not load role catalog. Try again.';
  }

  TeamDataRetryRequester? _teamDataRetryRequester(AuthSession? session) {
    if (session == null) return null;
    return () async {
      if (!mounted) return;
      await Future.wait<void>(<Future<void>>[
        _loadTeamRoleOptionsIfNeeded(session, force: true),
        _loadTeamDataIfNeeded(session, force: true),
        _loadOrgHierarchyIfNeeded(session, force: true),
      ]);
    };
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
    if (!mounted) return;
    if (_teamDataLoadState.loading == next.loading &&
        _teamDataLoadState.loaded == next.loaded) {
      return;
    }
    _teamDataLoadState = next;
    _teamDataLoadStateListenable.value = next;
  }

  TeamUserListItem _teamUserFromEntry(TeamUserListEntry entry) {
    return teamUserListItemFromEntry(entry, roleOptions: _teamRoleOptions);
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
      orgUnitId: entry.orgUnitId,
      orgUnitLabel: entry.orgUnitLabel,
      expiresAt: entry.expiresAt,
    );
  }

  // Phase 9.UX.4 — load org hierarchy alongside Team data. The
  // gateway's `listOrgHierarchy` is a tenant-scoped read; if the
  // gateway is not wired we fall back to a deterministic
  // demo-mode fixture so the kDemoMode walkthrough completes
  // without a backend (per Block 3 requirement).
  Future<void> _loadOrgHierarchyIfNeeded(
    AuthSession session, {
    bool force = false,
  }) async {
    final key = '${session.userId}|${session.operatorId}|${session.locationId}';
    if (!force && _teamOrgHierarchyLoadedFor == key) {
      _publishOrgHierarchyLoadState(TeamOrgHierarchyLoadState.ready);
      return;
    }
    if (_teamOrgHierarchyLoadingFor == key) {
      _publishOrgHierarchyLoadState(
        TeamOrgHierarchyLoadState(
          loading: true,
          loaded: _teamOrgHierarchyLoadedFor == key,
        ),
      );
      return;
    }
    _teamOrgHierarchyLoadingFor = key;
    _publishOrgHierarchyLoadState(
      TeamOrgHierarchyLoadState(
        loading: true,
        loaded: _teamOrgHierarchyLoadedFor == key,
      ),
    );
    final gateway = widget.authOperationsGateway;
    if (gateway == null) {
      // Demo / unauth path: seed an in-memory hierarchy keyed on the
      // session's operator + location so the walkthrough click path
      // can move the location and grant org-unit scope without a
      // backend round-trip.
      if (mounted) {
        _publishOrgHierarchy(
          orgUnits: _demoOrgUnitsFor(session),
          locations: _demoOrgLocationsFor(session),
          loadedKey: key,
        );
      }
      _publishOrgHierarchyLoadState(TeamOrgHierarchyLoadState.ready);
      _teamOrgHierarchyLoadingFor = null;
      return;
    }
    try {
      final listed = await gateway.listOrgHierarchy(
        TeamOrgHierarchyListCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
        ),
      );
      if (!mounted) return;
      _publishOrgHierarchy(
        orgUnits: listed.orgUnits,
        locations: listed.locations,
        loadedKey: key,
      );
      _publishOrgHierarchyLoadState(TeamOrgHierarchyLoadState.ready);
    } catch (error) {
      debugPrint('Org hierarchy load failed: $error');
      _publishOrgHierarchyLoadState(
        TeamOrgHierarchyLoadState(
          loaded: _teamOrgHierarchyLoadedFor == key,
          errorMessage: _orgHierarchyLoadMessage(error),
        ),
      );
    } finally {
      if (_teamOrgHierarchyLoadingFor == key) {
        _teamOrgHierarchyLoadingFor = null;
      }
    }
  }

  /// Single fan-out for org hierarchy state changes — keeps the
  /// `_team*` snapshots, the listenables, and the derived
  /// `TeamOrgUnitOption` projection in sync. The listenables drive
  /// the open Settings route's rebuilds; the snapshot fields seed
  /// fresh route opens before the listenable yields.
  void _publishOrgHierarchy({
    required List<TeamOrgUnitEntry> orgUnits,
    required List<TeamOrgLocationEntry> locations,
    String? loadedKey,
  }) {
    setState(() {
      _teamOrgUnits = orgUnits;
      _teamOrgLocations = locations;
      if (loadedKey != null) _teamOrgHierarchyLoadedFor = loadedKey;
    });
    _teamOrgUnitsListenable.value = orgUnits;
    _teamOrgLocationsListenable.value = locations;
    _teamOrgUnitOptionsListenable.value = orgUnits
        .map(
          (unit) => TeamOrgUnitOption(
            orgUnitId: unit.orgUnitId,
            label: unit.label,
            path: unit.path,
          ),
        )
        .toList(growable: false);
  }

  void _publishOrgHierarchyLoadState(TeamOrgHierarchyLoadState next) {
    if (!mounted) return;
    final current = _teamOrgHierarchyLoadState;
    if (current.loading == next.loading &&
        current.loaded == next.loaded &&
        current.errorMessage == next.errorMessage) {
      return;
    }
    _teamOrgHierarchyLoadState = next;
    _teamOrgHierarchyLoadStateListenable.value = next;
  }

  String _orgHierarchyLoadMessage(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('status: 404') || text.contains('not found')) {
      return 'Hierarchy route not found. Rebuild with the staging proxy.';
    }
    if (text.contains('status: 401') || text.contains('status: 403')) {
      return 'You do not have access to this hierarchy.';
    }
    if (text.contains('transport_error') || text.contains('status: null')) {
      return 'Could not reach the proxy. Check connection and retry.';
    }
    return 'Could not load hierarchy. Try again.';
  }

  TeamOrgUnitCreateRequester? _teamOrgUnitCreateRequester(
    AuthSession? session,
  ) {
    if (session == null) return null;
    return (draft) async {
      final gateway = widget.authOperationsGateway;
      if (gateway == null) {
        // Demo-mode write: append a new org unit + refresh the
        // listenable so the walkthrough sees the new node land
        // immediately.
        final parent = _teamOrgUnits.firstWhere(
          (unit) => unit.orgUnitId == draft.parentOrgUnitId,
          orElse: () => _teamOrgUnits.isEmpty
              ? _demoRootFor(session)
              : _teamOrgUnits.first,
        );
        final created = TeamOrgUnitEntry(
          orgUnitId: 'demo-org-unit-${DateTime.now().microsecondsSinceEpoch}',
          parentOrgUnitId: parent.orgUnitId,
          unitType: draft.unitType,
          path: '${parent.path}.${draft.label}',
          label: draft.name,
        );
        if (mounted) {
          _publishOrgHierarchy(
            orgUnits: <TeamOrgUnitEntry>[..._teamOrgUnits, created],
            locations: _teamOrgLocations,
          );
        }
        return TeamOrgUnitCreated(orgUnitId: created.orgUnitId);
      }
      final created = await gateway.createOrgUnit(
        TeamOrgUnitCreateCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          parentOrgUnitId: draft.parentOrgUnitId,
          unitType: draft.unitType,
          label: draft.label,
          name: draft.name,
        ),
      );
      unawaited(_loadOrgHierarchyIfNeeded(session, force: true));
      return created;
    };
  }

  TeamLocationOrgUnitMoveRequester? _teamLocationMoveRequester(
    AuthSession? session,
  ) {
    if (session == null) return null;
    return (draft) async {
      final gateway = widget.authOperationsGateway;
      if (gateway == null) {
        final parent = _teamOrgUnits.firstWhere(
          (unit) => unit.orgUnitId == draft.parentOrgUnitId,
          orElse: () => _demoRootFor(session),
        );
        if (mounted) {
          final nextLocations = _teamOrgLocations
              .map(
                (loc) => loc.locationId == draft.locationId
                    ? TeamOrgLocationEntry(
                        locationId: loc.locationId,
                        parentOrgUnitId: parent.orgUnitId,
                        orgUnitPath: parent.path,
                        label: loc.label,
                      )
                    : loc,
              )
              .toList(growable: false);
          _publishOrgHierarchy(
            orgUnits: _teamOrgUnits,
            locations: nextLocations,
          );
        }
        return const TeamLocationOrgUnitMoved(moved: true);
      }
      final moved = await gateway.moveLocationToOrgUnit(
        TeamLocationOrgUnitMoveCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          targetLocationId: draft.locationId,
          parentOrgUnitId: draft.parentOrgUnitId,
        ),
      );
      unawaited(_loadOrgHierarchyIfNeeded(session, force: true));
      return moved;
    };
  }

  TeamOrgUnitEntry _demoRootFor(AuthSession session) {
    return TeamOrgUnitEntry(
      orgUnitId: 'demo-root-${session.operatorId}',
      parentOrgUnitId: null,
      unitType: 'corp',
      path: 'forgeflow',
      label: 'Forge & Flow',
    );
  }

  List<TeamOrgUnitEntry> _demoOrgUnitsFor(AuthSession session) {
    return <TeamOrgUnitEntry>[_demoRootFor(session)];
  }

  List<TeamOrgLocationEntry> _demoOrgLocationsFor(AuthSession session) {
    final root = _demoRootFor(session);
    return <TeamOrgLocationEntry>[
      TeamOrgLocationEntry(
        locationId: session.locationId,
        parentOrgUnitId: root.orgUnitId,
        orgUnitPath: root.path,
        label: 'Current location',
      ),
    ];
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
              targetOrgUnitId: request.orgUnitId,
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

  SettingsRoleCreateRequester? _teamRoleCreateRequester(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (result) async {
      final created = await gateway.createRole(
        TeamRoleCreateCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          roleKey: result.roleKey,
          displayName: result.displayName,
          description: result.description,
          permissions: result.permissionUpdates,
          reason: 'settings_custom_role_create',
        ),
      );
      _upsertTeamRole(created.role);
      unawaited(_loadTeamRoleOptionsIfNeeded(session, force: true));
      return created.role;
    };
  }

  SettingsRolePatchRequester? _teamRolePatchRequester(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (result) async {
      if (result.roleId.trim().isEmpty) {
        throw StateError('Role patch was missing a role id.');
      }
      final patched = await gateway.patchRole(
        TeamRolePatchCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          roleId: result.roleId,
          displayName: result.displayName,
          description: result.description,
          permissions: result.permissionUpdates,
          reason: 'settings_custom_role_update',
        ),
      );
      _upsertTeamRole(patched.role);
      unawaited(_loadTeamRoleOptionsIfNeeded(session, force: true));
      return patched.role;
    };
  }

  SettingsRoleDeleteRequester? _teamRoleDeleteRequester(AuthSession? session) {
    final gateway = widget.authOperationsGateway;
    if (gateway == null || session == null) return null;
    return (role) async {
      final deleted = await gateway.deleteRole(
        TeamRoleDeleteCommand(
          actorUserId: session.userId,
          operatorId: session.operatorId,
          locationId: session.locationId,
          roleId: role.roleId,
          reason: 'settings_custom_role_delete',
        ),
      );
      if (deleted.deleted) {
        _removeTeamRole(role.roleId);
        unawaited(_loadTeamRoleOptionsIfNeeded(session, force: true));
      }
      return deleted.deleted;
    };
  }

  void _upsertTeamRole(TeamRoleCatalogEntry role) {
    final next = <TeamRoleCatalogEntry>[];
    var replaced = false;
    for (final existing in _teamRoleCatalog) {
      if (existing.roleId == role.roleId) {
        next.add(role);
        replaced = true;
      } else {
        next.add(existing);
      }
    }
    if (!replaced) next.add(role);
    _publishTeamRoleCatalog(next);
  }

  void _removeTeamRole(String roleId) {
    final next = _teamRoleCatalog
        .where((role) => role.roleId != roleId)
        .toList(growable: false);
    _publishTeamRoleCatalog(next);
  }

  void _publishTeamRoleCatalog(
    List<TeamRoleCatalogEntry> roles, {
    String? loadedKey,
  }) {
    if (!mounted) return;
    final nextCatalog = List<TeamRoleCatalogEntry>.unmodifiable(roles);
    final nextOptions = nextCatalog
        .map(
          (role) =>
              TeamRoleOption(roleId: role.roleId, label: role.displayName),
        )
        .toList(growable: false);
    final nextRoleIdsByKey = <String, String>{
      for (final role in nextCatalog) role.roleKey: role.roleId,
    };
    setState(() {
      if (loadedKey != null) _teamRolesLoadedFor = loadedKey;
      _teamRoleCatalog = nextCatalog;
      _teamRoleIdsByKey = nextRoleIdsByKey;
      if (nextOptions.isNotEmpty) _teamRoleOptions = nextOptions;
    });
    _teamRoleCatalogListenable.value = nextCatalog;
    if (nextOptions.isNotEmpty) {
      _teamRoleOptionsListenable.value = nextOptions;
    }
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
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Center(child: SyncStateBadge()),
        ),
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
                const SyncStateBadge(),
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

    // Phase 10a.UX.0 — prefer the bootstrap-provided
    // [RealtimeSubscription] when wired (production main entry +
    // proxy URI). Fall back to the test-injected stream so widget
    // tests stay scriptable. The subscription emits its current
    // state synchronously via [currentConnectionState], so seed the
    // [StreamBuilder] with that to avoid a brief idle/hidden flash
    // on shell mount.
    final bootstrapSubscription = _resolveRealtimeSubscription();
    final Stream<RealtimeConnectionState>? connectionStream =
        bootstrapSubscription?.connectionState ?? widget.realtimeConnectionState;
    final RealtimeConnectionState initialState = bootstrapSubscription != null
        ? bootstrapSubscription.currentConnectionState
        : widget.realtimeInitialConnectionState;
    return RealtimeConnectionScope(
      connectionStateStream: connectionStream,
      initialState: initialState,
      child: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        appBar: widget.embeddedInBarrio ? embeddedAppBar : standaloneAppBar,
        body: SafeArea(
          top: !widget.embeddedInBarrio,
          child: IndexedStack(
            index: _selectedIndex,
            children: List<Widget>.generate(
              4,
              (index) => _buildTab(index, revision),
            ),
          ),
        ),
        bottomNavigationBar: _AppBottomNav(
          selectedIndex: _selectedIndex,
          onTap: _navigateTo,
        ),
      ),
    );
  }
}

/// Phase 9.UX.grant-payload — pure mapping from the gateway-side
/// [TeamUserListEntry] to the section-side [TeamUserListItem]. Lives at
/// top-level so `_teamUserFromEntry` stays a thin wrapper and the grant
/// translation is testable without booting the AppShell widget tree.
///
/// Each `TeamGrantSnapshot` carries an authoritative `roleLabel` joined
/// inside the gateway projection, so the dialog never depends on the
/// section's role-catalog load completing before the user list. The
/// `roleOptions` argument is only consulted when the gateway emits a
/// snapshot with `roleLabel == null` (e.g., a stale proxy that has not
/// rolled out the additive field yet) — the entry's primary roleLabel
/// and the in-section catalog are used as fallbacks before the raw
/// roleId.
TeamUserListItem teamUserListItemFromEntry(
  TeamUserListEntry entry, {
  List<TeamRoleOption> roleOptions = const <TeamRoleOption>[],
}) {
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
    grants: entry.grants
        .map(
          (grant) => TeamUserRoleGrant(
            userRoleId: grant.userRoleId,
            roleId: grant.roleId,
            roleLabel: _grantRoleLabelFor(entry, roleOptions, grant),
            scopeType: grant.scopeType,
            locationId: grant.locationId,
            orgUnitId: grant.orgUnitId,
            effectiveLocationIds: grant.effectiveLocationIds,
          ),
        )
        .toList(growable: false),
  );
}

String _grantRoleLabelFor(
  TeamUserListEntry entry,
  List<TeamRoleOption> roleOptions,
  TeamGrantSnapshot grant,
) {
  final supplied = grant.roleLabel;
  if (supplied != null && supplied.isNotEmpty) return supplied;
  if (entry.roleId == grant.roleId && entry.roleLabel.isNotEmpty) {
    return entry.roleLabel;
  }
  for (final option in roleOptions) {
    if (option.roleId == grant.roleId) return option.label;
  }
  return grant.roleId;
}

class _TeamSettingsRouteStateMirror {
  _TeamSettingsRouteStateMirror._({
    required this.teamRoleOptions,
    required this.teamRoleCatalog,
    required this.teamRoleCatalogLoadState,
    required this.teamUsers,
    required this.teamPendingInvites,
    required this.teamDataLoadState,
    required this.teamOrgUnits,
    required this.teamOrgLocations,
    required this.teamOrgUnitOptions,
    required this.teamOrgHierarchyLoadState,
    required List<VoidCallback> detachListeners,
  }) : _detachListeners = detachListeners;

  factory _TeamSettingsRouteStateMirror.capture(_AppShellState owner) {
    final detachListeners = <VoidCallback>[];
    final mirror = _TeamSettingsRouteStateMirror._(
      teamRoleOptions: ValueNotifier<List<TeamRoleOption>>(
        owner._teamRoleOptionsListenable.value,
      ),
      teamRoleCatalog: ValueNotifier<List<TeamRoleCatalogEntry>>(
        owner._teamRoleCatalogListenable.value,
      ),
      teamRoleCatalogLoadState: ValueNotifier<TeamRoleCatalogLoadState>(
        owner._teamRoleCatalogLoadStateListenable.value,
      ),
      teamUsers: ValueNotifier<List<TeamUserListItem>>(
        owner._teamUsersListenable.value,
      ),
      teamPendingInvites: ValueNotifier<List<TeamPendingInviteListItem>>(
        owner._teamPendingInvitesListenable.value,
      ),
      teamDataLoadState: ValueNotifier<TeamSettingsDataLoadState>(
        owner._teamDataLoadStateListenable.value,
      ),
      teamOrgUnits: ValueNotifier<List<TeamOrgUnitEntry>>(
        owner._teamOrgUnitsListenable.value,
      ),
      teamOrgLocations: ValueNotifier<List<TeamOrgLocationEntry>>(
        owner._teamOrgLocationsListenable.value,
      ),
      teamOrgUnitOptions: ValueNotifier<List<TeamOrgUnitOption>>(
        owner._teamOrgUnitOptionsListenable.value,
      ),
      teamOrgHierarchyLoadState: ValueNotifier<TeamOrgHierarchyLoadState>(
        owner._teamOrgHierarchyLoadStateListenable.value,
      ),
      detachListeners: detachListeners,
    );

    mirror._mirror(
      owner._teamRoleOptionsListenable,
      mirror.teamRoleOptions,
      detachListeners,
    );
    mirror._mirror(
      owner._teamRoleCatalogListenable,
      mirror.teamRoleCatalog,
      detachListeners,
    );
    mirror._mirror(
      owner._teamRoleCatalogLoadStateListenable,
      mirror.teamRoleCatalogLoadState,
      detachListeners,
    );
    mirror._mirror(
      owner._teamUsersListenable,
      mirror.teamUsers,
      detachListeners,
    );
    mirror._mirror(
      owner._teamPendingInvitesListenable,
      mirror.teamPendingInvites,
      detachListeners,
    );
    mirror._mirror(
      owner._teamDataLoadStateListenable,
      mirror.teamDataLoadState,
      detachListeners,
    );
    mirror._mirror(
      owner._teamOrgUnitsListenable,
      mirror.teamOrgUnits,
      detachListeners,
    );
    mirror._mirror(
      owner._teamOrgLocationsListenable,
      mirror.teamOrgLocations,
      detachListeners,
    );
    mirror._mirror(
      owner._teamOrgUnitOptionsListenable,
      mirror.teamOrgUnitOptions,
      detachListeners,
    );
    mirror._mirror(
      owner._teamOrgHierarchyLoadStateListenable,
      mirror.teamOrgHierarchyLoadState,
      detachListeners,
    );
    return mirror;
  }

  final ValueNotifier<List<TeamRoleOption>> teamRoleOptions;
  final ValueNotifier<List<TeamRoleCatalogEntry>> teamRoleCatalog;
  final ValueNotifier<TeamRoleCatalogLoadState> teamRoleCatalogLoadState;
  final ValueNotifier<List<TeamUserListItem>> teamUsers;
  final ValueNotifier<List<TeamPendingInviteListItem>> teamPendingInvites;
  final ValueNotifier<TeamSettingsDataLoadState> teamDataLoadState;
  final ValueNotifier<List<TeamOrgUnitEntry>> teamOrgUnits;
  final ValueNotifier<List<TeamOrgLocationEntry>> teamOrgLocations;
  final ValueNotifier<List<TeamOrgUnitOption>> teamOrgUnitOptions;
  final ValueNotifier<TeamOrgHierarchyLoadState> teamOrgHierarchyLoadState;
  final List<VoidCallback> _detachListeners;
  bool _disposed = false;

  void _mirror<T>(
    ValueListenable<T> source,
    ValueNotifier<T> target,
    List<VoidCallback> detachListeners,
  ) {
    void listener() {
      if (!_disposed) target.value = source.value;
    }

    source.addListener(listener);
    detachListeners.add(() => source.removeListener(listener));
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final detach in _detachListeners.reversed) {
      detach();
    }
    teamRoleOptions.dispose();
    teamRoleCatalog.dispose();
    teamRoleCatalogLoadState.dispose();
    teamUsers.dispose();
    teamPendingInvites.dispose();
    teamDataLoadState.dispose();
    teamOrgUnits.dispose();
    teamOrgLocations.dispose();
    teamOrgUnitOptions.dispose();
    teamOrgHierarchyLoadState.dispose();
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
