# Code Ops Debt — Resolved 2026-05-07

Archived from `CODE_OPS_DEBT.md` on 2026-05-07 when the live doc was
trimmed to "open-only".

**Outcome:** 13-lane parallel fix sweep dispatched 2026-05-07.
12 PRs merged + 1 PR closed redundantly (work shipped to master via
parallel slice). ~40 of 50 audit findings resolved, all 7 P0
launch-blockers cleared.

## Lane scoreboard

| Lane | Themes | PR | Outcome |
|---|---|---|---|
| M1 — BYPASSRLS predicates | E (3×) | [#304](https://github.com/SaidKhan005/forge-flow-demo/pull/304) | merged |
| M2 — actor_kind audit sweep | F#4 | [#336](https://github.com/SaidKhan005/forge-flow-demo/pull/336) | merged |
| M3 — Permission keys catalog sweep | F#1-2 | [#337](https://github.com/SaidKhan005/forge-flow-demo/pull/337) | merged |
| M4 — 7shifts vendor-id alignment | G#1 | [#306](https://github.com/SaidKhan005/forge-flow-demo/pull/306) | merged |
| M5 — Worker startup wiring | C (6 findings) | [#338](https://github.com/SaidKhan005/forge-flow-demo/pull/338) | merged |
| M6 — Demo-fallback hardening | I#3-4 | [#339](https://github.com/SaidKhan005/forge-flow-demo/pull/339) | closed-redundant (parallel master slice shipped equivalent work) |
| M7 — Mobile sync server-truth coverage | H#3-7,9 (6 findings) | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) | merged |
| M8 — Cutover preflight smokes | J#1-2 | [#341](https://github.com/SaidKhan005/forge-flow-demo/pull/341) | merged |
| M9 — ForgeFlow flavor star/target wiring | H#1 | [#303](https://github.com/SaidKhan005/forge-flow-demo/pull/303) | merged |
| M10 — Vendor capability polish | G#3-7 (5 findings) | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) | merged |
| M11 — Mobile push gating | H#2 | [#305](https://github.com/SaidKhan005/forge-flow-demo/pull/305) | merged |
| M12 — Webhook signing secret | G#2 | [#343](https://github.com/SaidKhan005/forge-flow-demo/pull/343) | merged |
| M13 — Theme B mechanical proxy routes | B#2-4 (4 findings) | [#344](https://github.com/SaidKhan005/forge-flow-demo/pull/344) | merged |

## Closed findings — by theme

### Theme B — Server routes (3 of 5 mechanical fixes closed)

| Finding | PR | Resolution |
|---|---|---|
| 11A.14 ships permission key `admin.users.reset_mfa_factors`; proxy gates on legacy `team.users.reset_mfa` | [#344](https://github.com/SaidKhan005/forge-flow-demo/pull/344) (`f1fe578`) | admin path now gates on `PermissionKeys.adminUsersResetMfaFactors`; team path retains `teamUsersResetMfa` |
| 11W.4 Sessions team-listing throws `team_sessions_not_routed` 501 | [#344](https://github.com/SaidKhan005/forge-flow-demo/pull/344) (`f1fe578`) | `GET /v1/auth/team/sessions` shipped, gated on `team.session.force_logout` |
| 11W.7 ships PATCH for account/timing but no GET | [#344](https://github.com/SaidKhan005/forge-flow-demo/pull/344) (`f1fe578`) | `GET /v1/operator/account` + `GET /v1/operator/business-timing-profiles` shipped under existing OperatorWriteRouter RLS |

### Theme C — NOTIFY producers without LISTEN consumers (all 6 closed)

PR [#338](https://github.com/SaidKhan005/forge-flow-demo/pull/338) (`024de04`).
SIGTERM drains all consumers cleanly before HTTP listener close.
Audit-anchor flipped from fail-OPEN to fail-loud.

| Channel | Resolution |
|---|---|
| `audit_anchor_tick` (daily 02:00 UTC) | LISTEN wired, runtime built once at startup, single-flight guard, fail-loud env-flag gate |
| `rollups_tick` (60s + 5min) | `RollupWorker.claimBatch` fanned across 7 `RollupGrain`s |
| `forge_email_outbox_tick` (per-minute) | `EmailOutboxDispatcher.drainBatch()` wired through new `PostgresEmailOutboxRepository` |
| `mobile_push_outbox` | discovers (operator, location) via admin pool; claims + dispatches via tenant pool |
| `OutboxTripwirePoller` | proxy-internal poller against `realtimeTripwireGateway` |
| `pg_partman` daily partition maintenance | new migration `202605081100_partman_maintenance_hourly_cron.sql` registers hourly schedule (Azure split-DB safe) |

### Theme E — BYPASSRLS UPDATEs missing `operator_id` predicate (all 3 closed)

PR [#304](https://github.com/SaidKhan005/forge-flow-demo/pull/304) (`251c008`).
Same shape as the already-closed C5 finding from CODE_HEALTH.

| Finding | Resolution |
|---|---|
| `revokeAllSessionsForUserAsAdmin` filters only by `user_id` inside `withSystem` | EXISTS subquery via `users.operator_id` (auth_sessions has no own `operator_id` column) |
| `clearForUser` (GDPR helper) deletes by `user_id` only inside `withSystem` | EXISTS subquery — same shape |
| `acceptInvite` / `revokeInvite` UPDATE only on `invite_id` | literal `operator_id` predicate (auth_invites carries the column directly) |

### Theme F — Permission catalog hand-typed (all 3 closed)

| Finding | PR | Resolution |
|---|---|---|
| Hand-typed strings `'team.users.invite'` etc. in `team_settings_section.dart`, `settings_screen.dart` | [#337](https://github.com/SaidKhan005/forge-flow-demo/pull/337) (`36ceae0`) | settings_screen routed through `PermissionKeys.*`; team_settings_section.dart was deleted by parallel PR #324 (W3.A dead-code drop) |
| 5 operator_web screens redefine `kHierarchyViewPermissionKey` etc. inline | [#337](https://github.com/SaidKhan005/forge-flow-demo/pull/337) (`36ceae0`) | All 5 operator_web screens routed through `PermissionKeys.*`; `permission_key_lint.dart` extended with raw-literal pass + escape hatch |
| `actorKind` defaults to `'user'` even for service principals | [#336](https://github.com/SaidKhan005/forge-flow-demo/pull/336) (`7f0930a`) | `actorKind` now required; 5 user-path call sites pass `'user'` explicitly; MFA removal worker classified `'system'` |

### Theme G — Vendor identifier / capability inconsistencies (all 7 closed)

| Finding | PR | Resolution |
|---|---|---|
| 7shifts vendor-id drift (`'7shifts'` vs `'seven_shifts'`) | [#306](https://github.com/SaidKhan005/forge-flow-demo/pull/306) (`a052c34`) | `'seven_shifts'` is single source of truth; display strings preserved as `'7shifts'`; no backfill migration needed |
| `lookupSigningSecret` reads OAuth token instead of HMAC secret | [#343](https://github.com/SaidKhan005/forge-flow-demo/pull/343) (`2db70d7`) | new migration `202605080600_…` adds `webhook_signing_secret_ciphertext`; `lookupSigningSecret` reads new column with fail-closed posture; `rotateWebhookSigningSecret` write path; runbook documents per-vendor provisioning |
| Humanity authMode mismatch | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) (`797f957`) | flipped BINDER per Humanity v1 docs (genuinely keyPaste); adapter unchanged; binder now registers Humanity unconditionally |
| Oracle MICROS Simphony unreachable webhook verifier | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) (`797f957`) | flipped BINDER per Oracle docs (genuinely poll-only); removed unreachable verifier file + companion test |
| Aloha sink stale comment | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) (`797f957`) | comment now matches reality |
| Banned `'seated_at'` Dart literal in projector | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) (`797f957`) | replaced with `_kSeatedAtCanonicalKey` constant; banned-grep test added mirroring per-sink pattern |
| SevenRooms partnership_status missing field | [#342](https://github.com/SaidKhan005/forge-flow-demo/pull/342) (`797f957`) | `Application status:` field added |

### Theme H — Mobile↔server-truth contract violations (8 of 9 closed)

| Finding | PR | Resolution |
|---|---|---|
| ForgeFlow flavor missing `starTargetSelectionWriteClient` | [#303](https://github.com/SaidKhan005/forge-flow-demo/pull/303) (`0d5dce4`) | wired in production bootstrap |
| Mobile push migration not staging-applied but client unconditionally calls proxy | [#305](https://github.com/SaidKhan005/forge-flow-demo/pull/305) (`70c8af7`) | gated behind `MOBILE_PUSH_NOTIFICATIONS_ENABLED` (default `false`); flips post-migration per runbook |
| Empty server table returns 200 (cannot distinguish "feature not yet projected" from "operator has zero stars") | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | both routes return `available:false / status:unavailable / reason:no_projected_rows` for empty server tables |
| Wage-role 8 dropped server columns | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | all 9 dropped columns now consumed (server_id, job_code, vendor_id, vendor_role_id, source, is_active, effective_at, metadata, updated_by) |
| `wage_role_rows` SQLite missing `server_id` | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | V31 migration adds `server_id TEXT NULL` + UNIQUE `(restaurant_id, server_id) WHERE server_id IS NOT NULL` |
| Weekly plan 5 missing provenance fields | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | V33 migration + 5 fields consumed in mobile `_snapshotPayload` |
| DAS service-period settings volatile only | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | V32 migration adds cache table; persisted on each pull; rehydrated on app start |
| Realtime invalidation list missing `restaurant_users` | [#340](https://github.com/SaidKhan005/forge-flow-demo/pull/340) (`1098bd5`) | `isBusinessScopeInvalidationEvent` now triggers on `restaurant_users` insert/update/delete |

### Theme I — Demo-mode reader-side leaks (2 of 4 closed via parallel slice)

| Finding | Resolution |
|---|---|
| 11 admin gateway accessors silently fall back to `_default*DemoGateway` | parallel master slice shipped equivalent work; M6 PR #339 closed as redundant. Each gateway resolver in `lib/main_admin.dart` now hard-fails when `ADMIN_PROXY_BASE_URI` is missing AND `ADMIN_DEMO_AUTH=false` |
| 4 production paths still import `lib/dev/demo_fixture_data.dart` | parallel master slice shipped equivalent work. All 4 imports rerouted to `lib/services/baseline_authority_service.dart` (Layer 3) |

### Theme J — Cutover & acceptance harness theater (2 of 5 closed)

| Finding | PR | Resolution |
|---|---|---|
| Cutover.0 preflight only runs 2 of 6 documented smokes | [#341](https://github.com/SaidKhan005/forge-flow-demo/pull/341) (`c21dc04`) | 4 missing smokes added with full test coverage (AGE Cypher MATCH, pgvector cosine, /health 200, pg_partman+pg_cron active) |
| `_defaultSecretRead` is a stub that throws `StateError` | [#341](https://github.com/SaidKhan005/forge-flow-demo/pull/341) (`c21dc04`) | `_GcpSecretManagerSecretReadProbe` wired via existing `MetadataServerAccessTokenProvider` (ADC) + `package:http`; never throws, fails red on missing/empty secret |

## Launch-blocking shortlist — final state

All seven launch-blockers identified by the audit have been resolved
or have a clear closure path:

| # | Finding | Status |
|---|---|---|
| 1 | 7shifts vendor-id drift | ✅ closed — PR #306 |
| 2 | Webhook signature verifier reads OAuth token instead of HMAC secret | ✅ closed — PR #343 |
| 3 | 3 BYPASSRLS UPDATEs missing operator_id | ✅ closed — PR #304 |
| 4 | ForgeFlow flavor missing star/target server-write client | ✅ closed — PR #303 |
| 5 | Mobile push migration not staging-applied but client unconditionally calls proxy | ✅ closed — PR #305 |
| 6 | Cutover preflight missing 4/6 smokes + secret check stub | ✅ closed — PR #341 |
| 7 | 11A.14 paired-approval erasure has no proxy route + reset-MFA-factors gates on legacy key | ✅ closed — gate-key alignment via PR #344; single-admin PII erasure route via PR #377 (operator chose single-admin + grace-window reverse instead of paired approval) |

---

## Evening sweep — operator-decision closures (2026-05-07 → 2026-05-08)

After the morning audit-batch sweep, the operator gave decisions on the
9 outstanding items. Eight lanes dispatched in parallel. All 8 with PRs
merged; item 9 (Theme H#8) is owned by the Phase 8 framework finishing
push.

| Item | Theme | Decision | PR |
|---|---|---|---|
| 1 | A — session-claim resolver | 1hr MFA freshness; redirect-to-login + redo MFA on stale | [#384](https://github.com/SaidKhan005/forge-flow-demo/pull/384) — `JwtFreshMfaResolver` reads Firebase `auth_time` claim; 4 admin actions un-pinned |
| 2 | B#1 — paired-approval erasure | Single-admin (uses item 1's resolver); reversible during grace; PII-only | [#377](https://github.com/SaidKhan005/forge-flow-demo/pull/377) — 3 routes + grace-expiry worker + 24h reverse window |
| 3 | B#5 — server-side audit-log CSV | Server-side streamed; respect same UX filters; verify time filter end-to-end | [#378](https://github.com/SaidKhan005/forge-flow-demo/pull/378) — `GET /v1/auth/audit-log/export.csv`; time filter already present at every layer; replaces 100k-row client-side renderer |
| 4 | I#1-2 — kDemoMode reader-side branches | Keep the demo switch; verify writer-side end-to-end on mobile; document carve-outs | [#379](https://github.com/SaidKhan005/forge-flow-demo/pull/379) — zero drift found; 2 carve-outs documented; flow diagram in `docs/contracts/demo_mode_contract.md`; regression test asserts demo writes to same SQLite tables as prod |
| 5 | D — Pub/Sub realtime cross-pod replay | Approve all; simplicity + functionality first; cost-aware | [#380](https://github.com/SaidKhan005/forge-flow-demo/pull/380) — default-disabled; 5-min retention; per-pod subscription with TTL=1h auto-cleanup; <\$1/pod/month when enabled, \$0 when disabled; Azure split-DB cron migration |
| 6 | J#3 — Browser Use harness | Codex automation, not in-repo binary | [#368](https://github.com/SaidKhan005/forge-flow-demo/pull/368) — runbook renamed + rewritten; 7 cross-refs updated |
| 7 | J#4 — slice-acceptance contract | Relax — CI's are expensive | [#381](https://github.com/SaidKhan005/forge-flow-demo/pull/381) — contract softened to advisory pattern; CLAUDE.md/PROJECT_TRACKER.md/CODEX_PROMPT_GENERATION_STANDARD.md updated |
| 8 | J#5 — graphify candidates | Backlog under AI freeze | [#369](https://github.com/SaidKhan005/forge-flow-demo/pull/369) — 503 message rewritten to surface paused-by-design; tracker entry under AI-paused set |
| 9 | H#8 — first-backfill status null | Self-closes via Phase 8 framework finishing push | n/a — naturally resolves when that push touches the route shape |

**~50 of 50 audit findings closed across both sweeps.**
