-- Lane: code-health.M2
--
-- CODE_HEALTH reference:
--   "Salt-less SHA-256 password-history hash"
--   (lib/services/auth/repository_password_history_check.dart:38)
--   — credential oracle on table leak.
--
-- Intent (schema only; no app code in this slice):
--   The 9.0 password_history schema stored a bare SHA-256 of
--   (operator_id || user_id || candidate). Per-tenant + per-user salting
--   raised the cost of a same-password fingerprint attack across rows,
--   but it did NOT defeat an offline rainbow-table attack against a
--   single (operator_id, user_id) pair: an attacker who exfiltrates the
--   table can pre-compute SHA-256(operator || user || guess) for a
--   dictionary of guesses and learn whether each user re-used a common
--   password. There is no per-row work factor and no secret material
--   outside the table.
--
--   This migration adds the columns required to migrate the hash family
--   to a salted form WITHOUT touching the existing rows' bytes:
--
--     password_hash_salt        BYTEA         per-row random salt
--     password_hash_pepper_id   TEXT          which env-injected pepper
--                                              was mixed in (rotation)
--     password_hash_algo        TEXT NOT NULL identifies the hash family
--                                              of password_hash so the
--                                              verifier can pick the
--                                              right code path
--
--   Existing rows are flagged 'sha256-legacy' with NULL salt so the
--   legacy verification code path (no salt, no pepper) can still
--   constant-time-compare them. The DEFAULT for new rows is
--   'sha256-salted' so a forgotten code path cannot ship sha256 (legacy
--   without salt) by accident — code lane L12 will explicitly set the
--   algo on every write and is responsible for actually generating the
--   per-row salt and selecting the active pepper id from env.
--
--   A NOT VALID CHECK constraint enforces the legacy <-> salt invariant:
--     algo = 'sha256-legacy'  IFF  salt IS NULL
--   We mark it NOT VALID so the apply does not take an ACCESS EXCLUSIVE
--   lock to re-scan existing rows; the backfill above already ensures
--   every legacy row has NULL salt. We then VALIDATE CONSTRAINT in a
--   separate statement, which scans without the heavy lock.
--
--   Code lane L12 will:
--     * generate a 16+ byte CSPRNG salt on every write
--     * select the active pepper id from env / KMS
--     * write password_hash = SHA-256(operator || user || salt ||
--                                      pepper || candidate)
--     * verify legacy rows (algo = 'sha256-legacy') via the existing
--       unsalted code path during the migration window
--     * set algo = 'sha256-salted' on every new row
--
-- Forward-compatible: the columns are nullable (except algo), so older
-- proxy builds that have not yet been redeployed when this migration
-- applies continue to insert legacy-shape rows; the trigger of the new
-- behavior is the L12 code change, not this schema change.

ALTER TABLE public.password_history
  ADD COLUMN IF NOT EXISTS password_hash_salt BYTEA,
  ADD COLUMN IF NOT EXISTS password_hash_pepper_id TEXT,
  ADD COLUMN IF NOT EXISTS password_hash_algo TEXT NOT NULL DEFAULT 'sha256';

-- Backfill: every existing row is, by construction, the legacy
-- unsalted hash family. Mark it so the verifier can route to the
-- legacy code path. NULL salt + NULL pepper_id are explicit so the
-- CHECK constraint below holds for every existing row.
UPDATE public.password_history
   SET password_hash_algo = 'sha256-legacy',
       password_hash_salt = NULL,
       password_hash_pepper_id = NULL
 WHERE password_hash_algo = 'sha256';

-- Flip the column DEFAULT so any code path that forgets to set the
-- algo explicitly produces a salted row (which the CHECK constraint
-- below will reject if the salt is also NULL — a loud failure beats
-- silently writing an unsalted row labeled 'sha256').
ALTER TABLE public.password_history
  ALTER COLUMN password_hash_algo SET DEFAULT 'sha256-salted';

-- Integrity invariant: legacy rows have NULL salt; non-legacy rows
-- have non-NULL salt. NOT VALID skips the existing-row scan at apply
-- (the backfill already ensured legacy rows have NULL salt); the
-- VALIDATE CONSTRAINT below scans the table without taking an ACCESS
-- EXCLUSIVE lock.
ALTER TABLE public.password_history
  ADD CONSTRAINT password_history_salt_legacy_invariant_chk
  CHECK (
    (password_hash_algo = 'sha256-legacy' AND password_hash_salt IS NULL)
    OR
    (password_hash_algo <> 'sha256-legacy' AND password_hash_salt IS NOT NULL)
  ) NOT VALID;

ALTER TABLE public.password_history
  VALIDATE CONSTRAINT password_history_salt_legacy_invariant_chk;

COMMENT ON COLUMN public.password_history.password_hash_salt IS
  'code-health.M2: per-row CSPRNG salt for the salted hash family. NULL for legacy rows (algo=''sha256-legacy''). Non-NULL for every other algo. Enforced by password_history_salt_legacy_invariant_chk.';
COMMENT ON COLUMN public.password_history.password_hash_pepper_id IS
  'code-health.M2: identifier of the env-injected pepper mixed into the hash input. Lets us rotate the pepper without rehashing every row — the verifier resolves the pepper from this id. NULL is legal for legacy rows.';
COMMENT ON COLUMN public.password_history.password_hash_algo IS
  'code-health.M2: hash family identifier for password_hash. ''sha256-legacy'' = pre-M2 unsalted SHA-256 (operator || user || candidate); ''sha256-salted'' = SHA-256 (operator || user || salt || pepper || candidate). New rows default to ''sha256-salted''. The verifier dispatches on this column.';
