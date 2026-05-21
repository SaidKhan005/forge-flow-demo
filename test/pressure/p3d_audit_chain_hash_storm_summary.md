# p3d_audit_chain_hash_storm — Phase 3D audit-chain hash storm

**Runner:** `test/pressure/p3d_audit_chain_hash_storm_test.dart`
(in-process pressure against `AuditChainHasher` in
`tool/audit_anchor/audit_anchor.dart`; DB harness env-gated).

**What it pressures:** the hash-chained `audit_logs` table — SHA-256
`prev_row_hash || canonical_payload`, scoped per (operator_id,
chain_date). The in-process portion drives the Dart-side hasher that
mirrors the SQL trigger byte-for-byte, over a synthetic 1000-row
chain. If the hasher stays consistent under load, the on-DB chain
stays consistent.

**Status at branch fork point:** PASS. In-memory pressure (1000-row
chain build, concurrent hashing, tamper detection) runs under
default `flutter test`; the live-Postgres N=1000 INSERT storm skips
behind its env gate.

## Inputs

- Env gate (DB portion): `FF_RUN_PRESSURE_P3D_AUDIT_CHAIN=1` plus a
  local Postgres with the `audit_logs` partition + trigger applied.
- In-memory inputs: a deterministic chain builder that uses the
  production `AuditChainHasher.canonicalPayload` for byte
  composition + SHA-256 over `prev_row_hash || canonical`.

## What it asserts

- A 1000-row deterministic chain verifies clean (`verifyChain`
  returns zero violations).
- 1000 concurrent `recomputeRowHash` calls on the same row return
  byte-identical output (the hasher holds no shared state).
- A single-byte payload tamper at row 500 is detected at row 500 and
  fans out to downstream prev_row_hash links.
- 10 chains × 100 rows do not cross-link — each chain's first row
  has a null prev_row_hash and distinct terminal hash.

## How to read the output

- Healthy run: 4 in-memory test cases pass; the env-gate test skips.
- Regression: a failure means the canonical-payload byte composition
  drifted from the SQL trigger, which would silently break the audit
  chain's forensic guarantee. This is auth-adjacent (hash-chained
  audit log); escalate per CLAUDE.md gate.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #5.

## Backlog

Live-Postgres harness — N=1000 concurrent INSERTs against a real
`audit_logs` partition; assert `verifyChain` returns zero violations
post-storm and the chain links remain monotonic by id.
