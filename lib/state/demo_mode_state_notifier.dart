// 8.demo-mode-banner — Runtime per-(operator, location, category)
// demo-mode notifier.
//
// Reads `demo_mode_state` rows for the active (operator, location)
// scope via the existing proxy `SyncProxyClient.fetchDemoModeStates`
// surface (Phase 8.0). The notifier is the read-side complement to
// `DemoModeFlipPolicy` (write-side): the AppShell-mounted
// `DemoModeBanner` widget watches this notifier so the banner
// appears for every category that is still `is_demo = true` and
// auto-clears once the row flips after the operator's first vendor
// backfill commits.
//
// Why a notifier rather than a direct gateway read:
//   * Multiple operator-app surfaces could subscribe (banner today,
//     status badge / Settings hint tomorrow). One refresh per scope
//     change beats every screen pulling its own copy.
//   * Refresh on app foreground (lifecycle resume) and on scope
//     change is centralised here, so the banner does not need to
//     own lifecycle plumbing.
//   * Realtime invalidation: when `RealtimeEventBus` publishes an
//     integrations / first-backfill event for the active operator,
//     the notifier kicks off a single refresh.
//
// HP #2 (CLAUDE.md): the notifier reads runtime state from the
// `demo_mode_state` table — it does NOT branch on the build-time
// `kDemoMode` flag. Demo and prod resolve through the same code
// path; the only difference is which writer populated the row
// (`MockReplayDataSourceProvider` vs vendor sinks).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/integration/demo_mode_state.dart';
import '../services/integration/integration_adapter_common.dart';
import '../services/sync/sync_proxy_client.dart';

/// Snapshot of `demo_mode_state` rows for the active scope, plus
/// the last error encountered fetching them.
@immutable
class DemoModeStateSnapshot {
  const DemoModeStateSnapshot({
    required this.operatorId,
    required this.locationId,
    required this.records,
    this.errorMessage,
    this.lastRefreshedAt,
  });

  /// Empty / unscoped snapshot — used as the initial state and after
  /// scope clears (sign-out).
  static const DemoModeStateSnapshot empty = DemoModeStateSnapshot(
    operatorId: '',
    locationId: '',
    records: <DemoModeRecord>[],
  );

  /// Active operator id this snapshot was pulled for. Empty when no
  /// scope is active.
  final String operatorId;

  /// Active location id this snapshot was pulled for. Empty when no
  /// scope is active.
  final String locationId;

  /// All `demo_mode_state` rows the proxy returned for the scope.
  /// Bounded to at most one row per [IntegrationCategory].
  final List<DemoModeRecord> records;

  /// Non-null when the most-recent fetch failed. The notifier keeps
  /// the prior [records] so a transient failure does not flicker the
  /// banner away; consumers can opt in to surfacing the error via
  /// this field.
  final String? errorMessage;

  /// UTC instant of the most-recent successful refresh. Null until
  /// the first fetch resolves.
  final DateTime? lastRefreshedAt;

  /// True when the scope is active AND any category row reports
  /// `is_demo = true`. The banner watches this to decide whether to
  /// render at all.
  bool get hasDemoCategories =>
      operatorId.isNotEmpty &&
      locationId.isNotEmpty &&
      records.any((r) => r.isDemo);

  /// Returns the categories still in demo mode for the active scope,
  /// in stable [IntegrationCategory] order.
  List<IntegrationCategory> get demoCategories {
    if (!hasDemoCategories) return const <IntegrationCategory>[];
    final order = <IntegrationCategory>[
      IntegrationCategory.pos,
      IntegrationCategory.labor,
      IntegrationCategory.reservation,
    ];
    final present = <IntegrationCategory>{
      for (final record in records)
        if (record.isDemo) record.category,
    };
    return <IntegrationCategory>[
      for (final category in order)
        if (present.contains(category)) category,
    ];
  }

  DemoModeStateSnapshot copyWith({
    String? operatorId,
    String? locationId,
    List<DemoModeRecord>? records,
    String? errorMessage,
    DateTime? lastRefreshedAt,
  }) {
    return DemoModeStateSnapshot(
      operatorId: operatorId ?? this.operatorId,
      locationId: locationId ?? this.locationId,
      records: records ?? this.records,
      errorMessage: errorMessage,
      lastRefreshedAt: lastRefreshedAt ?? this.lastRefreshedAt,
    );
  }
}

/// `ChangeNotifier` that owns the runtime demo-mode snapshot for the
/// active (operator, location) scope.
///
/// Lifecycle is driven by callers in the AppShell:
///   * [setScope] — bind to (operator, location). Triggers a refresh
///     when the scope actually changes; idempotent for repeat calls
///     with the same pair.
///   * [refresh] — re-pull the rows (used on app foreground / realtime
///     invalidation / explicit user action).
///   * [clear] — drop the snapshot, e.g. on sign-out.
class DemoModeStateNotifier extends ChangeNotifier {
  DemoModeStateNotifier({
    SyncProxyClient? client,
    DateTime Function()? now,
  })  : _client = client,
        _now = now ?? DateTime.now;

  SyncProxyClient? _client;
  final DateTime Function() _now;

  DemoModeStateSnapshot _snapshot = DemoModeStateSnapshot.empty;
  Future<void>? _inFlight;
  int _generation = 0;

  /// Latest snapshot. Always non-null.
  DemoModeStateSnapshot get snapshot => _snapshot;

  /// True when a refresh is currently in flight.
  bool get isRefreshing => _inFlight != null;

  /// Inject / replace the proxy client. Production wires this once
  /// from the bootstrap `Provider<SyncProxyClient?>`; tests can swap
  /// in a fake. A null client disables refreshes (the banner stays
  /// hidden).
  void bindClient(SyncProxyClient? client) {
    if (identical(_client, client)) return;
    _client = client;
    // Re-trigger if a scope is already set; otherwise wait for
    // setScope to seed.
    if (_snapshot.operatorId.isNotEmpty && _snapshot.locationId.isNotEmpty) {
      unawaited(refresh());
    }
  }

  /// Bind to (operator, location). Triggers a refresh when the scope
  /// changes. Empty strings clear the snapshot.
  Future<void> setScope({
    required String operatorId,
    required String locationId,
  }) async {
    if (operatorId.isEmpty || locationId.isEmpty) {
      clear();
      return;
    }
    if (operatorId == _snapshot.operatorId &&
        locationId == _snapshot.locationId) {
      return;
    }
    _generation++;
    _snapshot = DemoModeStateSnapshot(
      operatorId: operatorId,
      locationId: locationId,
      records: const <DemoModeRecord>[],
    );
    notifyListeners();
    await refresh();
  }

  /// Drop the active scope. Used on sign-out / scope clear.
  void clear() {
    if (_snapshot.operatorId.isEmpty && _snapshot.locationId.isEmpty) return;
    _generation++;
    _snapshot = DemoModeStateSnapshot.empty;
    notifyListeners();
  }

  /// Pull the latest demo-mode rows for the active scope. Coalesces
  /// concurrent calls — only one in-flight request per scope.
  Future<void> refresh() async {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final client = _client;
    final operatorId = _snapshot.operatorId;
    final locationId = _snapshot.locationId;
    if (client == null || operatorId.isEmpty || locationId.isEmpty) {
      return;
    }
    final generationAtStart = _generation;
    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      final records = await client.fetchDemoModeStates(
        operatorId: operatorId,
        locationId: locationId,
      );
      // Drop the result on the floor when scope flipped mid-flight.
      if (generationAtStart != _generation) return;
      _snapshot = _snapshot.copyWith(
        records: List<DemoModeRecord>.unmodifiable(records),
        errorMessage: null,
        lastRefreshedAt: _now().toUtc(),
      );
      notifyListeners();
    } catch (error, stackTrace) {
      if (generationAtStart != _generation) return;
      _snapshot = _snapshot.copyWith(
        errorMessage: error.toString(),
      );
      notifyListeners();
      // Swallow — the banner is best-effort UX. The error is captured
      // on the snapshot so a future surface can render it.
      debugPrint('DemoModeStateNotifier refresh failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }
}
