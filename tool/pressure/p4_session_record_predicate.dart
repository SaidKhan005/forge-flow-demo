// Shared session-record completeness predicate used by the
// `p4_session_soak.dart` and `p4_operator_day_soak.dart` harnesses
// AND by the production observability gauge (future slice: wire as
// `proxy.session_record.incomplete{route, missing_field}` per R3 §2
// recommendation #3).
//
// Origin: addendum B1+B2 hot-fix slice. R3 §2 calls this predicate
// out as the "cheapest immediate defense" for Bug A (proxy returned
// an incomplete session record). The contract change introduced in
// the same slice (Option A — proxy accepts scope-less `ff_support` /
// `super_admin` claims) means the predicate has a TWO-MODE shape:
//
//   1. Tenant-scoped login (the common case): every field
//      (`session_id`, `user_id`, `operator_id`, `location_id`) MUST
//      be non-empty.
//   2. Global-admin login (`ff_support` / `super_admin`): only
//      `session_id` and `user_id` are required; `operator_id` and
//      `location_id` MUST be empty strings, because global admins
//      pick an operator via the impersonation flow downstream.
//
// The harness calls this predicate on EVERY successful sign-in. A
// missing-field finding short-circuits the run with a non-zero exit
// code (Bug A regression). The same predicate is reusable by an
// in-proxy assertion if a future slice wants to fail-closed on the
// response shape before it ever leaves the proxy.

import 'dart:async';

/// Outcome of an [SessionRecordCompleteness.assertComplete] check.
class SessionRecordAssertion {
  const SessionRecordAssertion({
    required this.complete,
    required this.missingFields,
    required this.unexpectedFields,
  });

  /// True iff the record satisfied the shape for its role mode.
  final bool complete;

  /// Fields the record was missing OR had as empty strings when they
  /// should have been non-empty.
  final List<String> missingFields;

  /// Fields the record had as non-empty strings when they should have
  /// been empty (global-admin mode contract violation).
  final List<String> unexpectedFields;

  bool get isFailure => !complete;
}

class SessionRecordCompleteness {
  const SessionRecordCompleteness._();

  /// Roles that signal a global admin (platform-wide) identity. These
  /// roles bypass the per-tenant scope requirement; the contract
  /// expects `operator_id` and `location_id` to be empty strings.
  static const Set<String> globalAdminRoles = <String>{
    'ff_support',
    'super_admin',
  };

  /// Check the JSON body of a `POST /v1/auth/session/login` 200
  /// response. The proxy ALSO accepts the same shape when the route
  /// echoes scope (see `proxy_auth_session_ledger_writer.dart`); the
  /// predicate is symmetric across both call sites.
  ///
  /// [roles] is the set of roles the harness sent in the JWT. When
  /// `roles` intersects [globalAdminRoles] the global-admin shape is
  /// enforced; otherwise the tenant-scoped shape is enforced.
  static SessionRecordAssertion assertComplete(
    Map<String, Object?> body, {
    required Set<String> roles,
  }) {
    final isGlobalAdmin = roles.any(globalAdminRoles.contains);
    final sessionId = _readString(body['session_id']);
    final userId = _readString(body['user_id']);
    final operatorId = _readString(body['operator_id']);
    final locationId = _readString(body['location_id']);

    final missing = <String>[];
    final unexpected = <String>[];

    if (sessionId.isEmpty) missing.add('session_id');
    if (userId.isEmpty) missing.add('user_id');

    if (isGlobalAdmin) {
      // Global admins: operator_id + location_id must be empty
      // strings. The response shape MUST still carry the keys (so the
      // client can sanity-check the shape) but they MUST be empty.
      if (operatorId.isNotEmpty) unexpected.add('operator_id');
      if (locationId.isNotEmpty) unexpected.add('location_id');
    } else {
      // Tenant-scoped: every field must be non-empty.
      if (operatorId.isEmpty) missing.add('operator_id');
      if (locationId.isEmpty) missing.add('location_id');
    }

    return SessionRecordAssertion(
      complete: missing.isEmpty && unexpected.isEmpty,
      missingFields: List<String>.unmodifiable(missing),
      unexpectedFields: List<String>.unmodifiable(unexpected),
    );
  }

  static String _readString(Object? value) {
    if (value is String) return value;
    if (value == null) return '';
    return value.toString();
  }
}

/// Result of a soak-harness sign-in step: the proxy's HTTP status,
/// the session-record assertion, and a small response excerpt for
/// per-finding evidence.
class SoakSignInResult {
  const SoakSignInResult({
    required this.statusCode,
    required this.assertion,
    required this.responseExcerpt,
    required this.elapsedMs,
  });

  final int statusCode;
  final SessionRecordAssertion assertion;
  final String responseExcerpt;
  final int elapsedMs;
}

/// Shared finding shape for p4 harnesses. Mirrors the per-vendor
/// `_Finding` envelope used by `p3a_webhook_flood.dart` but is
/// session-shaped rather than vendor-shaped.
class SoakFinding {
  const SoakFinding({
    required this.category,
    required this.detail,
    required this.evidence,
  });

  final String category;
  final String detail;
  final Map<String, Object?> evidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'category': category,
        'detail': detail,
        'evidence': evidence,
      };
}

/// CLI duration parser shared by both p4 harnesses; identical to the
/// p3a shape so the lanes feel the same to reviewers.
int parseSoakDurationSeconds(String raw) {
  final m = RegExp(r'^(\d+)(s|sec|min|m|h)$').firstMatch(raw.trim());
  if (m == null) {
    throw FormatException('cannot parse duration: "$raw"');
  }
  final n = int.parse(m.group(1)!);
  final unit = m.group(2)!;
  switch (unit) {
    case 's':
    case 'sec':
      return n;
    case 'min':
    case 'm':
      return n * 60;
    case 'h':
      return n * 3600;
  }
  throw FormatException('unknown duration unit: "$unit"');
}

/// Hard guard substrings for soak harness URLs. Same posture as p3a:
/// refuse to run against anything that doesn't look like preview /
/// staging / a local in-process target.
const List<String> kSoakAllowedHostSubstrings = <String>[
  'forge-flow-preview-',
  'forge-flow-staging-',
  'localhost',
  '127.0.0.1',
];

bool isSoakProxyUrlAllowed(String url) {
  return kSoakAllowedHostSubstrings.any((s) => url.contains(s));
}

/// Future shape used by both harnesses for SIGINT-driven shutdown.
class SoakShutdownSignal {
  final Completer<void> _completer = Completer<void>();

  Future<void> get future => _completer.future;
  bool get isFired => _completer.isCompleted;
  void fire() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
