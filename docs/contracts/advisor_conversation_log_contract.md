# `advisor_conversation_log` Contract

**Status:** Active. Lands with Phase 9.0Σ.h (table + audit-privacy
column split, 2026-04-28) and Phase 9.0Σ.h2 (audit-privacy permission
gate + repository audit-read path, 2026-04-28).

**Authority order:** This contract documents the at-rest privacy
posture, the audit-read code path, and the redaction / retention
ledger rules for advisor conversation provenance rows. The canonical
sources are:

- `db/migrations/202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`
  — table, partitioning, column-level GRANT split, RLS policies,
  retention purge function.
- `db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
  — `admin.audit_privacy.read` permission key + default role grants
  + `audit_privacy` Postgres role membership.
- `lib/auth/permission_keys.dart` — `PermissionKeys.adminAuditPrivacyRead`
  + `PermissionKeys.requiresMfa` membership.
- `lib/infrastructure/persistence/postgres/repositories/advisor_conversation_log_repository.dart`
  — `recordTurn` (write path) + `auditReadConversation` (audit-privacy
  read path).
- `docs/contracts/auth_permission_key_catalog.md` — catalog row.

When code or other docs disagree with this contract, the migrations
and `PermissionKeys` constants win.

## Why a separate contract

Item 5 of `phase_9_scalability_decisions_2026-04-27.md` (Hard Promise
#6) locks the at-rest privacy posture: every advisor turn writes one
provenance row through the proxy, raw question and recommendation
text are encrypted at rest, and the encrypted-content read path is
gated by a restricted audit-privacy / privacy-compliance permission.
Hashes and non-sensitive metadata stay queryable through the ordinary
`service_role` path so audit and replay surfaces can render summaries
without decrypting raw content.

This contract documents how those layers compose at runtime — which
permission gates which read, what the paired audit row looks like,
and how retention / legal-hold / redaction interact with the chain.

## At-rest encryption (CMK reference)

Each row carries:

- `content_encrypted bytea NOT NULL` — ciphertext of the canonical
  advisor-turn payload.
- `content_iv bytea NOT NULL` — initialization vector / nonce used
  by the AEAD primitive.
- `content_key_ref text NOT NULL` — reference to the KMS-managed
  Customer Managed Key (CMK), e.g. `kv://forge-flow/cmk/v1`. The row
  stores the **reference**, never the raw key material. Pairs with
  the CMK provisioned at server creation under `cutover.0a` (item 8
  of the 4-27 scalability lock).

The proxy encrypts the canonical payload at write time using the CMK
referenced in `content_key_ref` and binds the ciphertext + IV through
`AdvisorConversationLogRepository.recordTurn`. The repository
deliberately does **not** accept plaintext — encryption is upstream
of the persistence layer. The 9.0Σ.h migration does not call
`pgp_sym_encrypt(...)`; the database never sees plaintext content.

`content_hash text NOT NULL` (SHA-256 hex of the canonical payload)
is queryable through `service_role` for integrity / dedup checks
without decrypting the raw content.

## Column-level access split

`db/migrations/202604280007_phase_9_0sigma_h_advisor_conversation_log.sql`
configures three roles:

| Role | INSERT | SELECT (safe metadata) | SELECT (`content_encrypted`, `content_iv`, `content_key_ref`) | UPDATE / DELETE |
| --- | --- | --- | --- | --- |
| `service_role` | yes | yes (column allowlist) | **no** — column-level grant omitted | no |
| `audit_privacy` | no | yes (full row, NOLOGIN) | yes — full row | no |
| `forge_admin` | yes | yes (full row, BYPASSRLS) | yes — full row | yes (paired-super-admin / break-glass) |

Postgres enforces column-level grants at the privilege layer (before
RLS evaluates), so a `SELECT *` issued through the runtime
`service_role` connection errors at the privilege layer before any
row is returned. The encrypted columns are physically unreadable on
the runtime path; the only ordinary route to the raw bytes is the
audit-privacy access path documented below.

## Audit-privacy permission gate

The audit-privacy read path requires **all three** of:

1. **App-layer permission key.** `PermissionKeys.adminAuditPrivacyRead`
   (`'admin.audit_privacy.read'`) must be present in the caller's
   resolved permission set. The key is `requires_mfa = true`, so the
   caller's session must carry a fresh `auth_time` MFA assertion. The
   key is seeded by
   `db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`
   with `frozen = true`.
2. **Non-blank reason string.** Every audit read carries a free-text
   reason captured in the paired audit row's payload. Empty / blank
   reasons are rejected before the transaction opens.
3. **Postgres role assumption.** Inside the tenant transaction, the
   repository issues `SET LOCAL ROLE audit_privacy` immediately
   before the SELECT that touches `content_encrypted` /
   `content_iv` / `content_key_ref`, then `RESET ROLE` (back to the
   pooled connection's owning role) before writing the audit row.
   `SET LOCAL ROLE` is transaction-scoped, so the role assumption is
   automatically released at COMMIT/ROLLBACK; pooled connection reuse
   cannot leak audit-privacy access into the next request.

Default role grants for `admin.audit_privacy.read`:

- `super_admin` — granted (every-key invariant via the foundation
  cross-join seed, plus an explicit grant in the h2 migration so
  re-applies of the foundation seed do not drop the new key).
- `ff_support` — granted (F&F support's primary tool for
  investigating advisor incidents on behalf of an operator).
- `operator_owner` / `operator_manager` / `operator_supervisor` /
  `operator_staff` — **not** granted by default. Raw advisor
  conversation content is F&F-internal at launch. An operator who
  needs read access must request it via F&F support OR have a custom
  operator-scoped role explicitly grant the key through 9.6's role
  management surface.

## Paired audit row (every read)

Every successful audit-privacy read writes one row into
`public.audit_logs` (the SHA-256 hash-chained, append-only audit
table from 9.0Σ.f). The row carries:

- `operator_id` — the operator the conversation rows belong to.
- `location_id` — the location scope the audit-read path ran under.
- `chain_date` — UTC date of `occurred_at` (the chain partition
  scope; computed automatically by the audit_logs CHECK constraint).
- `actor_kind = 'user'` — F&F human actor.
- `actor_user_id` — the user_id of the audit-read caller.
- `target_kind = 'advisor_conversation_log'` — what was read.
- `target_id = '<conversation_id>'` — the conversation the read
  scoped to.
- `action = 'advisor_conversation_log.audit_privacy_read'` — the
  audit-action key.
- `payload` (jsonb object) — at minimum:
  - `reason` — the non-blank reason the caller supplied.
  - `records_read_count` — integer count of conversation_log rows
    the audit-read returned (zero allowed, e.g. when the conversation
    has been redacted or no rows match the predicate).

Audit rows are append-only at the grant shape (UPDATE / DELETE
revoked from `service_role` and `forge_admin`); the chain-hash
trigger forbids retroactive payload mutation without a break-glass
DBA path. Mid-row redaction follows the procedure in
`runbooks/audit_chain_verify_runbook.md`.

The audit-read repository method writes the audit row in the **same
tenant transaction** as the encrypted SELECT. If the audit insert
fails, the encrypted SELECT is rolled back too — there is no read
path that returns ciphertext without leaving an audit trail.

## Repository contract

`AdvisorConversationLogRepository.auditReadConversation(...)`:

- Validates the caller passed the `admin.audit_privacy.read`
  permission marker (a strongly-typed authorization handle, not a
  bare string compared at the boundary) and a non-blank `reason`.
- Opens a tenant-scoped transaction via
  `OperatorScopedRepository.withTenant`.
- Inside the transaction:
  1. `SET LOCAL ROLE audit_privacy` — flip into the column-level
     GRANT scope that admits encrypted columns.
  2. SELECT the conversation rows. The column list **explicitly
     includes** `content_encrypted`, `content_iv`,
     `content_key_ref`, and `content_hash` — those are the columns
     the role assumption exists to authorize. A SELECT issued
     through the runtime `service_role` connection cannot reach
     them (the column-level GRANT in the h migration omits them
     from `service_role`'s SELECT allowlist).
  3. `RESET ROLE` — drop back to the pooled connection's owning
     role before writing the audit row.
  4. INSERT the paired `audit_logs` row with `records_read_count`
     and `reason`.
- Returns a collection of `AuditPrivacyConversationRow` value
  objects.

### Return-type contract

`AuditPrivacyConversationRow` carries the encrypted payload
(`contentEncrypted`, `contentIv`, `contentKeyRef`, `contentHash`)
alongside the metadata so a forensic investigator can drive the
CMK lookup → AEAD decrypt pipeline. The bytes ride on the value
object under explicit, audit-named accessors:

- `contentEncrypted: List<int>` — unmodifiable view of the
  ciphertext.
- `contentIv: List<int>` — unmodifiable view of the AEAD IV /
  nonce.
- `contentKeyRef: String` — KMS reference (Key Vault path /
  version), never the raw key material.
- `contentHash: String` — SHA-256 hex of the canonical payload,
  for post-decrypt integrity cross-check.

`AuditPrivacyConversationRow.toString()` deliberately surfaces
**metadata only** (`id`, `conversationId`, `turnIndex`, `role`).
Accidental `print(row)` / log-line interpolation cannot leak
ciphertext, IV bytes, key references, or hash digests. Callers
that need the encrypted bytes must read the named field
explicitly, which makes every disclosure surface auditable in
code review. Decrypted plaintext (where it exists) must flow
through a separate, deliberately-audited surface — never through
this value object's `toString()`.

The `recordTurn` write path is unchanged; producers continue to bind
already-encrypted bytes + IV + KMS reference and never see this
audit-read surface.

Errors thrown from the repository never echo plaintext, ciphertext,
IV bytes, key references, hashes, tokens, or any bound parameter
value. Messages name only the table, the failure mode (e.g.
permission denial, RLS denial, blank reason), and the contract that
was violated.

## Retention / legal-hold / redaction ledger

The 9.0Σ.h migration ships the schema hooks the retention/legal-hold
gate from item 5 (Q9 retention compatibility) requires:

- `legal_hold boolean NOT NULL DEFAULT false` — per-row freeze flag.
  When `TRUE`, the row is excluded from automatic retention purges
  regardless of age. Mutated only via the `forge_admin` BYPASSRLS
  paths (paired-super-admin / litigation hold). `service_role` may
  READ the flag for legal-hold UX but cannot UPDATE it.
- `retention_class text NOT NULL DEFAULT 'standard'` — tiered
  retention bucket: `'standard'` (launch retention window),
  `'extended'` (contractual longer-than-standard), `'legal'` (soft
  hold paired with `legal_hold = true`), `'permanent'` (never-purge,
  also excluded by the purge predicate).
- `advisor_conversation_log_op_purge_idx` — partial index excluding
  legal-hold and permanent rows so the periodic purge scan walks
  only eligible rows.
- `public.advisor_conversation_log_purge(target_operator_id,
  before_ts, batch_size)` — `SECURITY DEFINER` function executable
  only by `forge_admin`. Batched DELETE of rows older than
  `before_ts` for the named operator. **Never** deletes rows where
  `legal_hold = true` or `retention_class = 'permanent'`.

### Redaction ledger

GDPR Art. 17 erasure of advisor-conversation rows runs through the
paired-super-admin BYPASSRLS path:

1. The redaction operator obtains paired-super-admin approval and
   captures the redaction reason, target user, and date range.
2. A `forge_admin`-scoped transaction performs the redaction (UPDATE
   to clear encrypted content + IV but preserve the row id /
   metadata required by the audit chain) OR a partition-drop +
   retention-class flip per the procedure in
   `runbooks/gdpr_erasure_runbook.md`.
3. An `audit_logs` row is written with `action =
   'advisor_conversation_log.redact'`, `target_kind =
   'advisor_conversation_log'`, `target_id = '<conversation_id>'`,
   and `payload.reason` + `payload.paired_super_admin_approver_id`
   + `payload.records_redacted_count`.

The audit-read path (`auditReadConversation`) returns redacted rows
the same way it returns active rows: as names-only value objects with
the redaction state visible (e.g. `is_redacted = true`,
`redacted_at`). Ciphertext is not surfaced for redacted rows even to
audit-privacy callers — the redaction ledger is the source of truth
for what was redacted and when.

### Retention sweeps

The Phase 10a / 11a Cloud Run scheduled job calls
`advisor_conversation_log_purge` in a batched loop until it returns
0. The runbook (`runbooks/advisor_conversation_log_retention.md`,
queued under Phase 10a) documents:

- Per-operator retention window resolution.
- Pre-sweep dry-run query.
- Batched-loop cadence + monitoring.
- Audit-row emission for each sweep (action =
  `'advisor_conversation_log.retention_purge'`, payload.deleted_count
  + payload.before_ts + payload.batch_size).
- Verification that legal_hold and permanent rows survive.

## Out of contract scope

- Encryption primitive selection (AEAD algorithm + key length) —
  documented in the `cutover.0a` CMK provisioning runbook; this
  contract names only the column shape (`bytea` ciphertext + `bytea`
  IV + `text` key reference).
- Per-operator retention windows — operator-scope settings live on
  `operators` / `operator_compliance_profile`, not on this contract.
- The Phase 11b advisor UX read surface — that surface reads
  metadata-only summaries through `service_role`; only the
  audit-privacy / redaction / forensic surfaces consume the encrypted
  columns.
