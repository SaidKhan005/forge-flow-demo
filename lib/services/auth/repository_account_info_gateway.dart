import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/feature_entitlements_repository.dart';
import '../../infrastructure/persistence/postgres/repositories/pricing_contract_overrides_repository.dart';
import 'account_info_gateway.dart';

class RepositoryAccountInfoGateway implements AccountInfoGateway {
  const RepositoryAccountInfoGateway({
    required UsersRepository usersRepository,
    AccountPlanSnapshotResolver? planSnapshotResolver,
  }) : _usersRepository = usersRepository,
       _planSnapshotResolver = planSnapshotResolver;

  final UsersRepository _usersRepository;
  final AccountPlanSnapshotResolver? _planSnapshotResolver;

  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    final row = await _usersRepository.findSelfProfile(
      operatorId: request.operatorId,
      locationId: request.locationId,
      actorUserId: request.actorUserId,
    );
    if (row == null) {
      throw const AccountInfoUnavailable(
        code: 'account_not_found',
        message: 'account info is unavailable',
      );
    }
    final planSnapshot = await _loadPlanSnapshot(
      operatorId: request.operatorId,
      locationId: request.locationId,
      fallbackTierKey: row.subscriptionTier,
    );
    return AccountInfo(
      displayName: _nonBlankOr(row.displayName, row.email),
      email: row.email,
      statusLabel: _statusLabel(row.status),
      locationLabel: _nonBlankOr(row.locationLabel, 'Current location'),
      roleLabels: List<String>.unmodifiable(
        row.roleLabels
            .map(_friendlyRoleLabel)
            .where((label) => label.isNotEmpty),
      ),
      mfaEnabled: row.mfaEnabled,
      lastActiveAt: row.lastActiveAt,
      lastLoginAt: row.lastLoginAt,
      passwordUpdatedAt: row.passwordUpdatedAt,
      logoUrl: row.logoUrl,
      // Plans & Limits Phase 5b follow-up — carry the operator's own
      // plan + trial (read from the operator-scoped `operators` join in
      // findSelfProfile) onto the account read so the operator-web
      // "Your plan" screen lights up on live.
      subscriptionTier: row.subscriptionTier,
      trialMode: row.trialMode,
      trialExpiresAt: row.trialExpiresAt,
      planSnapshot: planSnapshot,
    );
  }

  Future<AccountPlanSnapshot?> _loadPlanSnapshot({
    required String operatorId,
    required String locationId,
    required String? fallbackTierKey,
  }) async {
    final resolver = _planSnapshotResolver;
    if (resolver == null) return null;
    try {
      return await resolver.resolve(
        operatorId: operatorId,
        locationId: locationId,
        fallbackTierKey: fallbackTierKey,
      );
    } catch (_) {
      return null;
    }
  }

  static String _statusLabel(String status) {
    return switch (status.trim()) {
      'active' => 'Active',
      'invited' => 'Invited',
      'suspended' => 'Suspended',
      'dormant_30' || 'dormant_60' || 'dormant_90' => 'Dormant',
      'deleted' => 'Closed',
      _ => 'Available',
    };
  }

  static String _friendlyRoleLabel(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.contains('.')) return '';
    if (!trimmed.contains('_')) return trimmed;
    return trimmed
        .split('_')
        .where((part) => part.isNotEmpty)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join(' ');
  }

  static String _nonBlankOr(String? value, String fallback) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? fallback : trimmed;
  }
}

class RepositoryAccountPlanSnapshotResolver
    implements AccountPlanSnapshotResolver {
  const RepositoryAccountPlanSnapshotResolver({
    required FeatureEntitlementsRepository entitlementsRepository,
    required PricingContractOverridesRepository contractOverridesRepository,
  }) : _entitlementsRepository = entitlementsRepository,
       _contractOverridesRepository = contractOverridesRepository;

  final FeatureEntitlementsRepository _entitlementsRepository;
  final PricingContractOverridesRepository _contractOverridesRepository;

  @override
  Future<AccountPlanSnapshot?> resolve({
    required String operatorId,
    required String locationId,
    required String? fallbackTierKey,
  }) async {
    final resolution = await _contractOverridesRepository.resolveEffective(
      operatorId: operatorId,
      selectedScope: PricingContractScopeTarget.location(
        locationId: locationId,
      ),
      adminReason: 'auth.account.plan_snapshot',
    );
    final effective = resolution?.effective;
    final tierKey = _firstNonBlank(effective?.tierKey, fallbackTierKey);
    if (tierKey == null) return null;
    final entitlements = await _entitlementsRepository.listEntitlements(
      reason: 'auth.account.plan_snapshot.entitlements',
    );
    final enabledFeatureSlugs = <String>[
      for (final row in entitlements)
        if (row.tierKey == tierKey && row.enabled) row.featureSlug,
    ];
    return AccountPlanSnapshot(
      tierKey: tierKey,
      enabledFeatureSlugs: List<String>.unmodifiable(enabledFeatureSlugs),
      priceLine: effective == null ? null : _priceLine(effective),
      sourceLabel: resolution?.inheritedSource.sourceLabel,
      contractLabel: _blankToNull(effective?.contractLabel),
      overrideStatus: resolution?.overrideStatus.wireName,
    );
  }

  static String? _priceLine(PricingContractTerms terms) {
    final monthly = _money(terms.monthlyUsd);
    if (monthly == null) {
      return _firstNonBlank(terms.contractLabel, 'Custom contract');
    }
    final firstSeat = _money(terms.firstSeatUsd);
    if (firstSeat == null || terms.firstNSeats == null) {
      return '$monthly/mo';
    }
    final additionalSeat = _money(terms.additionalSeatUsd);
    if (additionalSeat == null || additionalSeat == firstSeat) {
      return '$monthly/mo plus $firstSeat/seat';
    }
    return '$monthly/mo plus $firstSeat/$additionalSeat seat';
  }

  static String? _money(num? value) {
    if (value == null) return null;
    final normalized = value.toDouble();
    final dollars = normalized == normalized.roundToDouble()
        ? normalized.toStringAsFixed(0)
        : normalized.toStringAsFixed(2);
    return '\$$dollars';
  }

  static String? _firstNonBlank(String? first, String? second) =>
      _blankToNull(first) ?? _blankToNull(second);

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
