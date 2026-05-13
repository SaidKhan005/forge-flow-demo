# Post-Codex Wave Completion Deep Audit — 2026-05-13

**Auditor:** Orchestrator (this Claude session) — deep retrospective on 21 merged slices.
**Master tip at audit:** `b688abc9` (`origin/master`, merge of PR #549).
**Scope:** A0, A2.1, A2.2, A3.1, A4.1, A5+A8, A6.1, A7.1, A9.1, A10.1, A11.1, A11.2,
B1.a, B1.b, B3, B4, B7.a, B9.1, B9.2, B11.1, C-8.
**Method:** for each slice — re-read original audit doc, re-verify spec → diff alignment,
spot-check file:line claims on current master, run additional probes the original audit
might have missed (RLS posture, indexes, demo carve-outs, idempotency stores, follow-up
tracking).

## Summary

- Slices reviewed: **21**
- Blocking bugs (P0): **0**
- Material gaps (P1): **5**
- Doc drift (P2): **4**
- Nits / cleanups (P3): **2**
- Re-verified clean: **15** (A2.1, A2.2, A3.1, A4.1, A5+A8, A6.1, A7.1, A9.1, A10.1,
  A11.2, B1.a, B3, B4, B7.a, B9.1)

## Per-slice findings

### A0 — B1+B2 Verification probe (orchestrator-owned; no PR)

**Status:** Clean — probe accurately confirms `runZonedGuarded` (`tool/advisor_proxy/main.dart:95`),
scope-less branch (`tool/advisor_proxy/advisor_proxy.dart:2179, :2189, :2206, :2258`),
and contract tests pass.

- **P3 — A0-1 (doc drift)**: `docs/_audits/code_health/a0_b1_b2_post_merge_verification.md:74`
  references `test/load/pressure/` for the soak harness output dir. A10.1 (PR #523) renamed
  that path to `test/pressure/`; the A0 doc was authored before the rename so the reference
  is stale-but-historical. **Suggested action:** add a footnote "*as of A0 authoring; post-A10.1
  the harness writes to `test/pressure/`*" or leave alone (it's an immutable historical record).

### A2.1 — Scaffold inventory + dead-code sweep (PR #519)

**Status:** Clean — re-verified against master `b688abc9`.

- `lib/admin/widgets/deferred_admin_screen_placeholder.dart` — deleted, 0 callers anywhere.
- `lib/operator_web/widgets/deferred_screen_placeholder.dart` — deleted, 0 callers anywhere.
- Inventory at `docs/_audits/code_health/a2_scaffold_inventory.md` updated.

### A2.2 — Email pipeline wire-or-delete (PR #540)

**Status:** Clean — re-verified against master.

- `tool/advisor_proxy/email_templates/operator_admin_invite.md` and
  `password_reset_request.md` confirmed deleted.
- `lib/services/email/email_template_renderer.dart` registry shrunk to 10 entries.
- Test at `test/services/email/email_template_renderer_test.dart:270-273` pins the
  deleted IDs as absent.
- Remaining grep hits for `operator_admin_invite` / `password_reset_request` strings in
  production code are all unrelated: audit event types (`auth.password_reset_requested`),
  gateway file names, widget keys. Live flows wire through Firebase action-link email
  per `lib/services/auth/proxy_password_reset_gateway.dart`.

### A3.1 — Monolith seam-map + bleed-stop lint (PR #533)

**Status:** Clean — re-verified against master.

- `tool/advisor_proxy/advisor_proxy.dart` line count: **18,871**.
- Ceiling in `tool/advisor_proxy_size_lint.dart:72`: `kAdvisorProxyMaxLines = 19071`.
- Headroom: **200** (as designed).
- Seam map doc at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` cross-references
  the decomp plan; cluster boundaries spot-check correctly.

### A4.1 — Performance audit pass (PR #517)

**Status:** Clean for a doc-only audit. Minor citation drift acknowledged.

- `kPostgresDefaultMaxConnectionsPerPool = 4` still at
  `lib/infrastructure/persistence/postgres/postgres_executor.dart:55` (A4.2 will bump to 20).
- `healthProducerConcurrency` reference moved from `:1646` (audit) → `:1686` (post-merge
  on PR #517) → `:1704` (current master) due to surrounding code drift. Symbol intact;
  no code change required, only audit-doc line numbers drift.

### A5+A8 — Schema versioning + audit_logs UPDATE lint (PR #527)

**Status:** Clean — re-verified against master.

- `db/migrations/post_deploy/` directory exists with `README.md` (convention doc).
- `tool/audit_logs_update_lint.dart` (273 LoC) live; regex correctly handles
  `[only]`, `[public.]`, `[quoted "audit_logs"]` variants.
- `tool/audit_logs_update_allowlist.txt` has the single grandfathered entry
  `db/migrations/202605131010_admin_audit_logs_business_date.sql`.
- `tool/migration_drift_scanner.dart` has `--require-expand-contract` flag +
  `defaultExpandContractGrandfatherCutoff = '202605131030_b11_1_auth_handoff_codes.sql'`.

### A6.1 — Proxy health UI honesty pass (PR #498)

**Status:** Clean — re-verified against master.

- `_metricDisplayValue` returns `'No value yet'` for null/blank at
  `lib/admin/screens/health_admin_screen.dart:1197-1202`.
- `_metricRemediation` exhausts severities + producer warnings at `:1222-1263`.

### A7.1 — Frameworks cross-reference sweep (PR #526)

**Status:** Clean — re-verified against master.

- 5 framework files live at `docs/frameworks/*.md`; zero at `docs/<NAME>FRAMEWORK.md`.
- Remaining `docs/PERFORMANCE_FRAMEWORK.md` style references are all in audit/planning/
  archive context (intentional historical records).

### A9.1 — lib/data rehome (PR #530)

**Status:** Clean — re-verified against master.

- `lib/data/` does not exist on master (delete-only doctrine fully honored).
- `lib/dev/mock_integration_replay_seed.dart` present (3 files in `lib/dev/`).
- `lib/domain/constants/app_defaults.dart` and `cross_axis_pair_catalog.dart` present.
- `package:forge_and_flow/data/` or `../data/` imports: **zero** matches in `lib/` and `test/`.

### A10.1 — Test consolidation (PR #523)

**Status:** Clean — re-verified against master.

- `test/load/pressure/` does not exist; all files moved to `test/pressure/`.
- Pressure tools (`tool/pressure/p3*.dart`, `p4*.dart`) consistently write to
  `test/pressure/` output dir.
- Stale `test/load/pressure/` references on master are only in:
  - `test/pressure/README.md:6` — explicit historical reference, intentional.
  - `docs/_audits/code_health/a0_b1_b2_post_merge_verification.md:74` — historical record.
  - `docs/_audits/code_health/a11_soak_harness_durable_kit.md` — historical record per
    A10.1 followup analysis.
  - `docs/_execution/lane_a_code_health/0{1,2,3}_*.md` and `docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md`
    — planning docs that pre-date the rename. **P3 doc-drift; not surfaced to runtime.**

### A11.1 — Production session-record gauge (PR #522)

**Status:** Material gap — gauge counters live in-memory but never read/emitted externally.

- `SessionRecordIncompleteGauge` class at `tool/advisor_proxy/advisor_proxy.dart:6969`.
- Single emission site (only one `observe` call): `advisor_proxy.dart:13188` for
  `POST /v1/auth/session/login`.
- `snapshot()` and `totalIncrements()` methods exist (`advisor_proxy.dart:7024, :7033`)
  but are **not called by any production code path on master** (grep returns only the
  class definition + the gauge_test.dart file using them in unit tests).

- **P1 — A11.1-1 (dead observability path)**: The gauge accumulates per-`(route,
  missing_field)` counts in a `Map<String, Map<String, int>>` but no consumer reads it.
  Comments in `tool/advisor_proxy/advisor_proxy.dart:6949`, `:8580`,
  `tool/advisor_proxy/proxy_bootstrap.dart:456, :1170`, and `tool/advisor_proxy/main.dart:1677`
  all describe the gauge as "emits `proxy.session_record.incomplete{route, missing_field}`"
  but that metric is never produced — no `/health` producer reads `snapshot()`, no
  log-emit reads `totalIncrements()`, no OpenTelemetry/Prometheus sink exists. Slice spec
  (`docs/_execution/lane_a_code_health/03_execution_slices.md` Slice A11.1) said "wire the
  R3 §2 stretch goal — proxy emits …". Wiring landed; emission did not. Furthermore the
  gauge is **per-process**, so even if a reader existed, multi-instance Cloud Run autoscaling
  would produce N disjoint counter sets. **Authority anchor:** Metric Honesty Doctrine
  (`memory/project_metric_honesty_doctrine.md`) — every metric carries `state` + `provenance`.
  **Suggested action:** open a follow-up to (a) add a `/health` producer that exposes the
  gauge snapshot, or (b) log the snapshot on a timer, or (c) downgrade the comments to
  describe the gauge accurately as "in-memory observability buffer" and document the
  followup in `POST_HARDENING_FOLLOWUPS.md`.

### A11.2 — Soak harness durable extensions (PR #537)

**Status:** Clean — re-verified against master.

- `tool/pressure/p4_fd_watcher.dart` (189 LoC), `p4_heap_snapshot_uploader.dart` (398 LoC)
  present.
- `HeapSnapshotUploadTarget` is properly storage-agnostic; `GcsHeapSnapshotUploadTarget`
  is one impl behind the interface.
- Inert by default — uploader logs one `"skipped"` line and stays idle when
  `GCS_BUCKET_HEAP_SNAPSHOTS` / `GCS_BEARER_TOKEN` unset (verified at lines 157-166, 267-272).
- Follow-up to swap GCS → Azure Blob is locked in `docs/POST_HARDENING_FOLLOWUPS.md`
  P1 section (lines 84-124, with binding-constraint that env vars must stay unset).

### B1.a — Inheritance notice propagation (PR #501 + follow-up)

**Status:** Clean — re-verified against master.

- `_singleCoveredLocationName` getter present at
  `lib/admin/screens/per_location_data_accuracy_screen.dart:355` and
  `lib/admin/screens/polling_and_pricing_admin_screen.dart:318`.
- Copy rewrite (Option 1 follow-up): "This scope only covers $location. Adjusting … is
  equivalent to a per-location change — there are no other locations under this scope to
  inherit from." at `per_location_data_accuracy_screen.dart:502` and
  `polling_and_pricing_admin_screen.dart:669`.

### B1.b — Admin audit actor fix (PR #500)

**Status:** Material gap — fix only applied to one of five admin gateways carrying the same bug.

- `OperatorOnboardingAdminProxyGateway._audit` at
  `tool/advisor_proxy/proxy_bootstrap.dart:3685-3719` writes `actorKind: 'forge_admin'` (✓ fixed).
- Tests at `test/advisor_proxy_bootstrap_test.dart:372, :396` pin `patchOperator` +
  `addLocation` only.

- **P1 — B1.b-1 (peer-bug not closed)** — **RESOLVED 2026-05-13 by B1.c
  (peer-bug sweep flips all four `_audit` helpers to `actorKind:
  'forge_admin'` + adds 4 audit-chain integrity test cases at
  `test/advisor_proxy_bootstrap_test.dart`).**

  Four other admin gateways in the same file have
  identical pattern — `_audit` helper with comment "*Admin path: actor is a verified F&F
  admin JWT*" but body writes `actorKind: 'user'`. The PR #500 audit doc explicitly
  flagged the first one (4015) as "*peer bug B1.c candidate*" with "*Recommend either
  (a) widen B1.b scope post-merge … OR (b) open a B1.c peer-fix slice*". Neither action
  taken — no B1.c row in the ledger, no follow-up in `POST_HARDENING_FOLLOWUPS.md`.
  **Affected sites on master `b688abc9`:**
  - `tool/advisor_proxy/proxy_bootstrap.dart:4083` — `PricingTierAdminProxyGateway._audit`
    (events `admin.pricing.cap_upserted`, `admin.pricing.template_applied`).
  - `tool/advisor_proxy/proxy_bootstrap.dart:5638` — corpus admin `_audit` (event
    `admin.corpus.rollback`).
  - `tool/advisor_proxy/proxy_bootstrap.dart:6287` — graph candidates admin `_audit`.
  - `tool/advisor_proxy/proxy_bootstrap.dart:6745` — feature flags admin `_audit`.
  Every comment explicitly states "actor is a verified F&F admin JWT" but the code records
  `actor_kind = 'user'`, breaking actor-kind honesty in audit_logs / auth_events_audit for
  pricing, corpus, graph, and feature-flag admin writes. **Authority anchor:** CLAUDE.md
  "Proxy & API Conventions" — "service principals: non-human actors authenticate with
  `sp:`-prefixed JWTs; `audit_logs.actor_kind` never NULL". F&F admin acting cross-operator
  must be `forge_admin`. **Suggested action:** open `B1.c` slice that flips these four
  `actorKind: 'user'` to `actorKind: 'forge_admin'` + extends the
  `test/advisor_proxy_bootstrap_test.dart` regression tests to cover all four gateways.

### B3 — Role-key hybrid identifier sweep (PR #502)

**Status:** Clean — re-verified against master.

- Proxy explicitly rejects `role_key` with `'role_id_required'` 400 at
  `tool/advisor_proxy/advisor_proxy.dart:11858-11865` (improved over the audit-doc
  description of "passive disuse" — actual code is active rejection).
- `missing_role_grant_fields` at `:11868` requires `user_id`, `role_id`, `scope_type`.
- `TeamRoleGrantCreateCommand` carries `roleId: roleId` (`:11885`).

### B4 — Two-product taxonomy in role editor (PR #513)

**Status:** Clean — re-verified against master.

- `_rolePermissionProduct` at
  `lib/services/auth/repository_auth_operations_gateway.dart:1920-1926` and mirror in
  `lib/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart:138`.
- Classification: `'product.barrio.access'` OR `barrio.*` prefix → `'barrio'`, else
  `'forgeflow'`.
- Frozen `lib/auth/permission_keys.dart` untouched (no new keys added).
- Demo gateway mirrors live gateway (HP #2 single-writer rule preserved).

### B7.a — Invite hierarchy-scope fix (PR #507 + follow-up)

**Status:** Clean — re-verified against master.

- `'invite.cancel'` emitted at
  `lib/services/auth/repository_auth_operations_gateway.dart:550`, guarded by `affected > 0`.
- Display-label switches at `lib/operator_web/services/web_team_audit_log_gateway.dart:257-260`
  and `lib/services/auth/auth_operations_gateway.dart:1102-1105` map BOTH historic
  `'auth.invite_revoked'` and new `'invite.cancel'` to `'Invite cancelled'`.
- Mobile screen copy at `lib/operator_web/screens/members_screen.dart:518` shows the
  matching snackbar text.

### B9.1 — Sign-in-security 301 redirect (PR #510)

**Status:** Clean — re-verified against master.

- `Dockerfile.operator_web:123-125` and `Dockerfile.admin_console:113-115` both contain
  `location = /...sign-in-security { return 301 "/my-account$is_args$args#security"; }`.
- nginx `location =` is exact-match only by design; sub-paths under `/sign-in-security/`
  fall through to the SPA. Per slice spec this is correct (only the exact landing URL
  redirects).

### B9.2 — My Account consolidation + Active Sessions (PR #547)

**Status:** Material gaps in client-side freshness gate logic.

The B9.2 changes live on `origin/master` (`lib/operator_web/services/web_account_gateway.dart`
at master is 419 lines, with the `WebAccountSessionGateway` abstract class,
`signOutOtherSessions` implementation, and `_requireFreshMfaToken` gate; worktree HEAD
predates the merge but the slice is on master). All references below cite `b688abc9`.

- **P1 — B9.2-1 (clock-skew false-positive on freshness gate)**: `_requireFreshMfaToken`
  in `lib/operator_web/services/web_account_gateway.dart:184-191` rejects on
  `authTime.isAfter(now)`, with zero tolerance window. If the client's clock is even
  seconds **behind** the server clock that minted the token, `auth_time` will be in the
  client's "future" and the gate fires `AccountSessionFreshMfaRequiredException`. A user
  on a machine with a clock running 30 seconds slow cannot sign out other sessions.
  **Authority anchor:** Time Guardrails in CLAUDE.md (timing is restaurant-local; UTC for
  fact tables) doesn't directly cover client clock skew, but RFC 8628/9470 clients
  conventionally tolerate ≥30s clock skew. **Suggested action:** add a `Duration(seconds: 60)`
  tolerance to the `authTime.isAfter(now)` predicate, or drop that branch entirely
  (a token whose `auth_time` is in the future is still a real freshly-authenticated token).

- **P1 — B9.2-2 (defense-in-depth-only freshness; server bypass)**: The gate is purely
  client-side. The server route `/v1/auth/session/revoke` has no RFC 9470 step-up
  enforcement; a malicious or buggy client can bypass `_requireFreshMfaToken` and revoke
  with a stale token. B11.2 is on the ledger as `assigned` to address this; until B11.2
  lands, the audit log is the only forensic trail. **Authority anchor:** CLAUDE.md
  "Agent-Led Slices" — auth-critical slices require operator sign-off; the operator
  approved B9.2 conditional on B11.2 being planned. **Suggested action:** ensure B11.2
  is scheduled before any soft-launch of Active Sessions revoke; document the bypass risk
  as a known limitation in the operator-facing release notes.

- **P3 — B9.2-3 (freshness window inconsistency)**: `_freshMfaWindow = Duration(hours: 1)`
  at `web_account_gateway.dart` while `lib/auth/auth_session.dart:71-74` documents a
  5-minute window for the "Phase 9 decision lock" and `lib/auth/fresh_mfa_resolver.dart:17`
  notes "decision: 1 hour, not 5 minutes." Three windows on three timescales. Not a bug
  (sign-out-others is less critical than account edits), but the catalog of freshness
  windows is currently undocumented and risks future inconsistency. **Suggested action:**
  add a one-paragraph table to `docs/contracts/` or `lib/auth/` README listing the three
  windows and what each protects.

### B11.1 — handoff_codes table + endpoints (PR #512)

**Status:** Material gaps in idempotency store and grant scope.

The migration at `db/migrations/202605131030_b11_1_auth_handoff_codes.sql` and the routes
at `tool/advisor_proxy/auth_handoff_routes.dart` (~856 LoC) are well-implemented overall:
- RLS wrapper `app_current_operator()` used (migration line 195-199).
- Server-side `gen_random_bytes(16)` for opaque codes.
- Code-shape CHECK at migration line 105-108 (22-64 char base64-url).
- Atomic UPDATE…RETURNING with predicate in `handoff_codes_repository.dart`.
- 410/403 classification with constant-time existence-not-leaking handling
  (`auth_handoff_routes.dart:609-627`).
- target_path open-redirect defense at `:641-685` (rejects absolute URLs, `//evil/path`).
- Reaper at mint head with 1-day horizon (`handoff_codes_repository.dart:148-160`).

- **P1 — B11.1-1 (in-memory idempotency store vs proxy convention)**: CLAUDE.md "Proxy
  & API Conventions" mandates "*Every proxy write is idempotent. Clients carry an
  idempotency key; **proxy stores keys in `proxy_requests` (UNIQUE)***." `HandoffMintIdempotencyCache`
  at `tool/advisor_proxy/auth_handoff_routes.dart:287-347` uses an in-process
  `Map<String, _CacheEntry>` with `maxEntries: 5000` and `ttl: Duration(hours: 1)`.
  On Cloud Run autoscaling with N proxy instances, an idempotent-retry that lands on a
  different instance bypasses the cache and double-mints. **Exposure is small in practice**
  because handoff codes have 60-second TTL and each is single-use; the worst case is two
  valid handoff codes for the same (operator, user, idempotency-key) where only one gets
  redeemed and the other reaps within 60s + 1d. Functionally low-impact, but architecturally
  divergent from the proxy convention. **Authority anchor:** CLAUDE.md "Proxy & API
  Conventions". **Suggested action:** either (a) migrate `HandoffMintIdempotencyCache` to
  the existing `proxy_requests` Postgres-backed UNIQUE store, or (b) document in
  `docs/POST_HARDENING_FOLLOWUPS.md` why the in-memory path is acceptable for this
  60-second-TTL route specifically.

- **P2 — B11.1-2 (forge_admin DELETE grant inconsistent with comment)**: Migration line
  237-244 reads `grant select, delete on public.handoff_codes to forge_admin;` but the
  comment block at `:236-239` says "*forge_admin gets read for ops visibility*". DELETE
  is not "read". DELETE may be intentional (allowing admin to nuke a hung handoff row
  from a forge-admin debug console) but the comment doesn't justify it — privilege bloat
  surfaced by inconsistency. **Authority anchor:** CLAUDE.md "Proxy & API Conventions"
  least-privilege philosophy. **Suggested action:** either drop `delete` from the grant
  to match the comment, or update the comment to explain why DELETE is needed.

### C-8 — Notification preferences catalog completeness (PR #499)

**Status:** Material gap on default-state honesty.

- All 7 catalog entries enumerated in `_kEventState` at
  `lib/operator_web/screens/settings_notifications_screen.dart:88-95`.
- State assignments: 3 `available`, 3 `comingSoon`, 1 `backendOnly`.
- Defense-in-depth at `:237`: `if (_stateFor(event) != _NotifEventState.available) return;`.

- **P2 — C-8-1 (fallback default violates honesty doctrine)**: `_stateFor` at
  `settings_notifications_screen.dart:102-103` defaults to `_NotifEventState.available`
  when an event is missing from `_kEventState`. A newly added catalog entry without a
  matching matrix update will render as a working toggle while no emitter exists, producing
  zero notifications silently. **Authority anchor:** Metric Honesty Doctrine — every
  metric carries `state` + `provenance`; the analog here is that a preference row should
  declare its readiness explicitly. **Suggested action:** flip the default to
  `_NotifEventState.comingSoon` so new entries fail visibly until an explicit assignment;
  alternatively, raise a `StateError` in dev/test builds when the matrix is incomplete.

## Cross-cutting findings

### CC-1 — Five admin-gateway `_audit` helpers share the B1.b bug pattern

P1, surfaced under B1.b above. Pricing, corpus, graph-candidates, and feature-flags admin
gateways all write `actorKind: 'user'` despite carrying admin-JWT comments. PR #500 audit
doc flagged one (4015→4083) and recommended either widening or opening `B1.c`. Neither
happened; ledger row for `B1.c` does not exist, `POST_HARDENING_FOLLOWUPS.md` has no
entry. Hash-chained audit_logs rows for these four routes lose actor-kind honesty until
fixed.

### CC-2 — Three undocumented client-side freshness windows

P3, surfaced under B9.2 above. `web_account_gateway.dart` 1 hour vs `auth_session.dart`
5 minutes vs `fresh_mfa_resolver.dart`'s declared 1-hour-vs-5-minute decision conflict.
No single contract doc lists them. Risk that future slices pick yet another value.

### CC-3 — A11.1 observability gauge has no consumer

P1, surfaced under A11.1 above. The slice promised emission of
`proxy.session_record.incomplete{route, missing_field}`; only the buffer was wired.
Followup neither tracked nor downgraded in slice/audit/PR commentary.

### CC-4 — A10.1 doc-drift residue spans 5+ historical/planning docs

P3, acceptable historical drift. `test/load/pressure/` still appears in
`a0_b1_b2_post_merge_verification.md`, `a11_soak_harness_durable_kit.md`,
`lane_a_code_health/0{1,2,3}_*.md`, and `b1_b2_proxy_soak_fix/01_execution_slice.md`.
A10.1 worker correctly avoided these (slice forbade tracker/index touches). A doc-hygiene
sweep can address; not surfaced to runtime.

### CC-5 — `lib/dev/` ownership is not formally claimed by a contract

A9.1 moved `mock_integration_replay_seed.dart` into `lib/dev/`. CLAUDE.md "Service-Layer
Split" lists `lib/dev/ — demo and dev-only` but no formal contract doc describes what
belongs there, what doesn't, who owns it, or how it interacts with `kDemoMode` builds.
Three files live there now (`demo_fixture_data.dart`, `fixture_seed_data.dart`,
`mock_integration_replay_seed.dart`). Risk: future slices add reader-side branching here
without anchor. **P3 — CC-5 (no immediate action required; suggest adding a half-page
`docs/contracts/lib_dev_ownership.md` when the next slice touches that directory).**

## Recommendations sorted by priority

### P0 (blocking, fix before next wave)

None.

### P1 (material, fix this wave)

- **B1.b peer-bug closure (B1.c).** Four `_audit` helpers still write `actorKind: 'user'`
  on admin-JWT paths. **Evidence:** `tool/advisor_proxy/proxy_bootstrap.dart:4083, 5638,
  6287, 6745`. **Authority:** CLAUDE.md "Proxy & API Conventions" — `actor_kind` honesty.
  **Action:** open `B1.c` slice; flip all four to `'forge_admin'`; extend
  `test/advisor_proxy_bootstrap_test.dart` regression to cover pricing-tier, corpus,
  graph, feature-flags.

- **A11.1 gauge wiring closure.** The session-record incomplete gauge collects counts
  but no consumer reads them, breaking the slice promise of emitting
  `proxy.session_record.incomplete{route, missing_field}`. **Evidence:**
  `tool/advisor_proxy/advisor_proxy.dart:6969-7047` (gauge); no
  `snapshot()` / `totalIncrements()` caller anywhere outside the unit test.
  **Authority:** slice spec `docs/_execution/lane_a_code_health/03_execution_slices.md`
  Slice A11.1 + Metric Honesty Doctrine. **Action:** add a `/health` producer that
  exposes the snapshot, or log it on a timer, or downgrade the gauge to "internal
  buffer" in comments and document the followup in `POST_HARDENING_FOLLOWUPS.md`.

- **B9.2 clock-skew tolerance on `_requireFreshMfaToken`.** Zero tolerance for
  `authTime.isAfter(now)` causes false-positive `AccountSessionFreshMfaRequiredException`
  for clients with slow clocks. **Evidence:** `lib/operator_web/services/web_account_gateway.dart:184-191`.
  **Authority:** CLAUDE.md Time Guardrails + RFC 9470 conventional tolerance ≥30s.
  **Action:** add `Duration(seconds: 60)` skew tolerance, or remove the `isAfter` branch
  entirely (a future `auth_time` is still a valid fresh-MFA token).

- **B9.2 server-side step-up enforcement gap.** Client-side `_requireFreshMfaToken` is
  bypassable; the server route `/v1/auth/session/revoke` does not enforce RFC 9470 step-up.
  **Evidence:** `tool/advisor_proxy/advisor_proxy.dart:8502-8508` route is bearer-auth
  only; B11.2 row (ledger line 66) targets this gap. **Authority:** CLAUDE.md
  "Agent-Led Slices" — auth-critical slices require explicit operator approval; operator
  pre-approved B9.2 conditional on B11.2 landing. **Action:** schedule B11.2 to land
  before Active Sessions revoke is soft-launched; document the bypass risk in operator
  release notes; consider a feature flag to disable the UI until server-side enforcement
  ships.

- **B11.1 idempotency-store convention divergence.** Cache is in-process Map; the proxy
  convention is `proxy_requests` UNIQUE in Postgres. **Evidence:**
  `tool/advisor_proxy/auth_handoff_routes.dart:287-347`. **Authority:** CLAUDE.md
  "Proxy & API Conventions" — "*proxy stores keys in `proxy_requests` (UNIQUE)*". **Action:**
  either migrate `HandoffMintIdempotencyCache` to `proxy_requests`-backed store, or
  document an explicit carve-out in `POST_HARDENING_FOLLOWUPS.md` with the 60-second-TTL
  rationale.

### P2 (doc drift, fix opportunistically)

- **B11.1 forge_admin grant comment.** Migration grants `select, delete` but comment
  says "*forge_admin gets read for ops visibility*". **Evidence:**
  `db/migrations/202605131030_b11_1_auth_handoff_codes.sql:236-244`. **Authority:**
  CLAUDE.md least-privilege philosophy. **Action:** either drop `delete` from grant or
  update comment to explain why DELETE is needed (e.g., "to scrub a stuck handoff row
  in support investigations").

- **C-8 default-state fallback to `available`.** New catalog entries silently render as
  working toggles without an emitter. **Evidence:**
  `lib/operator_web/screens/settings_notifications_screen.dart:102-103`. **Authority:**
  Metric Honesty Doctrine. **Action:** flip default to `_NotifEventState.comingSoon`,
  or raise `StateError` in dev/test when the matrix is incomplete.

- **B9.2 freshness-window catalog.** Three windows (5 min / 1 hour / 1 hour) across
  three files with no central doc. **Evidence:** `web_account_gateway.dart`,
  `lib/auth/auth_session.dart:71-74`, `lib/auth/fresh_mfa_resolver.dart:17`.
  **Authority:** CLAUDE.md Time Guardrails meta-discipline. **Action:** add a half-page
  catalog to `docs/contracts/` listing each window, what it protects, and how to choose.

- **A0 + A10.1 doc-drift residue.** Multiple historical docs still reference
  `test/load/pressure/`. **Evidence:** `docs/_audits/code_health/a0_b1_b2_post_merge_verification.md:74`,
  `docs/_audits/code_health/a11_soak_harness_durable_kit.md`,
  `docs/_execution/lane_a_code_health/0{1,2,3}_*.md`,
  `docs/_execution/b1_b2_proxy_soak_fix/01_execution_slice.md`. **Authority:** A10.1
  worker correctly avoided these per slice scope. **Action:** opportunistic doc-hygiene
  sweep when the next planning-doc edit touches these files.

### P3 (nits)

- **CC-5 `lib/dev/` ownership.** No formal contract claims this directory.
  **Suggested action:** add a half-page `docs/contracts/lib_dev_ownership.md` when the
  next slice touches `lib/dev/`.

- **A4.1 audit-doc citation drift.** `proxy_bootstrap.dart:1646` (audit) → `:1686`
  (post-merge) → `:1704` (current master). Symbol intact; only line numbers shift as
  surrounding code churns. **Suggested action:** future audit docs should pin a content
  fingerprint (function name + 1-line snippet) instead of a bare line number to survive
  drift.
