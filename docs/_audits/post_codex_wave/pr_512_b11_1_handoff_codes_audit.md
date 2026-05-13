# PR #512 Audit — B11.1 Handoff Codes Table + Endpoints

**Slice:** B11.1 (Lane B — features)
**Owner:** Claude lane executor
**Branch:** `claude/b11-1-handoff-codes-table-endpoints`
**Base:** `master` (no drift)
**Gate:** `operator` — **every single trigger** fires: auth-critical, RLS-touching, schema-touching (new migration), proxy-touching, high-risk per ledger.
**Size:** 3208 additions / 15 deletions / 14 files / 3426 diff lines
**Chunking:** light variant (under both 20-file and 5K-LoC thresholds; deep spot-checks on critical lenses given risk profile)

## Pattern B compliance

Both audit tables present in PR body ✓. Executor audit is unusually thorough — 14 lenses, every cell cites file:line + verdict.

## Verdict

**approve-for-merge subject to explicit operator approval.** Implementation is clean and discipline-compliant. Operator MUST decide because:
- New auth-critical surface (handoff redemption — A1 supersedes Decision #5)
- New `public.handoff_codes` schema requires Production1 migration apply event
- High-risk per ledger

## Executor spot-checks (auth-critical surfaces)

| Critical lens | Evidence on diff/master | Verdict |
|---|---|---|
| RLS wrapper discipline | Migration uses `app_current_operator()` (line 58, 124, 187, 195); bare `current_setting()` explicitly forbidden in inline comments (line 21, 196) | ✓ |
| Server-only code generation | `gen_random_bytes(16)` (~128 bits entropy) — primary key, never client-supplied (lines 40, 83, 129) | ✓ |
| Code-shape CHECK | base64-url 22-64 char server-side CHECK; padding stripped (lines 70, 107) | ✓ |
| URL discipline (A1 addendum) | Route handler reads `body['code']`, NOT `request.uri.queryParameters` — explicit comment at line 815-816; **explicit security test asserts redeem IGNORES code in URL query param** | ✓ |
| Hash-chain audit emission | `sha256.convert(utf8.encode(code))` 4 sites (mint emit + redeem emit + test fixtures); raw code never logged | ✓ |
| Idempotency-Key required on mint | 400 `idempotency_key_missing` if absent; 400 if too long; 409 `idempotency_key_conflict` on replay with different body | ✓ |
| Atomic UPDATE...RETURNING on redeem | Predicate enforced inside DB (consumed_at IS NULL AND expires_at > now() AND operator_id match); 410 on replay/expiry; 403 on cross-operator | ✓ |
| TIMESTAMPTZ throughout | No `TIMESTAMP WITHOUT TIME ZONE`; 60s±5s TTL CHECK | ✓ |
| Operator-leading index | Re-keyed after pre-push lint catch (commit `1c0ef052`); reaper index now `(operator_id, expires_at) WHERE consumed_at IS NULL`. PK on `code` covers single-row redeem lookup → no separate `(code)` index needed (documented inline at migration line 179-180) | ✓ |
| Frozen-surface | `lib/auth/permission_keys.dart` untouched; `lib/data/**` untouched | ✓ |
| Demo carve-out | No `kDemoMode` reader branches | ✓ |
| `postgres_import_lint` boundary | `package:postgres` only in `lib/infrastructure/persistence/postgres/` per worker output | ✓ |

## Pre-push lint catch (honesty observation — POSITIVE)

The executor's PR body explicitly discloses that the pre-push hook caught a real RLS-performance violation the executor's 14-lens audit missed (operator-leading index ordering). The fix landed in commit `1c0ef052` before the PR opened. **This is exactly the kind of honest disclosure the audit discipline rewards.** The lint guardrails are doing their job; the executor didn't try to hide the catch.

## Ancillary doc + script updates verified

Worker updated 5 ancillary files per `migration_drift_scanner --strict-docs` discipline (after-db-migrations rule in CLAUDE.md):

| File | Change | Verdict |
|---|---|---|
| `docs/POST_HARDENING_FOLLOWUPS.md` | "37 → 38" pending-apply count bump | mechanical, correct |
| `docs/phases/phase_11A_operations_console_plan.md` | migration cutoff reference update | mechanical |
| `docs/phases/phase_9_execution_backlog.md` | migration cutoff reference update | mechanical |
| `runbooks/phase_9_production1_migration_apply_runbook.md` | cutoff line update | mechanical |
| `scripts/postgres_staging_setup.ps1` | 1-line script tweak | mechanical |

These are required-by-discipline housekeeping, not scope creep.

## Authority anchors verified

- Addendum A1 (supersedes Decision #5) at `docs/_execution/lane_b_features/01_product_rule_and_ia.md` — redemption-code path replaces JWT-in-URL
- CLAUDE.md HP #4 (per-operator isolation NON-NEGOTIABLE) — RLS + operator-scoped table satisfies
- CLAUDE.md "RLS-Ready Schema" + `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — wrapper-only RLS posture confirmed
- CLAUDE.md "Time Guardrails" + `docs/contracts/phase_7_55_time_boundary_contract.md` — TIMESTAMPTZ + business_date convention preserved (no temporal regression)
- CLAUDE.md "Proxy & API Conventions" — idempotency key, structured logs, hash-chain audit

## Findings

**No additional findings beyond what the executor already surfaced.**

The pre-push lint catch + fix is the only "imperfection" in the audit trail, and the executor was transparent about it. Test coverage (31/31 pass) is comprehensive — includes the URL-query-param-ignored security test, replay 410, expired 410, wrong-operator 403, rate-limit 429, idempotency-key validation 400, idempotency replay 409, malformed-body 400, target_path validation 400, router-not-configured 503.

## Production1 migration apply queue

This PR adds migration `db/migrations/202605131030_b11_1_auth_handoff_codes.sql` (215 lines). It bumps the post-hardening pending-apply queue from 37 → 38 (per the executor's own ancillary doc update). The migration will land on staging immediately when this PR merges; Production1 apply event needs to be scheduled separately via `runbooks/phase_9_production1_migration_apply_runbook.md`. **Operator should authorize the Production1 apply event timing as part of approving this PR.**

## Cross-lane unblocking

Merging this unblocks:
- **B11.2** (Claude — RFC 9470 step-up challenge on sensitive routes) — depends on B11.1 merged per ledger.
- **C-5** (Codex — mobile pointer rows do deep-link redemption) — depends on B11.1 merged per ledger. Note: the mobile client-side URL pattern is outside this proxy contract, but addendum A1's URL-discipline is enforced server-side here.

## Next action

Escalate to operator with merge recommendation. Once approved → orchestrator merges + updates ledger + (separately) operator authorizes Production1 migration apply event timing.
