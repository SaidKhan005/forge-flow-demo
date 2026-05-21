# p3d_audit_chain_hash_storm — Phase 3D audit-chain hash storm

**Runner:** `test/pressure/p3d_audit_chain_hash_storm_test.dart`
(in-process pressure against `AuditChainHasher` in
`tool/audit_anchor/audit_anchor.dart`).

**What it pressures:** the hash-chained `audit_logs` table — SHA-256
`prev_row_hash || canonical_payload`, scoped per (operator_id,
chain_date). The in-process portion drives the Dart-side hasher that
mirrors the SQL trigger byte-for-byte, over a synthetic 1000-row
chain. If the hasher stays consistent under load, the on-DB chain
stays consistent.

**Status:** PASS. In-memory pressure (1000-row chain build,
concurrent hashing, tamper detection) runs under default
`flutter test` (no env gate, no skips).

## Inputs

- In-memory inputs: a deterministic chain builder that uses the
  production `AuditChainHasher.canonicalPayload` for byte
  composition + SHA-256 over `prev_row_hash || canonical`.

## What it asserts

- A 1000-row deterministic chain verifies clean (`verifyChain`
  returns zero violations).
- 1000 concurrent `recomputeRowHash` calls on the same row return
  byte-identical output (the hasher holds no shared state).
- A naive single-byte payload tamper at row 500 (stored hash left
  intact) is detected as a row_hash mismatch at row 500.
- A sophisticated tamper (payload changed AND row 500 hash
  recomputed) breaks the row 501 prev_row_hash link — still
  tamper-evident.
- 10 chains × 100 rows do not cross-link — each chain's first row
  has a null prev_row_hash and distinct terminal hash.

## How to read the output

- Healthy run: 5 in-memory test cases pass.
- Regression: a failure means the canonical-payload byte composition
  drifted from the SQL trigger, which would silently break the audit
  chain's forensic guarantee. This is auth-adjacent (hash-chained
  audit log); escalate per CLAUDE.md gate.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #5.

## Deferred

DB-backed concurrency pressure (N=1000 concurrent INSERTs against a
real `audit_logs` partition, asserting `verifyChain` returns zero
violations post-storm and the chain links remain monotonic by id)
needs a live Postgres and is deferred to a future infra-gated
slice — see POST_HARDENING_FOLLOWUPS.
