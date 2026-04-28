// Forge & Flow advisor proxy bootstrap helpers.
//
// Kept separate from `main.dart` so production wiring can be tested
// without binding a socket or opening a live database connection.

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/recovery_code_attempt_store.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/auth/permission_resolution.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/auth/rate_limited_hibp_range_fetcher.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_attempt_limiter.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_consumer.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_generator.dart';
import 'package:forge_and_flow/services/mfa/recovery_code_hasher.dart';

import 'advisor_proxy.dart';

typedef PostgresPoolFactory = PostgresPool Function(String connectionString);

class ProxyProductionBindings {
  const ProxyProductionBindings({
    required this.authSessionLedgerWriter,
    required this.permissionSnapshotResolver,
    required this.adminPermissionGuard,
    required this.authOperationsGateway,
    required this.passwordChangeGateway,
    required this.mfaOperationsGateway,
  });

  final AuthSessionLedgerWriter authSessionLedgerWriter;
  final ProxyPermissionSnapshotResolver permissionSnapshotResolver;
  final ProxyAdminPermissionGuard adminPermissionGuard;
  final AuthOperationsGateway authOperationsGateway;
  final PasswordChangeGateway passwordChangeGateway;
  final MfaOperationsGateway mfaOperationsGateway;
}

/// Builds all Phase 9 production route bindings without opening network or
/// database connections. Live I/O begins only when a request invokes one of the
/// returned gateways.
ProxyProductionBindings buildProxyProductionBindings(
  ProxyConfig config, {
  PostgresPoolFactory postgresPoolFactory = PackagePostgresPool.fromUrl,
}) {
  final firebaseAdmin = _buildFirebaseAdminAuthClient(config);
  final tenantPool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  final adminPool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresAdminUrl),
  );
  final tenantWrapper = TenantTransactionWrapper(tenantPool);
  final adminWrapper = TenantTransactionWrapper(adminPool);

  final tenantUserRoles = UserRolesRepository(tenantWrapper);
  final tenantRolePermissions = RolePermissionsRepository(tenantWrapper);
  final tenantAudit = AuthEventsAuditRepository(tenantWrapper);
  final tenantUsers = UsersRepository(tenantWrapper);
  final tenantMfaFactors = MfaFactorsRepository(tenantWrapper);

  final permissionSnapshotResolver = RepositoryProxyPermissionSnapshotResolver(
    userRolesRepository: tenantUserRoles,
    rolePermissionsRepository: tenantRolePermissions,
    requiresMfaKeys: PermissionKeys.requiresMfa,
  );

  return ProxyProductionBindings(
    authSessionLedgerWriter: RepositoryAuthSessionLedgerWriter(
      repository: AuthSessionsRepository(tenantWrapper),
    ),
    permissionSnapshotResolver: permissionSnapshotResolver,
    adminPermissionGuard: RepositoryProxyAdminPermissionGuard(
      userRolesRepository: tenantUserRoles,
      rolePermissionsRepository: tenantRolePermissions,
      requiresMfaKeys: PermissionKeys.requiresMfa,
    ),
    authOperationsGateway: RepositoryAuthOperationsGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: UsersRepository(adminWrapper),
      rolesRepository: RolesRepository(adminWrapper),
      userRolesRepository: UserRolesRepository(adminWrapper),
      authInvitesRepository: AuthInvitesRepository(adminWrapper),
      auditRepository: AuthEventsAuditRepository(adminWrapper),
    ),
    passwordChangeGateway: RepositoryPasswordChangeGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: tenantUsers,
      passwordHistoryRepository: PasswordHistoryRepository(tenantWrapper),
      auditRepository: tenantAudit,
      hibpScreener: HibpPwnedPasswordScreener(
        fetcher: RateLimitedHibpRangeFetcher(inner: HttpHibpRangeFetcher()),
      ),
      passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
    ),
    mfaOperationsGateway: RepositoryMfaOperationsGateway(
      enrollmentService: FirebaseMfaEnrollmentService(
        client: IdentityToolkitFirebaseMfaClient(
          apiKey: config.secretFor(ProxySecretNames.firebaseWebApiKey),
        ),
        codeGenerator: RecoveryCodeGenerator(),
        codeHasher: const Sha256RecoveryCodeHasher(),
        saltSource: SecureRandomRecoveryCodeSaltSource(),
      ),
      mfaFactorsRepository: tenantMfaFactors,
      recoveryCodeConsumer: RecoveryCodeConsumer(
        hasher: const Sha256RecoveryCodeHasher(),
        repository: tenantMfaFactors,
        limiter: RecoveryCodeAttemptLimiter(
          store: PostgresRecoveryCodeAttemptStore(adminWrapper),
        ),
      ),
      auditRepository: tenantAudit,
    ),
  );
}

/// Builds the production auth-session ledger writer for the proxy.
///
/// Auth session writes are tenant-scoped user operations, so they use
/// [ProxySecretNames.postgresUrl] rather than the admin/deployment DSN.
/// The returned writer still fails closed at request time if the
/// database is unavailable; constructing it does not open a network
/// connection.
AuthSessionLedgerWriter buildAuthSessionLedgerWriter(
  ProxyConfig config, {
  PostgresPoolFactory postgresPoolFactory = PackagePostgresPool.fromUrl,
}) {
  final pool = postgresPoolFactory(
    config.secretFor(ProxySecretNames.postgresUrl),
  );
  return RepositoryAuthSessionLedgerWriter(
    repository: AuthSessionsRepository(TenantTransactionWrapper(pool)),
  );
}

FirebaseAdminAuthClient _buildFirebaseAdminAuthClient(ProxyConfig config) {
  final projectId = config.firebaseProjectId;
  if (projectId == null || projectId.isEmpty) {
    throw ProxyConfigError(
      'advisor proxy missing required non-secret config by name: '
      '${ProxyConfigNames.firebaseProjectId}. Set it before exposing '
      'Phase 9 auth-operation routes.',
      missingSecretNames: const <String>[ProxyConfigNames.firebaseProjectId],
    );
  }
  return IdentityToolkitFirebaseAdminAuthClient(
    projectId: projectId,
    apiKey: config.secretFor(ProxySecretNames.firebaseWebApiKey),
    accessTokenProvider: MetadataServerAccessTokenProvider(),
    continueUrl: config.firebaseEmailActionContinueUrl,
  );
}

class RepositoryProxyPermissionSnapshotResolver
    implements ProxyPermissionSnapshotResolver {
  RepositoryProxyPermissionSnapshotResolver({
    required UserRolesRepository userRolesRepository,
    required RolePermissionsRepository rolePermissionsRepository,
    required Set<String> requiresMfaKeys,
    DateTime Function()? now,
  }) : _userRolesRepository = userRolesRepository,
       _rolePermissionsRepository = rolePermissionsRepository,
       _requiresMfaKeys = Set<String>.unmodifiable(requiresMfaKeys),
       _now = now ?? DateTime.now;

  final UserRolesRepository _userRolesRepository;
  final RolePermissionsRepository _rolePermissionsRepository;
  final Set<String> _requiresMfaKeys;
  final DateTime Function() _now;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    final bundle = await _loadPermissionBundle(
      userRolesRepository: _userRolesRepository,
      rolePermissionsRepository: _rolePermissionsRepository,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      userId: scope.userId,
    );
    final evaluatedAt = _now().toUtc();
    return ProxyPermissionSnapshot(
      userId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      rolesVersion: scope.rolesVersion,
      evaluatedAt: evaluatedAt,
      permissions: PermissionResolver.resolveAll(
        grants: bundle.grants,
        rules: bundle.rules,
        operatorId: scope.operatorId,
        locationId: scope.locationId,
        now: evaluatedAt,
      ),
      requiresMfaKeys: _requiresMfaKeys,
    );
  }
}

class RepositoryProxyAdminPermissionGuard implements ProxyAdminPermissionGuard {
  RepositoryProxyAdminPermissionGuard({
    required UserRolesRepository userRolesRepository,
    required RolePermissionsRepository rolePermissionsRepository,
    required Set<String> requiresMfaKeys,
    Duration freshnessWindow = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _userRolesRepository = userRolesRepository,
       _rolePermissionsRepository = rolePermissionsRepository,
       _requiresMfaKeys = Set<String>.unmodifiable(requiresMfaKeys),
       _freshnessWindow = freshnessWindow,
       _now = now ?? DateTime.now;

  final UserRolesRepository _userRolesRepository;
  final RolePermissionsRepository _rolePermissionsRepository;
  final Set<String> _requiresMfaKeys;
  final Duration _freshnessWindow;
  final DateTime Function() _now;

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    final requestedAt = (context.requestedAt ?? _now()).toUtc();
    final recaptcha = context.recaptchaOutcome;
    if (recaptcha == ProxyAdminGuardRecaptcha.reject) {
      return const ProxyAdminRejected(reasonCode: 'recaptcha_rejected');
    }
    if (recaptcha == ProxyAdminGuardRecaptcha.challenge) {
      return const ProxyAdminChallengeRequired();
    }

    if (_requiresMfaKeys.contains(context.requestedPermissionKey) &&
        requestedAt.difference(context.lastFreshAuthAt.toUtc()) >
            _freshnessWindow) {
      return ProxyAdminMfaStaleAuth(
        refreshAfter: context.lastFreshAuthAt.toUtc().add(_freshnessWindow),
      );
    }

    final bundle = await _loadPermissionBundle(
      userRolesRepository: _userRolesRepository,
      rolePermissionsRepository: _rolePermissionsRepository,
      operatorId: context.operatorId,
      locationId: context.locationId,
      userId: context.actorUserId,
    );
    final activeRoleIds = <String>{
      for (final grant in bundle.grants)
        if (grant.operatorId == context.operatorId &&
            grant.isActiveAt(requestedAt) &&
            grant.coversLocation(context.locationId))
          grant.roleId,
    };
    for (final rule in bundle.rules) {
      if (rule.permissionKey != context.requestedPermissionKey) continue;
      if (!activeRoleIds.contains(rule.roleId)) continue;
      if (rule.effect == PermissionEffect.deny) {
        return ProxyAdminDeniedExplicit(matchedRoleId: rule.roleId);
      }
    }
    final effect = PermissionResolver.resolve(
      permissionKey: context.requestedPermissionKey,
      grants: bundle.grants,
      rules: bundle.rules,
      operatorId: context.operatorId,
      locationId: context.locationId,
      now: requestedAt,
    );
    return effect == PermissionEffect.allow
        ? const ProxyAdminAllowed()
        : const ProxyAdminDeniedDefault();
  }
}

Future<_PermissionBundle> _loadPermissionBundle({
  required UserRolesRepository userRolesRepository,
  required RolePermissionsRepository rolePermissionsRepository,
  required String operatorId,
  required String locationId,
  required String userId,
}) async {
  final grantRows = await userRolesRepository.activeGrantsForUser(
    operatorId: operatorId,
    locationId: locationId,
    targetUserId: userId,
    actorUserId: userId,
  );
  final grants = <UserRoleGrant>[
    for (final row in grantRows)
      UserRoleGrant(
        userRoleId: row.userRoleId,
        userId: row.userId,
        roleId: row.roleId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        validFrom: row.validFrom,
        validUntil: row.validUntil,
        revokedAt: row.revokedAt,
      ),
  ];
  final roleIds = grants.map((grant) => grant.roleId).toSet();
  final rules = <RolePermissionRule>[];
  for (final roleId in roleIds) {
    final rows = await rolePermissionsRepository.listForRole(
      operatorId: operatorId,
      locationId: locationId,
      roleId: roleId,
      actorUserId: userId,
    );
    rules.addAll(
      rows.map(
        (row) => RolePermissionRule(
          roleId: row.roleId,
          permissionKey: row.permissionKey,
          effect: _permissionEffectFromSql(row.effect),
        ),
      ),
    );
  }
  return _PermissionBundle(
    grants: List<UserRoleGrant>.unmodifiable(grants),
    rules: List<RolePermissionRule>.unmodifiable(rules),
  );
}

PermissionEffect _permissionEffectFromSql(String value) {
  return value == 'allow' ? PermissionEffect.allow : PermissionEffect.deny;
}

class _PermissionBundle {
  const _PermissionBundle({required this.grants, required this.rules});

  final List<UserRoleGrant> grants;
  final List<RolePermissionRule> rules;
}
