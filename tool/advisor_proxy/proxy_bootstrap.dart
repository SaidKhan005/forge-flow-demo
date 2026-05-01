// Forge & Flow advisor proxy bootstrap helpers.
//
// Kept separate from `main.dart` so production wiring can be tested
// without binding a socket or opening a live database connection.

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/corpus_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/event_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/locations_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factor_removal_requests_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mfa_recovery_request_attempts_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operator_admins_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/operators_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/org_units_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/password_history_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/provider_credentials_repository.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_stub_provider.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/role_permissions_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/usage_caps_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/user_roles_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/auth/permission_resolution.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_confirm_gateway.dart';
import 'package:forge_and_flow/services/auth/password_reset_request_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/auth/rate_limited_hibp_range_fetcher.dart';
import 'package:forge_and_flow/services/auth/repository_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/repository_account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_change_gateway.dart';
import 'package:forge_and_flow/services/auth/repository_password_history_check.dart';
import 'package:forge_and_flow/services/mfa/firebase_mfa_enrollment_service.dart';
import 'package:forge_and_flow/services/mfa/identity_toolkit_firebase_mfa_client.dart';
import 'package:forge_and_flow/services/mfa/mfa_operations_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_recovery_request_gateway.dart';
import 'package:forge_and_flow/services/mfa/mfa_removal_worker.dart';

import 'advisor_proxy.dart';

typedef PostgresPoolFactory = PostgresPool Function(String connectionString);

class ProxyProductionBindings {
  const ProxyProductionBindings({
    required this.accountingStore,
    required this.authSessionLedgerWriter,
    required this.firebaseAdminAuthClient,
    required this.accountInfoGateway,
    required this.permissionSnapshotResolver,
    required this.adminPermissionGuard,
    required this.authOperationsGateway,
    required this.servicePrincipalJwtIssuanceGateway,
    required this.passwordChangeGateway,
    required this.passwordResetConfirmGateway,
    required this.passwordResetRequestGateway,
    required this.mfaOperationsGateway,
    required this.mfaRecoveryRequestGateway,
    required this.mfaRemovalWorker,
    required this.operatorLocationAdminGateway,
    required this.pricingTierAdminGateway,
    required this.corpusAdminGateway,
    required this.integrationAdminGateway,
    required this.integrationAdminActorResolver,
  });

  final ProxyAccountingStore accountingStore;
  final AuthSessionLedgerWriter authSessionLedgerWriter;
  final FirebaseAdminAuthClient firebaseAdminAuthClient;
  final AccountInfoGateway accountInfoGateway;
  final ProxyPermissionSnapshotResolver permissionSnapshotResolver;
  final ProxyAdminPermissionGuard adminPermissionGuard;
  final AuthOperationsGateway authOperationsGateway;
  final ServicePrincipalJwtIssuanceGateway servicePrincipalJwtIssuanceGateway;
  final PasswordChangeGateway passwordChangeGateway;
  final PasswordResetConfirmGateway passwordResetConfirmGateway;
  final PasswordResetRequestGateway passwordResetRequestGateway;
  final MfaOperationsGateway mfaOperationsGateway;
  final MfaRecoveryRequestGateway mfaRecoveryRequestGateway;
  final MfaRemovalWorker mfaRemovalWorker;
  final OperatorLocationAdminProxyGateway operatorLocationAdminGateway;
  final PricingTierAdminProxyGateway pricingTierAdminGateway;
  final CorpusAdminProxyGateway corpusAdminGateway;
  final IntegrationAdminProxyGateway integrationAdminGateway;
  final IntegrationAdminActorResolver integrationAdminActorResolver;
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
  final tenantMfaRemovalRequests = MfaFactorRemovalRequestsRepository(
    tenantWrapper,
  );
  final tenantEventOutbox = EventOutboxRepository(tenantWrapper);
  final adminMfaFactors = MfaFactorsRepository(adminWrapper);
  final adminMfaRemovalRequests = MfaFactorRemovalRequestsRepository(
    adminWrapper,
  );
  final adminEventOutbox = EventOutboxRepository(adminWrapper);
  final firebaseMfaClient = IdentityToolkitFirebaseMfaClient(
    apiKey: config.secretFor(ProxySecretNames.firebaseWebApiKey),
  );
  final adminAudit = AuthEventsAuditRepository(adminWrapper);
  final authOperationsGateway = RepositoryAuthOperationsGateway(
    firebaseAdmin: firebaseAdmin,
    usersRepository: UsersRepository(adminWrapper),
    rolesRepository: RolesRepository(adminWrapper),
    rolePermissionsRepository: RolePermissionsRepository(adminWrapper),
    userRolesRepository: UserRolesRepository(adminWrapper),
    authInvitesRepository: AuthInvitesRepository(adminWrapper),
    // Writer-side audit rows still flow through the admin wrapper —
    // append-only inserts must succeed even when an admin path runs
    // outside a tenant scope. The 9.UX.6 self-service read uses a
    // separate tenant-scoped repository binding (see
    // `auditReadRepository`) so the per-user WHERE + per-tenant RLS
    // policy gate the projection without disturbing the existing
    // writer.
    auditRepository: adminAudit,
    auditReadRepository: AuthEventsAuditRepository(tenantWrapper),
    // Phase 9.UX.4: tenant-scoped reads/writes — per-operator RLS
    // policies on `org_units` + `locations` are the gate, so the
    // repo runs through the tenant pool, not the admin pool.
    orgUnitsRepository: OrgUnitsRepository(tenantWrapper),
    // Phase 9.UX.5: self-service Active Sessions reads / revokes
    // also go through the tenant pool — the per-user RLS policy on
    // `auth_sessions` is the gate, and admin-grade revoke-all paths
    // remain on the existing AuthSessionLedgerWriter binding.
    authSessionsRepository: AuthSessionsRepository(tenantWrapper),
  );

  final permissionSnapshotResolver = RepositoryProxyPermissionSnapshotResolver(
    userRolesRepository: tenantUserRoles,
    rolePermissionsRepository: tenantRolePermissions,
    requiresMfaKeys: PermissionKeys.requiresMfa,
  );

  return ProxyProductionBindings(
    accountingStore: PostgresProxyAccountingStore(wrapper: tenantWrapper),
    firebaseAdminAuthClient: firebaseAdmin,
    accountInfoGateway: RepositoryAccountInfoGateway(
      usersRepository: tenantUsers,
    ),
    authSessionLedgerWriter: RepositoryAuthSessionLedgerWriter(
      repository: AuthSessionsRepository(tenantWrapper),
    ),
    permissionSnapshotResolver: permissionSnapshotResolver,
    adminPermissionGuard: RepositoryProxyAdminPermissionGuard(
      userRolesRepository: tenantUserRoles,
      rolePermissionsRepository: tenantRolePermissions,
      requiresMfaKeys: PermissionKeys.requiresMfa,
    ),
    authOperationsGateway: authOperationsGateway,
    servicePrincipalJwtIssuanceGateway:
        PostgresServicePrincipalJwtIssuanceGateway(
          wrapper: tenantWrapper,
          issuer: ServicePrincipalJwtIssuer(
            sharedSecret: config.secretFor(
              ProxySecretNames.servicePrincipalJwtSecret,
            ),
          ),
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
    passwordResetConfirmGateway: RepositoryPasswordResetConfirmGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: UsersRepository(adminWrapper),
      passwordHistoryRepository: PasswordHistoryRepository(tenantWrapper),
      auditRepository: adminAudit,
      hibpScreener: HibpPwnedPasswordScreener(
        fetcher: RateLimitedHibpRangeFetcher(inner: HttpHibpRangeFetcher()),
      ),
      passwordHistoryHasher: const Sha256PasswordHistoryHasher(),
    ),
    // Phase 9.UX.7: self-serve password-reset request. The lookup
    // runs through the admin pool (we must find the user by email
    // even though the Flutter caller is unauthenticated), Firebase
    // Identity Platform issues the action link, and the audit row
    // lands on the resolved user's tenant scope.
    passwordResetRequestGateway: RepositoryPasswordResetRequestGateway(
      firebaseAdmin: firebaseAdmin,
      usersRepository: UsersRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    mfaOperationsGateway: RepositoryMfaOperationsGateway(
      enrollmentService: FirebaseMfaEnrollmentService(
        client: firebaseMfaClient,
      ),
      mfaFactorsRepository: tenantMfaFactors,
      auditRepository: tenantAudit,
      firebaseMfaClient: firebaseMfaClient,
      removalRequestsRepository: tenantMfaRemovalRequests,
    ),
    mfaRecoveryRequestGateway: RepositoryMfaRecoveryRequestGateway(
      usersRepository: UsersRepository(adminWrapper),
      eventOutboxRepository: tenantEventOutbox,
      rateLimiter: PostgresMfaRecoveryRequestRateLimiter(adminWrapper),
    ),
    mfaRemovalWorker: MfaRemovalWorker(
      removalRequestsRepository: adminMfaRemovalRequests,
      mfaFactorsRepository: adminMfaFactors,
      usersRepository: UsersRepository(adminWrapper),
      auditRepository: adminAudit,
      firebaseAdmin: firebaseAdmin,
      eventOutboxRepository: adminEventOutbox,
    ),
    // Phase 11A.1 — operator/location admin gateway. The repos run
    // through the admin pool (POSTGRES_ADMIN_URL) because the F&F
    // admin console scans / writes across operators; per-tenant RLS
    // would block cross-operator listings.
    operatorLocationAdminGateway: RepositoryOperatorLocationAdminProxyGateway(
      operatorsRepository: OperatorsRepository(adminWrapper),
      locationsRepository: LocationsRepository(adminWrapper),
      operatorAdminsRepository: OperatorAdminsRepository(adminWrapper),
      authOperationsGateway: authOperationsGateway,
      auditRepository: adminAudit,
    ),
    // Phase 11A.2 — pricing tier admin gateway. Same admin pool
    // rationale: the F&F admin browses caps across the fleet and
    // edits subscription tiers without any operator session in flight,
    // so per-tenant RLS would block reads. The OrgUnitsRepository
    // resolves each operator's root org_unit id to populate the
    // 9.0Σ.g `usage_caps.billing_owner_org_unit_id` /
    // `scoped_org_unit_id` NOT NULL columns.
    pricingTierAdminGateway: RepositoryPricingTierAdminProxyGateway(
      operatorsRepository: OperatorsRepository(adminWrapper),
      usageCapsRepository: UsageCapsRepository(adminWrapper),
      orgUnitsRepository: OrgUnitsRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    // Phase 11A.3a — corpus admin gateway. Same admin pool rationale
    // as pricing: the corpus is shared methodology across operators,
    // not tenant-scoped data. The repository runs through `withSystem`
    // (forge_admin BYPASSRLS) so the read/write covers every chunk +
    // version row.
    corpusAdminGateway: RepositoryCorpusAdminProxyGateway(
      corpusRepository: CorpusRepository(adminWrapper),
      auditRepository: adminAudit,
    ),
    // Phase 11A.4 — Integration management gateway. Backed by the
    // `provider_credentials` masked-display ledger and a KMS stub
    // provider. Production swaps in a real KMS implementation
    // (Cloud Run KMS / Azure Key Vault) post-launch; the gateway
    // contract stays identical.
    integrationAdminGateway: RepositoryIntegrationAdminProxyGateway(
      providerCredentialsRepository: ProviderCredentialsRepository(
        adminWrapper,
      ),
      kmsProvider: KmsStubProvider(),
      auditRepository: adminAudit,
    ),
    // Phase 11A.4 — Resolves the verified Firebase UID into a
    // Postgres `users.user_id` (UUID) for audit attribution before
    // any integration write runs. Backed by the admin pool because
    // the lookup is cross-tenant (F&F admins live outside any
    // operator scope).
    integrationAdminActorResolver:
        RepositoryIntegrationAdminActorResolver(
          usersRepository: UsersRepository(adminWrapper),
        ),
  );
}

/// Production [OperatorLocationAdminProxyGateway] backed by
/// [OperatorsRepository] / [LocationsRepository] /
/// [OperatorAdminsRepository]. Translates the proxy's command shape
/// into repo calls and projects the row results into JSON-ready
/// maps the route handler can return as-is. Every UUID is generated
/// by Postgres (`default gen_random_uuid()`) and returned via
/// `RETURNING`, so multiple Cloud Run instances cannot collide on
/// IDs.
class RepositoryOperatorLocationAdminProxyGateway
    implements OperatorLocationAdminProxyGateway {
  RepositoryOperatorLocationAdminProxyGateway({
    required OperatorsRepository operatorsRepository,
    required LocationsRepository locationsRepository,
    required OperatorAdminsRepository operatorAdminsRepository,
    required AuthOperationsGateway authOperationsGateway,
    required AuthEventsAuditRepository auditRepository,
  }) : _operators = operatorsRepository,
       _locations = locationsRepository,
       _operatorAdmins = operatorAdminsRepository,
       _authOperationsGateway = authOperationsGateway,
       _auditRepository = auditRepository;

  final OperatorsRepository _operators;
  final LocationsRepository _locations;
  final OperatorAdminsRepository _operatorAdmins;
  final AuthOperationsGateway _authOperationsGateway;
  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithLocations({
    required String actorUserId,
    required String adminReason,
  }) async {
    final operators = await _operators.listOperators(adminReason: adminReason);
    final locationsByOperator = <String, List<LocationAdminRow>>{};
    final allLocations = await _locations.listAllLocations(
      adminReason: adminReason,
    );
    for (final loc in allLocations) {
      locationsByOperator
          .putIfAbsent(loc.operatorId, () => <LocationAdminRow>[])
          .add(loc);
    }
    final bundles = <Map<String, Object?>>[
      for (final op in operators)
        <String, Object?>{
          'operator': op.toJson(),
          'locations': <Map<String, Object?>>[
            for (final loc
                in locationsByOperator[op.operatorId] ??
                    const <LocationAdminRow>[])
              loc.toJson(),
          ],
          // Per-operator admin-grant count. The full list is loaded
          // on demand via the future per-operator detail endpoint
          // (Phase 11A.x). Surfacing the count here lets the admin
          // console flag operators without an admin attached.
          'admin_grant_count': (await _operatorAdmins.listForOperator(
            operatorId: op.operatorId,
            adminReason: '$adminReason:admin_grants:${op.operatorId}',
          )).length,
        },
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.operator_location.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'operator_count': operators.length,
        'location_count': allLocations.length,
      },
    );
    return bundles;
  }

  @override
  Future<Map<String, Object?>> onboardOperator({
    required String actorUserId,
    required String businessName,
    required String ownerEmail,
    required String subscriptionTier,
    required String preferredCurrency,
    required String adminUserEmail,
    required String primaryLocationName,
    required String primaryLocationTimezone,
    required int primaryLocationRolloverHour,
    required String adminReason,
  }) async {
    final result = await _operators.onboardOperatorAtomically(
      businessName: businessName,
      ownerEmail: ownerEmail,
      subscriptionTier: subscriptionTier,
      preferredCurrency: preferredCurrency,
      locationName: primaryLocationName,
      locationAddress: '',
      locationTimezone: primaryLocationTimezone,
      locationRolloverHour: primaryLocationRolloverHour,
      adminReason: adminReason,
    );
    final invite = await _authOperationsGateway.createInvite(
      TeamInviteCreateCommand(
        actorUserId: actorUserId,
        operatorId: result.operator.operatorId,
        locationId: result.location.locationId,
        email: adminUserEmail,
        roleId: 'operator_owner',
        scopeType: 'operator_wide',
      ),
    );
    final adminUserId = invite.userId;
    if (adminUserId == null || adminUserId.isEmpty) {
      throw StateError(
        'auth operations invite did not return the created user_id',
      );
    }
    await _operatorAdmins.upsertAdminGrant(
      userId: adminUserId,
      operatorId: result.operator.operatorId,
      isSuperAdmin: false,
      scopeType: 'operator_owner',
      adminReason: '$adminReason:operator_admins',
    );
    await _audit(
      actorUserId: actorUserId,
      targetUserId: adminUserId,
      operatorId: result.operator.operatorId,
      locationId: result.location.locationId,
      eventType: 'admin.operator_location.onboarded',
      adminReason: adminReason,
      payload: <String, Object?>{
        'business_name': businessName,
        'owner_email': ownerEmail,
        'admin_user_email': adminUserEmail,
        'invite_id': invite.inviteId,
      },
    );
    return <String, Object?>{
      'operator': result.operator.toJson(),
      'locations': <Map<String, Object?>>[result.location.toJson()],
      'admin_user_id': adminUserId,
      'admin_invite_id': invite.inviteId,
    };
  }

  @override
  Future<Map<String, Object?>?> patchOperator({
    required String actorUserId,
    required String operatorId,
    String? businessName,
    String? ownerEmail,
    String? subscriptionTier,
    String? preferredCurrency,
    String? primaryLocationId,
    required String adminReason,
  }) async {
    final updated = await _operators.updateOperator(
      operatorId: operatorId,
      businessName: businessName,
      ownerEmail: ownerEmail,
      subscriptionTier: subscriptionTier,
      preferredCurrency: preferredCurrency,
      primaryLocationId: primaryLocationId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_patched',
        adminReason: adminReason,
        payload: <String, Object?>{
          'changed_fields': <String>[
            if (businessName != null) 'business_name',
            if (ownerEmail != null) 'owner_email',
            if (subscriptionTier != null) 'subscription_tier',
            if (preferredCurrency != null) 'preferred_currency',
            if (primaryLocationId != null) 'primary_location_id',
          ],
        },
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>?> suspendOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    final updated = await _operators.suspendOperator(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_suspended',
        adminReason: adminReason,
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>?> reactivateOperator({
    required String actorUserId,
    required String operatorId,
    required String adminReason,
  }) async {
    final updated = await _operators.reactivateOperator(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (updated != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: updated.operatorId,
        locationId: updated.primaryLocationId,
        eventType: 'admin.operator_location.operator_reactivated',
        adminReason: adminReason,
      );
    }
    return updated?.toJson();
  }

  @override
  Future<Map<String, Object?>> addLocation({
    required String actorUserId,
    required String operatorId,
    required String name,
    required String address,
    required String timezone,
    required int businessDayRolloverHour,
    required String adminReason,
  }) async {
    final created = await _locations.insertLocation(
      operatorId: operatorId,
      name: name,
      address: address,
      timezone: timezone,
      businessDayRolloverHour: businessDayRolloverHour,
      adminReason: adminReason,
    );
    await _audit(
      actorUserId: actorUserId,
      operatorId: created.operatorId,
      locationId: created.locationId,
      eventType: 'admin.operator_location.location_added',
      adminReason: adminReason,
      payload: <String, Object?>{'name': name},
    );
    return created.toJson();
  }

  @override
  Future<Map<String, Object?>?> patchLocation({
    required String actorUserId,
    required String locationId,
    String? name,
    String? address,
    String? timezone,
    int? businessDayRolloverHour,
    required String adminReason,
  }) async {
    final patched = await _locations.updateLocation(
      locationId: locationId,
      name: name,
      address: address,
      timezone: timezone,
      businessDayRolloverHour: businessDayRolloverHour,
      adminReason: adminReason,
    );
    if (patched != null) {
      await _audit(
        actorUserId: actorUserId,
        operatorId: patched.operatorId,
        locationId: patched.locationId,
        eventType: 'admin.operator_location.location_patched',
        adminReason: adminReason,
        payload: <String, Object?>{
          'changed_fields': <String>[
            if (name != null) 'name',
            if (address != null) 'address',
            if (timezone != null) 'timezone',
            if (businessDayRolloverHour != null) 'business_day_rollover_hour',
          ],
        },
      );
    }
    return patched?.toJson();
  }

  @override
  Future<AdminLocationRemovalResult> removeLocation({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    final operator = await _operators.findById(
      operatorId: operatorId,
      adminReason: '$adminReason:lookup',
    );
    if (operator == null) {
      return AdminLocationRemovalResult.notFound;
    }
    if (operator.primaryLocationId == locationId) {
      return AdminLocationRemovalResult.primaryLocationProtected;
    }
    final affected = await _locations.deleteLocation(
      locationId: locationId,
      operatorId: operatorId,
      adminReason: adminReason,
    );
    if (affected == 0) {
      return AdminLocationRemovalResult.notFound;
    }
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: 'admin.operator_location.location_removed',
      adminReason: adminReason,
    );
    return AdminLocationRemovalResult.removed;
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      targetUserId: targetUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Locked tier-template caps the proxy seeds when the admin applies
/// a template. Mirrors the launch-time defaults in
/// `lib/admin/models/pricing_tier_admin_models.dart`. Keep in sync.
const Map<String, List<_PricingTierTemplateCap>> _kPricingTierTemplateCaps =
    <String, List<_PricingTierTemplateCap>>{
  'pilot': <_PricingTierTemplateCap>[
    _PricingTierTemplateCap(
      usageClass: 'advisor_qa',
      monthlyCapUsd: 50.0,
      perInvocationCapUsd: 0.10,
    ),
  ],
  'starter': <_PricingTierTemplateCap>[
    _PricingTierTemplateCap(
      usageClass: 'advisor_qa',
      monthlyCapUsd: 50.0,
      perInvocationCapUsd: 0.10,
    ),
  ],
  'premium': <_PricingTierTemplateCap>[
    _PricingTierTemplateCap(
      usageClass: 'advisor_qa',
      monthlyCapUsd: 200.0,
      perInvocationCapUsd: 0.20,
    ),
  ],
  'elite': <_PricingTierTemplateCap>[
    _PricingTierTemplateCap(
      usageClass: 'advisor_qa',
      monthlyCapUsd: 400.0,
      perInvocationCapUsd: 0.20,
    ),
    _PricingTierTemplateCap(
      usageClass: 'coach_qa',
      monthlyCapUsd: 300.0,
      perInvocationCapUsd: 0.20,
    ),
  ],
  'pro': <_PricingTierTemplateCap>[
    _PricingTierTemplateCap(
      usageClass: 'advisor_qa',
      monthlyCapUsd: 600.0,
      perInvocationCapUsd: 0.20,
    ),
    _PricingTierTemplateCap(
      usageClass: 'coach_qa',
      monthlyCapUsd: 400.0,
      perInvocationCapUsd: 0.20,
    ),
    _PricingTierTemplateCap(
      usageClass: 'workflow_pl',
      monthlyCapUsd: 500.0,
      perInvocationCapUsd: 5.0,
    ),
    _PricingTierTemplateCap(
      usageClass: 'workflow_schedule',
      monthlyCapUsd: 300.0,
      perInvocationCapUsd: 5.0,
    ),
  ],
  'enterprise': <_PricingTierTemplateCap>[],
};

class _PricingTierTemplateCap {
  const _PricingTierTemplateCap({
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
  });

  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
}

/// Production [PricingTierAdminProxyGateway] backed by
/// [OperatorsRepository] + [UsageCapsRepository] +
/// [OrgUnitsRepository]. Translates the proxy's command shape into
/// repo calls and projects the row results into JSON-ready maps the
/// route handler can return as-is. Every edit threads `actorUserId`
/// into the repository's `created_by` / `updated_by` audit columns.
///
/// 9.0Σ.g `usage_caps` carries `billing_owner_org_unit_id` /
/// `scoped_org_unit_id` as NOT NULL columns on the post-flip schema.
/// For the launch admin pricing UX both axes resolve to the
/// operator's root `org_units` row (corp pays for corp scope); future
/// surfaces can pass distinct ids when corp / sub-brand billing
/// splits are wired.
class RepositoryPricingTierAdminProxyGateway
    implements PricingTierAdminProxyGateway {
  RepositoryPricingTierAdminProxyGateway({
    required OperatorsRepository operatorsRepository,
    required UsageCapsRepository usageCapsRepository,
    required OrgUnitsRepository orgUnitsRepository,
    required AuthEventsAuditRepository auditRepository,
  })  : _operators = operatorsRepository,
        _caps = usageCapsRepository,
        _orgUnits = orgUnitsRepository,
        _auditRepository = auditRepository;

  final OperatorsRepository _operators;
  final UsageCapsRepository _caps;
  final OrgUnitsRepository _orgUnits;
  final AuthEventsAuditRepository _auditRepository;

  /// Resolves the operator's root `org_units` id (the row with
  /// `parent_id IS NULL`). The 9.0Σ.g step-b backfill plus the
  /// `OrgUnitsRepository.createRoot` onboarding path guarantees one
  /// per operator. Throws [PricingTierAdminGatewayValidationError] if
  /// the operator has no root row (shouldn't happen post-backfill,
  /// but the admin path fails closed instead of letting the FK throw
  /// a 503).
  Future<String> _rootOrgUnitId({
    required String operatorId,
    required String adminReason,
  }) async {
    final roots = await _orgUnits.listAllRootsAsAdmin(
      adminReason: '$adminReason:org_units_root:$operatorId',
    );
    for (final row in roots) {
      if (row.operatorId == operatorId) return row.id;
    }
    throw const PricingTierAdminGatewayValidationError(
      statusCode: 400,
      code: 'no_org_unit_root',
      message:
          'operator has no root org_units row; run the 9.0Σ.g backfill before editing usage_caps',
    );
  }

  @override
  Future<List<Map<String, Object?>>> listOperatorsWithCaps({
    required String actorUserId,
    required String adminReason,
  }) async {
    final operators = await _operators.listOperators(adminReason: adminReason);
    final allCaps = await _caps.listAllCaps(adminReason: adminReason);
    final capsByOperator = <String, List<UsageCapAdminRow>>{};
    for (final cap in allCaps) {
      capsByOperator
          .putIfAbsent(cap.operatorId, () => <UsageCapAdminRow>[])
          .add(cap);
    }
    final bundles = <Map<String, Object?>>[
      for (final op in operators)
        <String, Object?>{
          'operator': <String, Object?>{
            'operator_id': op.operatorId,
            'business_name': op.businessName,
            'subscription_tier': op.subscriptionTier,
            'preferred_currency': op.preferredCurrency,
            'primary_location_id': op.primaryLocationId,
            'suspended': op.suspendedAt != null,
          },
          'caps': <Map<String, Object?>>[
            for (final cap
                in capsByOperator[op.operatorId] ?? const <UsageCapAdminRow>[])
              cap.toJson(),
          ],
        },
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.pricing.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'operator_count': operators.length,
        'cap_count': allCaps.length,
      },
    );
    return bundles;
  }

  @override
  Future<Map<String, Object?>?> updateOperatorTier({
    required String actorUserId,
    required String operatorId,
    required String subscriptionTier,
    required String adminReason,
  }) async {
    final updated = await _operators.updateOperator(
      operatorId: operatorId,
      subscriptionTier: subscriptionTier,
      adminReason: adminReason,
    );
    if (updated == null) return null;
    await _audit(
      actorUserId: actorUserId,
      operatorId: updated.operatorId,
      locationId: updated.primaryLocationId,
      eventType: 'admin.pricing.tier_patched',
      adminReason: adminReason,
      payload: <String, Object?>{'subscription_tier': subscriptionTier},
    );
    return _bundleFor(updated, adminReason: adminReason);
  }

  @override
  Future<Map<String, Object?>> upsertUsageCap({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String usageClass,
    required double monthlyCapUsd,
    required double perInvocationCapUsd,
    String? staffId,
    String? workflowId,
    required String adminReason,
  }) async {
    final orgUnitId = await _rootOrgUnitId(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    final cap = await _caps.upsertCap(
      operatorId: operatorId,
      billingOwnerOrgUnitId: orgUnitId,
      scopedOrgUnitId: orgUnitId,
      locationId: locationId,
      usageClass: usageClass,
      monthlyCapUsd: monthlyCapUsd,
      perInvocationCapUsd: perInvocationCapUsd,
      staffId: staffId,
      workflowId: workflowId,
      actorUserId: actorUserId,
      adminReason: adminReason,
    );
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: 'admin.pricing.cap_upserted',
      adminReason: adminReason,
      payload: <String, Object?>{
        'usage_class': usageClass,
        'monthly_cap_usd': monthlyCapUsd,
        'per_invocation_cap_usd': perInvocationCapUsd,
        if (staffId != null) 'staff_id': staffId,
        if (workflowId != null) 'workflow_id': workflowId,
      },
    );
    return cap.toJson();
  }

  @override
  Future<Map<String, Object?>?> applyTierTemplate({
    required String actorUserId,
    required String operatorId,
    required String tierKey,
    required String adminReason,
  }) async {
    final template = _kPricingTierTemplateCaps[tierKey];
    if (template == null) return null;
    // Validate every precondition BEFORE any write so a failure can
    // never leave the operator in a partial state (subscription_tier
    // updated but cap rows never seeded). Specifically: confirm the
    // operator exists, has a primary_location_id, and has a root
    // org_units row.
    final existing = await _operators.findById(
      operatorId: operatorId,
      adminReason: '$adminReason:lookup',
    );
    if (existing == null) return null;
    final primaryLocation = existing.primaryLocationId;
    if (primaryLocation == null) {
      throw const PricingTierAdminGatewayValidationError(
        statusCode: 400,
        code: 'no_primary_location',
        message:
            'operator must have a primary_location_id before a tier template can be applied',
      );
    }
    final orgUnitId = await _rootOrgUnitId(
      operatorId: operatorId,
      adminReason: adminReason,
    );
    final updatedOperator = await _operators.updateOperator(
      operatorId: operatorId,
      subscriptionTier: tierKey,
      adminReason: adminReason,
    );
    if (updatedOperator == null) return null;
    for (final cap in template) {
      await _caps.upsertCap(
        operatorId: operatorId,
        billingOwnerOrgUnitId: orgUnitId,
        scopedOrgUnitId: orgUnitId,
        locationId: primaryLocation,
        usageClass: cap.usageClass,
        monthlyCapUsd: cap.monthlyCapUsd,
        perInvocationCapUsd: cap.perInvocationCapUsd,
        actorUserId: actorUserId,
        adminReason: '$adminReason:${cap.usageClass}',
      );
    }
    await _audit(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: primaryLocation,
      eventType: 'admin.pricing.template_applied',
      adminReason: adminReason,
      payload: <String, Object?>{
        'tier_key': tierKey,
        'cap_rows': template.length,
      },
    );
    return _bundleFor(updatedOperator, adminReason: adminReason);
  }

  Future<Map<String, Object?>> _bundleFor(
    OperatorAdminRow operator, {
    required String adminReason,
  }) async {
    final caps = await _caps.listForOperator(
      operatorId: operator.operatorId,
      adminReason: '$adminReason:bundle:${operator.operatorId}',
    );
    return <String, Object?>{
      'operator': <String, Object?>{
        'operator_id': operator.operatorId,
        'business_name': operator.businessName,
        'subscription_tier': operator.subscriptionTier,
        'preferred_currency': operator.preferredCurrency,
        'primary_location_id': operator.primaryLocationId,
        'suspended': operator.suspendedAt != null,
      },
      'caps': <Map<String, Object?>>[for (final cap in caps) cap.toJson()],
    };
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    String? operatorId,
    String? locationId,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Production [CorpusAdminProxyGateway] backed by [CorpusRepository].
///
/// Live chunking, embedding generation, and Voyage / Anthropic calls
/// are out of scope for this slice — the production binding wires the
/// admin path against the repository's existing transactional commit
/// helper. The actual upload pipeline lights up in 11A.3b once the
/// markdown chunker is split out of `tool/advisor_corpus/main.dart`
/// into a server-side helper. The current binding rejects an upload
/// until that helper is wired so the route never silently writes an
/// empty version row in production.
class RepositoryCorpusAdminProxyGateway implements CorpusAdminProxyGateway {
  RepositoryCorpusAdminProxyGateway({
    required CorpusRepository corpusRepository,
    required AuthEventsAuditRepository auditRepository,
  })  : _corpus = corpusRepository,
        _auditRepository = auditRepository;

  final CorpusRepository _corpus;
  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<List<Map<String, Object?>>> listVersions({
    required String actorUserId,
    required String adminReason,
  }) async {
    final versions = await _corpus.listVersions(adminReason: adminReason);
    final payload = <Map<String, Object?>>[
      for (final v in versions) v.toJson(),
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.corpus.list',
      adminReason: adminReason,
      payload: <String, Object?>{'version_count': versions.length},
    );
    return payload;
  }

  @override
  Future<Map<String, Object?>?> fetchVersion({
    required String actorUserId,
    required String versionId,
    required String adminReason,
  }) async {
    final all = await _corpus.listVersions(adminReason: adminReason);
    CorpusVersionRow? ref;
    for (final v in all) {
      if (v.versionId == versionId) {
        ref = v;
        break;
      }
    }
    if (ref == null) return null;
    final chunks = await _corpus.chunksForVersion(
      versionId: versionId,
      adminReason: '$adminReason:chunks:$versionId',
    );
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.corpus.fetch',
      adminReason: adminReason,
      payload: <String, Object?>{
        'version_id': versionId,
        'chunk_count': chunks.length,
      },
    );
    return <String, Object?>{
      'version': <String, Object?>{
        ...ref.toJson(),
        'chunk_count': chunks.length,
      },
      'chunks': <Map<String, Object?>>[
        for (final c in chunks)
          <String, Object?>{
            ...c.toJson(),
            'snippet': c.text.length > 280
                ? '${c.text.substring(0, 280)}…'
                : c.text,
          },
      ],
    };
  }

  @override
  Future<Map<String, Object?>> previewDiff({
    required String actorUserId,
    required String fileName,
    required String contentType,
    required List<int> bytes,
    required String idempotencyKey,
    required String adminReason,
  }) {
    // 11A.3b owns the live chunker. Surface a typed validation error
    // so the screen renders the actionable banner instead of a 503.
    throw const CorpusAdminGatewayValidationError(
      statusCode: 503,
      code: 'corpus_pipeline_not_configured',
      message:
          'corpus upload pipeline ships in 11A.3b; '
          'demo mode runs the in-memory gateway end-to-end',
    );
  }

  @override
  Future<Map<String, Object?>> commitVersion({
    required String actorUserId,
    required String previewToken,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) {
    throw const CorpusAdminGatewayValidationError(
      statusCode: 503,
      code: 'corpus_pipeline_not_configured',
      message: 'corpus commit pipeline ships in 11A.3b',
    );
  }

  @override
  Future<Map<String, Object?>?> rollbackVersion({
    required String actorUserId,
    required String targetVersionId,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    // Forward the idempotency key into the repository so a retry
    // collapses to the same `corpus_versions` row. Without this, a
    // dropped response followed by a client retry would write a
    // second rollback ledger entry plus a second audit row, which
    // contradicts the slice's "same key → same response" promise.
    final result = await _corpus.rollbackToVersion(
      targetVersionId: targetVersionId,
      actorUserId: actorUserId,
      summary: summary.isEmpty
          ? 'Rolled back to $targetVersionId'
          : summary,
      adminReason: adminReason,
      idempotencyKey: idempotencyKey,
    );
    // Skip the audit insert on a cache replay — the prior request
    // that filled the cache already wrote the audit row, and writing
    // again would leave two audit entries for one logical change.
    if (!result.replayed) {
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.corpus.rollback',
        adminReason: adminReason,
        payload: <String, Object?>{
          'target_version_id': targetVersionId,
          'new_version_id': result.version.versionId,
          'idempotency_key': idempotencyKey,
        },
      );
    }
    return result.version.toJson();
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}


/// Stable status placeholders the Integrations screen renders for
/// non-rotatable rows (vendor connectors, FX-rate source, email
/// provider). The proxy answers `GET /v1/admin/integrations` with
/// these unchanged for the launch slice; later phases swap them out
/// for live status as those surfaces ship.
const List<Map<String, Object?>> _kIntegrationDefaultVendorConnectors =
    <Map<String, Object?>>[
  <String, Object?>{
    'id': 'connector_compeat',
    'display_name': 'Compeat connector',
    'status_label': 'placeholder',
    'detail_message': 'Vendor connector lights up in Phase 8.',
  },
  <String, Object?>{
    'id': 'connector_mp',
    'display_name': 'Marketman connector',
    'status_label': 'placeholder',
    'detail_message': 'Vendor connector lights up in Phase 8.',
  },
];

const Map<String, Object?> _kIntegrationDefaultFxRateSource = <String, Object?>{
  'id': 'fx_rate',
  'display_name': 'FX-rate source',
  'status_label': 'green',
  'detail_message': 'ECB daily reference feed (fallback active).',
};

const Map<String, Object?> _kIntegrationDefaultEmailProvider =
    <String, Object?>{
  'id': 'email',
  'display_name': 'Email provider',
  'status_label': 'placeholder',
  'detail_message': 'Email provider lands in Phase 9.8.',
};

/// Production [IntegrationAdminProxyGateway] backed by
/// [ProviderCredentialsRepository] + [KmsProvider]. Translates the
/// proxy's command shape into repo + KMS calls and projects the
/// result into JSON-ready maps the route handler can return as-is.
///
/// Plaintext is held in memory only for the duration of a single
/// rotation call; it is handed to the KMS provider, then returned
/// once on the response. The repository receives only the masked
/// display string and the KMS pointer.
class RepositoryIntegrationAdminProxyGateway
    implements IntegrationAdminProxyGateway {
  RepositoryIntegrationAdminProxyGateway({
    required ProviderCredentialsRepository providerCredentialsRepository,
    required KmsProvider kmsProvider,
    required AuthEventsAuditRepository auditRepository,
  }) : _credentials = providerCredentialsRepository,
       _kmsProvider = kmsProvider,
       _auditRepository = auditRepository;

  final ProviderCredentialsRepository _credentials;
  final KmsProvider _kmsProvider;
  final AuthEventsAuditRepository _auditRepository;

  @override
  Future<Map<String, Object?>> listBundle({
    required String actorUserId,
    required String adminReason,
  }) async {
    final rows = await _credentials.listActive(adminReason: adminReason);
    final keysJson = <Map<String, Object?>>[
      for (final row in rows) row.toJson(),
    ];
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.integrations.list',
      adminReason: adminReason,
      payload: <String, Object?>{
        'provider_key_count': rows.length,
      },
    );
    return <String, Object?>{
      'provider_keys': keysJson,
      'vendor_connectors': _kIntegrationDefaultVendorConnectors,
      'fx_rate_source': _kIntegrationDefaultFxRateSource,
      'email_provider': _kIntegrationDefaultEmailProvider,
    };
  }

  @override
  Future<Map<String, Object?>> rotateProviderKey({
    required String actorUserId,
    required String keyKind,
    required String plaintextValue,
    required String adminReason,
  }) async {
    if (!kProviderCredentialKinds.contains(keyKind)) {
      throw IntegrationAdminGatewayValidationError(
        statusCode: 400,
        code: 'unknown_key_kind',
        message: 'key_kind "$keyKind" is not a known provider lane',
      );
    }
    KmsWriteResult writeResult;
    try {
      writeResult = await _kmsProvider.writeSecret(
        logicalKeyKind: keyKind,
        plaintext: plaintextValue,
      );
    } on KmsWriteFailure catch (error) {
      // KMS write failed → no audit-success row, prior key stays
      // active (the repository was never called), and we record the
      // rotation_failed audit row before raising. The proxy maps the
      // validation error onto a 503 response.
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.integrations.rotation_failed',
        adminReason: adminReason,
        payload: <String, Object?>{
          'key_kind': keyKind,
          'failure_kind': 'kms_write_failed',
          'message': error.message,
        },
      );
      throw IntegrationAdminGatewayValidationError(
        statusCode: 503,
        code: 'kms_write_failed',
        message: error.message,
      );
    }
    final ProviderCredentialRow row;
    try {
      row = await _credentials.rotate(
        keyKind: keyKind,
        maskedValue: writeResult.maskedDisplay,
        kmsSecretName: writeResult.secretName,
        actorUserId: actorUserId,
        adminReason: adminReason,
      );
    } catch (error) {
      // Postgres write failed AFTER KMS succeeded — record the
      // failure so an operator can investigate the orphaned KMS
      // secret. Prior key stays active (the repository transaction
      // rolled back, so no `is_active` flip happened).
      await _audit(
        actorUserId: actorUserId,
        eventType: 'admin.integrations.rotation_failed',
        adminReason: adminReason,
        payload: <String, Object?>{
          'key_kind': keyKind,
          'failure_kind': 'persistence_failed',
          'kms_secret_name': writeResult.secretName,
          'message': error.toString(),
        },
      );
      rethrow;
    }
    await _audit(
      actorUserId: actorUserId,
      eventType: 'admin.integrations.rotation_success',
      adminReason: adminReason,
      payload: <String, Object?>{
        'key_kind': keyKind,
        'credential_id': row.credentialId,
        'kms_secret_name': row.kmsSecretName,
      },
    );
    return <String, Object?>{
      'row': row.toJson(),
      'plaintext_value': plaintextValue,
    };
  }

  Future<void> _audit({
    required String actorUserId,
    required String eventType,
    required String adminReason,
    Map<String, Object?> payload = const <String, Object?>{},
  }) {
    return _auditRepository.insertSystemEvent(
      actorUserId: actorUserId,
      eventType: eventType,
      adminReason: adminReason,
      payload: <String, Object?>{'admin_reason': adminReason, ...payload},
    );
  }
}

/// Production [IntegrationAdminActorResolver] backed by
/// [UsersRepository.findActiveUserIdByFirebaseUidSystem]. The lookup
/// runs through the admin pool because F&F admin actors are not in
/// any single operator's tenant scope.
class RepositoryIntegrationAdminActorResolver
    implements IntegrationAdminActorResolver {
  RepositoryIntegrationAdminActorResolver({
    required UsersRepository usersRepository,
  }) : _users = usersRepository;

  final UsersRepository _users;

  @override
  Future<String?> resolveActorUserId({
    required String firebaseUid,
    required String adminReason,
  }) {
    return _users.findActiveUserIdByFirebaseUidSystem(
      firebaseUid: firebaseUid,
      adminReason: adminReason,
    );
  }
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
        scopeType: row.scopeType,
        locationId: row.locationId,
        orgUnitId: row.orgUnitId,
        effectiveLocationIds: row.effectiveLocationIds,
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
