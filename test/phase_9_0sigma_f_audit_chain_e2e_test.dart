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

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

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
