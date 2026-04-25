import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'services/target_cycle_service.dart';
import 'services/wage_standard_context_service.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';

/// Shared Forge & Flow app bootstrap used by both standalone and host shells.
Future<void> bootstrapAndRunApp(Widget app) async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Compatibility bridge: prime in-memory BaselineData from persisted
  // selection for the few remaining bridge-era helpers. This no longer
  // re-authors the persisted profile; cycle-backed ActiveTargetProfile
  // authority is repaired below before the UI loads.
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

  runApp(app);
}
