import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'data/app_defaults.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'services/auth_login_service.dart';
import 'services/auth/auth_session_ledger_writer.dart';
import 'services/business_date_authority_service.dart';
import 'services/mobile_push/mobile_push_notification_service.dart';
import 'models/baseline_candidate_shift.dart';
import 'services/realtime/realtime_subscription.dart';
import 'services/secure_session_storage.dart';
import 'services/scope/business_scope_repository.dart';
import 'services/star_target_selection_write_service.dart';
import 'services/sync/mobile_operational_sync_runtime.dart';
import 'services/sync/sync_proxy_client.dart';
import 'services/target_cycle_service.dart';
import 'services/wage_standard_context_service.dart';
import 'state/auth_session_notifier.dart';
import 'state/realtime_auth_bridge.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';

/// Shared Forge & Flow app bootstrap used by both standalone and host shells.
///
/// 9.3 wires a single [AuthSessionNotifier] above whichever app
/// shell the caller passes in, so the embedded Forge & Flow surface
/// inside Barrio reuses the same live session as standalone Barrio
/// (HP #9 from the Phase 9 product boundary rules — "Forge & Flow
/// inside Barrio uses the live Barrio session; no second login").
///
/// Production callers pass real [authLoginService] /
/// [secureSessionStorage] / [authSessionLedgerWriter] implementations
/// once `firebase_auth`, `flutter_secure_storage`, and the Postgres
/// pool land in their respective slices. Defaults are fail-closed
/// scaffold implementations so a misconfigured deploy surfaces a
/// clear "no auth backend wired" error rather than silently allowing.
Future<void> bootstrapAndRunApp(
  Widget app, {
  AuthLoginService? authLoginService,
  SecureSessionStorage? secureSessionStorage,
  AuthSessionLedgerWriter? authSessionLedgerWriter,
  RealtimeSubscription? realtimeSubscription,
  SyncProxyClient? syncProxyClient,
  StarTargetSelectionWriteClient? starTargetSelectionWriteClient,
  MobilePushNotificationService? mobilePushNotifications,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  final loginService =
      authLoginService ?? const ScaffoldFailingAuthLoginService();
  final storage = secureSessionStorage ?? ScaffoldFailingSecureSessionStorage();
  // B6: ledger writer defaults to scaffold-failing so a production
  // deploy that wires Firebase + secure storage but forgets the
  // Postgres-backed RepositoryAuthSessionLedgerWriter surfaces a
  // clear "no auth ledger wired" error rather than silently dropping
  // auth_sessions rows. The notifier fails sign-in closed when the
  // login ledger cannot be recorded, while refresh/sign-out remain
  // log-and-continue to preserve low-friction session UX.
  final ledgerWriter =
      authSessionLedgerWriter ?? const ScaffoldFailingAuthSessionLedgerWriter();
  final authNotifier = AuthSessionNotifier(
    loginService: loginService,
    storage: storage,
    ledgerWriter: ledgerWriter,
  );
  BaselineManagerService.instance.serverSelectionWriter =
      starTargetSelectionWriteClient == null
      ? null
      : AuthSessionStarTargetSelectionWriter(
          client: starTargetSelectionWriteClient,
          authSessionProvider: () => authNotifier.session,
          projectionContextProvider: _buildStarTargetProjectionContext,
        );
  final mobilePush =
      mobilePushNotifications ?? const NoopMobilePushNotificationService();
  _bindMobilePushRegistrationToAuth(mobilePush, authNotifier);

  // Phase 10a.UX.0 — expose the bridge subscription (when wired by
  // production main entry points) so the operator-facing
  // [SyncStateBadge] in [AppShell] can render its Live / Reconnecting
  // chrome. Demo / no-Firebase paths pass `null`; the badge stays
  // hidden in those builds, which matches the no-realtime-channel
  // reality.
  //
  // The [RealtimeAuthBridge] sits ABOVE every operator surface
  // (standalone F&F shell, embedded F&F destination inside Barrio,
  // Barrio home itself) so the tenant context tracks the auth
  // session for the lifetime of the subscription — popping out of
  // the embedded F&F destination cannot leave a stale operator
  // channel alive across a later sign-out. No-op when the
  // subscription was not wired (try/catch resolves through to a
  // null subscription).
  runApp(
    Provider<MobilePushRouteIntentSource>.value(
      value: mobilePush.routeIntents,
      child: Provider<BusinessScopeClient?>.value(
        value: syncProxyClient is BusinessScopeClient
            ? syncProxyClient as BusinessScopeClient
            : null,
        // 8.demo-mode-banner — expose the same SyncProxyClient instance
        // the operational sync host uses so the AppShell-mounted
        // [DemoModeBanner] can call `fetchDemoModeStates(...)` for the
        // active (operator, location) without standing up a parallel
        // HTTP client. Demo / no-Firebase paths leave this null; the
        // banner stays hidden when no client is wired (matches the
        // no-runtime-state-available reality).
        child: Provider<SyncProxyClient?>.value(
          value: syncProxyClient,
          child: ChangeNotifierProvider<AuthSessionNotifier>.value(
            value: authNotifier,
            child: Provider<RealtimeSubscription?>.value(
              value: realtimeSubscription,
              child: RealtimeAuthBridge(
                child: MobileOperationalSyncHost(
                  syncClient: syncProxyClient,
                  child: app,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  // Fire-and-forget startup work after the first frame is unblocked.
  // AuthGate renders a Flutter loading/login surface while session
  // rehydrate resolves instead of leaving Android/iOS on the native
  // splash screen during SQLite/profile warm-up.
  unawaited(authNotifier.rehydrate());
  unawaited(mobilePush.start());
  unawaited(_warmUpPersistedState());
}

void _bindMobilePushRegistrationToAuth(
  MobilePushNotificationService mobilePush,
  AuthSessionNotifier authNotifier,
) {
  void sync() {
    final session = authNotifier.session;
    unawaited(
      mobilePush.updateRegistrationContext(
        session == null
            ? null
            : MobilePushRegistrationContext(
                userId: session.userId,
                operatorId: session.operatorId,
                locationId: session.locationId,
              ),
      ),
    );
  }

  authNotifier.addListener(sync);
  sync();
}

Future<StarTargetProjectionContext?> _buildStarTargetProjectionContext({
  required String restaurantId,
  required Iterable<BaselineCandidateShift> selectedCandidates,
}) async {
  final selected = selectedCandidates.toList(growable: false);
  if (selected.isEmpty) return null;
  final anchorDate = await BusinessDateAuthorityService.instance
      .resolvePlanningAnchorDate(restaurantId);
  if (anchorDate == null) {
    throw const StarTargetSelectionWriteException(
      code: 'planning_anchor_unavailable',
      message:
          'Sync closed history before projecting the selected star target.',
    );
  }
  final wageContext = await WageStandardContextService.instance.resolve(
    restaurantId,
  );
  double cplh = 0;
  double splh = 0;
  double ppa = 0;
  var floor = selected.first.cplh;
  var ceiling = selected.first.cplh;
  for (final candidate in selected) {
    cplh += candidate.cplh;
    splh += candidate.splh;
    ppa += candidate.ppa;
    if (candidate.cplh < floor) floor = candidate.cplh;
    if (candidate.cplh > ceiling) ceiling = candidate.cplh;
  }
  final count = selected.length.toDouble();
  return StarTargetProjectionContext(
    effectiveStart: anchorDate,
    effectiveEnd: _addIsoDays(anchorDate, 59),
    calibrationWindowStart: BusinessDateAuthorityService.subtractDays(
      anchorDate,
      59,
    ),
    calibrationWindowEnd: anchorDate,
    targetCplh: cplh / count,
    targetSplh: splh / count,
    targetPpa: ppa / count,
    fohWage: wageContext.fohWage ?? MeridianConfig.fohWage,
    bohWage: wageContext.bohWage ?? MeridianConfig.bohWage,
    opzFloorCplh: floor,
    opzCeilingCplh: ceiling,
    reason: 'manager selected star target on mobile',
  );
}

String _addIsoDays(String isoDate, int days) {
  final parts = isoDate.split('-');
  final date = DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  ).add(Duration(days: days));
  return '${date.year}-${date.month.toString().padLeft(2, '0')}'
      '-${date.day.toString().padLeft(2, '0')}';
}

Future<void> _warmUpPersistedState() async {
  try {
    // Compatibility bridge: prime in-memory BaselineData from persisted
    // selection for the few remaining bridge-era helpers. This no longer
    // re-authors the persisted profile; cycle-backed ActiveTargetProfile
    // authority is repaired below after the first Flutter frame.
    await BaselineManagerService.instance.primeManagerOverride();

    // 7.55p.5h-review-fix: rehydrate Benchmark graph honesty from the
    // persisted active cycle so a fresh app launch gets the correct
    // recommendation-quality signals (RANGE UNCONFIRMED / RANGE
    // UNCERTAIN / RANGE TOO WIDE TO TEACH / GOOD OPZ RANGE) without
    // depending on an in-process cycle write. Manager-override cycles
    // explicitly clear the signals here so that branch keeps driving
    // from BaselineData.
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    await WageStandardContextService.instance.loadOrBootstrapProfile(
      restaurantId,
    );
    await TargetCycleService.instance.hydrateBenchmarkHonestyFromActiveCycle(
      restaurantId,
    );
  } catch (error, stackTrace) {
    debugPrint('Startup warm-up failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
