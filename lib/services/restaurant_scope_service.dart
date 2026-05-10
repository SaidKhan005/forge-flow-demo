// Phase 7.55 hardening — Restaurant scope service (Layer 3).
//
// CLAUDE.md "Architecture Guardrails":
//   "Widgets do not own source-truth or service-period bucketing."
//
// Centralizes widget/notifier reads of the active restaurant id so
// the UI layer never imports `SqliteRestaurantScopeRepository` directly.
// Service code that legitimately owns SQLite I/O (e.g. read services
// that already aggregate multiple repositories) may continue to call
// the repository singleton; this seam exists for the widget tree.
//
// POST_HARDENING_FOLLOWUPS.md P1 routes
// `lib/screens/notifications_screen.dart` and
// `lib/screens/schedule/schedule_forecast_notifier.dart` through this
// service. The same shape is intended for the P2
// `lib/screens/settings/settings_wage_authority_section.dart`
// follow-up; that work lands in a separate slice.

import 'package:flutter/foundation.dart';

import '../domain/repositories/restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';

class RestaurantScopeService {
  RestaurantScopeService._();
  static final RestaurantScopeService instance = RestaurantScopeService._();

  RestaurantScopeRepository _repo = SqliteRestaurantScopeRepository.instance;

  /// Test seam: swap the underlying repository (singleton in production).
  @visibleForTesting
  void overrideRepositoryForTest(RestaurantScopeRepository repo) {
    _repo = repo;
  }

  /// Test seam: reset to the production singleton.
  @visibleForTesting
  void resetForTest() {
    _repo = SqliteRestaurantScopeRepository.instance;
  }

  /// Returns the active restaurant id for the current scope, creating
  /// the demo restaurant row if no active restaurant has been
  /// initialized yet (matches the underlying repository contract).
  Future<String> getActiveRestaurantId() => _repo.getActiveRestaurantId();
}
