You are running CODE_HEALTH remediation for Forge & Flow on the branch
master @ d12eda81+. Your authority order is:

  1. This prompt.
  2. CODE_HEALTH.md at repo root (the audit you are remediating).
  3. CLAUDE.md at repo root (Hard Promises, Architecture Guardrails,
     Time Guardrails, RLS-Ready Schema, Proxy & API Conventions,
     Service-Layer Split). NEVER violate Hard Promise #7 (no BYO-key)
     or the operator-scoped repository pattern.
  4. docs/contracts/** for any rule the slice touches.
  5. docs/CODEX_PROMPT_GENERATION_STANDARD.md for the multi-block
     prompt format you reuse for sub-agents you spawn.

REPO ROOT: C:\Git Local Repos\forge_flow_demo

==============================================================
WHAT YOU ARE FIXING (CODE_HEALTH.md, audit dated 2026-05-06)
==============================================================

5 critical findings (C1-C5), ~20 high-severity findings across
proxy / auth / domain / integrations / migrations / persistence /
AI / UI / workers, plus 5 structural risks. Read CODE_HEALTH.md
end-to-end before you start. Do not skim.

The other Claude account is running plug-and-play onboarding
slices (Phase 8 binder + projector + sync worker deploy + OAuth
refresh wire-in). DO NOT TOUCH any of these files — they are
hot for the other lane:

  HOT FILES (forbidden until further notice):
    tool/advisor_proxy/admin_integrations_routes.dart
    tool/advisor_proxy/{pos,reservation,labor}_adapter_registry.dart
    tool/advisor_proxy/main.dart  *(see exception below)*
    tool/integration_sync_worker/**
    tool/first_connection_backfill_harness/**
    lib/services/integration/canonical_fact_post_commit_projector.dart
    lib/services/integration/dispatch.dart
    lib/services/integration/integration_sync_worker.dart
    lib/services/auth/oauth_refresh_cron.dart
    lib/services/integration/backfill_dispatch.dart
    lib/services/sync/http_sync_proxy_client.dart
    lib/services/app_data_status_service.dart
    Dockerfile (root)
    scripts/deploy_*.ps1

  EXCEPTION: tool/advisor_proxy/main.dart can be touched ONLY for
  SIGTERM-handler insertion (the C3 fix in CH-7 below). When you
  edit it, restrict the diff to the listener lifecycle around
  HttpServer.bind / serveRequests. If you find yourself needing
  to touch route logic in main.dart, stop and ask.

==============================================================
WORKFLOW (identical to the parallel-lane standard)
==============================================================

Each lane is an independent worktree:

  Agent({
    description: "<lane id>",
    isolation: "worktree",
    prompt: <see lane briefing below>
  })

Inside each worktree, the agent:
  1. Builds on a fresh branch named `claude/code-health-<lane-id>`.
  2. Implements the lane's scope ONLY. Touches no file outside the
     "Files in scope" allowlist.
  3. Runs `dart analyze` on changed files at minimum. If the lane
     touches a tested seam, runs the matching test
     (`flutter test test/<path>` or `dart test test/<path>`).
  4. Commits on its branch with a single message of the form:
       fix(code-health.<lane-id>): <one-line summary>
       Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  5. Pushes the branch.
  6. Opens a PR via `gh pr create` with title and body templated as:

       title: "fix(code-health.<lane-id>): <summary>"
       body:
         ## Summary
         - <bullet 1>
         - <bullet 2>

         ## CODE_HEALTH reference
         <quote the exact section of CODE_HEALTH.md this closes>

         ## Test plan
         - [ ] <command 1>
         - [ ] <command 2>

         🤖 Generated with [Claude Code](https://claude.com/claude-code)

  7. Reports the PR URL back to you.

You then HOLD for user review. DO NOT MERGE PRs yourself. Once the
user signals merge, the user does the merge from the master clone.

==============================================================
WORKTREE / PATH-COLLISION DISCIPLINE (don't repeat V1 mistake)
==============================================================

The previous parallel lane shipped agents that wrote into the
master clone instead of their isolated worktree. Prevent this:

  - Every Agent invocation MUST set isolation: "worktree".
  - The agent's prompt MUST start with: "You are working in an
    isolated git worktree. The repository root for this task is
    the current working directory of this shell. Do not cd up.
    Do not run `git -C <other-path>` commands. All edits go to
    files relative to this worktree's root."
  - The agent's prompt MUST end with a self-check: before commit,
    run `git rev-parse --show-toplevel` and confirm the path
    contains `.claude/worktrees/`. Abort and report if not.

==============================================================
SEQUENCING
==============================================================

Three migration-only lanes ship FIRST (sequenced, parallel within
the wave). They each create a migration file under db/migrations
and run `tool/migration_drift_scanner.dart --fix --strict-docs`
plus `tool/migration_cutoff_lint.dart`. They do NOT touch app
code. After all three migrations merge to master, Wave 1 (code
lanes) launches in parallel. Wave 2 (domain cleanup) is sequenced
last because it touches files several Wave 1 lanes also touch.

  Wave 0 — migrations (parallel within wave, all 3 ship together)
    M1   admin idempotency expires_at + sweep cron
    M2   password history salt + pepper columns
    M3   audit anchor azure blob + advisory lock infra

  Wave 1 — code (parallel within wave, file-disjoint)
    L1   C1 operator_owner role escalation
    L2   C2 Random.secure() idempotency
    L3   C5 UsersRepository operator_id predicates + cross-tenant
    L4   proxy hardening (SIGTERM + LLM breaker + body-cap +
         JWT enumeration leak + admin idempotency TTL code,
         needs M1)
    L5   sync worker (SIGTERM + FOR UPDATE SKIP LOCKED + claim
         discipline + bare-catch fix)         *** SKIP THIS LANE ***
                                              -- this is a HOT FILE,
                                              the other Claude
                                              account owns it
    L6   OAuth refresh claim discipline       *** SKIP THIS LANE ***
                                              -- HOT FILE, other lane
    L7   MFA removal (SIGTERM + retry cap + DLQ + audit-in-tx)
    L8   realtime + email outbox (DLQ counter + typed errors +
         SIGTERM)
    L9   audit anchor (crash recovery + advisory lock + Azure
         Blob daily wire, needs M3)
    L10  auth hardening (recovery code TOCTOU + constant-time
         consumer + recaptcha freshness + HIBP shape validation)
    L11  MFA enrollment race + GDPR pending-erasure expiry
    L12  password history salt+pepper code (needs M2)
    L13  Anthropic prompt cache on the wire + dart-define key
         removal
    L14  AlwaysMissAdvisorResponseCache → real cache, with
         provider-failure fallback (CH C: cache placeholder)

  Wave 2 — domain cleanup (sequenced after Wave 1)
    L15  domain layer cleanup combined into ONE lane because of
         cross-file touches:
            - BaselineData removed from lib/dev/, becomes a
              proper Layer 3 baseline service
            - schedule_plan_resolver Layer 7 dependency
              inversion (extract pure formula or invert dep)
            - labor_model decomposition rounding fix
            - cycleId millisecondsSinceEpoch → uuid v4
            - weekly_plan_snapshot Mon-first assertion
            - daypart_table.dart no longer imports
              lib/dev/demo_fixture_data.dart

After Wave 2, drop a final tracker update bumping
PROJECT_TRACKER.md "Now" to note CODE_HEALTH closeout, and edit
CODE_HEALTH.md to add a "Resolution" section listing each PR
URL keyed to the finding it closed.

==============================================================
LANE BRIEFINGS (paste these into the corresponding Agent prompt)
==============================================================

Each lane briefing is self-contained for the sub-agent. Append
this preamble to every lane prompt:

    "You are working in an isolated git worktree. The repository
    root for this task is the current working directory of this
    shell. Do not cd up. Do not run `git -C <other-path>`. All
    edits go to files relative to this worktree's root.

    Authority order: this prompt > CODE_HEALTH.md > CLAUDE.md >
    docs/contracts/**.

    Forbidden files (any edit aborts the lane):
    <paste HOT FILES list above>

    Before commit, run:
       git rev-parse --show-toplevel
    Confirm the path contains `.claude/worktrees/`. Abort and
    report if not."

------------------------------------------------------------
M1 — admin idempotency expires_at + sweep cron
  CODE_HEALTH ref:    C4 (admin idempotency no TTL)
  Files in scope:
    db/migrations/<NEW>_admin_idempotency_expires_at.sql
    docs/migrations/migrations_inventory.md  (drift output)
  Goal: add `expires_at TIMESTAMPTZ NOT NULL DEFAULT now() +
        interval '15 minutes'` to whatever table holds the
        admin idempotency rows (search advisor_proxy.dart
        `_runAdminIdempotent` → table reference). Add a
        partial index on (expires_at) WHERE status = 'in_flight'.
        Add a pg_cron sweep that DELETEs expired in_flight rows
        every 5 min. Operator-scoped if applicable; if global,
        document why.
  Verify: `dart run tool/migration_drift_scanner.dart --fix
          --strict-docs` then `dart run tool/migration_cutoff_lint.dart`.
  No code edits.

------------------------------------------------------------
M2 — password history salt + pepper columns
  CODE_HEALTH ref:    "Salt-less SHA-256 password-history hash"
  Files in scope:
    db/migrations/<NEW>_password_history_salt_pepper.sql
    docs/migrations/migrations_inventory.md
  Goal: add columns `password_hash_salt BYTEA`, `password_hash_pepper_id TEXT`,
        `password_hash_algo TEXT NOT NULL DEFAULT 'sha256'` to the
        password_history table (search
        `repository_password_history_check.dart` → table reference).
        Backfill existing rows with NULL salt + algo='sha256-legacy'.
        Add a CHECK constraint requiring (salt IS NULL) iff
        algo='sha256-legacy'.
  Verify: drift scanner + cutoff lint.

------------------------------------------------------------
M3 — audit anchor Azure blob + advisory lock infra
  CODE_HEALTH ref:    "Audit anchor sweep has no advisory-lock
                       guard" + paused Azure blob cadence
  Files in scope:
    db/migrations/<NEW>_audit_anchor_advisory_lock_infra.sql
    docs/migrations/migrations_inventory.md
  Goal: add `audit_anchor_advisory_lock_id INTEGER` constant table
        (1 row), add `last_anchor_blob_url TEXT, last_anchor_blob_at
        TIMESTAMPTZ` to the existing audit_anchor table. Do NOT
        unpause the cron — code lane L9 wires the daily Azure write.
  Verify: drift scanner + cutoff lint.

------------------------------------------------------------
L1 — C1 operator_owner role escalation
  CODE_HEALTH ref:    C1 (role_management_policy.dart:181)
  Files in scope:
    lib/auth/role_management_policy.dart
    test/auth/role_management_policy_test.dart
  Goal: in the grantable-roles check, ensure operator_owner cannot
        emit `super_admin` or `ff_support` in the allowed set,
        even within their own tenant. Mirror the existing tier-
        ordering check that exists for other actor kinds. Add
        regression test: operator_owner + grant super_admin →
        expect denial.
  Verify: `flutter test test/auth/role_management_policy_test.dart`

------------------------------------------------------------
L2 — C2 Random.secure() idempotency
  CODE_HEALTH ref:    C2 (proxy_refresh_token_revoker.dart:62)
  Files in scope:
    lib/services/auth/proxy_refresh_token_revoker.dart
    test/services/auth/proxy_refresh_token_revoker_test.dart (new)
  Goal: replace
          'idem-${DateTime.now().microsecondsSinceEpoch}'
        with a 128-bit hex from `Random.secure()` (look at how
        other call sites build idempotency keys — e.g.
        `lib/services/proxy/proxy_idempotency.dart` if present —
        and reuse). Test: 1000 generated keys are all distinct
        and each is exactly 32 hex chars.
  Verify: `flutter test test/services/auth/proxy_refresh_token_revoker_test.dart`

------------------------------------------------------------
L3 — C5 UsersRepository operator_id predicates + cross-tenant
  CODE_HEALTH ref:    C5 (users_repository.dart:444,869,887,906) +
                      "Cross-tenant scans" (3 SystemUser methods)
  Files in scope:
    lib/infrastructure/persistence/postgres/repositories/users_repository.dart
    test/infrastructure/persistence/postgres/repositories/users_repository_test.dart
  Goal: every UPDATE in `withSystem` (BYPASSRLS) MUST take an
        `operatorId` parameter and bind it in the WHERE clause.
        For the three System-tier scan methods
        (firebaseUidForUserSystem, findActiveUserIdByFirebaseUidSystem,
        findMfaRecoveryTargetByEmail) add a `requireOperatorId`
        named param defaulting to `null` only for the legitimate
        login-resolution callers (search call sites, update them
        to pass the operatorId once known). Add tests that prove
        a leaked operatorId mismatch returns 0 rows updated.
  Verify: targeted unit tests + `dart analyze` on changed files.

------------------------------------------------------------
L4 — proxy hardening
  CODE_HEALTH ref:    C3 (SIGTERM) + secondary LLM breaker/timeout +
                      body-size cap + JWT enumeration leak +
                      C4 admin idempotency TTL code (needs M1)
  Files in scope:
    tool/advisor_proxy/main.dart   (SIGTERM ONLY around HttpServer
                                    listen; no route-logic edits)
    tool/advisor_proxy/advisor_proxy.dart
    test/tool/advisor_proxy/secondary_llm_breaker_test.dart (new)
  Wait condition: M1 must be merged first.
  Goal:
    a) SIGTERM handler that:
       - calls `httpServer.close(force: false)` after a 25s grace
       - drains in-flight requests
       - flushes ProxyUsageCounterStore + audit log queues
       - then exits
    b) secondary LLM (Gemini) gateway:
       - per-call timeout = 8 seconds
       - circuit breaker (5 failures in 60s → open for 30s)
       - typed error classification, no bare catch
    c) body-size cap PER ROUTE: graph-candidate batch endpoint
       gets 16MB cap; everything else stays at 1MB. Search
       `_bodySizeLimit` and route registration.
    d) JWT verifier composite: collapse the "SP verifier installed"
       enumeration signal — return identical error text/timing
       whether SP verifier is wired or not.
    e) `_runAdminIdempotent`: read `expires_at` from the table
       (now exists per M1). On hit with `status='in_flight'` AND
       `expires_at < now()`, treat as orphan and reclaim. Add a
       background sweeper.
  Verify: targeted tests for breaker, body-size cap, idempotency
          reclaim, SIGTERM drain. `dart analyze` on changed files.

------------------------------------------------------------
L7 — MFA removal worker
  CODE_HEALTH ref:    "MFA removal worker has no retry cap, no DLQ" +
                      "audit-log + outbox enqueue happen AFTER
                       markCompleted outside the same transaction"
  Files in scope:
    lib/services/auth/mfa_removal_worker.dart
    tool/mfa_removal_worker/main.dart  (or wherever its loop lives)
    test/services/auth/mfa_removal_worker_test.dart
  Goal:
    a) SIGTERM handler in the worker entry main.dart.
    b) `attempt_count` increment + `max_attempts=10` retry cap;
       past cap, mark `status='dead_lettered'` and emit metric +
       outbox event for human triage.
    c) `markCompleted` + audit log insert + outbox enqueue all run
       in the SAME `withTenant` transaction. If any fails, the
       whole tx aborts and the row stays claimable.
  Verify: unit tests for cap + tx atomicity.

------------------------------------------------------------
L8 — realtime bridge + email outbox
  CODE_HEALTH ref:    "Realtime bridge DLQ is theatre" +
                      "Email outbox dispatcher reverse-engineers
                       failure kind from string `.contains`"
  Files in scope:
    lib/services/realtime/realtime_bridge.dart
    lib/services/email/email_outbox_dispatcher.dart
    tool/realtime_bridge_worker/main.dart  (SIGTERM)
    tool/email_outbox_dispatcher/main.dart (SIGTERM)
    test/services/realtime/realtime_bridge_test.dart
    test/services/email/email_outbox_dispatcher_test.dart
  Goal:
    a) realtime_bridge: increment `attempt_count` on every failed
       publish; when `attempt_count >= _dlqCap`, MOVE the row to
       `realtime_dlq` table (or set `status='dead_lettered'`),
       emit metric. Test: 5 failures → row reaches DLQ.
    b) email_outbox_dispatcher: introduce typed error union
       (TransientError, PermanentError, RateLimitError) returned
       from the SendGrid call site; dispatcher branches on type,
       no string `.contains`.
    c) Both worker entry main.dart files: SIGTERM handler.
  Verify: targeted tests + `dart analyze`.

------------------------------------------------------------
L9 — audit anchor (needs M3)
  CODE_HEALTH ref:    "Audit anchor verify can't recover from
                       crashed-write state" + "no advisory-lock
                       guard" + paused Azure blob cadence
  Files in scope:
    lib/services/audit/audit_anchor.dart
    tool/audit_anchor_job/main.dart
    test/services/audit/audit_anchor_test.dart
  Goal:
    a) Crash-recovery: on startup, scan for rows in
       `status='writing'` and roll forward (verify hash, set to
       'committed' or 'failed' deterministically).
    b) Wrap sweep in `pg_advisory_lock(audit_anchor_advisory_lock_id)`
       — only one anchor sweep at a time across all instances.
    c) After hash chain commit, write JSON manifest to Azure Blob
       Storage container `audit-anchors-prod`; populate
       `last_anchor_blob_url` + `last_anchor_blob_at` (added by M3).
       Use the existing AzureBlobClient; if missing, add minimal
       wrapper around `package:azblob` or shell out to az CLI in
       Cloud Run. Document the choice.
    d) SIGTERM handler in worker entry.
  Verify: integration test with fake blob client + advisory lock
          exclusion test.

------------------------------------------------------------
L10 — auth hardening
  CODE_HEALTH ref:    Recovery code TOCTOU + linear-scan timing +
                      reCAPTCHA challengeTs freshness + HIBP shape
                      validation order
  Files in scope:
    lib/services/auth/recovery_code_attempt_limiter.dart
    lib/services/auth/recovery_code_consumer.dart
    lib/services/auth/recaptcha_v3_verifier.dart
    lib/services/auth/password_change_service.dart
    test/services/auth/recovery_code_attempt_limiter_test.dart
    test/services/auth/recovery_code_consumer_test.dart
    test/services/auth/recaptcha_v3_verifier_test.dart
    test/services/auth/password_change_service_test.dart
  Goal:
    a) recovery_code_attempt_limiter: collapse
       `check + recordAttempt` into a single atomic UPDATE …
       RETURNING (or `INSERT … ON CONFLICT DO UPDATE … RETURNING`)
       so two parallel attempts cannot both pass.
    b) recovery_code_consumer: replace early-break linear scan
       with a constant-time comparison across ALL slots; the
       chosen slot is independent of timing.
    c) recaptcha_v3_verifier: reject when
       `challengeTs > 60 seconds old`. Configurable; default 60.
    d) password_change_service: shape validation (length, charset,
       complexity) runs BEFORE the HIBP roundtrip.
  Verify: per-file unit tests covering each fix.

------------------------------------------------------------
L11 — MFA enrollment race + GDPR pending-erasure expiry
  CODE_HEALTH ref:    "MFA enrollment finalize re-queries
                       accounts:lookup for newest factor" +
                      "GDPR pending-erasure approvals have no
                       expiry"
  Files in scope:
    lib/services/auth/identity_toolkit_firebase_mfa_client.dart
    lib/services/auth/gdpr_erasure_service.dart
    test/services/auth/identity_toolkit_firebase_mfa_client_test.dart
    test/services/auth/gdpr_erasure_service_test.dart
  Goal:
    a) Read the enrolled-factor PHONE_NUMBER (or matching factor
       id) from the finalize response payload directly; only
       fall back to accounts:lookup if the response is absent.
    b) gdpr_erasure_service: reject any approval whose
       `approved_at < now() - interval '14 days'`. Configurable
       per-deployment env.
  Verify: unit tests for both.

------------------------------------------------------------
L12 — password history salt+pepper code (needs M2)
  CODE_HEALTH ref:    "Salt-less SHA-256 password-history hash"
  Files in scope:
    lib/services/auth/repository_password_history_check.dart
    test/services/auth/repository_password_history_check_test.dart
  Goal: hash candidate password with per-row salt + global pepper
        (env-injected). Algo column 'sha256-legacy' rows still
        verify legacy way; new writes always use 'sha256-salted'.
        Constant-time compare on the digest.
  Verify: unit test for legacy + new format.

------------------------------------------------------------
L13 — Anthropic prompt cache on the wire + dart-define key removal
  CODE_HEALTH ref:    "Anthropic prompt caching is computed but
                       never sent on the wire" +
                      "defaultAnthropicOnlineCheck uses dart-define
                       API key" (Hard Promise #7 violation)
  Files in scope:
    lib/services/llm/anthropic_http_complete_fn.dart
    lib/services/advisor/advisor_model_config_service.dart
    test/services/llm/anthropic_http_complete_fn_test.dart
    test/services/advisor/advisor_model_config_service_test.dart
  Goal:
    a) anthropic_http_complete_fn: send `system` as a structured
       array of content blocks with `cache_control` markers when
       provided, instead of flat string. Match the shape that
       advisor_proxy.dart:4800 already computes.
    b) advisor_model_config_service: remove the dart-define API
       key path entirely; online check goes through the proxy
       (`/v1/llm/health` or equivalent). If the proxy isn't
       reachable, return Unknown rather than fabricating a result.
  Verify: roundtrip test that captures the outgoing JSON and
          asserts cache_control is on the first content block.

------------------------------------------------------------
L14 — AlwaysMissAdvisorResponseCache → real cache
  CODE_HEALTH ref:    "AlwaysMissAdvisorResponseCache still in
                       production wiring" — collapsed fallback
                       chain (LLM → secondary → cache → refusal)
  Files in scope:
    tool/advisor_proxy/advisor_response_cache.dart   (or wherever
                                                      AlwaysMiss
                                                      lives — search)
    tool/advisor_proxy/main.dart  (the single line that registers
                                   the cache provider — keep diff
                                   tiny and ONLY this line)
    db/migrations/<NEW>_advisor_response_cache_table.sql
    test/tool/advisor_proxy/advisor_response_cache_test.dart
  Goal: postgres-backed semantic cache table keyed by (operator_id,
        model_class, prompt_hash, embedding_id_optional). 24h TTL
        default. On cache hit, return stored response with
        `cache_hit=true`. The fallback chain becomes
        (LLM → secondary → cache → refusal) per the spec. Wire
        the new cache provider into main.dart, replacing the
        AlwaysMiss singleton.
  Verify: integration test that proves cache hit + miss; metric
          test that prompt_cache_hit_rate moves above 0%.

------------------------------------------------------------
L15 — Wave 2 — domain layer cleanup (sequenced last)
  CODE_HEALTH ref:    "BaselineData (in lib/dev/) is mutated and
                       read by canonical services" + "schedule_plan_resolver
                       Layer 7 imports lib/services/labor_model.dart" +
                      "labor_model.dart:266 decomposition rounding" +
                      "cycleId millisecondsSinceEpoch collision" +
                      "weekly_plan_snapshot Mon-first assertion" +
                      "daypart_table.dart imports demo_fixture_data.dart"
  Files in scope:
    lib/dev/baseline_data.dart                     (move OR delete)
    lib/services/baseline_*                         (BaselineData
                                                    callers)
    lib/services/target_cycle_service.dart
    lib/services/learn_benchmark_context_service.dart
    lib/services/baseline_selection_analytics_service.dart
    lib/services/labor_model.dart
    lib/domain/services/schedule_plan_resolver.dart
    lib/services/weekly_plan_snapshot_service.dart
    lib/widgets/daypart_table.dart
    test/services/target_cycle_service_test.dart
    test/services/labor_model_test.dart
    test/services/weekly_plan_snapshot_service_test.dart
  Wait condition: ALL Wave 1 PRs merged.
  Goal:
    a) Promote BaselineData out of lib/dev/ into a real Layer 3
       service (lib/services/baseline_authority_service.dart).
       Demo seeding becomes a writer-side function in lib/dev/
       that PRIMES that service at boot under kDemoMode. Canonical
       services no longer import lib/dev/.
    b) schedule_plan_resolver: invert the dependency. Either move
       the relevant pure formula out of labor_model.dart into a
       Layer 3 module both can import, OR pass the formula in as
       an injectable callback. Layer 7 (domain) does not import
       Layer 3+ (services).
    c) labor_model.dart:266: re-derive axis dollars as a single
       atomic computation rather than rounding 5 intermediates.
       Add property-based test: rounding cannot flip Primary
       Driver assignment within ±$0.50 noise.
    d) target_cycle_service.dart:283: cycleId from `Uuid().v4()`,
       not millisecondsSinceEpoch.
    e) weekly_plan_snapshot_service.dart:215: ASSERT day-row
       rotation matches `_defaultDayWeights` Mon-first ordering.
       Throw on mismatch.
    f) daypart_table.dart: stop importing lib/dev/demo_fixture_data.dart;
       widget pulls fixture only behind kDemoMode through a
       provider seam.
  Verify: full test suite for the touched files.

==============================================================
DISPATCH ORDER
==============================================================

1. Open three Agent calls in ONE message for M1, M2, M3.
   Wait. Confirm all three PRs open and look right. Push to user
   for review/merge. Block here until all three are merged to
   master.

2. Once Wave 0 lands, open Agent calls for L1, L2, L3, L4, L7,
   L8, L9, L10, L11, L12, L13, L14 in ONE message. Each in its
   own worktree. Wait. Each opens a PR. Hold for user merge.

3. Once Wave 1 fully lands, open ONE Agent call for L15.

4. After L15 lands: edit CODE_HEALTH.md to add a "Resolution"
   section. Edit PROJECT_TRACKER.md "Now" to note CODE_HEALTH
   closeout.

==============================================================
GOLDEN RULES
==============================================================

- Never edit a HOT FILE (the other Claude account owns those).
- Every commit message: fix(code-health.<lane-id>): <summary>.
- Every PR body cites the CODE_HEALTH section it closes.
- Do not merge PRs yourself; user merges from master.
- If a lane's tests reveal a broader bug, STOP and report. Do
  not silently expand scope.
- If `dart analyze` surfaces unrelated pre-existing infos in the
  changed file, leave them; only fix the issue your lane owns.
- If two lanes look like they touch the same file (re-read scope
  carefully — only L15 plus 1-2 others may collide), STOP and
  ask the user to re-sequence.

End of prompt.