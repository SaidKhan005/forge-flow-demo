import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';

class MobilePushTokenRegistration {
  const MobilePushTokenRegistration({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.token,
    required this.platform,
    required this.provider,
    required this.appVariant,
    required this.appEnvironment,
    required this.installationId,
    required this.envelopeKey,
    this.clientInfo = const <String, Object?>{},
  });

  final String operatorId;
  final String locationId;
  final String userId;
  final String token;
  final String platform;
  final String provider;
  final String appVariant;
  final String appEnvironment;
  final String installationId;
  final String envelopeKey;
  final Map<String, Object?> clientInfo;
}

class MobilePushTokenRevokeCommand {
  const MobilePushTokenRevokeCommand({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.appVariant,
    required this.appEnvironment,
    this.installationId,
    this.token,
  });

  final String operatorId;
  final String locationId;
  final String userId;
  final String appVariant;
  final String appEnvironment;
  final String? installationId;
  final String? token;
}

class MobilePushTokenRow {
  const MobilePushTokenRow({
    required this.pushTokenId,
    required this.operatorId,
    required this.userId,
    required this.platform,
    required this.provider,
    required this.appVariant,
    required this.appEnvironment,
    required this.installationId,
    required this.tokenHash,
    required this.enabledAt,
    required this.revokedAt,
    required this.lastSeenAt,
    required this.lastSentAt,
  });

  final String pushTokenId;
  final String operatorId;
  final String userId;
  final String platform;
  final String provider;
  final String appVariant;
  final String appEnvironment;
  final String installationId;
  final String tokenHash;
  final DateTime enabledAt;
  final DateTime? revokedAt;
  final DateTime lastSeenAt;
  final DateTime? lastSentAt;

  Map<String, Object?> toSafeJson() => <String, Object?>{
    'push_token_id': pushTokenId,
    'platform': platform,
    'provider': provider,
    'app_variant': appVariant,
    'app_environment': appEnvironment,
    'installation_id': installationId,
    'enabled_at': enabledAt.toUtc().toIso8601String(),
    'revoked_at': revokedAt?.toUtc().toIso8601String(),
    'last_seen_at': lastSeenAt.toUtc().toIso8601String(),
    'last_sent_at': lastSentAt?.toUtc().toIso8601String(),
  };
}

class MobilePushSendableToken {
  const MobilePushSendableToken({
    required this.pushTokenId,
    required this.userId,
    required this.platform,
    required this.provider,
    required this.appVariant,
    required this.appEnvironment,
    required this.token,
  });

  final String pushTokenId;
  final String userId;
  final String platform;
  final String provider;
  final String appVariant;
  final String appEnvironment;
  final String token;
}

class MobilePushTokensRepository extends OperatorScopedRepository {
  MobilePushTokensRepository(super.tenantWrapper);

  static const String _selectColumns =
      'push_token_id::text as push_token_id, '
      'operator_id::text as operator_id, '
      'user_id::text as user_id, '
      'platform, '
      'provider, '
      'app_variant, '
      'app_environment, '
      'installation_id, '
      'token_hash, '
      'enabled_at, '
      'revoked_at, '
      'last_seen_at, '
      'last_sent_at';

  Future<MobilePushTokenRow> register(MobilePushTokenRegistration command) {
    final tokenHash = hashPushToken(command.token);
    final tokenLastFour = _lastFour(command.token);
    final ctx = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.userId,
    );
    return withTenant<MobilePushTokenRow>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into public.mobile_push_tokens ('
        'operator_id, user_id, platform, provider, app_variant, '
        'app_environment, installation_id, token_hash, token_ciphertext, '
        'token_last_four, client_info'
        ') values ('
        '@operator_id::uuid, @user_id::uuid, @platform, @provider, '
        '@app_variant, @app_environment, @installation_id, @token_hash, '
        'pgp_sym_encrypt(@token_plaintext, @envelope_key), '
        '@token_last_four, @client_info::jsonb'
        ') on conflict ('
        'operator_id, user_id, app_variant, app_environment, installation_id'
        ') do update set '
        'platform = excluded.platform, '
        'provider = excluded.provider, '
        'token_hash = excluded.token_hash, '
        'token_ciphertext = excluded.token_ciphertext, '
        'token_last_four = excluded.token_last_four, '
        'client_info = excluded.client_info, '
        'enabled_at = case '
        '  when public.mobile_push_tokens.revoked_at is not null '
        '    or public.mobile_push_tokens.disabled_at is not null '
        '  then now() '
        '  else public.mobile_push_tokens.enabled_at '
        'end, '
        'disabled_at = null, '
        'revoked_at = null, '
        'last_registered_at = now(), '
        'last_seen_at = now(), '
        'updated_at = now() '
        'returning $_selectColumns',
        parameters: <String, Object?>{
          'operator_id': command.operatorId,
          'user_id': command.userId,
          'platform': command.platform,
          'provider': command.provider,
          'app_variant': command.appVariant,
          'app_environment': command.appEnvironment,
          'installation_id': command.installationId,
          'token_hash': tokenHash,
          'token_plaintext': command.token,
          'envelope_key': command.envelopeKey,
          'token_last_four': tokenLastFour,
          'client_info': jsonEncode(command.clientInfo),
        },
      );
      if (rows.isEmpty) {
        throw StateError('mobile push token registration returned no rows');
      }
      return _tokenRowFromMap(rows.single);
    });
  }

  Future<int> revoke(MobilePushTokenRevokeCommand command) {
    final conditions = <String>[];
    final parameters = <String, Object?>{
      'operator_id': command.operatorId,
      'user_id': command.userId,
      'app_variant': command.appVariant,
      'app_environment': command.appEnvironment,
    };
    final installationId = _trimmed(command.installationId);
    if (installationId != null) {
      conditions.add('installation_id = @installation_id');
      parameters['installation_id'] = installationId;
    }
    final token = _trimmed(command.token);
    if (token != null) {
      conditions.add('token_hash = @token_hash');
      parameters['token_hash'] = hashPushToken(token);
    }
    if (conditions.isEmpty) {
      throw ArgumentError(
        'mobile push token revoke requires installationId or token',
      );
    }
    final ctx = TenantContext(
      operatorId: command.operatorId,
      locationId: command.locationId,
      userId: command.userId,
    );
    final selector = conditions.join(' or ');
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update public.mobile_push_tokens '
        'set revoked_at = coalesce(revoked_at, now()), '
        '    disabled_at = coalesce(disabled_at, now()), '
        '    updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and user_id = @user_id::uuid '
        '  and app_variant = @app_variant '
        '  and app_environment = @app_environment '
        '  and revoked_at is null '
        '  and ($selector)',
        parameters: parameters,
      );
    });
  }

  Future<List<MobilePushSendableToken>> listSendableTokensForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required String appVariant,
    required String appEnvironment,
    required String envelopeKey,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<List<MobilePushSendableToken>>(ctx, (exec) async {
      final rows = await exec.query(
        'select '
        'push_token_id::text as push_token_id, '
        'user_id::text as user_id, '
        'platform, provider, app_variant, app_environment, '
        'pgp_sym_decrypt(token_ciphertext, @envelope_key) as token_plaintext '
        'from public.mobile_push_tokens '
        'where operator_id = @operator_id::uuid '
        '  and user_id = @user_id::uuid '
        '  and app_variant = @app_variant '
        '  and app_environment = @app_environment '
        '  and revoked_at is null '
        '  and disabled_at is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
          'app_variant': appVariant,
          'app_environment': appEnvironment,
          'envelope_key': envelopeKey,
        },
      );
      return rows.map(_sendableFromMap).toList(growable: false);
    });
  }

  Future<int> markSent({
    required String operatorId,
    required String locationId,
    required String userId,
    required String pushTokenId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    return withTenant<int>(ctx, (exec) {
      return exec.execute(
        'update public.mobile_push_tokens '
        'set last_sent_at = now(), last_seen_at = now(), updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and user_id = @user_id::uuid '
        '  and push_token_id = @push_token_id::uuid '
        '  and revoked_at is null',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'user_id': userId,
          'push_token_id': pushTokenId,
        },
      );
    });
  }

  static String hashPushToken(String token) {
    return sha256.convert(utf8.encode(token.trim())).toString();
  }
}

MobilePushTokenRow _tokenRowFromMap(PostgresRow row) {
  return MobilePushTokenRow(
    pushTokenId: row['push_token_id']! as String,
    operatorId: row['operator_id']! as String,
    userId: row['user_id']! as String,
    platform: row['platform']! as String,
    provider: row['provider']! as String,
    appVariant: row['app_variant']! as String,
    appEnvironment: row['app_environment']! as String,
    installationId: row['installation_id']! as String,
    tokenHash: row['token_hash']! as String,
    enabledAt: _toDateTime(row['enabled_at'])!,
    revokedAt: _toDateTime(row['revoked_at']),
    lastSeenAt: _toDateTime(row['last_seen_at'])!,
    lastSentAt: _toDateTime(row['last_sent_at']),
  );
}

MobilePushSendableToken _sendableFromMap(PostgresRow row) {
  final token = row['token_plaintext'];
  if (token is! String || token.isEmpty) {
    throw StateError('mobile push token decrypt returned malformed token');
  }
  return MobilePushSendableToken(
    pushTokenId: row['push_token_id']! as String,
    userId: row['user_id']! as String,
    platform: row['platform']! as String,
    provider: row['provider']! as String,
    appVariant: row['app_variant']! as String,
    appEnvironment: row['app_environment']! as String,
    token: token,
  );
}

String? _trimmed(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _lastFour(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length <= 4 ? trimmed : trimmed.substring(trimmed.length - 4);
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value.toUtc();
  if (value is String) {
    return value.isEmpty ? null : DateTime.parse(value).toUtc();
  }
  return null;
}
