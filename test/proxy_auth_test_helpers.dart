// Shared test helpers for the proxy_auth_*_test.dart split.
//
// Bucket 5d of the 2026-05-20 test-suite tightening audit: extracted out of
// `test/proxy_auth_operations_route_test.dart` (3,599 lines) when the
// original monolith was split into four focused files:
//   - proxy_auth_account_and_permission_test.dart
//   - proxy_auth_password_and_session_test.dart
//   - proxy_auth_mfa_test.dart
//   - proxy_auth_invite_and_admin_test.dart
//
// These helpers (route harness, HTTP response wrappers, JWT verifier
// double, snapshot resolver double, recording-gateway fakes for
// account info, admin permission guard, password change/reset, MFA,
// MFA recovery, and the broad AuthOperations gateway) were
// file-private in the original monolith. They are promoted to
// library-public (leading `_` dropped) so the four split files can
// share them without code duplication. Behaviour is byte-identical
// to the pre-split source.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/mfa/mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

const proxyAuthUserId = '11111111-1111-4111-8111-111111111111';
const proxyAuthFirebaseUid = 'firebase-auth-uid';
const proxyAuthOperatorId = '22222222-2222-4222-8222-222222222222';
const proxyAuthLocationId = '33333333-3333-4333-8333-333333333333';
const proxyAuthRoleId = '44444444-4444-4444-8444-444444444444';

Future<T> withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

class RouteHarness {
  RouteHarness._({
    required this.server,
    required this.client,
    required this.baseUri,
  });

  final HttpServer server;
  final HttpClient client;
  final Uri baseUri;

  static Future<RouteHarness> start({
    AccountInfoGateway? accountInfoGateway,
    ProxyPermissionSnapshotResolver? permissionSnapshotResolver,
    AuthOperationsGateway? authOperationsGateway,
    ProxyAdminPermissionGuard? adminPermissionGuard,
    PasswordChangeGateway? passwordChangeGateway,
    PasswordResetConfirmGateway? passwordResetConfirmGateway,
    PasswordResetRequestGateway? passwordResetRequestGateway,
    MfaOperationsGateway? mfaOperationsGateway,
    MfaRecoveryRequestGateway? mfaRecoveryRequestGateway,
    ProxyJwtVerifier? verifier,
    ProxyAuthIdempotencyCache? authIdempotencyCache,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: verifier ?? StaticVerifier());
    // Per-test cache so the global default doesn't carry replays
    // across test cases.
    final perTestCache = authIdempotencyCache ?? ProxyAuthIdempotencyCache();
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        accountInfoGateway: accountInfoGateway,
        permissionSnapshotResolver: permissionSnapshotResolver,
        authOperationsGateway: authOperationsGateway,
        adminPermissionGuard: adminPermissionGuard,
        passwordChangeGateway: passwordChangeGateway,
        passwordResetConfirmGateway: passwordResetConfirmGateway,
        passwordResetRequestGateway: passwordResetRequestGateway,
        mfaOperationsGateway: mfaOperationsGateway,
        mfaRecoveryRequestGateway: mfaRecoveryRequestGateway,
        authIdempotencyCache: perTestCache,
        now: () => DateTime.utc(2026, 4, 28, 12),
      );
    });
    return RouteHarness._(
      server: server,
      client: HttpClient(),
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
    );
  }

  Future<HttpJsonResponse> get(String path, {bool authorize = true}) async {
    final request = await client.getUrl(baseUri.resolve(path));
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    final response = await request.close();
    return HttpJsonResponse.from(response);
  }

  /// Streaming-friendly variant of [get] that surfaces the raw body
  /// + headers (rather than forcing a JSON decode). Used by the CSV
  /// export tests so they can assert on the streamed bytes + the
  /// `text/csv` + `Content-Disposition` headers.
  Future<HttpRawResponse> getRaw(String path, {bool authorize = true}) async {
    final request = await client.getUrl(baseUri.resolve(path));
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    final response = await request.close();
    return HttpRawResponse.from(response);
  }

  Future<HttpJsonResponse> postJson(
    String path,
    Map<String, Object?> body, {
    bool authorize = true,
    String? idempotencyKey,
  }) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    if (authorize) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    }
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return HttpJsonResponse.from(response);
  }

  Future<HttpJsonResponse> patchJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final request = await client.patchUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return HttpJsonResponse.from(response);
  }

  Future<HttpJsonResponse> deleteJson(
    String path,
    Map<String, Object?> body, {
    String? idempotencyKey,
  }) async {
    final request = await client.deleteUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return HttpJsonResponse.from(response);
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

class HttpJsonResponse {
  const HttpJsonResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;

  static Future<HttpJsonResponse> from(HttpClientResponse response) async {
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    return HttpJsonResponse(
      statusCode: response.statusCode,
      json: raw.isEmpty
          ? const <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(raw) as Map),
    );
  }
}

class HttpRawResponse {
  const HttpRawResponse({
    required this.statusCode,
    required this.body,
    required this.contentType,
    required this.headers,
  });

  final int statusCode;
  final String body;
  final String? contentType;
  final Map<String, List<String>> headers;

  static Future<HttpRawResponse> from(HttpClientResponse response) async {
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name.toLowerCase()] = List<String>.from(values);
    });
    return HttpRawResponse(
      statusCode: response.statusCode,
      body: raw,
      contentType: response.headers.contentType?.toString(),
      headers: headers,
    );
  }
}

class StaticVerifier implements ProxyJwtVerifier {
  StaticVerifier({
    DateTime? lastFreshAuthAt,
    this.roles = const <String>['roles_version:7'],
  }) : lastFreshAuthAt = lastFreshAuthAt ?? DateTime.utc(2026, 4, 28, 11, 59);

  final DateTime lastFreshAuthAt;
  final List<String> roles;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: proxyAuthUserId,
      firebaseUid: proxyAuthFirebaseUid,
      operatorId: proxyAuthOperatorId,
      locationId: proxyAuthLocationId,
      roles: roles,
      rolesVersion: 7,
      lastFreshAuthAt: lastFreshAuthAt,
    );
  }
}

class FixedSnapshotResolver implements ProxyPermissionSnapshotResolver {
  const FixedSnapshotResolver(this.snapshot);

  final ProxyPermissionSnapshot snapshot;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async => snapshot;
}

class RecordingAccountInfoGateway implements AccountInfoGateway {
  RecordingAccountInfoGateway({
    this.logoUrl,
    this.subscriptionTier,
    this.trialMode = false,
    this.trialExpiresAt,
  });

  /// Wave 2 W-5-mobile-FU-2 — optional brand-mark URL the recording
  /// gateway folds into the `AccountInfo` it returns. Null by default
  /// so existing tests stay byte-identical; the W-5-mobile-FU-2 wire
  /// tests opt in to a non-null value to pin the proxy → mobile
  /// round-trip of `operators.logo_url`.
  final String? logoUrl;

  /// Plans & Limits Phase 5b follow-up — optional plan + trial the
  /// recording gateway folds into the `AccountInfo`. Null/false by
  /// default so existing tests stay byte-identical; the new wire tests
  /// opt in to pin the proxy → operator-web round-trip of the
  /// operator's own `subscription_tier` / `trial_mode` /
  /// `trial_expires_at`.
  final String? subscriptionTier;
  final bool trialMode;
  final DateTime? trialExpiresAt;

  final requests = <AccountInfoRequest>[];

  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    requests.add(request);
    return AccountInfo(
      displayName: 'Jane Operator',
      email: 'jane@example.test',
      statusLabel: 'Active',
      locationLabel: 'Downtown',
      roleLabels: const <String>['Kitchen Lead'],
      mfaEnabled: true,
      lastLoginAt: DateTime.utc(2026, 4, 28, 11),
      lastActiveAt: DateTime.utc(2026, 4, 28, 12),
      passwordUpdatedAt: DateTime.utc(2026, 4, 20, 9),
      logoUrl: logoUrl,
      subscriptionTier: subscriptionTier,
      trialMode: trialMode,
      trialExpiresAt: trialExpiresAt,
    );
  }
}

class RecordingAdminGuard implements ProxyAdminPermissionGuard {
  RecordingAdminGuard({this.decision = const ProxyAdminAllowed()});

  final ProxyAdminGuardDecision decision;
  final permissionKeys = <String>[];

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    permissionKeys.add(context.requestedPermissionKey);
    return decision;
  }
}

class RecordingPasswordChangeGateway implements PasswordChangeGateway {
  RecordingPasswordChangeGateway({
    this.result = const PasswordChangeCompleted(),
  });

  final PasswordChangeCompleted result;
  final commands = <PasswordChangeCommand>[];

  @override
  Future<PasswordChangeCompleted> changePassword(
    PasswordChangeCommand command,
  ) async {
    commands.add(command);
    return result;
  }
}

class RecordingPasswordResetConfirmGateway
    implements PasswordResetConfirmGateway {
  final commands = <PasswordResetConfirmCommand>[];

  @override
  Future<PasswordResetConfirmCompleted> confirmPasswordReset(
    PasswordResetConfirmCommand command,
  ) async {
    commands.add(command);
    return const PasswordResetConfirmCompleted();
  }
}

class RecordingPasswordResetRequestGateway
    implements PasswordResetRequestGateway {
  RecordingPasswordResetRequestGateway({this.throwOnRequest});

  final Object Function()? throwOnRequest;
  final commands = <PasswordResetRequestCommand>[];

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    commands.add(command);
    if (throwOnRequest != null) {
      throw throwOnRequest!();
    }
    return const PasswordResetRequestAccepted();
  }
}

/// Recording gateway that throws [failure] for the first
/// [failuresBeforeSuccess] calls and then succeeds. Used to assert
/// the proxy idempotency cache lets a same-key retry hit a fresh
/// gateway invocation after a 5xx (so transient infrastructure
/// blips can recover without a key rotation).
class RecoveringPasswordResetRequestGateway
    implements PasswordResetRequestGateway {
  RecoveringPasswordResetRequestGateway({
    required this.failuresBeforeSuccess,
    required this.failure,
  });

  final int failuresBeforeSuccess;
  final Object Function() failure;
  final commands = <PasswordResetRequestCommand>[];

  @override
  Future<PasswordResetRequestAccepted> requestReset(
    PasswordResetRequestCommand command,
  ) async {
    commands.add(command);
    if (commands.length <= failuresBeforeSuccess) {
      throw failure();
    }
    return const PasswordResetRequestAccepted();
  }
}

class RecordingMfaOperationsGateway implements MfaOperationsGateway {
  RecordingMfaOperationsGateway({
    this.resetError,
    this.factors = const <MfaFactorSummary>[],
    this.revokeResult = const MfaRevokeFactorCompleted(revoked: false),
    this.cancelResult = const MfaCancelFactorRemovalCompleted(cancelled: true),
  });

  final MfaOperationRejected? resetError;
  final List<MfaFactorSummary> factors;
  final MfaRevokeFactorCompleted revokeResult;
  final MfaCancelFactorRemovalCompleted cancelResult;
  final resetUserFactors = <MfaRevokeUserFactorsCommand>[];
  final begins = <MfaTotpBeginCommand>[];
  final lists = <MfaListFactorsCommand>[];
  final revokes = <MfaRevokeFactorCommand>[];
  final recoveryCodeViews = <MfaMarkRecoveryCodesViewedCommand>[];
  final cancels = <MfaCancelFactorRemovalCommand>[];

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    begins.add(command);
    return const TotpEnrollmentSetup(
      factorId: 'factor-session-1',
      secretBase32: 'JBSWY3DPEHPK3PXP',
      otpAuthUrl: 'otpauth://totp/Forge%20%26%20Flow:owner@example.test',
    );
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    lists.add(command);
    return MfaListFactorsCompleted(factors: factors);
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    revokes.add(command);
    return revokeResult;
  }

  @override
  Future<MfaMarkRecoveryCodesViewedCompleted> markRecoveryCodesViewed(
    MfaMarkRecoveryCodesViewedCommand command,
  ) async {
    recoveryCodeViews.add(command);
    final viewedAt = DateTime.utc(2026, 5, 6, 12, recoveryCodeViews.length - 1);
    return MfaMarkRecoveryCodesViewedCompleted(viewedAt: viewedAt);
  }

  @override
  Future<MfaCancelFactorRemovalCompleted> cancelFactorRemoval(
    MfaCancelFactorRemovalCommand command,
  ) async {
    cancels.add(command);
    return cancelResult;
  }

  @override
  Future<MfaRevokeUserFactorsCompleted> revokeUserFactors(
    MfaRevokeUserFactorsCommand command,
  ) async {
    resetUserFactors.add(command);
    final error = resetError;
    if (error != null) throw error;
    return MfaRevokeUserFactorsCompleted(
      requestedCount: 1,
      requestIds: const <String>['removal-request-1'],
      executeAfter: DateTime.utc(2026, 5, 1, 12),
    );
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    return const MfaTotpConfirmCompleted(factorId: 'factor-db-1');
  }
}

class RecordingMfaRecoveryRequestGateway implements MfaRecoveryRequestGateway {
  final commands = <MfaRecoveryRequestCommand>[];

  @override
  Future<MfaRecoveryRequestAccepted> requestRecovery(
    MfaRecoveryRequestCommand command,
  ) async {
    commands.add(command);
    return const MfaRecoveryRequestAccepted(
      queued: true,
      requestId: 'recovery-request-1',
    );
  }
}

class RecordingAuthOperationsGateway implements AuthOperationsGateway {
  final userLists = <TeamUserListCommand>[];
  final roleLists = <TeamRoleCatalogListCommand>[];
  final roleCreates = <TeamRoleCreateCommand>[];
  final rolePatches = <TeamRolePatchCommand>[];
  final seededRoleEdits = <TeamSeededRolePermissionsEditCommand>[];
  final roleDeletes = <TeamRoleDeleteCommand>[];
  final inviteLists = <TeamInviteListCommand>[];
  final inviteCreates = <TeamInviteCreateCommand>[];
  final profilePatches = <TeamUserProfilePatchCommand>[];
  final selfProfilePatches = <SelfProfilePatchCommand>[];

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) async {
    userLists.add(command);
    return const TeamUsersListed(
      users: <TeamUserListEntry>[
        TeamUserListEntry(
          userId: 'target-user',
          email: 'target@example.test',
          displayName: 'Target User',
          roleId: proxyAuthRoleId,
          roleLabel: 'Kitchen Lead',
          status: 'active',
          mfaEnrolled: true,
          userRoleId: 'grant-1',
          // Phase 9.UX.grant-payload — surface a representative
          // multi-scope grant set so the route serializer's `grants`
          // field is exercised end-to-end.
          grants: <TeamGrantSnapshot>[
            TeamGrantSnapshot(
              userRoleId: 'grant-1',
              roleId: proxyAuthRoleId,
              scopeType: 'operator_wide',
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-2',
              roleId: proxyAuthRoleId,
              scopeType: 'org_unit',
              orgUnitId: 'unit-east',
              sourceOrgUnitId: 'unit-east',
              effectiveLocationIds: <String>['loc-vancouver', 'loc-burnaby'],
            ),
            TeamGrantSnapshot(
              userRoleId: 'grant-3',
              roleId: proxyAuthRoleId,
              scopeType: 'location',
              locationId: 'loc-vancouver',
              effectiveLocationIds: <String>['loc-vancouver'],
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(
    TeamRoleCatalogListCommand command,
  ) async {
    roleLists.add(command);
    return TeamRoleCatalogListed(
      roles: <TeamRoleCatalogEntry>[proxyAuthTeamRole],
    );
  }

  @override
  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  ) async {
    profilePatches.add(command);
    return TeamUserProfilePatched(
      user: TeamUserListEntry(
        userId: command.targetUserId,
        // W-1 — Members edit-user write path. Both `displayName` and
        // `email` are optional on the command; the recording stub
        // surfaces whichever value was supplied, falling back to the
        // existing fixture so the route test assertions keep working.
        email: command.email ?? 'target@example.test',
        displayName: command.displayName ?? 'Target User',
        roleId: proxyAuthRoleId,
        roleLabel: 'Kitchen Lead',
        status: 'active',
        mfaEnrolled: true,
      ),
    );
  }

  @override
  Future<SelfProfilePatched> patchSelfProfile(
    SelfProfilePatchCommand command,
  ) async {
    // Wave 2 W-3 — self-service profile editor. Mirrors patchUserProfile
    // but the target is the caller themselves; the recording stub
    // surfaces whichever values were supplied.
    selfProfilePatches.add(command);
    return SelfProfilePatched(
      userId: command.actorUserId,
      email: command.email ?? 'actor@example.test',
      displayName: command.displayName ?? 'Actor User',
      emailChanged: command.email != null,
      displayNameChanged: command.displayName != null,
    );
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) async {
    roleCreates.add(command);
    return const TeamRoleCreated(role: proxyAuthTeamRole);
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) async {
    rolePatches.add(command);
    return const TeamRolePatched(role: proxyAuthTeamRole, bumpedUsers: 2);
  }

  @override
  Future<TeamRolePatched> editSeededRolePermissions(
    TeamSeededRolePermissionsEditCommand command,
  ) async {
    seededRoleEdits.add(command);
    return const TeamRolePatched(role: proxyAuthTeamRole, bumpedUsers: 2);
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) async {
    roleDeletes.add(command);
    return const TeamRoleDeleted(deleted: true);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) async {
    inviteLists.add(command);
    return TeamInvitesListed(
      invites: <TeamInviteListEntry>[
        TeamInviteListEntry(
          inviteId: 'invite-1',
          email: 'new@example.test',
          roleId: proxyAuthRoleId,
          roleLabel: 'Kitchen Lead',
          scopeType: 'operator_wide',
          expiresAt: DateTime.utc(2026, 5, 5, 12),
          createdAt: DateTime.utc(2026, 4, 29, 12),
        ),
      ],
    );
  }

  @override
  Future<TeamInviteCreated> createInvite(
    TeamInviteCreateCommand command,
  ) async {
    inviteCreates.add(command);
    return TeamInviteCreated(
      inviteId: 'invite-1',
      expiresAt: DateTime.utc(2026, 5, 5, 12),
    );
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(
    TeamInviteRevokeCommand command,
  ) async {
    return const TeamInviteRevoked(revoked: true);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(
    TeamUserStatusCommand command,
  ) async {
    return const TeamUserStatusUpdated(updated: true);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) async {
    return const TeamPasswordResetQueued();
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(
    TeamMfaResetCommand command,
  ) async {
    return const TeamMfaResetQueued(requestedCount: 1);
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) async {
    return const TeamMfaRemovalCancelled(cancelled: true);
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) async {
    return const TeamRoleGrantCreated(userRoleId: 'grant-1');
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) async {
    return const TeamRoleGrantRevoked(revoked: true);
  }

  final orgHierarchyLists = <TeamOrgHierarchyListCommand>[];
  final orgUnitCreates = <TeamOrgUnitCreateCommand>[];
  final orgUnitMoves = <TeamOrgUnitMoveCommand>[];
  final orgUnitRenames = <TeamOrgUnitRenameCommand>[];
  final orgUnitLifecycle = <TeamOrgUnitLifecycleCommand>[];
  final orgUnitDeletes = <TeamOrgUnitLifecycleCommand>[];
  final locationOrgUnitMoves = <TeamLocationOrgUnitMoveCommand>[];
  final locationLifecycle = <TeamLocationLifecycleCommand>[];
  final locationDeletes = <TeamLocationLifecycleCommand>[];

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) async {
    orgHierarchyLists.add(command);
    return const TeamOrgHierarchyListed(
      orgUnits: <TeamOrgUnitEntry>[
        TeamOrgUnitEntry(
          orgUnitId: '66666666-6666-4666-8666-666666666666',
          parentOrgUnitId: null,
          unitType: 'corp',
          path: 'acme',
          label: 'ACME',
        ),
      ],
      locations: <TeamOrgLocationEntry>[
        TeamOrgLocationEntry(
          locationId: '33333333-3333-4333-8333-333333333333',
          parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
          orgUnitPath: 'acme',
          label: 'Downtown',
        ),
      ],
    );
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(
    TeamOrgUnitCreateCommand command,
  ) async {
    orgUnitCreates.add(command);
    return const TeamOrgUnitCreated(
      orgUnitId: '77777777-7777-4777-8777-777777777777',
    );
  }

  @override
  Future<TeamOrgUnitMoved> moveOrgUnit(TeamOrgUnitMoveCommand command) async {
    orgUnitMoves.add(command);
    return TeamOrgUnitMoved(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: command.parentOrgUnitId,
        unitType: 'region',
        path: 'acme.east',
        label: 'East Region',
      ),
    );
  }

  @override
  Future<TeamOrgUnitRenamed> renameOrgUnit(
    TeamOrgUnitRenameCommand command,
  ) async {
    orgUnitRenames.add(command);
    return TeamOrgUnitRenamed(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
        unitType: 'region',
        path: 'acme.east',
        label: command.name,
      ),
    );
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) async {
    locationOrgUnitMoves.add(command);
    return const TeamLocationOrgUnitMoved(moved: true);
  }

  @override
  Future<TeamOrgUnitLifecycleUpdated> suspendOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) async {
    orgUnitLifecycle.add(command);
    return TeamOrgUnitLifecycleUpdated(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
        unitType: 'region',
        path: 'acme.east',
        label: 'East Region',
        suspendedAt: DateTime.utc(2026, 5, 8, 12),
      ),
    );
  }

  @override
  Future<TeamOrgUnitLifecycleUpdated> reactivateOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) async {
    orgUnitLifecycle.add(command);
    return TeamOrgUnitLifecycleUpdated(
      orgUnit: TeamOrgUnitEntry(
        orgUnitId: command.orgUnitId,
        parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
        unitType: 'region',
        path: 'acme.east',
        label: 'East Region',
      ),
    );
  }

  @override
  Future<TeamHierarchyDeleted> deleteOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) async {
    orgUnitDeletes.add(command);
    return const TeamHierarchyDeleted(deleted: true);
  }

  @override
  Future<TeamLocationLifecycleUpdated> suspendLocation(
    TeamLocationLifecycleCommand command,
  ) async {
    locationLifecycle.add(command);
    return TeamLocationLifecycleUpdated(
      location: TeamOrgLocationEntry(
        locationId: command.targetLocationId,
        parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
        orgUnitPath: 'acme',
        label: 'Downtown',
        suspendedAt: DateTime.utc(2026, 5, 8, 12),
      ),
    );
  }

  @override
  Future<TeamLocationLifecycleUpdated> reactivateLocation(
    TeamLocationLifecycleCommand command,
  ) async {
    locationLifecycle.add(command);
    return TeamLocationLifecycleUpdated(
      location: TeamOrgLocationEntry(
        locationId: command.targetLocationId,
        parentOrgUnitId: '66666666-6666-4666-8666-666666666666',
        orgUnitPath: 'acme',
        label: 'Downtown',
      ),
    );
  }

  @override
  Future<TeamHierarchyDeleted> deleteLocation(
    TeamLocationLifecycleCommand command,
  ) async {
    locationDeletes.add(command);
    return const TeamHierarchyDeleted(deleted: true);
  }

  final activeSessionsLists = <AuthActiveSessionsListCommand>[];
  final sessionRevokes = <AuthSessionRevokeCommand>[];
  final allSessionsRevokes = <AuthAllSessionsRevokeCommand>[];

  List<AuthSessionSummary> activeSessions = <AuthSessionSummary>[
    AuthSessionSummary(
      sessionId: '88888888-8888-4888-8888-888888888888',
      deviceLabel: 'Forge & Flow app · iOS',
      userAgent: 'Forge&Flow/1.0',
      ip: '203.0.113.10',
      geoCountry: 'CA',
      createdAt: DateTime.utc(2026, 4, 28, 12),
      lastSeenAt: DateTime.utc(2026, 4, 28, 12),
    ),
  ];

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) async {
    activeSessionsLists.add(command);
    return AuthActiveSessionsListed(
      sessions: List<AuthSessionSummary>.unmodifiable(activeSessions),
    );
  }

  final teamActiveSessionsLists = <AuthTeamActiveSessionsListCommand>[];
  List<AuthTeamActiveSessionSummary> teamActiveSessions =
      <AuthTeamActiveSessionSummary>[];

  @override
  Future<AuthTeamActiveSessionsListed> listTeamActiveSessions(
    AuthTeamActiveSessionsListCommand command,
  ) async {
    teamActiveSessionsLists.add(command);
    return AuthTeamActiveSessionsListed(
      sessions: List<AuthTeamActiveSessionSummary>.unmodifiable(
        teamActiveSessions,
      ),
    );
  }

  @override
  Future<AuthSessionRevoked> revokeSession(
    AuthSessionRevokeCommand command,
  ) async {
    sessionRevokes.add(command);
    return const AuthSessionRevoked(revoked: true);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) async {
    allSessionsRevokes.add(command);
    return const AuthAllSessionsRevoked(revokedCount: 2);
  }

  final auditLogLists = <AuthEventListCommand>[];

  List<AuthEventListEntry> auditLogEntries = <AuthEventListEntry>[
    AuthEventListEntry(
      eventId: '99999999-9999-4999-8999-999999999999',
      eventKind: AuthEventKind.signIn,
      eventType: 'auth.user.signed_in',
      friendlyLabel: 'Sign-in',
      occurredAt: DateTime.utc(2026, 4, 28, 12),
      ip: '203.0.113.10',
      geoCountry: 'CA',
    ),
  ];
  bool auditLogHasMore = false;

  /// When true, the recording gateway honors offset + slices
  /// [auditLogEntries] using [auditLogPagedPageSize] (not the
  /// command's limit, so the export route's larger inner page size
  /// can still be forced into multiple roundtrips). `hasMore` is set
  /// based on whether the slice covers the tail. The export route
  /// relies on this so the paging loop exercises the seam.
  bool auditLogPagedMode = false;
  int auditLogPagedPageSize = 100;

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) async {
    auditLogLists.add(command);
    if (auditLogPagedMode) {
      final offset = command.offset < 0 ? 0 : command.offset;
      final pageSize = auditLogPagedPageSize < 1 ? 1 : auditLogPagedPageSize;
      final start = offset.clamp(0, auditLogEntries.length);
      final end = (start + pageSize).clamp(0, auditLogEntries.length);
      final slice = auditLogEntries.sublist(start, end);
      return AuthEventsListed(
        entries: List<AuthEventListEntry>.unmodifiable(slice),
        hasMore: end < auditLogEntries.length,
      );
    }
    return AuthEventsListed(
      entries: List<AuthEventListEntry>.unmodifiable(auditLogEntries),
      hasMore: auditLogHasMore,
    );
  }
}

const proxyAuthTeamRole = TeamRoleCatalogEntry(
  roleId: proxyAuthRoleId,
  roleKey: 'kitchen_lead',
  displayName: 'Kitchen Lead',
  description: 'Can coach kitchen handoffs',
  isSeeded: false,
  isEditable: true,
  operatorId: proxyAuthOperatorId,
  permissions: <TeamRolePermissionRule>[
    TeamRolePermissionRule(permissionKey: 'team.users.view', effect: 'allow'),
  ],
);
