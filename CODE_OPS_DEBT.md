# Code Ops Debt Report

**Audit date:** 2026-05-07
**Branch reviewed:** `master` @ `932d46f` (post `claude/code-health-factcheck-addendum`, post `8.operator-self-service.per-vendor-oauth-descriptors`, post 2026-05-07 doc trim).
**Method:** Six parallel read-only audit agents, each scoped to a distinct surface, with explicit instructions to exclude (a) anything already in `CODE_HEALTH.md` (closed or addendum residuals) and (b) the current Phase 8 framework push (vendor-credential broker, sink production binder, OAuth refresh worker, per-vendor OAuth descriptors, `8.framework.*`, `8.gap-*`, `8.transport.*`, `8.spine-bridge-sink-fanout.*`).

This doc is the operational-debt sibling to `CODE_HEALTH.md`:
- `CODE_HEALTH.md` = original 2026-05-06 audit + closeout + 2026-05-07
  fact-check addendum. Mostly closed; residuals call out specific
  surfaces where a phase doc still needs to land.
- `CODE_OPS_DEBT.md` = this doc. Captures **doc-vs-code drift**:
  features the trackers call accepted/live but the code is
  operationally under-finished. Companion to the V1 launch punchlist.

---

## Executive summary

The codebase has a recurring "wired-but-inert" pattern that's broader
than `CODE_HEALTH.md` captured. Components are constructed and exported
but never instantiated in production `main.dart` files; NOTIFY producers
fire without LISTEN consumers; contract gates compile but evaluate to
`false`; runbooks describe acceptance harnesses without owning a
binary. Six distinct surfaces show the same shape:

1. **Phase 11A admin console** — feature flags pinned to `false`,
   server routes missing for shipped permission keys.
2. **Phase 11W operator web console** — Sessions team-listing returns
   501; Business Timing READ uses demo gateway in prod.
3. **Phase 10a real-time + audit anchor + cron jobs** — five `pg_cron`
   jobs emit NOTIFY into channels with no LISTEN consumer.
4. **Vendor adapters / capability flags** — vendor IDs spelled two
   different ways across files; webhook signature verifiers handed an
   OAuth token instead of a webhook signing secret.
5. **Mobile core sync** — ForgeFlow flavor missing star/target
   write-client wiring (Hard Rule #1 violation); 8 server columns
   silently dropped on the wage_role_rows mobile read; weekly-plan
   provenance fields ignored.
6. **Cutover preflight + acceptance harness** — preflight runs 2 of
   6 documented smokes; secret check throws `StateError`; "Browser Use
   acceptance harness" is a manual click-path runbook with no harness
   binary.

Practical impact: the spine is built, most slices are honest about
what they shipped, but the **last 5% of every shipped slice — the part
where production is pointed at the new code — is missing in roughly a
third of the surfaces the trackers say are done.**

---

## What we excluded (read this if a finding looks duplicated)

This audit deliberately did not re-flag:

- Anything in `CODE_HEALTH.md` Closed / Deferred / Out-of-scope /
  Addendum sections (e.g. C1–C5, advisor_proxy.dart monolith size,
  conflicting `actor_kind` constraint definitions,
  `phase_8_set_business_date()` `SECURITY DEFINER`,
  `DatabaseHelper.instance` hardcoded to `DemoScope.restaurantId`,
  Postgres pool size pinned at 4, pre-flight token estimate
  client-supplied, cost-discipline levers unwired, per-process
  permission cache invalidation, sync worker bare `catch (_)`,
  `ShiftDashboardNotifier._load` race, MFA removal audit-log
  atomicity, `labor_model.dart` rounding, etc.).
- The current Phase 8 framework finishing pushes:
  `8.framework.async-adapter-factories`, `8.framework.deploy-script-pgcrypto-and-vendor-secrets`,
  `8.framework.proxy-config-vendor-app-credentials`, `8.framework.production-oauth-refresh-closures`,
  `8.framework.per-tenant-location-config-resolver`, `8.framework.adp-and-qbt-gateways`,
  `8.framework.tenant-routing-webhook-adapters`, `8.framework.vendor-credential-resolver-bridge`,
  `8.framework.typed-app-credentials-humanity-qbt-7shifts-libro-publicbaseuri`,
  `8.adapter-sink-production-binder`,
  `8.oauth-refresh-production-worker`, `8.oauth-refresh-worker.closure-registry-wire-in`,
  `8.operator-self-service-vendor-connect-routes`,
  `8.operator-self-service.per-vendor-oauth-descriptors`,
  `8.operator-self-service.route-alignment-gap-5-6`,
  `8.gap-1` through `8.gap-7`, `8.transport.*`,
  `8.spine-bridge-sink-fanout.*`, `8.backfill-worker-adapter-factory-wire-in`.

If a finding here looks like it should be in CODE_HEALTH, it is
deliberately a **post-CODE_HEALTH** finding (i.e. a regression after
the audit was authored, or a surface CODE_HEALTH never reached).

---

## Findings — by theme

Severity tags within each theme:

- **P0** = launch-blocking or actively wrong (data corruption, exfil,
  or feature non-existent despite "ACCEPT" claim).
- **P1** = operationally degraded; visible to first operator.
- **P2** = NOTIFY-emitter without consumer (cron-driven feature that
  doesn't run).
- **P3** = defense-in-depth gap, capability/contract drift, or harness
  theater.

### Theme A — Pinned-to-`false` admin actions waiting on the unscheduled "session-claim resolver"

These features are catalogued in docs/migrations + reachable in
widgets, but the production admin shell hardcodes the gate to `false`.
No phase doc names where the resolver lands; no slice currently
scheduled.

| Sev | Finding | Ref |
|---|---|---|
| P1 | `canEditSeeded = false` (constant) | `lib/admin/admin_routes.dart:907` |
| P1 | `canResetMfa`, `canIssuePairedErasure`, `canExportAuditLog` all `const … = false` (covers 11A.14 reset-MFA-factors, paired-approval erasure, 11W.5 audit-log export) | `lib/admin/admin_routes.dart:1109-1111` |

### Theme B — Server routes that doc-claim ACCEPT but don't exist

| Sev | Finding | Ref |
|---|---|---|
| P0 | 11A.14 paired-approval erasure has no proxy route. User-action switch hard-codes only `suspend`/`reactivate`/`soft-delete`/`reset-password`/`reset-mfa`/`cancel-mfa-removal`/`force-logout`. Zero `erase_pii` / `/erase` routes anywhere. | `tool/advisor_proxy/advisor_proxy.dart:10303` |
| P1 | 11A.14 ships permission key `admin.users.reset_mfa_factors` (in `202605061100_…`); proxy gates on the legacy `team.users.reset_mfa`. Zero references to the new key in `tool/advisor_proxy/`. | `tool/advisor_proxy/advisor_proxy.dart:10289-10299` |
| P1 | 11W.4 Sessions team-listing throws `team_sessions_not_routed` 501; `/v1/auth/team/sessions` does not exist on the proxy. Sessions screen always silently degrades to "own sessions only" in prod. | `lib/operator_web/auth/firebase_operator_web_auth_source.dart:586-592` |
| P1 | 11W.7 ships PATCH for account/timing but no GET. Reads fall through to the legacy account endpoint, which doesn't include the four new editable columns from migration `202605070000_…`. | `tool/advisor_proxy/operator_routes.dart:51-55` |
| P1 | 11W.5 audit-log "export" actually pages `/v1/auth/audit-log` 100k times client-side and renders RFC 4180 in the browser. Permission gate is widget-only theater; proxy never sees the new key. | `lib/operator_web/services/web_team_audit_log_gateway.dart:586-637` |

### Theme C — NOTIFY producers without LISTEN consumers

Each migration registers a `pg_cron` schedule that emits NOTIFY; the
consumer worker exists but is never instantiated in `main.dart` /
`proxy_bootstrap.dart`.

| Sev | Channel | Worker class | Ref |
|---|---|---|---|
| P1 | `audit_anchor_tick` (daily 02:00 UTC) | Cloud Scheduler subscriber paused; no LISTEN; `tool/audit_anchor/main.dart:269-270` returns `ScaffoldRejectingAuditAnchorBlobClient` whenever `AZURE_AD_TENANT_ID` is unset, with no startup hard-fail. **Fail-OPEN.** | `db/migrations/202605061700_hardening_audit_anchor_daily_schedule.sql:160-188` + `tool/audit_anchor/main.dart:269-270` |
| P2 | `rollups_tick` (60s + 5min) | `RollupWorker` defined but never instantiated in prod. Phase 9.0Σ.k rollup aggregation is theatre. | `db/migrations/202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql:188-246` + `lib/services/rollups/rollup_worker.dart:54` |
| P2 | `forge_email_outbox_tick` (per-minute) | `EmailOutboxDispatcher` defined but never instantiated outside tests. Producer-side enqueues accumulate as `status='pending'` forever. | `db/migrations/202605040200_phase_9_8_email_provider.sql:364-407` + `lib/services/email/email_outbox_dispatcher.dart:308` |
| P2 | `mobile_push_outbox` | `MobilePushDispatcher` defined but never instantiated; no claim method on the outbox repo. | `tool/advisor_proxy/mobile_push_notifications.dart:299-378` |
| P2 | `OutboxTripwirePoller` | Defined for Phase 10a.4 Q22 cadence; never instantiated outside admin observability screen. | `lib/services/realtime/outbox_tripwire_poller.dart:52` |
| P2 | `pg_partman` daily partition maintenance | `cron.schedule('partman_maintenance', …)` is a comment-only TODO. Runbook step, not DB-resident. | `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql:38-46` |

### Theme D — Phase 10a "shared state" replay is single-pod-only

| Sev | Finding | Ref |
|---|---|---|
| P0 | `RealtimeReplayResolver(backlog: realtimeInProcessPublisher)` reads the in-process 256-entry ring buffer of the same pod. After Cloud Run restart or any cross-pod reconnect, every cursor falls outside the empty backlog and the route emits `replay_truncated`. The `last_event_id` replay claim from Phase 10a.5 is satisfied within one pod's lifetime only. | `tool/advisor_proxy/main.dart:399-449` |
| P1 | `PUBSUB_REALTIME_ENABLED` flag exists; the publisher path is `_unwiredPubsubMessagePublisher` `throw StateError(…)`. **Pub/Sub adapter is genuinely not wired despite Phase 10a.1 ACCEPT.** | `tool/advisor_proxy/main.dart:1185-1196` |
| P3 | The bounded `event_outbox` retention sweep at 03:00 UTC ships in `202605051000_phase_10a_3_outbox_retention_sweep.sql` alongside the legacy `event_outbox_retention_sweep_daily` cron at 09:00 UTC from `202605050200`. Neither migration drops the legacy schedule; on Azure split-DB topology both DO blocks emit NOTICE-and-return when applied to `forgeflow`, requiring a manual `cron.schedule_in_database(..., 'forgeflow')` runbook step. | `db/migrations/202605051000_phase_10a_3_outbox_retention_sweep.sql:280-324` |

### Theme E — BYPASSRLS UPDATEs missing `operator_id` predicate ✅ closed via [PR #304](https://github.com/SaidKhan005/forge-flow-demo/pull/304) (`251c008`)

Same shape as the already-closed C5 finding; CODE_HEALTH only fixed
four call sites (`updateStatus`, `softDelete`, `redactPii`,
`bumpRolesVersion` on `users_repository`). Three more existed; all closed.

| Sev | Finding | Ref | Status |
|---|---|---|---|
| P0 | `revokeAllSessionsForUserAsAdmin` filters only by `user_id` inside `withSystem`. Cross-tenant exfil shape if RLS has any bug. | `lib/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart:281-289` | closed: `251c008` (EXISTS subquery via `users.operator_id` since `auth_sessions` has no own `operator_id` column) |
| P0 | `clearForUser` (GDPR helper) deletes by `user_id` only inside `withSystem`. | `lib/infrastructure/persistence/postgres/repositories/password_history_repository.dart:173` | closed: `251c008` (EXISTS subquery — same shape) |
| P0 | `acceptInvite` / `revokeInvite` UPDATE only on `invite_id`. RLS plus the wrapper-context is the sole defense; the per-tenant predicate the contract calls "primary defense" is absent. | `lib/infrastructure/persistence/postgres/repositories/auth_invites_repository.dart:163, 190` | closed: `251c008` (literal `operator_id` predicate — `auth_invites` carries the column directly) |

### Theme F — Permission catalog hand-typed where the lint can't catch it

`docs/contracts/auth_permission_key_catalog.md` says
`lib/auth/permission_keys.dart` is the source. `permission_key_lint.dart`
catches catalog/constant drift but not raw string usage in widgets.

| Sev | Finding | Ref |
|---|---|---|
| P3 | `'team.users.invite'`, `'team.users.deactivate'`, `'team.roles.assign'` etc. as hand-typed strings despite `PermissionKeys.teamUsersInvite`/`Deactivate`/`Assign` existing. | `lib/screens/team/team_settings_section.dart:356-826`, `lib/screens/settings_screen.dart:767-777` |
| P3 | Each operator_web screen redefines `const String kHierarchyViewPermissionKey = 'team.users.view'` (etc.). Multiple parallel string copies of the same dotted key. | `lib/operator_web/screens/{hierarchy,members,audit_log,roles,sessions}_screen.dart` |
| P3 | `actorKind` parameter defaults to `'user'` even when callers pass `actorServicePrincipalId`. CLAUDE.md promises actor_kind never NULL; six call sites never override (`mfa_operations_gateway.dart:562/665/770`, `repository_password_change_gateway.dart:140`, `repository_auth_operations_gateway.dart:1447`). Worker-driven audit rows silently mis-tag as `'user'`. | `lib/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart:114` |

### Theme G — Vendor identifier / capability inconsistencies

| Sev | Finding | Ref |
|---|---|---|
| P0 | `kSevenShiftsVendorId='7shifts'` in the credential bridge; `'seven_shifts'` in the adapter and labor registry. Dispatcher resolves on `'seven_shifts'`; OAuth descriptors register `'7shifts'`. **A connection persisted by the OAuth flow with `vendor_id='7shifts'` will fail `_isVendorRegistered` and emit `vendor_not_registered`.** Same drift in `vendor_capability_index.dart` cadence-picker keying and `vendor_admin_status_catalog.dart:177`. **closed:** `a052c34` ([PR #306](https://github.com/SaidKhan005/forge-flow-demo/pull/306)) — `'seven_shifts'` is single source of truth; display strings preserved as `'7shifts'`; no backfill migration needed. | `lib/integrations/labor/seven_shifts_credential_bridge.dart:14` vs `lib/integrations/labor/seven_shifts_labor_adapter.dart:71` |
| P0 | `lookupSigningSecret` reads `access_token_ciphertext`. **HMAC signing secrets ≠ OAuth bearer tokens.** Toast / Square / Clover / Libro field-mapping docs treat webhook signing as a separate provisioning artifact. No `webhook_signing_secret_ciphertext` column anywhere. **Every verifier in the binder receives the wrong material; signature verification cannot validate any real vendor.** | `lib/services/integration/repository_inbound_webhook_gateway.dart:243-256` |
| P1 | Humanity adapter declares `authMode: VendorAuthMode.keyPaste`; binder treats Humanity as OAuth, requires `proxyConfig.hasHumanityAppCredentials`. A keyPaste vendor cannot be "disabled" by missing app creds. | `lib/integrations/labor/humanity_labor_adapter.dart:451` + `tool/advisor_proxy/phase_8_production_binder.dart:651-682` |
| P1 | Oracle MICROS Simphony has `OracleMicrosSimphonyWebhookSignatureVerifier` registered, but adapter declares `webhookSupport: pollOnly`. **Verifier is unreachable; `InboundWebhookHandler` only fires for non-pollOnly capability.** | `tool/advisor_proxy/phase_8_production_binder.dart:481-514` + `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart:186` |
| P3 | Aloha sink header comment claims `coversFieldExposed: false`; adapter + registry both declare `true`. Sink comment is stale; downstream readers grepping the sink for source of truth will get the wrong answer. | `lib/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink.dart:66-71` |
| P3 | Banned `'seated_at'` Dart literal in a non-INSERT key array. The per-file grep tests target sinks only; this slipped past. | `lib/services/integration/open_shift_snapshot_projector.dart:787` |
| P3 | SevenRooms `partnership_status.md` lacks the `Application status:` field that 16 of 17 vendors carry. Lifecycle column drift between adapter capability profile (states `documented`) and partnership status. | `docs/integrations/sevenrooms/partnership_status.md` |

### Theme H — Mobile↔server-truth contract violations

| Sev | Finding | Ref |
|---|---|---|
| P0 | Production ForgeFlow flavor does **not** pass `starTargetSelectionWriteClient` to `bootstrapAndRunApp`. Only `lib/main.dart:48` wires it. `BaselineManagerService.serverSelectionWriter` is `null` in prod; manager override silently writes locally via `TargetCycleService.applyManagerOverrideCycle`. **Mobile becomes durable owner — exactly what `mobile_core_star_target_truth_contract.md` Hard Rule #1 forbids.** | `lib/main_forgeflow.dart:61-79` |
| P0 | `firebase_auth_runtime_bindings.dart` unconditionally wires `ProxyMobilePushTokenGateway` regardless of whether migration `202605060000_…` is applied. **Token-register POSTs from a production phone before staging-apply will 500 against the missing `mobile_push_tokens` table.** No staging-gate flag. | `lib/services/auth/firebase_auth_runtime_bindings.dart:183-187` + `runbooks/phase_9_production1_migration_apply_runbook.md:633-636` |
| P1 | Empty server table returns `200 + {rows:[], next_cursor:null}`. Sync clients only short-circuit on `available:false`/`status:unavailable`. **Cannot distinguish "feature not yet projected" from "operator has zero stars."** Same shape for weekly_plan reads. | `tool/advisor_proxy/star_target_routes.dart:437-446` + `lib/services/sync/star_target_sync_resources.dart:443-457` |
| P1 | Proxy emits `wage_role_row_id, job_code, vendor_id, vendor_role_id, source, is_active, effective_at, metadata, updated_by`. Mobile `_wageRoleRowFromJson` reads only `role_name, labor_bucket, hourly_rate, weighted_hours`. **8 server columns dropped on the floor.** | `tool/advisor_proxy/proxy_bootstrap.dart:2047-2052` + `lib/services/sync/http_sync_proxy_client.dart:962-988` |
| P1 | `wage_role_rows` SQLite table has no `server_id` column. Cache key is `INTEGER PRIMARY KEY AUTOINCREMENT + (restaurant_id, role_name) UNIQUE`. **Renamed/duplicated/deleted-then-recreated server rows can't be tracked across syncs.** Only `replaceAll` works correctly. | `lib/infrastructure/persistence/sqlite/sqlite_database_schema.dart:285-294` |
| P1 | Server emits `is_active, supersedes_snapshot_id, lock_reason, metadata, locked_by_user_id`; mobile `_snapshotPayload` reads none. **Mobile cannot tell which snapshot is the locked week-in-force plan when server returns multiple snapshots for one week.** | `lib/services/sync/weekly_plan_sync_resources.dart:251-340` + `tool/advisor_proxy/weekly_plan_routes.dart:534-564` |
| P1 | `data_accuracy_service_period_settings` keyed rows live in volatile `_latestDataAccuracyServicePeriodSettings` only; no SQLite cache. **App restart between sweeps returns empty until next pull.** Mobile-side computations fall back to legacy single-row settings silently. | `lib/services/sync/postgres_shift_record_to_mobile_sync.dart:234-258` |
| P1 | `fetchFirstBackfillStatus` returns `{first_backfill_status: null}` 200 when no row exists. **Conflates "no first-connect ever started for this operator" with "first-connect job genuinely missing/lost."** | `tool/advisor_proxy/proxy_bootstrap.dart:2102-2137` + `lib/services/sync/http_sync_proxy_client.dart:281-296` |
| P1 | Realtime invalidation list has no entry for `restaurant_users` insert/delete. **Reassigning a user to a different-tz location silently uses stale `BusinessScope.businessTimezone` until next manual sync trigger.** | `lib/services/scope/business_scope_repository.dart:41-62` + `lib/services/sync/mobile_operational_sync_runtime.dart:217-261` |

### Theme I — Demo-mode reader-side leaks (Hard Promise #2 violation)

CLAUDE.md: *"kDemoMode is a writer-side switch; same tables, same
reads, same UI either way."*

| Sev | Finding | Ref |
|---|---|---|
| P1 | `AppDataStatusService.evaluate` branches on `bool.fromEnvironment('kDemoMode')` at READ time, returning a different `AppDataStatus.demo()` shape vs `.current()`. | `lib/services/app_data_status_service.dart:16,136` |
| P1 | Login screen branches on `kDemoMode || FORGE_FLOW_DEMO_MODE` to render an extra "demo operator sign-in" button. | `lib/screens/auth/login_screen.dart:17-19` |
| P1 | 11 admin gateway accessors fall back to `_default*DemoGateway` when no live gateway is wired. **kDemoMode walkthroughs and unwired prod deploys converge on the same in-memory demo seed.** Pricing / Corpus / Integration / Observability / FeatureFlags / Debug / Members / Roles-Hierarchy / Audited-Support all silently demo on env-var typo; only Operator/Location fail-closes loudly. | `lib/admin/admin_routes.dart:1410,1416,1419+` + `lib/main_admin.dart:215-217+` |
| P3 | 4 production paths still import `lib/dev/demo_fixture_data.dart` (one is the SQLite bootstrap). Not in CODE_HEALTH closed/deferred lists. | `lib/services/shift_data_source.dart:12`, `lib/screens/baseline_tracker.dart:8`, `lib/screens/schedule_builder.dart:11`, `lib/infrastructure/persistence/sqlite/sqlite_database.dart:12` |

### Theme J — Cutover & acceptance harness theater

| Sev | Finding | Ref |
|---|---|---|
| P0 | `phase_production_cutover_plan.md:250-256` lists 6 cutover.0 smokes (Postgres SELECT 1, **AGE Cypher MATCH**, **pgvector cosine**, **`/health` 200**, RLS-leading-column audit, **`pg_partman`+`pg_cron` active**); the harness only runs schema_presence + RLS + firewall + secrets + DNS. **4 of 6 promised smokes missing.** Running cutover.0 today greens an environment that may be missing AGE / pgvector / health / partman+cron. | `tool/cutover/preflight_smoke.dart:281-313` |
| P0 | `_defaultSecretRead` is a stub that throws `StateError` on any non-skipped run, forcing every workstation invocation to either pass `--skip-secrets` (yellow) or red-fail. **No live GCP Secret Manager SDK call wired anywhere.** | `tool/cutover/preflight_smoke.dart:560-573` |
| P3 | Runbook describes manual click-path workflow with table templates and screenshot conventions. **No `tool/browser_use/`, no `test/e2e/`, no harness binary** — `grep` for `browser_use|run_browser_use|browser_use_runner` in `*.dart` returns zero matches. | `runbooks/browser_use_acceptance_harness_runbook.md` |
| P3 | Claims acceptance gate for every runtime slice; **no CI lint, no commit hook, no enforcement.** Operator-honor-system. | `docs/contracts/slice_runtime_acceptance_contract.md` |
| P3 | 11A.3.x graphify routes return `graph_candidates_not_configured` 503 when bundle isn't on disk. `tool/advisor_proxy/graphify_candidates/candidates/` is empty (only README ships). **Any deploy without hand-staged bundle is a 503 wall.** | `tool/advisor_proxy/advisor_proxy.dart:11944,12021` |

---

## Launch-blocking shortlist (P0-tagged items)

If V1 ships before these land, the listed consequence is what an
operator hits on day 1.

| # | Finding | Day-1 consequence |
|---|---|---|
| 1 | 7shifts vendor-id drift (Theme G) | First 7shifts OAuth connect creates a record the dispatcher refuses to process. Operator sees "connected" with no data flowing. |
| 2 | Webhook signature verifier reads OAuth token instead of HMAC secret (Theme G) | No real vendor's signed webhook ever validates. Either every webhook drops, or — worse — verification short-circuits and an attacker who knows a webhook URL can impersonate any vendor. |
| 3 | 3 BYPASSRLS UPDATEs missing operator_id (Theme E) | Any RLS bug propagates to cross-tenant session revocation, password-history wipe, or invite mutation. Same exfil shape as the closed C5. |
| 4 | ForgeFlow flavor missing star/target server-write client (Theme H) | Manager star/target overrides write to the phone's SQLite instead of the server. Hard Rule #1 violation; operator switches devices and loses their state. |
| 5 | Mobile push migration not staging-applied but client unconditionally calls the proxy (Theme H) | First production phone token-register hits a missing table; proxy returns 500. Push notifications cannot be enabled until the migration applies. |
| 6 | Cutover preflight missing 4/6 smokes + secret check is a stub (Theme J) | `cutover.0` greens an environment that may have a broken AGE / pgvector / health / partman / secrets state. Launch-readiness verdict is unsafe. |
| 7 | 11A.14 paired-approval erasure has no proxy route + reset-MFA-factors gates on legacy key (Themes A + B) | The "delete a customer's data" action is a 404. Reset-MFA-factors is reachable through the old (broader-scope) permission, not the new (narrower) one shipped with the slice. |

---

## Recommended sweeps (close most of the audit in five focused passes)

Each sweep is file-disjoint enough to parallelize across worktrees if
needed; the sequencing matters only for #5.

1. **NOTIFY/LISTEN sweep.** Walk every `pg_cron` migration. For every
   NOTIFY channel, assert there's a LISTEN consumer instantiated in
   production startup (`tool/advisor_proxy/main.dart`,
   `tool/advisor_proxy/proxy_bootstrap.dart`, or a sibling `tool/`
   binary that `Dockerfile`/Cloud Run actually starts). Add a CI lint
   that grep-matches NOTIFY channels against LISTEN strings in
   production code paths. Closes Theme C entirely (5 channels) plus
   the audit-anchor blob fail-OPEN in Theme C.

2. **Demo-fallback hardening sweep.** Walk every admin / operator-web
   gateway accessor in `lib/main_admin.dart`, `lib/main_operator_web.dart`,
   and the `*_resolveGateway` helpers. Replace silent demo fallback
   when prod URI resolution fails with a startup hard-fail. Adds a
   prod-only loud banner if any gateway resolved to a demo seed.
   Closes Theme I rows 3–4 plus the four `lib/dev/` imports from prod
   paths.

3. **`withSystem` predicate sweep.** Walk every `withSystem` call site
   in `lib/infrastructure/persistence/postgres/repositories/`. For
   every UPDATE/DELETE that operates on a row with an `operator_id`
   column, add the predicate. The C5 fix template applies as-is.
   Closes Theme E entirely.

4. **Permission-key sweep.** Replace inline permission strings with
   `PermissionKeys.*` constants across `lib/operator_web/screens/`
   and `lib/screens/team/`. Then extend `permission_key_lint.dart` to
   grep for raw `'team.…'` / `'admin.…'` / `'operator.…'` literals in
   widget files. Also fix the `actor_kind` default-to-`'user'` shape
   (require an explicit kind on every audit insert with a service
   principal). Closes Theme F entirely.

5. **Cutover.0 completeness sweep.** Land the four missing
   `preflight_smoke.dart` smokes (AGE Cypher MATCH, pgvector cosine,
   `/health` 200, `pg_partman+pg_cron` active). Wire the GCP Secret
   Manager SDK into `_defaultSecretRead` so secret check is a real
   call. **Sequencing:** must land before any operator runs
   `cutover.0`. Closes Theme J rows 1–2.

After those five sweeps:

- Theme C, E, F, I, J → mostly closed.
- Theme A → still open until the "session-claim resolver" lane is
  scheduled (no other sweep touches it).
- Theme B → still open; each missing route needs its own targeted
  slice (5 routes).
- Theme D → still open; Pub/Sub adapter + cross-pod replay need their
  own slice.
- Theme G → still open; the 7shifts vendor-id rename is a one-line
  fix per file but needs coordination across 5+ files; the webhook
  signing-secret column is a schema slice.
- Theme H → still open; each mobile/server contract row needs a
  per-resource fix (DAO mirror columns, sync field reads, scope
  invalidation entry).

---

## Plain-English version

### The headline

A lot of things that look finished aren't actually turned on. The
pattern is the same one CODE_HEALTH already named — but it's broader
than just the proxy file. It shows up in six places now: the admin
console, the operator web console, the real-time event system, the
vendor integrations, the mobile sync, and the cutover safety check
itself.

The shape is always: someone built the right component, wrote tests
against it, marked the slice "accepted" — but then nobody wired the
component into the production startup path. Or, worse, the wiring
exists but it's pointing at a placeholder that returns "no" or "empty"
instead of doing the real thing. The dashboards say green; the feature
is dead.

### If you launched tomorrow, what would actually break

**Day-one webhooks would fail silently.** The code that's supposed to
check vendor webhook signatures is grabbing the wrong key — it's
reading the OAuth login token instead of the webhook signing secret,
which is a different thing. So no real vendor's signatures will ever
verify. In a calm system, you'd see noisy logs. In an attack, anyone
who knew a webhook URL could pretend to be a vendor.

**A 7shifts connection would land in a broken slot.** The 7shifts
integration has its name spelled two different ways inside the code
(`'7shifts'` in one half, `'seven_shifts'` in the other). The OAuth
flow uses one spelling; the dispatcher that routes incoming data uses
the other. So a customer who connects 7shifts gets a connection
record that the data router refuses to process. They'd appear connected
and see nothing arrive.

**The first phone that connects to production would crash the push
system.** The mobile-push database table hasn't been applied to
production yet, but the code that registers a phone for push
notifications doesn't check that — it tries to write to the missing
table and the proxy returns 500. Then the push dispatcher itself was
built but never started up in production, so even after you apply the
migration, no notifications would actually send.

**The "delete a customer's data" action doesn't exist.** The 11A.14
phase shipped a key for "paired-approval PII erasure" and put it in
the docs and in the permission catalog. There's no server route for
it. The button in the UI calls a URL that returns 404.

**Five admin actions are wired to "no, you can't."** Edit-seeded-roles,
reset-MFA, paired-erasure, audit-log-export, and a couple more all
check a permission that's hardcoded to `false` in the production admin
shell. The comment says they're waiting on a "session-claim resolver"
that's supposed to land later — but no phase doc names where that
happens, and no slice is currently scheduled to do it. So the admin
features look reachable in the UI and refuse to run.

**The cutover safety check itself isn't safe.** The pre-flight harness
is supposed to run six smokes before you flip the switch (database
query, graph database, vector search, health endpoint, partition
manager, security check). It actually runs three. The other three are
stubbed out. Worse, the "verify production secrets are in place"
check throws an error every time it's invoked — so to get a green
run, you have to pass `--skip-secrets`, which makes the green
meaningless. If you ran cutover.0 today, it would green-light a launch
on an environment that's missing things.

### Things that quietly don't work

**Daily audit-log anchor isn't running.** The hash-chained audit log
writes a daily "anchor" to Azure Blob to bound when tampering could
have happened. The migration sets up a Postgres notification every day
at 02:00 UTC. Nothing in the code listens for that notification. The
Cloud Scheduler that was supposed to listen is paused. So the daily
anchor cadence is zero in production today. The chain itself works;
the bound on tampering doesn't.

**The rollups system is theatre.** Phase 9.0Σ.k schedules background
jobs every 60 seconds and every 5 minutes to recompute aggregates.
The migration is applied. The worker that consumes those signals
exists in code, has tests, and is never started. So those scheduled
wake-ups fire into the void; rollups never actually compute.

**The email outbox accumulates forever.** Same shape: there's a queue,
there's a per-minute scheduler, there's a dispatcher class. The
dispatcher is never instantiated in production. Anything queued sits
in `pending` status. (The 9.8 email phase is marked accepted.)

**Real-time event replay only works inside one server pod.** The
"if you disconnect and reconnect, you won't miss messages" feature
reads from a 256-entry buffer that lives in the same pod's memory.
If Cloud Run rotates the pod (which happens routinely), that buffer
is empty for the new pod, and every reconnecting client gets a "we
lost your place" error. The Pub/Sub adapter that would solve this is
checked into the code with a `throw` statement that says "not wired."

### Things the docs say work that quietly drift

**The mobile app is silently the source of truth where it shouldn't
be.** A few weeks ago we shipped a contract that says "the server owns
which star shifts the manager picked" — mobile is supposed to be a
cache. In the actual ForgeFlow startup file, we forgot to pass the
server-write client to the bootstrap. So the manager-override path
falls back to writing locally on the phone instead of the server.
Hard Rule #1 of that contract is being violated in production.

**The mobile app drops fields the server now sends.** When we expanded
the `wage_role_rows` table to track who-edited-what and source-of-truth
metadata, the proxy started emitting eight new columns. The mobile
sync client is still reading the four original fields and ignoring
the rest. Same shape on weekly-plan snapshots — the server emits five
fields the mobile client doesn't read, including the one that says
"this is the locked week-in-force plan."

**The mobile cache loses some settings on app restart.** Service-period
data-accuracy settings get pulled from the server into a variable in
memory. There's no SQLite cache. So if you restart the app between
sweeps, those settings vanish until the next pull lands.

**Demo mode leaks into production reads in five places.** The deal is
"demo mode is just a writer-side switch — same tables, same reads,
same UI either way." That promise breaks in five spots: the app data
status service, the login screen, eleven admin gateways (when an env
var typo silently picks the demo path), and four files that still
import `lib/dev/` directly into production code (one of them is the
SQLite bootstrap itself). So in production, with the wrong env, an
operator can be looking at seeded fake data without any banner or
warning.

### The defense-in-depth pattern from CODE_HEALTH is recurring

CODE_HEALTH found one class of UPDATE statement that filtered by
`user_id` only when it ran in BYPASSRLS context, instead of
`(operator_id, user_id)`. We fixed those. Three more of the same shape
exist elsewhere — revoking sessions, clearing password history,
accepting/revoking invites. If RLS has a bug, those three operations
leak across tenants the same way the closed ones did.

Also: the "actor kind" field on the audit log defaults to `'user'`.
Worker-driven audit rows (six call sites that pass a service-principal
id) never override the default, so they write `actor_kind='user'`
even though the actor is a worker. The CLAUDE.md promise says
actor_kind is never NULL; the unstated promise is "and never wrong,"
which it is.

And: permission keys are defined in a "frozen catalog"
(`lib/auth/permission_keys.dart`) that's supposed to be the source of
truth. The lint catches catalog drift. It doesn't catch
`'team.users.invite'` typed inline in a widget. We have at least seven
widget files doing that, including five in operator_web that redefine
the same constants from scratch. If we ever rename a permission key,
the lint passes, the catalog updates, and the widgets silently keep
checking the old name.

### What this means for V1

The "where are we, really?" answer is: the spine is built and most of
the slices are honest about what they shipped. But the **last 5%** of
every shipped slice — the part where you actually point production at
the new code — is missing in a lot of places that the trackers say
are done.

Practical recommendation: before V1 declaration, run a single "finish
the wiring" sweep that does the five things in the previous section.
After those five sweeps, the seven launch-blocking items collapse to
maybe two (the 7shifts vendor-id drift and the webhook-signature-vs-OAuth-
token confusion both need targeted fixes).

The rest of the findings are operational debt that wouldn't stop V1
but would burn time on the first incident.

---

## Status & maintenance

**Status:** open. Items get marked `(closed: <commit-sha>)` inline as
each finding is fixed, then moved to a closeout section at the bottom
of this file once a sweep completes.

**Update cadence:** re-audit at every cutover gate transition (same
shape as the V1 launch punchlist), and at every "finish the wiring"
sweep close.

**Cross-references:**
- `CODE_HEALTH.md` — original audit + closeout + addendum.
- `docs/_execution/2026-05-05_v1_launch_punchlist.md` — what's left
  for V1 launch (operational items only).
- `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items from the
  2026-05-02 deep audit.
- `PROJECT_TRACKER.md` — routing.
- `CLAUDE.md` — Hard Promises (this audit found violations of #2 and
  #4).
