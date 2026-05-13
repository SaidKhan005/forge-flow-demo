// Lane B B2.4 — WebTeamRolesGatewayLive catalog-version field parsing
// tests.
//
// Pins the contract added in B2.4: the gateway parses two new
// additive nullable fields on every role row the proxy returns:
//
//   * `catalog_version_id` — UUID string of the
//     `default_role_catalog_versions` row the operator is
//     following at read time. NULL for custom rows + genesis-state
//     seeded rows.
//   * `catalog_published_at` — ISO-8601 UTC timestamp of that
//     version's `published_at`. NULL alongside `catalog_version_id`.
//
// Back-compat (legacy proxy build that doesn't carry the fields):
// the gateway tolerates missing keys as null, so an operator-web
// build running against a not-yet-redeployed proxy renders the
// fallback "Managed by Forge & Flow" copy without crashing.
//
// Defensive: a non-null `catalog_published_at` that isn't a
// parseable ISO-8601 string surfaces as a typed
// `WebTeamRolesError(code: malformed_response, ...)` so the screen
// can downgrade gracefully.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:forge_and_flow/operator_web/services/web_team_roles_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';

const String _kCatalogVersionId =
    '66666666-6666-6666-6666-666666666666';
const String _kPublishedAtIso = '2026-01-15T17:00:00.000Z';
final DateTime _kPublishedAtUtc = DateTime.utc(2026, 1, 15, 17, 0);

void main() {
  final proxyBase = Uri.parse('https://proxy.forgeflow.test');
  Future<String?> tokenProvider() async => 'test-id-token';

  group('WebTeamRolesGatewayLive catalog-version field parsing', () {
    test(
      'both fields present → parsed onto TeamRoleCatalogEntry; '
      'catalog_published_at returned as UTC DateTime',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                _seededRoleJson(
                  catalogVersionId: _kCatalogVersionId,
                  catalogPublishedAt: _kPublishedAtIso,
                ),
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.roles, hasLength(1));
        expect(listed.roles[0].catalogVersionId, equals(_kCatalogVersionId));
        expect(listed.roles[0].catalogPublishedAt, equals(_kPublishedAtUtc));
        expect(
          listed.roles[0].catalogPublishedAt!.isUtc,
          isTrue,
          reason: 'gateway normalises catalog_published_at to UTC',
        );
      },
    );

    test(
      'both fields absent (legacy proxy build pre-B2.4) → '
      'catalogVersionId + catalogPublishedAt both null; back-compat '
      'is preserved',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                _seededRoleJson(includeCatalogFields: false),
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.roles, hasLength(1));
        expect(listed.roles[0].isSeeded, isTrue);
        expect(listed.roles[0].catalogVersionId, isNull);
        expect(listed.roles[0].catalogPublishedAt, isNull);
      },
    );

    test(
      'both fields explicitly null (genesis state — no catalog '
      'version published yet) → catalogVersionId + '
      'catalogPublishedAt both null',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                _seededRoleJson(
                  catalogVersionId: null,
                  catalogPublishedAt: null,
                ),
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.roles, hasLength(1));
        expect(listed.roles[0].catalogVersionId, isNull);
        expect(listed.roles[0].catalogPublishedAt, isNull);
      },
    );

    test(
      'malformed catalog_published_at (non-ISO-8601 string) → '
      'WebTeamRolesError(code: malformed_response); screen falls '
      'back to the version-agnostic copy',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                _seededRoleJson(
                  catalogVersionId: _kCatalogVersionId,
                  catalogPublishedAt: 'not-a-timestamp',
                ),
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        await expectLater(
          gateway.listRoles(
            const TeamRoleCatalogListCommand(
              actorUserId: 'actor',
              operatorId: 'op',
              locationId: 'loc',
            ),
          ),
          throwsA(
            isA<WebTeamRolesError>().having(
              (e) => e.code,
              'code',
              equals('malformed_response'),
            ),
          ),
        );
      },
    );

    test(
      'custom role row: catalog fields parse to null even when the '
      'proxy returns explicit nulls; back-compat is preserved',
      () async {
        final client = MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'roles': <Object?>[
                _customRoleJson(),
              ],
            }),
            200,
          );
        });
        final gateway = WebTeamRolesGatewayLive(
          proxyBaseUri: proxyBase,
          idTokenProvider: tokenProvider,
          httpClient: client,
        );

        final listed = await gateway.listRoles(
          const TeamRoleCatalogListCommand(
            actorUserId: 'actor',
            operatorId: 'op',
            locationId: 'loc',
          ),
        );

        expect(listed.roles, hasLength(1));
        expect(listed.roles[0].isSeeded, isFalse);
        expect(listed.roles[0].catalogVersionId, isNull);
        expect(listed.roles[0].catalogPublishedAt, isNull);
      },
    );
  });
}

Map<String, Object?> _seededRoleJson({
  String? catalogVersionId,
  String? catalogPublishedAt,
  bool includeCatalogFields = true,
}) {
  return <String, Object?>{
    'role_id': '44444444-4444-4444-8444-444444444444',
    'role_key': 'operator_owner',
    'display_name': 'Owner',
    'description': '',
    'is_seeded': true,
    'is_editable': false,
    'operator_id': null,
    'permissions': const <Object?>[],
    if (includeCatalogFields) 'catalog_version_id': catalogVersionId,
    if (includeCatalogFields) 'catalog_published_at': catalogPublishedAt,
  };
}

Map<String, Object?> _customRoleJson() {
  return <String, Object?>{
    'role_id': '55555555-5555-5555-8555-555555555555',
    'role_key': 'custom.floor_captain',
    'display_name': 'Floor Captain',
    'description': '',
    'is_seeded': false,
    'is_editable': true,
    'operator_id': 'op',
    'permissions': const <Object?>[],
    // Proxy emits explicit nulls for custom rows so the wire shape
    // stays uniform; gateway must tolerate that without surfacing
    // them as "set" on the entry.
    'catalog_version_id': null,
    'catalog_published_at': null,
  };
}
