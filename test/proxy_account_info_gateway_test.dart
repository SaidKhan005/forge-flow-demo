// Phase 9.UX account-info proxy client tests.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_account_info_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyAccountInfoGateway', () {
    test('loads self account info from the authenticated route', () async {
      final fake = _FakeAccountInfoHttpClient(
        getResponse: ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{
            'display_name': 'Jane Operator',
            'email': 'jane@example.test',
            'status_label': 'Active',
            'location_label': 'Downtown',
            'role_labels': <Object?>['Kitchen Lead', 'Owner'],
            'mfa_enabled': true,
            'last_login_at': DateTime.utc(2026, 4, 28, 11).toIso8601String(),
            'last_active_at': DateTime.utc(2026, 4, 28, 12).toIso8601String(),
            'password_updated_at': DateTime.utc(
              2026,
              4,
              20,
              9,
            ).toIso8601String(),
          },
        ),
      );
      final gateway = ProxyAccountInfoGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final info = await gateway.load(_request);

      expect(info.displayName, equals('Jane Operator'));
      expect(info.roleLabels, equals(<String>['Kitchen Lead', 'Owner']));
      expect(info.mfaEnabled, isTrue);
      expect(info.lastLoginAt, equals(DateTime.utc(2026, 4, 28, 11)));
      final call = fake.gets.single;
      expect(call.url.path, equals(ProxyAccountInfoGateway.accountPath));
      expect(
        call.headers[HttpHeaders.authorizationHeader],
        equals('Bearer id-token'),
      );
    });

    test('missing ID token fails before network', () async {
      final fake = _FakeAccountInfoHttpClient();
      final gateway = ProxyAccountInfoGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final thrown = await _captureError(gateway.load(_request));

      expect(thrown, isA<ProxyAccountInfoError>());
      expect((thrown! as ProxyAccountInfoError).code, equals('no_id_token'));
      expect(fake.gets, isEmpty);
    });

    test('proxy rejection maps to narrow safe error', () async {
      final fake = _FakeAccountInfoHttpClient(
        getResponse: const ProxyAuthOperationsResponse(
          statusCode: 503,
          body: <String, Object?>{
            'error': 'account_info_unavailable',
            'message': 'database table names are not exposed to the UI',
          },
        ),
      );
      final gateway = ProxyAccountInfoGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(gateway.load(_request));

      expect(thrown, isA<ProxyAccountInfoError>());
      final error = thrown! as ProxyAccountInfoError;
      expect(error.code, equals('account_info_unavailable'));
      expect(error.statusCode, equals(503));
      expect(error.message, equals('account info request failed'));
    });

    test(
      'malformed payload fails closed without leaking response details',
      () async {
        final fake = _FakeAccountInfoHttpClient(
          getResponse: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'display_name': 'Jane Operator'},
          ),
        );
        final gateway = ProxyAccountInfoGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final thrown = await _captureError(gateway.load(_request));

        expect(thrown, isA<ProxyAccountInfoError>());
        final error = thrown! as ProxyAccountInfoError;
        expect(error.code, equals('malformed_response'));
        expect(error.message.contains('display_name'), isFalse);
      },
    );

    test('transport failures collapse to transport_error', () async {
      final fake = _FakeAccountInfoHttpClient.throws(
        StateError('postgres://secret-dsn'),
      );
      final gateway = ProxyAccountInfoGateway(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final thrown = await _captureError(gateway.load(_request));

      expect(thrown, isA<ProxyAccountInfoError>());
      final error = thrown! as ProxyAccountInfoError;
      expect(error.code, equals('transport_error'));
      expect(error.message.contains('postgres://secret-dsn'), isFalse);
    });
  });
}

const _request = AccountInfoRequest(
  actorUserId: 'user-1',
  operatorId: 'op-1',
  locationId: 'loc-1',
);

Future<Object?> _captureError(Future<dynamic> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _FakeAccountInfoHttpClient implements ProxyAuthOperationsHttpClient {
  _FakeAccountInfoHttpClient({
    this.getResponse = const ProxyAuthOperationsResponse(
      statusCode: 200,
      body: <String, Object?>{
        'display_name': 'Jane Operator',
        'email': 'jane@example.test',
        'status_label': 'Active',
        'location_label': 'Downtown',
        'role_labels': <Object?>[],
        'mfa_enabled': false,
      },
    ),
  });

  _FakeAccountInfoHttpClient.throws(Object error)
    : getResponse = null,
      _error = error;

  final ProxyAuthOperationsResponse? getResponse;
  Object? _error;
  final gets = <_CapturedGet>[];

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    final error = _error;
    if (error != null) throw error;
    gets.add(_CapturedGet(url: url, headers: headers));
    return getResponse!;
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    throw UnimplementedError();
  }
}

class _CapturedGet {
  const _CapturedGet({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}
