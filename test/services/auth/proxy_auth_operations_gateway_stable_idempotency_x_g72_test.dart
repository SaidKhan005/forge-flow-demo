// X-G72 — caller-stable idempotency keys for the mobile
// ProxyAuthOperationsGateway.
//
// Before the fix the gateway minted a fresh random `Idempotency-Key`
// on EVERY HTTP send (the default factory). A mobile retry of a
// mutating org/team write therefore presented a NEW key, defeating the
// proxy's `proxy_requests` UNIQUE replay guard and double-applying the
// mutation (duplicate org-units, double-applied lifecycle, etc.).
//
// These tests pin the corrected behavior:
//   * a retried mutating op reuses the SAME deterministic key;
//   * a genuinely-distinct op (different route or different payload)
//     gets a DIFFERENT key — distinct intents are never coalesced;
//   * an explicitly-injected factory still wins verbatim (legacy +
//     existing-suite parity);
//   * GET reads are not stabilised (no server-side replay guard) so a
//     fresh per-call key is harmless.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';

void main() {
  final baseUri = Uri.parse('https://forge-flow-proxy.example.com');

  ProxyAuthOperationsGateway buildGateway(_RecordingHttpClient fake) {
    // NOTE: no idempotencyKeyFactory injected — this exercises the
    // production wiring path where the bindings inject nothing and the
    // gateway must derive a caller-stable key itself.
    return ProxyAuthOperationsGateway(
      proxyBaseUri: baseUri,
      idTokenProvider: () async => 'id-token',
      httpClient: fake,
    );
  }

  String keyOf(_CapturedCall call) => call.headers['Idempotency-Key']!;

  group('X-G72 caller-stable idempotency keys', () {
    test(
      'a retried createOrgUnit reuses the SAME idempotency key',
      () async {
        final fake = _RecordingHttpClient(
          postResponse: const ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{'org_unit_id': 'ou-1'},
          ),
        );
        final gateway = buildGateway(fake);
        const command = TeamOrgUnitCreateCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          parentOrgUnitId: 'root',
          unitType: 'region',
          label: 'West',
          name: 'West Region',
        );

        await gateway.createOrgUnit(command);
        await gateway.createOrgUnit(command); // mobile retry

        expect(fake.posts, hasLength(2));
        expect(keyOf(fake.posts[0]), equals(keyOf(fake.posts[1])));
        expect(keyOf(fake.posts[0]), startsWith('mob-authops-'));
      },
    );

    test(
      'distinct ops (different route) get DIFFERENT idempotency keys',
      () async {
        // Response carries the keys both routes parse so the focus
        // stays on the Idempotency-Key header, not response shape.
        final fake = _RecordingHttpClient(
          postResponse: ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{
              'org_unit_id': 'ou-1',
              'invite_id': 'inv-1',
              'expires_at': DateTime.utc(2026, 6, 1).toIso8601String(),
            },
          ),
        );
        final gateway = buildGateway(fake);

        await gateway.createOrgUnit(
          const TeamOrgUnitCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            parentOrgUnitId: 'root',
            unitType: 'region',
            label: 'West',
            name: 'West Region',
          ),
        );
        await gateway.createInvite(
          const TeamInviteCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            email: 'new.user@example.test',
            roleId: 'role-1',
            scopeType: 'operator_wide',
          ),
        );

        expect(fake.posts, hasLength(2));
        expect(keyOf(fake.posts[0]), isNot(equals(keyOf(fake.posts[1]))));
      },
    );

    test(
      'same route, different payload ⇒ DIFFERENT idempotency key',
      () async {
        final fake = _RecordingHttpClient(
          postResponse: const ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{'org_unit_id': 'ou-1'},
          ),
        );
        final gateway = buildGateway(fake);

        await gateway.createOrgUnit(
          const TeamOrgUnitCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            parentOrgUnitId: 'root',
            unitType: 'region',
            label: 'West',
            name: 'West Region',
          ),
        );
        await gateway.createOrgUnit(
          const TeamOrgUnitCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            parentOrgUnitId: 'root',
            unitType: 'region',
            label: 'East',
            name: 'East Region',
          ),
        );

        expect(fake.posts, hasLength(2));
        expect(keyOf(fake.posts[0]), isNot(equals(keyOf(fake.posts[1]))));
      },
    );

    test(
      'a retried DELETE (deleteRole) reuses the SAME idempotency key',
      () async {
        final fake = _RecordingHttpClient(
          deleteResponse: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{'deleted': true},
          ),
        );
        final gateway = buildGateway(fake);
        const command = TeamRoleDeleteCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
          roleId: 'role-9',
        );

        await gateway.deleteRole(command);
        await gateway.deleteRole(command); // retry

        expect(fake.deletes, hasLength(2));
        expect(keyOf(fake.deletes[0]), equals(keyOf(fake.deletes[1])));
      },
    );

    test(
      'an explicitly-injected factory still wins VERBATIM (legacy parity)',
      () async {
        final fake = _RecordingHttpClient(
          postResponse: const ProxyAuthOperationsResponse(
            statusCode: 201,
            body: <String, Object?>{'org_unit_id': 'ou-1'},
          ),
        );
        final gateway = ProxyAuthOperationsGateway(
          proxyBaseUri: baseUri,
          idTokenProvider: () async => 'id-token',
          httpClient: fake,
          idempotencyKeyFactory: () => 'legacy-fixed-key',
        );

        await gateway.createOrgUnit(
          const TeamOrgUnitCreateCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
            parentOrgUnitId: 'root',
            unitType: 'region',
            label: 'West',
            name: 'West Region',
          ),
        );

        expect(keyOf(fake.posts.single), equals('legacy-fixed-key'));
      },
    );

    test('GET reads are not stabilised (fresh key per call)', () async {
      final fake = _RecordingHttpClient(
        getResponse: const ProxyAuthOperationsResponse(
          statusCode: 200,
          body: <String, Object?>{'org_units': <Object?>[], 'locations': <Object?>[]},
        ),
      );
      final gateway = buildGateway(fake);

      await gateway.listOrgHierarchy(
        const TeamOrgHierarchyListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );
      await gateway.listOrgHierarchy(
        const TeamOrgHierarchyListCommand(
          actorUserId: 'actor',
          operatorId: 'op',
          locationId: 'loc',
        ),
      );

      expect(fake.gets, hasLength(2));
      expect(keyOf(fake.gets[0]), isNot(equals(keyOf(fake.gets[1]))));
    });
  });
}

class _RecordingHttpClient implements ProxyAuthOperationsHttpClient {
  _RecordingHttpClient({
    ProxyAuthOperationsResponse? getResponse,
    ProxyAuthOperationsResponse? postResponse,
    ProxyAuthOperationsResponse? patchResponse,
    ProxyAuthOperationsResponse? deleteResponse,
  }) : _getResponse = getResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{},
           ),
       _postResponse = postResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true},
           ),
       _patchResponse = patchResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true},
           ),
       _deleteResponse = deleteResponse ??
           const ProxyAuthOperationsResponse(
             statusCode: 200,
             body: <String, Object?>{'ok': true, 'deleted': true},
           );

  final ProxyAuthOperationsResponse _getResponse;
  final ProxyAuthOperationsResponse _postResponse;
  final ProxyAuthOperationsResponse _patchResponse;
  final ProxyAuthOperationsResponse _deleteResponse;

  final List<_CapturedCall> gets = <_CapturedCall>[];
  final List<_CapturedCall> posts = <_CapturedCall>[];
  final List<_CapturedCall> patches = <_CapturedCall>[];
  final List<_CapturedCall> deletes = <_CapturedCall>[];

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    gets.add(_CapturedCall(url: url, headers: Map.of(headers)));
    return _getResponse;
  }

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    posts.add(_CapturedCall(url: url, headers: Map.of(headers)));
    return _postResponse;
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    patches.add(_CapturedCall(url: url, headers: Map.of(headers)));
    return _patchResponse;
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    deletes.add(_CapturedCall(url: url, headers: Map.of(headers)));
    return _deleteResponse;
  }
}

class _CapturedCall {
  const _CapturedCall({required this.url, required this.headers});

  final Uri url;
  final Map<String, String> headers;
}
