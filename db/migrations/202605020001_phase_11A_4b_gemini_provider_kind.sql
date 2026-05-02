-- Phase 11A.4b — widen provider_credentials.key_kind to admit 'gemini'.
--
-- 11A.4 (202605010000_phase_11A_4_provider_credentials.sql) locked the
-- key_kind set to ('anthropic', 'voyage', 'azure_db'). Block 2 adds
-- Gemini as a server-side LLM fallback (see Hard Promise #7 in
-- CLAUDE.md), which adds a fourth rotatable lane to the masked-display
-- ledger that backs the F&F Operations Console. The row shape, the
-- partial unique index, and the rotation transaction shape are all
-- unchanged — only the CHECK constraint widens.
--
-- The constraint is dropped and recreated under the same name so future
-- audits / dumps see a single named constraint per kind set, not a
-- chain of historical aliases.

begin;

alter table public.provider_credentials
  drop constraint if exists provider_credentials_key_kind_chk;

alter table public.provider_credentials
  add constraint provider_credentials_key_kind_chk check (
    key_kind in ('anthropic', 'voyage', 'azure_db', 'gemini')
  );

commit;
