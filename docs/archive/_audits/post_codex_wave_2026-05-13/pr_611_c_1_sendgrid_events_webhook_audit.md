# PR #611 Audit — C-1 SendGrid Event Webhook Receiver

**Slice:** C-1 (Lane C — Cross-Surface Parity; ledger row 83)
**Owner:** Claude lane parallel executor
**Branch:** `claude/c-1-sendgrid-events-webhook`
**Base:** `master` @ `0a6311cb`
**Gate:** `auto` per ledger row 83 — pre-reconciled by operator ("no business live yet" direction) despite proxy-touching surface
**Risk:** **Medium** — server-to-server inbound webhook with ECDSA gate + admin-pool write path; no schema/RLS/permission-key surface change; `advisor_proxy.dart` literally untouched
**Size:** 2,045 additions / 0 deletions / 7 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L with file:line citations + **5 executor-only lenses** EXEC+1 through EXEC+5). Consumes C-1a's prep migration (PR #599 merged) verbatim — `ON CONFLICT (provider_event_id) WHERE provider_event_id IS NOT NULL` predicate exactly matches the partial UNIQUE INDEX C-1a shipped. Pre-decode ECDSA P-256 signature verify confirmed by inline ordering (verify at line 539 / 721 precedes jsonDecode at line 563 / 740). Env-var-only pubkey (`SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM`) matches the C-1 spec's preferred source per the C-1 ECDSA pubkey gap investigation report; 503 retry posture aligns with SendGrid's 5xx retry semantics. `advisor_proxy.dart` UNTOUCHED — pre-check mount via `main.dart` mirrors `adminEmailRouter` / `Phase80IntegrationRoutes` precedent.

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present in PR body with file:line citations. Executor adds 5 executor-only lenses:
- EXEC+1: Signature-verify-before-decode discipline (line ordering pinned by test)
- EXEC+2: ON CONFLICT predicate exactly matches C-1a's partial UNIQUE INDEX
- EXEC+3: Env-var-only pubkey + 503 retry posture (correct SendGrid semantics)
- EXEC+4: Pre-check mount pattern (advisor_proxy.dart untouched)
- EXEC+5: Honest design-decision disclosures (3 sensible deferrals)

## What landed

| File | LoC | Kind |
|---|---|---|
| `tool/advisor_proxy/sendgrid_events_webhook.dart` | +827 | NEW route handler + ECDSA verifier seam |
| `lib/services/email/sendgrid_event_payload.dart` | +301 | NEW pure-Dart typed parser (no `package:postgres`) |
| `lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart` | +191 | NEW repository — single `insertProviderEvent` via `withSystem` admin-pool |
| `tool/advisor_proxy/proxy_bootstrap.dart` | +54 | router construction |
| `tool/advisor_proxy/main.dart` | +25 | pre-check mount ahead of `routeRequest` |
| `test/proxy/sendgrid_events_webhook_test.dart` | +506 (NEW) | 14 webhook cases |
| `test/services/email/sendgrid_event_payload_test.dart` | +141 (NEW) | 9 parser cases |

**Architectural decisions worth confirming:**
- **`withSystem` (admin-pool BYPASSRLS) for inbound webhook writer** — correct posture per CLAUDE.md "RLS-Ready Schema". SendGrid webhook is server-to-server with no tenant context; admin-pool with stable audit reason `'email_event.insert_provider_event'`. Existing FK-join RLS (via `email_outbox.operator_id`) preserved on reads.
- **Env-var-only pubkey + 503 retry** — matches C-1 spec's preferred source (per investigation report `c_1_ecdsa_pubkey_gap_investigation.md`); mirrors `EMAIL_CREDENTIALS_ENVELOPE_KEY` precedent; SendGrid retries 5xx by default so events queue upstream while operators wire the secret.
- **No `audit_logs` writes by design** — `email_event` row IS the audit trail; emitting per-webhook-event audit_logs would balloon the hash chain by 3-5x (SendGrid emits multiple events per send) with zero added signal.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `advisor_proxy.dart` literally untouched | `git diff origin/master -- tool/advisor_proxy/advisor_proxy.dart` returns 0 lines | Independent diff confirms; bleed-stop lint 19,805 / 19,900 (headroom 95 — UNCHANGED) |
| `lib/auth/permission_keys.dart` untouched | diff scope | Zero changes — ECDSA signature is the only gate; no Firebase JWT, no permission key |
| No new migration | diff scope | Zero `db/migrations/**` files; C-1a (PR #599) already shipped the column + partial UNIQUE INDEX |
| Verify BEFORE decode | route handler lines 539/563 + 721/740 | Independent grep: `_signatureVerifier.verify(...)` at line 539 precedes `jsonDecode(utf8.decode(body))` at line 563; same ordering at lines 721/740 in dispatch path. Inline comment at line 558 reinforces: "decode JSON only AFTER signature passes" |
| ON CONFLICT predicate matches C-1a partial UNIQUE INDEX | `email_event_repository.dart` dartdoc lines 40-41 vs `202605131700_c_1a_email_event_provider_id.sql:61` | Independent grep: both use `WHERE provider_event_id IS NOT NULL`. Postgres requires this match for partial-index-targeting `ON CONFLICT` |
| Env var name pinned and 503 retry posture | `kSendGridPubKeyEnvVar = 'SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM'` (line 124); 503 at lines 483 + 681 | Independent grep confirms both paths (tryHandle + dispatch) return 503 `pubkey_not_configured` when env unset |
| `withSystem` admin-pool write with stable audit reason | repository dartdoc lines 9-29 | `'email_event.insert_provider_event'` reason recorded; correct posture for cross-tenant inbound webhook |
| Parser is pure-Dart (no `package:postgres`) | grep on `sendgrid_event_payload.dart` | Zero matches; `postgres_import_lint` clean |
| 1 MB body cap (413 response) | route handler | Reasonable for SendGrid's max-30-events batch size |
| Pre-check mount pattern | `main.dart` (+25) ahead of `routeRequest` | Mirrors `adminEmailRouter` + `Phase80IntegrationRoutes` precedent; router writes its own response so monolith never sees the request |
| Pubkey loader per-request (rotation without restart) | `Platform.environment[kSendGridPubKeyEnvVar]` at line 244 | Loader invoked per-request — rotated key picks up without proxy restart |
| `audit_logs_update_lint` clean | tool output | INSERT-only flow; no `audit_logs` writes |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `0a6311cb` | ✓ — `gh pr view --json baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables + 5 EXEC+ lenses | ✓ — worker 14L + executor 14L + EXEC+1 through EXEC+5 |
| 7 files match PR body declaration | ✓ — `git diff --stat`: 7 files, +2,045 / 0 |
| `advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `permission_keys.dart` diff = 0 lines | ✓ — independent `git diff` |
| `db/migrations/` diff = 0 lines | ✓ — independent `git diff` |
| Verify-before-decode line ordering | ✓ — line 539 verify before line 563 decode (independent grep) |
| ON CONFLICT predicate matches C-1a migration | ✓ — both use `WHERE provider_event_id IS NOT NULL` (independent grep) |
| Env var name matches C-1 spec + investigation report | ✓ — `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM` at line 124 |
| 68/68 tests pass (23 new + 45 sibling regression) | ✓ disclosed |
| `dart analyze --fatal-infos` clean | ✓ disclosed ("No issues found!") |
| `postgres_import_lint` clean | ✓ disclosed |
| `audit_logs_update_lint` clean | ✓ disclosed |
| Bleed-stop unchanged at 19,805 / 19,900 | ✓ disclosed; independent diff confirms |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No Codex-owned conflict | ✓ — Claude lane C-territory; Codex's C-5 (PR #600) already merged earlier |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present + 5 EXEC+ lenses with file:line citations.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no new migration in this PR; C-1a is the migration and was queued (not applied) earlier |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 83 says C-1 auto-gate prereq `C-1a merged`; C-1a merged (PR #599) at audit start; matches PR scope |
| Worker disclosure operator should know | ⚠ THREE non-blocking disclosures: **(a)** `email_credentials.sendgrid_event_webhook_pubkey_pem` column deferred to a future C-1b for per-operator key rotation (env-var path is the precedent — mirrors `EMAIL_CREDENTIALS_ENVELOPE_KEY`); **(b)** no `audit_logs` writes by design (`email_event` row IS the audit trail); **(c)** pubkey loader called per-request for rotation-without-restart. All three are sensible defaults with documented rationale. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. All sensitive-path flags resolved cleanly (advisor_proxy.dart untouched, no migration, no permission key, no audit_logs balloon). Three honest disclosures are forward-looking design transparency, not slice defects.

## Cross-lane notes

- **Consumes C-1a verbatim** — PR #599 shipped the column + partial UNIQUE INDEX; C-1 uses exactly that predicate in the `ON CONFLICT` clause. No re-extension of C-1a's schema.
- **Unblocks C-2** — "wire-or-delete 6 template-only emails" can now proceed against the live event-receiver surface.
- **C-1b conditionally queued** — if per-operator key rotation becomes a P0 (e.g. credential compromise), add `email_credentials.sendgrid_event_webhook_pubkey_pem` then. Env var is fine for V1 launch ("no business live yet" + "F&F holds all provider keys server-side" per Hard Promise #7).
- **No interaction with parallel L_A1** (PR #608, merged earlier this tick) — disjoint surfaces.
- **No Codex-owned files touched** — Codex's C-5 (PR #600) is the only Codex slice merged in this wave; C-1 is Claude lane.

## Findings

None blocking. Three honest disclosures (deferred `email_credentials` column, no `audit_logs` writes, per-request pubkey loader) are forward-looking design transparency.

**Orchestrator note for closeout phase:** wire `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM` in Cloud Run env when the deploy actually goes live. Until then, 503 `pubkey_not_configured` is the correct retry posture (SendGrid will queue events upstream).

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 83 — C-1 ledger row (auto-gate, prereq `C-1a merged`)
- PR #599 (C-1a) — prep migration that this slice consumes verbatim
- `db/migrations/202605131700_c_1a_email_event_provider_id.sql` — partial UNIQUE INDEX predicate
- `docs/_audits/post_codex_wave/c_1_ecdsa_pubkey_gap_investigation.md` — env-var-first interpretation
- CLAUDE.md "RLS-Ready Schema" — `withSystem` admin-pool for server-to-server inbound
- CLAUDE.md Hard Promise #7 — F&F holds all provider keys server-side
- CLAUDE.md "Proxy & API Conventions" — proxy pre-check mount pattern
- Operator's 2026-05-13 "no business live yet" direction — auto-gate posture despite sensitive paths

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. C-2 unblocked. C-1b conditionally queued (only if per-operator key rotation becomes a P0 post-launch).
