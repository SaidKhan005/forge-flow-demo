import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_tokens_repository.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart'
    show OAuthAccessTokenProvider;

class MobilePushGatewayException implements Exception {
  const MobilePushGatewayException({
    required this.statusCode,
    required this.code,
    required this.message,
  });

  final int statusCode;
  final String code;
  final String message;
}

abstract class MobilePushTokenGateway {
  Future<Map<String, Object?>> register({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });

  Future<int> revoke({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });
}

class RepositoryMobilePushTokenGateway implements MobilePushTokenGateway {
  RepositoryMobilePushTokenGateway({
    required MobilePushTokensRepository repository,
    required String tokenEnvelopeKey,
  }) : _repository = repository,
       _tokenEnvelopeKey = tokenEnvelopeKey;

  final MobilePushTokensRepository _repository;
  final String _tokenEnvelopeKey;

  @override
  Future<Map<String, Object?>> register({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final token = _requiredString(body, 'token');
    final platform = _requiredEnum(body, 'platform', const <String>{
      'ios',
      'android',
    });
    final provider = _optionalEnum(body, 'provider', const <String>{
      'fcm',
      'apns',
    }, fallback: 'fcm');
    final appVariant = _requiredIdentifier(body, 'app_variant');
    final appEnvironment = _requiredIdentifier(body, 'app_environment');
    final installationId = _requiredString(body, 'installation_id');
    final clientInfo = _optionalObject(body, 'client_info');
    final row = await _repository.register(
      MobilePushTokenRegistration(
        operatorId: operatorId,
        locationId: locationId,
        userId: actorUserId,
        token: token,
        platform: platform,
        provider: provider,
        appVariant: appVariant,
        appEnvironment: appEnvironment,
        installationId: installationId,
        envelopeKey: _tokenEnvelopeKey,
        clientInfo: clientInfo,
      ),
    );
    return row.toSafeJson();
  }

  @override
  Future<int> revoke({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) {
    final appVariant = _requiredIdentifier(body, 'app_variant');
    final appEnvironment = _requiredIdentifier(body, 'app_environment');
    final installationId = _optionalString(body, 'installation_id');
    final token = _optionalString(body, 'token');
    if (installationId == null && token == null) {
      throw const MobilePushGatewayException(
        statusCode: 400,
        code: 'missing_push_token_selector',
        message: 'installation_id or token is required',
      );
    }
    return _repository.revoke(
      MobilePushTokenRevokeCommand(
        operatorId: operatorId,
        locationId: locationId,
        userId: actorUserId,
        appVariant: appVariant,
        appEnvironment: appEnvironment,
        installationId: installationId,
        token: token,
      ),
    );
  }
}

abstract class MobilePushSelfTestGateway {
  Future<MobilePushDispatchSummary> sendSelfTest({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  });
}

class RepositoryMobilePushSelfTestGateway implements MobilePushSelfTestGateway {
  RepositoryMobilePushSelfTestGateway({
    required MobilePushTokensRepository tokensRepository,
    required MobilePushSender sender,
    required String tokenEnvelopeKey,
  }) : _tokensRepository = tokensRepository,
       _sender = sender,
       _tokenEnvelopeKey = tokenEnvelopeKey;

  final MobilePushTokensRepository _tokensRepository;
  final MobilePushSender _sender;
  final String _tokenEnvelopeKey;

  @override
  Future<MobilePushDispatchSummary> sendSelfTest({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> body,
  }) async {
    final appVariant = _requiredIdentifier(body, 'app_variant');
    final appEnvironment = _requiredIdentifier(body, 'app_environment');
    final title =
        _optionalString(body, 'title') ?? 'Forge & Flow notification test';
    final messageBody =
        _optionalString(body, 'body') ?? 'Your phone popup path is connected.';
    final tokens = await _tokensRepository.listSendableTokensForUser(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
      appVariant: appVariant,
      appEnvironment: appEnvironment,
      envelopeKey: _tokenEnvelopeKey,
    );

    var sentCount = 0;
    var failedCount = 0;
    for (final token in tokens) {
      try {
        await _sender.send(
          MobilePushSendRequest(
            token: token.token,
            platform: token.platform,
            title: title,
            body: messageBody,
            deeplink: 'forgeflow://notifications',
            data: const <String, Object?>{
              'notification_id': 'mobile_push_self_test',
              'source_topic': 'mobile_push.self_test',
            },
          ),
        );
        sentCount += 1;
        await _tokensRepository.markSent(
          operatorId: operatorId,
          locationId: locationId,
          userId: actorUserId,
          pushTokenId: token.pushTokenId,
        );
      } catch (_) {
        failedCount += 1;
      }
    }
    return MobilePushDispatchSummary(
      targetCount: tokens.length,
      sentCount: sentCount,
      failedCount: failedCount,
    );
  }
}

abstract class MobilePushSender {
  Future<MobilePushSendResult> send(MobilePushSendRequest request);
}

class MobilePushSendRequest {
  MobilePushSendRequest({
    required this.token,
    required this.platform,
    required this.title,
    required this.body,
    required Map<String, Object?> data,
    this.deeplink,
  }) : data = sanitizePushData(data);

  final String token;
  final String platform;
  final String title;
  final String body;
  final String? deeplink;
  final Map<String, String> data;

  Map<String, Object?> toFcmHttpV1Json() {
    final message = <String, Object?>{
      'token': token,
      'notification': <String, Object?>{'title': title, 'body': body},
      if (data.isNotEmpty || deeplink != null)
        'data': <String, String>{
          ...data,
          if (deeplink != null) 'deeplink': deeplink!,
        },
    };
    if (platform == 'ios') {
      message['apns'] = <String, Object?>{
        'headers': <String, String>{'apns-priority': '10'},
        'payload': <String, Object?>{
          'aps': <String, Object?>{'sound': 'default'},
        },
      };
    } else if (platform == 'android') {
      message['android'] = <String, Object?>{'priority': 'HIGH'};
    }
    return <String, Object?>{'message': message};
  }
}

class MobilePushSendResult {
  const MobilePushSendResult({this.providerMessageId});

  final String? providerMessageId;
}

class FcmHttpV1MobilePushSender implements MobilePushSender {
  FcmHttpV1MobilePushSender({
    required this.firebaseProjectId,
    required OAuthAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 10),
  }) : _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client();

  final String firebaseProjectId;
  final OAuthAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final Duration timeout;

  @override
  Future<MobilePushSendResult> send(MobilePushSendRequest request) async {
    final accessToken = await _accessTokenProvider.accessToken();
    final uri = Uri.https(
      'fcm.googleapis.com',
      '/v1/projects/$firebaseProjectId/messages:send',
    );
    final response = await _httpClient
        .post(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $accessToken',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
          },
          body: jsonEncode(request.toFcmHttpV1Json()),
        )
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MobilePushGatewayException(
        statusCode: 503,
        code: 'fcm_send_failed',
        message: 'FCM send failed with status ${response.statusCode}',
      );
    }
    final decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    String? name;
    if (decoded is Map) {
      final raw = decoded['name'];
      if (raw is String && raw.isNotEmpty) name = raw;
    }
    return MobilePushSendResult(providerMessageId: name);
  }
}

class MobilePushDispatcher {
  MobilePushDispatcher({
    required MobilePushTokensRepository tokensRepository,
    required MobilePushOutboxRepository outboxRepository,
    required MobilePushSender sender,
    required String tokenEnvelopeKey,
  }) : _tokensRepository = tokensRepository,
       _outboxRepository = outboxRepository,
       _sender = sender,
       _tokenEnvelopeKey = tokenEnvelopeKey;

  final MobilePushTokensRepository _tokensRepository;
  final MobilePushOutboxRepository _outboxRepository;
  final MobilePushSender _sender;
  final String _tokenEnvelopeKey;

  Future<MobilePushDispatchSummary> dispatch({
    required String locationId,
    required MobilePushOutboxMessage message,
  }) async {
    final tokens = await _tokensRepository.listSendableTokensForUser(
      operatorId: message.operatorId,
      locationId: locationId,
      userId: message.userId,
      appVariant: message.appVariant,
      appEnvironment: message.appEnvironment,
      envelopeKey: _tokenEnvelopeKey,
    );

    var sentCount = 0;
    var failedCount = 0;
    String? lastError;
    for (final token in tokens) {
      try {
        await _sender.send(
          MobilePushSendRequest(
            token: token.token,
            platform: token.platform,
            title: message.title,
            body: message.body,
            deeplink: message.deeplink,
            data: <String, Object?>{
              ...message.data,
              'message_id': message.messageId,
              'dedupe_key': message.dedupeKey,
              if (message.sourceTopic != null)
                'source_topic': message.sourceTopic,
            },
          ),
        );
        sentCount += 1;
        await _tokensRepository.markSent(
          operatorId: message.operatorId,
          locationId: locationId,
          userId: message.userId,
          pushTokenId: token.pushTokenId,
        );
      } catch (error) {
        failedCount += 1;
        lastError = error is MobilePushGatewayException
            ? error.code
            : error.runtimeType.toString();
      }
    }
    await _outboxRepository.markResult(
      operatorId: message.operatorId,
      locationId: locationId,
      userId: message.userId,
      messageId: message.messageId,
      targetCount: tokens.length,
      sentCount: sentCount,
      failedCount: failedCount,
      lastError: lastError,
    );
    return MobilePushDispatchSummary(
      targetCount: tokens.length,
      sentCount: sentCount,
      failedCount: failedCount,
    );
  }
}

class MobilePushDispatchSummary {
  const MobilePushDispatchSummary({
    required this.targetCount,
    required this.sentCount,
    required this.failedCount,
  });

  final int targetCount;
  final int sentCount;
  final int failedCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_count': targetCount,
    'sent_count': sentCount,
    'failed_count': failedCount,
  };
}

Map<String, String> sanitizePushData(Map<String, Object?> data) {
  final result = <String, String>{};
  for (final entry in data.entries) {
    final key = entry.key.trim();
    if (key.isEmpty) continue;
    if (_looksSensitiveKey(key)) {
      throw MobilePushGatewayException(
        statusCode: 400,
        code: 'push_payload_contains_secret_key',
        message: 'push payload data contains a secret-shaped key',
      );
    }
    final value = entry.value;
    if (value == null) continue;
    if (value is Map || value is Iterable) {
      throw MobilePushGatewayException(
        statusCode: 400,
        code: 'push_payload_data_must_be_flat',
        message: 'push payload data values must be scalar',
      );
    }
    result[key] = value.toString();
  }
  return Map<String, String>.unmodifiable(result);
}

final RegExp _identifierPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

const List<String> _sensitiveKeyFragments = <String>[
  'token',
  'secret',
  'password',
  'authorization',
  'api_key',
  'private_key',
  'refresh_token',
  'access_token',
  'client_secret',
];

bool _looksSensitiveKey(String key) {
  final normalized = key.toLowerCase();
  return _sensitiveKeyFragments.any(normalized.contains);
}

String _requiredString(Map<String, Object?> body, String field) {
  final value = _optionalString(body, field);
  if (value == null) {
    throw MobilePushGatewayException(
      statusCode: 400,
      code: 'missing_$field',
      message: '$field is required',
    );
  }
  return value;
}

String? _optionalString(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _requiredEnum(
  Map<String, Object?> body,
  String field,
  Set<String> allowed,
) {
  final value = _requiredString(body, field).toLowerCase();
  if (!allowed.contains(value)) {
    throw MobilePushGatewayException(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field is invalid',
    );
  }
  return value;
}

String _optionalEnum(
  Map<String, Object?> body,
  String field,
  Set<String> allowed, {
  required String fallback,
}) {
  final value = _optionalString(body, field)?.toLowerCase();
  if (value == null) return fallback;
  if (!allowed.contains(value)) {
    throw MobilePushGatewayException(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field is invalid',
    );
  }
  return value;
}

String _requiredIdentifier(Map<String, Object?> body, String field) {
  final value = _requiredString(body, field).toLowerCase();
  if (!_identifierPattern.hasMatch(value)) {
    throw MobilePushGatewayException(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be lower_snake_case',
    );
  }
  return value;
}

Map<String, Object?> _optionalObject(Map<String, Object?> body, String field) {
  final raw = body[field];
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map) {
    throw MobilePushGatewayException(
      statusCode: 400,
      code: 'invalid_$field',
      message: '$field must be an object',
    );
  }
  return raw.map((key, value) => MapEntry(key.toString(), value));
}
