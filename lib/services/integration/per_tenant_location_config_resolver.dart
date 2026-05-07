// Phase 8 framework — per-(operator, location) runtime-config resolver.
//
// Adapter Deps records (Lightspeed LSK, SevenRooms, …) need three
// per-tenant runtime values that the credential bridges do not supply:
//
//   * `restaurantTimezone` — IANA id, source-of-truth: `locations.timezone`
//   * `businessDayRolloverHour` — 0..23, source-of-truth: per-location
//     override (`locations.business_day_rollover_hour`) when set, else
//     the operator default (`operators.rollover_hour`).
//   * `webhookBaseUri` — the F&F endpoint the vendor calls back into.
//     Composed from the configured public base URI plus the canonical
//     `/v1/webhooks/<vendorId>/<operatorId>/<locationId>` shape used
//     across the inbound webhook router (see
//     `tool/advisor_proxy/admin_integrations_routes.dart`).
//
// The resolver runs through `OperatorScopedRepository.withTenant` so
// every read flows through the per-tenant `SET LOCAL` chain. The SQL
// filters on both `operator_id` and `location_id` so cross-tenant
// reads are impossible regardless of RLS posture; RLS is the backup
// defense.
//
// Resolved configs are cached in-process by `(operatorId, locationId,
// vendorId)` for a short TTL (default 5 min) so high-frequency webhook
// dispatch does not hammer the DB. The cache is a simple invalidate-on-
// expiry map; per-process memory is bounded by the active tenant count
// and the TTL window. Cache eviction respects time only — there is no
// LRU because the working set on a single proxy instance is small.

import 'dart:collection';

import '../../infrastructure/persistence/postgres/operator_scoped_repository.dart';
import '../../infrastructure/persistence/postgres/postgres_executor.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';

/// Default cache time-to-live for resolved configs. Five minutes keeps
/// the resolver cheap under the 1.C binder's webhook fan-out while
/// still picking up operator-side timezone / rollover edits within
/// one cycle.
const Duration kPerTenantLocationConfigDefaultTtl = Duration(minutes: 5);

/// Default operator-level rollover when neither `locations` nor
/// `operators` carries a value. Mirrors the
/// `operators.rollover_hour` column default declared in
/// `db/migrations/202605070000_phase_11W_7_operator_account_fields.sql`.
const int kPerTenantLocationConfigDefaultRolloverHour = 4;

/// Resolved per-(operator, location, vendor) runtime config the
/// 1.C binder hands to adapter Deps records.
class PerTenantLocationConfig {
  PerTenantLocationConfig({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.restaurantTimezone,
    required this.businessDayRolloverHour,
    required this.webhookBaseUri,
  }) {
    if (restaurantTimezone.trim().isEmpty) {
      throw ArgumentError.value(
        restaurantTimezone,
        'restaurantTimezone',
        'must be a non-blank IANA id',
      );
    }
    if (businessDayRolloverHour < 0 || businessDayRolloverHour > 23) {
      throw ArgumentError.value(
        businessDayRolloverHour,
        'businessDayRolloverHour',
        'must be in 0..23',
      );
    }
  }

  /// Operator owning [locationId]. Echoed back so callers can audit
  /// the resolved config without re-threading the request context.
  final String operatorId;

  /// Location the config resolved for.
  final String locationId;

  /// Vendor id the [webhookBaseUri] was minted for.
  final String vendorId;

  /// IANA timezone (e.g. `America/Toronto`) sourced from
  /// `locations.timezone`. The proxy validates IANA strings before
  /// they land in the table; the resolver trusts what it reads.
  final String restaurantTimezone;

  /// Business-day rollover hour 0..23. Per-location override
  /// (`locations.business_day_rollover_hour`) wins; falls back to the
  /// operator-level default (`operators.rollover_hour`); finally
  /// [kPerTenantLocationConfigDefaultRolloverHour] when neither is set.
  final int businessDayRolloverHour;

  /// Vendor-aware F&F webhook URL — the value the adapter surfaces in
  /// its `ConnectResult.webhookUrl` so the operator can paste it into
  /// the vendor admin portal (manualPaste vendors) or the connect-time
  /// flow auto-registers it (autoRegister vendors).
  final Uri webhookBaseUri;
}

/// Thrown when the resolver cannot find the requested location for the
/// operator. Typed so callers can translate the failure into a 404 at
/// their boundary instead of leaking a generic `StateError`.
class PerTenantConfigNotFound implements Exception {
  PerTenantConfigNotFound({
    required this.operatorId,
    required this.locationId,
  });

  final String operatorId;
  final String locationId;

  @override
  String toString() =>
      'PerTenantConfigNotFound(operatorId: $operatorId, '
      'locationId: $locationId)';
}

/// Time provider seam so tests can drive cache expiry without
/// `Future.delayed`.
typedef _NowFn = DateTime Function();

/// Per-(operator, location) runtime-config resolver.
///
/// Construction takes:
///   * a `TenantTransactionWrapper`-bound base (via the
///     `OperatorScopedRepository` constructor) so SQL flows through
///     the canonical SET LOCAL path.
///   * `webhookPublicBaseUri` — F&F's public webhook entry, e.g.
///     `Uri.parse('https://api.forgeflow.app')`. The vendor-aware
///     suffix `/v1/webhooks/<vendorId>/<operatorId>/<locationId>` is
///     appended per resolve call.
///   * optional `cacheTtl` (defaults to
///     [kPerTenantLocationConfigDefaultTtl]).
class PerTenantLocationConfigResolver extends OperatorScopedRepository {
  PerTenantLocationConfigResolver(
    super.tenantWrapper, {
    required Uri webhookPublicBaseUri,
    Duration cacheTtl = kPerTenantLocationConfigDefaultTtl,
    DateTime Function()? now,
  })  : _webhookPublicBaseUri = _validateBaseUri(webhookPublicBaseUri),
        _cacheTtl = cacheTtl,
        _now = now ?? DateTime.now;

  final Uri _webhookPublicBaseUri;
  final Duration _cacheTtl;
  final _NowFn _now;
  final Map<_CacheKey, _CacheEntry> _cache = HashMap<_CacheKey, _CacheEntry>();

  /// Resolve the runtime config for `(operatorId, locationId, vendorId)`.
  ///
  /// Throws [PerTenantConfigNotFound] when the location does not exist
  /// for the operator. Cache TTL is honored: a second call inside the
  /// TTL window does not hit the DB.
  Future<PerTenantLocationConfig> resolve({
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    _validateVendorId(vendorId);

    final key = _CacheKey(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );
    final now = _now();
    final cached = _cache[key];
    if (cached != null && now.isBefore(cached.expiresAt)) {
      return cached.value;
    }

    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    final fetched = await withTenant<PerTenantLocationConfig?>(ctx, (exec) {
      return _readConfig(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        vendorId: vendorId,
      );
    });
    if (fetched == null) {
      // Drop any stale cache entry so the next call retries the read
      // instead of returning a phantom hit if the location was just
      // recreated.
      _cache.remove(key);
      throw PerTenantConfigNotFound(
        operatorId: operatorId,
        locationId: locationId,
      );
    }
    _cache[key] = _CacheEntry(value: fetched, expiresAt: now.add(_cacheTtl));
    return fetched;
  }

  /// Discards every cached entry. The 1.C binder calls this after a
  /// runtime config rewrite (e.g. operator-web edits the timezone) so
  /// the next adapter dispatch picks up the new value immediately
  /// rather than waiting for the TTL to expire.
  void invalidateAll() {
    _cache.clear();
  }

  /// Discards every cached entry for one tenant location. Cheaper than
  /// [invalidateAll] when only one (operator, location) tuple changes.
  void invalidateLocation({
    required String operatorId,
    required String locationId,
  }) {
    _cache.removeWhere(
      (key, _) =>
          key.operatorId == operatorId && key.locationId == locationId,
    );
  }

  Future<PerTenantLocationConfig?> _readConfig(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String vendorId,
  }) async {
    final rows = await exec.query(
      'select '
      '  loc.timezone as timezone, '
      '  loc.business_day_rollover_hour as location_rollover_hour, '
      '  op.rollover_hour as operator_rollover_hour '
      'from public.locations loc '
      'join public.operators op '
      '  on op.operator_id = loc.operator_id '
      'where loc.operator_id = @operator_id::uuid '
      '  and loc.location_id = @location_id::uuid '
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
      },
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final timezone = row['timezone'];
    if (timezone is! String || timezone.trim().isEmpty) {
      // The schema declares timezone NOT NULL, but defend in depth:
      // a stub that returned null would otherwise crash inside the
      // value-object constructor with a less specific error.
      throw StateError(
        'locations.timezone is null/blank for operator=$operatorId '
        'location=$locationId',
      );
    }
    final rolloverHour = _resolveRolloverHour(
      locationRollover: _intOrNull(row['location_rollover_hour']),
      operatorRollover: _intOrNull(row['operator_rollover_hour']),
    );

    return PerTenantLocationConfig(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      restaurantTimezone: timezone,
      businessDayRolloverHour: rolloverHour,
      webhookBaseUri: _composeWebhookUri(
        vendorId: vendorId,
        operatorId: operatorId,
        locationId: locationId,
      ),
    );
  }

  Uri _composeWebhookUri({
    required String vendorId,
    required String operatorId,
    required String locationId,
  }) {
    // The canonical inbound webhook router pattern is
    //   POST /v1/webhooks/<vendorId>/<operatorId>/<locationId>
    // (see tool/advisor_proxy/admin_integrations_routes.dart and
    // lib/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart).
    // We append onto whatever path the configured public base already
    // carries (e.g. `https://api.forgeflow.app/` -> appended; an
    // explicit `/proxy` prefix would be preserved).
    final basePath = _webhookPublicBaseUri.path;
    final normalizedBase = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final suffix = '/v1/webhooks/$vendorId/$operatorId/$locationId';
    return _webhookPublicBaseUri.replace(path: '$normalizedBase$suffix');
  }
}

int _resolveRolloverHour({
  required int? locationRollover,
  required int? operatorRollover,
}) {
  if (locationRollover != null) return locationRollover;
  if (operatorRollover != null) return operatorRollover;
  return kPerTenantLocationConfigDefaultRolloverHour;
}

int? _intOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

void _validateVendorId(String vendorId) {
  if (vendorId.trim().isEmpty) {
    throw ArgumentError.value(vendorId, 'vendorId', 'must be non-blank');
  }
  // Mirror the inbound webhook router pattern (see
  // admin_integrations_routes.dart `_webhookPattern`):
  // `[a-z0-9_]+`. Reject anything else so a path-traversal attempt
  // cannot land inside the composed URL.
  if (!_vendorIdPattern.hasMatch(vendorId)) {
    throw ArgumentError.value(
      vendorId,
      'vendorId',
      'must match [a-z0-9_]+',
    );
  }
}

Uri _validateBaseUri(Uri base) {
  if (!base.hasScheme || !(base.scheme == 'https' || base.scheme == 'http')) {
    throw ArgumentError.value(
      base,
      'webhookPublicBaseUri',
      'must be an absolute http/https URI',
    );
  }
  if (base.host.isEmpty) {
    throw ArgumentError.value(
      base,
      'webhookPublicBaseUri',
      'must include a host',
    );
  }
  return base;
}

final RegExp _vendorIdPattern = RegExp(r'^[a-z0-9_]+$');

class _CacheKey {
  const _CacheKey({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
  });

  final String operatorId;
  final String locationId;
  final String vendorId;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _CacheKey &&
        other.operatorId == operatorId &&
        other.locationId == locationId &&
        other.vendorId == vendorId;
  }

  @override
  int get hashCode => Object.hash(operatorId, locationId, vendorId);
}

class _CacheEntry {
  const _CacheEntry({required this.value, required this.expiresAt});

  final PerTenantLocationConfig value;
  final DateTime expiresAt;
}
