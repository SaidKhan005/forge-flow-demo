import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_session.dart';
import '../../domain/models/business_scope.dart';
import '../../domain/models/restaurant_location.dart';
import '../../domain/services/utc_metadata_timestamp.dart';
import '../../infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_baseline_selection_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../../state/auth_session_notifier.dart';
import '../realtime/realtime_event.dart';
import '../realtime/realtime_subscription.dart';
import '../scope/business_scope_repository.dart';
import 'postgres_shift_record_to_mobile_sync.dart';
import 'sync_proxy_client.dart';

typedef MobileSyncFactory =
    Future<PostgresShiftRecordToMobileSync> Function(SyncProxyClient client);

/// Hook signature used by [MobileOperationalSyncHost] (and tests) to
/// purge mirrored rows whose `restaurant_id` is NOT [keepRestaurantId].
/// Defaults to wiping shift_records / open_shift_snapshots /
/// restaurant_timing_configs plus selected-star / target cache mirrors
/// across the SQLite repos the runtime pulls into; tests can substitute
/// a stub. See BUG 1 (HIGH).
typedef CrossTenantWipe = Future<void> Function(String keepRestaurantId);

class MobileOperationalSyncRunner {
  MobileOperationalSyncRunner({
    required this.client,
    MobileSyncFactory? syncFactory,
    Future<String> Function(AuthSession session)? restaurantIdResolver,
    Future<BusinessScope?> Function(AuthSession session)? activeScopeResolver,
  }) : _syncFactory = syncFactory ?? _defaultSyncFactory,
       _restaurantIdResolver =
           restaurantIdResolver ?? _activateSessionRestaurant,
       _activeScopeResolver =
           activeScopeResolver ?? _resolvePersistedActiveScope;

  final SyncProxyClient client;
  final MobileSyncFactory _syncFactory;
  final Future<String> Function(AuthSession session) _restaurantIdResolver;
  final Future<BusinessScope?> Function(AuthSession session)
  _activeScopeResolver;

  bool _running = false;
  AuthSession? _pendingSession;
  int _generation = 0;

  /// Optional probe that returns true when the in-flight sweep should
  /// abort (e.g. the user signed out mid-pull). Wired by
  /// [MobileOperationalSyncHost] to a `userId`-equality recheck against
  /// the live [AuthSessionNotifier]. See BUG 2 (HIGH).
  bool Function()? _abortProbe;

  /// Test/host hook for installing the abort probe. The probe is checked
  /// before each page fetch and after each successful page; when it
  /// returns true the runner stops the loop and skips writes for the
  /// remaining pages. Pass `null` to clear.
  // ignore: use_setters_to_change_properties
  void setAbortProbe(bool Function()? probe) {
    _abortProbe = probe;
  }

  void cancelInFlightSync() {
    _generation++;
  }

  Future<SyncResult?> syncSession(
    AuthSession? session, {
    String reason = 'manual',
  }) async {
    if (session == null || !session.isLive(now: DateTime.now())) {
      return null;
    }
    if (_running) {
      _pendingSession = session;
      return null;
    }
    _running = true;
    var current = session;
    SyncResult? result;
    try {
      while (true) {
        _pendingSession = null;
        final runGeneration = _generation;
        bool isAborted() =>
            runGeneration != _generation || (_abortProbe?.call() ?? false);
        final scope = await _resolveSyncScope(current);
        final sync = await _syncFactory(client);
        result = await sync.sync(
          operatorId: scope.session.operatorId,
          locationId: scope.session.locationId,
          restaurantId: scope.restaurantId,
          isAborted: isAborted,
        );
        if (isAborted()) {
          // BUG 2 (HIGH): the auth context flipped mid-sweep; bail out
          // before promoting any pending session so the next caller
          // re-evaluates against the fresh session.
          break;
        }
        final pending = _pendingSession;
        if (pending == null) break;
        current = pending;
      }
      return result;
    } finally {
      _running = false;
    }
  }

  static Future<PostgresShiftRecordToMobileSync> _defaultSyncFactory(
    SyncProxyClient client,
  ) async {
    final db = await SqliteDatabase.instance.database;
    return PostgresShiftRecordToMobileSync(
      client: client,
      shiftRepository: SqliteShiftRecordRepository.instance,
      watermarkDao: ImportTrackingDao(db),
    );
  }

  static Future<String> _activateSessionRestaurant(AuthSession session) async {
    final now = nowIsoUtc();
    final location = RestaurantLocation(
      restaurantId: session.locationId,
      displayName: 'Live location',
      businessTimezone: '',
      createdAt: now,
      updatedAt: now,
    );
    await SqliteRestaurantScopeRepository.instance.activateRuntimeRestaurant(
      location,
    );
    return location.restaurantId;
  }

  Future<_MobileSyncScope> _resolveSyncScope(AuthSession session) async {
    final activeScope = await _activeScopeResolver(session);
    if (activeScope != null && activeScope.isLocationScope) {
      final locationId = activeScope.locationId!;
      final effectiveSession = session.copyWith(
        operatorId: activeScope.operatorId,
        locationId: locationId,
      );
      final now = nowIsoUtc();
      await SqliteRestaurantScopeRepository.instance.activateRuntimeRestaurant(
        activeScope.toRestaurantLocation(createdAt: now, updatedAt: now),
      );
      return _MobileSyncScope(
        session: effectiveSession,
        restaurantId: locationId,
      );
    }
    final restaurantId = await _restaurantIdResolver(session);
    return _MobileSyncScope(session: session, restaurantId: restaurantId);
  }

  static Future<BusinessScope?> _resolvePersistedActiveScope(
    AuthSession session,
  ) {
    return SqliteActiveScopeRepository.instance.getActiveScope(session.userId);
  }
}

class _MobileSyncScope {
  const _MobileSyncScope({required this.session, required this.restaurantId});

  final AuthSession session;
  final String restaurantId;
}

/// Default cross-tenant wipe used by [MobileOperationalSyncHost]. Calls
/// the per-repo `wipeForOtherScopes` hooks the runtime pulls into so a
/// shared-device operator/location flip cannot leave the prior tenant's
/// rows reachable through DAO reads that don't filter by scope.
Future<void> defaultCrossTenantWipe(String keepRestaurantId) async {
  await SqliteShiftRecordRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteOpenShiftSnapshotRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteRestaurantTimingConfigRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteBaselineSelectionRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteTargetCycleRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteTargetProfileRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
  await SqliteWeeklyPlanSnapshotRepository.instance.wipeForOtherScopes(
    keepRestaurantId,
  );
}

class MobileOperationalSyncHost extends StatefulWidget {
  const MobileOperationalSyncHost({
    super.key,
    required this.syncClient,
    required this.child,
    this.runner,
    this.crossTenantWipe = defaultCrossTenantWipe,
  });

  final SyncProxyClient? syncClient;
  final Widget child;
  final MobileOperationalSyncRunner? runner;

  /// Override-able cross-tenant wipe hook so widget tests can stub the
  /// SQLite delete pass while still exercising the
  /// `_handleAuthChanged` -> wipe -> sync wiring. See BUG 1 (HIGH).
  final CrossTenantWipe crossTenantWipe;

  @override
  State<MobileOperationalSyncHost> createState() =>
      _MobileOperationalSyncHostState();
}

class _MobileOperationalSyncHostState extends State<MobileOperationalSyncHost>
    with WidgetsBindingObserver {
  AuthSessionNotifier? _authNotifier;
  RealtimeSubscription? _realtimeSubscription;
  StreamSubscription<RealtimeEvent>? _eventsSubscription;
  StreamSubscription<void>? _replayTruncatedSubscription;
  StreamSubscription<BusinessScope>? _scopeChangeSubscription;
  MobileOperationalSyncRunner? _runner;
  String? _lastAuthScope;
  String? _lastBusinessScopeKey;
  String? _activeSweepUserId;
  String? _activeSweepScopeKey;

  @override
  void initState() {
    super.initState();
    // BUG 5 (MEDIUM): hot-restart skips `dispose()` so the singleton
    // `_runtimeActiveRestaurantId` on `SqliteRestaurantScopeRepository`
    // can still hold the previous process's override. Clear it here
    // BEFORE `_bindAuthNotifier` runs (in `didChangeDependencies`) so a
    // fresh process always starts with no override; the next
    // `_handleAuthChanged` re-activates the right one.
    SqliteRestaurantScopeRepository.instance.clearRuntimeRestaurantOverride();
    WidgetsBinding.instance.addObserver(this);
    _scopeChangeSubscription = ActiveBusinessScopeChangeBus.instance.changes
        .listen(_handleBusinessScopeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureRunner();
    _bindAuthNotifier();
    _bindRealtimeSubscription();
    _syncForCurrentSession('host_attached');
  }

  @override
  void didUpdateWidget(covariant MobileOperationalSyncHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.syncClient != widget.syncClient ||
        oldWidget.runner != widget.runner) {
      _runner = null;
      _lastAuthScope = null;
      _lastBusinessScopeKey = null;
      _ensureRunner();
      _syncForCurrentSession('sync_client_changed');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncForCurrentSession('app_resumed');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authNotifier?.removeListener(_handleAuthChanged);
    _authNotifier = null;
    _scopeChangeSubscription?.cancel();
    _scopeChangeSubscription = null;
    _eventsSubscription?.cancel();
    _replayTruncatedSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void _ensureRunner() {
    final client = widget.syncClient;
    if (client == null) {
      _runner = null;
      return;
    }
    _runner ??= widget.runner ?? MobileOperationalSyncRunner(client: client);
  }

  void _bindAuthNotifier() {
    AuthSessionNotifier? next;
    try {
      next = Provider.of<AuthSessionNotifier>(context, listen: false);
    } on ProviderNotFoundException {
      next = null;
    }
    if (identical(next, _authNotifier)) return;
    _authNotifier?.removeListener(_handleAuthChanged);
    _authNotifier = next;
    _authNotifier?.addListener(_handleAuthChanged);
  }

  void _bindRealtimeSubscription() {
    RealtimeSubscription? next;
    try {
      next = Provider.of<RealtimeSubscription?>(context, listen: false);
    } on ProviderNotFoundException {
      next = null;
    }
    if (identical(next, _realtimeSubscription)) return;
    _eventsSubscription?.cancel();
    _replayTruncatedSubscription?.cancel();
    _realtimeSubscription = next;
    _eventsSubscription = next?.events.listen(_handleRealtimeEvent);
    _replayTruncatedSubscription = next?.replayTruncated.listen((_) {
      _syncForCurrentSession('realtime_replay_truncated');
    });
  }

  void _handleAuthChanged() {
    final session = _authNotifier?.session;
    if (session == null) {
      _lastAuthScope = null;
      SqliteRestaurantScopeRepository.instance.clearRuntimeRestaurantOverride();
      return;
    }
    final scope = '${session.operatorId}:${session.locationId}';
    if (scope == _lastAuthScope) return;
    final priorScope = _lastAuthScope;
    _lastAuthScope = scope;
    if (priorScope != null) {
      // BUG 1 (HIGH): operator OR location flipped on a shared device.
      // Purge the prior tenant's mirrored rows from local SQLite BEFORE
      // the next sync sweep so DAO reads that don't filter by
      // (operator_id, location_id) cannot return stale rows. The mobile
      // SQLite tables key on `restaurant_id`; the runtime promotes
      // `session.locationId` into the active `restaurantId`, so the new
      // tenant's `restaurantId` is exactly the new `locationId`.
      _wipeOtherTenantsThenSync(session, 'auth_changed');
      return;
    }
    _syncForCurrentSession('auth_changed');
  }

  void _wipeOtherTenantsThenSync(AuthSession session, String reason) {
    unawaited(() async {
      try {
        await widget.crossTenantWipe(session.locationId);
      } catch (error, stack) {
        debugPrint('Mobile operational sync wipe failed ($reason): $error');
        debugPrintStack(stackTrace: stack);
      }
      _syncForCurrentSession(reason);
    }());
  }

  void _handleBusinessScopeChanged(BusinessScope scope) {
    if (!scope.isLocationScope) return;
    final session = _authNotifier?.session;
    if (session == null) return;
    final key = scope.stableKey;
    if (key == _lastBusinessScopeKey) return;
    _runner?.cancelInFlightSync();
    _lastBusinessScopeKey = key;
    _wipeOtherTenantsThenSync(
      session.copyWith(
        operatorId: scope.operatorId,
        locationId: scope.locationId,
      ),
      'business_scope_changed',
    );
  }

  void _handleRealtimeEvent(RealtimeEvent event) {
    final session = _authNotifier?.session;
    if (session == null || event.operatorId != session.operatorId) return;
    if (!_isOperationalInvalidation(event)) return;
    _syncForCurrentSession('realtime:${event.topic}');
  }

  void _syncForCurrentSession(String reason) {
    final runner = _runner;
    if (runner == null) return;
    final session = _authNotifier?.session;
    if (session == null) return;
    // Track the scope so a subsequent `_handleAuthChanged` can tell the
    // delta between the prior tenant and the new tenant. Without this,
    // the very first scope change after host attach would see
    // `priorScope == null` and skip the wipe.
    _lastAuthScope ??= '${session.operatorId}:${session.locationId}';
    // BUG 2 (HIGH): capture the userId at sweep start and re-check the
    // live session before each page fetch. If the user signs out or the
    // operator/location flips mid-pull, the runner aborts the loop and
    // skips writes for the remaining pages instead of continuing
    // against the stale token + scope.
    final initialUserId = session.userId;
    final initialBusinessScopeKey = _lastBusinessScopeKey;
    _activeSweepUserId = initialUserId;
    _activeSweepScopeKey = initialBusinessScopeKey;
    runner.setAbortProbe(() {
      final live = _authNotifier?.session;
      return live == null ||
          live.userId != initialUserId ||
          _lastBusinessScopeKey != initialBusinessScopeKey;
    });
    unawaited(
      runner
          .syncSession(session, reason: reason)
          .catchError((Object error, StackTrace stack) {
            debugPrint('Mobile operational sync failed ($reason): $error');
            debugPrintStack(stackTrace: stack);
            return null;
          })
          .whenComplete(() {
            if (_activeSweepUserId == initialUserId &&
                _activeSweepScopeKey == initialBusinessScopeKey) {
              _activeSweepUserId = null;
              _activeSweepScopeKey = null;
              runner.setAbortProbe(null);
            }
          }),
    );
  }

  bool _isOperationalInvalidation(RealtimeEvent event) {
    if (isBusinessScopeInvalidationEvent(event)) return true;
    final topic = event.topic.toLowerCase();
    if (topic.contains('shift_record') ||
        topic.contains('open_shift_snapshot') ||
        topic.contains('variance_week') ||
        topic.contains('demo_mode') ||
        topic.contains('data_accuracy') ||
        topic.contains('polling_tier') ||
        topic.contains('selected_star') ||
        topic.contains('target_cycle') ||
        topic.contains('active_target_profile') ||
        topic.contains('target_profile_version') ||
        topic.contains('weekly_plan_snapshot') ||
        topic.contains('forecast_context') ||
        topic.contains('backfill') ||
        topic.contains('connector_backfill_job') ||
        topic.contains('business_timing') ||
        topic.contains('timing')) {
      return true;
    }
    final table = event.payload['table']?.toString().toLowerCase();
    return table == 'shift_records' ||
        table == 'open_shift_snapshots' ||
        table == 'demo_mode_state' ||
        table == 'data_accuracy_settings' ||
        table == 'forge_flow_polling_tier_assignment' ||
        table == 'selected_star_shift_decisions' ||
        table == 'target_cycles' ||
        table == 'active_target_profiles' ||
        table == 'target_profile_versions' ||
        table == 'weekly_plan_snapshots' ||
        table == 'forecast_contexts' ||
        table == 'forecast_context' ||
        table == 'connector_backfill_jobs' ||
        table == 'business_timing_profiles' ||
        table == 'business_timing_service_periods' ||
        table == 'restaurant_timing_configs';
  }
}
