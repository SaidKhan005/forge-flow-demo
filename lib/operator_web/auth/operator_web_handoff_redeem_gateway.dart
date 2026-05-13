// Slice C-5 - Operator Web handoff redemption gateway.
//
// Web-safe adapter for POST /v1/auth/handoff/redeem. The browser may
// land on `/handoff?code=...&nav=...`, but this gateway sends the code
// to the proxy in a JSON body only. Step-up challenge ids, when emitted
// by later sensitive operations, stay in request headers through the
// existing step-up handler.

import '../services/operator_web_proxy_client.dart';

class OperatorWebHandoffRedeemResult {
  const OperatorWebHandoffRedeemResult({
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.targetPath,
  });

  final String userId;
  final String operatorId;
  final String locationId;
  final String targetPath;
}

class OperatorWebHandoffRedeemRejected implements Exception {
  const OperatorWebHandoffRedeemRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() =>
      'OperatorWebHandoffRedeemRejected($statusCode $code): $message';
}

abstract class OperatorWebHandoffRedeemGateway {
  Future<OperatorWebHandoffRedeemResult> redeemHandoffCode({
    required String code,
  });
}

abstract class OperatorWebHandoffRedeemGatewayProvider {
  OperatorWebHandoffRedeemGateway get handoffRedeemGateway;
}

class ProxyOperatorWebHandoffRedeemGateway
    implements OperatorWebHandoffRedeemGateway {
  ProxyOperatorWebHandoffRedeemGateway({
    required OperatorWebProxyClient client,
    required Future<String?> Function() idTokenProvider,
  }) : _client = client,
       _idTokenProvider = idTokenProvider;

  static const String redeemPath = '/v1/auth/handoff/redeem';

  final OperatorWebProxyClient _client;
  final Future<String?> Function() _idTokenProvider;

  @override
  Future<OperatorWebHandoffRedeemResult> redeemHandoffCode({
    required String code,
  }) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const OperatorWebHandoffRedeemRejected(
        code: 'no_id_token',
        message: 'You need to be signed in to complete the handoff.',
        statusCode: 401,
      );
    }
    final OperatorWebJsonResponse response;
    try {
      response = await _client.postJson(
        redeemPath,
        idToken: token,
        body: <String, Object?>{'code': code},
      );
    } on OperatorWebProxyException catch (error) {
      throw OperatorWebHandoffRedeemRejected(
        code: error.code,
        message: error.message,
        statusCode: error.statusCode ?? 500,
      );
    }

    final userId = _readString(response.body['user_id']);
    final operatorId = _readString(response.body['operator_id']);
    final locationId = _readString(response.body['location_id']);
    final targetPath = _readString(response.body['target_path']);
    if (userId == null ||
        operatorId == null ||
        locationId == null ||
        targetPath == null) {
      throw const OperatorWebHandoffRedeemRejected(
        code: 'malformed_redeem_response',
        message:
            'The handoff service returned an unexpected response. Please sign in again.',
        statusCode: 502,
      );
    }
    return OperatorWebHandoffRedeemResult(
      userId: userId,
      operatorId: operatorId,
      locationId: locationId,
      targetPath: targetPath,
    );
  }

  static String? _readString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
