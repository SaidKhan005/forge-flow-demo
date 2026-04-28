// Phase 9 auth-ops binding - app-side permission snapshot loader tests.
//
// Covers the client bridge that lets live Settings read server-resolved
// permissions after Firebase sign-in. No live HTTP or Firebase calls.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/services/auth/proxy_permission_snapshot_loader.dart';

import '../tool/advisor_proxy/advisor_proxy.dart' as proxy;

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('ProxyPermissionContextLoader', () {
    test('snapshot path matches proxy route contract', () {
      expect(
        ProxyPermissionContextLoader.snapshotPath,
        equals(proxy.authPermissionsSnapshotPath),
      );
    });

    test(
      'loads snapshot, validates scope, and maps permission effects',
      () async {
        final fake = _FakePermissionSnapshotHttpClient(
          response: ProxyPermissionSnapshotResponse(
            statusCode: 200,
            body: <String, Object?>{
              'user_id': 'user_1',
              'operator_id': 'op_1',
              'location_id': 'loc_1',
              'roles_version': 4,
              'evaluated_at': DateTime.utc(2026, 4, 28, 12).toIso8601String(),
              'permissions': const <String, Object?>{
                'team.users.view': 'allow',
                'team.users.invite': 'deny',
                'ignored.weird': 'bogus',
              },
              'requires_mfa': const <String>['billing.manage'],
            },
          ),
        );
        final loader = ProxyPermissionContextLoader(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
        );

        final context = await loader.load(_session());

        expect(context, isNotNull);
        expect(context!.snapshot.userId, equals('user_1'));
        expect(context.snapshot.rolesVersion, equals(4));
        expect(
          context.snapshot.entries['team.users.view'],
          equals(PermissionEffect.allow),
        );
        expect(
          context.snapshot.entries['team.users.invite'],
          equals(PermissionEffect.deny),
        );
        expect(context.snapshot.entries.containsKey('ignored.weird'), isFalse);
        expect(context.requiresFreshAuth('billing.manage'), isTrue);

        final request = fake.gets.single;
        expect(request.url.path, equals(proxy.authPermissionsSnapshotPath));
        expect(
          request.headers[HttpHeaders.authorizationHeader],
          equals('Bearer id-token'),
        );
        expect(request.headers['Idempotency-Key'], isNotEmpty);
      },
    );

    test('missing ID token fails before network', () async {
      final fake = _FakePermissionSnapshotHttpClient();
      final loader = ProxyPermissionContextLoader(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => null,
        httpClient: fake,
      );

      final error = await _captureError(loader.load(_session()));

      expect(error, isA<PermissionContextLoadError>());
      expect(
        (error! as PermissionContextLoadError).code,
        equals('no_id_token'),
      );
      expect(fake.gets, isEmpty);
    });

    test('non-200 response maps narrow proxy error', () async {
      final fake = _FakePermissionSnapshotHttpClient(
        response: const ProxyPermissionSnapshotResponse(
          statusCode: 503,
          body: <String, Object?>{'error': 'permission_snapshot_unavailable'},
        ),
      );
      final loader = ProxyPermissionContextLoader(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final error = await _captureError(loader.load(_session()));

      expect(error, isA<PermissionContextLoadError>());
      final typed = error! as PermissionContextLoadError;
      expect(typed.code, equals('permission_snapshot_unavailable'));
      expect(typed.statusCode, equals(503));
    });

    test('scope mismatch fails closed', () async {
      final fake = _FakePermissionSnapshotHttpClient(
        response: ProxyPermissionSnapshotResponse(
          statusCode: 200,
          body: <String, Object?>{
            'user_id': 'other_user',
            'operator_id': 'op_1',
            'location_id': 'loc_1',
            'roles_version': 4,
            'evaluated_at': DateTime.utc(2026, 4, 28, 12).toIso8601String(),
            'permissions': const <String, Object?>{},
          },
        ),
      );
      final loader = ProxyPermissionContextLoader(
        proxyBaseUri: baseUri,
        idTokenProvider: () async => 'id-token',
        httpClient: fake,
      );

      final error = await _captureError(loader.load(_session()));

      expect(error, isA<PermissionContextLoadError>());
      expect(
        (error! as PermissionContextLoadError).code,
        equals('scope_mismatch'),
      );
    });
  });
}

AuthSession _session() => AuthSession(
  userId: 'user_1',
  operatorId: 'op_1',
  locationId: 'loc_1',
  firebaseIdToken: 'stored-id-token',
  issuedAt: DateTime.utc(2026, 4, 28, 11),
  expiresAt: DateTime.utc(2026, 4, 28, 13),
  lastFreshAuthAt: DateTime.utc(2026, 4, 28, 11),
  roles: const <String>[],
  mfaEnrolled: false,
);

Future<Object?> _captureError(Future<Object?> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

class _SnapshotGetCall {
  const _SnapshotGetCall({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}

class _FakePermissionSnapshotHttpClient
    implements ProxyPermissionSnapshotHttpClient {
  _FakePermissionSnapshotHttpClient({
    this.response = const ProxyPermissionSnapshotResponse(
      statusCode: 200,
      body: <String, Object?>{},
    ),
  });

  final ProxyPermissionSnapshotResponse response;
  final gets = <_SnapshotGetCall>[];

  @override
  Future<ProxyPermissionSnapshotResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    gets.add(
      _SnapshotGetCall(url: url, headers: Map<String, String>.from(headers)),
    );
    return response;
  }
}
