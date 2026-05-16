# Infrastructure Deferrals Inventory

**Purpose.** A single discovery index for the long tail of deliberate
"we'll finish this later" infrastructure deferrals that today live only as
scattered per-file code comments (and a couple of incidental lines in forward
plans). Each row records the governing comment's exact `file:line`, the stated
trigger/phase, the surfaces affected, and how strongly the decision is
documented. Built for GAP B6 (consolidate weakly-governed infra deferrals).

**How to use.** This is a *discovery index, not authority*. It does not decide
or re-decide anything. When an item has a real owner (a phase doc, a contract,
a decision register entry), that owner remains canonical and wins on conflict
per `CLAUDE.md` Authority Order. Use this doc to *find* the deferrals and their
governing comments; use the cited phase/contract to act on one. Line numbers
are accurate as of the commit that adds this file and will drift — treat the
`file:line` as a pointer to re-grep, not a permanent anchor. "Doc strength"
is the honest current state: `code-comment-only` means the rationale exists
*only* in the cited comment(s) and is not carried by any contract/plan/ledger
row.

---

## Auth / Security

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| Mandatory MFA enforcement | TOTP enrollment ships at launch; **mandatory** MFA enforcement for admin-tier accounts is deferred. `MfaPolicy.evaluate` never returns `requiredAndNotEnrolled`/`requiredAndEnrolled`; `requiresStaffMfa` hard-returns `false`. Seam (signature + enum values) preserved so rollout reuses it. | `lib/auth/mfa_policy.dart:3-6`, `:41-47`, `:57-62` | "post-launch stability and explicit approval" (reopened 2026-04-30) | backend + all auth-gated surfaces | code-comment-only | Bounded — seam reserved, gated on explicit approval |
| Permission cache: shared/Memorystore tier | In-process LRU only (per-instance, `(userId, rolesVersion)` key, ~60s TTL). Shared/Memorystore cache deferred. | `lib/auth/permission_cache.dart:14-15` | "until ~50k MAU per the plan" | backend (proxy) | code-comment-only (refs "the plan") | Bounded — explicit MAU trigger |
| Permission cache cross-instance fan-out | Postgres `NOTIFY permission_cache_invalidate` listener; echo of malformed payloads intentionally deferred to avoid re-broadcasting bad data. | `lib/auth/permission_cache_invalidation_listener.dart:1`, `:161` | code-health PCACHE-FANOUT (horizontal scale-out) | backend (proxy) | code-comment-only | Bounded — narrow, behavior-preserving carve-out |
| Force sign-out (operator self-service) | Team/Members surface offers Suspend/Reset password/Reset MFA but **not** Force sign-out; deferred to the session-revocation owner. | `lib/operator_web/screens/members_screen.dart:26-31` | Phase 11W.4 (Sessions) | operator-web | code-comment-only (names owning phase) | Bounded — owned by a named phase |
| OAuth refresh cron: no auto-disable email | 3-strike cap flips connector status to `error` + writes `audit_logs`; **no** `email_outbox` emit. Operator sees state in admin UI only. | `lib/services/integration/oauth_refresh_cron.dart:38-43` | "lands later when volume justifies it" | backend + admin (UI shows state) | code-comment-only (refs lean-cut 2 memo) | Unbounded-ish — "when volume justifies", no hard trigger |

## Sync / Data Parity

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| Mobile multi-tenant resume | Watermark row keyed on `(operator_id, location_id)`; mobile V1 is single-tenant. Schema reservation lets post-V1 multi-tenant land without a migration. | `lib/services/sync/postgres_shift_record_to_mobile_sync.dart:27-32` | "post-V1 multi-tenant" | mobile + backend | code-comment-only (HP #4 schema reservation) | Bounded — schema reserved, no migration needed |
| `business_day_rollover_hour` column drop | Aloha/Square/NCR sinks now read `location.timezone` + the timing-profile chain; the deprecated `location.business_day_rollover_hour` column is left in place — drop deferred. | `lib/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink.dart:47-48`, `lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart:58`, `lib/infrastructure/persistence/postgres/ncr_pos_postgres_sink.dart:48` | "deferred to a follow-up" (Per-Daypart V1 Slice 7b) | backend | code-comment-only | Bounded — named slice did the deprecation; only column drop pending |
| Inheritance descendant cache: cross-pod fanout | Per-pod cache; `invalidate()` only clears the LOCAL pod. Other pods serve stale until TTL. Multi-pod posture needs shorter TTL or cross-pod fanout. | `lib/services/hierarchy/inheritance_descendant_cache.dart:239-243` | "V1 single-pod posture"; B6/B8 wire call sites | backend (proxy) | code-comment-only | Bounded — single-pod is the stated V1 posture |
| Realtime cross-pod replay (Pub/Sub) | Resolver supports both topologies; in-process ring is always-on fallback, Cloud Pub/Sub-fed ring layered on when `PUBSUB_REALTIME_ENABLED=true`. N5 lane plumbs the production wiring. | `lib/services/realtime/realtime_replay_resolver.dart:123` | N5 cross-pod replay lane; `PUBSUB_REALTIME_ENABLED` | backend (proxy) | code-comment-only (env-gated, infra in place) | Bounded — toggle + infra already present |
| Manual-DLQ operator action | Bridge worker only writes `attempt_cap_exceeded`; `forced_dlq` reason constant reserved but never written — manual-DLQ operator flow deferred. | `lib/infrastructure/persistence/postgres/repositories/event_outbox_dead_letter_repository.dart:100-103`, `:113-116` | "post-V1 manual-DLQ operator action" | backend + (future) operator UI | code-comment-only | Bounded — constant reserved |
| 7shifts `hours_and_wages` upgrade | Adapter sits in `perEmployeeWithRates`; would qualify as `perEmployeeWithDollars` IFF it consumes `/reports/hours_and_wages`. | `lib/services/integration/labor_wage_source_class.dart:32-36`, `lib/integrations/labor/seven_shifts_labor_adapter.dart:245-248` | `8.7S.upgrade.hours_and_wages` follow-up | backend + (post-V1) wage editor | code-comment-only (names follow-up slice) | Bounded — owned by a named slice |

## Notifications / Email

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| In-app notification scheduling | `AppRefreshCoordinator` is reload/bus-driven only — no timers, no polling, no auto-refresh loops; notification scheduling deferred. | `lib/state/app_refresh_coordinator.dart:31` | Phase 7.55p.4d | mobile | code-comment-only (names owning phase) | Bounded — owned by a named phase |
| Notification event hooks (`backend-only` states) | Several notification events render disabled / `backend-only` switches until their producer hook ships; map flips when audit matrix flips. | `lib/operator_web/screens/settings_notifications_screen.dart:78-87`, `:241-244` | "when a hook ships" (refs `notification_event_fanout.dart:737-757` FOLLOW-UPs + audit matrix E4/O3) | operator-web | code-comment-only (refs FOLLOW-UP comments + audit matrix) | Bounded — gated on per-event producer hooks |
| Email provider (SendGrid) lands Phase 9.8 | Integration admin returns "Email provider lands in Phase 9.8."; SendGrid rotation route is the Phase 9.8 extension. | `lib/admin/services/integration_admin_gateway.dart:118`, `:762`, `lib/admin/screens/integration_admin_screen.dart:9` | Phase 9.8 | admin + backend | code-comment-only (names owning phase) | Bounded — owned by a named phase |
| ToS / legal copy (Phase 9.8) | Data settings shows "Legal copy is in review for Phase 9.8"; existing operator agreements remain in effect. `tos_acceptances` is the Phase 9.8 schema. | `lib/screens/settings/settings_data_sections.dart:791`, `lib/operator_web/auth/operator_web_auth_source.dart:446` | Phase 9.8 | mobile + operator-web + backend | code-comment-only / interim copy shipped | Bounded — owned by a named phase |
| Vendor 3-strike auto-disable email wiring | Multiple POS/reservation adapters note "No 3-strike auto-disable email wiring (deferred to `9.8.email`)" (or "no email auto-disable"). Worker dispatcher seam exists; some adapters do not emit. | `lib/integrations/pos/aloha_ncr_voyix_pos_adapter.dart:47`, `lib/integrations/pos/toast_pos_adapter.dart:43`, `lib/integrations/reservation/tock_reservation_adapter.dart:42`, `lib/integrations/reservation/sevenrooms_reservation_adapter.dart:47`, `lib/integrations/reservation/opentable_reservation_adapter.dart:31`, `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart:42` | `9.8.email` (where named); else unscoped | backend + (operator email) | code-comment-only | Mixed — `9.8.email`-named rows bounded; "no email auto-disable" rows are unscoped someday |

## Scale / Performance

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| Circuit breaker: cross-instance state | Per-instance in-memory v1. Cross-instance Memorystore deferred. Rolling-window error rate, p99 latency, cost-breach trips deferred; `FailureKind.costBreach`/`http429` reserved but not raised/used in v1. | `lib/domain/services/circuit_breaker.dart:3-13` | E.2b (Lock 7); refs `phase_11a_decision_register.md:938-972` | backend (proxy) | contract-backed (decision register) + code-comment | Bounded — decision-register-anchored, E.2b trigger |
| Advisor response cache impl | v1 ships `AlwaysMissAdvisorResponseCache` (always null). Real impl (`query_response_cache` or in-memory LRU) lands with E.2b alongside Gemini secondary. Interface is real so it's a swap-in. | `lib/domain/services/advisor_response_cache.dart:3-6` | E.2b (Lock 7 secondary fallback) | backend (proxy) | code-comment-only | Bounded — interface reserved, E.2b trigger |
| Multi-location supervisor wiring | `RestaurantScopeNotifier` exposes a single active restaurant; multi-location supervisor sync deferred. | `lib/forge_flow_app.dart:1213-1215` | "a later phase" | mobile | code-comment-only | Unbounded-ish — "a later phase", no named owner |

## Vendor / Live-HTTP

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| SevenRooms live HTTP verification | Engineered at lifecycle `documented`; live HTTP verification deferred until partner credentials issued. | `lib/integrations/reservation/sevenrooms_reservation_adapter.dart:7-10` | `8R.SR.live.sandbox` + `8R.SR.live.prod` (4-8 wk partner lead time) | backend | code-comment-only (refs partnership_status.md) | Bounded — named live slices, external blocker |
| Oracle MICROS Simphony live HTTP | `documented` lifecycle; live OAuth/HTTP exchange deferred. | `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart:144-147`, `:204` | `8.OR.live.sandbox` + `8.OR.live.prod` (8-16 wk partner lead) | backend | code-comment-only | Bounded — named live slices, external blocker |
| Agendrix live HTTP | `documented` lifecycle; live HTTP / OAuth token exchange deferred. | `lib/integrations/labor/agendrix_labor_adapter.dart:151`, `:216` | live follow-up slice | backend | code-comment-only | Bounded — named live follow-up |
| Push Operations live HTTP | `documented` lifecycle; live HTTP / bearer + company-id bind deferred. | `lib/integrations/labor/push_operations_labor_adapter.dart:164`, `:237` | live follow-up slice | backend | code-comment-only | Bounded — named live follow-up |
| Humanity live HTTP | `documented` lifecycle; live HTTP deferred. | `lib/integrations/labor/humanity_labor_adapter.dart:425` | live follow-up slice | backend | code-comment-only | Bounded — named live follow-up |
| Lightspeed LSK live HTTP | `documented` lifecycle; live HTTP deferred. | `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart:6` | live follow-up slice | backend | code-comment-only | Bounded — named live follow-up |
| Clover / Revel live HTTP | Engineered against documented APIs only; live HTTP rolls out via a later live slice. | `lib/integrations/pos/clover_pos_adapter.dart:12`, `lib/integrations/pos/revel_pos_adapter.dart:7` | later live slice | backend | code-comment-only | Bounded — named live slice |
| Operator Web Console: live HTTP gateway | `11W.0` ships shell + onboarding click path; live HTTP wiring against the proxy is a thin gateway in a follow-up slice. Deploy script refuses non-demo build until it lands. | `lib/operator_web/auth/operator_web_auth_source.dart:28-34` | `11W.0.live` slice | operator-web + backend | code-comment-only (deploy-script guard enforces) | Bounded — named live slice + deploy guard |
| Vendor connections panel: gateway not wired | Panel renders a non-functional state when the host shell has not wired the live HTTP gateway yet. | `lib/operator_web/screens/vendor_connections_screen.dart:115` | host-shell live gateway wiring | operator-web | code-comment-only | Bounded — follows the 11W.0.live wiring above |

## Misc (UI scope holds)

| Item | What's deferred / interim behavior | file:line | Trigger / phase | Surfaces | Doc strength | Bounded vs someday |
|---|---|---|---|---|---|---|
| Hierarchy tree full chain (Business Setup / Timing) | Tree renders only reachable rungs (Business → optional Region → Location); brand/district rungs not exposed by the timing bundle. Data-gap explainer shown below the tree. | `lib/operator_web/screens/business_setup_screen.dart:259`, `:338-342`, `lib/operator_web/screens/business_timing_editor_screen.dart:200` | `TODO(wave-N)` — "once hierarchy reachable" | operator-web | code-comment-only (`TODO(wave-N)`) | Unbounded-ish — `wave-N` placeholder, no concrete wave |
| Per-day / per-row inheritance badges | Schedule + Wage Authority show a screen-level scope notice instead of per-day / per-row inheritance badges, pending hierarchy columns on `weekly_plan_snapshot` / `wage_role_rows`. | `lib/operator_web/screens/schedule_screen.dart:179-182`, `lib/operator_web/screens/wage_authority_screen.dart:479-481` | `TODO(wave-3+ hierarchy forecasts/wages)` — gated on new schema columns | operator-web | code-comment-only (`TODO(wave-3+ ...)`) | Bounded-ish — gated on named schema columns; `wave-3+` is loose |
| Audit-log hierarchy-filtered CSV | Hierarchy-filter pane has no CSV export; CSV stays on the legacy unfiltered audit-log surface. | `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart:26-29` | "future-slice item ... to keep B8.b scoped" | operator-web | code-comment-only | Unbounded-ish — "future-slice item", no named owner |
| Operator Web onboarding URL sync | `11W.0` ships only the magic-link landing parser; URL synchronization for the rest of the click path deferred to keep the slice scoped. | `lib/operator_web/router/operator_web_router.dart:5-7`, `:15-21` | "a follow-up" | operator-web | code-comment-only | Unbounded-ish — "a follow-up", no named owner |
| Account screen HP #11 backend-only explainer | Per-notice explainer surfaced when scope is below business and not a location, because some inheritance is backend-only (no per-scope override UI). | `lib/operator_web/screens/account_screen.dart:200-204`, `:1049` | HP #11 ("document why ... backend-only/gated") | operator-web | contract-backed (HP #11) + code-comment | Bounded — HP #11 explicitly permits the documented carve-out |

---

## Cross-reference note

`docs/_indices/NEXT_WAVE_PLAN.md` carries **no** match for these deferral
triggers (`E.2b`, `~50k MAU`, `Memorystore`, `9.8`, `11W.4`, `.live.`), and
`docs/POST_HARDENING_FOLLOWUPS.md` only mentions them incidentally — which is
precisely the weak-governance condition GAP B6 targets. The strongest-governed
items are the two **circuit breaker** rows (anchored in
`docs/phases/phase_11a/phase_11a_decision_register.md:938-972` Lock 7) and the
**HP #11** account-screen explainer. Everything else is `code-comment-only`
today; this index is the discovery layer until a real owner exists.
