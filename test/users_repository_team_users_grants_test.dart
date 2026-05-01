// Phase 9.UX.grant-payload — UsersRepository.listTeamUsers grants
// projection.
//
// Pins the additive `grants` column on `selectTeamUsersByOperator`:
// every active `user_roles` row is aggregated per user with the full
// scope payload (`scope_type`, `org_unit_id`, `location_id`,
// `effective_location_ids`) so the role-change dialog's inheritance
// hint can render without a follow-up read. Existing `locationId`
// semantics (`coalesce(ur.location_id, u.primary_location_id)`) stay
// unchanged — the test asserts both surfaces.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/users_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _validOpId = '11111111-1111-1111-1111-111111111111';
const String _validLocId = '22222222-2222-2222-2222-222222222222';
const String _validUserId = '33333333-3333-3333-3333-333333333333';

const String _opWideGrantId = 'a0000000-0000-4000-8000-000000000001';
const String _orgUnitGrantId = 'a0000000-0000-4000-8000-000000000002';
const String _locationGrantId = 'a0000000-0000-4000-8000-000000000003';

const String _orgUnitId = 'b0000000-0000-4000-8000-000000000001';
const String _otherLocationId = 'c0000000-0000-4000-8000-000000000001';

void main() {
  group('UsersRepository.listTeamUsers grants payload', () {
    test(
      'aggregates one row per user with all active grants nested in '
      'jsonb form',
      () async {
        final pool = _TeamUsersPool(
          teamUserRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _validUserId,
              'email': 'multi@example.test',
              'display_name': 'Multi Grant',
              'role_id': 'role-owner',
              'role_label': 'Owner',
              'status': 'active',
              'user_role_id': _opWideGrantId,
              'location_id': _validLocId,
              'location_label': 'Vancouver Robson',
              'mfa_enrolled': true,
              'mfa_removal_request_id': null,
              'last_active_at': DateTime.utc(2026, 4, 28),
              'grants': <Map<String, Object?>>[
                <String, Object?>{
                  'user_role_id': _opWideGrantId,
                  'role_id': 'role-owner',
                  'role_label': 'Owner',
                  'scope_type': 'operator_wide',
                  'org_unit_id': null,
                  'location_id': null,
                  'source_org_unit_id': null,
                  'effective_location_ids': const <String>[],
                  'valid_from': '2026-04-01T00:00:00.000Z',
                  'valid_until': null,
                  'revoked_at': null,
                },
                <String, Object?>{
                  'user_role_id': _orgUnitGrantId,
                  'role_id': 'role-manager',
                  'role_label': 'Manager',
                  'scope_type': 'org_unit',
                  'org_unit_id': _orgUnitId,
                  'location_id': null,
                  'source_org_unit_id': _orgUnitId,
                  'effective_location_ids': <String>[
                    _validLocId,
                    _otherLocationId,
                  ],
                  'valid_from': '2026-04-02T00:00:00.000Z',
                  'valid_until': null,
                  'revoked_at': null,
                },
                <String, Object?>{
                  'user_role_id': _locationGrantId,
                  'role_id': 'role-supervisor',
                  'role_label': 'Supervisor',
                  'scope_type': 'location',
                  'org_unit_id': null,
                  'location_id': _validLocId,
                  'source_org_unit_id': null,
                  'effective_location_ids': <String>[_validLocId],
                  'valid_from': '2026-04-03T00:00:00.000Z',
                  'valid_until': null,
                  'revoked_at': null,
                },
              ],
            },
          ],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        final rows = await repo.listTeamUsers(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
        );

        expect(rows, hasLength(1));
        final row = rows.single;
        // Backward-compat surface: locationId still projects via the
        // coalesce(ur.location_id, u.primary_location_id) column.
        expect(row.locationId, equals(_validLocId));
        expect(row.userRoleId, equals(_opWideGrantId));
        // New surface: full grants array with one element per active
        // grant carrying authoritative scope_type + ancillary scope ids.
        expect(row.grants, hasLength(3));
        final byScope = <String, TeamUserGrantRepositoryRow>{
          for (final grant in row.grants) grant.scopeType: grant,
        };
        expect(byScope.keys.toSet(), <String>{
          'operator_wide',
          'org_unit',
          'location',
        });
        expect(byScope['operator_wide']!.userRoleId, equals(_opWideGrantId));
        expect(byScope['operator_wide']!.locationId, isNull);
        expect(byScope['operator_wide']!.orgUnitId, isNull);
        // Authoritative role label travels with the snapshot so the
        // dialog never has to wait on the role-catalog load.
        expect(byScope['operator_wide']!.roleLabel, equals('Owner'));
        expect(byScope['org_unit']!.orgUnitId, equals(_orgUnitId));
        expect(byScope['org_unit']!.roleLabel, equals('Manager'));
        expect(
          byScope['org_unit']!.effectiveLocationIds,
          equals(<String>[_validLocId, _otherLocationId]),
        );
        expect(byScope['location']!.locationId, equals(_validLocId));
        expect(byScope['location']!.roleLabel, equals('Supervisor'));
      },
    );

    test(
      'emits the additive grants subselect alongside the existing '
      'projection without renaming locationId',
      () async {
        final pool = _TeamUsersPool();
        final repo = UsersRepository(TenantTransactionWrapper(pool));

        await repo.listTeamUsers(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
        );

        // Pull the team-users SELECT (skip SET LOCAL preamble).
        final selectSql = pool.transactions.single.executedSql.firstWhere(
          (sql) => sql.contains('from users u'),
          orElse: () => '',
        );
        expect(selectSql, isNotEmpty);
        // Backward-compat: existing coalesce projection still emitted.
        expect(
          selectSql,
          contains('coalesce(ur.location_id::text, u.primary_location_id::text)'),
        );
        // New surface: per-user grants subselect + effective-location lookup.
        expect(selectSql, contains('jsonb_agg'));
        expect(selectSql, contains('user_effective_locations uel'));
        expect(selectSql, contains('source_user_role_id = urg.user_role_id'));
        // Active-only filter on the grants aggregate (mirror the lateral).
        expect(selectSql, contains('urg.revoked_at is null'));
        expect(selectSql, contains('urg.valid_from <= now()'));
        // Authoritative role-label join so per-grant labels are
        // resolved server-side and never depend on the client's
        // role-catalog load order.
        expect(selectSql, contains('left join roles rg'));
        expect(selectSql, contains('rg.display_name'));
      },
    );

    test(
      'role_label falls back to the raw role_id when the roles row is '
      'missing (defense-in-depth)',
      () async {
        final pool = _TeamUsersPool(
          teamUserRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _validUserId,
              'email': 'orphan@example.test',
              'display_name': 'Orphan Role',
              'role_id': 'role-owner',
              'role_label': 'Owner',
              'status': 'active',
              'user_role_id': _opWideGrantId,
              'location_id': null,
              'location_label': null,
              'mfa_enrolled': false,
              'mfa_removal_request_id': null,
              'last_active_at': null,
              'grants': <Map<String, Object?>>[
                <String, Object?>{
                  'user_role_id': _opWideGrantId,
                  'role_id': 'role-orphan',
                  // role_label deliberately omitted — emulates a
                  // FK-detached row or a future migration that
                  // lands rows ahead of the join.
                  'scope_type': 'operator_wide',
                  'effective_location_ids': const <String>[],
                },
              ],
            },
          ],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listTeamUsers(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
        );
        // Falls back to the raw role_id so the row never crashes
        // and the dialog still renders something deterministic.
        expect(rows.single.grants.single.roleLabel, equals('role-orphan'));
      },
    );

    test('users with zero active grants project an empty grants list',
        () async {
      final pool = _TeamUsersPool(
        teamUserRows: <PostgresRow>[
          <String, Object?>{
            'user_id': _validUserId,
            'email': 'no-grants@example.test',
            'display_name': 'No Grants',
            'role_id': 'role-staff',
            'role_label': 'Staff',
            'status': 'active',
            'user_role_id': null,
            'location_id': null,
            'location_label': null,
            'mfa_enrolled': false,
            'mfa_removal_request_id': null,
            'last_active_at': null,
            'grants': const <Map<String, Object?>>[],
          },
        ],
      );
      final repo = UsersRepository(TenantTransactionWrapper(pool));
      final rows = await repo.listTeamUsers(
        operatorId: _validOpId,
        locationId: _validLocId,
        actorUserId: _validUserId,
      );
      expect(rows.single.grants, isEmpty);
    });

    test(
      'tolerates a JSON-encoded string from the postgres jsonb cast',
      () async {
        // The SQL casts jsonb_agg(...)::text so the postgres driver may
        // return the column as a String; `_decodeGrantsJson` parses it.
        const grantsText =
            '[{"user_role_id":"$_opWideGrantId","role_id":"role-owner",'
            '"role_label":"Owner",'
            '"scope_type":"operator_wide","org_unit_id":null,'
            '"location_id":null,"source_org_unit_id":null,'
            '"effective_location_ids":[],'
            '"valid_from":"2026-04-01T00:00:00Z",'
            '"valid_until":null,"revoked_at":null}]';
        final pool = _TeamUsersPool(
          teamUserRows: <PostgresRow>[
            <String, Object?>{
              'user_id': _validUserId,
              'email': 'string@example.test',
              'display_name': 'String Encoded',
              'role_id': 'role-owner',
              'role_label': 'Owner',
              'status': 'active',
              'user_role_id': _opWideGrantId,
              'location_id': null,
              'location_label': null,
              'mfa_enrolled': false,
              'mfa_removal_request_id': null,
              'last_active_at': null,
              'grants': grantsText,
            },
          ],
        );
        final repo = UsersRepository(TenantTransactionWrapper(pool));
        final rows = await repo.listTeamUsers(
          operatorId: _validOpId,
          locationId: _validLocId,
          actorUserId: _validUserId,
        );
        expect(rows.single.grants, hasLength(1));
        expect(rows.single.grants.single.scopeType, equals('operator_wide'));
        expect(rows.single.grants.single.userRoleId, equals(_opWideGrantId));
        expect(rows.single.grants.single.roleLabel, equals('Owner'));
      },
    );
  });
}

class _TeamUsersPool implements PostgresPool {
  _TeamUsersPool({this.teamUserRows = const <PostgresRow>[]});

  final List<PostgresRow> teamUserRows;
  final List<_TeamUsersTransaction> transactions = <_TeamUsersTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _TeamUsersTransaction(teamUserRows: teamUserRows);
    transactions.add(tx);
    return tx;
  }
}

class _TeamUsersTransaction extends PostgresTransaction {
  _TeamUsersTransaction({required this.teamUserRows});

  final List<PostgresRow> teamUserRows;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from users u')) return teamUserRows;
    return <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 1;
  }

  @override
  Future<void> commit() async {
    if (_finalized) return;
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    if (_finalized) return;
    _finalized = true;
  }
}
