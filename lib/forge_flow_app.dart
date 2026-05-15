import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'auth/auth_session.dart';
import 'auth/permission_effect.dart';
import 'domain/models/restaurant_location.dart';
import 'domain/models/business_scope.dart';
import 'services/app_notification_service.dart';
import 'services/auth/auth_operations_gateway.dart';
import 'services/auth/handoff_code_gateway.dart';
import 'services/auth/password_change_gateway.dart';
import 'services/auth/password_reset_deep_link_source.dart';
import 'services/auth/password_reset_gateway.dart';
import 'services/auth/proxy_permission_snapshot_loader.dart';
import 'services/boundary_event_outbox.dart';
import 'services/business_date_authority_service.dart';
import 'services/sqlite_boundary_event_outbox.dart';
import 'services/mfa/mfa_operations_gateway.dart';
import 'services/mfa/mfa_recovery_request_gateway.dart';
import 'services/mobile_push/mobile_push_notification_service.dart';
import 'services/shift_data_source.dart';
import 'services/scope/business_scope_repository.dart';
import 'services/team/team_scope_visibility_policy.dart';
import 'state/active_target_profile_notifier.dart';
import 'state/app_refresh_coordinator.dart';
import 'state/app_runtime_invalidation_bus.dart';
import 'state/auth_session_notifier.dart';
import 'state/demand_forecast_context_notifier.dart';
import 'state/demo_mode_state_notifier.dart';
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
import 'services/sync/sync_proxy_client.dart';
import 'widgets/demo_mode_banner.dart';
import 'widgets/operator_brand_mark.dart';
import 'widgets/peer_edit_toast.dart';
import 'screens/schedule_builder.dart';
import 'screens/settings_screen.dart';
import 'screens/shift_dashboard.dart';
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
    this.handoffCodeGateway,
  });

  final bool requireAuth;
  final PermissionContextLoader? permissionContextLoader;
  final AuthOperationsGateway? authOperationsGateway;
  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;
  final HandoffCodeGateway? handoffCodeGateway;
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
      handoffCodeGateway: handoffCodeGateway,
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
        // MP6 — French (Quebec) localization support.
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en'),
          Locale('fr'),
          Locale('fr', 'CA'),
        ],
        // Phase 10a.UX.1 — wrap the home content in (a) the realtime
        // producer wiring that pipes 10a.UX.0's shared
        // [RealtimeSubscription.events] into the
        // [RealtimeEventBus] (and clears the freshness map on
        // sign-out / operator change), and (b) a shell-level
        // [PeerEditToast] so a shared-state frame surfaces a
        // SnackBar across every route. The subscription itself is
        // owned by the bootstrap layer (10a.UX.0); this widget
        // consumes it via Provider so both lanes share one socket.
        home: _MobilePushRouteIntentHost(
          child: _RealtimeProducerWiring(
            child: _PeerEditToastShellHost(child: homeContent),
          ),
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
class _MobilePushRouteIntentHost extends StatefulWidget {
  const _MobilePushRouteIntentHost({required this.child});

  final Widget child;

  @override
  State<_MobilePushRouteIntentHost> createState() =>
      _MobilePushRouteIntentHostState();
}

class _MobilePushRouteIntentHostState
    extends State<_MobilePushRouteIntentHost> {
  StreamSubscription<MobilePushRouteIntent>? _subscription;
  MobilePushRouteIntentSource? _source;
  bool _openingNotifications = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final source = _resolveSource();
    if (identical(source, _source)) return;
    _subscription?.cancel();
    _source = source;
    if (source == null) return;
    _subscription = source.intents.listen(_handleIntent);
    for (final intent in source.takePendingIntents()) {
      _handleIntent(intent);
    }
  }

  MobilePushRouteIntentSource? _resolveSource() {
    try {
      return Provider.of<MobilePushRouteIntentSource>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _handleIntent(MobilePushRouteIntent intent) {
    if (!mounted) return;
    if (intent.destination == MobilePushRouteDestination.notifications) {
      _openNotificationsFromIntent();
    }
  }

  void _openNotificationsFromIntent() {
    if (_openingNotifications) return;
    _openingNotifications = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _openingNotifications = false;
        return;
      }
      final route = MaterialPageRoute<void>(
        settings: const RouteSettings(name: NotificationsScreen.routeName),
        builder: (_) => const NotificationsScreen(),
        fullscreenDialog: true,
      );
      unawaited(
        Navigator.of(context).push<void>(route).whenComplete(() {
          _openingNotifications = false;
        }),
      );
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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
      return Provider.of<LastSyncedTimestampsNotifier>(context, listen: false);
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
        // 8.demo-mode-banner — runtime per-(operator, location, category)
        // demo-mode notifier. The AppShell-mounted [DemoModeBanner]
        // watches this so the banner reflects the live `demo_mode_state`
        // rows pulled via the proxy. Bound to the active scope from
        // inside the AppShell (auth session + RestaurantScopeNotifier);
        // bound to the proxy `SyncProxyClient` so a refresh round-trips
        // through `/v1/operators/{op}/locations/{loc}/demo_mode_states`.
        ChangeNotifierProvider<DemoModeStateNotifier>(
          create: (_) => DemoModeStateNotifier(),
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
  final HandoffCodeGateway? handoffCodeGateway;

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
    this.handoffCodeGateway,
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

  /// Tracks whether the app has been backgrounded at least once.
  /// Prevents the cold-start `resumed` callback from triggering a
  /// duplicate refresh — notifiers already load in their constructors.
  bool _hasBeenBackgrounded = false;
  String? _businessScopesLoadedFor;
  String? _businessScopesLoadingFor;
  String? _businessScopesPendingReloadFor;
  final TextEditingController _businessScopeSearchController =
      TextEditingController();
  String _businessScopeSearchQuery = '';
  RealtimeEventBus? _businessScopeRealtimeBus;
  StreamSubscription<RealtimeEvent>? _businessScopeRealtimeSubscription;

  /// Foreground-only business-date boundary supervisor. Spawns one
  /// `CurrentStateBoundaryMonitor` per accessible `RestaurantLocation`
  /// so multi-location operators get independent restaurant-local
  /// boundary clocks (Time Boundary Contract Rule 1).
  BoundaryMonitorSupervisor? _boundarySupervisor;
  RestaurantScopeNotifier? _scopeListenedFor;

  // 8.demo-mode-banner — bookkeeping for the runtime demo-mode
  // notifier. The notifier instance lives in [ForgeFlowScope]; the
  // shell binds the active [SyncProxyClient] + (operator, location)
  // scope and listens to scope/auth changes so the banner refreshes
  // whenever the operator switches scope or the auth session flips.
  AuthSessionNotifier? _demoModeAuthListenedTo;
  RestaurantScopeNotifier? _demoModeScopeListenedTo;
  String? _demoModeBoundScopeKey;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindBusinessScopeRealtimeBus();
    _bindDemoModeNotifier();
  }

  /// 8.demo-mode-banner — bind the runtime demo-mode notifier to the
  /// active [SyncProxyClient] (so it can pull
  /// `demo_mode_state` rows via the proxy) and to the live
  /// (operator, location) scope. Re-evaluates whenever the auth
  /// session or restaurant scope changes; the notifier itself
  /// debounces same-scope rebinds and only fires a refresh when the
  /// scope actually flips. Demo / no-Firebase shells have a null
  /// client; the notifier stays silent and the banner stays hidden.
  void _bindDemoModeNotifier() {
    final notifier = _resolveDemoModeNotifier();
    if (notifier == null) return;
    notifier.bindClient(_resolveSyncProxyClient());

    // Watch the auth notifier so login/logout/operator flips push a
    // new scope into the demo notifier.
    AuthSessionNotifier? authNotifier;
    try {
      authNotifier = Provider.of<AuthSessionNotifier>(context, listen: false);
    } on ProviderNotFoundException {
      authNotifier = null;
    }
    if (!identical(authNotifier, _demoModeAuthListenedTo)) {
      _demoModeAuthListenedTo?.removeListener(_syncDemoModeScope);
      _demoModeAuthListenedTo = authNotifier;
      _demoModeAuthListenedTo?.addListener(_syncDemoModeScope);
    }

    // Watch the restaurant scope so a business-scope drawer flip pushes
    // the new (operator, location) into the demo notifier even when
    // the auth session itself does not change.
    RestaurantScopeNotifier? scopeNotifier;
    try {
      scopeNotifier = Provider.of<RestaurantScopeNotifier>(
        context,
        listen: false,
      );
    } on ProviderNotFoundException {
      scopeNotifier = null;
    }
    if (!identical(scopeNotifier, _demoModeScopeListenedTo)) {
      _demoModeScopeListenedTo?.removeListener(_syncDemoModeScope);
      _demoModeScopeListenedTo = scopeNotifier;
      _demoModeScopeListenedTo?.addListener(_syncDemoModeScope);
    }
    _syncDemoModeScope();
  }

  /// Resolves the bootstrap-provided [SyncProxyClient] from the
  /// surrounding Provider tree. Null when no proxy is wired (demo /
  /// widget tests / no-Firebase shells).
  SyncProxyClient? _resolveSyncProxyClient() {
    try {
      return Provider.of<SyncProxyClient?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Resolves the [DemoModeStateNotifier] from the surrounding
  /// Provider tree. Returns null when the shell mounts under a tree
  /// that did not include [ForgeFlowScope] (e.g. some widget tests).
  DemoModeStateNotifier? _resolveDemoModeNotifier() {
    try {
      return Provider.of<DemoModeStateNotifier>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Compute the live (operator, location) scope and push it into the
  /// demo notifier. Called on auth changes, on restaurant-scope
  /// changes, and from `_bindDemoModeNotifier`.
  void _syncDemoModeScope() {
    if (!mounted) return;
    final notifier = _resolveDemoModeNotifier();
    if (notifier == null) return;
    final session = _demoModeAuthListenedTo?.session;
    final scope = _demoModeScopeListenedTo?.activeScope;
    final operatorId = scope?.operatorId ?? session?.operatorId ?? '';
    final locationId = scope?.locationId ?? session?.locationId ?? '';
    if (operatorId.isEmpty || locationId.isEmpty) {
      _demoModeBoundScopeKey = null;
      notifier.clear();
      return;
    }
    final key = '$operatorId:$locationId';
    if (key == _demoModeBoundScopeKey) return;
    _demoModeBoundScopeKey = key;
    unawaited(
      notifier.setScope(operatorId: operatorId, locationId: locationId),
    );
  }

  void _bindBusinessScopeRealtimeBus() {
    RealtimeEventBus? next;
    try {
      next = Provider.of<RealtimeEventBus>(context, listen: false);
    } on ProviderNotFoundException {
      next = null;
    }
    if (identical(next, _businessScopeRealtimeBus)) return;
    _businessScopeRealtimeSubscription?.cancel();
    _businessScopeRealtimeBus = next;
    _businessScopeRealtimeSubscription = next?.events.listen(
      _handleBusinessScopeRealtimeEvent,
    );
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

  BusinessScopeClient? _resolveBusinessScopeClient() {
    try {
      return Provider.of<BusinessScopeClient?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _loadBusinessScopesIfNeeded(AuthSession? session, {bool force = false}) {
    if (session == null) return;
    final client = _resolveBusinessScopeClient();
    if (client == null) {
      // Mobile-FU-business-scope-drawer-seed — when no networked
      // [BusinessScopeClient] is wired (demo bootstrap, offline first
      // boot, or the brief window before the proxy fetch resolves),
      // seed the in-app business-scope drawer from the locally-seeded
      // `restaurant_locations` rows so the operator sees their active
      // location instead of the empty state. HP #2 compliant: the
      // demo writer side already seeded these rows; this reader does
      // not branch on `kDemoMode`.
      final key = session.userId;
      if (_businessScopesLoadingFor == key) {
        if (force) _businessScopesPendingReloadFor = key;
        return;
      }
      if (!force && _businessScopesLoadedFor == key) return;
      if (force) _businessScopesLoadedFor = null;
      _businessScopesLoadingFor = key;
      final scope = context.read<RestaurantScopeNotifier>();
      unawaited(
        scope
            .seedAvailableScopesFromLocal(
              userId: session.userId,
              operatorId: session.operatorId,
            )
            .then((_) {
              if (!mounted) return;
              _businessScopesLoadedFor = key;
            })
            .catchError((Object error, StackTrace stack) {
              debugPrint('Local business scope seed failed: $error');
              debugPrintStack(stackTrace: stack);
            })
            .whenComplete(() {
              if (_businessScopesLoadingFor == key) {
                _businessScopesLoadingFor = null;
              }
            }),
      );
      return;
    }
    final key = session.userId;
    if (_businessScopesLoadingFor == key) {
      if (force) _businessScopesPendingReloadFor = key;
      return;
    }
    if (!force && _businessScopesLoadedFor == key) {
      return;
    }
    if (force) _businessScopesLoadedFor = null;
    _businessScopesLoadingFor = key;
    final scope = context.read<RestaurantScopeNotifier>();
    unawaited(
      scope
          .loadBusinessScopes(userId: session.userId, client: client)
          .then((_) {
            if (!mounted) return;
            _businessScopesLoadedFor = key;
          })
          .catchError((Object error, StackTrace stack) {
            debugPrint('Business scope load failed: $error');
            debugPrintStack(stackTrace: stack);
          })
          .whenComplete(() {
            if (_businessScopesLoadingFor == key) {
              _businessScopesLoadingFor = null;
            }
            if (!mounted || _businessScopesPendingReloadFor != key) return;
            _businessScopesPendingReloadFor = null;
            final liveSession = _resolveAuthSession();
            if (liveSession?.userId == key) {
              _loadBusinessScopesIfNeeded(liveSession, force: true);
            }
          }),
    );
  }

  void _handleBusinessScopeRealtimeEvent(RealtimeEvent event) {
    final session = _resolveAuthSession();
    if (session != null && event.operatorId == session.operatorId) {
      // 8.demo-mode-banner — integrations / first-backfill activity
      // can flip a `demo_mode_state` row; trigger a refresh whenever
      // we see a relevant topic for the active operator. Topic check
      // is intentionally permissive: any `integrations.*` or
      // `first_backfill.*` frame may have flipped the row, so we ask
      // the notifier to re-pull and let it diff. Same-scope same-rows
      // notifies still fire `notifyListeners`, but the banner is
      // cheap to rebuild.
      if (_isDemoModeInvalidationEvent(event)) {
        unawaited(_resolveDemoModeNotifier()?.refresh() ?? Future.value());
      }
    }
    if (!isBusinessScopeInvalidationEvent(event)) return;
    if (session == null || event.operatorId != session.operatorId) return;
    _loadBusinessScopesIfNeeded(session, force: true);
  }

  /// 8.demo-mode-banner — heuristic that flags a [RealtimeEvent] as
  /// possibly affecting the per-(operator, location, category)
  /// demo-mode state. The proxy does not yet broadcast a dedicated
  /// `integrations.demo_mode_flip` topic; the next-best signal is any
  /// integrations / first-backfill notification, which is the only
  /// path that can flip the row. False positives are harmless — they
  /// trigger an extra proxy round-trip; false negatives leave the
  /// banner stale until the next foreground / scope change refresh.
  static bool _isDemoModeInvalidationEvent(RealtimeEvent event) {
    final topic = event.topic;
    return topic.startsWith('integrations.') ||
        topic.startsWith('first_backfill.') ||
        topic.startsWith('integration.') ||
        topic == 'demo_mode_state.flipped';
  }

  AuthSession? _resolveAuthSession() {
    try {
      return Provider.of<AuthSessionNotifier>(context, listen: false).session;
    } on ProviderNotFoundException {
      return null;
    }
  }

  Future<void> _selectBusinessScope(BusinessScope scope) async {
    if (!scope.isLocationScope) return;
    final session = context.read<AuthSessionNotifier>().session;
    if (session == null) return;
    await context.read<RestaurantScopeNotifier>().activateBusinessScope(
      scope,
      userId: session.userId,
    );
  }

  Widget _buildBusinessScopeDrawer(BuildContext context) {
    final notifier = context.watch<RestaurantScopeNotifier>();
    final scopes = notifier.availableScopes;
    final locationScopes = filterBusinessScopeLocationsForDrawer(scopes, '');
    final filteredScopes = filterBusinessScopeLocationsForDrawer(
      scopes,
      _businessScopeSearchQuery,
    );
    final activeKey = notifier.activeScope?.stableKey;
    return Drawer(
      backgroundColor: AppColors.backgroundDeep,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Text(
                'Locations',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const Key('business_scope_location_search'),
                controller: _businessScopeSearchController,
                onChanged: (value) {
                  setState(() {
                    _businessScopeSearchQuery = value;
                  });
                },
                style: const TextStyle(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Search locations',
                  hintStyle: const TextStyle(color: AppColors.textMuted),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppColors.textMuted,
                  ),
                  suffixIcon: _businessScopeSearchQuery.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          color: AppColors.textMuted,
                          onPressed: () {
                            _businessScopeSearchController.clear();
                            setState(() {
                              _businessScopeSearchQuery = '';
                            });
                          },
                        ),
                  filled: true,
                  fillColor: AppColors.backgroundMid.withValues(alpha: 0.65),
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: locationScopes.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Your available locations will appear here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    )
                  : filteredScopes.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No matching locations.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                      itemCount: filteredScopes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 2),
                      itemBuilder: (context, index) {
                        final scope = filteredScopes[index];
                        final selected = scope.stableKey == activeKey;
                        return BusinessScopeDrawerTile(
                          scope: scope,
                          selected: selected,
                          onTap: () {
                            Navigator.of(context).maybePop();
                            unawaited(_selectBusinessScope(scope));
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
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
    // W2.A — keep the bell badge in sync with the active restaurant.
    if (restaurant != null) {
      unawaited(AppNotificationService.instance.start(restaurant.restaurantId));
    }
  }

  @override
  void dispose() {
    _businessScopeRealtimeSubscription?.cancel();
    _businessScopeRealtimeSubscription = null;
    _businessScopeRealtimeBus = null;
    _businessScopesPendingReloadFor = null;
    _businessScopeSearchController.dispose();
    _scopeListenedFor?.removeListener(_syncSupervisorToScope);
    _scopeListenedFor = null;
    // 8.demo-mode-banner — release the auth/scope listeners the demo
    // notifier was wired through. The notifier itself lives in
    // [ForgeFlowScope] and is disposed by the Provider when the app
    // tree tears down.
    _demoModeAuthListenedTo?.removeListener(_syncDemoModeScope);
    _demoModeAuthListenedTo = null;
    _demoModeScopeListenedTo?.removeListener(_syncDemoModeScope);
    _demoModeScopeListenedTo = null;
    _demoModeBoundScopeKey = null;
    _boundarySupervisor?.dispose();
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
      // 8.demo-mode-banner — re-pull the demo-mode rows on real
      // foreground resume. Catches any flip that happened while the
      // app was backgrounded (e.g. the connect flow happened on
      // operator web in another tab) without waiting on the
      // realtime spine to redeliver.
      unawaited(_resolveDemoModeNotifier()?.refresh() ?? Future.value());
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
    // W3.A — mobile Settings collapsed to 3 read-only tabs (Account,
    // Setup, Data). Team management + advisor admin live on Operator
    // Web; the AppShell no longer threads team state through here.
    final authNotifier = context.read<AuthSessionNotifier>();
    final session = authNotifier.session;
    final navigator = Navigator.of(context);
    final teamActor = await _teamActorForSettings(context, session);
    if (!mounted) return;
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          teamActor: teamActor,
          passwordChangeGateway: widget.passwordChangeGateway,
          accountInfoGateway: widget.accountInfoGateway,
          mfaOperationsGateway: widget.mfaOperationsGateway,
          handoffCodeGateway: widget.handoffCodeGateway,
          // Phase 9.UX.5 - Active Sessions in Account tab. Demo /
          // unauth shells fall back to the in-memory fixture so the
          // walkthrough can show multiple devices without a backend.
          authOperationsGateway: widget.authOperationsGateway,
          allowDemoActiveSessionsFallback: widget.authOperationsGateway == null,
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

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        settings: const RouteSettings(name: NotificationsScreen.routeName),
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
    AuthSession? session;
    try {
      session = Provider.of<AuthSessionNotifier>(context).session;
    } on ProviderNotFoundException {
      session = null;
    }
    final businessScopeSession = session;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadBusinessScopesIfNeeded(businessScopeSession);
    });

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
          icon: ValueListenableBuilder<int>(
            valueListenable:
                AppNotificationService.instance.unreadCountNotifier,
            builder: (context, count, child) {
              const iconWidget = Icon(
                Icons.notifications_none_outlined,
                size: 26,
                color: AppColors.textMuted,
              );
              if (count <= 0) return iconWidget;
              return Badge.count(count: count, child: iconWidget);
            },
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
                Builder(
                  builder: (context) => _AppShellIconButton(
                    icon: Icons.menu,
                    tooltip: 'Business',
                    onTap: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
                const SizedBox(width: 10),
                // Wave 2 W-5-mobile-FU — operator's uploaded logo
                // shown next to the menu button. Falls back to the
                // F&F splash icon when the operator has not uploaded
                // one. Closes the mobile half of W-5 (PR #686) that
                // was deferred because plumbing logo_url through the
                // mobile AuthSession touches every test that pins a
                // session shape (mitigated here by adding logoUrl as
                // an optional, nullable field).
                OperatorBrandMarkLeading(logoUrl: session?.logoUrl),
                const SizedBox(width: 10),
                const SyncStateBadge(),
                const Spacer(),
                ValueListenableBuilder<int>(
                  valueListenable:
                      AppNotificationService.instance.unreadCountNotifier,
                  builder: (context, count, _) {
                    final button = _AppShellIconButton(
                      icon: Icons.notifications_none_outlined,
                      tooltip: 'Notifications',
                      onTap: () => _openNotifications(context),
                    );
                    if (count <= 0) return button;
                    return Badge.count(count: count, child: button);
                  },
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
        bootstrapSubscription?.connectionState ??
        widget.realtimeConnectionState;
    final RealtimeConnectionState initialState = bootstrapSubscription != null
        ? bootstrapSubscription.currentConnectionState
        : widget.realtimeInitialConnectionState;
    return RealtimeConnectionScope(
      connectionStateStream: connectionStream,
      initialState: initialState,
      child: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        appBar: widget.embeddedInBarrio ? embeddedAppBar : standaloneAppBar,
        drawer: _buildBusinessScopeDrawer(context),
        // 8.demo-mode-banner — runtime per-(operator, location, category)
        // demo banner mounted directly above the tab body, beneath the
        // app bar. Renders one slim row per category whose
        // `demo_mode_state.is_demo` is still `true`; auto-clears once
        // every row flips after the operator's first vendor backfill
        // commits (HP #2 — runtime-state read, no kDemoMode branch).
        body: SafeArea(
          top: !widget.embeddedInBarrio,
          child: Column(
            mainAxisSize: MainAxisSize.max,
            children: <Widget>[
              const DemoModeBanner(),
              Expanded(
                child: IndexedStack(
                  index: _selectedIndex,
                  children: List<Widget>.generate(
                    4,
                    (index) => _buildTab(index, revision),
                  ),
                ),
              ),
            ],
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

@visibleForTesting
List<BusinessScope> filterBusinessScopeLocationsForDrawer(
  Iterable<BusinessScope> scopes,
  String query,
) {
  final normalizedQuery = query.trim().toLowerCase();
  final locationScopes = scopes.where((scope) => scope.isLocationScope);
  if (normalizedQuery.isEmpty) {
    return locationScopes.toList(growable: false);
  }
  return locationScopes
      .where((scope) {
        final searchable = <String>[
          scope.label,
          scope.operatorId,
          if (scope.locationId != null) scope.locationId!,
          if (scope.sortPath != null) scope.sortPath!,
        ].join(' ').toLowerCase();
        return searchable.contains(normalizedQuery);
      })
      .toList(growable: false);
}

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

/// Mobile-FU-business-scope-drawer-seed — one row of the
/// business-scope drawer. Extracted as a top-level widget so the
/// active-scope highlight (selected tile + check icon) is independently
/// testable.
///
/// Rendering rules (match the rest of the F&F mobile design system):
/// - Background tinted via [ListTile.selectedTileColor] when [selected].
/// - Leading icon flips to [AppColors.sunsetDark] when [selected].
/// - Title weight bumps from w500 → w700 when [selected].
/// - Trailing [Icons.check_circle] is shown only when [selected].
class BusinessScopeDrawerTile extends StatelessWidget {
  const BusinessScopeDrawerTile({
    super.key,
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final BusinessScope scope;
  final bool selected;
  final VoidCallback onTap;

  /// Test anchor for the leading icon of the active row.
  static const Key activeLeadingIconKey = Key(
    'business_scope_drawer_tile_active_leading_icon',
  );

  /// Test anchor for the trailing check icon shown only when [selected].
  static const Key activeCheckIconKey = Key(
    'business_scope_drawer_tile_active_check_icon',
  );

  @visibleForTesting
  static IconData iconFor(BusinessScope scope) => switch (scope.scopeType) {
    'operator' => Icons.business_outlined,
    'org_unit' => Icons.account_tree_outlined,
    'location' => Icons.storefront_outlined,
    _ => Icons.work_outline,
  };

  @visibleForTesting
  static String subtitleFor(BusinessScope scope) {
    if (scope.isLocationScope) {
      final sortPath = scope.sortPath;
      if (sortPath != null && sortPath.isNotEmpty && sortPath != scope.label) {
        return sortPath;
      }
      return 'Location';
    }
    if (scope.scopeType == 'operator') return 'All locations';
    return 'Location views only';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: selected
          ? const Key('business_scope_drawer_tile_active')
          : Key('business_scope_drawer_tile_${scope.stableKey}'),
      enabled: true,
      selected: selected,
      selectedTileColor: AppColors.backgroundMid.withValues(alpha: 0.7),
      leading: Icon(
        iconFor(scope),
        key: selected ? activeLeadingIconKey : null,
        color: selected ? AppColors.sunsetDark : AppColors.textMuted,
      ),
      title: Text(
        scope.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppColors.textPrimary,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      subtitle: Text(
        subtitleFor(scope),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
      trailing: selected
          ? const Icon(
              Icons.check_circle,
              key: activeCheckIconKey,
              color: AppColors.sunsetDark,
            )
          : null,
      onTap: onTap,
    );
  }
}
