// Lane B B2.1 + B2.3 — Default Role catalog admin gateway.
//
// Thin HTTP client over the three admin routes:
//   GET  /v1/admin/auth/role-catalogs                {super_admin, ff_support}
//   POST /v1/admin/auth/role-catalogs/publish        super_admin only
//   GET  /v1/admin/auth/role-catalogs/blast-radius   {super_admin, ff_support}
//
// The admin Flutter client never holds a Postgres connection string
// and never reaches the database directly — every read/write flows
// through the F&F admin proxy. NO `package:postgres` import here per
// CLAUDE.md "Service-Layer Split".
//
// Payload shapes mirror the proxy contract documented in
// `tool/advisor_proxy/admin_default_role_catalog_routes.dart`.
//
// B2.2 (separate slice) ships the admin editor screen that consumes
// this gateway. B2.3 adds the blast-radius read endpoint so the
// publish dialog can render "Affecting N businesses, N locations,
// N users" copy instead of the plain-English fallback.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/permission_keys.dart';
import 'admin_http_timeout.dart';

/// Built-in v2 starter role catalog shown by the admin editor before
/// any Default Role Catalog version has been published. This includes
/// the F&F-internal roles plus the operator-facing seeded roles from
/// `db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql`.
List<Object?> defaultRoleCatalogStarterPayload() => <Object?>[
  _starterRole(
    roleKey: PermissionKeys.roleSuperAdmin,
    displayName: 'Ecosystem admin',
    description: 'Full Forge & Flow platform administration access.',
    permissionKeys: _starterEcosystemAdminPermissions,
  ),
  _starterRole(
    roleKey: PermissionKeys.roleFfSupport,
    displayName: 'Support access',
    description: 'Read-only Forge & Flow support access.',
    permissionKeys: _starterSupportAccessPermissions,
  ),
  _starterRole(
    roleKey: 'operator_owner',
    displayName: 'Owner',
    description:
        'Owns the business. Full operational access plus billing, '
        'integrations, and team admin.',
    permissionKeys: _starterAllPermissions,
  ),
  _starterRole(
    roleKey: 'operator_general_manager',
    displayName: 'General Manager',
    description:
        'Runs all locations and staff. Operational edit access plus '
        'staff admin and audit view; no billing or subscription '
        'mutations.',
    permissionKeys: _starterOperationsPermissions,
  ),
  _starterRole(
    roleKey: 'location_manager',
    displayName: 'Location Manager',
    description:
        'Runs one location. Invites and removes staff, edits schedules, '
        'sees variance and benchmarks at that location.',
    permissionKeys: _starterLocationManagerPermissions,
  ),
  _starterRole(
    roleKey: 'supervisor',
    displayName: 'Supervisor',
    description:
        'Supervises shifts at one location. Edits short-term schedule, '
        'marks shift covers, sees variance for shifts they ran.',
    permissionKeys: _starterSupervisorPermissions,
  ),
  _starterRole(
    roleKey: 'finance_analyst',
    displayName: 'Finance Analyst',
    description:
        'Reviews invoices and usage, adjusts usage caps. Cannot change '
        'the subscription plan or connect billing integrations.',
    permissionKeys: _starterFinanceAnalystPermissions,
  ),
  _starterRole(
    roleKey: 'auditor_compliance',
    displayName: 'Auditor / Compliance',
    description:
        'Read-only audit trail and PII oversight. Sees who did what '
        'and when, exports the audit log, cannot mutate data.',
    permissionKeys: _starterAuditorCompliancePermissions,
  ),
  _starterRole(
    roleKey: 'training_lead',
    displayName: 'Training Lead',
    description:
        'Manages employee training and onboarding content. Edits '
        'supervisor content and the interview playbook; does not edit '
        'the F&F handbook source.',
    permissionKeys: _starterTrainingLeadPermissions,
  ),
  _starterRole(
    roleKey: 'team_admin',
    displayName: 'Team Admin',
    description:
        'Manages the team roster, role assignments, MFA, and password '
        'resets. Does not see operational dashboards.',
    permissionKeys: _starterTeamAdminPermissions,
  ),
];

Map<String, Object?> _starterRole({
  required String roleKey,
  required String displayName,
  required String description,
  required List<String> permissionKeys,
}) {
  return <String, Object?>{
    'role_key': roleKey,
    'display_name': displayName,
    'description': description,
    'permissions': <Object?>[
      for (final key in permissionKeys)
        <String, Object?>{'permission_key': key, 'effect': 'allow'},
    ],
  };
}

const List<String> _starterEcosystemAdminPermissions = <String>[
  PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesEditSeeded,
  PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesDefaultCatalogView,
  PermissionKeys.teamRolesDefaultCatalogEdit,
  PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditLogView,
];

const List<String> _starterSupportAccessPermissions = <String>[
  PermissionKeys.adminRolesView,
  PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesDefaultCatalogView,
  PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditLogView,
];

const List<String> _starterAllPermissions = <String>[
  ..._starterOperationsPermissions,
  'barrio.handbook.edit',
  'team.roles.create_custom',
  'team.hierarchy.suspend',
  'team.hierarchy.delete',
  'team.audit_log.export',
  'billing.invoice.view',
  'billing.usage.view',
  'billing.usage_caps.edit',
  'billing.subscription.manage',
  'billing.payment_method.manage',
  'account.configure',
  'business_timing.configure',
  'admin.users.reset_mfa_factors',
  'admin.audit_log.export',
  'admin.audit_privacy.read',
];

const List<String> _starterOperationsPermissions = <String>[
  'product.forgeflow.access',
  'product.barrio.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.variance.edit',
  'forgeflow.schedule.view',
  'forgeflow.schedule.edit',
  'forgeflow.baseline.view',
  'forgeflow.baseline.override',
  'forgeflow.history.view',
  'forgeflow.benchmark.view',
  'forgeflow.benchmark.edit',
  'forgeflow.target_profile.view',
  'forgeflow.target_profile.manage',
  'forgeflow.target_cycle.view',
  'forgeflow.target_cycle.unlock',
  'forgeflow.target_cycle.replace',
  'forgeflow.weekly_plan.view',
  'forgeflow.weekly_plan.lock',
  'forgeflow.settings.view',
  'forgeflow.settings.manage',
  'barrio.handbook.view',
  'barrio.interview_playbook.view',
  'barrio.jim_taylor.view',
  'barrio.preston_lee.view',
  'barrio.supervisor_content.view',
  'barrio.supervisor_content.edit',
  'barrio.el_podio.view',
  'barrio.streak.view',
  'team.users.view',
  'team.users.invite',
  'team.users.deactivate',
  'team.users.reactivate',
  'team.users.reset_password',
  'team.users.reset_mfa',
  'team.users.self_update',
  'team.roles.view',
  'team.roles.assign',
  'team.roles.revoke',
  'team.audit_log.view',
  'admin.users.view',
  'admin.audit_log.view',
  'workflow.catalog.view',
  'workflow.run',
  'workflow.history.view',
];

const List<String> _starterLocationManagerPermissions = <String>[
  'product.forgeflow.access',
  'product.barrio.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.schedule.view',
  'forgeflow.schedule.edit',
  'forgeflow.baseline.view',
  'forgeflow.history.view',
  'forgeflow.benchmark.view',
  'forgeflow.target_profile.view',
  'forgeflow.target_cycle.view',
  'forgeflow.weekly_plan.view',
  'forgeflow.settings.view',
  'barrio.handbook.view',
  'barrio.interview_playbook.view',
  'barrio.jim_taylor.view',
  'barrio.preston_lee.view',
  'barrio.supervisor_content.view',
  'barrio.el_podio.view',
  'barrio.streak.view',
  'team.users.view',
  'team.users.invite',
  'team.users.deactivate',
  'team.users.self_update',
  'team.roles.view',
  'team.roles.assign',
  'workflow.catalog.view',
];

const List<String> _starterSupervisorPermissions = <String>[
  'product.forgeflow.access',
  'product.barrio.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.schedule.view',
  'forgeflow.history.view',
  'forgeflow.weekly_plan.view',
  'barrio.handbook.view',
  'barrio.interview_playbook.view',
  'barrio.jim_taylor.view',
  'barrio.preston_lee.view',
  'barrio.supervisor_content.view',
  'barrio.el_podio.view',
  'barrio.learning.complete_unit',
  'barrio.streak.view',
  'team.users.self_update',
];

const List<String> _starterFinanceAnalystPermissions = <String>[
  'billing.invoice.view',
  'billing.usage.view',
  'billing.usage_caps.edit',
  'admin.audit_log.view',
  'team.users.self_update',
];

const List<String> _starterAuditorCompliancePermissions = <String>[
  'admin.audit_log.view',
  'admin.audit_log.export',
  'admin.users.view',
  'admin.audit_privacy.read',
  'team.audit_log.view',
  'team.audit_log.export',
  'team.users.self_update',
];

const List<String> _starterTrainingLeadPermissions = <String>[
  'product.barrio.access',
  'barrio.handbook.view',
  'barrio.interview_playbook.view',
  'barrio.interview_playbook.edit',
  'barrio.jim_taylor.view',
  'barrio.preston_lee.view',
  'barrio.supervisor_content.view',
  'barrio.supervisor_content.edit',
  'barrio.el_podio.view',
  'barrio.streak.view',
  'team.users.self_update',
];

const List<String> _starterTeamAdminPermissions = <String>[
  'team.users.view',
  'team.users.invite',
  'team.users.deactivate',
  'team.users.reactivate',
  'team.users.reset_password',
  'team.users.reset_mfa',
  'team.users.self_update',
  'team.roles.view',
  'team.roles.assign',
  'team.roles.revoke',
  'team.audit_log.view',
  'team.session.force_logout',
  'admin.users.view',
];

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef DefaultRoleCatalogAdminBearerTokenProvider = Future<String> Function();

/// Source for the next idempotency key. Production wires this to the
/// admin idempotency-key minter; tests pin a deterministic value.
typedef DefaultRoleCatalogIdempotencyKeyProvider = String Function();

/// Top-level error type for gateway calls. Carries an HTTP-style
/// status code + machine-readable error code so the screen can branch
/// on `permission_denied` / `validation_failed` / `idempotency_request_in_flight`
/// without parsing `message`.
class DefaultRoleCatalogAdminGatewayError implements Exception {
  const DefaultRoleCatalogAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'DefaultRoleCatalogAdminGatewayError($statusCode/$errorCode): $message';
}

/// One catalog version row as returned by the proxy. Mirrors the
/// `DefaultRoleCatalogVersionRow.toJson` shape from the repository.
class DefaultRoleCatalogVersionView {
  const DefaultRoleCatalogVersionView({
    required this.versionId,
    required this.versionNumber,
    required this.publishedAt,
    required this.publishedByUserId,
    required this.payload,
    required this.payloadSha256,
    required this.isCurrent,
    required this.supersededAt,
    required this.notes,
  });

  final String versionId;
  final int versionNumber;
  final DateTime publishedAt;
  final String publishedByUserId;
  final List<Object?> payload;
  final String payloadSha256;
  final bool isCurrent;
  final DateTime? supersededAt;
  final String? notes;

  factory DefaultRoleCatalogVersionView.fromJson(Map<String, Object?> json) {
    final supersededRaw = json['superseded_at'];
    return DefaultRoleCatalogVersionView(
      versionId: json['version_id'] as String,
      versionNumber: (json['version_number'] as num).toInt(),
      publishedAt: DateTime.parse(json['published_at'] as String).toUtc(),
      publishedByUserId: json['published_by_user_id'] as String,
      payload: (json['payload'] as List?) ?? const <Object?>[],
      payloadSha256: json['payload_sha256'] as String,
      isCurrent: (json['is_current'] as bool?) ?? false,
      supersededAt: supersededRaw is String
          ? DateTime.parse(supersededRaw).toUtc()
          : null,
      notes: json['notes'] as String?,
    );
  }
}

/// Carry-shape for the GET response: current row (when one exists) +
/// history list ordered by `version_number desc`.
class DefaultRoleCatalogListing {
  const DefaultRoleCatalogListing({
    required this.current,
    required this.history,
  });

  final DefaultRoleCatalogVersionView? current;
  final List<DefaultRoleCatalogVersionView> history;
}

/// B2.3 — blast-radius counts for a given catalog version. Returned
/// from `GET /v1/admin/auth/role-catalogs/blast-radius`. Mirrors the
/// repository's `DefaultRoleCatalogBlastRadiusCounts` shape with one
/// extra `versionNumber` field the proxy joins in for display.
class DefaultRoleCatalogBlastRadius {
  const DefaultRoleCatalogBlastRadius({
    required this.versionId,
    required this.versionNumber,
    required this.operatorCount,
    required this.locationCount,
    required this.userCount,
  });

  final String versionId;
  final int versionNumber;
  final int operatorCount;
  final int locationCount;
  final int userCount;

  /// True when no operators are pinned to this version. The publish
  /// dialog uses this to decide between the numeric copy ("Affecting
  /// N businesses...") and the plain-English fallback ("This is the
  /// first published catalog...").
  bool get isZeroState =>
      operatorCount == 0 && locationCount == 0 && userCount == 0;

  factory DefaultRoleCatalogBlastRadius.fromJson(Map<String, Object?> json) {
    return DefaultRoleCatalogBlastRadius(
      versionId: json['version_id'] as String,
      versionNumber: (json['version_number'] as num?)?.toInt() ?? 0,
      operatorCount: (json['operator_count'] as num?)?.toInt() ?? 0,
      locationCount: (json['location_count'] as num?)?.toInt() ?? 0,
      userCount: (json['user_count'] as num?)?.toInt() ?? 0,
    );
  }
}

abstract class DefaultRoleCatalogAdminGateway {
  /// GET the current catalog version + history. Admits ff_support +
  /// super_admin.
  Future<DefaultRoleCatalogListing> listCatalogs({int historyLimit = 20});

  /// Publish a new catalog version. super_admin only. The proxy
  /// requires an `Idempotency-Key` header — provided here from
  /// [idempotencyKeyProvider].
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  });

  /// B2.3 — GET the blast-radius counts (operator + location + user)
  /// for [versionId]. Admits ff_support + super_admin (read-only).
  ///
  /// Throws [DefaultRoleCatalogAdminGatewayError] with `statusCode: 404`
  /// when [versionId] does not exist, `statusCode: 400` when the param
  /// is malformed, or other status codes for proxy errors. The publish
  /// dialog catches the error and falls back to plain-English copy so
  /// a transient backend hiccup never blocks the operator from
  /// publishing.
  Future<DefaultRoleCatalogBlastRadius> getBlastRadius({
    required String versionId,
  });
}

class HttpDefaultRoleCatalogAdminGateway
    implements DefaultRoleCatalogAdminGateway {
  HttpDefaultRoleCatalogAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    required this.idempotencyKeyProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/auth/role-catalogs[/publish]` against
  /// this.
  final Uri baseUri;
  final DefaultRoleCatalogAdminBearerTokenProvider bearerTokenProvider;
  final DefaultRoleCatalogIdempotencyKeyProvider idempotencyKeyProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String listPath = '/v1/admin/auth/role-catalogs';
  static const String publishPath = '/v1/admin/auth/role-catalogs/publish';
  static const String blastRadiusPath =
      '/v1/admin/auth/role-catalogs/blast-radius';

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({
    int historyLimit = 20,
  }) async {
    final body = await _send(
      method: 'GET',
      path: '$listPath?limit=$historyLimit',
    );
    final currentJson = body['current'];
    final historyJson = (body['history'] as List?) ?? const <Object?>[];
    return DefaultRoleCatalogListing(
      current: currentJson is Map
          ? DefaultRoleCatalogVersionView.fromJson(
              currentJson.cast<String, Object?>(),
            )
          : null,
      history: <DefaultRoleCatalogVersionView>[
        for (final entry in historyJson)
          if (entry is Map)
            DefaultRoleCatalogVersionView.fromJson(
              entry.cast<String, Object?>(),
            ),
      ],
    );
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) async {
    final body = await _send(
      method: 'POST',
      path: publishPath,
      idempotencyKey: idempotencyKeyProvider(),
      jsonBody: <String, Object?>{
        'payload': payload,
        if (notes != null && notes.isNotEmpty) 'notes': notes,
      },
    );
    return DefaultRoleCatalogVersionView.fromJson(body);
  }

  @override
  Future<DefaultRoleCatalogBlastRadius> getBlastRadius({
    required String versionId,
  }) async {
    final encoded = Uri.encodeQueryComponent(versionId);
    final body = await _send(
      method: 'GET',
      path: '$blastRadiusPath?version_id=$encoded',
    );
    return DefaultRoleCatalogBlastRadius.fromJson(body);
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw DefaultRoleCatalogAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin default role catalog proxy timed out after '
            '${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw DefaultRoleCatalogAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin default role catalog proxy returned an error',
    );
  }
}

/// In-memory gateway used by demo + widget tests. Persists nothing
/// across runs. Mirrors the proxy contract:
///   * publish appends a row and flips `is_current`.
///   * list returns the current row + history ordered desc.
///   * blast-radius returns deterministic counts seeded by
///     [blastRadiusByVersionId] (defaults to zero counts so the dialog
///     renders its plain-English fallback).
class InMemoryDefaultRoleCatalogAdminGateway
    implements DefaultRoleCatalogAdminGateway {
  InMemoryDefaultRoleCatalogAdminGateway({
    DateTime Function()? now,
    String Function()? versionIdGenerator,
    String? publishedByUserId,
    Map<String, DefaultRoleCatalogBlastRadius>? blastRadiusByVersionId,
  }) : _now = now ?? DateTime.now,
       _versionIdGenerator = versionIdGenerator ?? _defaultVersionIdGenerator,
       _publishedByUserId = publishedByUserId ?? 'demo-admin-user',
       _blastRadiusByVersionId =
           blastRadiusByVersionId ??
           const <String, DefaultRoleCatalogBlastRadius>{};

  final DateTime Function() _now;
  final String Function() _versionIdGenerator;
  final String _publishedByUserId;
  final Map<String, DefaultRoleCatalogBlastRadius> _blastRadiusByVersionId;
  final List<DefaultRoleCatalogVersionView> _versions =
      <DefaultRoleCatalogVersionView>[];

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({
    int historyLimit = 20,
  }) async {
    final sorted = List<DefaultRoleCatalogVersionView>.from(_versions)
      ..sort((a, b) => b.versionNumber.compareTo(a.versionNumber));
    final history = sorted.take(historyLimit).toList(growable: false);
    final current = sorted
        .where((v) => v.isCurrent)
        .cast<DefaultRoleCatalogVersionView?>()
        .firstWhere((v) => v != null, orElse: () => null);
    return DefaultRoleCatalogListing(current: current, history: history);
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) async {
    final nextVersion = _versions.isEmpty
        ? 1
        : _versions
                  .map((v) => v.versionNumber)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    // Mark prior current as superseded.
    final supersededAt = _now().toUtc();
    for (var i = 0; i < _versions.length; i++) {
      if (_versions[i].isCurrent) {
        _versions[i] = DefaultRoleCatalogVersionView(
          versionId: _versions[i].versionId,
          versionNumber: _versions[i].versionNumber,
          publishedAt: _versions[i].publishedAt,
          publishedByUserId: _versions[i].publishedByUserId,
          payload: _versions[i].payload,
          payloadSha256: _versions[i].payloadSha256,
          isCurrent: false,
          supersededAt: supersededAt,
          notes: _versions[i].notes,
        );
      }
    }
    final fresh = DefaultRoleCatalogVersionView(
      versionId: _versionIdGenerator(),
      versionNumber: nextVersion,
      publishedAt: _now().toUtc(),
      publishedByUserId: _publishedByUserId,
      payload: List<Object?>.unmodifiable(payload),
      // In-memory only — production SHA-256 happens server-side. We
      // surface a deterministic placeholder so the screen can render.
      payloadSha256: 'a' * 64,
      isCurrent: true,
      supersededAt: null,
      notes: notes,
    );
    _versions.add(fresh);
    return fresh;
  }

  @override
  Future<DefaultRoleCatalogBlastRadius> getBlastRadius({
    required String versionId,
  }) async {
    // Seeded counts win; otherwise return a deterministic zero state
    // so the publish dialog renders its plain-English fallback in
    // demo mode (no operators yet → genuinely zero blast radius).
    final seeded = _blastRadiusByVersionId[versionId];
    if (seeded != null) return seeded;
    // 404 parity with the proxy when the version is unknown — keeps
    // the dialog's error-fallback path consistent in widget tests.
    final exists = _versions.any((v) => v.versionId == versionId);
    if (!exists) {
      throw DefaultRoleCatalogAdminGatewayError(
        statusCode: 404,
        errorCode: 'version_not_found',
        message: 'no catalog version exists for version_id=$versionId',
      );
    }
    final version = _versions.firstWhere((v) => v.versionId == versionId);
    return DefaultRoleCatalogBlastRadius(
      versionId: versionId,
      versionNumber: version.versionNumber,
      operatorCount: 0,
      locationCount: 0,
      userCount: 0,
    );
  }
}

String _defaultVersionIdGenerator() =>
    'mem-${DateTime.now().microsecondsSinceEpoch}';
