# Post-Codex Wave — Closeout Checklist (DRAFT)

**Status:** Draft. Read-only launchpad for the wave-finish → visual-test → doc-audit → close-out → refactor-handoff sequence operator approved 2026-05-13.

**Wave snapshot at draft time:** Master tip `a129987a`. 40 / 54 slices merged. Watcher loop running on 5-min ticks.

---

## 1. What's left in the wave (14 slices)

### Claude lane (9)
- **B2.3** — Blast-radius endpoint (Small, auto, no deps) — ready
- **B2.4** — Per-role catalog date projection (Small, auto, no deps) — ready
- **L_A1** — Inheritance Tree primitive (Medium, operator, no deps) — ready
- **L_A2** — Descendant-set cache (Medium, operator, dep `L_A1 merged`)
- **B8** — Audit log hierarchy filter (Medium, operator, dep `L_A2 merged`)
- **C-1a** — UNIQUE INDEX prep migration (Small, operator, no deps) — ready
- **C-1** — SendGrid webhook receiver (Small, auto, dep `C-1a merged`)
- **C-2** — Wire-or-delete 6 email templates (Medium, operator, dep `C-1 merged`)
- **C-11** — Pressure-test inventory under preview (Medium, operator, dep `C-2 merged`)

### Codex lane (4)
- **B6** — Benchmark override (Medium, operator, dep `B10.1 merged ✓`) — ready
- **C-5** — Mobile pointer deep-link redemption (Medium, operator-High, dep `B11.1 merged ✓`) — ready
- **C-6** — Inheritance Tree shared component consumer (Medium, auto, dep `B1.a merged ✓`) — **⚠ dep gap: should also depend on `L_A2 merged`** (flagged 2026-05-13; operator confirmation pending)
- **C-7** — Adaptive 2FA button (Small, auto, dep `B9.2 merged ✓`) — in-flight on `codex/c-7-adaptive-2fa-button` worktree

### Orchestrator (1)
- **C-12** — Final lane-C integration audit (Small, auto, dep `all C-* merged`)

**Ready-to-pull right now:** B2.3, B2.4, L_A1, C-1a (Claude); B6, C-5 (Codex). 6 slices can go in parallel; the rest are dep-blocked.

---

## 2. Visual-test surface map (operator drives)

Per operator 2026-05-13 plan: "visually test and audit fully against docs" between wave finish and closeout.

| Surface | Slices that touched it | Walkthrough notes |
|---|---|---|
| **Mobile — Settings → Data tab** | C-4 (demo→live switch) | Toggle Demo→Live one-way; confirm dialog; verify Live→Demo refused with operator-readable copy ("live data has arrived; demo mode cannot be restored") |
| **Mobile — auth flow** | B11.2.b (step-up dialogs) — universal on 20 sensitive routes; C-7 mobile parity (in-flight) | Once C-7 lands: trigger step-up on a sensitive route, verify fresh `auth_time` prompt + clock-skew ±60s grace |
| **Admin Console — Default Role Catalog** | B2.1 (backend), B2.2 (admin editor) | Three-region page (current/history/draft); double-confirm publish dialog with type-confirm-by-version; verify "Affecting N businesses..." copy currently shows plain-English consequences (B2.3 will swap in numerics when shipped) |
| **Admin Console — Vendor Applicability** | B10.1 (backend), B10.2 (admin editor) | Per-`setting_kind` tabs (wage/covers/polling); vendor table with enable + effective dates + metadata JSON; required reason + idempotency-key per write; temporal end/replace only |
| **Operator-web — Roles screen** | B2.2 (Default badge + "Managed by Forge & Flow" annotation) | Verify badge on `is_seeded=true` rows only; "Seeded" → "Default" rename consistent. B2.4 will add "Updated by F&F on \<date\>" when shipped |
| **Operator-web — My Account → Security** | C-3 (sign-in security fold) | Verify `SecurityScreen` is gone; 3 redirect routes work (`/security`, `/sign-in-security`, `/operator-web/sign-in-security`); recent sign-in activity rendered inline |
| **Operator-web — Data Accuracy → Wage Source** | B10.2 (live wage authority binding) | Picker reads `vendor_applicability` filtered to `enabled=true AND effective_until IS NULL`; disables vendor source with operator-readable copy when no current wage vendor enabled |
| **Mobile — Inbox / Notifications** | C-9 (catalog-backed rendering) | `eventKey` resolution preferred over legacy `type`; safe TOS fallback copy; mobile stays read-only (no preference switches) |

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
- [ ] **HP #11** — Hierarchy-scoped settings mandatory. **B10.2** wires hierarchy-scoped wage source; **B8/L_A1/L_A2** queue hierarchy filter. Verify settings surfaces show selected scope + inherited source + effective value.

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
4. **Plus once they merge:** `C-1a` (UNIQUE INDEX on `email_event(sg_event_id)`), `L_A1` (Inheritance Tree + ltree model), `L_A2` (descendant cache table)

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
| **Today (master)** | **19,803** | **19,900** | (headroom 97) |

**Net wave growth:** +932 LoC (18,871 → 19,803). Caused by dispatch envelopes in `routeRequest` delegating to NEW route files. The route handlers themselves landed in decomposed sibling files — the discipline held.

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
- [ ] Verify all 11 C-slices on master (currently 4 merged: C-3 ✓, C-4 ✓, C-9 ✓, C-10 ✓; 7 still in flight or assigned)
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

- **C-6 dep gap** — Codex C-6 ("Inheritance Tree shared component consumer") shows `dep: B1.a merged` but almost certainly needs `L_A2 merged` too. Flagged for operator confirmation; not yet acted on.
- **GCS → Azure Blob swap** (A11.2 heap-snapshot uploader) — locked in `docs/POST_HARDENING_FOLLOWUPS.md` P1 section; not on wave ledger because it's a swap, not a slice.
- **B11.1 idempotency-store convention** — wave deep audit P2 finding; not assigned a ledger slice.
- Any other items the visual-test phase surfaces.

---

## 10. Sign-off chain (proposed)

Operator confirms each of these before declaring wave closed:

1. [ ] All 14 remaining slices merged (or explicitly deferred to a future wave with ledger rows)
2. [ ] Visual-test walkthrough completed on all 7 operator-facing surfaces
3. [ ] Doc audit clean (HPs #1–11 + doctrine docs + contracts)
4. [ ] All 5+ queued migrations applied to staging
5. [ ] All 5+ queued migrations applied to Production1
6. [ ] `PROJECT_TRACKER.md` updated with wave delta
7. [ ] C-12 closeout audit doc produced
8. [ ] Bleed-stop ceiling baseline recorded for refactor phase entry

Once all 8 checked, the wave closes and the refactor phase opens.

---

**Draft status:** awaiting operator review. Edit freely; tell orchestrator when to finalize.
