// Phase 11W.8 follow-up — Operator Web Vendor Lifecycle Recently
// Available gateway.
//
// Reads the `vendor_lifecycle_notification` (mirrored as the
// recently-available list) projection through the operator-scoped proxy
// route shipped by
// `tool/advisor_proxy/vendor_lifecycle_recently_available_routes.dart`.
//
// Web-safe: pure-Dart, no `dart:io`. Mirrors the existing operator-web
// gateway shape (live HTTP impl + demo impl + provider sentinel) so
// the auth source mixes in the gateway and the screen consumes it via
// `is`-typecheck without coupling to a concrete impl.
//
// UX writing standard (per `memory/project_ux_writing_standard.md`):
// the screen renders plain-English copy ("3 days ago" / "yesterday" /
// "today") for the relative timestamp; the gateway returns the raw
// UTC instant so the screen can format without re-parsing strings.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// One vendor row, projected from the proxy's
/// `/v1/operator/vendor-lifecycle/recently-available` response. Field
/// names mirror the wire shape so the screen + gateway never disagree.
class OperatorWebRecentlyAvailableVendor {
  const OperatorWebRecentlyAvailableVendor({
    required this.vendorId,
    required this.vendorDisplayName,
    required this.lifecycleState,
    required this.promotedAt,
  });

  /// Stable vendor key matching `connector_connection.vendor_id`.
  final String vendorId;

  /// Operator-facing display name ("Toast"). Falls back to [vendorId]
  /// on the proxy side when the capability registry has no entry.
  final String vendorDisplayName;

  /// Wire lifecycle state. Today always `productionCredentialed`; the
  /// field is kept on the wire so a future `liveWithOperators` flip
  /// can ride the same response without a breaking change.
  final String lifecycleState;

  /// UTC timestamp of the lifecycle promotion. Rendered as a relative
  /// "3 days ago" string by the screen.
  final DateTime promotedAt;
}

/// Wire response for one read. Order is `promoted_at desc` so the
/// screen renders newest first.
class OperatorWebRecentlyAvailableVendorsBundle {
  const OperatorWebRecentlyAvailableVendorsBundle({
    required this.operatorId,
    required this.since,
    required this.vendors,
  });

  final String operatorId;
  final DateTime since;
  final List<OperatorWebRecentlyAvailableVendor> vendors;
}

/// Narrow gateway interface the Vendor Connections recently-available
/// panel reads against. Demo + live impls share the same shape.
abstract class OperatorWebVendorLifecycleRecentlyAvailableGateway {
  /// Loads the recently-available vendors for the caller's operator.
  /// [since] narrows the look-back window when non-null; the proxy
  /// clamps anything beyond its 90-day max.
  Future<OperatorWebRecentlyAvailableVendorsBundle> loadRecentlyAvailable({
    DateTime? since,
  });
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply an [OperatorWebVendorLifecycleRecentlyAvailableGateway].
/// Demo sources omit the mixin and the screen renders an honest empty
/// state instead of falling back to a fixture (so the demo
/// walkthrough does not lie about progress).
abstract class OperatorWebVendorLifecycleRecentlyAvailableGatewayProvider {
  OperatorWebVendorLifecycleRecentlyAvailableGateway?
      get vendorLifecycleRecentlyAvailableGateway;
}

/// Thrown when the proxy returns a non-2xx, the response body is
/// malformed, or the network call fails. Carries the proxy's error
/// code + message verbatim so the screen can surface honest copy.
class OperatorWebVendorLifecycleRecentlyAvailableError implements Exception {
  const OperatorWebVendorLifecycleRecentlyAvailableError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'OperatorWebVendorLifecycleRecentlyAvailableError(code: $code, '
      'status: $statusCode, message: $message)';
}

/// Live `package:http` implementation. Reads the Firebase ID token off
/// the supplied provider on every call so refreshed tokens land on the
/// next request; reuses the operator-web proxy path constant.
class OperatorWebVendorLifecycleRecentlyAvailableGatewayLive
    implements OperatorWebVendorLifecycleRecentlyAvailableGateway {
  OperatorWebVendorLifecycleRecentlyAvailableGatewayLive({
    required this.proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 30),
  })  : _idTokenProvider = idTokenProvider,
        _httpClient = httpClient ?? http.Client(),
        _timeout = timeout;

  final Uri proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  /// Wire path the live route is mounted at. Mirrored by the proxy
  /// route file `vendor_lifecycle_recently_available_routes.dart`.
  static const String path = '/v1/operator/vendor-lifecycle/recently-available';

  @override
  Future<OperatorWebRecentlyAvailableVendorsBundle> loadRecentlyAvailable({
    DateTime? since,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebVendorLifecycleRecentlyAvailableError(
        code: 'no_id_token',
        message:
            'Recently-available vendors gateway has no live Firebase ID '
            'token to attach to the request.',
      );
    }
    final params = <String, String>{};
    if (since != null) {
      params['since'] = since.toUtc().toIso8601String();
    }
    final url = proxyBaseUri.resolve(path).replace(
          queryParameters: params.isEmpty ? null : params,
        );
    final request = http.Request('GET', url)
      ..headers.addAll(<String, String>{
        'accept': 'application/json',
        'authorization': 'Bearer ${token.trim()}',
      });
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const OperatorWebVendorLifecycleRecentlyAvailableError(
        code: 'transport_timeout',
        message:
            'Recently-available vendors request timed out before reaching '
            'the proxy.',
      );
    } catch (error) {
      throw OperatorWebVendorLifecycleRecentlyAvailableError(
        code: 'transport_error',
        message:
            'Recently-available vendors request failed before reaching the '
            'proxy ($error).',
      );
    }
    final raw = await streamed.stream.bytesToString().timeout(_timeout);
    Object? decoded;
    if (raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        decoded = const <String, Object?>{};
      }
    }
    final body = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw OperatorWebVendorLifecycleRecentlyAvailableError(
        code: _readNonBlankString(body['error']) ??
            'vendor_lifecycle_recently_available_failed',
        message: _readNonBlankString(body['message']) ??
            'proxy returned status ${streamed.statusCode}',
        statusCode: streamed.statusCode,
      );
    }
    return _bundleFromJson(body);
  }

  static OperatorWebRecentlyAvailableVendorsBundle _bundleFromJson(
    Map<String, Object?> body,
  ) {
    final operatorId = _readNonBlankString(body['operator_id']) ?? '';
    final since = _readDate(body['since']) ?? DateTime.now().toUtc();
    final raw = body['vendors'];
    final vendors = <OperatorWebRecentlyAvailableVendor>[];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is Map<Object?, Object?>) {
          final vendor = _vendorFromJson(Map<String, Object?>.from(entry));
          if (vendor != null) vendors.add(vendor);
        }
      }
    }
    return OperatorWebRecentlyAvailableVendorsBundle(
      operatorId: operatorId,
      since: since,
      vendors: List<OperatorWebRecentlyAvailableVendor>.unmodifiable(vendors),
    );
  }

  static OperatorWebRecentlyAvailableVendor? _vendorFromJson(
    Map<String, Object?> json,
  ) {
    final vendorId = _readNonBlankString(json['vendor_id']);
    final lifecycleState = _readNonBlankString(json['lifecycle_state']);
    final promotedAt = _readDate(json['promoted_at']);
    if (vendorId == null || lifecycleState == null || promotedAt == null) {
      return null;
    }
    final displayName =
        _readNonBlankString(json['vendor_display_name']) ?? vendorId;
    return OperatorWebRecentlyAvailableVendor(
      vendorId: vendorId,
      vendorDisplayName: displayName,
      lifecycleState: lifecycleState,
      promotedAt: promotedAt,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value.toUtc();
    final raw = _readNonBlankString(value);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

/// In-memory demo + test gateway. Tests instantiate it directly with
/// the same fixture shape the live gateway returns; the demo auth
/// source generally omits the provider mixin so the screen renders
/// honest "no new vendors" copy without faking promotions.
class OperatorWebVendorLifecycleRecentlyAvailableGatewayInMemory
    implements OperatorWebVendorLifecycleRecentlyAvailableGateway {
  OperatorWebVendorLifecycleRecentlyAvailableGatewayInMemory({
    required this.operatorId,
    List<OperatorWebRecentlyAvailableVendor>? vendors,
    DateTime? defaultSince,
  })  : _vendors = List<OperatorWebRecentlyAvailableVendor>.unmodifiable(
          vendors ?? const <OperatorWebRecentlyAvailableVendor>[],
        ),
        _defaultSince = defaultSince;

  final String operatorId;
  final List<OperatorWebRecentlyAvailableVendor> _vendors;
  final DateTime? _defaultSince;

  @override
  Future<OperatorWebRecentlyAvailableVendorsBundle> loadRecentlyAvailable({
    DateTime? since,
  }) async {
    final effectiveSince = since?.toUtc() ??
        _defaultSince?.toUtc() ??
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 14));
    final filtered = _vendors
        .where(
          (vendor) => !vendor.promotedAt.toUtc().isBefore(effectiveSince),
        )
        .toList(growable: false);
    filtered.sort((a, b) => b.promotedAt.compareTo(a.promotedAt));
    return OperatorWebRecentlyAvailableVendorsBundle(
      operatorId: operatorId,
      since: effectiveSince,
      vendors: List<OperatorWebRecentlyAvailableVendor>.unmodifiable(filtered),
    );
  }
}
