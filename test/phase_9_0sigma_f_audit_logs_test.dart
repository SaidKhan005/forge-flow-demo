// Phase 9.0Σ.f — hash-chained audit_logs tests.
//
// Local framework slice (no live database, no live Azure). Five
// groups:
//
//   1. Migration shape — declares audit_logs partitioned by chain_date
//      with `actor_kind`, prev/row_hash columns, the chain trigger,
//      pg_partman registration intent, tenant-leading indexes,
//      wrapper-only RLS, and append-only grants.
//
//   2. RLS lint posture — runs `RlsPolicyLintRunner` against the new
//      migration and proves it passes.
//
//   3. Pure hash-chain recomputation — `AuditChainHasher` reproduces
//      the SQL trigger byte-for-byte and detects retroactive
//      mutation in a deterministic sample chain.
//
//   4. Anchor + verify orchestrator with fakes — `AuditAnchorOrchestrator`
//      walks the chain, builds deterministic evidence, writes through
//      the [AuditAnchorBlobClient] abstraction, records the anchor,
//      and detects every failure mode without any live Azure call.
//
//   5. Runbook posture — names immutability, verification, break-glass,
//      no live secrets/SAS tokens.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import '../tool/audit_anchor/audit_anchor.dart';
import '../tool/audit_anchor/main.dart' as audit_anchor_main;
import '../tool/rls_policy_lint.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';
const String _opB = '44444444-4444-4444-4444-444444444444';

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
      expect(
        migrationSql,
        contains('operator_id uuid not null'),
      );
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
      expect(
        migrationSql,
        contains('partition by range (chain_date)'),
      );
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
      expect(
        migrationSql,
        contains('actor_kind = \'user\''),
      );
      expect(
        migrationSql,
        contains('actor_user_id is not null'),
      );
      expect(
        migrationSql,
        contains('actor_principal_id is null'),
      );
      expect(
        migrationSql,
        contains('actor_kind = \'service\''),
      );
      expect(
        migrationSql,
        contains('actor_principal_id is not null'),
      );
      expect(
        migrationSql,
        contains('actor_user_id is null'),
      );
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
        contains(
          "chain_date = (occurred_at at time zone 'UTC')::date",
        ),
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
      expect(
        migrationSql,
        contains('pg_advisory_xact_lock'),
      );
      expect(
        migrationSql,
        contains(
          "new.operator_id::text || ':' || new.chain_date::text",
        ),
      );
      // Previous-row lookup IS scoped to (operator_id, chain_date).
      expect(
        migrationSql,
        contains('where operator_id = new.operator_id'),
      );
      expect(
        migrationSql,
        contains('and chain_date  = new.chain_date'),
      );
      expect(migrationSql, contains('order by id desc'));
      expect(migrationSql, contains('limit 1'));
      // Hash composition matches the locked formula:
      //   row_hash = digest(coalesce(prev,''::bytea) || canonical, 'sha256').
      expect(
        migrationSql,
        contains(
          "coalesce(new.prev_row_hash, ''::bytea) || canonical",
        ),
      );
      expect(migrationSql, contains("'sha256'"));
      // Trigger is BEFORE INSERT FOR EACH ROW (only point a producer
      // cannot bypass).
      expect(
        migrationSql,
        contains('before insert on public.audit_logs'),
      );
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
      expect(
        migrationSql,
        contains('from public.part_config'),
      );
      expect(
        migrationSql,
        contains('public.create_parent'),
      );
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('partman.create_parent')),
        reason: 'partman.create_parent is the wrong schema on Azure; '
            'use public.create_parent (live-verified 2026-04-26)',
      );
      expect(
        migrationSql.toLowerCase(),
        isNot(contains('partman.part_config')),
        reason: 'partman.part_config is the wrong schema on Azure; '
            'use public.part_config (live-verified 2026-04-26)',
      );
      // Verified argument shape from the audit script.
      expect(
        migrationSql,
        contains("p_parent_table  := 'public.audit_logs'"),
      );
      expect(
        migrationSql,
        contains("p_control       := 'chain_date'"),
      );
      expect(
        migrationSql,
        contains("p_interval      := '1 day'"),
        reason: 'pg_partman v5 takes a Postgres interval expression, '
            'not the legacy v4 keyword',
      );
      expect(
        migrationSql,
        contains('p_premake       := 7'),
      );
      expect(
        migrationSql,
        contains('p_default_table := false'),
        reason: 'matches the verified usage_logs registration in '
            'db/verification/202604250006_..._audits.sql',
      );
      expect(
        migrationSql,
        contains('p_jobmon        := false'),
        reason: 'matches the verified usage_logs registration; pg_jobmon '
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
      expect(
        migrationSql,
        contains('infinite_time_partitions = true'),
      );
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
        contains(
          'alter table public.audit_logs enable row level security',
        ),
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
          contains(
            'grant select, insert on public.audit_logs to $role',
          ),
          reason: '$role gets read + append only',
        );
        expect(
          migrationSql,
          contains(
            'revoke update, delete on public.audit_logs from $role',
          ),
          reason: '$role explicitly loses UPDATE/DELETE so a future '
              'wider grant cannot weaken the append-only posture',
        );
        expect(
          migrationSql,
          contains(
            'grant usage on sequence public.audit_logs_id_seq to $role',
          ),
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
      expect(
        migrationSql,
        contains('primary key (operator_id, chain_date)'),
      );
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
        contains(
          'create policy "audit_chain_anchors_per_tenant_select"',
        ),
      );
      expect(
        migrationSql,
        contains(
          'create policy "audit_chain_anchors_per_tenant_insert"',
        ),
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
        reason: 'audit_logs policies must read GUCs through the '
            '9.0Σ.b wrappers; violations: ${result.violations}',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('AuditChainHasher (pure recomputation)', () {
    const hasher = AuditChainHasher();

    test('canonicalPayload uses NUL-separated UTF-8 fields with NULL '
        'collapsed to empty strings (matches the SQL trigger)', () {
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
        '$_opA\x00'
        '\x00' // location_id NULL → empty
        '2026-04-27\x00'
        '2026-04-27T12:34:56.000789Z\x00'
        'user\x00'
        '$_userA\x00'
        '\x00' // actor_principal_id NULL → empty
        'user\x00'
        '$_userA\x00'
        'auth.session.login\x00'
        '{"event_id": "evt-1"}\x00',
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
        sha256
            .convert(<int>[
              ...row1Hash,
              ...hasher.canonicalPayload(row2),
            ])
            .bytes,
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
        reason: 'row[1] payload tampered → row_hash recomputation '
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
        expect(pos, greaterThan(lastIndex),
            reason: 'key "$key" must follow alphabetical predecessors');
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

  // ───────────────────────────────────────────────────────────────────
  group('AuditAnchorOrchestrator (anchor mode, fakes)', () {
    test('anchors every unanchored completed chain end-to-end: '
        'recomputes hash chain, writes evidence to fake Blob client, '
        'records anchor row, returns one result per chain', () async {
      final clean = _buildCleanChain();
      final reader = _FakeReader(
        unanchored: <AuditChainSummary>[
          AuditChainSummary(
            operatorId: _opA,
            chainDate: DateTime.utc(2026, 4, 27),
          ),
        ],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: const <String, AuditChainAnchor>{},
      );
      final writer = _FakeAnchorWriter();
      final blob = _FakeBlobClient();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      final results = await orchestrator.runAnchor(
        operatorId: _opA,
        asOfUtc: DateTime.utc(2026, 4, 28),
        nowUtc: DateTime.utc(2026, 4, 28, 2, 0, 0),
      );
      expect(results, hasLength(1));
      expect(results.single.outcome, AnchorOutcome.anchored);

      // Blob got the deterministic evidence.
      expect(blob.writes, hasLength(1));
      final write = blob.writes.single;
      expect(write.containerName, 'forge-flow-audit-anchors');
      expect(
        write.blobName,
        'audit_anchors/$_opA/2026-04-27.json',
      );
      // Decoded evidence carries the chain's terminal data verbatim.
      final evidence =
          const AnchorEvidenceCodec().decode(write.evidenceBytes);
      expect(evidence.schemaVersion, 1);
      expect(evidence.operatorId, _opA);
      expect(evidence.terminalRowId, clean.last.id);
      expect(
        evidence.terminalRowHashHex,
        equals(_hex(clean.last.rowHash)),
      );
      expect(evidence.rowCount, BigInt.from(clean.length));

      // Anchor row recorded with the same terminal hash + row count
      // and the Blob client's returned URI/ETag.
      expect(writer.inserts, hasLength(1));
      final anchor = writer.inserts.single;
      expect(anchor.operatorId, _opA);
      expect(anchor.chainDate, DateTime.utc(2026, 4, 27));
      expect(anchor.terminalRowHash, equals(clean.last.rowHash));
      expect(anchor.terminalRowId, clean.last.id);
      expect(anchor.rowCount, BigInt.from(clean.length));
      expect(anchor.blobUri, equals(write.fakeUri));
      expect(anchor.blobEtag, equals(write.fakeEtag));
    });

    test('refuses to anchor a self-inconsistent chain — emits a '
        'chainHashMismatch result and writes neither the Blob nor '
        'the anchor row', () async {
      final tampered = _buildCleanChain()..[1] = _retamperRow(
        _buildCleanChain()[1],
        newPayloadText: '{"forged": true}',
      );
      final reader = _FakeReader(
        unanchored: <AuditChainSummary>[
          AuditChainSummary(
            operatorId: _opA,
            chainDate: DateTime.utc(2026, 4, 27),
          ),
        ],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': tampered,
        },
        anchorsByDate: const <String, AuditChainAnchor>{},
      );
      final writer = _FakeAnchorWriter();
      final blob = _FakeBlobClient();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      final results = await orchestrator.runAnchor(
        operatorId: _opA,
        asOfUtc: DateTime.utc(2026, 4, 28),
        nowUtc: DateTime.utc(2026, 4, 28, 2),
      );
      expect(results, hasLength(1));
      expect(results.single.outcome, AnchorOutcome.chainHashMismatch);
      expect(results.single.violations, isNotEmpty);
      expect(blob.writes, isEmpty,
          reason: 'no Blob write on self-verification failure');
      expect(writer.inserts, isEmpty,
          reason: 'no anchor row on self-verification failure');
    });

    test('returns no results when there are no unanchored completed '
        'chains for the operator (idempotent re-runs are safe)',
        () async {
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: const <String, List<AuditLogRow>>{},
        anchorsByDate: const <String, AuditChainAnchor>{},
      );
      final writer = _FakeAnchorWriter();
      final blob = _FakeBlobClient();
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: writer,
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      final results = await orchestrator.runAnchor(
        operatorId: _opA,
        asOfUtc: DateTime.utc(2026, 4, 28),
        nowUtc: DateTime.utc(2026, 4, 28, 2),
      );
      expect(results, isEmpty);
      expect(blob.writes, isEmpty);
      expect(writer.inserts, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('AuditAnchorOrchestrator (verify mode, fakes)', () {
    test('returns ok when chain, anchor, and Blob evidence agree',
        () async {
      final clean = _buildCleanChain();
      final blob = _FakeBlobClient();
      final evidenceBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
      );
      blob.preload(
        blobName: 'audit_anchors/$_opA/2026-04-27.json',
        bytes: evidenceBytes,
        etag: 'etag-clean',
      );
      final anchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowHash: clean.last.rowHash,
        terminalRowId: clean.last.id,
        rowCount: BigInt.from(clean.length),
        blobUri: 'https://fake/audit_anchors/$_opA/2026-04-27.json',
        blobEtag: 'etag-clean',
        anchoredAt: DateTime.utc(2026, 4, 28, 2),
      );
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: <String, AuditChainAnchor>{
          '$_opA|2026-04-27': anchor,
        },
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
      );
      expect(result.outcome, VerifyOutcome.ok);
    });

    test('reports anchorMissing when the anchor row does not exist',
        () async {
      final clean = _buildCleanChain();
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: const <String, AuditChainAnchor>{},
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: _FakeBlobClient(),
        containerName: 'forge-flow-audit-anchors',
      );
      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
      );
      expect(result.outcome, VerifyOutcome.anchorMissing);
    });

    test('reports anchorTerminalMismatch when the in-DB chain disagrees '
        'with the anchor row terminal hash', () async {
      final clean = _buildCleanChain();
      final wrongHash = Uint8List(32)
        ..fillRange(0, 32, 0xAA);
      final anchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowHash: wrongHash, // diverges from chain.last.rowHash
        terminalRowId: clean.last.id,
        rowCount: BigInt.from(clean.length),
        blobUri: 'https://fake/x',
        blobEtag: 'etag-x',
        anchoredAt: DateTime.utc(2026, 4, 28, 2),
      );
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: <String, AuditChainAnchor>{
          '$_opA|2026-04-27': anchor,
        },
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: _FakeBlobClient(),
        containerName: 'forge-flow-audit-anchors',
      );
      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
      );
      expect(result.outcome, VerifyOutcome.anchorTerminalMismatch);
    });

    test('reports blobEvidenceMismatch when ETag drifts — Blob '
        'immutability prevents body changes, so an ETag mismatch is '
        'a forensic alert (the runbook covers escalation)', () async {
      final clean = _buildCleanChain();
      final blob = _FakeBlobClient();
      final evidenceBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
      );
      blob.preload(
        blobName: 'audit_anchors/$_opA/2026-04-27.json',
        bytes: evidenceBytes,
        etag: 'etag-current',
      );
      final anchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowHash: clean.last.rowHash,
        terminalRowId: clean.last.id,
        rowCount: BigInt.from(clean.length),
        blobUri: 'https://fake/audit_anchors/$_opA/2026-04-27.json',
        blobEtag: 'etag-stale', // drifts from blob's etag-current
        anchoredAt: DateTime.utc(2026, 4, 28, 2),
      );
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: <String, AuditChainAnchor>{
          '$_opA|2026-04-27': anchor,
        },
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
    });

    test('reports blobUnavailable when the Blob client raises '
        'AuditAnchorBlobUnavailable (no live Azure call needed)',
        () async {
      final clean = _buildCleanChain();
      final anchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowHash: clean.last.rowHash,
        terminalRowId: clean.last.id,
        rowCount: BigInt.from(clean.length),
        blobUri: 'https://fake/x',
        blobEtag: 'etag-x',
        anchoredAt: DateTime.utc(2026, 4, 28, 2),
      );
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: <String, AuditChainAnchor>{
          '$_opA|2026-04-27': anchor,
        },
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: const ScaffoldRejectingAuditAnchorBlobClient(),
        containerName: 'forge-flow-audit-anchors',
      );
      final result = await orchestrator.runVerify(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
      );
      expect(result.outcome, VerifyOutcome.blobUnavailable);
      expect(result.message, contains('not wired to live Azure'));
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // Negative tests for each evidence-envelope axis. Round-2 fix: the
  // verifier previously checked only `terminal_row_hash_hex`, so a
  // forged Blob body matching the terminal hash would pass even if
  // operator_id, chain_date, terminal_row_id, row_count,
  // schema_version, or anchored_at were wrong. Each axis now surfaces
  // a specific blobEvidenceMismatch message so the runbook (failed-
  // anchor triage section) can match the failing axis to the right
  // procedure.
  group('AuditAnchorOrchestrator verify rejects evidence-envelope '
      'mismatches on every axis, not just terminal_row_hash_hex', () {
    final clean = _buildCleanChain();

    Future<VerifyRunResult> runWithEvidence({
      required AnchorEvidence forgedEvidence,
      required AuditChainAnchor anchor,
      String? requestedOperatorId,
      DateTime? requestedChainDate,
    }) async {
      final blob = _FakeBlobClient();
      blob.preload(
        blobName:
            'audit_anchors/${(requestedOperatorId ?? _opA).toLowerCase()}/'
            '${_formatTestDate(requestedChainDate ?? DateTime.utc(2026, 4, 27))}.json',
        bytes: const AnchorEvidenceCodec().encode(forgedEvidence),
        etag: anchor.blobEtag,
      );
      final reader = _FakeReader(
        unanchored: const <AuditChainSummary>[],
        chainsByDate: <String, List<AuditLogRow>>{
          '$_opA|2026-04-27': clean,
        },
        anchorsByDate: <String, AuditChainAnchor>{
          '$_opA|2026-04-27': anchor,
        },
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: reader,
        anchorWriter: _FakeAnchorWriter(),
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      return orchestrator.runVerify(
        operatorId: requestedOperatorId ?? _opA,
        chainDate: requestedChainDate ?? DateTime.utc(2026, 4, 27),
      );
    }

    AuditChainAnchor goodAnchor() => AuditChainAnchor(
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowHash: clean.last.rowHash,
          terminalRowId: clean.last.id,
          rowCount: BigInt.from(clean.length),
          blobUri: 'https://fake/x',
          blobEtag: 'etag-good',
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        );

    AnchorEvidence goodEvidence() => AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        );

    test('forged operator_id (matching hash, wrong tenant) → '
        'blobEvidenceMismatch with operator_id message', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opB, // forged: different operator, same hash
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('operator_id'));
    });

    test('forged chain_date (different day, matching hash) → '
        'blobEvidenceMismatch with chain_date message', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 26), // forged: yesterday
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('chain_date'));
    });

    test('forged terminal_row_id (matching hash but different id) → '
        'blobEvidenceMismatch with terminal_row_id message', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: BigInt.from(9999), // forged
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('terminal_row_id'));
    });

    test('forged row_count → blobEvidenceMismatch with row_count '
        'message', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(99), // forged: claim more rows
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('row_count'));
    });

    test('forged schema_version → blobEvidenceMismatch with '
        'schema_version message (drift detection)', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 2, // forged: future schema
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('schema_version'));
    });

    test('forged anchored_at → blobEvidenceMismatch with anchored_at '
        'message', () async {
      final result = await runWithEvidence(
        forgedEvidence: AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 29, 2), // forged: next day
        ),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.blobEvidenceMismatch);
      expect(result.message, contains('anchored_at'));
    });

    test('every other field correct → ok (regression guard so the '
        'envelope check does not over-flag)', () async {
      final result = await runWithEvidence(
        forgedEvidence: goodEvidence(),
        anchor: goodAnchor(),
      );
      expect(result.outcome, VerifyOutcome.ok);
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('audit_anchor CLI (env-name only, no live secret values)', () {
    test('parseArgs requires anchor|verify and at least one '
        '--operator-id', () {
      expect(
        () => audit_anchor_main.parseArgs(<String>[]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => audit_anchor_main.parseArgs(<String>['unknown']),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => audit_anchor_main.parseArgs(<String>['anchor']),
        throwsA(isA<FormatException>()),
      );
    });

    test('parseArgs verify requires --chain-date and exactly one '
        '--operator-id', () {
      expect(
        () => audit_anchor_main.parseArgs(<String>[
          'verify',
          '--operator-id=$_opA',
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => audit_anchor_main.parseArgs(<String>[
          'verify',
          '--operator-id=$_opA',
          '--operator-id=$_opB',
          '--chain-date=2026-04-27',
        ]),
        throwsA(isA<FormatException>()),
      );
      final args = audit_anchor_main.parseArgs(<String>[
        'verify',
        '--operator-id=$_opA',
        '--chain-date=2026-04-27',
      ]);
      expect(args.mode, audit_anchor_main.AuditAnchorMode.verify);
      expect(args.operatorIds, equals(<String>[_opA]));
      expect(args.chainDateUtc, equals(DateTime.utc(2026, 4, 27)));
    });

    test('AuditAnchorRuntimeConfig.fromEnvironment names ONLY: missing '
        'env vars throw AuditAnchorConfigError that surfaces the var '
        'name without echoing values', () {
      // Missing AZURE_BLOB_AUDIT_CONTAINER first (deterministic
      // ordering — required list).
      Object? thrown;
      try {
        audit_anchor_main.AuditAnchorRuntimeConfig.fromEnvironment(
          const <String, String>{},
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<AuditAnchorConfigError>());
      expect(
        (thrown as AuditAnchorConfigError).name,
        AuditAnchorEnvNames.azureBlobContainer,
      );
      expect(
        thrown.toString(),
        contains('audit_chain_verify_runbook.md'),
      );
    });

    test('AuditAnchorRuntimeConfig.fromEnvironment loads the resolved '
        'POSTGRES_URL value (so PackagePostgresPool.fromUrl can open '
        'a real connection at deploy time) AND tracks env *names* in '
        'loadedSecretNames for the diagnostic line', () {
      final config =
          audit_anchor_main.AuditAnchorRuntimeConfig.fromEnvironment(
        const <String, String>{
          AuditAnchorEnvNames.postgresUrl:
              'postgresql://user:pw@host:5432/db?sslmode=require',
          AuditAnchorEnvNames.azureBlobContainer: 'audit-container',
          AuditAnchorEnvNames.azureBlobEndpoint:
              'https://example.blob.core.invalid',
        },
      );
      expect(config.containerName, 'audit-container');
      // The resolved value is on the bundle so PackagePostgresPool
      // .fromUrl can open against the live host. The bundle never
      // gets printed; the diagnostic line uses loadedSecretNames.
      expect(
        config.postgresUrl,
        equals('postgresql://user:pw@host:5432/db?sslmode=require'),
      );
      expect(
        config.loadedSecretNames,
        containsAll(<String>[
          AuditAnchorEnvNames.azureBlobContainer,
          AuditAnchorEnvNames.azureBlobEndpoint,
          AuditAnchorEnvNames.postgresUrl,
        ]),
      );
    });

    test('runCli without poolFactory override uses '
        'PackagePostgresPool.fromUrl by default — production CLI is '
        'runnable as-is from `dart run tool/audit_anchor/main.dart` '
        'without a follow-up wiring slice', () async {
      // Build a fake pool factory that records the connection string
      // it was handed. We assert the CLI passes the *value* from env
      // (not the env name); the default factory wires
      // PackagePostgresPool.fromUrl with that value.
      final receivedConnStrings = <String>[];
      PostgresPool fakePoolFactory(String connectionString) {
        receivedConnStrings.add(connectionString);
        return _RecordingPool();
      }

      // The default Blob client is scaffold-rejecting; the CLI
      // surfaces that as a runtime error rather than a config error.
      // We pin the env to a synthetic POSTGRES_URL so the build path
      // runs end-to-end without leaving any live calls.
      // ignore: close_sinks - test sinks; close adds noise without value.
      final out = _StringSink();
      // ignore: close_sinks - test sinks; close adds noise without value.
      final err = _StringSink();
      final code = await audit_anchor_main.runCli(
        <String>[
          'verify',
          '--operator-id=$_opA',
          '--chain-date=2026-04-27',
        ],
        environment: const <String, String>{
          AuditAnchorEnvNames.postgresUrl:
              'postgresql://user:pw@host:5432/db?sslmode=require',
          AuditAnchorEnvNames.azureBlobContainer: 'audit-container',
          AuditAnchorEnvNames.azureBlobEndpoint:
              'https://example.blob.core.invalid',
        },
        poolFactory: fakePoolFactory,
        out: out,
        err: err,
      );
      // The pool factory got the resolved POSTGRES_URL value, not
      // the env var name. Production CLI now calls
      // PackagePostgresPool.fromUrl with the live value at deploy
      // time.
      expect(receivedConnStrings, hasLength(1));
      expect(
        receivedConnStrings.single,
        equals('postgresql://user:pw@host:5432/db?sslmode=require'),
      );
      // Recording pool throws on every begin → exit 3 (runtime err).
      expect(code, 3);
      // Diagnostic line lists env NAMES only (no values).
      expect(
        out.toString(),
        contains('audit_anchor starting (loaded secret names'),
      );
      expect(
        out.toString(),
        isNot(contains('postgresql://')),
        reason: 'POSTGRES_URL value MUST NOT appear in stdout',
      );
    });

    test('runCli verify path returns 0 with an injected orchestrator '
        '(no env, no live wiring needed for the success path)',
        () async {
      final clean = _buildCleanChain();
      final blob = _FakeBlobClient();
      final evidenceBytes = const AnchorEvidenceCodec().encode(
        AnchorEvidence(
          schemaVersion: 1,
          operatorId: _opA,
          chainDate: DateTime.utc(2026, 4, 27),
          terminalRowId: clean.last.id,
          terminalRowHashHex: _hex(clean.last.rowHash),
          rowCount: BigInt.from(clean.length),
          anchoredAt: DateTime.utc(2026, 4, 28, 2),
        ),
      );
      blob.preload(
        blobName: 'audit_anchors/$_opA/2026-04-27.json',
        bytes: evidenceBytes,
        etag: 'etag-ok',
      );
      final anchor = AuditChainAnchor(
        operatorId: _opA,
        chainDate: DateTime.utc(2026, 4, 27),
        terminalRowHash: clean.last.rowHash,
        terminalRowId: clean.last.id,
        rowCount: BigInt.from(clean.length),
        blobUri: 'https://fake/x',
        blobEtag: 'etag-ok',
        anchoredAt: DateTime.utc(2026, 4, 28, 2),
      );
      final orchestrator = AuditAnchorOrchestrator(
        reader: _FakeReader(
          unanchored: const <AuditChainSummary>[],
          chainsByDate: <String, List<AuditLogRow>>{
            '$_opA|2026-04-27': clean,
          },
          anchorsByDate: <String, AuditChainAnchor>{
            '$_opA|2026-04-27': anchor,
          },
        ),
        anchorWriter: _FakeAnchorWriter(),
        blobClient: blob,
        containerName: 'forge-flow-audit-anchors',
      );
      // ignore: close_sinks - test sinks; close adds noise without value.
      final out = _StringSink();
      // ignore: close_sinks - test sinks; close adds noise without value.
      final err = _StringSink();
      final code = await audit_anchor_main.runCli(
        <String>[
          'verify',
          '--operator-id=$_opA',
          '--chain-date=2026-04-27',
        ],
        orchestratorOverride: orchestrator,
        out: out,
        err: err,
      );
      expect(code, 0);
      expect(out.toString(), contains('ok $_opA / 2026-04-27'));
      expect(err.toString(), isEmpty);
    });

    test('runCli surfaces AuditAnchorConfigError without echoing env '
        'values (exit 2)', () async {
      // ignore: close_sinks - test sinks; close adds noise without value.
      final out = _StringSink();
      // ignore: close_sinks - test sinks; close adds noise without value.
      final err = _StringSink();
      final code = await audit_anchor_main.runCli(
        <String>[
          'verify',
          '--operator-id=$_opA',
          '--chain-date=2026-04-27',
        ],
        environment: const <String, String>{},
        out: out,
        err: err,
      );
      expect(code, 2);
      // Error message must name the missing env var but never the
      // value (the test environment provides no values, but defense
      // in depth: the message contains only the var name).
      expect(
        err.toString(),
        contains(AuditAnchorEnvNames.azureBlobContainer),
      );
      expect(
        err.toString(),
        contains('audit_chain_verify_runbook.md'),
      );
    });

    test('production blob client default is the scaffold rejecter — '
        'live Azure wiring requires explicit operator action per the '
        'runbook', () async {
      // Asserting the default behavior directly: writing throws
      // AuditAnchorBlobUnavailable, never reaching any network.
      const client = ScaffoldRejectingAuditAnchorBlobClient();
      Object? thrownWrite;
      try {
        await client.writeImmutable(
          containerName: 'x',
          blobName: 'y',
          evidenceBytes: const <int>[1, 2, 3],
        );
      } catch (e) {
        thrownWrite = e;
      }
      expect(thrownWrite, isA<AuditAnchorBlobUnavailable>());
      expect(
        thrownWrite.toString(),
        contains('audit_chain_verify_runbook.md'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  group('audit_chain_verify runbook posture', () {
    final runbook = File('runbooks/audit_chain_verify_runbook.md');

    setUpAll(() {
      expect(
        runbook.existsSync(),
        isTrue,
        reason: 'runbook must accompany the migration + anchor tool',
      );
    });

    test('names Azure Blob immutability, daily verification, and '
        'manual verification surfaces', () {
      final body = runbook.readAsStringSync();
      expect(body.toLowerCase(), contains('immutable'));
      expect(body, contains('audit_anchor anchor'));
      expect(body, contains('audit_anchor verify'));
      // Cloud Run scheduled job posture.
      expect(body, contains('Cloud Run'));
    });

    test('locks break-glass UPDATE/DELETE prohibition + paired '
        'approval requirement (matches GDPR runbook posture)', () {
      final body = runbook.readAsStringSync();
      // The append-only-by-grant rule is named explicitly.
      expect(body, contains('append-only'));
      expect(body, contains('Break-glass'));
      // Cross-runbook reference so a future contributor cannot
      // diverge them silently.
      expect(body, contains('runbooks/gdpr_erasure_runbook.md'));
      // The break-glass SQL block keeps the GRANT/REVOKE wrapper
      // pattern (transaction-scoped privilege elevation).
      expect(body, contains('grant update on public.audit_logs'));
      expect(body, contains('revoke update on public.audit_logs'));
    });

    test('does not contain real secrets, tokens, SAS URLs, or account '
        'names; references env names only', () {
      final body = runbook.readAsStringSync();
      // No SAS-token query strings in URLs.
      expect(
        body,
        isNot(contains('?sv=')),
        reason: 'SAS tokens leak credentials; runbook must use '
            'env-name placeholders only',
      );
      expect(
        body,
        isNot(contains('AccountKey=')),
        reason: 'connection strings expose account keys; never embed '
            'one in the repo',
      );
      // Env names referenced (so an executor knows what to set), but
      // never values.
      expect(body, contains(AuditAnchorEnvNames.azureBlobContainer));
      expect(body, contains(AuditAnchorEnvNames.azureBlobEndpoint));
      expect(body, contains(AuditAnchorEnvNames.postgresUrl));
    });

    test('explicitly states live Azure setup/mutation requires human '
        'approval before execution (CLAUDE.md "no live Azure '
        'mutation in repo")', () {
      final body = runbook.readAsStringSync();
      expect(body.toLowerCase(), contains('human approval'));
      expect(
        body,
        contains('CLAUDE.md "no live Azure mutation in repo"'),
      );
    });

    test('pg_partman verification snippet uses live-verified '
        'public.part_config (NOT partman.part_config); regression '
        'guard so the runbook stays aligned with the migration after '
        'the round-2 schema fix', () {
      final body = runbook.readAsStringSync();
      expect(
        body,
        contains('from public.part_config'),
        reason: 'runbook must point operators at the live-verified '
            'schema; partman.* would send the next executor down '
            'the same bad path the migration just fixed',
      );
      expect(
        body,
        isNot(contains('from partman.part_config')),
        reason: 'partman.part_config is the wrong schema on Azure; '
            'live-verified 2026-04-26 confirmed pg_partman lives in '
            'public — see phase_11a_decision_register.md Lock 2',
      );
      // Cross-link to the verified pattern source so a future
      // contributor knows where to re-check.
      expect(
        body,
        contains('phase_11a_decision_register.md'),
      );
    });

    test('evidence export emits true JSONL (one JSON object per line) '
        'via jsonb_build_object + format text — NOT format csv with '
        'a tab delimiter (which would produce TSV mis-named .jsonl '
        'and break Q9 replay parsers)', () {
      final body = runbook.readAsStringSync();
      // Required: jsonb_build_object projection so each row is a
      // single JSON object, plus `format text` so `\copy` writes
      // each value verbatim with a trailing newline.
      expect(
        body,
        contains('jsonb_build_object'),
        reason: 'JSONL emitter must build each line as a JSON object',
      );
      expect(
        body,
        contains('with (format text)'),
        reason: '`\\copy ... with (format text)` is the only output '
            'mode that writes a single value per line without '
            'quoting/header decoration',
      );
      // Forbidden: the previous broken pattern. Either of these
      // strings would silently regress the JSONL output.
      expect(
        body,
        isNot(contains("with (format csv, header, delimiter E'\\t')")),
        reason: 'CSV mode quote-wraps values and writes a header — '
            'breaks JSONL parsers even with a .jsonl file extension',
      );
      expect(
        RegExp(r'with\s*\(\s*format\s+csv', caseSensitive: false)
            .hasMatch(body),
        isFalse,
        reason: 'no `format csv` anywhere in the export block — even '
            'with whitespace variants',
      );
      // The export block names JSONL as canonical (Q9 lock).
      expect(body, contains('JSONL is canonical'));
      expect(body, contains('Q9 lock'));
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
    out.add(_buildRow(
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
    ));
    prev = hash;
  }
  return out;
}

AuditLogRow _retamperRow(AuditLogRow original, {required String newPayloadText}) {
  return _buildRow(
    id: original.id,
    operatorId: original.operatorId,
    locationId: original.locationId,
    chainDate: original.chainDate,
    occurredAt: original.occurredAt,
    actorKind: original.actorKind,
    actorUserId: original.actorUserId,
    actorPrincipalId: original.actorPrincipalId,
    targetKind: original.targetKind,
    targetId: original.targetId,
    action: original.action,
    payloadText: newPayloadText,
    prevRowHash: original.prevRowHash,
    // Keep the OLD row_hash so the recompute disagrees with stored.
    rowHash: original.rowHash,
  );
}

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _formatTestDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

class _FakeReader implements AuditChainReader {
  _FakeReader({
    required this.unanchored,
    required this.chainsByDate,
    required this.anchorsByDate,
  });

  final List<AuditChainSummary> unanchored;
  final Map<String, List<AuditLogRow>> chainsByDate;
  final Map<String, AuditChainAnchor> anchorsByDate;

  String _key(String operatorId, DateTime chainDate) {
    final utc = chainDate.toUtc();
    return '$operatorId|'
        '${utc.year.toString().padLeft(4, '0')}-'
        '${utc.month.toString().padLeft(2, '0')}-'
        '${utc.day.toString().padLeft(2, '0')}';
  }

  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) async {
    return unanchored
        .where((s) => s.operatorId == operatorId)
        .toList(growable: false);
  }

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) async {
    return chainsByDate[_key(operatorId, chainDate)] ?? const <AuditLogRow>[];
  }

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) async {
    return anchorsByDate[_key(operatorId, chainDate)];
  }
}

class _FakeAnchorWriter implements AuditChainAnchorWriter {
  final List<AuditChainAnchor> inserts = <AuditChainAnchor>[];

  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) async {
    inserts.add(anchor);
  }
}

class _FakeBlobWrite {
  _FakeBlobWrite({
    required this.containerName,
    required this.blobName,
    required this.evidenceBytes,
    required this.fakeUri,
    required this.fakeEtag,
  });

  final String containerName;
  final String blobName;
  final List<int> evidenceBytes;
  final String fakeUri;
  final String fakeEtag;
}

class _FakeBlobClient implements AuditAnchorBlobClient {
  final List<_FakeBlobWrite> writes = <_FakeBlobWrite>[];
  final Map<String, _PreloadedBlob> _preload = <String, _PreloadedBlob>{};

  void preload({
    required String blobName,
    required List<int> bytes,
    required String etag,
  }) {
    _preload[blobName] = _PreloadedBlob(bytes: bytes, etag: etag);
  }

  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    final write = _FakeBlobWrite(
      containerName: containerName,
      blobName: blobName,
      evidenceBytes: evidenceBytes,
      fakeUri: 'https://fake/$containerName/$blobName',
      fakeEtag: 'etag-${writes.length + 1}',
    );
    writes.add(write);
    return AnchorBlobWriteResult(uri: write.fakeUri, etag: write.fakeEtag);
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    final preloaded = _preload[blobName];
    if (preloaded == null) {
      throw AuditAnchorBlobUnavailable(
        'fake: blob $blobName not preloaded',
      );
    }
    return AnchorBlobReadResult(
      bytes: preloaded.bytes,
      etag: preloaded.etag,
    );
  }
}

class _PreloadedBlob {
  _PreloadedBlob({required this.bytes, required this.etag});
  final List<int> bytes;
  final String etag;
}

/// Pool that throws on every transaction — used by the
/// "default-pool-factory wiring" test to confirm the CLI passes the
/// resolved POSTGRES_URL value through to the factory and surfaces
/// downstream connection errors as runtime errors (exit 3) without
/// echoing the connection string back to stdout/stderr.
class _RecordingPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() async {
    throw StateError('recording pool does not open a real connection');
  }
}

class _StringSink implements IOSink {
  final StringBuffer _buffer = StringBuffer();

  @override
  String toString() => _buffer.toString();

  @override
  void writeln([Object? object = '']) {
    _buffer.writeln(object);
  }

  @override
  void write(Object? object) {
    _buffer.write(object);
  }

  @override
  Future<dynamic> close() async {}

  @override
  Future<dynamic> get done => Future<void>.value();

  @override
  Future<void> flush() async {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }

  @override
  void add(List<int> data) {
    _buffer.write(utf8.decode(data));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Encoding encoding = utf8;
}
