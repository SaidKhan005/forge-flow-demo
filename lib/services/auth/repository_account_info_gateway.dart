import '../../infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'account_info_gateway.dart';

class RepositoryAccountInfoGateway implements AccountInfoGateway {
  const RepositoryAccountInfoGateway({required UsersRepository usersRepository})
    : _usersRepository = usersRepository;

  final UsersRepository _usersRepository;

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
    );
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
