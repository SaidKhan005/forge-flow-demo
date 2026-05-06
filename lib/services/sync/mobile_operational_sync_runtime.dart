import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../auth/auth_session.dart';
import '../../domain/models/restaurant_location.dart';
import '../../domain/services/utc_metadata_timestamp.dart';
import '../../infrastructure/persistence/sqlite/dao/import_tracking_dao.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../../state/auth_session_notifier.dart';
import '../realtime/realtime_event.dart';
import '../realtime/realtime_subscription.dart';
import 'postgres_shift_record_to_mobile_sync.dart';
import 'sync_proxy_client.dart';

typedef MobileSyncFactory =
    Future<PostgresShiftRecordToMobileSync> Function(SyncProxyClient client);

class MobileOperationalSyncRunner {
  MobileOperationalSyncRunner({
    required this.client,
    MobileSyncFactory? syncFactory,
    Future<String> Function(AuthSession session)? restaurantIdResolver,
  }) : _syncFactory = syncFactory ?? _defaultSyncFactory,
       _restaurantIdResolver =
           restaurantIdResolver ?? _activateSessionRestaurant;

  final SyncProxyClient client;
  final MobileSyncFactory _syncFactory;
  final Future<String> Function(AuthSession session) _restaurantIdResolver;

  bool _running = false;
  AuthSession? _pendingSession;

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
        final restaurantId = await _restaurantIdResolver(current);
        final sync = await _syncFactory(client);
        result = await sync.sync(
          operatorId: current.operatorId,
          locationId: current.locationId,
          restaurantId: restaurantId,
        );
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
}

class MobileOperationalSyncHost extends StatefulWidget {
  const MobileOperationalSyncHost({
    super.key,
    required this.syncClient,
    required this.child,
    this.runner,
  });

  final SyncProxyClient? syncClient;
  final Widget child;
  final MobileOperationalSyncRunner? runner;

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
  MobileOperationalSyncRunner? _runner;
  String? _lastAuthScope;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    _lastAuthScope = scope;
    _syncForCurrentSession('auth_changed');
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
    unawaited(
      runner.syncSession(session, reason: reason).catchError((
        Object error,
        StackTrace stack,
      ) {
        debugPrint('Mobile operational sync failed ($reason): $error');
        debugPrintStack(stackTrace: stack);
        return null;
      }),
    );
  }

  bool _isOperationalInvalidation(RealtimeEvent event) {
    final topic = event.topic.toLowerCase();
    if (topic.contains('shift_record') ||
        topic.contains('open_shift_snapshot') ||
        topic.contains('variance_week') ||
        topic.contains('demo_mode') ||
        topic.contains('data_accuracy') ||
        topic.contains('polling_tier') ||
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
        table == 'business_timing_profiles' ||
        table == 'business_timing_service_periods' ||
        table == 'restaurant_timing_configs';
  }
}
