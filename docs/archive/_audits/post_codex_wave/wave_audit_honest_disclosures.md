# Wave Audit — Honest Disclosure Tracking

**Master tip:** `63b67753` (merge of PR #635 — B8.b operator-web parity)
**Auditor:** read-only agent (6 of 8) — Honest-Disclosure Tracking dimension
**Date:** 2026-05-13
**Scope:** 70 PR audit docs + 8 cross-cutting / housekeeping docs under `docs/_audits/post_codex_wave/` (excluding `README.md` and `pr_476_smoke_run_evidence.txt`)

---

## Verdict

**Largely-honest with 5 untracked disclosures.** The wave's honest-disclosure doctrine held up well: ~90% of worker-disclosed deferrals, scope cuts, and known limitations are tracked in `docs/_indices/WAVE_EXECUTION_LEDGER.md`, `docs/POST_HARDENING_FOLLOWUPS.md`, or explicit operator-decision artifacts. The doctrine WORKS — disclosures surfaced, operators picked, follow-up rows opened.

However, **5 disclosures remain UNTRACKED** as of master tip `63b67753`. None are auth-critical or RLS-touching; the highest-severity untracked items are observability completeness (PR #635 demo-only HTTP wiring) and code-hygiene polish (PR #628 vendor display-name resolver). All are deferrable to a closeout housekeeping slice or fold-in candidates for `docs/POST_HARDENING_FOLLOWUPS.md` "Doc-Drift + Nits Batch."

Of the 6 known-deferred items the task brief asked me to verify, **all 6 are closed correctly**: B11.2 → B11.2.b (PR #586 ✓), B8 → B8.b (PR #635 ✓), B6 ceiling decompose (PR #634 ✓), C-2-D production binding (PR #633 ✓), C-1 → C-1b (intentional non-action, documented at `c_1_ecdsa_pubkey_gap_investigation.md`), L_A2's 5 forward-looking disclosures (all design-intentional and operator-pre-approved per Option α framing).

The one pre-existing test failure that's still on master and lacks a follow-up is **`admin_integrations_response_sanitization_test.dart`** — disclosed in PR #634 as "pre-existing, not introduced by this PR" but never added to `docs/KNOWN_FAILING_TESTS.md` and never investigated. This is the cleanest follow-up the closeout phase should pick up.

---

## Disclosure inventory

### Lane A — Code Health

| Slice / PR | Disclosure | Tracking surface | Status |
|---|---|---|---|
| A2.1 / #519 | (none — pure delete) | n/a | — |
| A2.2 / #540 | (none — clean operator-approved delete) | n/a | — |
| A3.1 / #533 | (none — read-only seam-map + lint addition) | n/a | — |
| A3.2 / #563 | 1 bare catch intentionally retained at line 2416 (`Platform.environment` swallow; `UnsupportedError` is an `Error` not `Exception`) | Audit doc inline rationale + line comment | **tracked (inline)** |
| A3.3 / #572 | 2 retentions at line 2426 + line 7024 (the latter explicitly owned by A11.1.b) | Audit doc + ledger row 47 (A11.1.b) | **tracked** |
| A3.4 / #581 | (a) self-disclosed `git stash` use during baseline cross-check; (b) master size-lint regression from B10.1; (c) 5 pre-existing test failures in `admin_cors_bootstrap_test.dart`; (d) B10.1 carry-forward bare-catch at line 14109 | (a) self-recovered; (b) closed by Bundle 33 ceiling raise 19,071 → 19,600; (c) closed by PR #588 (admin_cors_bootstrap_test snapshot fix); (d) closed by Bundle 33 typed catch | **all 4 tracked + all 4 closed** |
| A4.1 / #517 | (none — pure doc audit pass) | n/a | — |
| A4.2 / #552 | Pattern B drift (audit format) — 2nd occurrence | Audit doc P3 nit; reset on next compliant PR | **tracked (nit)** |
| A5+A8 / #527 | Grandfathered cutoff to B11.1's migration | Migration file + scanner constant `defaultExpandContractGrandfatherCutoff` | **tracked (in code)** |
| A6.1 / #498 | (none) | n/a | — |
| A7.1 / #526 | Worker installed canonical hooks during rebase; minor doc-hygiene drift not in scope | A10.1 followup PR #528 closed those it could | **tracked** |
| A9.1 / #530 | Worker's internal A9-F1 send-back catch (positive — not a deferral) | n/a | — |
| A10.1 / #523 | (a) Closure-registry assertion failures in `p3c_oauth_refresh_storm_runner_test.dart`; (b) 3 docs still cite `test/load/pressure/` paths (historical, not surfaced to runtime) | (a) `KNOWN_FAILING_TESTS.md` open row; (b) `wave_completion_deep_audit_2026_05_13.md` CC-4 + folded into POST_HARDENING_FOLLOWUPS "Doc-Drift + Nits Batch" P1 section | **both tracked** |
| A11.1 / #522 | Gauge wired but no consumer reads `snapshot()` / `totalIncrements()` — "in-memory observability buffer" only | Closed by A11.1.b PR #571 (ledger row 47) | **tracked + closed** |
| A11.1.b / #571 | (none — closes A11.1's gap) | n/a | — |
| A11.2 / #537 | GCS vs Azure Blob backend choice — operator decision deferred | `docs/POST_HARDENING_FOLLOWUPS.md` P1 section "Soak Heap-Snapshot Uploader: swap GCS → Azure Blob (A11.2 follow-up)" with binding constraint that env vars stay unset | **tracked** |
| L_A1 / #608 | (none — operator-approved Option 1 no-migration framing) | n/a | — |
| L_A2 / #616 | **5 forward-looking disclosures**: (a) per-pod posture (`invalidate()` is local-only); (b) no call-site wiring (B6/B8 own `invalidate()` calls); (c) no observability surface yet (`statsSnapshot()` not in /health); (d) successful empty lists ARE cached; (e) default OFF | All 5 are operator-pre-approved per Option α framing at L_A1 merge ("performance projection, not structural prereq"); (b) closed by B6 PR #634 + B8 PR #624 consumers; (c) is deferred-forever per "future slice if/when operationally needed"; (d)+(e) are pinned by tests, not deferrals | **all 5 tracked (design-intentional)** |

### Lane B — Features

| Slice / PR | Disclosure | Tracking surface | Status |
|---|---|---|---|
| B1.a / #501 | Planning ambiguity (slice doc gate vs. copy) | Operator-decision Option 1 chosen; orchestrator-fix PR #501 follow-up applied | **tracked + closed** |
| B1.b / #500 | Peer-bug `B1.c` candidate at `proxy_bootstrap.dart:4015` (pricing-tier admin gateway) | B1.c ledger row 57 + PR #561 closed it | **tracked + closed** |
| B1.c / #561 | (a) Pattern B drift (3rd Claude lane occurrence); (b) minor `dart analyze` disclosure gap | (a) P1 finding in audit — prompt-drift remediated via fresh-Claude-lane handoff prompt update + counter reset; (b) P3 nit | **tracked (process)** |
| B2.1 / #584 | Bleed-stop overshoot 19,628 / 19,600 | Closed in same orchestrator bundle (ceiling raise 19,600 → 19,700) | **tracked + closed** |
| B2.2 / #590 | 2 honest gaps: (a) blast-radius numeric counts; (b) per-role `catalog_published_at` annotation | (a) B2.3 ledger row 72 + PR #603 closed; (b) B2.4 ledger row 73 + PR #609 closed | **both tracked + closed** |
| B2.3 / #603 | (a) 5 pre-existing test failures in `test/proxy/`; (b) `user_count` caveat (no soft-delete on `public.users`) | (a) 3 of 5 closed by PR #610 (audit_chain_anchors_routes + 2 registry_proxy_health_check_store snapshots), 1 by PR #625 (auth_location_integrations), 1 (`admin_integrations_response_sanitization_test`) still on master per PR #634 disclosure — **UNTRACKED**; (b) dartdoc inline note + closeout-phase observation | **(a) partially tracked; 1 UNTRACKED** + (b) tracked-in-code |
| B2.4 / #609 | (none — clean closure of Gap 2) | n/a | — |
| B3 / #502 | "Rejects role_key" wording loose vs. actual "requires role_id, ignores role_key" mechanism | Audit doc inline observation | **tracked (informational)** |
| B4 / #513 | (none) | n/a | — |
| B5 / #557 | Permission-key completeness half deferred (frozen `lib/auth/**` touch) | B5.b ledger row 63 + PR #573 closed | **tracked + closed** |
| B5.b / #573 | (none — closes B5's deferred half) | n/a | — |
| B6 / #630 (held) → #634 | (a) Ceiling breach 19,961 / 19,900 (61-line overage); (b) wider blast radius on `proxy_bootstrap.dart` refactor | (a) Operator picked option (a) decompose → PR #634 closed (ceiling preserved 88 headroom); (b) decompose mirrors B8 pattern verbatim | **tracked + closed** |
| B7.a / #507 | Audit event rename `auth.invite_revoked` → `invite.cancel` creates consumer drift at 3 sites | Orchestrator-fix Option A applied (consumer label switches updated for both names) | **tracked + closed** |
| B8 / #624 | **6 forward-looking deferrals**: (1) B8.b operator-web parity deferred; (2) operator-web hierarchy route not shipped; (3) L_A2 cache bypassed (Option b per L_A1 framing); (4) per-pod latency recorder only; (5) no CSV export; (6) InheritanceTree picker opt-in (needs OrgUnits gateway slice) | (1) B8.b ledger row 67 + PR #635 closed; (2) closed by (1); (3) operator-aligned design pick (L_A1 framing); (4)–(6) **UNTRACKED** as future enhancements | **2 tracked + closed; 1 design-intentional; 3 UNTRACKED** |
| B8.b / #635 | "Live HTTP wiring is a small follow-up (1 mixin import + gateway construction on Firebase auth source) — non-blocking; pane renders in demo today" | **UNTRACKED** — no new ledger row, no POST_HARDENING entry | **UNTRACKED** |
| B9.1 / #510 | (none) | n/a | — |
| B9.2 / #547 | Server-side step-up enforcement on `/v1/auth/session/revoke` deferred; operator approved conditional on B11.2 planned | B11.2 ledger row 75 + closed by B11.2.b PR #586 (incl. clock-skew P1 fix) | **tracked + closed** |
| B9.3 / #568 | Client-side clock-skew handling complements B11.2.b server-side fix | B11.2.b ledger row 76 acknowledged; cross-lane note explicit | **tracked + closed** |
| B10.1 / #576 | (a) Codex worker hit advisor_proxy ceiling without raising it; (b) audit miss on operator-leading split index F2 fix | (a) Closed by Bundle 33 ceiling raise + B10.1 carry-forward bare-catch typed; (b) F2 fix applied | **tracked + closed** |
| B10.2 / #594 | (none — closes B10.1's operator-web binding) | n/a | — |
| B11.1 / #512 | (a) In-memory idempotency store divergent from `proxy_requests` convention; (b) `forge_admin` DELETE grant inconsistent with "read for ops visibility" comment | (a) `POST_HARDENING_FOLLOWUPS.md` P1 "B11.1 Idempotency-Store Convention" section (full follow-up scope spelled out); (b) `wave_completion_deep_audit_2026_05_13.md` P2 item folded into "Doc-Drift + Nits Batch" section | **both tracked** |
| B11.2 / #550 | **3 explicit deferrals**: (1) per-route wiring into proxy handlers; (2) client-side adapter (`fresh_mfa_resolver.dart`, `mfa_freshness_redirect_listener.dart`, new `step_up_challenge_handler.dart`); (3) Postgres-backed `StepUpChallengesGateway` impl | All 3 closed by B11.2.b ledger row 76 + PR #586 (Build-Toward-Production: schema + wiring + Postgres binding + client adapter in 1 PR) | **tracked + closed** |
| B11.2.b / #586 | 20 sensitive routes vs ledger's 14 estimate (better-than-estimated, fully transparent) | Audit doc transparency; no follow-up needed | **tracked (informational)** |

### Lane C — Cross-Surface Parity

| Slice / PR | Disclosure | Tracking surface | Status |
|---|---|---|---|
| C-1a / #599 | (a) Pre-existing runbook count drift recovered; (b) possible C-1b need (ECDSA pubkey column on `email_credentials`) | (a) recovered in PR diff; (b) `c_1_ecdsa_pubkey_gap_investigation.md` (read-only investigation; verdict: **c-1b-not-required** per Hard Promise #7 env-var-first posture) | **both tracked** |
| C-1 / #611 | 3 honest disclosures: (a) `email_credentials.sendgrid_event_webhook_pubkey_pem` column deferred to conditional C-1b; (b) no `audit_logs` writes by design; (c) pubkey loader per-request for rotation-without-restart | (a) `c_1_ecdsa_pubkey_gap_investigation.md` documents env-var-first as V1 launch posture per HP #7; (b)+(c) design intent documented inline | **all 3 tracked (design-intentional)** |
| C-2 / #617 | 5 stop-and-disclosed drafts (C/D/E/F/G) requiring operator architectural decisions | `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md` recorded operator picks; new ledger rows for each pick (C-2-C, C-2-D, C-2-F, C-2-Del) | **tracked + all closed** |
| C-2-C / #629 | (a) Removal-only sub-path (server-side enrollment hook deferred); (b) `accountSecurityUrl` hardcoded for V1 (future per-flavor parameterization) | (a) Slice notes in ledger row 86 mention "server-side enrollment hook deferred" inline but **NO follow-up row or POST_HARDENING entry**; (b) audit doc inline note only — **UNTRACKED** for closeout | **(a) partially tracked (slice notes); (b) UNTRACKED** |
| C-2-D / #631 | "Production runtime binding NOT shipped in this slice" — observer defaults to null | C-2-D-binding ledger row 88 + PR #633 closed | **tracked + closed** |
| C-2-D-binding / #633 | (none — closes C-2-D's production wire deferral) | n/a | — |
| C-2-F / #628 | (a) ~715 LoC prod vs ~400 LoC matrix estimate; (b) vendor display-name resolver returns raw vendor id today (renders `lightspeed_lsk` instead of `Lightspeed`) | (a) Honest LoC disclosure pinned in PR body + audit doc; (b) Audit doc inline note only ("future hoist via shared registry") — **UNTRACKED** | **(a) tracked (informational); (b) UNTRACKED** |
| C-2-Del / #627 | (none — clean delete pair) | n/a | — |
| C-3 / #579 | (none — -1196 net LoC delete) | n/a | — |
| C-4 / #592 | Bleed-stop overshoot 19,808 / 19,700 (108 over) | Closed in same orchestrator bundle (ceiling raise 19,700 → 19,900); HP #2 doctrine expansion (3 → 4 carve-outs) was specced by ledger row 81 | **tracked + closed** |
| C-5 / #600 | Cross-lane B11.2.b test failure disclosed (wall-clock time bomb) | Background investigation agent spawned → PR #604 fixed the test fake | **tracked + closed** |
| C-6 / #622 | (none) | n/a | — |
| C-7 / #636 | (adaptive 2FA button; no major disclosures in audit doc) | n/a | — |
| C-7a / #626 | Three minor non-blocking disclosures: pre-existing POST_HARDENING count drift, stale numbered list in runbook, mid-flight rebase | All cosmetic and recovered in PR | **tracked** |
| C-8 / #499 | Default-state fallback to `available` for unknown catalog entries | `wave_completion_deep_audit_2026_05_13.md` P2 C-8-1 + folded into POST_HARDENING_FOLLOWUPS "Doc-Drift + Nits Batch" P1 section | **tracked** |
| C-9 / #580 | (none) | n/a | — |
| C-10 / #556 | (none) | n/a | — |
| C-11 / #620 | **5 forward-looking disclosures**: (a) Mailosaur not wired (operator owed env-vars in preview CI); (b) Patrol not in pubspec (operator decides priority); (c) 4 wired SendGrid surfaces not self-driveable from harness; (d) R4 reference doc not findable in slice specs (doc-hygiene gap); (e) PROXY_URL allowlist enforced | (a)+(b) operator action items in ledger row 98 ("Operator owed"); (c)+(e) design intent (acceptable per worker contract); (d) doc-hygiene noted but **UNTRACKED** for separate follow-up | **4 tracked; 1 UNTRACKED** |
| C-12 / TBD | (orchestrator closeout — not yet spawned) | n/a | — |

### Cross-cutting / Housekeeping audit docs

| Doc | Disclosure | Tracking surface | Status |
|---|---|---|---|
| `wave_completion_deep_audit_2026_05_13.md` | 5 P1 findings (B1.c, A11.1 gauge, B9.2 clock-skew, B9.2 server-side step-up, B11.1 idempotency-store convention) + 4 P2 + 2 P3 | B1.c → PR #561; A11.1 → PR #571 (A11.1.b); B9.2 clock-skew + step-up → PR #586 (B11.2.b); B11.1 idempotency → POST_HARDENING P1 section; P2/P3 → POST_HARDENING "Doc-Drift + Nits Batch" P1 section | **5 P1 closed; 4 P2 + 2 P3 tracked in ledger doc** |
| `orchestrator_bundle_33_b10_1_fallout.md` | (closes B10.1 fallout) | (orchestrator-owned bundle) | **closed** |
| `final_housekeeping_sweep_2026_05_13.md` | (stages repo for Claude lane restart) | (orchestrator-owned bundle) | **closed** |
| `followups_doc_drift_cleanup_2026_05_13.md` | (3 mechanical doc-drift fixes to POST_HARDENING_FOLLOWUPS) | (orchestrator-owned bundle) | **closed** |
| `c_1_ecdsa_pubkey_gap_investigation.md` | Read-only investigation; verdict: c-1b-not-required | `docs/archive/_audits/post_codex_wave_2026-05-13/c_1_ecdsa_pubkey_gap_investigation.md:130-139` (verdict + recommendation) + ledger row 83 unchanged | **tracked (operator-decision)** |
| `pr_476_b1_b2_audit.md`, `pr_481/482/484/488/490/495_audit.md`, `pr_b_pr_a_rollup_audit.md`, `pr_473_b3_retroactive_audit.md` | Pre-wave retroactive audits — closed via Phase 5b orchestrator-fix and re-audit | All resolved per audit doc verdict lines | **tracked + closed** |
| `test_proxy_5_failures_investigation.md` | (companion to PRs #588, #604, #610, #625 — fixes for stale-snapshot tests) | (housekeeping investigation) | **tracked** |
| `pr_588`, `pr_604`, `pr_610`, `pr_625_*_audit.md` | (test snapshot / time-bomb fixes — no further disclosures) | (test housekeeping) | **closed** |

---

## Untracked disclosures (findings)

### Finding U-1 — `admin_integrations_response_sanitization_test.dart` pre-existing failure (P2)

**Slice / Audit doc:** PR #634 (B6 benchmark overrides decompose) line 58: *"Pre-existing failure on `admin_integrations_response_sanitization_test` verified on clean master (NOT introduced)"*.

**Status on master `63b67753`:** still failing per PR #634 disclosure; **not in `docs/KNOWN_FAILING_TESTS.md`** (only the `p3c_oauth_refresh_storm_runner_test.dart` closure-registry drift entry is listed); not in any follow-up ledger row.

**Authority anchor:** `docs/KNOWN_FAILING_TESTS.md` discipline ("Codex maintains this file. Add an entry when verification confirms a failure is pre-existing on clean HEAD").

**Recommendation for closeout (C-12) phase:**
- (a) Reproduce on clean master; if fails, add an entry to `KNOWN_FAILING_TESTS.md` with file:line + investigation notes (mirror PR #588's pattern).
- (b) If quick-fixable (likely a stale-snapshot pattern like PR #588/#610/#625), file a 1-PR test-only fix slice (Mirror PR #625 shape verbatim).

**Severity:** P2 (test discipline; not a regression, not blocking master, but breaks the "Codex maintains this file" rule).

### Finding U-2 — B8.b live HTTP wiring on Firebase auth source (P3)

**Slice / Audit doc:** PR #635 (B8.b operator-web parity) audit doc line 76: *"Live HTTP wiring on the Firebase auth source remains a small follow-up (1 mixin import + 1 constructor call) and is non-blocking — the existing pane renders against in-memory data on unmixed sources."*

**Status on master `63b67753`:** pane renders in demo mode only; live operators won't see the hierarchy filter until the Firebase auth source mixes in `OperatorWebAuditLogHierarchyGatewayProvider`. **No follow-up ledger row, no POST_HARDENING entry.**

**Authority anchor:** Hard Promise #10 — *"Every backend phase ships operator-facing UX before phase close."* B8 + B8.b are technically the backend + operator-web shipment but live wiring is the actual operator-facing surface.

**Recommendation for closeout (C-12) phase:**
- File a tiny ledger row `B8.c` (Small / Low / auto, 1 mixin import + 1 constructor call per audit doc line 76).
- Verify on staging that live operators can access the hierarchy filter pane post-wire.

**Severity:** P3 (operator-facing gap, but minimal LoC; arguably already covered by C-12 closeout if it sweeps "follow-ups in audit docs").

### Finding U-3 — C-2-F vendor display-name resolver returns raw vendor id (P3)

**Slice / Audit doc:** PR #628 (C-2-F `vendor_connection_auto_disabled` wire) audit doc line 126: *"vendor display-name resolver returns `null` today (renders raw vendor id like `lightspeed_lsk` instead of `Lightspeed`); a follow-up slice can hoist a shared display-name registry without changing this dispatcher's signature. Worker explicitly disclosed this in the dispatcher inline comment."*

**Status on master `63b67753`:** raw vendor id rendered in `vendor_connection_auto_disabled` email body; `Grep` returns 0 matches for "vendor display name resolver" outside the audit doc itself. **No follow-up ledger row, no POST_HARDENING entry.**

**Authority anchor:** Project UX writing standard (`memory/project_ux_writing_standard.md`) — "Operator-facing copy reads as training; plain English; no engineering jargon." `lightspeed_lsk` is engineering jargon; `Lightspeed` is plain English.

**Recommendation for closeout (C-12) phase:**
- File a `C-2-F-display` ledger row (Small / Low / auto) — hoist a `lib/integrations/ui/vendor_display_name_registry.dart` lookup table; dispatcher signature stays stable.
- Alternatively, fold into POST_HARDENING_FOLLOWUPS "Doc-Drift + Nits Batch" P1 section if no slice picks it up.

**Severity:** P3 (cosmetic but operator-visible — affects every auto-disable email).

### Finding U-4 — C-2-C `accountSecurityUrl` hardcoded for V1 (P3)

**Slice / Audit doc:** PR #629 (C-2-C `mfa_factor_changed_notice` wire) audit doc lines 105, 128-132: *"`accountSecurityUrl` hardcoded; if F&F operator-web ever splits into per-flavor entries (e.g. Barrio rebrand), this URL needs a config seam. Worker disclosed inline."*

**Status on master `63b67753`:** URL pinned at slice-bound constant; per-flavor parameterization deferred. **No follow-up ledger row, no POST_HARDENING entry.**

**Authority anchor:** Flavor split contract (`lib/main_forgeflow.dart` vs `lib/main_barrio.dart`) + project_v1_launch_decisions_2026_05_03 (V1 ships forgeflow-only; Barrio is paused per project_barrio_paused.md).

**Recommendation for closeout (C-12) phase:**
- Defer per `project_barrio_paused.md` — Barrio is paused so flavor split is not on the V1 critical path.
- Worth a single-line entry under POST_HARDENING_FOLLOWUPS "Doc-Drift + Nits Batch" or a "Barrio-resume prerequisites" section so it's recoverable when Barrio resumes.

**Severity:** P3 (latent; only activates if Barrio resumes).

### Finding U-5 — B8 forward-looking deferrals 4-6 (P3 each)

**Slice / Audit doc:** PR #624 (B8 audit log hierarchy filter) lines 24-26 — three additional forward-looking deferrals not addressed by the B8.b ledger row:

1. **Per-pod latency recorder only** (cross-pod aggregation = future slice)
2. **No CSV export on admin screen**
3. **InheritanceTree picker is opt-in** (admin shell needs OrgUnits gateway slice for `rootNode` feed)

**Status on master `63b67753`:** B8.b ledger row only addresses items 1-3 of the disclosure list (operator-web parity, hierarchy route, L_A2 framing). Items 4-6 are **UNTRACKED**.

**Authority anchor:** B8 audit doc lines 24-26.

**Recommendation for closeout (C-12) phase:**
- Items 4-5 (cross-pod aggregation, CSV export): operator-decision required — defer to V1+1 or scope into a new lane B follow-up depending on operator priority.
- Item 6 (InheritanceTree picker for admin shell): blocks on a separate `OrgUnitsGateway` slice (cross-lane); file as a tracking dependency in POST_HARDENING_FOLLOWUPS.
- Alternatively, fold all 3 into POST_HARDENING_FOLLOWUPS "Doc-Drift + Nits Batch" P1 section.

**Severity:** P3 each (3 items; admin observability + admin UX polish — not blocking V1 launch).

---

## Pre-existing test failures status

The wave doctrine treats "verified on clean master pre-PR" disclosures as honest (not regressions). Here's the per-test status as of master tip `63b67753`:

| Test file | Discovered in PR | Status | Where fixed | Follow-up needed? |
|---|---|---|---|---|
| `test/proxy/admin_cors_bootstrap_test.dart` (`FeatureFlagsTableAdminCorsOriginsExtraFlag — query shape`) | A3.4 / #581 disclosure | **FIXED** | PR #588 (snapshot fix mirroring production `feature_flag_system_wide_operator_id()` SQL contract) | No |
| `test/proxy/audit_chain_anchors_routes_test.dart:216` ("rejects a token without operator scope with 403") | B2.3 / #603 disclosure | **FIXED** | PR #610 (role label swap `super_admin` → `operator_owner`) | No |
| `test/proxy/registry_proxy_health_check_store_test.dart:217` ("AGE thrown error projects ageOk → false") | B2.3 / #603 disclosure | **FIXED** | PR #610 (`StateError` → `Exception` per A3.3's narrowing) | No |
| `test/proxy/registry_proxy_health_check_store_test.dart:239` ("pgvector distance error projects pgvectorOk → false") | B2.3 / #603 disclosure | **FIXED** | PR #610 (`StateError` → `Exception` per A3.3's narrowing) | No |
| `test/proxy/b11_2_b_step_up_wiring_test.dart:175` ("valid presented Step-Up-Challenge-Id HEADER admits the request") | C-5 / #600 cross-lane disclosure | **FIXED** | PR #604 (wall-clock time-bomb fix in `_RecordingStepUpGateway` test fake — constructor injection of `now`) | No |
| `test/proxy/auth_location_integrations_route_test.dart:488` (FormatException from `_failingProjection()` StateError) | A3.3 fallout (PR #572) | **FIXED** | PR #625 (`StateError('boom')` → `Exception('boom')` mirroring PR #610 verbatim) | No |
| `test/tool/advisor_proxy/admin_integrations_response_sanitization_test.dart` | B6 decompose / #634 disclosure | **STILL FAILING ON MASTER** per PR #634 audit line 58 | NOT YET FIXED | **YES — Finding U-1 above** |
| `test/pressure/p3c_oauth_refresh_storm_runner_test.dart` (closure registry drift, 2 cases) | A10.1 / #523 disclosure | **STILL FAILING ON MASTER** | NOT YET FIXED | **TRACKED** in `docs/KNOWN_FAILING_TESTS.md` open row (acceptable per A10.1 scope discipline) |

**Aggregate**: 6 of 7 pre-existing failures were closed by housekeeping PRs (#588, #604, #610, #625). 1 (`admin_integrations_response_sanitization_test`) remains on master without a follow-up — this is **Finding U-1**. 1 additional drift (`p3c_oauth_refresh_storm_runner_test`) is tracked in `KNOWN_FAILING_TESTS.md` as expected pre-existing per A10.1 worker scope discipline.

---

## Aggregate metrics

**Inventory total**: 70 PR audit docs reviewed + 8 cross-cutting docs (78 docs).

**Disclosures extracted by category**:
- Total disclosures across all PRs: **~58 distinct disclosures** (some PRs have multiple; some have none)
- **Tracked in `WAVE_EXECUTION_LEDGER.md`** (new ledger row): **15** (A11.1.b, B1.c, B2.3, B2.4, B5.b, B8.b, B11.2.b, C-1a, C-2-C, C-2-D, C-2-F, C-2-Del, C-2-D-binding, C-7a, plus L_A1 + L_A2 which are prerequisites not pure follow-ups)
- **Tracked in `POST_HARDENING_FOLLOWUPS.md`**: **5 sections** (B11.1 idempotency-store convention, A11.2 GCS→Azure swap, A10.1 doc-drift, B9.2 freshness-window catalog folded into "Doc-Drift + Nits Batch", C-8 default-state fallback folded into "Doc-Drift + Nits Batch")
- **Tracked elsewhere with explicit citation**: **6** (C-1b in `c_1_ecdsa_pubkey_gap_investigation.md`; C-2 operator picks in `c_2_email_template_wire_or_delete_decisions.md`; B6 ceiling resolution in `orchestrator_bundle_33_b10_1_fallout.md`; pre-existing test fixes in PRs #588 #604 #610 #625; A3.4 retentions in inline comments; B11.2.b "20 routes vs 14 estimate" in audit doc)
- **Operator-decision documented**: **8** (B1.a Option 1 copy fix; B5.b approval; B6 path (a) decompose; B8 path (a) accept B8.b deferral; B11.2 Option A scaffold + B11.2.b wiring; C-2 operator picks C/D/F WIRE + E/G DELETE; C-7a approval; HP #2 4th carve-out doctrine expansion)

**Untracked disclosures (FINDINGS)**: **5**
- U-1: `admin_integrations_response_sanitization_test` pre-existing failure (P2)
- U-2: B8.b live HTTP wiring on Firebase auth source (P3)
- U-3: C-2-F vendor display-name resolver returns raw vendor id (P3)
- U-4: C-2-C `accountSecurityUrl` hardcoded for V1 (P3)
- U-5: B8 forward-looking deferrals 4-6 (P3 each = 3 items)

**Tracking rate**: ~58/63 = **~92% of disclosures are tracked** in at least one of the four canonical surfaces (ledger / POST_HARDENING / explicit citation / operator-decision artifact). 8% untracked, all P2 or P3 severity, none auth/RLS/schema/proxy-critical.

**Doctrine assessment**: the wave's honest-disclosure doctrine **holds up under retrospective audit**. Workers reliably disclosed deferrals, scope cuts, and known limitations in PR bodies; orchestrator audit docs reliably captured those disclosures and routed them to follow-up ledger rows or POST_HARDENING entries. The 5 untracked items are all low-severity, mostly fold-in candidates for the POST_HARDENING "Doc-Drift + Nits Batch" P1 section that's already established for this category of work.

---

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` (master tip `63b67753`, 202 lines, 61 slices total) — primary tracking surface
- `docs/POST_HARDENING_FOLLOWUPS.md` (631 lines) — secondary tracking surface
- `docs/KNOWN_FAILING_TESTS.md` (1 open row at master tip) — pre-existing test failure quarantine
- `docs/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` — sibling deep audit (5 P1 + 4 P2 + 2 P3 — all tracked correctly)
- `docs/archive/_audits/post_codex_wave_2026-05-13/c_1_ecdsa_pubkey_gap_investigation.md` — operator-decision artifact pattern
- `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md` — operator-pick matrix pattern
- `docs/archive/_audits/post_codex_wave_2026-05-13/orchestrator_bundle_33_b10_1_fallout.md` — orchestrator-bundle housekeeping pattern
- `CLAUDE.md` "Hard Promises" #7 (server-side keys) + #10 (operator-facing UX before phase close) + addendum C4 (no silent failures)
- `~/.claude/projects/.../memory/feedback_followups_doc_hygiene.md` — ledger-first discipline ("ledger first, followups doc second; if an audit finding has a clear next-slice home, fold into the ledger row's scope")
- `~/.claude/projects/.../memory/feedback_audit_plan_status_flips.md` — audit doc status flip discipline (deep audit finding #1 → RESOLVED 2026-05-13 by B1.c banner pattern)

---

## Summary recommendation for C-12 closeout

1. **Add Finding U-1** (`admin_integrations_response_sanitization_test`) to `docs/KNOWN_FAILING_TESTS.md` or file a 1-PR test-only fix (mirror PR #625 verbatim).
2. **Fold Findings U-2, U-3, U-5** into `docs/POST_HARDENING_FOLLOWUPS.md` "Doc-Drift + Nits Batch" P1 section (or create a "Wave Closeout Residuals" section if a separate heading is preferred).
3. **Defer Finding U-4** to a "Barrio-resume prerequisites" placeholder in POST_HARDENING_FOLLOWUPS — flavor-split parameterization only activates if/when Barrio resumes per `project_barrio_paused.md`.
4. **Confirm `admin_integrations_response_sanitization_test` reproducibility on clean master** before closeout — if it's a flake rather than a stable failure, the right action may be quarantine instead of fix.

No P0 or P1 disclosures are untracked. The wave is closeout-ready from an honest-disclosure-tracking standpoint.
