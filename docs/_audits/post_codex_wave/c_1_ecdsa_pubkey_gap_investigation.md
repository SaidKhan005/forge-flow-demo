# C-1 ECDSA Pubkey Gap Investigation

**Date:** 2026-05-13
**Author:** Claude (orchestrator, post-PR #599 follow-up)
**Trigger:** PR #599 (C-1a) audit doc line 87, 95 — worker flagged that `email_credentials` lacks an ECDSA pubkey column required by C-1's `X-Twilio-Email-Event-Webhook-Signature` verifier path. Operator asked whether a C-1b prep migration is needed before C-1 can land.
**Scope:** Read-only investigation. No migration written. No ledger touched. No apply queue change.

---

## 1. Verdict

**c-1b-not-required** — C-1 can ship without a new `email_credentials` column. The C-1 slice prompt (`05_new_codex_execution_prompt.md` line 102-106) already pins the **env-var-first** posture: `SENDGRID_EVENT_WEBHOOK_PUBKEY` (PEM) is the primary key source; the `email_credentials` fallback is described as optional ("if present"). The env-var path requires zero schema change and matches the V1 single-tenant SendGrid posture (one F&F-wide subuser, one verification key, rotated via Cloud Run env / Secret Manager — identical contract to `EMAIL_CREDENTIALS_ENVELOPE_KEY` in the existing `202605040200_phase_9_8_email_provider.sql` migration comment at lines 41-45).

**One-sentence rationale:** C-1's signature verifier reads a single F&F-platform-wide ECDSA P-256 public key; that key fits the same env-var contract already used for the pgcrypto envelope key, so no additional `email_credentials` column is required for V1.

---

## 2. Current schema

`public.email_credentials` is defined in `db/migrations/202605040200_phase_9_8_email_provider.sql` lines 81-115. Columns:

| Column | Type | Nullability | File:line |
|---|---|---|---|
| `credential_id` | `uuid` | NOT NULL (PK, `gen_random_uuid()`) | `202605040200_phase_9_8_email_provider.sql:82` |
| `provider_kind` | `text` | NOT NULL (check: `in ('sendgrid')`) | `:83, 93-95` |
| `masked_value` | `text` | NOT NULL | `:84` |
| `encrypted_api_key` | `bytea` | NOT NULL (pgcrypto envelope of SendGrid API key) | `:85` |
| `kms_secret_name` | `text` | NULL | `:86` |
| `created_by` | `uuid` | NULL | `:87` |
| `updated_by` | `uuid` | NULL | `:88` |
| `is_active` | `boolean` | NOT NULL (default `true`) | `:89` |
| `rotated_at` | `timestamptz` | NOT NULL (default `now()`) | `:90` |
| `created_at` | `timestamptz` | NOT NULL (default `now()`) | `:91` |
| `updated_at` | `timestamptz` | NOT NULL (default `now()`) | `:92` |

Indexes / constraints:

- `email_credentials_pkey` on `credential_id` (`:82`).
- `email_credentials_active_uq` partial unique index on `(provider_kind) WHERE is_active` (`:98-100`) — enforces "exactly one active row per provider_kind."
- `email_credentials_provider_active_idx` on `(provider_kind, is_active)` (`:102-103`).
- `email_credentials_provider_kind_chk` check constraint locking `provider_kind` to `'sendgrid'` (`:93-95`).

Posture (per `:64-79`, `:108-115`): F&F platform-wide, **no `operator_id`, no RLS policy**. Reads/writes via the admin pool (`forge_admin` BYPASSRLS). Rotation INSERTs a new row and flips the prior `is_active` to `false` in one transaction.

**There is no Dart model for `email_credentials`.** `Grep "EmailCredential"` returns zero hits across the codebase. The only Dart consumer is `tool/advisor_proxy/admin_email_routes.dart` line 11 (a comment reference) and `lib/services/email/sendgrid_email_provider.dart` line 30-34 (provider-side docstring describing where the API key comes from). The active key is read repository-side by the proxy through the admin pool — no model object exists, so the column set above is the ground truth.

---

## 3. SendGrid verification flow — what C-1 actually needs

**SendGrid docs** (`https://www.twilio.com/docs/sendgrid/for-developers/tracking-events/getting-started-event-webhook-security-features`, fetched 2026-05-13):

- Cryptographic primitive: **ECDSA** ("Elliptic Curve Digital Signature Algorithm (ECDSA) is used for generating the private and public key pair").
- Signature header: `X-Twilio-Email-Event-Webhook-Signature`.
- Timestamp header: `X-Twilio-Email-Event-Webhook-Timestamp`.
- Signed payload: `timestamp || raw_body` (per SDK / C-1 spec at `05_new_codex_execution_prompt.md:90-92`).
- Key delivery: "you will see the **Signature verification** setting is enabled and your public verification key is displayed" — i.e., operator copies it from SendGrid UI; SendGrid's API also supports key retrieval. Format is base64-encoded ECDSA public key (industry-standard SendGrid client SDKs accept it as base64 → PEM or DER).

**C-1 slice spec** says (`docs/_execution/lane_c_parity/03_execution_slices.md:19`):

> ECDSA `X-Twilio-Email-Event-Webhook-Signature` verification — pubkey loaded from env or `email_credentials` row.

**C-1 prompt** says (`docs/_execution/lane_c_parity/05_new_codex_execution_prompt.md:101-106`):

> Required signature verifier:
> - ECDSA P-256 over SHA-256
> - Pubkey source: prefer env var `SENDGRID_EVENT_WEBHOOK_PUBKEY` (PEM); fall back to a row in `email_credentials` if present.
> - Reject if timestamp drift > 5 minutes (clock skew tolerance) to prevent replay attacks.

**Plumbing audit matrix** says (`docs/_execution/lane_c_parity/02_plumbing_audit_matrix.md:27`):

> Required: `X-Twilio-Email-Event-Webhook-Signature` (ECDSA over body + timestamp). Public key in `email_credentials` row or env var.

Three independent authority docs agree: env var is the **primary** key source, an `email_credentials` row is a stated **fallback option only**.

---

## 4. Gap analysis

**There is no schema-level gap that blocks C-1 from shipping.**

- The C-1 spec explicitly allows the env-var-only path (`SENDGRID_EVENT_WEBHOOK_PUBKEY`).
- The env-var precedent is already established: the existing `EMAIL_CREDENTIALS_ENVELOPE_KEY` env var (`202605040200_phase_9_8_email_provider.sql:41-45`) is the canonical "F&F platform-wide secret in Cloud Run env / Secret Manager" pattern; the SendGrid Event Webhook verification pubkey follows the same contract (one F&F-wide subuser → one verification key → rotated through env).
- V1 is single-SendGrid-subuser (per `phase_9_8_email_provider_slice.md:138`: "V1 expected volume: ~50 operators × ~30 emails/month per operator = 1,500/month. Free tier covers V1"). No per-operator SendGrid subuser fan-out is on the V1 plan, so no per-row pubkey is needed.
- A `Grep "pubkey"` across `lib/` returns zero hits. A `Grep "EVENT_WEBHOOK_VERIFICATION_KEY|event_webhook_pubkey|SENDGRID_VERIFICATION"` returns only authority-doc mentions (the ledger + this slice's planning docs). No existing column to reuse, but also no existing column being asked for by C-1's primary path.

**The flagged gap from PR #599 audit (the `email_credentials.event_webhook_pubkey_pem` column) is a *fallback* gap, not a *blocker* gap.** The C-1 worker would only hit it if the operator explicitly directs C-1 to use the DB-row path instead of the env-var path. The current C-1 prompt (line 103) directs the env-var path as the prefer.

---

## 5. C-1b draft spec

**Not required for C-1 to ship.** This section is left intentionally blank per the verdict in §1.

If a future slice (post-V1, or after the SendGrid setup proves the env-var path is wrong for some operational reason) does decide to add a DB-row fallback, the minimal column would be:

- File: `db/migrations/2026XXXXHHMM_c_1b_email_credentials_event_webhook_pubkey.sql` (next lex slot after `202605131700`).
- DDL: `alter table public.email_credentials add column if not exists event_webhook_pubkey_pem text;` — NULLABLE so existing rows replay cleanly.
- No new index needed (single-active-row pattern already covers lookup).
- No RLS change — `email_credentials` already has no RLS policy (F&F platform-wide, admin-pool access).
- No `GRANT`/`REVOKE` — existing table-level grants cover the new column.
- Cutoff-mirror doc bumps (per the C-1a / B11.1 / B2.1 precedent): runbook pending list + count, `POST_HARDENING_FOLLOWUPS.md`, `scripts/postgres_staging_setup.ps1` `MIGRATION_CUTOFF` marker, two phase-doc cutoff phrases.
- Test: ~10 cases (column exists, type text, NULLABLE, no new RLS policy, no new GRANT, idempotent replay, existing rows un-broken).
- Size: ~120 LoC migration + ~180 LoC test + 5 doc lines = small.

**This is documented here only as the future-option shape.** The recommendation in §7 is **do not ship it now.**

---

## 6. Alternative — env var only (the actual V1 path)

Pros:

- Zero schema change. C-1 ships as already-spec'd.
- Matches the existing F&F platform-wide secret idiom (`EMAIL_CREDENTIALS_ENVELOPE_KEY` from the same Phase 9.8 migration's bootstrap comment).
- Matches the V1 single-subuser SendGrid posture — no per-operator pubkey is needed because there is only one F&F-side SendGrid account.
- Rotation = deploy a new Cloud Run revision with the new env value. Same operational footprint already in use for `EMAIL_CREDENTIALS_ENVELOPE_KEY`. No new runbook section, no new admin UI rotation surface.
- KMS rollout (per HP #7, "production keys in Cloud Run env / KMS") will pick this env var up at the same time as the other Phase 9.8 secrets when the 8.0 KMS slice lands — no separate rollout step.

Cons:

- Future multi-subuser SendGrid fan-out (V2+ scale) would need a per-row pubkey. Not a V1 problem.
- A bad / missing env var fails closed on every webhook call until the deploy is fixed. This is the intended fail-mode for a server-side secret — same as the existing pgcrypto envelope key (`202605040200_phase_9_8_email_provider.sql:42-45`).
- Operator cannot rotate the verification pubkey from the admin UI today. **This is also the existing posture for `email_credentials.encrypted_api_key`** (no admin UI; rotation is a deploy-side / KMS-side action), so the env-var path matches the established convention.

**Net:** the cons are all "V2 or later" considerations. The env-var-only path is the right V1 shape.

---

## 7. Recommendation

**Proceed with C-1 as already-spec'd; do NOT author C-1b.**

- The C-1 prompt at `05_new_codex_execution_prompt.md:103` already directs the env-var path as the preferred key source. The C-1 worker will hit zero schema gaps on the env-var path.
- The PR #599 audit flag was forward-looking transparency (correct disclosure discipline), not a slice-blocking finding. The C-1a audit doc itself called both disclosures "forward-looking transparency, not blocking" (`pr_599_c_1a_email_event_provider_id_audit.md:87, 102`).
- If C-1's worker, during implementation, decides the env-var path is somehow insufficient (e.g., the operator wants per-environment pubkey rotation managed via a DB row instead of a deploy), the worker should **STOP and surface the question to the orchestrator** rather than retro-authoring an `email_credentials` column. Worker is not authorized to add schema in a non-schema slice.
- C-1 stays a no-migration slice; the C-1a prep covered the dedupe-key gap that *was* schema-touching, and that's the only schema work this wave needs for C-1.

**Action for the operator:** approve C-1 to launch with its current prompt. No C-1b. The env-var `SENDGRID_EVENT_WEBHOOK_PUBKEY` becomes a Cloud Run env / Secret Manager line item alongside the existing `EMAIL_CREDENTIALS_ENVELOPE_KEY` — both V1-launch operational prerequisites, both rotation-by-deploy, both KMS-eligible when 8.0 lands.

---

## Authority anchors

- `db/migrations/202605040200_phase_9_8_email_provider.sql` — `email_credentials` schema, env-var precedent (`EMAIL_CREDENTIALS_ENVELOPE_KEY`).
- `db/migrations/202605131700_c_1a_email_event_provider_id.sql` — additive-expand idiom precedent + the migration that *did* unblock C-1.
- `docs/_audits/post_codex_wave/pr_599_c_1a_email_event_provider_id_audit.md:87,95` — the flag that triggered this investigation.
- `docs/_execution/lane_c_parity/03_execution_slices.md:9-29` — C-1 slice spec.
- `docs/_execution/lane_c_parity/02_plumbing_audit_matrix.md:20-29` — E1 gap, pubkey-source phrasing.
- `docs/_execution/lane_c_parity/05_new_codex_execution_prompt.md:101-106` — C-1 prompt's env-var-first directive.
- `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md` — V1 single-subuser sizing.
- SendGrid Event Webhook Security Features docs — ECDSA primitive, header names, key delivery from SendGrid UI.
- CLAUDE.md HP #7 — server-side keys only; Cloud Run env / KMS pattern.
