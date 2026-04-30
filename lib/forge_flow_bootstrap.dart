import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'services/auth_login_service.dart';
import 'services/auth/auth_session_ledger_writer.dart';
import 'services/secure_session_storage.dart';
import 'services/target_cycle_service.dart';
import 'services/wage_standard_context_service.dart';
import 'state/auth_session_notifier.dart';
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
  final storage =
      secureSessionStorage ?? ScaffoldFailingSecureSessionStorage();
  // B6: ledger writer defaults to scaffold-failing so a production
  // deploy that wires Firebase + secure storage but forgets the
  // Postgres-backed RepositoryAuthSessionLedgerWriter surfaces a
  // clear "no auth ledger wired" error rather than silently dropping
  // auth_sessions rows. The notifier fails sign-in closed when the
  // login ledger cannot be recorded, while refresh/sign-out remain
  // log-and-continue to preserve low-friction session UX.
  final ledgerWriter =
      authSessionLedgerWriter ??
      const ScaffoldFailingAuthSessionLedgerWriter();
  final authNotifier = AuthSessionNotifier(
    loginService: loginService,
    storage: storage,
    ledgerWriter: ledgerWriter,
  );

  runApp(
    ChangeNotifierProvider<AuthSessionNotifier>.value(
      value: authNotifier,
      child: app,
    ),
  );

  // Fire-and-forget startup work after the first frame is unblocked.
  // AuthGate renders a Flutter loading/login surface while session
  // rehydrate resolves instead of leaving Android/iOS on the native
  // splash screen during SQLite/profile warm-up.
  unawaited(authNotifier.rehydrate());
  unawaited(_warmUpPersistedState());
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
    await WageStandardContextService.instance
        .loadOrBootstrapProfile(restaurantId);
    await TargetCycleService.instance
        .hydrateBenchmarkHonestyFromActiveCycle(restaurantId);
  } catch (error, stackTrace) {
    debugPrint('Startup warm-up failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }
}
