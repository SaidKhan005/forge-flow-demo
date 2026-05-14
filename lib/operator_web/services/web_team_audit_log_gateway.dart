// Phase 11W.5 - Operator Web audit log gateway (live).
//
// `package:http` re-implementation of the Audit Log surface so the
// operator-web build can call the existing Phase 9 proxy route without
// dragging in `dart:io`.
//
// Routes (already shipped by Phase 9, no new backend surface added by
// 11W.5):
//
//   * GET  /v1/auth/audit-log  - actor + operator scoped audit ledger.
//                                Proxy clamps user_id to the verified
//                                bearer token; client-supplied
//                                user_id query params are ignored.
//
// Filter set (locked by the parity contract `§ Audit Log`):
//
//   * actor      - one or more user ids (rendered as a multi-select
//                  picker in the screen). The live route currently
//                  clamps to the calling user, so only demo mode
//                  supports a fan-out picker; live mode passes the
//                  actor filter through as a hint and lets the proxy
//                  handle it server-side once the route accepts it.
//   * action     - locked enum string (e.g. team.users.invite). Maps
//                  to the existing route's `event_kind` query for the
//                  coarse server-side bucket; the gateway also keeps
//                  the fine-grained action so demo mode + future live
//                  filter additions can apply it.
//   * target_kind / target_id  - free-text on the audit row. Demo
//                                mode applies these locally; live mode
//                                forwards them as query params for the
//                                proxy to honor when the route adds
//                                support.
//   * time_window  - one of last24h / last7d / last30d / last90d /
//                    custom. Mapped onto the existing route's `from` /
//                    `to` UTC params.
//   * actor_kind   - team_member / forge_admin / service_principal.
//                    Self-service surface fixes this to team_member;
//                    the F&F admin surface (11A.14) widens it.
//
// Pagination is offset-based on the wire (the live route) but
// presented as opaque cursor strings to the screen so a future swap
// to a server-side cursor leaves the screen contract unchanged. The
// gateway encodes the offset as `offset:<int>` and the screen treats
// the value as opaque.
//
// Privacy posture: the entry shape carries actor identity (display
// name + email) so the screen can render the audit row, but the
// gateway never returns raw IPs. The mobile reference section already
// hides them; the operator-web screen does the same.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Coarse action bucket for the Audit Log filter chips. Mirrors the
/// existing `AuthEventKind` set on the proxy so the live route's
/// `event_kind` query param can light up off the same enum.
enum WebAuditLogActionBucket {
  signIn,
  password,
  mfa,
  role,
  session,
  invite,
  user,
  other,
}

/// Wire-format key the existing `/v1/auth/audit-log` route accepts on
/// the `event_kind` query param. Stable across versions so the live
/// proxy contract does not move under us.
String webAuditLogActionBucketWireKey(WebAuditLogActionBucket bucket) {
  switch (bucket) {
    case WebAuditLogActionBucket.signIn:
      return 'sign_in';
    case WebAuditLogActionBucket.password:
      return 'password';
    case WebAuditLogActionBucket.mfa:
      return 'mfa';
    case WebAuditLogActionBucket.role:
      return 'role';
    case WebAuditLogActionBucket.session:
      return 'session';
    case WebAuditLogActionBucket.invite:
      return 'invite';
    case WebAuditLogActionBucket.user:
      return 'user';
    case WebAuditLogActionBucket.other:
      return 'other';
  }
}

/// Pre-canned time window the screen exposes. `custom` expects the
/// caller to set [WebAuditLogQuery.customFrom] / [WebAuditLogQuery.customTo].
enum WebAuditLogTimeWindow { last24h, last7d, last30d, last90d, custom }

/// Actor-kind filter. Self-service surface fixes this to team_member;
/// the F&F admin surface widens it to forge_admin / service_principal.
enum WebAuditLogActorKind { teamMember, forgeAdmin, servicePrincipal }

String webAuditLogActorKindWire(WebAuditLogActorKind kind) {
  switch (kind) {
    case WebAuditLogActorKind.teamMember:
      return 'team_member';
    case WebAuditLogActorKind.forgeAdmin:
      return 'forge_admin';
    case WebAuditLogActorKind.servicePrincipal:
      return 'service_principal';
  }
}

WebAuditLogActorKind? webAuditLogActorKindFromWire(String? raw) {
  switch (raw) {
    case 'team_member':
      return WebAuditLogActorKind.teamMember;
    case 'forge_admin':
      return WebAuditLogActorKind.forgeAdmin;
    case 'service_principal':
      return WebAuditLogActorKind.servicePrincipal;
  }
  return null;
}

/// Locked enum of canonical actions the parity contract names. The
/// gateway accepts arbitrary strings on the wire; this catalog drives
/// the screen's action picker so the demo + live surfaces share one
/// list of humanized labels.
class WebAuditLogActions {
  const WebAuditLogActions._();

  /// `team.users.invite` per parity contract example.
  static const String teamUsersInvite = 'team.users.invite';
  static const String teamUsersDeactivate = 'team.users.deactivate';
  static const String teamUsersReactivate = 'team.users.reactivate';
  static const String teamUsersSoftDelete = 'team.users.soft_delete';
  static const String teamUsersResetPassword = 'team.users.reset_password';
  static const String teamUsersResetMfa = 'team.users.reset_mfa';
  static const String teamRolesCreateCustom = 'team.roles.create_custom';
  static const String teamRolesAssign = 'team.roles.assign';
  static const String teamRolesRevoke = 'team.roles.revoke';
  static const String teamSessionForceLogout = 'team.session.force_logout';
  static const String teamOrgUnitMove = 'team.org_unit.move';
  static const String authSessionSignedIn = 'auth.user.signed_in';
  static const String authSessionSignedOut = 'auth.session_revoked';
  static const String authPasswordChanged = 'auth.password_changed';
  static const String authMfaEnrolled = 'auth.mfa_totp_enrolled';
  static const String authMfaFactorRemoved = 'auth.mfa_factor_removed';
  static const String auditExportRequested = 'audit.export.requested';

  /// Catalog the screen renders in its `Action` picker. Order matches
  /// the parity contract category ordering (team.users → team.roles →
  /// team.session → team.org_unit → auth.* → audit.*).
  static const List<String> catalog = <String>[
    teamUsersInvite,
    teamUsersDeactivate,
    teamUsersReactivate,
    teamUsersSoftDelete,
    teamUsersResetPassword,
    teamUsersResetMfa,
    teamRolesCreateCustom,
    teamRolesAssign,
    teamRolesRevoke,
    teamSessionForceLogout,
    teamOrgUnitMove,
    authSessionSignedIn,
    authSessionSignedOut,
    authPasswordChanged,
    authMfaEnrolled,
    authMfaFactorRemoved,
    auditExportRequested,
  ];
}

/// Humanized labels for the locked action enum.
///
/// Two label families coexist:
///   * `team.*` actions follow the verb-object form documented in the
///     parity contract example
///     (`team.users.invite` -> "Invited team member"). The team.*
///     namespace is the new audit_logs.action enum the parity slices
///     introduce; the contract names the labels directly.
///   * `auth.*` events come from the existing `auth_events_audit`
///     ledger that mobile already renders. Per the parity contract
///     hard constraint "Action humanization is rendered consistently
///     with mobile", these reuse mobile's
///     `AuthEventLabels.labelFor` mappings verbatim
///     (`lib/services/auth/auth_operations_gateway.dart`). Updating
///     either side requires updating the other.
class WebAuditLogActionLabels {
  const WebAuditLogActionLabels._();

  static String labelFor(String action) {
    switch (action) {
      // team.* family - verb-object form per the parity contract.
      case WebAuditLogActions.teamUsersInvite:
        return 'Invited team member';
      case WebAuditLogActions.teamUsersDeactivate:
        return 'Suspended team member';
      case WebAuditLogActions.teamUsersReactivate:
        return 'Reactivated team member';
      case WebAuditLogActions.teamUsersSoftDelete:
        return 'Soft-deleted team member';
      case WebAuditLogActions.teamUsersResetPassword:
        return 'Sent password reset email';
      case WebAuditLogActions.teamUsersResetMfa:
        return 'Reset two-factor sign-in';
      case WebAuditLogActions.teamRolesCreateCustom:
        return 'Created custom role';
      case WebAuditLogActions.teamRolesAssign:
        return 'Assigned role';
      case WebAuditLogActions.teamRolesRevoke:
        return 'Revoked role grant';
      case WebAuditLogActions.teamSessionForceLogout:
        return 'Signed out a team member session';
      case WebAuditLogActions.teamOrgUnitMove:
        return 'Moved an org unit';
      // auth.* family - mobile parity. Mirrors
      // `AuthEventLabels.labelFor` so the same event_type reads
      // identically on mobile and web.
      case WebAuditLogActions.authSessionSignedIn:
      case 'auth.signed_in':
        return 'Sign-in';
      case WebAuditLogActions.authSessionSignedOut:
        return 'Session revoked';
      case 'auth.all_sessions_revoked':
        return 'Signed out of all devices';
      case 'auth.user.password_changed':
      case WebAuditLogActions.authPasswordChanged:
        return 'Password changed';
      case 'auth.password_reset_requested':
        return 'Password reset requested';
      case 'auth.password_reset_confirmed':
        return 'Password reset completed';
      case WebAuditLogActions.authMfaEnrolled:
        return 'Two-factor sign-in enabled';
      case 'auth.mfa_totp_enroll_failed':
        return 'Two-factor sign-in setup failed';
      case 'auth.user.mfa_factor_removed':
      case WebAuditLogActions.authMfaFactorRemoved:
        return 'Two-factor sign-in disabled';
      case 'auth.user.mfa_recovery_requested':
      case 'auth.mfa_recovery_requested':
        return 'Two-factor sign-in recovery requested';
      case 'auth.role_grant_created':
        return 'Role grant added';
      case 'auth.role_grant_revoked':
        return 'Role grant revoked';
      case 'auth.custom_role_created':
        return 'Custom role created';
      case 'auth.custom_role_updated':
        return 'Custom role updated';
      case 'auth.custom_role_deleted':
        return 'Custom role deleted';
      case 'auth.invite_created':
        return 'Invite created';
      case 'auth.invite_revoked':
        return 'Invite cancelled';
      case 'invite.cancel':
        return 'Invite cancelled';
      case 'auth.invite_accepted':
        return 'Invite accepted';
      case 'auth.user_suspended':
        return 'User suspended';
      case 'auth.user_reactivated':
        return 'User reactivated';
      case 'auth.user_soft_deleted':
        return 'User soft-deleted';
      // audit.* family.
      case WebAuditLogActions.auditExportRequested:
        return 'Exported audit log';
    }
    // Fall back to a humanized version of the raw action string so a
    // newly added server-side action stays readable.
    final tail = action.contains('.')
        ? action.substring(action.lastIndexOf('.') + 1)
        : action;
    if (tail.isEmpty) return action;
    final words = tail.split('_');
    final first = words.first;
    final head = first.isEmpty
        ? ''
        : first.substring(0, 1).toUpperCase() + first.substring(1);
    final rest = words.skip(1).join(' ');
    return rest.isEmpty ? head : '$head $rest';
  }

  /// Coarse [WebAuditLogActionBucket] for the action so the action
  /// dropdown selection can light up the right `event_kind` query
  /// parameter on the existing route.
  static WebAuditLogActionBucket bucketFor(String action) {
    final lower = action.toLowerCase();
    if (lower.contains('signed_in') ||
        lower.contains('sign_in') ||
        lower.contains('signin') ||
        lower.contains('login')) {
      return WebAuditLogActionBucket.signIn;
    }
    if (lower.contains('password')) return WebAuditLogActionBucket.password;
    if (lower.contains('mfa') || lower.contains('totp')) {
      return WebAuditLogActionBucket.mfa;
    }
    if (lower.contains('role') || lower.contains('grant')) {
      return WebAuditLogActionBucket.role;
    }
    if (lower.contains('session')) return WebAuditLogActionBucket.session;
    if (lower.contains('invite')) return WebAuditLogActionBucket.invite;
    if (lower.contains('user_') || lower.contains('.user.')) {
      return WebAuditLogActionBucket.user;
    }
    return WebAuditLogActionBucket.other;
  }
}

/// One audit-log row. Mirrors the canonical `audit_logs` shape
/// projected by the proxy (the existing self-service route reads
/// `auth_events_audit` via `listAuthEventsForActor`; the audit_logs
/// rollout in Phase 11W.5 surfaces the new shape here). Fields the
/// existing route does not yet ship are nullable so the projection
/// can degrade cleanly until the route widens.
class WebAuditLogEntry {
  const WebAuditLogEntry({
    required this.entryId,
    required this.action,
    required this.actorKind,
    required this.createdAt,
    this.actorUserId,
    this.actorDisplayName,
    this.actorEmail,
    this.targetKind,
    this.targetId,
    this.payload = const <String, Object?>{},
    this.adminReason,
  });

  /// Stable id for the audit row. Used as the React key analogue.
  final String entryId;

  /// Raw action string (e.g. `team.users.invite`). The screen runs
  /// this through [WebAuditLogActionLabels.labelFor] for display.
  final String action;

  /// `team_member` for `/v1/auth/*` calls; `forge_admin` for
  /// `/v1/admin/auth/*` calls; `service_principal` for `sp:` JWTs.
  final WebAuditLogActorKind actorKind;

  /// `created_at` in UTC. The screen converts to operator-local TZ.
  final DateTime createdAt;

  final String? actorUserId;
  final String? actorDisplayName;
  final String? actorEmail;

  /// Entity touched (e.g. `team_user`, `role`, `session`, `org_unit`).
  final String? targetKind;

  /// Target id rendered with a copy-to-clipboard button.
  final String? targetId;

  /// Decoded JSONB payload for the `View payload` toggle. Empty map
  /// when the proxy did not include one.
  final Map<String, Object?> payload;

  /// REQUIRED for `actor_kind = forge_admin`; NULL otherwise. Renders
  /// inline on F&F admin rows once 11A.14 lights up; self-service
  /// rows leave it null.
  final String? adminReason;
}

/// Cursor-pagination wrapper. The screen treats [nextCursor] as
/// opaque. The gateway encodes the offset as `offset:<int>` so the
/// existing offset-based proxy route can be wrapped without leaking
/// shape to the screen.
class WebAuditLogPage {
  const WebAuditLogPage({required this.entries, this.nextCursor});

  final List<WebAuditLogEntry> entries;

  /// Opaque cursor for the next page. Null when the page is the
  /// last.
  final String? nextCursor;
}

/// Filter parameters the screen sends through to the gateway. The
/// shape here is the cross-surface contract; the live HTTP impl maps
/// it onto query params, the demo impl applies it locally.
class WebAuditLogQuery {
  const WebAuditLogQuery({
    this.actorUserIds = const <String>[],
    this.actions = const <String>[],
    this.actorKinds = const <WebAuditLogActorKind>[],
    this.targetKind,
    this.targetId,
    this.timeWindow = WebAuditLogTimeWindow.last7d,
    this.customFrom,
    this.customTo,
    this.cursor,
    this.limit = 200,
  });

  final List<String> actorUserIds;

  /// One or more actions (multi-select). When the list maps cleanly
  /// to a single [WebAuditLogActionBucket], the live gateway uses
  /// that on the `event_kind` query param.
  final List<String> actions;

  final List<WebAuditLogActorKind> actorKinds;
  final String? targetKind;
  final String? targetId;
  final WebAuditLogTimeWindow timeWindow;
  final DateTime? customFrom;
  final DateTime? customTo;

  /// Opaque cursor returned by the previous page; null on first
  /// page request.
  final String? cursor;

  /// Per the parity contract: 200 rows per page.
  final int limit;

  WebAuditLogQuery copyWith({
    List<String>? actorUserIds,
    List<String>? actions,
    List<WebAuditLogActorKind>? actorKinds,
    Object? targetKind = _unset,
    Object? targetId = _unset,
    WebAuditLogTimeWindow? timeWindow,
    Object? customFrom = _unset,
    Object? customTo = _unset,
    Object? cursor = _unset,
    int? limit,
  }) {
    return WebAuditLogQuery(
      actorUserIds: actorUserIds ?? this.actorUserIds,
      actions: actions ?? this.actions,
      actorKinds: actorKinds ?? this.actorKinds,
      targetKind: identical(targetKind, _unset)
          ? this.targetKind
          : targetKind as String?,
      targetId:
          identical(targetId, _unset) ? this.targetId : targetId as String?,
      timeWindow: timeWindow ?? this.timeWindow,
      customFrom: identical(customFrom, _unset)
          ? this.customFrom
          : customFrom as DateTime?,
      customTo:
          identical(customTo, _unset) ? this.customTo : customTo as DateTime?,
      cursor: identical(cursor, _unset) ? this.cursor : cursor as String?,
      limit: limit ?? this.limit,
    );
  }

  static const Object _unset = Object();
}

/// Result of a CSV export. The screen hands [csv] off to the browser
/// for download; the demo gateway also writes its own audit row so
/// the export-is-itself-audited rule renders in the walkthrough.
class WebAuditLogCsvExport {
  const WebAuditLogCsvExport({required this.csv, required this.filename});

  final String csv;
  final String filename;
}

/// Narrow gateway interface the Audit Log screen reads + exports
/// against. Mirrors the existing `/v1/auth/audit-log` shape with a
/// cursor-pagination wrapper.
abstract class WebTeamAuditLogGateway {
  /// Lists one page of audit rows matching [query].
  Future<WebAuditLogPage> listEntries(WebAuditLogQuery query);

  /// Renders [query] as a CSV string. Live mode requests a signed URL
  /// from the proxy and follows it; demo mode renders client-side
  /// (and writes an `audit.export.requested` row to its own fixture
  /// so the walkthrough sees the export-is-audited rule).
  Future<WebAuditLogCsvExport> exportCsv(
    WebAuditLogQuery query, {
    required String idempotencyKey,
  });
}

/// Thrown when the proxy returns a non-2xx for an audit log call, or
/// when the response body cannot be parsed.
class WebTeamAuditLogError implements Exception {
  const WebTeamAuditLogError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  bool get isForbidden => statusCode == 401 || statusCode == 403;

  @override
  String toString() =>
      'WebTeamAuditLogError(code: $code, status: $statusCode, message: $message)';
}

/// Wire response shape. Mirrors the live impl decode so unit tests
/// can assert on body without re-implementing the parser.
class WebTeamAuditLogResponse {
  const WebTeamAuditLogResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Map<String, Object?> body;
}

/// Path constants used by both the gateway and its tests.
class WebTeamAuditLogPaths {
  const WebTeamAuditLogPaths._();

  /// Existing Phase 9 route. Self-service; proxy auto-clamps the
  /// caller's user_id from the bearer token.
  static const String list = '/v1/auth/audit-log';

  /// Server-side streaming CSV export route (Theme B#5 N3). Same
  /// filter shape as [list]; gated on `team.audit_log.export`. The
  /// proxy streams RFC 4180 chunks back as a `text/csv` attachment so
  /// the operator-web build no longer pages a hundred-thousand-row
  /// ledger into memory. Aligns the time filter (and other filters)
  /// end-to-end (frontend filter -> proxy query string -> repository
  /// WHERE -> CSV bytes).
  static const String exportCsv = '/v1/auth/audit-log/export.csv';
}

/// Encodes [offset] as the opaque cursor strings the screen treats as
/// black boxes. Exposed for tests; the screen never decodes them.
String encodeAuditLogCursor(int offset) => 'offset:$offset';

/// Decodes the offset back out of [cursor]. Returns 0 when [cursor]
/// is null or malformed so a fresh first page request stays safe.
int decodeAuditLogCursor(String? cursor) {
  if (cursor == null) return 0;
  if (!cursor.startsWith('offset:')) return 0;
  final rest = cursor.substring('offset:'.length);
  return int.tryParse(rest) ?? 0;
}

/// Live `package:http` implementation. Reads the Firebase ID token
/// from the supplied provider on every call so refreshed tokens land
/// on the next request.
class WebTeamAuditLogGatewayLive implements WebTeamAuditLogGateway {
  WebTeamAuditLogGatewayLive({
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

  @override
  Future<WebAuditLogPage> listEntries(WebAuditLogQuery query) async {
    final response = await _send(
      method: 'GET',
      path: WebTeamAuditLogPaths.list,
      queryParameters: _queryParamsFor(query),
    );
    if (response.statusCode != 200) {
      throw _statusError(response);
    }
    final raw = response.body['entries'];
    if (raw is! List) {
      throw const WebTeamAuditLogError(
        code: 'malformed_response',
        message: 'audit log response was missing the entries list',
      );
    }
    final entries = raw
        .map((entry) => _entryFromJson(entry))
        .toList(growable: false);
    final hasMore = response.body['has_more'] == true;
    final pageOffset = decodeAuditLogCursor(query.cursor);
    final nextOffset = pageOffset + entries.length;
    return WebAuditLogPage(
      entries: List<WebAuditLogEntry>.unmodifiable(entries),
      nextCursor: hasMore ? encodeAuditLogCursor(nextOffset) : null,
    );
  }

  @override
  Future<WebAuditLogCsvExport> exportCsv(
    WebAuditLogQuery query, {
    required String idempotencyKey,
  }) async {
    // Theme B#5 N3 - the operator-web build now hits the proxy's
    // streaming server-side CSV exporter (gated on
    // `team.audit_log.export`) and surfaces the streamed bytes
    // verbatim. The proxy applies the same filter shape as the read
    // route + paginates the underlying repo so memory stays bounded
    // regardless of row count. The screen surfaces the response as a
    // download / clipboard fallback.
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamAuditLogError(
        code: 'no_id_token',
        message:
            'audit log gateway has no live Firebase ID token to attach to '
            'the request.',
      );
    }
    final url = proxyBaseUri.resolve(WebTeamAuditLogPaths.exportCsv).replace(
          queryParameters: _queryParamsFor(
            query.copyWith(cursor: null, limit: 200),
          ),
        );
    final request = http.Request('GET', url);
    request.headers.addAll(<String, String>{
      'accept': 'text/csv',
      'authorization': 'Bearer ${token.trim()}',
      'Idempotency-Key': idempotencyKey,
    });
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebTeamAuditLogError(
        code: 'transport_timeout',
        message:
            'audit log gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebTeamAuditLogError(
        code: 'transport_error',
        message:
            'audit log gateway request failed before reaching the proxy '
            '($error).',
      );
    }
    if (streamed.statusCode != 200) {
      // Non-2xx: the proxy emits a JSON error body for these (the
      // streaming bytes path only fires once the headers + 200 are
      // committed). Drain + decode so the operator gets a friendly
      // error.
      final raw = await streamed.stream.bytesToString().timeout(_timeout);
      Map<String, Object?> body = const <String, Object?>{};
      if (raw.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<Object?, Object?>) {
            body = Map<String, Object?>.from(decoded);
          }
        } on FormatException {
          // Leave body empty; surface generic error below.
        }
      }
      throw _statusError(
        WebTeamAuditLogResponse(statusCode: streamed.statusCode, body: body),
      );
    }
    final csv = await streamed.stream.bytesToString().timeout(_timeout);
    final filename = _filenameFromHeaders(streamed.headers) ??
        defaultAuditLogCsvFilename(DateTime.now().toUtc());
    return WebAuditLogCsvExport(csv: csv, filename: filename);
  }

  /// Pulls the `attachment; filename="..."` value out of the
  /// `Content-Disposition` header so the screen can surface the same
  /// filename the proxy chose. Returns null when the header is
  /// missing or malformed.
  static String? _filenameFromHeaders(Map<String, String> headers) {
    final disposition = headers['content-disposition'];
    if (disposition == null) return null;
    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(disposition);
    if (match == null) return null;
    final candidate = match.group(1);
    if (candidate == null) return null;
    final trimmed = candidate.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Map<String, String> _queryParamsFor(WebAuditLogQuery query) {
    final params = <String, String>{
      'limit': query.limit.toString(),
      'offset': decodeAuditLogCursor(query.cursor).toString(),
    };
    final from = _resolveFrom(query);
    final to = _resolveTo(query);
    if (from != null) params['from'] = from.toIso8601String();
    if (to != null) params['to'] = to.toIso8601String();
    if (query.actions.length == 1) {
      final bucket = WebAuditLogActionLabels.bucketFor(query.actions.first);
      params['event_kind'] = webAuditLogActionBucketWireKey(bucket);
      params['action'] = query.actions.first;
    } else if (query.actions.isNotEmpty) {
      params['action'] = query.actions.join(',');
    }
    if (query.actorUserIds.isNotEmpty) {
      params['actor_user_id'] = query.actorUserIds.join(',');
    }
    if (query.targetKind != null && query.targetKind!.trim().isNotEmpty) {
      params['target_kind'] = query.targetKind!.trim();
    }
    if (query.targetId != null && query.targetId!.trim().isNotEmpty) {
      params['target_id'] = query.targetId!.trim();
    }
    if (query.actorKinds.length == 1) {
      params['actor_kind'] = webAuditLogActorKindWire(query.actorKinds.first);
    }
    return params;
  }

  WebAuditLogEntry _entryFromJson(Object? raw) {
    if (raw is! Map) {
      throw const WebTeamAuditLogError(
        code: 'malformed_response',
        message: 'audit log entry payload was malformed',
      );
    }
    final json = Map<String, Object?>.from(raw);
    final entryId = _readNonBlankString(json['entry_id']) ??
        _readNonBlankString(json['event_id']) ??
        _readNonBlankString(json['id']);
    final action = _readNonBlankString(json['action']) ??
        _readNonBlankString(json['event_type']);
    final createdAtRaw = _readNonBlankString(json['created_at']) ??
        _readNonBlankString(json['occurred_at']);
    if (entryId == null || action == null || createdAtRaw == null) {
      throw const WebTeamAuditLogError(
        code: 'malformed_response',
        message: 'audit log entry payload was incomplete',
      );
    }
    final actorKindRaw = _readNonBlankString(json['actor_kind']);
    final actorKind =
        webAuditLogActorKindFromWire(actorKindRaw) ?? WebAuditLogActorKind.teamMember;
    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map
        ? Map<String, Object?>.from(payloadRaw)
        : const <String, Object?>{};
    return WebAuditLogEntry(
      entryId: entryId,
      action: action,
      actorKind: actorKind,
      createdAt: DateTime.parse(createdAtRaw).toUtc(),
      actorUserId: _readNonBlankString(json['actor_user_id']),
      actorDisplayName: _readNonBlankString(json['actor_display_name']) ??
          _readNonBlankString(json['display_name']),
      actorEmail: _readNonBlankString(json['actor_email']) ??
          _readNonBlankString(json['email']),
      targetKind: _readNonBlankString(json['target_kind']),
      targetId: _readNonBlankString(json['target_id']),
      payload: payload,
      adminReason: _readNonBlankString(json['admin_reason']),
    );
  }

  Future<WebTeamAuditLogResponse> _send({
    required String method,
    required String path,
    Map<String, String>? queryParameters,
    String? idempotencyKey,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const WebTeamAuditLogError(
        code: 'no_id_token',
        message:
            'audit log gateway has no live Firebase ID token to attach to '
            'the request.',
      );
    }
    final headers = <String, String>{
      'accept': 'application/json',
      'authorization': 'Bearer ${token.trim()}',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final url = proxyBaseUri.resolve(path).replace(
          queryParameters: queryParameters,
        );
    final request = http.Request(method, url);
    request.headers.addAll(headers);
    final http.StreamedResponse streamed;
    try {
      streamed = await _httpClient.send(request).timeout(_timeout);
    } on TimeoutException {
      throw const WebTeamAuditLogError(
        code: 'transport_timeout',
        message:
            'audit log gateway request timed out before reaching the proxy.',
      );
    } catch (error) {
      throw WebTeamAuditLogError(
        code: 'transport_error',
        message:
            'audit log gateway request failed before reaching the proxy '
            '($error).',
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
    final responseBody = decoded is Map<Object?, Object?>
        ? Map<String, Object?>.from(decoded)
        : const <String, Object?>{};
    return WebTeamAuditLogResponse(
      statusCode: streamed.statusCode,
      body: responseBody,
    );
  }

  WebTeamAuditLogError _statusError(WebTeamAuditLogResponse response) {
    final code =
        _readNonBlankString(response.body['error']) ?? 'audit_log_failed';
    return WebTeamAuditLogError(
      code: code,
      message: _readNonBlankString(response.body['message']) ??
          'proxy returned status ${response.statusCode}',
      statusCode: response.statusCode,
    );
  }

  static String? _readNonBlankString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _resolveFrom(WebAuditLogQuery query) {
    switch (query.timeWindow) {
      case WebAuditLogTimeWindow.last24h:
        return DateTime.now().toUtc().subtract(const Duration(hours: 24));
      case WebAuditLogTimeWindow.last7d:
        return DateTime.now().toUtc().subtract(const Duration(days: 7));
      case WebAuditLogTimeWindow.last30d:
        return DateTime.now().toUtc().subtract(const Duration(days: 30));
      case WebAuditLogTimeWindow.last90d:
        return DateTime.now().toUtc().subtract(const Duration(days: 90));
      case WebAuditLogTimeWindow.custom:
        return query.customFrom?.toUtc();
    }
  }

  static DateTime? _resolveTo(WebAuditLogQuery query) {
    switch (query.timeWindow) {
      case WebAuditLogTimeWindow.last24h:
      case WebAuditLogTimeWindow.last7d:
      case WebAuditLogTimeWindow.last30d:
      case WebAuditLogTimeWindow.last90d:
        return null;
      case WebAuditLogTimeWindow.custom:
        return query.customTo?.toUtc();
    }
  }
}

/// Renders [entries] as RFC 4180 CSV with the locked column order
/// shared between the live + demo gateway.
String renderAuditLogCsv(List<WebAuditLogEntry> entries) {
  final buffer = StringBuffer();
  buffer.writeln(
    'created_at,action,actor_user_id,actor_display_name,actor_email,'
    'actor_kind,target_kind,target_id,admin_reason,payload',
  );
  for (final entry in entries) {
    buffer.writeln(
      <String>[
        _csv(entry.createdAt.toUtc().toIso8601String()),
        _csv(entry.action),
        _csv(entry.actorUserId ?? ''),
        _csv(entry.actorDisplayName ?? ''),
        _csv(entry.actorEmail ?? ''),
        _csv(webAuditLogActorKindWire(entry.actorKind)),
        _csv(entry.targetKind ?? ''),
        _csv(entry.targetId ?? ''),
        _csv(entry.adminReason ?? ''),
        _csv(entry.payload.isEmpty ? '' : jsonEncode(entry.payload)),
      ].join(','),
    );
  }
  return buffer.toString();
}

String _csv(String raw) {
  if (raw.isEmpty) return '';
  if (raw.contains(',') || raw.contains('"') || raw.contains('\n')) {
    final escaped = raw.replaceAll('"', '""');
    return '"$escaped"';
  }
  return raw;
}

/// Default filename the screen uses when the browser triggers the
/// download. UTC timestamp keeps two exports in the same minute apart.
String defaultAuditLogCsvFilename(DateTime now) {
  final utc = now.toUtc();
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  final hh = utc.hour.toString().padLeft(2, '0');
  final mm = utc.minute.toString().padLeft(2, '0');
  return 'forge_flow_audit_log_$y$m${d}_$hh${mm}_utc.csv';
}
