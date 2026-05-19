// Per-Daypart V1 Slice 1.5: `shift_close_authority` and
// `local_close_fallback` were dropped from `restaurant_timing_configs`.
// Close-authority is auto-derived per shift from
// `lib/services/integration/close_authority_capability.dart`.

import 'dart:convert';
import '../../../../domain/models/restaurant_location.dart';
import '../../../../domain/models/restaurant_timing_config.dart';
import '../../../../domain/models/service_period_definition.dart';
import '../../../../domain/repositories/restaurant_timing_config_repository.dart';
import '../dao/restaurant_scope_dao.dart';
import '../dao/restaurant_timing_config_dao.dart';
import '../sqlite_database.dart';

class SqliteRestaurantTimingConfigRepository
    implements RestaurantTimingConfigRepository {
  SqliteRestaurantTimingConfigRepository._();
  static final SqliteRestaurantTimingConfigRepository instance =
      SqliteRestaurantTimingConfigRepository._();

  RestaurantTimingConfigDao? _dao;
  RestaurantScopeDao? _scopeDao;

  Future<RestaurantTimingConfigDao> get _daoReady async {
    if (_dao != null) return _dao!;
    final db = await SqliteDatabase.instance.database;
    _dao = RestaurantTimingConfigDao(db);
    return _dao!;
  }

  Future<RestaurantScopeDao> get _scopeDaoReady async {
    if (_scopeDao != null) return _scopeDao!;
    final db = await SqliteDatabase.instance.database;
    _scopeDao = RestaurantScopeDao(db);
    return _scopeDao!;
  }

  @override
  Future<RestaurantTimingConfig?> getTimingConfig(String restaurantId) async {
    final dao = await _daoReady;
    final raw = await dao.getRaw(restaurantId);
    if (raw == null) return null;

    // Compose timezone from RestaurantLocation — single source of truth.
    // No fallback: if the restaurant location row is missing, this is a scope
    // mismatch and we fail closed by returning null.
    final scopeDao = await _scopeDaoReady;
    final location = await scopeDao.getRestaurant(restaurantId);
    if (location == null) return null;
    final timezone = location.businessTimezone;

    final defsJson =
        jsonDecode(raw['service_period_definitions_json'] as String) as List;
    final definitions = defsJson
        .map(
          (e) => ServicePeriodDefinition.fromMap(
            Map<String, dynamic>.from(e as Map),
          ),
        )
        .toList();

    return RestaurantTimingConfig(
      restaurantId: raw['restaurant_id'] as String,
      businessTimezone: timezone,
      businessDayStartLocalTime: raw['business_day_start_local_time'] as String,
      weekStartDay: raw['week_start_day'] as int,
      servicePeriodDefinitions: definitions,
      createdAt: raw['created_at'] as String,
      updatedAt: raw['updated_at'] as String,
      selectedScopeType: raw['selected_scope_type'] as String?,
      selectedScopeId: raw['selected_scope_id'] as String?,
      sourceScopeType: raw['source_scope_type'] as String?,
      sourceScopeId: raw['source_scope_id'] as String?,
      sourceScopeLabel: raw['source_scope_label'] as String?,
      inheritedFromAncestor: _nullableBool(raw['inherited_from_ancestor']),
    );
  }

  @override
  Future<void> saveTimingConfig(RestaurantTimingConfig config) async {
    final dao = await _daoReady;
    await _hydrateScopeTimezone(config);
    await dao.upsert(
      restaurantId: config.restaurantId,
      businessDayStartLocalTime: config.businessDayStartLocalTime,
      weekStartDay: config.weekStartDay,
      servicePeriodDefinitions: config.servicePeriodDefinitions,
      createdAt: config.createdAt,
      updatedAt: config.updatedAt,
      selectedScopeType: config.selectedScopeType,
      selectedScopeId: config.selectedScopeId,
      sourceScopeType: config.sourceScopeType,
      sourceScopeId: config.sourceScopeId,
      sourceScopeLabel: config.sourceScopeLabel,
      inheritedFromAncestor: config.inheritedFromAncestor,
    );
  }

  static bool? _nullableBool(Object? value) {
    if (value == null) return null;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) {
      if (value == '1' || value.toLowerCase() == 'true') return true;
      if (value == '0' || value.toLowerCase() == 'false') return false;
    }
    return null;
  }

  Future<void> _hydrateScopeTimezone(RestaurantTimingConfig config) async {
    final timezone = config.businessTimezone.trim();
    if (timezone.isEmpty) return;
    final scopeDao = await _scopeDaoReady;
    final existing = await scopeDao.getRestaurant(config.restaurantId);
    if (existing == null) {
      await scopeDao.insertRestaurant(
        RestaurantLocation(
          restaurantId: config.restaurantId,
          displayName: 'Live location',
          businessTimezone: timezone,
          createdAt: config.createdAt,
          updatedAt: config.updatedAt,
        ),
      );
      return;
    }
    if (existing.businessTimezone == timezone) return;
    await scopeDao.updateRestaurant(
      RestaurantLocation(
        restaurantId: existing.restaurantId,
        displayName: existing.displayName,
        businessTimezone: timezone,
        createdAt: existing.createdAt,
        updatedAt: config.updatedAt,
      ),
    );
  }

  void resetDao() {
    _dao = null;
    _scopeDao = null;
  }

  /// Deletes every mirrored `restaurant_timing_configs` row whose
  /// `restaurant_id` is NOT [keepRestaurantId]. Called by
  /// `MobileOperationalSyncRuntime` on operator/location change so the
  /// prior tenant's timing config cannot leak through reads that don't
  /// filter by scope.
  Future<int> wipeForOtherScopes(String keepRestaurantId) async {
    final dao = await _daoReady;
    return dao.deleteForOtherRestaurants(keepRestaurantId);
  }

  /// Set-preserving sibling of [wipeForOtherScopes]. Deletes every
  /// mirrored `restaurant_timing_configs` row whose `restaurant_id` is
  /// NOT in [keepRestaurantIds]. Used only by the demo bootstrap
  /// source-swap (`demoScopePreservingCrossTenantWipe`) so a demo
  /// location switch keeps every demo location's timing config;
  /// production keeps the single-keep path byte-unchanged.
  Future<int> wipeForScopesNotIn(Set<String> keepRestaurantIds) async {
    final dao = await _daoReady;
    return dao.deleteForRestaurantsNotIn(keepRestaurantIds);
  }
}
