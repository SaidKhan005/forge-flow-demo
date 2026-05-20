// Phase 9.0Σ.f — B37 in-DB chain verifier end-to-end test.
//
// Pairs with `test/phase_9_0sigma_f_audit_logs_test.dart` (B27, which
// covers migration shape + RLS lint + small-chain unit contracts) and
// `tool/audit_anchor/test/anchor_e2e_test.dart` (B37 anchor surface).
//
// Scope (locked from B37 in `docs/phases/phase_9/phase_9_execution_backlog.md`):
//
//   * Build a deterministic 100-row synthetic chain set spanning
//     3 operators × 2 chain_date days = 6 chains.
//   * Walk every link in every chain via `prev_row_hash ||
//     canonical_payload` and assert every row's stored hash recomputes
//     verbatim.
//   * Detect a single-byte payload tamper at the expected row.
//   * Assert chain boundaries: `(operator_id, chain_date)` is the
//     scope, so different operators on the same date and the same
//     operator on different dates do not share a chain.
//
// Local framework only — no live Postgres, Azure Blob, or provider
// access. The 6 synthetic chains are produced by the same
// `AuditChainHasher` the verifier uses, which mirrors the SQL trigger
// in `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`
// byte-for-byte.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/advisor_proxy/advisor_proxy.dart' as proxy;
import '../tool/audit_anchor/audit_anchor.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _opC = '77777777-7777-7777-7777-777777777777';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '55555555-5555-5555-5555-555555555555';
const String _locC = '88888888-8888-8888-8888-888888888888';
const String _userA = '33333333-3333-3333-3333-333333333333';

void main() {
  // 3 operators × 2 chain dates = 6 chains. Row counts sum to 100 per
  // the B37 contract; each chain has at least 14 rows so prev/row hash
  // linking is exercised well past the boundary cases.
  const operators = <String>[_opA, _opB, _opC];
  const operatorLocations = <String, String>{
    _opA: _locA,
    _opB: _locB,
    _opC: _locC,
  };
  final dates = <DateTime>[
    DateTime.utc(2026, 4, 26),
    DateTime.utc(2026, 4, 27),
  ];
  // 20 + 18 + 17 + 15 + 16 + 14 = 100.
  const chainLengths = <int>[20, 18, 17, 15, 16, 14];

  group('B37 in-DB chain verifier — 100 rows × 3 operators × 2 dates', () {
    test('every row in every chain recomputes from prev_row_hash || '
        'canonical_payload — first row prev_row_hash is null, '
        'subsequent prev_row_hash matches prior row_hash, and the '
        'verifier returns zero violations across all 6 chains', () {
      final chains = _buildSyntheticChainSet(
        operators: operators,
        operatorLocations: operatorLocations,
        dates: dates,
        chainLengths: chainLengths,
      );
      // Total row budget is exactly 100 across 6 chains.
      final total = chains.values.fold<int>(
        0,
        (acc, rows) => acc + rows.length,
      );
      expect(total, equals(100));
      expect(chains.keys.length, equals(6));

      const hasher = AuditChainHasher();
      for (final entry in chains.entries) {
        final rows = entry.value;
        // Boundary: first row of every chain has null prev_row_hash —
        // chains do not share state across `(operator_id, chain_date)`.
        expect(
          rows.first.prevRowHash,
          isNull,
          reason: 'first row of ${entry.key} must have null prev hash',
        );
        // Subsequent rows: prev_row_hash equals the prior row's
        // row_hash (link integrity).
        for (var i = 1; i < rows.length; i++) {
          expect(
            rows[i].prevRowHash,
            equals(rows[i - 1].rowHash),
            reason:
                'row $i in ${entry.key} prev_row_hash must match '
                'prior row_hash',
          );
        }
        // Recomputation: every stored row_hash recomputes from
        // SHA256(prev_row_hash || canonical_payload).
        for (final row in rows) {
          expect(
            hasher.recomputeRowHash(row),
            equals(row.rowHash),
            reason: 'row ${row.id} in ${entry.key} hash must reproduce',
          );
        }
        // verifyChain agrees end-to-end.
        expect(
          hasher.verifyChain(rows),
          isEmpty,
          reason: 'verifyChain must report no violations for ${entry.key}',
        );
      }
    });

    test('a single-byte payload tamper on a mid-chain row in chain '
        '[opB, 2026-04-27] is detected at exactly the tampered row '
        '(row_hash mismatch); other chains stay clean', () {
      final chains = _buildSyntheticChainSet(
        operators: operators,
        operatorLocations: operatorLocations,
        dates: dates,
        chainLengths: chainLengths,
      );
      const tamperedChainKey = '$_opB|2026-04-27';
      final originalRows = chains[tamperedChainKey]!;
      // Pick a mid-chain row to flip a single byte of payload text.
      // The deterministic synthetic payload is `{"seq": <i>}`; replace
      // `5` with `6` to make exactly one byte differ from the canonical
      // bytes the trigger hashed over.
      final tamperedIndex = 5;
      final originalRow = originalRows[tamperedIndex];
      final tamperedPayload = originalRow.payloadText.replaceFirst(
        '"seq": 5',
        '"seq": 6',
      );
      // Sanity: the replacement actually changed exactly one byte.
      expect(
        _byteDiffCount(originalRow.payloadText, tamperedPayload),
        equals(1),
        reason: 'tamper must be a single-byte change (the test contract)',
      );
      final tamperedRow = AuditLogRow(
        id: originalRow.id,
        operatorId: originalRow.operatorId,
        locationId: originalRow.locationId,
        chainDate: originalRow.chainDate,
        occurredAt: originalRow.occurredAt,
        actorKind: originalRow.actorKind,
        actorUserId: originalRow.actorUserId,
        actorPrincipalId: originalRow.actorPrincipalId,
        targetKind: originalRow.targetKind,
        targetId: originalRow.targetId,
        action: originalRow.action,
        payloadText: tamperedPayload,
        prevRowHash: originalRow.prevRowHash,
        // Stored row_hash unchanged → mismatches recomputation.
        rowHash: originalRow.rowHash,
      );
      final tamperedRows = <AuditLogRow>[
        ...originalRows.sublist(0, tamperedIndex),
        tamperedRow,
        ...originalRows.sublist(tamperedIndex + 1),
      ];

      const hasher = AuditChainHasher();
      final violations = hasher.verifyChain(tamperedRows);
      expect(
        violations.any(
          (v) =>
              v.rowId == tamperedRow.id &&
              v.kind == ChainHashViolationKind.rowHashMismatch,
        ),
        isTrue,
        reason:
            'single-byte payload mutation at row ${tamperedRow.id} '
            'must surface a rowHashMismatch violation',
      );

      // The other 5 chains stay clean.
      for (final entry in chains.entries) {
        if (entry.key == tamperedChainKey) continue;
        expect(
          hasher.verifyChain(entry.value),
          isEmpty,
          reason: 'chain ${entry.key} was not tampered and must verify',
        );
      }
    });

    test('chain boundaries do not bleed: the same operator on '
        'different dates is a different chain, and different '
        'operators on the same date are a different chain — neither '
        'shares prev_row_hash linkage', () {
      final chains = _buildSyntheticChainSet(
        operators: operators,
        operatorLocations: operatorLocations,
        dates: dates,
        chainLengths: chainLengths,
      );
      // Every chain's first row has null prev_row_hash.
      for (final entry in chains.entries) {
        expect(
          entry.value.first.prevRowHash,
          isNull,
          reason: 'first row of ${entry.key} must have null prev hash',
        );
      }
      // Same operator, next-day chain does not reference the prior-day
      // terminal hash.
      final opADay0 = chains['$_opA|2026-04-26']!;
      final opADay1 = chains['$_opA|2026-04-27']!;
      expect(
        opADay1.first.prevRowHash,
        isNot(equals(opADay0.last.rowHash)),
        reason: 'opA day-1 first row must not link to opA day-0 terminal',
      );
      // Different operator, same date does not share a chain.
      final opBDay0 = chains['$_opB|2026-04-26']!;
      expect(
        opBDay0.first.prevRowHash,
        isNot(equals(opADay0.last.rowHash)),
        reason: 'opB day-0 first row must not link to opA day-0 terminal',
      );
      // Spot-check terminal hashes are distinct across chains (a
      // sanity check on canonical-payload distinctness — operator_id
      // and chain_date are part of the canonical bytes, so even if
      // every row's payload were identical the terminal hashes still
      // differ).
      final terminals = <String, Uint8List>{
        for (final entry in chains.entries) entry.key: entry.value.last.rowHash,
      };
      final unique = terminals.values.map(_hex).toSet();
      expect(
        unique.length,
        equals(terminals.length),
        reason:
            'every chain produces a distinct terminal hash because '
            'canonical bytes include operator_id and chain_date',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  //
  // KNOWN_FAILING — pending B.2.
  //
  // B.2 (auth-event family fan-out into hash-chained audit_logs) must
  // append a row to `public.audit_logs` for every auth-event the live
  // code emits. Production traffic crosses TWO distinct write boundaries
  // and B.2 must hook BOTH or real traffic stays uncovered:
  //
  //   1. Repository boundary — login, MFA enroll, and password change go
  //      through `AuthEventsAuditRepository.insertEvent` (the seam every
  //      user-facing auth gateway shares). Those three scenarios below
  //      drive that repository directly.
  //
  //   2. B41 gateway boundary — service-principal token issue goes
  //      through `PostgresServicePrincipalJwtIssuanceGateway.issue(...)`,
  //      which writes `insert into public.auth_events_audit` directly
  //      via raw SQL through `PostgresExecutor` (NOT through the
  //      repository). The SP scenario below drives that gateway
  //      end-to-end so a B.2 fan-out that only hooks repository writes
  //      cannot pass while real issuance traffic remains uncovered.
  //
  // Today neither boundary fans out into `audit_logs`; only
  // `auth_events_audit` is written. Each scenario runs against a fake
  // `PostgresPool` that observes whether an `insert into audit_logs`
  // statement was issued; the fake feeds any such INSERT into the
  // in-memory `_AuditLogChainStore`, which mirrors the SQL trigger
  // byte-for-byte (prev_row_hash + canonical payload + SHA-256
  // row_hash). When B.2 lands and BOTH boundaries emit the audit_logs
  // INSERT, the assertions below close on their own.
  //
  // KNOWN_FAILING tracking: docs/KNOWN_FAILING_TESTS.md (B.2 row).
  group('audit_logs receives auth-event family', () {
    test('Login event → audit_logs row exists with '
        'actor_kind=team_member (legacy "user" input is normalised by the '
        '2026-05-13 audit_logs actor-reason contract widening: new '
        'team/admin writes use "team_member", "forge_admin", '
        '"service_principal"; "user" is retained as a legacy alias for '
        '"team_member"), valid prev_row_hash (null on first row of the '
        'chain), and the chain remains valid through '
        'AuditChainHasher.verifyChain', () async {
      final harness = _AuthAuditChainHarness();
      final repo = AuthEventsAuditRepository(
        TenantTransactionWrapper(harness.pool),
      );

      // Real auth-gateway code path: identical event_type and actor
      // shape the production sign-in path emits via the same
      // AuthEventsAuditRepository every gateway shares. The legacy
      // `'user'` input is preserved here on purpose — production
      // normalises it to `'team_member'` per the audit-attribution
      // contract, and asserting the normalised value below is exactly
      // the regression guard we want.
      await repo.insertEvent(
        operatorId: _opA,
        locationId: _locA,
        eventType: 'auth.user.signed_in',
        actorKind: 'user',
        actorUserId: _userA,
        payload: const <String, Object?>{'method': 'password'},
      );

      final rows = harness.chainStore.rowsForOperator(_opA);
      if (rows.isEmpty) {
        fail(
          'KNOWN_FAILING (B.2): no audit_logs row was written for '
          'auth.user.signed_in. B.2 must fan AuthEventsAuditRepository.'
          'insertEvent into the audit_logs hash chain.',
        );
      }
      expect(rows, hasLength(1));
      expect(rows.single.actorKind, equals('team_member'),
          reason: 'audit_attribution_contract: new team/admin writes '
              'use "team_member"; "user" is a legacy alias normalised on '
              'write');
      expect(rows.single.actorUserId, equals(_userA));
      expect(rows.single.actorPrincipalId, isNull);
      expect(
        rows.single.prevRowHash,
        isNull,
        reason: 'first row of the chain has null prev_row_hash',
      );
      expect(const AuditChainHasher().verifyChain(rows), isEmpty);

      final anchor = harness.runAnchorJobHarness(operatorId: _opA);
      expect(anchor.terminalRowHash, equals(rows.last.rowHash));
      expect(anchor.rowCount, equals(BigInt.from(rows.length)));
    });

    test('MFA enroll event → audit_logs row exists with '
        'actor_kind=team_member (legacy "user" input normalised on write '
        'per the 2026-05-13 audit_logs widening), prev_row_hash links to '
        'the prior row, and the chain stays valid. Firebase boundary is '
        'mocked at the repository pool; everything below — repository '
        'write, trigger semantics, hash chain — is real', () async {
      final harness = _AuthAuditChainHarness();
      final repo = AuthEventsAuditRepository(
        TenantTransactionWrapper(harness.pool),
      );

      // Seed the chain with a prior login row so the MFA enroll row
      // exercises the prev_row_hash → row_hash link, not just the
      // first-row null-prev case the login scenario covers.
      await repo.insertEvent(
        operatorId: _opA,
        locationId: _locA,
        eventType: 'auth.user.signed_in',
        actorKind: 'user',
        actorUserId: _userA,
      );
      await repo.insertEvent(
        operatorId: _opA,
        locationId: _locA,
        eventType: 'auth.mfa_totp_enrolled',
        actorKind: 'user',
        actorUserId: _userA,
        targetUserId: _userA,
        payload: const <String, Object?>{'factor_type': 'totp'},
      );

      final rows = harness.chainStore.rowsForOperator(_opA);
      if (rows.length < 2) {
        fail(
          'KNOWN_FAILING (B.2): expected 2 audit_logs rows (login + '
          'mfa_totp_enrolled). Saw ${rows.length}. B.2 must fan the '
          'MFA gateway audit boundary into audit_logs.',
        );
      }
      final mfaRow = rows.last;
      expect(mfaRow.action, contains('mfa_totp_enrolled'));
      expect(mfaRow.actorKind, equals('team_member'),
          reason: 'audit_attribution_contract: "user" input normalises '
              'to "team_member" on write');
      expect(mfaRow.actorUserId, equals(_userA));
      expect(
        mfaRow.targetKind,
        equals('user'),
        reason:
            'B.2 must map auth_events_audit.target_user_id into '
            'audit_logs.target_kind/target_id (the user whose factor '
            'was enrolled)',
      );
      expect(mfaRow.targetId, equals(_userA));
      expect(
        mfaRow.prevRowHash,
        equals(rows[rows.length - 2].rowHash),
        reason: 'prev_row_hash must link to the prior row in the chain',
      );
      expect(const AuditChainHasher().verifyChain(rows), isEmpty);

      final anchor = harness.runAnchorJobHarness(operatorId: _opA);
      expect(anchor.terminalRowHash, equals(rows.last.rowHash));
    });

    test('Password change event → audit_logs row exists with '
        'actor_kind=team_member (legacy "user" input normalised on '
        'write), action matching the production gateway event_type '
        '"auth.password_changed" (RepositoryPasswordChangeGateway._audit), '
        'and target_kind/target_id naming the user whose password '
        'rotated. Chain remains valid.', () async {
      final harness = _AuthAuditChainHarness();
      final repo = AuthEventsAuditRepository(
        TenantTransactionWrapper(harness.pool),
      );

      // Production password-change gateway emits "auth.password_changed"
      // (not the alias "auth.user.password_changed" — the AuthEventLabels
      // mapping recognises both, but only the unprefixed form is the
      // actual gateway emission point). Pinning the test to the emitted
      // form keeps a B.2 fan-out implementation honest against the live
      // password-change traffic.
      await repo.insertEvent(
        operatorId: _opA,
        locationId: _locA,
        eventType: 'auth.password_changed',
        actorKind: 'user',
        actorUserId: _userA,
        targetUserId: _userA,
      );

      final rows = harness.chainStore.rowsForOperator(_opA);
      if (rows.isEmpty) {
        fail(
          'KNOWN_FAILING (B.2): no audit_logs row was written for '
          'auth.password_changed (the event_type the production '
          'RepositoryPasswordChangeGateway emits). B.2 must fan the '
          'password-change gateway audit boundary into audit_logs.',
        );
      }
      expect(rows, hasLength(1));
      expect(rows.single.actorKind, equals('team_member'),
          reason: 'audit_attribution_contract: "user" input normalises '
              'to "team_member" on write');
      expect(rows.single.actorUserId, equals(_userA));
      expect(rows.single.action, equals('auth.password_changed'));
      expect(
        rows.single.targetKind,
        equals('user'),
        reason:
            'B.2 must map auth_events_audit.target_user_id (uuid) into '
            'audit_logs.target_kind = "user" + target_id = <uuid> per '
            'the migration column comment',
      );
      expect(
        rows.single.targetId,
        equals(_userA),
        reason: 'target_id must carry the user uuid being password-rotated',
      );
      expect(const AuditChainHasher().verifyChain(rows), isEmpty);

      final anchor = harness.runAnchorJobHarness(operatorId: _opA);
      expect(anchor.terminalRowHash, equals(rows.last.rowHash));
    });

    test('Service-principal token issue → audit_logs row exists with '
        'actor_kind=service AND actor_principal_id carries the '
        '`sp:<service_principal_id>` JWT subject (per CLAUDE.md); '
        'actor_user_id is null (audit_logs_actor_shape_check); event_type '
        'matches the production B41 issuance path '
        '(PermissionKeys.adminServicePrincipalIssueToken). Drives the '
        'real PostgresServicePrincipalJwtIssuanceGateway.issue() — the '
        'live boundary that writes auth_events_audit directly via raw '
        'SQL (NOT through AuthEventsAuditRepository.insertEvent) — so a '
        'B.2 fan-out that only hooks repository writes cannot pass this '
        'test while the real issuance traffic stays uncovered. Chain '
        'remains valid.', () async {
      final harness = _AuthAuditChainHarness();
      const principalId = '99999999-9999-9999-9999-999999999999';
      const principalScopes = <String>['workflow.read'];
      harness.pool.servicePrincipalReplyId = principalId;
      harness.pool.servicePrincipalReplyScopes = principalScopes;

      // Real B41 boundary: PostgresServicePrincipalJwtIssuanceGateway.
      // issue() runs the full live choreography against the fake pool —
      // idempotency reservation, advisory lock, service_principal load,
      // recent-issuance count, JWT mint, _insertAuditRow (raw `insert
      // into public.auth_events_audit`), proxy_requests completion. A
      // B.2 fan-out implementation must hook the audit_logs INSERT into
      // *this* code path; hooking only repository writes leaves the
      // production token-issuance traffic uncovered.
      final gateway = proxy.PostgresServicePrincipalJwtIssuanceGateway(
        wrapper: TenantTransactionWrapper(harness.pool),
        issuer: const proxy.ServicePrincipalJwtIssuer(
          sharedSecret: 'test-secret',
        ),
      );
      final issued = await gateway.issue(
        proxy.ServicePrincipalJwtIssueCommand(
          servicePrincipalId: principalId,
          operator: const proxy.OperatorContext(
            userId: _userA,
            operatorId: _opA,
            locationId: _locA,
            roles: <String>['roles_version:1'],
          ),
          idempotencyKey: 'idem-known-failing-b2',
          issuedAt: DateTime.utc(2026, 4, 30, 12),
        ),
      );
      // Sanity: the real gateway ran end-to-end and produced an
      // sp:-subject JWT. If this fails the test setup is broken (not a
      // B.2 KNOWN_FAILING signal).
      expect(issued.jwt, isNotEmpty);

      final rows = harness.chainStore.rowsForOperator(_opA);
      if (rows.isEmpty) {
        fail(
          'KNOWN_FAILING (B.2): the real B41 issuance path '
          '(PostgresServicePrincipalJwtIssuanceGateway.issue) ran and '
          'wrote auth_events_audit directly, but no audit_logs row was '
          'produced. B.2 must fan the production B41 service-principal '
          'token-issue audit boundary into audit_logs (with '
          'actor_principal_id set to the canonical sp:<uuid> subject, '
          'not the bare UUID).',
        );
      }
      expect(rows, hasLength(1));
      expect(
        rows.single.action,
        equals(PermissionKeys.adminServicePrincipalIssueToken),
        reason:
            'audit_logs.action must carry the live B41 event_type '
            'constant so a rename refactor on either side stays in sync',
      );
      expect(
        rows.single.actorKind,
        equals('service'),
        reason: 'service-principal events carry actor_kind = service',
      );
      expect(
        rows.single.actorUserId,
        isNull,
        reason: 'audit_logs_actor_shape_check forbids both id slots',
      );
      expect(
        rows.single.actorPrincipalId,
        equals('sp:$principalId'),
        reason:
            'audit_logs.actor_principal_id is text and must hold '
            'the JWT subject "sp:<uuid>" (CLAUDE.md "Service '
            'principals" + 9.0Σ.f migration column comment), not the '
            'raw service_principal uuid.',
      );
      expect(const AuditChainHasher().verifyChain(rows), isEmpty);

      final anchor = harness.runAnchorJobHarness(operatorId: _opA);
      expect(anchor.terminalRowHash, equals(rows.last.rowHash));
    });
  });
}

/// Small helper: count byte-level differences between two UTF-8
/// strings. Used to assert the synthetic tamper is exactly one byte.
int _byteDiffCount(String a, String b) {
  final aBytes = a.codeUnits;
  final bBytes = b.codeUnits;
  if (aBytes.length != bBytes.length) {
    return (aBytes.length - bBytes.length).abs();
  }
  var diffs = 0;
  for (var i = 0; i < aBytes.length; i++) {
    if (aBytes[i] != bBytes[i]) diffs++;
  }
  return diffs;
}

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

String _formatDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

/// Builds 6 deterministic chains keyed by `operator_id|chain_date`.
/// Each chain is internally consistent — every stored row_hash equals
/// SHA-256(prev_row_hash || canonical_payload) per the SQL trigger.
/// Chain boundaries are independent: no cross-chain prev_row_hash link.
Map<String, List<AuditLogRow>> _buildSyntheticChainSet({
  required List<String> operators,
  required Map<String, String> operatorLocations,
  required List<DateTime> dates,
  required List<int> chainLengths,
}) {
  expect(
    operators.length * dates.length,
    chainLengths.length,
    reason: 'one chain length per (operator, date) combination',
  );
  const hasher = AuditChainHasher();
  final out = <String, List<AuditLogRow>>{};
  var combinationIdx = 0;
  for (final operatorId in operators) {
    for (final chainDate in dates) {
      final length = chainLengths[combinationIdx];
      final rows = <AuditLogRow>[];
      Uint8List? prev;
      for (var i = 0; i < length; i++) {
        final draft = AuditLogRow(
          // ID space is partitioned by combination so terminal IDs
          // across chains are distinct (a real database uses a single
          // bigserial; this synthetic spread mirrors the partition
          // semantic where each chain's id space is independent for
          // verifier purposes).
          id: BigInt.from(combinationIdx * 1000 + i + 1),
          operatorId: operatorId,
          locationId: operatorLocations[operatorId],
          chainDate: chainDate,
          // i minutes after midnight UTC stays inside the same UTC
          // date for chain lengths up to 1440 — well within bounds.
          occurredAt: chainDate.add(Duration(minutes: i)),
          actorKind: 'user',
          actorUserId: _userA,
          actorPrincipalId: null,
          targetKind: null,
          targetId: null,
          action: 'session.event.$i',
          payloadText: '{"seq": $i}',
          prevRowHash: prev,
          rowHash: Uint8List(32),
        );
        final canonical = hasher.canonicalPayload(draft);
        final hash = Uint8List.fromList(
          sha256.convert(<int>[...?prev, ...canonical]).bytes,
        );
        rows.add(
          AuditLogRow(
            id: draft.id,
            operatorId: draft.operatorId,
            locationId: draft.locationId,
            chainDate: draft.chainDate,
            occurredAt: draft.occurredAt,
            actorKind: draft.actorKind,
            actorUserId: draft.actorUserId,
            actorPrincipalId: draft.actorPrincipalId,
            targetKind: draft.targetKind,
            targetId: draft.targetId,
            action: draft.action,
            payloadText: draft.payloadText,
            prevRowHash: prev,
            rowHash: hash,
          ),
        );
        prev = hash;
      }
      out['$operatorId|${_formatDate(chainDate)}'] = rows;
      combinationIdx++;
    }
  }
  return out;
}

// ─── B.2 KNOWN_FAILING harness ──────────────────────────────────────────
//
// Pieces below back the `audit_logs receives auth-event family` group.
// The harness wires a fake `PostgresPool` that admits BOTH production
// auth-event write boundaries B.2 must close:
//
//   1. Repository boundary — login, MFA enroll, and password change
//      drive `AuthEventsAuditRepository.insertEvent` (the seam every
//      user-facing auth gateway shares).
//   2. B41 gateway boundary — service-principal token issue drives
//      `PostgresServicePrincipalJwtIssuanceGateway.issue(...)`, which
//      writes `insert into public.auth_events_audit` directly via raw
//      SQL through `PostgresExecutor` (NOT through the repository).
//
// The pool:
//
//   * Accepts the SET LOCAL block the wrapper issues.
//   * Returns a fake event_id for both `insert into auth_events_audit`
//     and `insert into public.auth_events_audit ... returning
//     event_id` shapes so the repository AND the issuance gateway
//     surface a happy path.
//   * Replies to the B41 issuance choreography (proxy_requests
//     idempotency lookup / reservation / completion, advisory lock,
//     service_principals load, recent-issuance count) so the live
//     gateway runs end-to-end and reaches its raw audit-INSERT.
//   * Watches for any `insert into audit_logs ...` (or
//     `insert into public.audit_logs ...`) statement from EITHER
//     boundary; when B.2 emits that INSERT, the fake feeds it into
//     the in-memory `_AuditLogChainStore`, which mirrors the SQL
//     trigger byte-for-byte. Today neither boundary emits the INSERT,
//     so the chain store stays empty and the four scenario assertions
//     fail by design.

class _AuthAuditChainHarness {
  _AuthAuditChainHarness();

  final _AuditLogChainStore chainStore = _AuditLogChainStore();
  late final _AuthEventsRecordingPool pool = _AuthEventsRecordingPool(
    chainStore,
  );

  /// Mimics `tool/audit_anchor`'s daily anchor job over the in-memory
  /// chain. Returns an `AuditChainAnchor` keyed on the chain's terminal
  /// row hash. Fails if the chain is empty so each scenario surfaces
  /// the empty-chain case as a KNOWN_FAILING signal rather than a
  /// silent no-op.
  AuditChainAnchor runAnchorJobHarness({
    required String operatorId,
    DateTime? chainDate,
  }) {
    final rows = chainStore.rowsForOperator(operatorId, chainDate: chainDate);
    if (rows.isEmpty) {
      fail(
        'runAnchorJobHarness: chain for $operatorId is empty — nothing '
        'to anchor (KNOWN_FAILING path; B.2 will populate the chain).',
      );
    }
    return AuditChainAnchor(
      operatorId: operatorId,
      chainDate: rows.last.chainDate,
      terminalRowHash: rows.last.rowHash,
      terminalRowId: rows.last.id,
      rowCount: BigInt.from(rows.length),
      blobUri:
          'mem://audit_anchors/$operatorId/'
          '${_formatDate(rows.last.chainDate)}.json',
      blobEtag: 'fake-etag-${rows.last.id}',
      anchoredAt: DateTime.utc(2026, 4, 30),
    );
  }
}

/// In-memory mirror of the BEFORE INSERT trigger in
/// `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`. Every
/// row is hashed via `AuditChainHasher` (the same hasher the verifier
/// uses) so a consumer can call `verifyChain` over the stored rows
/// straight-away.
class _AuditLogChainStore {
  final List<AuditLogRow> _rows = <AuditLogRow>[];

  void simulateInsert({
    required String operatorId,
    String? locationId,
    required DateTime occurredAt,
    required String actorKind,
    String? actorUserId,
    String? actorPrincipalId,
    String? targetKind,
    String? targetId,
    required String action,
    required String payloadText,
  }) {
    final chainDate = DateTime.utc(
      occurredAt.toUtc().year,
      occurredAt.toUtc().month,
      occurredAt.toUtc().day,
    );
    final priorChainRows = _rows
        .where((r) => r.operatorId == operatorId && r.chainDate == chainDate)
        .toList();
    final prev = priorChainRows.isEmpty ? null : priorChainRows.last.rowHash;
    final draft = AuditLogRow(
      id: BigInt.from(_rows.length + 1),
      operatorId: operatorId,
      locationId: locationId,
      chainDate: chainDate,
      occurredAt: occurredAt.toUtc(),
      actorKind: actorKind,
      actorUserId: actorUserId,
      actorPrincipalId: actorPrincipalId,
      targetKind: targetKind,
      targetId: targetId,
      action: action,
      payloadText: payloadText,
      prevRowHash: prev,
      rowHash: Uint8List(32),
    );
    const hasher = AuditChainHasher();
    final canonical = hasher.canonicalPayload(draft);
    final hash = Uint8List.fromList(
      sha256.convert(<int>[...?prev, ...canonical]).bytes,
    );
    _rows.add(
      AuditLogRow(
        id: draft.id,
        operatorId: draft.operatorId,
        locationId: draft.locationId,
        chainDate: draft.chainDate,
        occurredAt: draft.occurredAt,
        actorKind: draft.actorKind,
        actorUserId: draft.actorUserId,
        actorPrincipalId: draft.actorPrincipalId,
        targetKind: draft.targetKind,
        targetId: draft.targetId,
        action: draft.action,
        payloadText: draft.payloadText,
        prevRowHash: prev,
        rowHash: hash,
      ),
    );
  }

  List<AuditLogRow> rowsForOperator(String operatorId, {DateTime? chainDate}) {
    return _rows
        .where(
          (r) =>
              r.operatorId == operatorId &&
              (chainDate == null || r.chainDate == chainDate),
        )
        .toList(growable: false);
  }
}

class _AuthEventsRecordingPool implements PostgresPool {
  _AuthEventsRecordingPool(this.chainStore);

  final _AuditLogChainStore chainStore;

  /// Reply for `from public.service_principals` lookup the B41
  /// issuance gateway runs. Tests that drive the real issuance
  /// gateway set this so the principal-load step finds an active row.
  String? servicePrincipalReplyId;
  List<String> servicePrincipalReplyScopes = const <String>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _AuthEventsRecordingTransaction(this);
  }
}

class _AuthEventsRecordingTransaction extends PostgresTransaction {
  _AuthEventsRecordingTransaction(this.pool);

  final _AuthEventsRecordingPool pool;
  _AuditLogChainStore get chainStore => pool.chainStore;

  bool _finalized = false;
  int _eventSeq = 0;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');

    if (sql.contains('insert into audit_logs') ||
        sql.contains('insert into public.audit_logs')) {
      // B.2 path: the gateway emitted an audit_logs INSERT. Feed it
      // into the in-memory chain mirror so the scenario assertions
      // can verify chain integrity.
      _passThroughAuditLogsInsert(parameters);
      return <PostgresRow>[
        <String, Object?>{
          'id':
              '${chainStore.rowsForOperator(parameters['operator_id'] as String).length}',
        },
      ];
    }

    if ((sql.contains('insert into auth_events_audit') ||
            sql.contains('insert into public.auth_events_audit')) &&
        sql.contains('returning event_id')) {
      _eventSeq += 1;
      return <PostgresRow>[
        <String, Object?>{
          'event_id':
              '00000000-0000-0000-0000-${_eventSeq.toString().padLeft(12, '0')}',
        },
      ];
    }

    // ─── B41 issuance gateway SQL shapes ─────────────────────────
    // PostgresServicePrincipalJwtIssuanceGateway.issue() runs raw
    // SQL through the executor — the cases below let it complete
    // end-to-end against the fake pool.
    if (sql.contains('from public.proxy_requests')) {
      // Idempotency lookup — no replay row, so the gateway proceeds
      // through the full issuance path (and the audit INSERT runs).
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.service_principals')) {
      final id = pool.servicePrincipalReplyId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'id': id,
          'scopes': jsonEncode(pool.servicePrincipalReplyScopes),
          'revoked_at': null,
        },
      ];
    }
    if (sql.contains('count(*)::int as issuance_count')) {
      return const <PostgresRow>[
        <String, Object?>{'issuance_count': 0},
      ];
    }
    if (sql.contains('insert into public.proxy_requests')) {
      return const <PostgresRow>[
        <String, Object?>{'request_id': '55555555-5555-5555-5555-555555555555'},
      ];
    }

    // SET LOCAL set_config calls, advisory locks, generic SELECTs —
    // no-op result so the wrapper completes its setup.
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    if (sql.contains('insert into audit_logs') ||
        sql.contains('insert into public.audit_logs')) {
      _passThroughAuditLogsInsert(parameters);
    }
    if (sql.contains('update public.proxy_requests')) {
      // Idempotency completion — must report 1 affected row or the
      // issuance gateway raises idempotency_completion_missing.
      return 1;
    }
    return 1;
  }

  void _passThroughAuditLogsInsert(PostgresParameters parameters) {
    final operatorId = parameters['operator_id'];
    final actorKind = parameters['actor_kind'];
    if (operatorId is! String || actorKind is! String) return;
    chainStore.simulateInsert(
      operatorId: operatorId,
      locationId: parameters['location_id'] as String?,
      occurredAt:
          _coerceDateTime(parameters['occurred_at']) ??
          DateTime.utc(2026, 4, 30, 12),
      actorKind: actorKind,
      actorUserId: parameters['actor_user_id'] as String?,
      actorPrincipalId: parameters['actor_principal_id'] as String?,
      targetKind: parameters['target_kind'] as String?,
      targetId: parameters['target_id'] as String?,
      action: (parameters['action'] as String?) ?? '',
      payloadText: (parameters['payload'] as String?) ?? '{}',
    );
  }

  static DateTime? _coerceDateTime(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String) {
      try {
        return DateTime.parse(raw).toUtc();
      } on FormatException {
        return null;
      }
    }
    return null;
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
