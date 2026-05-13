# Post-Codex Wave — Closeout Checklist (DRAFT)

**Status:** Draft. Read-only launchpad for the wave-finish → visual-test → doc-audit → close-out → refactor-handoff sequence operator approved 2026-05-13.

**Wave snapshot:** Master tip `7d05ea32`. **46 / 54 slices merged** (was 40 at draft time `a129987a`). Watcher loop running on 5-min ticks. Last refresh: 2026-05-13 after Bundle 45 (#608 L_A1, #609 B2.4, #610 test-proxy fix, #611 C-1).

---

## 1. What's left in the wave (8 slices)

### Claude lane (4)
- **L_A2** — Descendant-set cache (Medium, operator, dep `L_A1 merged ✓`) — **in-flight (parallel Claude lane session 2026-05-13)**
- **B8** — Audit log hierarchy filter (Medium, operator, dep `L_A2 merged`)
- **C-2** — Wire-or-delete 6 email templates (Medium, operator, dep `C-1 merged ✓`) — **in-flight (parallel Claude lane session 2026-05-13)**
- **C-11** — Pressure-test inventory under preview (Medium, operator, dep `C-2 merged`)

### Codex lane (3)
- **B6** — Benchmark override (Medium, operator, dep `B10.1 merged ✓`) — Codex idle report 2026-05-13 morning had paused on `L_A1 / L_A2 / L_A3` per the slice doc + plumbing matrix; L_A1 now merged ✓; L_A2 in-flight. Re-evaluate once L_A2 lands.
- **C-6** — Inheritance Tree shared component consumer (Medium, auto, dep `L_A2 merged`) — dep updated 2026-05-13 from `B1.a merged` → `L_A2 merged` (PR #607). Operator-confirmed.
- **C-7** — Adaptive 2FA button (Small, auto, dep `B9.2 merged ✓`) — **escalated 2026-05-13 by Codex**: slice spec requires `mfa_factors.recovery_codes_viewed_at` column but `git grep` finds it only in docs, not in schema/model/gateway. **Operator decision pending on a C-7a prep migration** (additive `ADD COLUMN IF NOT EXISTS mfa_factors.recovery_codes_viewed_at timestamptz NULL` — mirrors C-1a → C-1 pattern). Until then C-7 is genuinely blocked, not just queued.

### Orchestrator (1)
- **C-12** — Final lane-C integration audit (Small, auto, dep `all C-* merged`)

**In-flight right now:** L_A2 + C-2 (Claude lane parallel session). **Dep-blocked:** B6 (post-L_A2), B8 (post-L_A2), C-6 (post-L_A2), C-11 (post-C-2), C-12 (post-all-C). **Data-contract-blocked:** C-7 (needs C-7a operator decision).

---

## 2. Visual-test surface map (operator drives)

Per operator 2026-05-13 plan: "visually test and audit fully against docs" between wave finish and closeout.

| Surface | Slices that touched it | Walkthrough notes |
|---|---|---|
| **Mobile — Settings → Data tab** | C-4 (demo→live switch) | Toggle Demo→Live one-way; confirm dialog; verify Live→Demo refused with operator-readable copy ("live data has arrived; demo mode cannot be restored") |
| **Mobile — auth flow** | B11.2.b (step-up dialogs) — universal on 20 sensitive routes; C-7 mobile parity (in-flight) | Once C-7 lands: trigger step-up on a sensitive route, verify fresh `auth_time` prompt + clock-skew ±60s grace |
| **Admin Console — Default Role Catalog** | B2.1 (backend), B2.2 (admin editor), B2.3 (blast-radius endpoint), B2.4 (per-row date annotation) | Three-region page (current/history/draft); double-confirm publish dialog with type-confirm-by-version; **B2.3 (PR #603)** swapped in live numerics — "Affecting N businesses, M locations, P users currently following version X"; plain-English fallback preserved for error/zero/genesis states |
| **Admin Console — Vendor Applicability** | B10.1 (backend), B10.2 (admin editor) | Per-`setting_kind` tabs (wage/covers/polling); vendor table with enable + effective dates + metadata JSON; required reason + idempotency-key per write; temporal end/replace only |
| **Operator-web — Roles screen** | B2.2 (Default badge), B2.4 (per-row date annotation) | Verify badge on `is_seeded=true` rows only; "Seeded" → "Default" rename consistent. **B2.4 (PR #609)** shipped the "Updated by F&F on Mon D, YYYY" annotation; non-seeded rows + null-date rows fall back to "Managed by Forge & Flow" verbatim |
| **Operator-web — My Account → Security** | C-3 (sign-in security fold) | Verify `SecurityScreen` is gone; 3 redirect routes work (`/security`, `/sign-in-security`, `/operator-web/sign-in-security`); recent sign-in activity rendered inline |
| **Operator-web — Data Accuracy → Wage Source** | B10.2 (live wage authority binding) | Picker reads `vendor_applicability` filtered to `enabled=true AND effective_until IS NULL`; disables vendor source with operator-readable copy when no current wage vendor enabled |
| **Mobile — Inbox / Notifications** | C-9 (catalog-backed rendering) | `eventKey` resolution preferred over legacy `type`; safe TOS fallback copy; mobile stays read-only (no preference switches) |
| **Mobile — Pointer rows → Operator Web handoff** | C-5 (PR #600, mobile pointer deep-link redemption) | Settings pointer rows mint B11.1 short-TTL opaque handoff codes via `HandoffCodeClient`; launch `https://app.forgeflow.app/handoff?code=...&nav=...`; verify body-only redeem (`POST /v1/auth/handoff/redeem`); fallback to clipboard for offline / proxy-5xx / launchUrl failure with plain-English snackbar |
| **Server-only — SendGrid Event Webhook** | C-1 (PR #611) | Server-to-server route, no operator UI surface. **Operator action for deploy:** wire `SENDGRID_EVENT_WEBHOOK_PUBKEY_PEM` in Cloud Run env. Until set, route returns 503 `pubkey_not_configured` (SendGrid retries 5xx upstream — events queue until secret lands). |

---

## 3. Doc audit checklist (verify wave delta against contracts)

Use `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`.

### Hard Promises (HP #1–11)

- [ ] **HP #1** — Phase 8 = pure transport swap; no new app logic. *Wave touched: nothing under Phase 8 vendor adapters.* ✓ expected clean.
- [ ] **HP #2** — Demo mode persists; `kDemoMode` writer-side switch. **Doctrine extended this wave (3 → 4 carve-outs)** via C-4 (PR #592). Verify CLAUDE.md + `docs/contracts/demo_mode_contract.md` updates match the runtime implementation.
- [ ] **HP #3** — No app logic changes before `7.58`. *Wave touched: nothing under `7.55–7.57` logic boundaries.* ✓ expected clean.
- [ ] **HP #4** — Per-operator isolation non-negotiable. **Wave added 3 operator-scoped repositories** (`StepUpChallengesRepository` B11.2.b, `DefaultRoleCatalogVersionsRepository` B2.1, `DemoModeStateRepository` C-4) + B10.1 schema. Verify operator-leading B-tree indexes + RLS via wrapper functions everywhere.
- [ ] **HP #5** — AGE infra; Advisor `11b` Contextual Retrieval. *Wave touched: nothing in AGE/advisor.* ✓ expected clean.
- [ ] **HP #6** — Advisor speaks in recommendations, not commands. *Wave touched: nothing advisor-facing.* ✓ expected clean.
- [ ] **HP #7** — F&F holds all provider keys server-side. *Wave touched: nothing BYO-key.* ✓ expected clean.
- [ ] **HP #8** — AI infrastructure general-purpose. *Wave touched: nothing AI-infra-specific.* ✓ expected clean.
- [ ] **HP #9** — AI cost metered by class. *Wave touched: nothing in `usage_caps`.* ✓ expected clean.
- [ ] **HP #10** — Every backend phase ships operator-facing UX. **Wave shipped 7 operator-facing surfaces** (table above). Verify each has Frontend Exposure section in its source doc.
- [ ] **HP #11** — Hierarchy-scoped settings mandatory. **B10.2** wires hierarchy-scoped wage source; **L_A1 (PR #608)** delivered the Inheritance Tree primitive (`InheritanceTreeNode` value class + shared `InheritanceTree` visualization widget + 3 read methods on `OrgUnitsRepository`); **L_A2 in-flight + B8 queued** to finish the hierarchy filter chain. Verify settings surfaces show selected scope + inherited source + effective value.

### Doctrine docs touched this wave

- [ ] **CLAUDE.md** — HP #2 carve-outs list extended 3 → 4 (PR #592, Bundle 38). Verify Section "Demo Mode" reads consistently.
- [ ] **docs/contracts/demo_mode_contract.md** — header "two intentional" → "four intentional"; full Carve-out #4 section added. Verify cross-refs from CLAUDE.md and back are consistent.
- [ ] **docs/contracts/auth_permission_key_catalog.md** — B5.b added 2 new permission keys (`account.configure`, `business_timing.configure`). Verify tri-mirror still aligns: catalog ↔ `lib/auth/permission_keys.dart` ↔ migration `202605131500_b5_b_catalog_tri_mirror.sql`.
- [ ] **docs/contracts/hardening_rls_and_repository_pattern_contract.md** — verify the 3 new operator-scoped repositories (StepUp, DefaultRoleCatalog, DemoModeState) match the contract's `OperatorScopedRepository<T>` shape + `withTenant`/`withSystem` posture.
- [ ] **docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md** — item 4 (operator-leading partial unique index) cited by admin_cors_bootstrap_test fix (PR #588). Verify item 4 wording still matches reality.

---

## 4. Migration apply queue (operator action at closeout)

Apply per `runbooks/phase_9_production1_migration_apply_runbook.md`. "No business live yet" makes this window ideal — additive expand, idempotent.

Order: by timestamp prefix (also dependency order).

1. `db/migrations/202605131500_b5_b_catalog_tri_mirror.sql` — 2 new permission keys + grants (super_admin + operator_owner + operator_admin only)
2. `db/migrations/202605131500_b10_1_vendor_applicability.sql` — vendor applicability temporal table + 6 indexes + RLS via wrapper
3. `db/migrations/202605131600_b2_1_default_role_catalog_versions.sql` — F&F-global versioned catalog table (no RLS — admin-pool BYPASSRLS posture, documented in migration header)
4. `db/migrations/202605131700_c_1a_email_event_provider_id.sql` — `email_event.provider_event_id text` + partial UNIQUE INDEX `WHERE provider_event_id IS NOT NULL`; idempotent DDL; predicate is load-bearing for C-1's `ON CONFLICT` dedupe
5. **Plus once it merges:** `L_A2` (descendant cache table — in-flight on parallel Claude lane session)

**Note on L_A1:** PR #608 ships **no migration** per operator's 2026-05-13 Option 1 pick — the existing `locations.org_unit_path` GIST index from `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` is the denormalization L_A2 will cache off. **Trailing risk:** if L_A2's worker determines a precomputed table is required for performance, an `L_A1b` migration queues at that point.

**Apply target:** staging first, then Production1. Each migration is additive expand and idempotent.

---

## 5. Bleed-stop ceiling state + reset plan

| Point | `advisor_proxy.dart` lines | Ceiling | Bundle that ratcheted |
|---|---|---|---|
| Pre-wave (A3.1 seam-map baseline) | 18,871 | 19,071 | A3.1 (PR #533) |
| After B10.1 (PR #576) | 19,458 | 19,071 | overshoot — fixed in Bundle 33 |
| After Bundle 33 raise | 19,543 | 19,600 | Bundle 33 (PR #583) |
| After B2.1 (PR #584, Bundle 34) | 19,628 | 19,700 | Bundle 34 (PR #585) |
| After B11.2.b (PR #586, Bundle 35) | 19,688 | 19,700 | no raise — inside ratchet |
| After C-4 (PR #592, Bundle 38) | 19,803 | 19,900 | Bundle 38 (PR #593) |
| After B2.3 (PR #603) | 19,805 (+2) | 19,900 | no raise — dispatch thread only |
| After B2.4 (PR #609, Bundle 45) | 19,812 (+7) | 19,900 | no raise — additive response keys in `_teamRoleToJson` only |
| After C-1 (PR #611, Bundle 45) | 19,812 (no change) | 19,900 | no raise — `advisor_proxy.dart` UNTOUCHED; route via `main.dart` pre-check mount (mirrors `adminEmailRouter` + `Phase80IntegrationRoutes` precedent) |
| **Today (master)** | **19,812** | **19,900** | (headroom 88) |

**Net wave growth:** +941 LoC (18,871 → 19,812). Caused by dispatch envelopes in `routeRequest` delegating to NEW route files. The route handlers themselves landed in decomposed sibling files — the discipline held.

**Closeout reset:** the ceiling should ratchet **down**, not up, once the proxy-split refactor phase starts extracting clusters per the seam map. At wave close, current line count becomes the new pre-refactor baseline.

---

## 6. Documentation drift sweep at closeout

- [ ] `PROJECT_TRACKER.md` — record wave net delta (54 slices, 17 lane-A + 23 lane-B + 14 lane-C; X merged at closeout)
- [ ] Archive any phase docs that closed: `docs/phases/proxy_split/proxy_split_plan.md` is referenced but actual refactor is post-wave (DO NOT archive yet)
- [ ] Update `docs/_audits/post_codex_wave/README.md` index to list all audit docs from this wave (currently lags — manual refresh needed)
- [ ] Confirm `docs/POST_HARDENING_FOLLOWUPS.md` items mentioned in wave audits are still tracked or have been folded into ledger rows

---

## 7. C-12 closeout slice scope (orchestrator-owned)

- [ ] Full lane-C integration audit (one doc, `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`)
- [ ] Verify all 13 C-slices on master (**currently 8 merged: C-1a ✓ #599, C-1 ✓ #611, C-3 ✓ #579, C-4 ✓ #592, C-5 ✓ #600, C-8 ✓ #499, C-9 ✓ #580, C-10 ✓ #556**; 4 in-flight or assigned: C-2 in-flight, C-6 + C-11 dep-blocked, C-7 data-contract-blocked; C-12 is this slice)
- [ ] Verify cross-surface parity (mobile vs operator-web vs admin) — what shipped where, what gaps remain
- [ ] Final pre-launch posture summary

---

## 8. Refactor handoff (post-wave phase, not in wave)

- Authority: `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` (25-step extraction order)
- Seam map: `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` (12 clusters)
- Bleed-stop lint: `tool/advisor_proxy_size_lint.dart` (ceiling will ratchet DOWN as extractions land)
- Phase doc to open: `docs/phases/proxy_split/proxy_split_plan.md` (referenced in seam map; needs to be authored)
- Estimated scope: multi-week phase; own ledger; not part of this wave

**Operator action at refactor start:**
- Confirm or revise the 25-step order
- Approve the proxy-split phase doc
- Set initial ratchet-down target (probably -1,000 LoC for the first extraction batch)

---

## 9. Open follow-ups not yet on ledger

- ~~**C-6 dep gap** — Codex C-6 shows `dep: B1.a merged` but almost certainly needs `L_A2 merged` too.~~ **RESOLVED 2026-05-13 (PR #607)**: dep updated `B1.a merged` → `L_A2 merged` per operator confirmation.
- **C-7 data-contract gap** — `mfa_factors.recovery_codes_viewed_at` column required by slice spec but absent from schema/model/gateway. Codex escalated 2026-05-13. **Operator decision pending on a C-7a prep migration** (additive `ADD COLUMN IF NOT EXISTS`, mirrors C-1a → C-1 pattern). Not yet on ledger.
- **C-1b conditional** — per-operator `email_credentials.sendgrid_event_webhook_pubkey_pem` column for SendGrid pubkey rotation without restart. **Only spin up if rotation becomes a P0 post-launch** (e.g. credential compromise). Env-var path is V1 launch posture per HP #7.
- **`auth_location_integrations_route_test.dart:476` residual** — same-class failure as the two fixed in PR #610 (A3.3 catch-narrowing fallout: test fake throws `StateError('boom')` instead of `Exception('boom')`); reproduces on master pre-PR-#610. Different production seam than PR #610's two fixes; one-line shape mirror. **In-flight on parallel Claude lane session 2026-05-13** (will follow the PR #588 / #604 / #610 playbook).
- **GCS → Azure Blob swap** (A11.2 heap-snapshot uploader) — locked in `docs/POST_HARDENING_FOLLOWUPS.md` P1 section; not on wave ledger because it's a swap, not a slice.
- **B11.1 idempotency-store convention** — wave deep audit P2 finding; not assigned a ledger slice.
- **Doctrine signals from PR #610 audit** — fold into closeout retro: (a) count failing test CASES, not files (Bundle 33 inflation pattern recurrent in B2.3's "5 test failures" disclosure); (b) A3.3 verification command list should have included every test that hits touched catch sites (A3.4 checklist refinement).
- Any other items the visual-test phase surfaces.

---

## 10. Sign-off chain (proposed)

Operator confirms each of these before declaring wave closed:

1. [ ] All 8 remaining slices merged (or explicitly deferred to a future wave with ledger rows)
2. [ ] Visual-test walkthrough completed on all 9 operator-facing surfaces
3. [ ] Doc audit clean (HPs #1–11 + doctrine docs + contracts)
4. [ ] All 4 queued migrations + L_A2 (once it lands) applied to staging
5. [ ] Same set applied to Production1
6. [ ] `PROJECT_TRACKER.md` updated with wave delta
7. [ ] C-12 closeout audit doc produced
8. [ ] Bleed-stop ceiling baseline recorded for refactor phase entry (current: 19,812 / 19,900 — headroom 88)

Once all 8 checked, the wave closes and the refactor phase opens.

---

**Draft status:** awaiting operator review. Edit freely; tell orchestrator when to finalize.
