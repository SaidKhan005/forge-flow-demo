// Phase 8 / Wave 11W.8 follow-up — operator-scoped read of the
// "recently available" vendor list.
//
// Operator-web Vendor Connections needs an in-app surface that mirrors
// the email fan-out shipped by `8.0.lifecycle` /
// `vendor_lifecycle_notification_dispatcher.dart`. When the dispatcher
// fans out a `vendor_now_available` email it stamps
// `vendor_lifecycle_notification.notified_at = now()`. This route
// exposes "vendors I subscribed to that recently flipped to
// production_credentialed" so the operator sees the same news in the
// console without waiting for the email to arrive.
//
// Routes:
//
//   GET /v1/operator/vendor-lifecycle/recently-available
//        Returns recently-promoted vendors for the caller's
//        operator_id. Default time window is the last 14 days; callers
//        may shrink it with `?since=<iso8601>` (must be in the past
//        and within the last 90 days).
//
// Auth + scope:
//   * Bearer token resolves to OperatorContext (operatorId).
//   * Per-tenant RLS enforced via `SET LOCAL` inside the gateway.
//   * Reads are open to operator-web roles that already see the
//     Vendor Connections screen — owner / admin write the screen,
//     `location_manager` lands on the read-only forbidden body but the
//     route still admits the role so the badge poll returns honestly.
//
// Idempotency:
//   * Read-only — no Idempotency-Key header required.
//
// CLAUDE.md compliance:
//   * Operator-scoped: every route resolves operatorId from the JWT,
//     never from the URL or body.
//   * Postgres time guardrail: timestamps round-trip in ISO-8601 UTC.

import 'dart:io' show HttpStatus;

const String operatorVendorLifecycleRecentlyAvailablePath =
    '/v1/operator/vendor-lifecycle/recently-available';

/// Default look-back window when the caller does not supply `?since=`.
/// Mirrors the slice prompt: vendors promoted in the last 14 days.
const Duration kOperatorVendorLifecycleRecentlyAvailableDefaultWindow =
    Duration(days: 14);

/// Hard upper bound on the look-back window the caller may request.
/// Anything older than the email subscription itself is irrelevant; the
/// Notify-me capture itself is at most a few months old in practice.
const Duration kOperatorVendorLifecycleRecentlyAvailableMaxWindow =
    Duration(days: 90);

/// Roles permitted to read the recently-available list. Mirrors the
/// admit set on the Vendor Connections screen so a `location_manager`
/// session sees the same read surface (the screen itself renders the
/// friendly forbidden body for the configure path).
const Set<String> kOperatorVendorLifecycleRecentlyAvailableReadRoles =
    <String>{
  'operator_owner',
  'operator_admin',
  'location_manager',
};

/// One row in the response — a vendor that recently flipped to
/// `production_credentialed` for which this operator had a Notify-me
/// subscription.
class OperatorRecentlyAvailableVendor {
  const OperatorRecentlyAvailableVendor({
    required this.vendorId,
    required this.vendorDisplayName,
    required this.lifecycleState,
    required this.promotedAt,
  });

  /// `vendor_lifecycle_notification.vendor_id`. Mirrors
  /// `connector_connection.vendor_id` so the screen can match the row
  /// up to the existing vendor card.
  final String vendorId;

  /// Operator-facing label (e.g. "Toast"). Production resolves this
  /// from the live capability registries; tests pin a fixed value.
  final String vendorDisplayName;

  /// Wire lifecycle state. Always `productionCredentialed` for now —
  /// only the `productionCredentialed` flip enqueues an email and
  /// stamps `notified_at`. The field is kept on the wire so a future
  /// `liveWithOperators` flip can ride the same response without a
  /// breaking change.
  final String lifecycleState;

  /// UTC timestamp the operator's first matching subscription was
  /// stamped `notified_at`. The screen renders this as a relative
  /// "3 days ago" string, falling back to the absolute value on
  /// hover.
  final DateTime promotedAt;
}

/// Resolves the operator-facing display name for a vendor id.
/// Production binds this to `lookupVendorCapability(vendorId)` over
/// the existing capability registries; tests pin a fixed map. Returns
/// null when the vendor id is unknown — the route then falls back to
/// the raw vendor id so the screen still renders an honest row.
typedef OperatorRecentlyAvailableVendorDisplayNameResolver = String? Function(
  String vendorId,
);

/// Narrow gateway seam the route reads against. Production binds this
/// to a tenant-pool query against `vendor_lifecycle_notification`
/// (filtered to `notified_at >= since`); tests inject a recording stub.
abstract class OperatorRecentlyAvailableVendorsGateway {
  /// Returns vendors whose `notified_at` is at or after [since] for the
  /// caller's [operatorId]. Result is unique per `vendor_id`; when the
  /// operator has multiple subscriptions for the same vendor the
  /// gateway returns the most recent stamp. Order is `promoted_at
  /// desc` so the screen renders newest first.
  ///
  /// [locationId] is forwarded to the tenant-scoped transaction so
  /// `SET LOCAL` populates the `app.location_id` GUC even though the
  /// `vendor_lifecycle_notification` table is operator-scoped only;
  /// keeping the GUC populated avoids surprising downstream readers
  /// that share the connection during the same request.
  Future<List<OperatorRecentlyAvailableVendorRow>> listRecentlyPromoted({
    required String operatorId,
    required String locationId,
    required DateTime since,
    String? actorUserId,
  });
}

/// Raw row shape returned by the gateway. The route stitches in the
/// per-vendor display name from the resolver before responding so the
/// gateway stays integration-agnostic (no `import` of the
/// `kPosCapabilityProfiles` map at the gateway layer).
class OperatorRecentlyAvailableVendorRow {
  const OperatorRecentlyAvailableVendorRow({
    required this.vendorId,
    required this.promotedAt,
  });

  final String vendorId;
  final DateTime promotedAt;
}

/// Result envelope returned by [OperatorVendorLifecycleRecentlyAvailableRouter.handle].
class OperatorVendorLifecycleRecentlyAvailableRouteResult {
  const OperatorVendorLifecycleRecentlyAvailableRouteResult({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Self-contained router for the read surface. Mounted by
/// `routeRequest` next to the other operator GET routes.
class OperatorVendorLifecycleRecentlyAvailableRouter {
  OperatorVendorLifecycleRecentlyAvailableRouter({
    required OperatorRecentlyAvailableVendorsGateway gateway,
    required OperatorRecentlyAvailableVendorDisplayNameResolver
        displayNameResolver,
    DateTime Function()? now,
  })  : _gateway = gateway,
        _resolveDisplayName = displayNameResolver,
        _now = now ?? DateTime.now;

  final OperatorRecentlyAvailableVendorsGateway _gateway;
  final OperatorRecentlyAvailableVendorDisplayNameResolver _resolveDisplayName;
  final DateTime Function() _now;

  /// True iff [path] / [method] match the read route. Method-and-path
  /// only; the dispatcher resolves auth + scope before invoking
  /// [handle].
  static bool matches(String path, String method) {
    return method == 'GET' &&
        path == operatorVendorLifecycleRecentlyAvailablePath;
  }

  /// Handles one read request after the dispatcher has resolved auth.
  Future<OperatorVendorLifecycleRecentlyAvailableRouteResult> handle({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required Map<String, String> queryParameters,
  }) async {
    final now = _now().toUtc();
    final raw = queryParameters['since'];
    DateTime since;
    if (raw == null) {
      since = now
          .subtract(kOperatorVendorLifecycleRecentlyAvailableDefaultWindow);
    } else {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        return const OperatorVendorLifecycleRecentlyAvailableRouteResult(
          statusCode: HttpStatus.badRequest,
          body: <String, Object?>{
            'error': 'invalid_since',
            'message':
                'since query parameter must be a non-blank ISO-8601 '
                'timestamp',
          },
        );
      }
      final parsed = DateTime.tryParse(trimmed);
      if (parsed == null) {
        return const OperatorVendorLifecycleRecentlyAvailableRouteResult(
          statusCode: HttpStatus.badRequest,
          body: <String, Object?>{
            'error': 'invalid_since',
            'message':
                'since query parameter must be a parseable ISO-8601 '
                'timestamp',
          },
        );
      }
      since = parsed.toUtc();
      if (since.isAfter(now)) {
        return const OperatorVendorLifecycleRecentlyAvailableRouteResult(
          statusCode: HttpStatus.badRequest,
          body: <String, Object?>{
            'error': 'invalid_since',
            'message': 'since query parameter must be in the past',
          },
        );
      }
      final earliest = now
          .subtract(kOperatorVendorLifecycleRecentlyAvailableMaxWindow);
      if (since.isBefore(earliest)) {
        since = earliest;
      }
    }

    final rows = await _gateway.listRecentlyPromoted(
      operatorId: operatorId,
      locationId: locationId,
      since: since,
      actorUserId: actorUserId,
    );
    return OperatorVendorLifecycleRecentlyAvailableRouteResult(
      statusCode: HttpStatus.ok,
      body: <String, Object?>{
        'operator_id': operatorId,
        'since': since.toIso8601String(),
        'vendors': <Map<String, Object?>>[
          for (final row in rows)
            <String, Object?>{
              'vendor_id': row.vendorId,
              'vendor_display_name':
                  _resolveDisplayName(row.vendorId) ?? row.vendorId,
              'lifecycle_state': 'productionCredentialed',
              'promoted_at': row.promotedAt.toUtc().toIso8601String(),
            },
        ],
      },
    );
  }
}
