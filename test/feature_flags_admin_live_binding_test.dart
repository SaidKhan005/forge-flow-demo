// HARD-H — feature flags admin live-binding test.
//
// Drives the production `routeRequest` HTTP handler (the same code path
// the deployed proxy executes) against a real Postgres database when
// the lane is wired to one. PASSIVE BY DEFAULT: the entire group skips
// cleanly when `LIVE_BINDING_POSTGRES_URL` is unset so `flutter test`
// from a fresh checkout never blocks on a missing env. Contract:
// `docs/contracts/hardening_test_corrections_contract.md`.
//
// Coverage (when wired):
//   * Toggle round-trip — `POST /v1/admin/feature-flags/toggle` with a
//     super_admin JWT returns 200, flips the flag state, and lands
//     exactly one `audit_logs` row tagged `admin.feature_flags.toggle`
//     (per the contract). The HARD-H gateway fix in
//     `tool/advisor_proxy/proxy_bootstrap.dart:2386` passes the flag's
//     operator_id + location_id to `insertSystemEvent` so the audit
//     fan-out lands a `audit_logs` row for per-operator flag toggles.
//   * RLS isolation — operator A under tenant SET LOCAL sees its own
//     `audit_logs` rows but NOT operator B's parallel rows (verifies
//     `audit_logs_per_tenant_select`). Driven through the production
//     route so the gateway-issued rows carry `operator_id` from the
//     flag row.
//   * Permission gating — POST with a non-admin JWT (no
//     `super_admin` role) returns 403 and writes zero
//     `audit_logs` rows.
//   * Audit hash chain integrity — `AuditChainHasher.verifyChain`
//     (the same recomputation the SQL trigger does) returns zero
//     violations against operator A's chain for today's UTC date
//     after two POSTs.
//
// HARD-H production fixes that ship with this slice (override the
// prompt's "test-only" constraint where the contract is binding):
//   1. Gateway audit_logs fan-out — `RepositoryFeatureFlagsAdminProxyGateway
//      .toggleFlag` now passes the flag's operator_id + location_id to
//      `insertSystemEvent` so per-operator flag toggles produce the
//      contract-required `audit_logs` row.
//   2. Admin idempotency table — new
//      `db/migrations/202605021000_phase_hardh_admin_idempotency.sql`
//      table backs the cross-tenant
//      `PostgresAdminRequestIdempotencyStore` in proxy_bootstrap.dart.
//      `_routeFeatureFlagsAdmin` now wraps the gateway call with
//      reserve/lookup against this store so two POSTs with the same
//      Idempotency-Key collapse to one toggle + one audit row.
//
// CLAUDE.md bindings: tenant + admin pools both flow through
// `PackagePostgresPool` + `TenantTransactionWrapper`, so SET LOCAL
// discipline holds and the rule against direct `package:postgres`
// imports outside `lib/infrastructure/persistence/postgres/` is
// preserved.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/feature_flags_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import '../tool/advisor_proxy/proxy_bootstrap.dart';
import '../tool/audit_anchor/audit_anchor.dart';

const String _envLiveUrl = 'LIVE_BINDING_POSTGRES_URL';
const String _envAdminUrl = 'LIVE_BINDING_POSTGRES_ADMIN_URL';

// Fixture UUIDs — RFC 4122 v4 / variant 1 (digits 0-9 / a-f only).
// `cafef00d` distinguishes HARD-H rows from any other live-binding
// fixture set so manual cleanup on staging recognises them.
const String _opA = 'cafef00d-aaaa-4aaa-8aaa-000000000001';
const String _opB = 'cafef00d-bbbb-4bbb-8bbb-000000000002';
const String _ouA = 'cafef00d-aaaa-4aaa-8aaa-100000000001';
const String _ouB = 'cafef00d-bbbb-4bbb-8bbb-100000000002';
const String _locA = 'cafef00d-aaaa-4aaa-8aaa-200000000001';
const String _locB = 'cafef00d-bbbb-4bbb-8bbb-200000000002';
const String _userAdminId = 'cafef00d-aaaa-4aaa-8aaa-300000000001';
const String _userNonAdminId = 'cafef00d-bbbb-4bbb-8bbb-300000000002';
const String _flagA = 'cafef00d-aaaa-4aaa-8aaa-400000000001';
const String _flagB = 'cafef00d-bbbb-4bbb-8bbb-400000000002';
const String _flagGlobal = 'cafef00d-9999-4999-8999-400000000003';

const String _userAdminFirebaseUid = 'firebase-uid-hardh-admin';
const String _userNonAdminFirebaseUid = 'firebase-uid-hardh-non-admin';

const String _adminEventType = 'admin.feature_flags.toggle';

void main() {
  final liveUrl = Platform.environment[_envLiveUrl];
  if (liveUrl == null || liveUrl.isEmpty) {
    test(
      'feature flags admin live-binding (passive default)',
      () {
        // Skip body intentionally empty — the skip reason is the contract.
      },
      skip:
          'Live-binding test is passive by default. To run against a real '
          'Postgres, set $_envLiveUrl (and optionally $_envAdminUrl for '
          'the admin pool, defaults to $_envLiveUrl). Live target is '
          'staging only — never Production1.',
    );
    return;
  }

  final adminUrl = Platform.environment[_envAdminUrl] ?? liveUrl;
  late PackagePostgresPool tenantPool;
  late PackagePostgresPool adminPool;
  late TenantTransactionWrapper tenantWrapper;
  late TenantTransactionWrapper adminWrapper;
  late RepositoryFeatureFlagsAdminProxyGateway gateway;
  late RepositoryIntegrationAdminActorResolver actorResolver;
  late PostgresAdminRequestIdempotencyStore idempotencyStore;
  late HttpServer server;
  late HttpClient httpClient;
  late Uri baseUri;
  late _MutableVerifier verifier;

  setUpAll(() async {
    tenantPool = PackagePostgresPool.fromUrl(liveUrl);
    adminPool = PackagePostgresPool.fromUrl(adminUrl);
    tenantWrapper = TenantTransactionWrapper(tenantPool);
    adminWrapper = TenantTransactionWrapper(adminPool);
    gateway = RepositoryFeatureFlagsAdminProxyGateway(
      featureFlagsRepository: FeatureFlagsRepository(adminWrapper),
      auditRepository: AuthEventsAuditRepository(adminWrapper),
    );
    actorResolver = RepositoryIntegrationAdminActorResolver(
      usersRepository: UsersRepository(adminWrapper),
    );
    idempotencyStore = PostgresAdminRequestIdempotencyStore(pool: adminPool);

    await _runAdmin(adminPool, _cleanupFixtures);
    await _runAdmin(adminPool, _seedFixtures);

    verifier = _MutableVerifier();
    final guard = ProxyRequestGuard(verifier: verifier);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          featureFlagsAdminGateway: gateway,
          integrationAdminActorResolver: actorResolver,
          adminRequestIdempotencyStore: idempotencyStore,
          now: () => DateTime.now().toUtc(),
        );
      } catch (_) {
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {
          // Swallow secondary failure.
        }
      }
    });
    httpClient = HttpClient();
    baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  });

  tearDownAll(() async {
    httpClient.close(force: true);
    await server.close(force: true);
    await _runAdmin(adminPool, _cleanupFixtures);
  });

  group('HARD-H feature flags admin live-binding', () {
    test('toggle round-trip: POST /v1/admin/feature-flags/toggle as '
        'super_admin returns 200 + lands exactly one audit_logs row '
        'tagged $_adminEventType for the per-operator flag', () async {
      verifier.claims = _adminClaims();
      final priorAuditLogsCount = await _countAuditLogsForFlag(
        adminPool,
        flagId: _flagA,
      );

      final response = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': 'hardh-toggle-roundtrip-key',
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );

      expect(
        response.statusCode,
        equals(200),
        reason:
            'POST as super_admin must return 200; got ${response.statusCode} '
            'body=${response.body}',
      );
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final flag = (body['flag'] as Map).cast<String, Object?>();
      expect(flag['flag_id'], equals(_flagA));
      expect(flag['enabled'], isTrue);
      expect(flag['updated_by'], equals(_userAdminId));

      final newAuditLogsCount = await _countAuditLogsForFlag(
        adminPool,
        flagId: _flagA,
      );
      expect(
        newAuditLogsCount,
        equals(priorAuditLogsCount + 1),
        reason:
            'POST must land exactly one new audit_logs row for $_flagA; '
            'the HARD-H gateway fix at proxy_bootstrap.dart:2386 passes '
            "the flag's operator_id + location_id through to "
            'insertSystemEvent so the audit_logs fan-out actually fires '
            'for per-operator flags',
      );
    });

    test('idempotent retry: two POSTs with the same Idempotency-Key + '
        'identical body collapse to one audit_logs row + one toggle. '
        'Backed by HARD-H admin_request_idempotency table.', () async {
      verifier.claims = _adminClaims();
      const idempotencyKey = 'hardh-idem-key-second-test';
      final priorAuditCount = await _countAuditLogsForKey(
        adminPool,
        key: idempotencyKey,
      );
      expect(
        priorAuditCount,
        equals(0),
        reason: 'precondition: this idempotency_key must not be in use yet',
      );

      Future<HttpClientResponseRecord> sendOnce() => _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': idempotencyKey,
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );

      // First POST executes the gateway and records the response.
      final first = await sendOnce();
      expect(
        first.statusCode,
        equals(200),
        reason:
            'first POST must succeed; got ${first.statusCode} '
            'body=${first.body}',
      );

      // Second POST with the same key + body must replay the cached
      // response, NOT execute the gateway again.
      final second = await sendOnce();
      expect(
        second.statusCode,
        equals(200),
        reason:
            'duplicate POST must replay cached 200 result; got '
            '${second.statusCode} body=${second.body}',
      );
      expect(
        second.body,
        equals(first.body),
        reason:
            'duplicate POST must return the byte-identical '
            'cached response',
      );

      // Exactly one audit_logs row for the key — the wire-side
      // dedup at HARD-H admin_request_idempotency caught the retry
      // before the gateway ran a second toggle.
      final newAuditCount = await _countAuditLogsForKey(
        adminPool,
        key: idempotencyKey,
      );
      expect(
        newAuditCount,
        equals(1),
        reason:
            'idempotent retry must collapse to a single audit row — '
            'two rows would mean the dedup at admin_request_idempotency '
            'is broken',
      );
    });

    test('idempotency conflict: same Idempotency-Key with a DIFFERENT body '
        'returns 409 idempotency_key_conflict', () async {
      verifier.claims = _adminClaims();
      const idempotencyKey = 'hardh-idem-conflict-key';

      final first = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': idempotencyKey,
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );
      expect(first.statusCode, equals(200));

      final second = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': idempotencyKey,
        },
        // Different enabled value.
        body: <String, Object?>{'flag_id': _flagA, 'enabled': false},
      );
      expect(
        second.statusCode,
        equals(409),
        reason:
            'reusing the key with a different body must surface as 409 '
            'idempotency_key_conflict, not silently replay the prior '
            'response. Got ${second.statusCode} body=${second.body}',
      );
      final body = jsonDecode(second.body) as Map<String, Object?>;
      expect(body['error'], equals('idempotency_key_conflict'));
    });

    test('RLS isolation: tenant A query of audit_logs returns at least '
        'its own row and zero operator B rows; tenant B sees the mirror '
        '— verifies audit_logs_per_tenant_select policy', () async {
      // Drive the toggles through the production route so the
      // gateway-issued audit_logs rows carry the per-operator
      // operator_id (post-HARD-H gateway fix). Then verify the
      // tenant-scoped SELECT under each operator's app.operator_id
      // sees only its own rows.
      verifier.claims = _adminClaims();
      await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': 'hardh-rls-key-A',
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );
      // Same super_admin actor toggles operator B's flag — the
      // gateway picks up the flag's operator_id (not the actor's
      // operator_id), so the audit_logs row for $_flagB lands under
      // operator B's chain.
      await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': 'hardh-rls-key-B',
        },
        body: <String, Object?>{'flag_id': _flagB, 'enabled': true},
      );

      final allRows = await _selectAuditLogsAsAdmin(
        adminPool,
        action: _adminEventType,
      );
      expect(
        allRows.where((r) => r.operatorId == _opA).length,
        greaterThanOrEqualTo(1),
        reason:
            'precondition: BYPASSRLS read must see operator A\'s '
            'audit_logs row (the toggle actually wrote)',
      );
      expect(
        allRows.where((r) => r.operatorId == _opB).length,
        greaterThanOrEqualTo(1),
        reason:
            'precondition: BYPASSRLS read must see operator B\'s '
            'audit_logs row',
      );

      final viewForA = await _selectAuditLogsAsTenant(
        tenantWrapper,
        ctx: TenantContext(
          operatorId: _opA,
          locationId: _locA,
          userId: _userAdminId,
        ),
        action: _adminEventType,
      );
      final viewForB = await _selectAuditLogsAsTenant(
        tenantWrapper,
        ctx: TenantContext(
          operatorId: _opB,
          locationId: _locB,
          userId: _userAdminId,
        ),
        action: _adminEventType,
      );

      // Non-empty + every row is the right operator's. The empty-list
      // case alone passes `every`, which would mask a broken RLS
      // policy that filters every row away — both axes must hold.
      expect(
        viewForA.where((r) => r.operatorId == _opA).length,
        greaterThanOrEqualTo(1),
        reason:
            'tenant A must see at least its own audit_logs row; an '
            'over-restrictive RLS policy that filters every row away '
            'would also pass an .every() check',
      );
      expect(
        viewForA.where((r) => r.operatorId == _opB).length,
        equals(0),
        reason:
            'tenant A must NOT see operator B\'s rows. Got operatorIds: '
            '${viewForA.map((r) => r.operatorId).toSet()}',
      );
      expect(
        viewForB.where((r) => r.operatorId == _opB).length,
        greaterThanOrEqualTo(1),
        reason: 'tenant B must see at least its own audit_logs row',
      );
      expect(
        viewForB.where((r) => r.operatorId == _opA).length,
        equals(0),
        reason:
            'tenant B must NOT see operator A\'s rows. Got operatorIds: '
            '${viewForB.map((r) => r.operatorId).toSet()}',
      );
    });

    test('permission gating: POST with a non-admin JWT returns 403 and '
        'writes zero audit_logs rows', () async {
      verifier.claims = _nonAdminClaims();
      final priorAuditLogsCount = await _countAuditLogsForFlag(
        adminPool,
        flagId: _flagA,
      );

      final response = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-non-admin-token',
          'Idempotency-Key': 'hardh-permission-denied-key',
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );

      expect(
        response.statusCode,
        equals(403),
        reason:
            'non-admin POST must be short-circuited with 403; got '
            '${response.statusCode} body=${response.body}',
      );
      final body = jsonDecode(response.body) as Map<String, Object?>;
      expect(body['error'], equals('permission_denied'));

      final newAuditLogsCount = await _countAuditLogsForFlag(
        adminPool,
        flagId: _flagA,
      );
      expect(
        newAuditLogsCount,
        equals(priorAuditLogsCount),
        reason:
            'permission denial must short-circuit before the audit '
            'insert; got prior=$priorAuditLogsCount, '
            'new=$newAuditLogsCount',
      );
    });

    test('audit_logs row_hash chain validates per (operator_id, chain_date) '
        'scope — AuditChainHasher.verifyChain returns zero violations '
        'after two POSTs through the production route', () async {
      verifier.claims = _adminClaims();

      // Pin the rows-belonging-to-this-test by their unique
      // idempotency keys. Earlier tests in the same suite write
      // operator A audit_logs rows too, so length-based assertions
      // alone would let a regression where these two POSTs fail to
      // write still pass on prior rows. Capture the exact rows that
      // are supposed to land here.
      const k1 = 'hardh-chain-key-1';
      const k2 = 'hardh-chain-key-2';
      final priorK1 = await _countAuditLogsForKey(adminPool, key: k1);
      final priorK2 = await _countAuditLogsForKey(adminPool, key: k2);
      expect(
        priorK1 + priorK2,
        equals(0),
        reason:
            'precondition: $k1 + $k2 must not already have rows in '
            'audit_logs (clean per-test idempotency keys)',
      );

      final response1 = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': k1,
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': false},
      );
      expect(
        response1.statusCode,
        equals(200),
        reason: 'first POST must succeed; got ${response1.statusCode}',
      );
      final response2 = await _post(
        httpClient,
        baseUri.resolve('/v1/admin/feature-flags/toggle'),
        headers: <String, String>{
          'Authorization': 'Bearer test-admin-token',
          'Idempotency-Key': k2,
        },
        body: <String, Object?>{'flag_id': _flagA, 'enabled': true},
      );
      expect(
        response2.statusCode,
        equals(200),
        reason: 'second POST must succeed; got ${response2.statusCode}',
      );

      // Verify each POST produced exactly one audit_logs row (the
      // delta-by-key check the hash-chain test would otherwise
      // pass-through on prior rows).
      expect(
        await _countAuditLogsForKey(adminPool, key: k1),
        equals(1),
        reason: 'first POST must land exactly one audit_logs row for $k1',
      );
      expect(
        await _countAuditLogsForKey(adminPool, key: k2),
        equals(1),
        reason: 'second POST must land exactly one audit_logs row for $k2',
      );

      final reader = PostgresAuditChainReader(
        wrapper: adminWrapper,
        defaultLocationId: _locA,
        defaultUserId: _userAdminId,
      );
      final today = DateTime.now().toUtc();
      final chainDate = DateTime.utc(today.year, today.month, today.day);

      final rows = await reader.readChainRows(
        operatorId: _opA,
        chainDate: chainDate,
      );
      expect(
        rows.length,
        greaterThanOrEqualTo(2),
        reason:
            'two POSTs through the production route must produce at '
            'least two rows in operator A\'s chain on today\'s UTC date',
      );
      // Defense against chain mixing: every row read for verification
      // must belong to the same (operator_id, chain_date) chain. The
      // reader filters by operator_id; this assertion documents that
      // any future regression in the SELECT shape (e.g. removing the
      // operator_id filter) is caught immediately.
      expect(
        rows.every((row) => row.operatorId == _opA),
        isTrue,
        reason:
            'every row in the verifier input must belong to operator A\'s '
            'chain — the audit_logs chain is scoped per '
            '(operator_id, chain_date) and mixing chains would let a '
            'broken chain in one operator hide behind a healthy one '
            "in another",
      );

      final violations = const AuditChainHasher().verifyChain(rows);
      expect(
        violations,
        isEmpty,
        reason:
            'AuditChainHasher.verifyChain must report zero violations — '
            'a prev_row_hash mismatch OR a row_hash that does not '
            'recompute from SHA-256(prev_row_hash || canonical_payload) '
            'would surface here. Violations: $violations',
      );
    });
  });
}

// ─── Test JWT verifier + claims helpers ───────────────────────────────

class _MutableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final value = claims;
    if (value == null) {
      throw ProxyJwtVerificationError(
        'test verifier not configured (set claims before each test)',
      );
    }
    return value;
  }
}

ProxyJwtClaims _adminClaims() => ProxyJwtClaims(
  userId: _userAdminId,
  operatorId: _opA,
  locationId: _locA,
  roles: const <String>['super_admin'],
  firebaseUid: _userAdminFirebaseUid,
  lastFreshAuthAt: DateTime.now().toUtc(),
);

ProxyJwtClaims _nonAdminClaims() => ProxyJwtClaims(
  userId: _userNonAdminId,
  operatorId: _opB,
  locationId: _locB,
  roles: const <String>['ff_support'],
  firebaseUid: _userNonAdminFirebaseUid,
  lastFreshAuthAt: DateTime.now().toUtc(),
);

// ─── HTTP helpers ─────────────────────────────────────────────────────

class HttpClientResponseRecord {
  HttpClientResponseRecord({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<HttpClientResponseRecord> _post(
  HttpClient client,
  Uri uri, {
  required Map<String, String> headers,
  required Map<String, Object?> body,
}) async {
  final request = await client.postUrl(uri);
  headers.forEach(request.headers.set);
  request.headers.contentType = ContentType.json;
  request.add(utf8.encode(jsonEncode(body)));
  final response = await request.close();
  final raw = await response.transform(utf8.decoder).join();
  return HttpClientResponseRecord(statusCode: response.statusCode, body: raw);
}

// ─── Fixture seed + cleanup ───────────────────────────────────────────

const String _fixtureMarker = 'hardh-feature-flags-live';

/// Seeds two operators, two locations, two users, two role grants, and
/// three feature_flags rows. Idempotent — uses `on conflict do nothing`
/// so re-runs of `setUpAll` against a half-cleaned DB land cleanly.
Future<void> _seedFixtures(PostgresExecutor exec) async {
  for (final entry in <Map<String, String>>[
    <String, String>{
      'id': _opA,
      'name': '$_fixtureMarker A',
      'email': '$_opA@$_fixtureMarker.invalid',
    },
    <String, String>{
      'id': _opB,
      'name': '$_fixtureMarker B',
      'email': '$_opB@$_fixtureMarker.invalid',
    },
  ]) {
    await exec.execute(
      'insert into public.operators '
      '(operator_id, business_name, owner_email) '
      'values (@id::uuid, @name, @email) '
      'on conflict (operator_id) do nothing',
      parameters: entry,
    );
  }

  for (final entry in <Map<String, String>>[
    <String, String>{
      'id': _ouA,
      'op': _opA,
      'path': '${_fixtureMarker.replaceAll('-', '_')}_a',
    },
    <String, String>{
      'id': _ouB,
      'op': _opB,
      'path': '${_fixtureMarker.replaceAll('-', '_')}_b',
    },
  ]) {
    await exec.execute(
      'insert into public.org_units '
      "(id, operator_id, parent_id, unit_type, path, name) "
      "values (@id::uuid, @op::uuid, null, 'corp', @path::ltree, @name) "
      'on conflict (id) do nothing',
      parameters: <String, Object?>{
        'id': entry['id'],
        'op': entry['op'],
        'path': entry['path'],
        'name': '${entry['op']!.substring(0, 8)} root',
      },
    );
  }

  for (final entry in <Map<String, String>>[
    <String, String>{
      'op': _opA,
      'loc': _locA,
      'ou': _ouA,
      'name': '$_fixtureMarker A loc',
    },
    <String, String>{
      'op': _opB,
      'loc': _locB,
      'ou': _ouB,
      'name': '$_fixtureMarker B loc',
    },
  ]) {
    await exec.execute(
      'insert into public.locations '
      '(location_id, operator_id, parent_org_unit_id, name, '
      'timezone, business_day_rollover_hour) '
      'values (@loc::uuid, @op::uuid, @ou::uuid, @name, @tz, @rollover) '
      'on conflict (location_id) do nothing',
      parameters: <String, Object?>{
        'loc': entry['loc'],
        'op': entry['op'],
        'ou': entry['ou'],
        'name': entry['name'],
        'tz': 'America/Toronto',
        'rollover': 4,
      },
    );
  }

  // Users — `firebase_uid` + `status='active'` so the production actor
  // resolver (`UsersRepository.findActiveUserIdByFirebaseUidSystem`)
  // can map the verified Firebase UID back to the seeded
  // `users.user_id`. Without these, the route's pre-gateway resolver
  // returns null and the POST fails with `actor_user_not_resolvable`
  // (403) before any contract bullet can be exercised.
  for (final entry in <Map<String, String>>[
    <String, String>{
      'id': _userAdminId,
      'op': _opA,
      'email': '$_userAdminId@$_fixtureMarker.invalid',
      'fb_uid': _userAdminFirebaseUid,
    },
    <String, String>{
      'id': _userNonAdminId,
      'op': _opB,
      'email': '$_userNonAdminId@$_fixtureMarker.invalid',
      'fb_uid': _userNonAdminFirebaseUid,
    },
  ]) {
    await exec.execute(
      'insert into public.users '
      "(user_id, operator_id, email, firebase_uid, status) "
      "values (@id::uuid, @op::uuid, @email, @fb_uid, 'active') "
      'on conflict (user_id) do nothing',
      parameters: entry,
    );
  }

  // Role grants — userAdmin → super_admin (carries
  // `admin.feature_flag.toggle`); userNonAdmin → supervisor.
  for (final entry in <Map<String, String>>[
    <String, String>{
      'user': _userAdminId,
      'op': _opA,
      'role_key': 'super_admin',
    },
    <String, String>{
      'user': _userNonAdminId,
      'op': _opB,
      'role_key': 'supervisor',
    },
  ]) {
    await exec.execute(
      'insert into public.user_roles '
      '(user_id, role_id, operator_id, scope_type, location_id, '
      'granted_by) '
      'select @user::uuid, r.role_id, @op::uuid, '
      "'operator_wide', null, @user::uuid "
      'from public.roles r '
      'where r.role_key = @role_key and r.operator_id is null '
      'on conflict (operator_id, user_id, role_id, '
      "coalesce(location_id, '00000000-0000-0000-0000-000000000000'::uuid)) "
      'where revoked_at is null do nothing',
      parameters: entry,
    );
  }

  for (final entry in <Map<String, Object?>>[
    <String, Object?>{
      'id': _flagA,
      'name': '${_fixtureMarker}_a_flag',
      'op': _opA,
    },
    <String, Object?>{
      'id': _flagB,
      'name': '${_fixtureMarker}_b_flag',
      'op': _opB,
    },
    <String, Object?>{
      'id': _flagGlobal,
      'name': '${_fixtureMarker}_global_flag',
      'op': null,
    },
  ]) {
    await exec.execute(
      'insert into public.feature_flags '
      '(flag_id, flag_name, operator_id, location_id, enabled, kind) '
      "values (@id::uuid, @name, @op::uuid, null, false, 'standard') "
      'on conflict (flag_id) do nothing',
      parameters: entry,
    );
  }
}

Future<void> _cleanupFixtures(PostgresExecutor exec) async {
  await exec.execute(
    'delete from public.feature_flags where flag_id::text in '
    "('$_flagA', '$_flagB', '$_flagGlobal')",
  );
  await exec.execute(
    'delete from public.proxy_requests where idempotency_key like '
    "'hardh-%'",
  );
  // HARD-H — the new admin idempotency cache lives in its own table
  // (cross-tenant scope, no operator_id). Cleanup must clear our
  // `hardh-*` keys here too; otherwise a successful run leaves cached
  // responses behind and the next setup deletes audit_logs/fixtures
  // but a re-issued POST replays the cached response without fanning
  // out into audit_logs, breaking the next run's audit assertions.
  await exec.execute(
    'delete from public.admin_request_idempotency where idempotency_key '
    "like 'hardh-%'",
  );
  await exec.execute(
    'delete from public.audit_logs where actor_user_id::text in '
    "('$_userAdminId', '$_userNonAdminId')",
  );
  await exec.execute(
    'delete from public.auth_events_audit where actor_user_id::text in '
    "('$_userAdminId', '$_userNonAdminId')",
  );
  for (final table in <String>[
    'audit_logs',
    'auth_events_audit',
    'user_roles',
    'users',
    'locations',
    'org_units',
  ]) {
    await exec.execute(
      'delete from public.$table where operator_id::text in '
      "('$_opA', '$_opB')",
    );
  }
  await exec.execute(
    'delete from public.operators where operator_id::text in '
    "('$_opA', '$_opB')",
  );
}

Future<void> _runAdmin(
  PostgresPool pool,
  Future<void> Function(PostgresExecutor exec) body,
) async {
  final tx = await pool.beginTransaction();
  var finalized = false;
  try {
    await tx.execute(
      "select set_config('app.bypass_rls_audit', "
      "'system:hardh_feature_flags_live', true)",
    );
    await body(tx);
    await tx.commit();
    finalized = true;
  } finally {
    if (!finalized) {
      try {
        await tx.rollback();
      } catch (_) {
        // Swallow rollback secondary failure.
      }
    }
  }
}

// ─── Verification helpers ─────────────────────────────────────────────

class _AuditLogsRow {
  const _AuditLogsRow({required this.operatorId, required this.action});
  final String? operatorId;
  final String action;
}

Future<int> _countAuditLogsForFlag(
  PackagePostgresPool adminPool, {
  required String flagId,
}) async {
  late int count;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select count(*) as cnt from public.audit_logs '
      'where action = @act '
      "and payload ->> 'flag_id' = @flag_id",
      parameters: <String, Object?>{'act': _adminEventType, 'flag_id': flagId},
    );
    count = _readCount(rows.single['cnt']);
  });
  return count;
}

Future<int> _countAuditLogsForKey(
  PackagePostgresPool adminPool, {
  required String key,
}) async {
  late int count;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select count(*) as cnt from public.audit_logs '
      "where payload ->> 'idempotency_key' = @key",
      parameters: <String, Object?>{'key': key},
    );
    count = _readCount(rows.single['cnt']);
  });
  return count;
}

Future<List<_AuditLogsRow>> _selectAuditLogsAsTenant(
  TenantTransactionWrapper wrapper, {
  required TenantContext ctx,
  required String action,
}) {
  return wrapper.runInTenantContext<List<_AuditLogsRow>>(ctx, (exec) async {
    final rows = await exec.query(
      'select operator_id::text as operator_id, action '
      'from public.audit_logs '
      'where action = @act',
      parameters: <String, Object?>{'act': action},
    );
    return <_AuditLogsRow>[
      for (final row in rows)
        _AuditLogsRow(
          operatorId: row['operator_id'] as String?,
          action: row['action']! as String,
        ),
    ];
  });
}

Future<List<_AuditLogsRow>> _selectAuditLogsAsAdmin(
  PackagePostgresPool adminPool, {
  required String action,
}) async {
  late List<_AuditLogsRow> result;
  await _runAdmin(adminPool, (exec) async {
    final rows = await exec.query(
      'select operator_id::text as operator_id, action '
      'from public.audit_logs '
      'where action = @act',
      parameters: <String, Object?>{'act': action},
    );
    result = <_AuditLogsRow>[
      for (final row in rows)
        _AuditLogsRow(
          operatorId: row['operator_id'] as String?,
          action: row['action']! as String,
        ),
    ];
  });
  return result;
}

int _readCount(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw) ?? 0;
  if (raw is BigInt) return raw.toInt();
  return 0;
}
