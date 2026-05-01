import 'dart:async';
import 'dart:io';

import 'account_info_gateway.dart';
import 'proxy_auth_operations_gateway.dart';

class ProxyAccountInfoError implements Exception {
  const ProxyAccountInfoError({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() =>
      'ProxyAccountInfoError(code: $code, status: $statusCode, '
      'message: $message)';
}

class ProxyAccountInfoGateway implements AccountInfoGateway {
  ProxyAccountInfoGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required ProxyAuthOperationsHttpClient httpClient,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient;

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final ProxyAuthOperationsHttpClient _httpClient;

  static const String accountPath = '/v1/auth/account';

  @override
  Future<AccountInfo> load(AccountInfoRequest request) async {
    final token = await _idTokenProvider();
    if (token == null || token.trim().isEmpty) {
      throw const ProxyAccountInfoError(
        code: 'no_id_token',
        message: 'account info has no live Firebase ID token',
      );
    }

    ProxyAuthOperationsResponse response;
    try {
      response = await _httpClient.getJson(
        url: _proxyBaseUri.resolve(accountPath),
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer ${token.trim()}',
        },
      );
    } on ProxyAccountInfoError {
      rethrow;
    } catch (error) {
      throw ProxyAccountInfoError(
        code: 'transport_error',
        message:
            'proxy account info failed before reaching the proxy '
            '(${_describeTransportError(error)})',
      );
    }

    if (response.statusCode != 200) {
      throw ProxyAccountInfoError(
        code: _errorCode(response.body),
        message: 'account info request failed',
        statusCode: response.statusCode,
      );
    }

    try {
      return AccountInfo.fromJson(response.body);
    } on AccountInfoUnavailable catch (error) {
      throw ProxyAccountInfoError(
        code: error.code,
        message: 'account info response was incomplete',
        statusCode: response.statusCode,
      );
    }
  }

  static String _errorCode(Map<String, Object?> body) {
    final error = body['error'];
    return error is String && error.trim().isNotEmpty
        ? error.trim()
        : 'account_info_failed';
  }

  static String _describeTransportError(Object error) {
    if (error is TimeoutException) return 'timeout';
    if (error is SocketException) return 'socket';
    if (error is HttpException) return 'http';
    if (error is HandshakeException) return 'tls';
    if (error is OSError) return 'os';
    return 'transport';
  }
}
