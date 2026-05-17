# Cross-Surface Parity Audit — Admin / Operator-Web / Mobile

**Date:** 2026-05-16 (status ledger refreshed 2026-05-17)
**Branch / HEAD:** master @ `40cc12df` (audit pass ran at `5c3fc74c`; see §0 ledger for what merged since)
**Method:** 11 read-only deep-research agents (6 inventory/parity + 5 line-level verification),
whole-file reads, control-flow traced, every claim file:line cited.
**Surfaces:**
- Admin = `lib/main_admin.dart` → `lib/admin/**` (F&F Ops Console, Flutter Web)
- Operator-Web = `lib/main_operator_web.dart` → `lib/operator_web/**` (`app.forgeflow.app`, Flutter Web)
- Mobile = `lib/main_forgeflow.dart` → `lib/forge_flow_app.dart` + `lib/screens/**` (offline SQLite app)

**Status legend:** Verdict = CONFIRMED / REVISED / REFUTED / RECLASSIFIED.
Class = TRUE-GAP / BY-DESIGN / BY-DESIGN-UNDOCUMENTED / CLEAN.
Lifecycle = OPEN / FIXED / FUTURE-WORK.

This doc is the canonical register. IDs are stable; reference them as G1, D1, U1, C1.

---

## 0. Post-merge status ledger — updated 2026-05-16 (AUTHORITATIVE; supersedes per-row Lifecycle cells below)

**Merged & live on master:**
- **G1, G2** → PR #831 (squash `e9e686f4`). FIXED — admin sign-in/out written to `auth_sessions`; Active Sessions list + per-row revoke + sign-out-everywhere. Independent audit: `pr_831_admin_session_ledger.md` (APPROVE-FOR-MERGE).
- **G5** → PR #831 + deploy follow-up `19eed29d` (`Dockerfile.admin_console` ARG + `--dart-define`; `deploy_admin_console.ps1` sets `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH` only for `-SharePreview`/`-DemoMode`). FIXED — real release-mode fail-closed guard.
- **G66** → PR #838. FIXED — `InvitedUserActivationLedgerWriter` wired in `proxy_bootstrap.dart`; live invitees (mobile + operator-web) now flip `invited→active`. Operator-signed-off Q3 policy: data-integrity `StateError` → warning log + login succeeds; genuine infra exception → fail closed. Audit: `pr_838_g66_invite_activation.md`.
- **G4** → PR #840. FIXED — admin self-service MFA enroll/confirm/recover + password change against existing `/v1/auth/mfa/*` + `/v1/auth/password/*` (Step-1 verdict A: no new backend routes). Audit: `pr_840_admin_self_mfa.md`.
- **G24 / G3** → **FIXED via PR #851** (`4575f162`, "G24/G3 S3′: delete magic-link/custom-token + ToS; Firebase reset-email onboarding"). The non-functional magic-link/custom-token attempt (**PR #832**, `9a7c736e`) was **REVERTED via PR #853** (`fd210f48`) before #851 landed the production-honest path: Firebase reset-email invite model, magic-link route/gateway/client deleted, ToS step dropped (defers `operator_self_served_tos_contract.md` / Phase 9.8), #832's MFA wiring retained. S1 root cause (G66) already FIXED via #838. `pr_832_operator_web_onboarding.md` remains SUPERSEDED. Detail: `onboarding_server_slice_spec.md`.
- **G60** → **FIXED via PR #855** (`b921af0f`, "caller-stable idempotency keys for operator-web account/timing writes"). `HttpWebAccountGateway` + `HttpWebBusinessTimingGateway` now carry caller-stable idempotency keys; data-corruption risk closed.
- **G19 / G62** → **FIXED via PR #857** (`d5629066`, "operator-web fail-loud on live wiring gap + demo banner"). Operator-web now surfaces a demo banner / `kDemoMode` tell and fails loud when live wiring is missing rather than silently serving fixtures.
- **G30** → **FIXED via PR #859** (`568c1741`, "alias operator-web auth permission literals to PermissionKeys constants"). Operator-web admit/role-inference bare permission strings replaced with `PermissionKeys` constants; behavior-preserving, catalog-rename-safe. (This is the §3 G30 slice; the broader G7 re-spec is separate — see Parked.)

**Operator decision — operator_admin verdict (2026-05-16):** independent trace resolved `operator_admin` as a **phantom** (never seeded v1 or v2; sole producer is `_inferRoles` synthesis; every consumer is fallback-only, unreachable once the permission snapshot hydrates). **Verdict: fold into `operator_owner`** (do NOT seed a 7th role, do NOT map to a v2 role). Implementation = doc-strike (G7c) + cruft removal (G7d), both gated behind the parked G7 re-spec. Full trace in `g7_permission_convergence_spec.md` "operator_admin VERDICT".

**Parked (operator said "stop" / awaiting explicit go — no work until resumed):**
- **G41 / G42 / G13** — HP#11 effective-value *timing* faking on admin + operator-web (admin read-only-accurate + a new dedicated resolution endpoint; proxy/RLS-gated backend route needed). TRUE-GAP, build deferred. Spec: `fix4_hp11_effective_value_spec.md`.
- **G7 re-spec** — the permission-convergence spec is **SUPERSEDED**: built on the stale v1 seed (6 roles). Real current model = the **v2 default role catalog, 10 roles** (`db/migrations/202605150000_phase_r2l_default_role_catalog_v2.sql` — incl. `location_manager`, `team_admin`, `operator_general_manager`; `operator_admin` is NOT a role key). G7 needs **re-spec vs v2** (carrying the operator_admin→operator_owner verdict + the `permission_keys.dart` v1→v2 constant refresh co-requisite) before any G7c/G7d work. `g7_permission_convergence_spec.md` headline §0 stays invalid; the §3 G30 slice already shipped (#859).

**Reclassified by operator decision — WON'T-FIX / BY-DESIGN (2026-05-16, confirmed):**
- **D1 / G65** (web apps have no realtime; data stale until manual refresh) → operator ruled "not needed". **WON'T-FIX**, reclassified BY-DESIGN-accepted; closed, no work.
- **G10 / G40 (data-accuracy covers/wage SOURCE scoping)** → operator ruled **INTENDED, not a gap** → **BY-DESIGN** (no work). Only the residual HP#11 *timing* faking (G41/G42/G13) stays a TRUE-GAP, and it is PARKED (see above).
- Already recorded below: G12 → BY-DESIGN-documented; G15 → REFUTED/FIXED (Slice 7b); G8 → downgraded to maintainability smell; G11 → enlarged (mobile Timing **and** Wage both non-compliant).

**Audit trail:** this register + all PR audits + specs committed via **PR #845** (`977795e0`, `claude/cross-surface-parity-audit-docs`), which also fixed the dead doc-pointer left in merged #838. Two doc deltas pushed to that branch after the #845 squash (D1/G65 won't-fix + active-wave sequencing; the operator_admin verdict block) were subsequently re-landed on master via later doc merges and are reflected above.

**Net state (2026-05-16):** FIXED/MERGED — G1/G2/G5 (#831 + `19eed29d`), G66 (#838), G4 (#840), G24/G3 (#851; #832 reverted via #853), G60 (#855), G19/G62 (#857), G30 (#859), audit docs (#845). PARKED awaiting operator go — G41/G42/G13 (HP#11 timing) + G7 re-spec. WON'T-FIX/BY-DESIGN (confirmed) — D1/G65, G10/G40 SOURCE-scoping.

### Wave-2 ledger — updated 2026-05-17 (G7 unparked + executed; HP#11 unparked; Round-2 HIGH closed; mobile dropped)

Operator gave the go on the parked items (G7 re-spec + HP#11) and Round-2 §0b HIGH cluster. **Standing scope rule: NO mobile** — every mobile leg is dropped/reverted, not deferred.

**Merged & live on master (`40cc12df`):**
- **G7 re-spec → fully executed** (supersedes the "G7 PARKED" line above). Sequence: G7c (`#870`, contract reconciled to v2 + phantom `operator_admin` struck) → G7-pre (`#871`, v2 role constants added to `permission_keys.dart`, soft-deleted v1 deprecated, `baselineRoleKeys` redefined) → G7a (`#885`, shared `_isAdminSuperAdmin` helper, 14 admin gates DRY'd) → G7b (`#887`, admin consumes `PermissionKeys` role constants, behavior-preserving) → **G7d-main** (`#889`, operator-web fallback role sets → v2 constants, phantom `operator_admin` dropped, `integrations.configure` inflation removed). Spec: `g7_permission_convergence_spec.md`. **G7d-mobile DROPPED (no-mobile)** — the `team_scope_visibility_policy.dart:71` GM Team-nav fix + MOB-G71 are not pursued.
- **HP#11 S1 → `#872`** (`7468d6f6`, operator-web `business-timing-resolution` route + wire contracts; the backend prerequisite for S3). FIXED. Spec: `fix4_hp11_effective_value_spec.md`. S1 locked operator decisions: new dedicated endpoint, covers-only, tolerate legacy 3-daypart, admin read-only-accurate.
- **Round-2 §0b HIGH cluster (non-mobile) closed:** G70 → `#874` (admin identity-PATCH caller-stable idempotency); OW-G72 → `#876` (op-web data-accuracy + vendor-connections stable idempotency); OW-G70 → `#881` (fail-loud guard extended to the 4 commerce-critical op-web routes).

**Reverted / dropped under the no-mobile rule (NOT deferred — closed):**
- **X-G72 + MOB-G70** — mobile auth-ops idempotency + prod 401-refresh wiring shipped as `#877` then **REVERTED via `#880`** (`f8ca4a14`). WON'T-FIX (mobile out of operator scope). The §0b "register correction" re G61's mobile-auto-recovers claim stands as documentation only.
- **MOB-G71** — mobile v1→v2 role staleness; folded into the dropped G7d-mobile. WON'T-FIX (no-mobile).

**HP#11 (Fix #4) — FULLY CLOSED 2026-05-17 (G13/G41/G42 fixed; G40 by-design):**
- **S1 → `#872`** operator-web business-timing-resolution route + wire contracts.
- **S3 (G13) → `#895`** (`065826ed`) operator-web Business-setup: real inherited/effective values; lossy `business_business_timing_resolver_local.dart` deleted; G45/Gap28 day-restricted periods round-trip. Audited clean, behavior-neutral, merged.
- **S2 → `#893`** (`0dcb4bf5`) admin cross-tenant `withSystem` read route + admin client gateway. RLS/proxy-touching → **explicit operator merge approval given**. Isolation verified: operator-scoped path byte-identical (SQL-equality test), sanctioned `runAsSystem` bypass only, admin-gated 403 for operators, read-only, no RLS policy/migration/wrapper changed.
- **S4 (G41+G42) → `#906`** (`e5aa032d`) admin timing surfaces: deleted hardcoded/synthetic candidate fabrication on `admin_timing_setup_screen.dart` + `operator_location_admin_screen.dart`; both resolve via S2 gateway → canonical resolver; read-only-accurate (no write affordance); Gap 31 honored. Audited clean, merged.
- **S5 (G40) → DROPPED** — operator ruled data-accuracy/polling covers/wage SOURCE-scoping INTENDED, not a gap (BY-DESIGN). No timing residual remained after S4.
- Net: G13/G41/G42 TRUE-GAP → FIXED; G40 → BY-DESIGN. HP#11 timing-faking fully eliminated across operator-web + admin.
- **Round-2 §0b MED/standalone (non-mobile, recorded, not started):** G71 (admin token-refresh-retry), G72 (admin demo-tell), X-G70 (demo-tell harmonization — admin leg only, mobile out), X-G71 (notification-prefs surface gap admin vs op-web), OW-G73 (dead wage route), OW-G74 (init stack-trace exposure), G73 (admin demo Roles v1 catalog — doc line).

**Doc loose ends (tracked, low-priority):** register §0 now current as of `40cc12df`; pre-existing `admin_shell_widget_test` IA-drift to log in `docs/KNOWN_FAILING_TESTS.md`; stale `stash@{0}` (redundant post-#840) to drop.

---

## 0b. Round-2 framework audit — NEW findings 2026-05-16 (post-fix master 1380c70e..5962a74c)

Method: 4 read-only agents applied `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` + the per-daypart surface-coverage method to CURRENT master, excluding all tracked G1–G66/D*/U1/C* and parked/won't-fix/in-flight items. **No regressions in the merged fix wave (#831/#838/#840/#851/#853/#855/#857/#859) — all hold for their covered scope.** Dominant theme: **incomplete coverage** — the same bug *classes* recur on surfaces/gateways the fixes did not touch.

### Idempotency (G60-class data-corruption) — 3 NEW loci, fix not regressed but scoped too narrowly
| ID | Surface | file:line | Note |
|---|---|---|---|
| G70 | Admin | `lib/admin/screens/my_account_admin_screen.dart:1576,1608-1612` | Identity-PATCH dialog re-mints a fresh key in the retryable submit handler; #855 (G60) fixed operator-web only. HIGH. |
| OW-G72 | Operator-Web | `lib/operator_web/services/operator_web_data_accuracy_gateway.dart:86,155`; `operator_web_vendor_connections_gateway.dart:240-254` (callers :81,129,174,202) | DataAccuracy + VendorConnections write gateways still mint fresh keys per call; #855 census never covered them. Hits the active per-daypart SOURCE write + vendor-credential persist. HIGH. |
| X-G72 | Mobile | `lib/services/auth/proxy_auth_operations_gateway.dart:1321,1385-1394`; not injected at `firebase_auth_runtime_bindings.dart:245-249` | `ProxyAuthOperationsGateway._send` stamps a fresh random key per HTTP send; ~14 mutating org/team writes (createRole/Invite/RoleGrant, create/move/rename/suspend/deleteOrgUnit, suspend/deleteLocation, revokeSession). Operator-web does the same op with a stable key. NEW (org-rename #841 post-register). HIGH. |

### Fail-loud (G62-class) — incomplete
| ID | Surface | file:line | Note |
|---|---|---|---|
| OW-G70 | Operator-Web | `lib/operator_web/router/operator_web_router.dart:1180-1291` (Vendor connections / Data accuracy / Wage authority / Schedule cases lack `_liveSurfaceMissingGateway`) | #857 guarded only 7 surfaces; the 4 highest-value (credential/SOURCE/schedule) routes still silently serve fixtures on a live wiring gap. HIGH. |

### Auth-resilience (G61-class) + register-claim correction
| ID | Surface | file:line | Note |
|---|---|---|---|
| MOB-G70 | Mobile | `lib/main_forgeflow.dart:71-74` (no `refreshIdToken` arg); guard `lib/services/sync/http_sync_proxy_client.dart:592,657` | Production `HttpSyncProxyClient` never wired with the refresher → mobile's 401-refresh-and-retry is DEAD in the prod flavor. **Corrects register G61's "mobile auto-recovers once" claim — false in prod.** HIGH. |
| G71 | Admin | bearer `main_admin.dart:751-757`; no 401 branch in any admin gateway | No token-refresh-retry on any admin gateway (destructive admin actions hard-fail on token skew); admin parallel of G61. MED. |

### Demo-honesty parity — fix wave created a new asymmetry
| ID | Surfaces | file:line | Note |
|---|---|---|---|
| X-G70 | All 3 | web `operator_web_demo_banner.dart` (added #857); mobile banner DELETED by #858; admin never had one (`DemoAdminAuthSource.signedInAsSuperAdmin()`, no tell) | 3 different demo-tell postures now. G19 FIXED for its scope but the wave inverted parity + admin leg never covered. HIGH (operator-facing honesty). |
| G72 | Admin | pill gated on `sharePreviewMode` only; `ADMIN_DEMO_AUTH` path `main_admin.dart:375-379` | `ADMIN_DEMO_AUTH` build serves all in-memory gateways with no demo tell (admin G19/G62 parallel). MED. |

### v1→v2 role staleness (fold into parked G7)
| ID | Surface | file:line | Note |
|---|---|---|---|
| MOB-G71 | Mobile | `lib/screens/settings_screen.dart:592-598` (`_isAdminTier` checks soft-deleted v1 `operator_manager`, never v2 `operator_general_manager`); empty-snapshot path `forge_flow_app.dart:1427-1428` | A v2 GM loses Setup+Integrations tabs (Account-only) when the permission snapshot is empty. Distinct file from the tracked G7d-mobile `team_scope_visibility_policy.dart:71`. **Fold into G7d-mobile scope.** MED. |
| OW-G71 | Operator-Web | `operator_web_auth_source.dart:287-296` admit set v1-stale | v2 `team_admin`/`operator_general_manager` admitted only via suffix-accident; over-grants vs v2 intent. **Subsumed by parked G7 re-spec.** MED, flag-only. |

### Capability-absence
| ID | Surfaces | file:line | Note |
|---|---|---|---|
| X-G71 | Admin/Mobile vs Op-Web | op-web `settings_notifications_screen.dart` (full editor) vs mobile `notifications_screen.dart` (read-only inbox) vs admin (none) | Notification-preferences editor exists only on operator-web; mobile inbox-only, admin none. Not scope-chrome (not subsumed by HP#11 sweep) — a missing-surface gap. MED. |

### Low / by-design-noted
- G73 (admin demo Roles seeds v1 6-role catalog — BY-DESIGN-UNDOCUMENTED, doc line); OW-G73 (dead `kOperatorWebNavWageAuthority` route + false comment); OW-G74 (init-failed surface renders full stack trace, collapsed — minor info-exposure); MOB-G72 (`FcmTokenRevalidationObserver` dead code, resume-revalidation safety net never wired).

### Disposition
- **HIGH cluster (proxy/auth-critical, recommend extend-the-pattern):** the 3 idempotency loci (G70/OW-G72/X-G72), OW-G70 fail-loud completion, MOB-G70 wire the refresher. All well-understood (extend the #855/#857 patterns). Each is operator-approval-gated (proxy/auth-touching).
- **Fold into in-flight G7:** MOB-G71 → G7d-mobile scope; OW-G71 → G7 re-spec (flag-only).
- **MED/standalone:** X-G70 demo-tell harmonization, G71/G72 admin auth-resilience + demo-tell, X-G71 notification-prefs surface gap.
- **Register correction:** the G61 row's "mobile auto-recovers once" is FALSE in prod (MOB-G70) — annotate when triaged.

### §0b disposition update — 2026-05-17 (the §0b tables above are the Round-2 backlog; this is their live status)
- **CLOSED/MERGED:** G70 (`#874`), OW-G72 (`#876`), OW-G70 (`#881`).
- **WON'T-FIX (no-mobile rule):** X-G72 + MOB-G70 (shipped `#877`, reverted `#880`); MOB-G71 (folded into dropped G7d-mobile). The G61-correction note is documentation only.
- **OPEN, recorded, not started (non-mobile MED/standalone):** G71, G72, X-G70 (admin leg only), X-G71, OW-G73, OW-G74, G73.
- The §0b rows are NOT a separate backlog file — this register §0b *is* the Round-2 backlog of record.

---

## 1. Fix-first ranking (priority order — original; see §0 for current status)

1. **G24 / G3** — live operator-web onboarding is non-functional (launch-blocking).
2. **G1 + G2** — admin sign-in not audited and admin sessions not revocable (security/audit).
3. **G60** — operator-web account/timing writes have no stable idempotency key (data-corruption risk).
4. **G40 / G41 / G42 / G13** — HP#11 effective-value is faked/synthetic on admin + operator-web.
5. **G5** — share-preview can publish fixture auth to public web; no code-level block.
6. **G62 + G19** — live wiring regression silently serves fixtures; no operator-web demo tell.
7. **G4** — admin cannot self-manage MFA yet enforces MFA-fresh gates.
8. **G7 / G30** — unify permission enforcement on the frozen `PermissionKeys` catalog.

---

## 2. Prior findings — verified register (G1–G19, D1, D7, D8, U1, C3, C4)

| ID | Verdict | Class | Lifecycle | Finding & key evidence (file:line) |
|---|---|---|---|---|
| G1 | CONFIRMED | TRUE-GAP | OPEN | Admin has no `auth_sessions` ledger writer; sign-in/out unrecorded. `main_admin.dart:241-267`; `admin_auth_gate.dart:374-477`; `my_account_admin_screen.dart:22-26` (screen admits it). Only `auth_sessions` ref is a read-only doc comment `roles_hierarchy_sessions_admin_gateway.dart:156`. |
| G2 | CONFIRMED | TRUE-GAP | OPEN | Admin: local sign-out only (`admin_auth_gate.dart:428-431`), no revoke/sign-out-all, own-session card says "not available" (`my_account_admin_screen.dart:692-699`). Operator-web: single-session revoke only (`web_team_sessions_gateway.dart:107-124`), `signOut()` Firebase-only (`firebase_operator_web_auth_source.dart:650-654`). Mobile: full (`auth_session_notifier.dart:479-600`, `proxy_refresh_token_revoker.dart:33-62`). |
| G3 | CONFIRMED | TRUE-GAP | OPEN | Live operator-web `submitPassword`/`beginMfaEnrollment`/`confirmMfaEnrollment`/`acceptTos` throw `UnsupportedError` (`firebase_operator_web_auth_source.dart:617-647`); `verifyMagicLinkToken` does NOT call `signInWithCustomToken` (`:576-586`). Demo source fully implements the path (`operator_web_auth_source.dart:648-807`). |
| G4 | CONFIRMED | TRUE-GAP | OPEN | 4 MFA-fresh-pinned admin actions (`admin_routes.dart:816-819`, `_isAdminMfaFresh` `:94-114`); only self-service is name/email (`admin_account_gateway.dart:74-78`); Security card read-only (`my_account_admin_screen.dart:519-526`). No admin enroll/recover/change-pw path. |
| G5 | CONFIRMED | TRUE-GAP | OPEN | Release assert `if (!kDebugMode && _kAdminDemoAuth && !_kAdminSharePreview)` exempts share-preview (`main_admin.dart:141-149`); `_resolveAuthSource` returns `DemoAdminAuthSource.signedInAsSuperAdmin()` on `ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN` (`:241-250`, fixtures `admin_auth_gate.dart:208-231`). Only deploy-script discipline guards public publish. |
| G6 | CONFIRMED | TRUE-GAP | OPEN | `serverSelectionWriter==null` (demo, or live w/o `FORGE_FLOW_PROXY_BASE_URI`) ⇒ local-only SQLite write, no warning/telemetry. `main_forgeflow.dart:60-115`; `forge_flow_bootstrap.dart:75-82`; `baseline_manager_service.dart:319-401`; `target_cycle_service.dart:175`. |
| G7 | CONFIRMED (sharpened) | TRUE-GAP | OPEN | 3 enforcement models. Admin = role-set only, never `PermissionKeys` (`admin_routes.dart` 15 sites). Operator-web = hybrid; admit uses bare strings not catalog constants (`firebase_operator_web_auth_source.dart:746-770`) → see G30. Mobile = frozen catalog + resolver (`permission_gate.dart:51-64`). |
| G8 | REVISED (downgraded) | TRUE-GAP (smell) | OPEN | 15 copy-pasted `roles.contains('super_admin')` sites in `admin_routes.dart` (census in §5). **No active mutating builder is unguarded**; demo full-write path unreachable in prod (`main_admin.dart:206-224` always non-null source). Maintainability risk, not a security hole. |
| G9 | CONFIRMED | TRUE-GAP (doc) | OPEN | `kOperatorWebAdmittedRoles` admits `operator_manager` (`operator_web_auth_source.dart:360-365`) but doc comment omits it (`:356-359`); every write-role set is owner/admin-only so behavior is safe. Stale contract/comment. |
| G10 | CONFIRMED | TRUE-GAP | OPEN (plan Gap 29) | Operator-web Data Accuracy screen imports/renders zero scope notice (`data_accuracy_screen.dart`); `hierarchy_scope_notice.dart:14-22` doc comment falsely lists it compliant. |
| G11 | REVISED (bigger) | TRUE-GAP | OPEN (plan Gap 30) | Mobile Timing raw values, no scope/inherited/effective (`settings_timing_authority_section.dart:126-154`). Earlier "mobile Wage is the compliant contrast" REFUTED — mobile Wage shows data-provenance not hierarchy scope (`settings_wage_authority_section.dart:874-879`). BOTH non-compliant. |
| G12 | RECLASSIFIED | BY-DESIGN (documented) | FUTURE-WORK (plan Gap 32) | Operator-web Wage hardcoded `HierarchyScopeLevel.location`, `inheritedFromLabel:null` BUT carries `backendOnlyExplainer` (`wage_authority_screen.dart:482-495`) — HP#11 escape clause satisfied. Functional pain (re-enter wages per location) remains future work; UI is honest. |
| G13 | CONFIRMED (worse) | TRUE-GAP | OPEN | Operator-web local resolver handles 4 of ~7 fields, **discards all org-unit intermediate profiles** (`http_business_timing_read_gateway.dart:134-141`), string-equality "inherited" heuristic mislabels deliberate same-value overrides (`business_business_timing_resolver_local.dart:56`), no period-count/overlap validation. Canonical: `business_timing_profile_resolver.dart:24-231`. |
| G14 | CONFIRMED (7 diffs) | TRUE-GAP | OPEN | Forked blended-wage. Operator-web `blended_wage_calculator.dart:106-145` vs mobile `wage_standard_context_service.dart:35-88,262-270`. Differences: negative-rate filter, precedence waterfall, FOH/BOH completeness gate, manager-row handling, data source, zero-hours semantics, provenance. Side-by-side in §6. |
| G15 | REFUTED (fixed) | — | FIXED (Slice 7b) | All 20 sinks migrated to hierarchy-aware HH:MM `SinkBusinessDateProjector` (`sink_business_date_projector.dart:133-209`); 0 `toBusinessDate(` calls remain. Residual log-only trigger drift re-filed as G50. |
| G16 | REVISED (narrowed) | TRUE-GAP | OPEN | Team/roles/sessions/security gateways DO pass stable keys. Defect confined to `HttpWebAccountGateway` + `HttpWebBusinessTimingGateway` → re-filed precisely as G60. Census §7. |
| G17 | CONFIRMED | TRUE-GAP (minor) | OPEN | Mobile boots with empty proxy URI (`firebase_auth_runtime_bindings.dart:200-288`), fails only at sign-in; web `StateError`s at launch (`main_admin.dart:281-284`, `main_operator_web.dart:180-190`). |
| G18 | CONFIRMED | TRUE-GAP (dead code) | OPEN | `ObservabilityAdminScreen` never passed `tripwireGateway` (`admin_routes.dart:1141-1147`; section gated `observability_admin_screen.dart:278`). `AuditLogAdminScreen` (`audit_log_admin_screen.dart:45`) referenced by no route. `Http*` impls never constructed. |
| G19 | CONFIRMED | TRUE-GAP | OPEN | No demo banner / `kDemoMode` tell anywhere in `operator_web_router.dart`; demo auth substitutes ~9 fixture gateways (`:1390-1504`). `DemoModeBanner` is mobile-only. |
| D1 | CONFIRMED | BY-DESIGN | — | Zero `RealtimeSubscription` in `lib/operator_web`/`lib/admin`. Web staleness unbounded until manual reload vs mobile ≤5-min push (`realtime_subscription.dart:67,176`). Consequence gap → G65. |
| D7 | CONFIRMED | BY-DESIGN (w/ caveat) | OPEN via G51 | Mobile `LaborModel` client-side vs operator-web server-precomputed (`operator_web_schedule_gateway.dart:535-549`); no shared path, no parity test. Mechanism = G51. |
| D8 | CONFIRMED | BY-DESIGN | — | Operator-web Schedule honestly backend-only via `HierarchyScopeNotice.backendOnlyExplainer` (`schedule_screen.dart:183-198`). Compliant. |
| U1 | CONFIRMED | BY-DESIGN-UNDOCUMENTED | OPEN (doc) | Admin Vendor Applicability is a global F&F catalog with no scope chrome and no doc rationale (`vendor_applicability_admin_screen.dart:241-300`; doc search empty). |
| C3 | CONFIRMED | CLEAN | — | Every admin gateway has a real `Http*` impl; only exceptions are the two G18 dead surfaces. |
| C4 | CONFIRMED | CLEAN | FIXED | Single `DaypartBucketer` engine in closed + live paths (`canonical_fact_to_closed_shift_input.dart:1098-1116`; `open_shift_snapshot_projector.dart:303-348`). |
| C1 | CONFIRMED | CLEAN | — | No undocumented reader-side `kDemoMode` branch on any surface; all hits are the 4 documented carve-outs or writer/source swaps. |
| C2 | CONFIRMED | CLEAN | — | Tenant scoping enforced server-side for all surfaces; admin cross-operator is the contract-allowed role bypass. |

---

## 3. New findings from the deep pass

### True gaps

| ID | Title | Lifecycle | Evidence (file:line) | Reasoning |
|---|---|---|---|---|
| G23 | Mobile doesn't cross-check ledger vs JWT scope; operator-web does | OPEN | Web `firebase_operator_web_auth_source.dart:387-395`; mobile `auth_session_notifier.dart:362-367` | Operator-web rejects `permission_scope_mismatch`; mobile blindly adopts ledger scope. Inconsistent defense-in-depth. |
| G24 | Live operator-web onboarding fully non-functional (escalation of G3) | OPEN | `firebase_operator_web_auth_source.dart:580-586` + G3 throws | Invited operator cannot sign in on live operator-web at all. Deploy-script block is the only thing preventing broken prod. Launch-blocking. |
| G30 | Operator-web admit/role-inference uses bare permission strings not catalog constants | OPEN | `firebase_operator_web_auth_source.dart:746,752-755,767-770` | All 4 match catalog today but un-aliased; a catalog rename silently breaks admit while screens stay correct. |
| G40 | Admin Data-Accuracy & Polling show a faked inherited-source | OPEN | `admin_hierarchy_settings_scope_policy.dart:14-50`; `admin_route_handoff.dart:241-260` | Policy always emits `setAtScope`/`locationOnly`, never `inheritedFrom*`; effective-value labels are static strings. Scope chrome decorative. |
| G41 | Admin Timing Setup shows faked effective timing | OPEN | `admin_timing_setup_screen.dart:189-216` | Service periods/week-start/close-rule hardcoded literals; tz/day-start from legacy integer column. Wrong "effective" values shown. |
| G42 | Admin operator-location screen runs correct resolver on synthetic inputs | OPEN | `operator_location_admin_screen.dart:3711-3759,3809+` | Feeds the resolver hardcoded/legacy candidates, not real `business_timing_profiles` rows; source labels derived from scope flag not actual provider. |
| G43 | Admin Pricing screen has no scope chrome at all | OPEN | `pricing_tier_admin_screen.dart:198-224` | HP#11 names "pricing"; scope applied functionally but zero selected/inherited/effective indication, no carve-out doc. |
| G44 | Hardcoded 3-period Daypart enum breaks 4-period configs | OPEN (plan Gap 27/36) | `data_accuracy_settings.dart:130,182-216`; `data_accuracy_screen.dart:235-237,529-544`; `settings_covers_setup_section.dart:42-46` | Covers/wage source structurally locked to lunch/dinner/late-night; 4th configured period unsettable on web+mobile; effective value wrong. Legacy enum reader coexists with keyed path, no precedence (plan Gap 36). |
| G45 | Operator-web service-period editor cannot express day-restricted periods | OPEN (plan Gap 28) | `service_period_editor.dart:28-62` vs `service_period_definition.dart:33-34` | `ServicePeriodDraft` omits `applicableDays`/`shortLabel`/`sortOrder`; silently writes all-days; mobile then shows contradicting effective value. |
| G50 | Log-only SQL trigger truncates sub-hour cutoffs (residual of G15) | OPEN (scoped) | `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147` vs `sink_business_date_projector.dart:133-209` | Bounded — fires only on `connector_sync_log`/`inbound_webhook_dead_letter`/`sanity_log`, operator-locked defense-in-depth. Two business-date rules unreconciled; migration comment references now-dead code. |
| G51 | Model-hours formula forked, no parity guard (D7 mechanism) | OPEN | `labor_model.dart:20-31` vs `schedule_plan_resolver.dart:197-205` | Byte-identical reimplementation justified by layering; 0 `LaborModel` refs in `schedule_plan_resolver_test.dart`. Rounding tweak silently desyncs mobile vs operator-web. |
| G52 | "Theoretical labor %" computed with two different denominators | OPEN | `labor_model.dart:49-60` vs `weekly_plan_snapshot_schedule_plan_projector.dart:21-25`; `weekly_plan_snapshot.dart:258-259` | Mobile = rate/wage property (volume-independent); snapshot path = dollars/sales with rounding artifacts. Same targets show different labor % per surface. |
| G60 | Operator-web account/timing writes have no stable idempotency key | OPEN | `operator_web_proxy_client.dart:281,227-259`; `web_account_gateway.dart:203-284`; `web_business_timing_gateway.dart:114-167` | `_applyHeaders` mints fresh key per call; `patchJson`/`deleteJson` expose no override. Retried `createProfile` ⇒ duplicate timing profiles; retried identity PATCH defeats `proxy_requests` UNIQUE. Violates Proxy & API Conventions invariant. |
| G61 | Operator-web has no 401 token-refresh-and-retry; mobile does | OPEN | `operator_web_proxy_client.dart` (none); `http_sync_proxy_client.dart:50,592-610,657-670` | Clock-skewed/mid-rotation token = hard failure on web, auto-recovers once on mobile. |
| G62 | Demo-fixture substitution also fires for a live source missing a mixin | OPEN | `operator_web_router.dart:1390-1504` (comments :1395-1399,1432-1436,1497-1501) | A live wiring regression silently serves/accepts edits against in-memory fixtures, no error, no visual tell (compounds G19). Writes appear to succeed but no-op. |
| G63 | Inconsistent error-envelope handling across operator-web surfaces | OPEN | `web_team_roles_gateway.dart:355-364`; `web_team_users_gateway.dart:535-544`; `web_security_gateway.dart:903-917`; `operator_web_proxy_client.dart:326-343` | Each gateway invents its own error code; none distinguish 409 replay vs real conflict; 2FA-freshness 403 handled inconsistently across screens. |
| G65 | No missed-event recovery on web (consequence of D1) | OPEN | `realtime_subscription.dart:436-461` (mobile only) | Cross-actor mutation (session revoke, role change) = unbounded blind window on web, no stale signal; mobile recovers ≤5 min. |

| G66 | Invite-activation decorator unwired (cross-surface, live onboarding broken) | OPEN (highest priority) | `proxy_bootstrap.dart:1295-1297`; `invited_user_activation_ledger_writer.dart` (zero prod callers); `invited_user_activation_repository.dart` | `InvitedUserActivationLedgerWriter` never constructed in prod ⇒ every live invitee (mobile AND operator-web) who completes the Firebase reset email + signs in is never activated; `users.status` stays `'invited'` forever, `auth_invites.accepted_at` null. True root cause behind G24/G3 Gap #2. Fix = wire the decorator (server-slice S1). See `onboarding_server_slice_spec.md`. |

### By-design / low-severity (logged, not action items)

| ID | Title | Evidence (file:line) | Why acceptable |
|---|---|---|---|
| G20 | 2FA-freshness window differs (admin 1h, web/mobile 5min); policy never forces enrollment | `fresh_mfa_resolver.dart:92`; `firebase_operator_web_auth_source.dart:806`; `auth_session.dart:88`; `mfa_policy.dart:34,63-69` | Documented post-launch deferral; flagged as coupled with G4. |
| G21 | Demo mobile operator = 30-day `ff_support` unsigned token; freshness gates no-op in demo | `demo_auth_login_service.dart:109-158` | Endorsed writer-side demo swap; no backend in demo. |
| G22 | Mobile adopts proxy-resolved scope post-auth | `auth_session_notifier.dart:362-380`; `auth_session_ledger_writer.dart:96-108` | Intentional global-admin carve-out; proxy verifies the bearer JWT. |
| G31 | Operator-web inflates `integrations.configure` → owner-tier role | `firebase_operator_web_auth_source.dart:746-759` | On server-resolved snapshot; no write escalation reachable (snapshot path shadows role-tier fallback). |
| G32 | `operator_manager` admitted but undocumented | `operator_web_auth_source.dart:360-365` | Behavior safe (no write set includes it); stale comment only. |
| G33 | Permission-snapshot load failure → no retry | `auth_permission_context_bridge.dart:95-103`; `settings_screen.dart:638,651` | `PermissionGate` fails closed (safe); availability/UX concern only; null-actor fail-open unreachable when authenticated. |
| G34 | Demo route mounts writable admin screens | `admin_routes.dart:1283,1354,...` | Production always passes non-null auth source; reachable only in widget tests; external CI grep-assert backs it. |
| G35 | Demo audit fixture uses non-catalog action label `team.org_unit.move` | `demo_team_fixtures.dart:1242,1602` | Display-only audit string, never a gate. |
| G53 | Three slightly different ISO-date format helpers | `business_date_resolver.dart:73-76`; `sink_business_date_projector.dart:245-250`; `canonical_fact_to_closed_shift_input.dart:1337-1342` | Years always 4-digit in practice; consolidation candidate only. |
| G64 | No operator-web demo proxy-client analogue | `demo_vendor_integration_sync_proxy_client.dart:59-91` | Intentional; web demo parity via gateway swaps not transport swap; throws loudly on misuse. |

---

## 4. Tally

- Original substantive findings: 19 true gaps (G1–G19), 8 by-design (D1–D8), 1 undocumented (U1), 4 clean (C1–C4).
- After verification: 1 refuted (G15→fixed), 1 downgraded to smell (G8), 1 reclassified to by-design-documented (G12), 1 enlarged (G11).
- New: 17 true gaps (G23,G24,G30,G40-45,G50-52,G60-63,G65) + 10 by-design/minor (G20-22,G31-35,G53,G64).
- **Net open true gaps:** G1,G2,G3/G24,G4,G5,G6,G7,G8,G9,G10,G11,G13,G14,G16/G60,G17,G18,G19,G23,G30,G40,G41,G42,G43,G44,G45,G50,G51,G52,G61,G62,G63,G65.

---

## 5. G8 ff_support gate-site census (`lib/admin/admin_routes.dart`)

Pattern at every site: `final canEdit = session != null && session.roles.contains('super_admin');`
Active builders with the gate: **15** (lines 689, 998, 1055, 1100, 1182, 1234-1235, 1255, 1300, 1371, 1445, 1506, 1632, 1861, 2169, 2478). Legacy `// ignore: unused_element` (excluded): 803, 1952, 2269. MFA-fresh shared helper `_isAdminMfaFresh` (`:94-114`) feeds `:816-819,1636,1865,1963,2170-2176,2278-2281`. No active mutating builder is unguarded; proxy (HP #7) is the authoritative backstop.

---

## 6. G14 blended-wage side-by-side

| Aspect | Operator-Web `computeBlendedWageSummary` (`blended_wage_calculator.dart:106-145`) | Mobile `WageStandardContextService` (`wage_standard_context_service.dart:35-88,262-270`) |
|---|---|---|
| Precedence | none, single pass | 5-step waterfall (labor-derived → appConfigured → configFallback → unavailable) |
| Negative rate | **skips `hourlyRate<0`** | **keeps** negative rows in weighted sum |
| Completeness | emits partial; blended=null iff hours==0 | requires FOH+BOH both non-null else MeridianConfig fallback |
| Manager rows | own bucket badge | folded into reference blended only |
| Data source | in-flight draft rows | persisted SQLite rows |
| Zero hours | null number | degraded source enum |
| Provenance | none | `source` + `builtAt` |

Materially different blended numbers when a negative rate exists, only one bucket configured, or manager rows present.

---

## 7. G16/G60 operator-web write-idempotency census

Stable caller key (OK): all `WebTeamRoles/Users/Hierarchy/Sessions` + `WebSecurity` gateways (required `idempotencyKey` arg). Mobile `HttpSyncProxyClient` + admin gateways: stable.

No stable key (RISK — `OperatorWebProxyClient`-backed):
- `HttpWebAccountGateway.patchAccount` `web_account_gateway.dart:203-207` — HIGH (business-identity PATCH).
- `HttpWebAccountGateway.patchSelfProfile` `:245-249` — HIGH (email/name; email change forces sign-out).
- `HttpWebAccountGateway.patchLocationTimezone` `:221-225` — MED.
- `HttpWebAccountGateway.patchLocationAccountOverrides` `:280-284` — MED.
- `HttpWebAccountGateway.signOutOtherSessions` `:350-365` — MED.
- `HttpWebBusinessTimingGateway.createProfile/addServicePeriod` `web_business_timing_gateway.dart:114-150` — HIGH (duplicate timing profiles on retry).
- `HttpWebBusinessTimingGateway.updateProfile/updateServicePeriod` `:130-167` — MED (lost-update window).

---

## 8. Provenance

Audit produced by orchestrator-dispatched read-only agents 2026-05-16. No code modified.
Resumable agent IDs (line-level verifiers): auth `a4740f561359605ba`, permission `a377cb38c9a80eb7c`,
HP#11 `a0565187200d9aeb4`, shared-logic `afdcf3fb01dc86fa8`, transport `ab745309ccfb31e68`.
Cross-references: `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (plan Gaps 27-47),
CLAUDE.md Hard Promises #2/#7/#11, `docs/contracts/core_app_architecture.md`.
