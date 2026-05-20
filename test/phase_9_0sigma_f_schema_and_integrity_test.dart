// Phase 9.0Σ.f — hash-chained audit_logs schema + pure-logic tests.
//
// Bucket 5g of the 2026-05-20 test-suite tightening audit: split off
// from the original `phase_9_0sigma_f_audit_logs_test.dart` (2,144 lines).
// Filename preserves the `phase_9_0sigma_f_` prefix per CLAUDE.md
// Authority Order (the prefix is load-bearing for the migration/test
// pairing convention).
//
// This file owns the migration shape, RLS lint, and pure hash/codec
// unit-level contracts. The CLI / orchestrator / runbook surfaces live
// in `phase_9_0sigma_f_cli_and_runbook_test.dart` (companion file).
//
// Groups in this file:
//
//   1. Migration shape — declares audit_logs partitioned by chain_date
//      with `actor_kind`, prev/row_hash columns, the chain trigger,
//      pg_partman registration intent, tenant-leading indexes,
//      wrapper-only RLS, and append-only grants. Also covers the
//      `audit_chain_anchors` ledger schema and grants.
//
//   2. RLS lint posture — runs `RlsPolicyLintRunner` against the new
//      migration and proves it passes.
//
//   3. Pure hash-chain recomputation — `AuditChainHasher` reproduces
//      the SQL trigger byte-for-byte at unit scale (small chains,
//      explicit row/prev hash mismatch shapes). The 100-row scale +
//      boundary coverage is in the chain E2E file.
//
//   4. `AnchorEvidenceCodec` — canonical JSON encode/decode round-trip
//      and key-order determinism.
//
//   5. `anchorBlobName` — deterministic blob path layout, lowercased
//      operator UUID.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/audit_anchor/audit_anchor.dart';
import '../tool/rls_policy_lint.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202604280005_phase_9_0sigma_f_audit_logs.sql',
  );

  // ───────────────────────────────────────────────────────────────────
  group('Phase 9.0Σ.f migration shape', () {
    test('declares audit_logs partitioned by chain_date with the locked '
        'column shape (actor_kind, prev/row_hash, jsonb_typeof + size '
        'CHECKs, no TIMESTAMP WITHOUT TIME ZONE)', () {
      expect(
        migrationSql,
        contains('create table if not exists public.audit_logs'),
      );
      expect(migrationSql, contains('id bigserial'));
      expect(migrationSql, contains('operator_id uuid not null'));
      expect(migrationSql, contains('location_id uuid null'));
      expect(migrationSql, contains('chain_date date not null'));
      expect(
        migrationSql,
        contains('occurred_at timestamptz not null default now()'),
      );
      expect(
        migrationSql,
        contains("check (actor_kind in ('user', 'service'))"),
      );
      expect(migrationSql, contains('actor_user_id uuid null'));
      expect(migrationSql, contains('actor_principal_id text null'));
      expect(migrationSql, contains('target_kind text null'));
      expect(migrationSql, contains('target_id text null'));
      expect(migrationSql, contains('action text not null'));
      expect(
        migrationSql,
        contains("payload jsonb not null default '{}'::jsonb"),
      );
      expect(
        migrationSql,
        contains("check (jsonb_typeof(payload) = 'object')"),
      );
      expect(
        migrationSql,
        contains('check (octet_length(payload::text) <= 262144)'),
      );
      expect(migrationSql, contains('prev_row_hash bytea null'));
      expect(migrationSql, contains('row_hash bytea not null'));
      // PK includes the partition key (chain_date) and is tenant-
      // leading per CLAUDE.md RLS performance discipline.
      expect(
        migrationSql,
        contains('primary key (operator_id, chain_date, id)'),
      );
      expect(migrationSql, contains('partition by range (chain_date)'));
      // No TIMESTAMP WITHOUT TIME ZONE anywhere.
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('timestamp without time zone')),
      );
    });

    test('actor_shape CHECK enforces exactly-one of '
        '(actor_user_id, actor_principal_id) per actor_kind', () {
      // The SQL CHECK is a single-line OR pair; the test asserts both
      // arms appear so a future contributor cannot relax one half
      // without the other.
      expect(migrationSql, contains('actor_kind = \'user\''));
      expect(migrationSql, contains('actor_user_id is not null'));
      expect(migrationSql, contains('actor_principal_id is null'));
      expect(migrationSql, contains('actor_kind = \'service\''));
      expect(migrationSql, contains('actor_principal_id is not null'));
      expect(migrationSql, contains('actor_user_id is null'));
    });

    test('chain_date is constrained to match occurred_at UTC date '
        'so the verifier can walk a chain by (operator_id, '
        'chain_date) without trusting external chain_date', () {
      expect(
        migrationSql,
        contains('audit_logs_chain_date_matches_occurred_at'),
      );
      expect(
        migrationSql,
        contains("chain_date = (occurred_at at time zone 'UTC')::date"),
      );
    });

    test('BEFORE INSERT trigger function locks the chain on '
        '(operator_id, chain_date), reads the prior row_hash, and '
        'computes row_hash = SHA-256(prev || canonical) — bounded '
        'chain scope per Scale Pressure-Test Guardrail #1', () {
      expect(
        migrationSql,
        contains('create or replace function public.audit_logs_set_chain()'),
      );
      // Advisory-lock on operator + chain_date (NOT a global chain).
      expect(migrationSql, contains('pg_advisory_xact_lock'));
      expect(
        migrationSql,
        contains("new.operator_id::text || ':' || new.chain_date::text"),
      );
      // Previous-row lookup IS scoped to (operator_id, chain_date).
      expect(migrationSql, contains('where operator_id = new.operator_id'));
      expect(migrationSql, contains('and chain_date  = new.chain_date'));
      expect(migrationSql, contains('order by id desc'));
      expect(migrationSql, contains('limit 1'));
      // Hash composition matches the locked formula:
      //   row_hash = digest(coalesce(prev,''::bytea) || canonical, 'sha256').
      expect(
        migrationSql,
        contains("coalesce(new.prev_row_hash, ''::bytea) || canonical"),
      );
      expect(migrationSql, contains("'sha256'"));
      // Trigger is BEFORE INSERT FOR EACH ROW (only point a producer
      // cannot bypass).
      expect(migrationSql, contains('before insert on public.audit_logs'));
      expect(
        migrationSql,
        contains('execute function public.audit_logs_set_chain()'),
      );
    });

    test('pg_partman registration uses the verified live-Azure '
        'public.* schema (per phase_11a_decision_register.md Lock 2 '
        'and db/verification/202604250006_..._audits.sql); '
        'idempotent DO block + premake = 7 + maintenance intent', () {
      // Extension declared.
      expect(
        migrationSql,
        contains('create extension if not exists pg_partman'),
      );
      // Verified function/table names (NOT the partman.* schema).
      // Live result 2026-04-26: Azure installed pg_partman into the
      // public schema, so partman.create_parent / partman.part_config
      // would fail at apply time.
      expect(migrationSql, contains('from public.part_config'));
      expect(migrationSql, contains('public.create_parent'));
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('partman.create_parent')),
        reason:
            'partman.create_parent is the wrong schema on Azure; '
            'use public.create_parent (live-verified 2026-04-26)',
      );
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('partman.part_config')),
        reason:
            'partman.part_config is the wrong schema on Azure; '
            'use public.part_config (live-verified 2026-04-26)',
      );
      // Verified argument shape from the audit script.
      expect(migrationSql, contains("p_parent_table  := 'public.audit_logs'"));
      expect(migrationSql, contains("p_control       := 'chain_date'"));
      expect(
        migrationSql,
        contains("p_interval      := '1 day'"),
        reason:
            'pg_partman v5 takes a Postgres interval expression, '
            'not the legacy v4 keyword',
      );
      expect(migrationSql, contains('p_premake       := 7'));
      expect(
        migrationSql,
        contains('p_default_table := false'),
        reason:
            'matches the verified usage_logs registration in '
            'db/verification/202604250006_..._audits.sql',
      );
      expect(
        migrationSql,
        contains('p_jobmon        := false'),
        reason:
            'matches the verified usage_logs registration; pg_jobmon '
            'is not present on Azure',
      );
      // Maintenance intent (run_maintenance, not partman.run_maintenance).
      expect(
        migrationSql,
        contains('public.run_maintenance(p_analyze := true)'),
      );
      // The UPDATE on part_config asserts the premake / retention /
      // infinite-partitions configuration we expect on every run.
      expect(migrationSql, contains('update public.part_config'));
      expect(migrationSql, contains('premake                  = 7'));
      expect(migrationSql, contains('retention_keep_table     = true'));
      expect(migrationSql, contains('infinite_time_partitions = true'));
    });

    test('tenant-leading indexes for chain, actor, target, and time '
        'lookups (item 4 / RLS performance discipline)', () {
      // Chain walk uses the PK; actor/target/time get explicit
      // tenant-leading indexes so policy evaluation folds into the
      // index probe.
      expect(
        migrationSql,
        contains(
          'create index if not exists audit_logs_actor_user_idx\n'
          '  on public.audit_logs (operator_id, actor_user_id, '
          'occurred_at)',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create index if not exists audit_logs_actor_principal_idx\n'
          '  on public.audit_logs (operator_id, actor_principal_id, '
          'occurred_at)',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create index if not exists audit_logs_target_idx\n'
          '  on public.audit_logs (operator_id, target_kind, '
          'target_id, occurred_at)',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create index if not exists audit_logs_time_idx\n'
          '  on public.audit_logs (operator_id, occurred_at);',
        ),
      );
    });

    test('RLS policies use the 9.0Σ.b wrapper, not bare '
        'current_setting (item 4)', () {
      expect(
        migrationSql,
        contains('alter table public.audit_logs enable row level security'),
      );
      expect(
        migrationSql,
        contains('create policy "audit_logs_per_tenant_select"'),
      );
      expect(
        migrationSql,
        contains('create policy "audit_logs_per_tenant_insert"'),
      );
      expect(
        migrationSql,
        contains('operator_id = public.app_current_operator()'),
      );
      // Bare current_setting('app.*') must NOT appear in policy
      // bodies. The lint group below also catches this; the literal
      // guard surfaces a regression before the lint runs.
      expect(
        migrationSql,
        isNot(contains("current_setting('app.operator_id'")),
      );
    });

    test('append-only grants: SELECT/INSERT only for runtime roles, '
        'UPDATE/DELETE explicitly REVOKEd', () {
      for (final role in <String>['service_role', 'forge_admin']) {
        expect(
          migrationSql,
          contains('grant select, insert on public.audit_logs to $role'),
          reason: '$role gets read + append only',
        );
        expect(
          migrationSql,
          contains('revoke update, delete on public.audit_logs from $role'),
          reason:
              '$role explicitly loses UPDATE/DELETE so a future '
              'wider grant cannot weaken the append-only posture',
        );
        expect(
          migrationSql,
          contains('grant usage on sequence public.audit_logs_id_seq to $role'),
          reason: '$role needs the bigserial sequence to allocate ids',
        );
      }
      // PUBLIC stays revoked.
      expect(
        migrationSql,
        contains('revoke all on public.audit_logs from public'),
      );
    });

    test('audit_chain_anchors append-only ledger: bytea terminal_row_hash, '
        'blob_uri/etag CHECKs, RLS via wrapper, INSERT-only grants, '
        'UPDATE/DELETE REVOKEd', () {
      expect(
        migrationSql,
        contains('create table if not exists public.audit_chain_anchors'),
      );
      expect(migrationSql, contains('terminal_row_hash bytea not null'));
      expect(migrationSql, contains('terminal_row_id bigint not null'));
      expect(migrationSql, contains('row_count bigint not null'));
      expect(
        migrationSql,
        contains('check (char_length(blob_uri) between 1 and 2048)'),
      );
      expect(
        migrationSql,
        contains('check (char_length(blob_etag) between 1 and 256)'),
      );
      expect(migrationSql, contains('primary key (operator_id, chain_date)'));
      // Tenant-leading retrieval index.
      expect(
        migrationSql,
        contains(
          'create index if not exists audit_chain_anchors_recent_idx\n'
          '  on public.audit_chain_anchors (operator_id, chain_date desc)',
        ),
      );
      // Wrapper-only RLS.
      expect(
        migrationSql,
        contains('create policy "audit_chain_anchors_per_tenant_select"'),
      );
      expect(
        migrationSql,
        contains('create policy "audit_chain_anchors_per_tenant_insert"'),
      );
      // Append-only grant shape (SELECT + INSERT, UPDATE/DELETE
      // revoked).
      for (final role in <String>['service_role', 'forge_admin']) {
        expect(
          migrationSql,
          contains(
            'grant select, insert on public.audit_chain_anchors to $role',
          ),
        );
        expect(
          migrationSql,
          contains(
            'revoke update, delete on public.audit_chain_anchors from $role',
          ),
        );
      }
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('Phase 9.0Σ.f RLS lint', () {
    test('migration passes the policy-aware lint', () {
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280005_phase_9_0sigma_f_audit_logs.sql': migrationSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            'audit_logs policies must read GUCs through the '
            '9.0Σ.b wrappers; violations: ${result.violations}',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('AuditChainHasher (pure recomputation)', () {
    const hasher = AuditChainHasher();

    test('canonicalPayload uses Unit Separator-delimited UTF-8 fields '
        'with NULL collapsed to empty strings (matches the SQL trigger)', () {
      final row = _buildRow(
        id: BigInt.from(1),
        operatorId: _opA,
        // Deliberate: location_id is NULL on this row.
        locationId: null,
        chainDate: DateTime.utc(2026, 4, 27),
        // 7th arg = millisecond, 8th = microsecond. 789 micros gives
        // the canonical to_char(... 'US') = "000789" formatted output.
        occurredAt: DateTime.utc(2026, 4, 27, 12, 34, 56, 0, 789),
        actorKind: 'user',
        actorUserId: _userA,
        actorPrincipalId: null,
        targetKind: 'user',
        targetId: _userA,
        action: 'auth.session.login',
        payloadText: '{"event_id": "evt-1"}',
        prevRowHash: null,
        rowHash: Uint8List(32),
      );
      final canonical = hasher.canonicalPayload(row);

      // Reproduce the expected layout in pure Dart so the test fails
      // if either the helper or the trigger drifts.
      final expected = utf8.encode(
        '$_opA\x1f'
        '\x1f' // location_id NULL → empty
        '2026-04-27\x1f'
        '2026-04-27T12:34:56.000789Z\x1f'
        'user\x1f'
        '$_userA\x1f'
        '\x1f' // actor_principal_id NULL → empty
        'user\x1f'
        '$_userA\x1f'
        'auth.session.login\x1f'
        '{"event_id": "evt-1"}\x1f',
      );
      expect(canonical, equals(expected));
    });

    test('recomputeRowHash chains rows: row_hash[i] = '
        'SHA256(row_hash[i-1] || canonical[i]); row_hash[0] uses '
        'prev = empty bytes (no previous row)', () {
      // Build a 2-row chain with deterministic content. We compute
      // the expected hashes the same way the SQL trigger would, then
      // assert the helper agrees.
      final row1 = _buildRow(
        id: BigInt.from(1),
        operatorId: _opA,
        locationId: _locA,
        chainDate: DateTime.utc(2026, 4, 27),
        occurredAt: DateTime.utc(2026, 4, 27, 8),
        actorKind: 'user',
        actorUserId: _userA,
        actorPrincipalId: null,
        targetKind: null,
        targetId: null,
        action: 'session.login',
        payloadText: '{"a": 1}',
        prevRowHash: null,
        rowHash: Uint8List(32),
      );
      final row1Hash = Uint8List.fromList(
        sha256.convert(hasher.canonicalPayload(row1)).bytes,
      );

      final row2 = _buildRow(
        id: BigInt.from(2),
        operatorId: _opA,
        locationId: _locA,
        chainDate: DateTime.utc(2026, 4, 27),
        occurredAt: DateTime.utc(2026, 4, 27, 8, 30),
        actorKind: 'user',
        actorUserId: _userA,
        actorPrincipalId: null,
        targetKind: null,
        targetId: null,
        action: 'session.refresh',
        payloadText: '{"a": 2}',
        prevRowHash: row1Hash,
        rowHash: Uint8List(32),
      );
      final row2Hash = Uint8List.fromList(
        sha256.convert(<int>[
          ...row1Hash,
          ...hasher.canonicalPayload(row2),
        ]).bytes,
      );

      expect(hasher.recomputeRowHash(row1), equals(row1Hash));
      expect(hasher.recomputeRowHash(row2), equals(row2Hash));
    });

    test('verifyChain returns no violations for a clean chain', () {
      final clean = _buildCleanChain();
      expect(hasher.verifyChain(clean), isEmpty);
    });

    test('verifyChain detects retroactive payload mutation '
        '(row_hash mismatch)', () {
      final clean = _buildCleanChain();
      // Mutate the payload of row[1] WITHOUT recomputing row_hash.
      // The trigger would have produced a different hash; verifyChain
      // catches the drift.
      final mutated = <AuditLogRow>[
        clean[0],
        _buildRow(
          id: clean[1].id,
          operatorId: clean[1].operatorId,
          locationId: clean[1].locationId,
          chainDate: clean[1].chainDate,
          occurredAt: clean[1].occurredAt,
          actorKind: clean[1].actorKind,
          actorUserId: clean[1].actorUserId,
          actorPrincipalId: clean[1].actorPrincipalId,
          targetKind: clean[1].targetKind,
          targetId: clean[1].targetId,
          action: clean[1].action,
          payloadText: '{"a": 9999}', // tampered
          prevRowHash: clean[1].prevRowHash,
          rowHash: clean[1].rowHash, // unchanged → mismatches recompute
        ),
        clean[2],
      ];
      final violations = hasher.verifyChain(mutated);
      expect(
        violations.any(
          (v) =>
              v.rowId == clean[1].id &&
              v.kind == ChainHashViolationKind.rowHashMismatch,
        ),
        isTrue,
        reason:
            'row[1] payload tampered → row_hash recomputation '
            'must flag a violation',
      );
    });

    test('verifyChain detects retroactive prev_row_hash forging '
        '(prev_hash mismatch)', () {
      final clean = _buildCleanChain();
      // Replace row[1].prev_row_hash with a different value; the
      // chain is now broken — row[1] claims to follow some other
      // row, not row[0].
      final forged = <AuditLogRow>[
        clean[0],
        _buildRow(
          id: clean[1].id,
          operatorId: clean[1].operatorId,
          locationId: clean[1].locationId,
          chainDate: clean[1].chainDate,
          occurredAt: clean[1].occurredAt,
          actorKind: clean[1].actorKind,
          actorUserId: clean[1].actorUserId,
          actorPrincipalId: clean[1].actorPrincipalId,
          targetKind: clean[1].targetKind,
          targetId: clean[1].targetId,
          action: clean[1].action,
          payloadText: clean[1].payloadText,
          prevRowHash: Uint8List(32), // forged "previous" hash
          rowHash: clean[1].rowHash,
        ),
        clean[2],
      ];
      final violations = hasher.verifyChain(forged);
      expect(
        violations.any(
          (v) =>
              v.rowId == clean[1].id &&
              v.kind == ChainHashViolationKind.prevHashMismatch,
        ),
        isTrue,
        reason: 'row[1] prev_row_hash mutated to mask its predecessor',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('AnchorEvidenceCodec', () {
    const codec = AnchorEvidenceCodec();

    test('encode produces canonical JSON: keys sorted alphabetically, '
        'no leading whitespace, deterministic across runs', () {
      final evidence = AnchorEvidence(
        schemaVersion: 1,
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowId: BigInt.from(42),
        terminalRowHashHex:
            '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        rowCount: BigInt.from(3),
        anchoredAt: DateTime.utc(2026, 4, 28, 2, 0, 0),
      );
      final bytes1 = codec.encode(evidence);
      final bytes2 = codec.encode(evidence);
      expect(bytes1, equals(bytes2));
      final text = utf8.decode(bytes1);
      // Check key order is alphabetical (anchored_at, chain_date,
      // operator_id, row_count, schema_version, terminal_row_hash_hex,
      // terminal_row_id).
      final keyOrder = <String>[
        'anchored_at',
        'chain_date',
        'operator_id',
        'row_count',
        'schema_version',
        'terminal_row_hash_hex',
        'terminal_row_id',
      ];
      var lastIndex = -1;
      for (final key in keyOrder) {
        final pos = text.indexOf('"$key"');
        expect(
          pos,
          greaterThan(lastIndex),
          reason: 'key "$key" must follow alphabetical predecessors',
        );
        lastIndex = pos;
      }
    });

    test('encode → decode round-trip preserves every field', () {
      final original = AnchorEvidence(
        schemaVersion: 1,
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowId: BigInt.from(42),
        terminalRowHashHex: 'a' * 64,
        rowCount: BigInt.from(3),
        anchoredAt: DateTime.utc(2026, 4, 28, 2, 30, 0),
      );
      final decoded = codec.decode(codec.encode(original));
      expect(decoded.schemaVersion, equals(1));
      expect(decoded.operatorId, equals(_opA));
      expect(decoded.chainDate, equals(DateTime.utc(2026, 4, 27)));
      expect(decoded.terminalRowId, equals(BigInt.from(42)));
      expect(decoded.terminalRowHashHex, equals('a' * 64));
      expect(decoded.rowCount, equals(BigInt.from(3)));
      expect(decoded.anchoredAt, equals(DateTime.utc(2026, 4, 28, 2, 30, 0)));
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('anchorBlobName', () {
    test('layout is audit_anchors/<lowercase-operator>/<YYYY-MM-DD>.json '
        'so the path is stable across uppercase / lowercase UUID '
        'variants', () {
      expect(
        anchorBlobName(
          operatorId: '11111111-AAAA-1111-1111-111111111111',
          chainDate: DateTime.utc(2026, 4, 27),
        ),
        equals(
          'audit_anchors/'
          '11111111-aaaa-1111-1111-111111111111/'
          '2026-04-27.json',
        ),
      );
    });
  });
}

// ─── helpers ──────────────────────────────────────────────────────────

String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}

AuditLogRow _buildRow({
  required BigInt id,
  required String operatorId,
  required String? locationId,
  required DateTime chainDate,
  required DateTime occurredAt,
  required String actorKind,
  required String? actorUserId,
  required String? actorPrincipalId,
  required String? targetKind,
  required String? targetId,
  required String action,
  required String payloadText,
  required Uint8List? prevRowHash,
  required Uint8List rowHash,
}) {
  return AuditLogRow(
    id: id,
    operatorId: operatorId,
    locationId: locationId,
    chainDate: chainDate,
    occurredAt: occurredAt,
    actorKind: actorKind,
    actorUserId: actorUserId,
    actorPrincipalId: actorPrincipalId,
    targetKind: targetKind,
    targetId: targetId,
    action: action,
    payloadText: payloadText,
    prevRowHash: prevRowHash,
    rowHash: rowHash,
  );
}

/// Builds a 3-row chain whose row_hash values agree with the trigger.
/// Each row's rowHash is computed from the canonical bytes the helper
/// produces, so the chain is internally consistent. Tests can mutate
/// individual rows to simulate retroactive tampering.
List<AuditLogRow> _buildCleanChain() {
  const hasher = AuditChainHasher();
  final base = <Map<String, Object?>>[
    <String, Object?>{
      'id': BigInt.from(1),
      'occurred_at': DateTime.utc(2026, 4, 27, 8),
      'action': 'session.login',
      'payload_text': '{"a": 1}',
    },
    <String, Object?>{
      'id': BigInt.from(2),
      'occurred_at': DateTime.utc(2026, 4, 27, 8, 30),
      'action': 'session.refresh',
      'payload_text': '{"a": 2}',
    },
    <String, Object?>{
      'id': BigInt.from(3),
      'occurred_at': DateTime.utc(2026, 4, 27, 9),
      'action': 'session.logout',
      'payload_text': '{"a": 3}',
    },
  ];
  final out = <AuditLogRow>[];
  Uint8List? prev;
  for (final entry in base) {
    final row = _buildRow(
      id: entry['id']! as BigInt,
      operatorId: _opA,
      locationId: _locA,
      chainDate: DateTime.utc(2026, 4, 27),
      occurredAt: entry['occurred_at']! as DateTime,
      actorKind: 'user',
      actorUserId: _userA,
      actorPrincipalId: null,
      targetKind: null,
      targetId: null,
      action: entry['action']! as String,
      payloadText: entry['payload_text']! as String,
      prevRowHash: prev,
      rowHash: Uint8List(32),
    );
    final canonical = hasher.canonicalPayload(row);
    final hash = Uint8List.fromList(
      sha256.convert(<int>[...?prev, ...canonical]).bytes,
    );
    out.add(
      _buildRow(
        id: row.id,
        operatorId: row.operatorId,
        locationId: row.locationId,
        chainDate: row.chainDate,
        occurredAt: row.occurredAt,
        actorKind: row.actorKind,
        actorUserId: row.actorUserId,
        actorPrincipalId: row.actorPrincipalId,
        targetKind: row.targetKind,
        targetId: row.targetId,
        action: row.action,
        payloadText: row.payloadText,
        prevRowHash: prev,
        rowHash: hash,
      ),
    );
    prev = hash;
  }
  return out;
}
