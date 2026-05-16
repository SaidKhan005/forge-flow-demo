# Phase 2 walkthrough — second-Claude handoff (admin console lane)

> **Created 2026-05-14 evening.** Paste-ready prompt for a second Claude
> lane running on a separate machine. This Claude owns the **admin
> console** lane only; the main Claude owns operator-web + mobile.

---

## Opening prompt (paste into the second-Claude session)

```
You are the Claude2 lane for the Phase 2 walkthrough on the
forge_flow_demo repo. The Main Claude lane owns operator-web + mobile;
you own the admin console.

Repo: https://github.com/SaidKhan005/forge-flow-demo
Main Claude is working on branch: claude/blissful-roentgen-e365a2

Your read-it-first stack (read top to bottom before anything else):

 1. CLAUDE.md (authority order + Hard Promises + Workflow + Agent-led
    slices contract).
 2. docs/_audits/wave_2/phase_2_walkthrough_master_plan.md (the
    cross-lane master plan + Status board + Gaps register + Dev-patches
    reference + Helper scripts + Worktree agent contract).
 3. docs/_indices/PHASE_2_WALKTHROUGH_CLAUDE2_HANDOFF.md (THIS FILE —
    your lane-specific surfaces-to-drive list + admin launch config).
 4. docs/_audits/wave_2/phase_2_walkthrough_verification.md (rolling
    evidence matrix — Main Claude's operator-web matrix sections are
    the canonical state shape. Build your admin console matrix in the
    same shape, in a new dedicated section.).
 5. docs/_indices/WAVE_2_LEDGER.md + DEBUG_MD_IMPLEMENTATION_STATUS.md
    (trackers — Main has already inline-annotated operator-web rows;
    you inline-annotate admin-only rows the same way as you go).

Your contract:
 - You operate as a mini-orchestrator on your own branch
   `claude2/admin-walkthrough-phase-2`.
 - You spawn worktree agents for the same kinds of work the master
   plan lists (annotation + fix + future surface-specific drives).
 - You NEVER touch the operator-web demo source, the mobile lib, or
   the trackers' Wave 2 / Wave 1 / DEBUG_MD rows that the Main Claude
   has marked ⏳ NOT-DRIVEN — those are the Main Claude's territory.
 - You DO own: every admin-console row across the three trackers,
   the admin demo fixtures, the admin launch config, and the matrix's
   "Admin console lane" section in the verification doc.
 - Gap-fix discipline: demo-fidelity gaps get fixed live (worktree
   agent → PR → you audit → merge). UX-decision gaps get filed as
   parked rows in the master plan Gaps register + WAVE_2_LEDGER.
 - Concurrency: NEVER edit operator-web source files
   (lib/operator_web/**), the mobile lib (lib/main_forgeflow.dart +
   related), or files the Main Claude marks "Main owns" in the master
   plan Status board.

Your goal: drive every admin-console row to ✅ DONE-LIVE or 🟢
SURFACE-LIVE or 🐛 GAP-FOUND, inline-annotate every admin-relevant
row in all three trackers, fix demo-fidelity bugs live via worktree
agents, file UX-decision gaps in the Gaps register, and commit each
meaningful slice of work with the doc updates in the same commit.

Stop only when: the admin console lane's acceptance criteria are met
(see below) AND committed/pushed; OR you need an operator decision
(file the question, do not guess); OR you need a coordination check
with Main (the master plan has a Cross-lane coordination section for
this).

Start with: read this file's "Surfaces to drive" list, pick the first
[ ] item, apply the admin dev patches per "Admin dev patches" below,
boot admin-console-demo via Claude Preview MCP, drive the surface,
update the matrix, annotate trackers, commit, push, loop.
```

---

## Lane scope

**Owned by Claude2 (admin lane):**
- All admin screens in `lib/admin/screens/**`
- Admin demo auth fixtures
- Admin matrix section in `phase_2_walkthrough_verification.md`
- Admin-only rows in WAVE_2_LEDGER + WAVE_EXECUTION_LEDGER + DEBUG_MD_IMPLEMENTATION_STATUS
- The admin-side half of any cross-console slice (e.g. RP-9 admin gate, RP-15 admin-undo, AC-1 admin actor_kind labels, W-4 admin My Account parity, OW-13d admin vendor-applicability tabs)

**Owned by Main Claude (operator-web + mobile):**
- All files under `lib/operator_web/**`
- `lib/main_operator_web.dart`
- Mobile lib (`lib/main_forgeflow.dart` + related under `lib/screens/**` for mobile)
- Operator-web demo fixtures + matrix
- Mobile demo fixtures + matrix
- The orchestrator-level Status board

**Shared (don't edit without cross-lane sync):**
- `docs/_audits/wave_2/phase_2_walkthrough_master_plan.md` — Main is primary editor; Claude2 may append to the Status board "Admin console lane" subsection + add admin rows to the Gaps register
- `docs/_audits/wave_2/phase_2_walkthrough_verification.md` — both lanes write to their own sections; do NOT edit each other's sections
- `docs/_indices/WAVE_2_LEDGER.md` + `WAVE_EXECUTION_LEDGER.md` + `DEBUG_MD_IMPLEMENTATION_STATUS.md` — both lanes annotate their own rows inline, never delete or modify the other lane's annotations

**Coordination rule:**
- Before pushing a commit, `git pull --rebase origin master` to pick up any merges from the other lane.
- If a row already has a `Phase 2 walkthrough 2026-05-14:` annotation from the other lane, **do NOT overwrite** — append a second line if your annotation adds new evidence (e.g. operator-web row that has admin-side parity).

---

## Admin console — surfaces to drive

Pick the next [ ] item, drive it, annotate, commit. After each surface, refresh the matrix in the verification doc and commit.

### Phase A — Login + shell + global affordances

- [ ] **Admin sign-in screen** (`lib/main_admin.dart` welcome path) — fixture-login users available in `ADMIN_DEMO_AUTH=true` mode: `super.admin@`, `support@`, `operator@` (see `_resolveAuthSource` in `main_admin.dart`). Validate: 3 user-type tiles, sign-in copy, no green logo on admin side either.
- [ ] **Admin top bar** — admin shell branding, operator switcher (`operator_picker_screen.dart`), F&F admin-vs-support role chip, sign-out CTA.
- [ ] **Admin nav rail / drawer** — confirm every admin screen entry from `lib/admin/screens/**` is reachable.

### Phase B — Read-back screens (the "explain this to me in plain English" group)

- [ ] **QI-8 Health admin screen** (`health_admin_screen.dart`, 1,390 LoC) — 3-tab tile-based system health rendering. Validate proxy-health tile + operational tiles. Operator's debug.md ask was: "can we audit proxy health and have that as a ui under the system health tab".
- [ ] **Observability admin** (`observability_admin_screen.dart`) — explain what's there.
- [ ] **Debug console admin** (`debug_console_admin_screen.dart`) — explain what's there.
- [ ] **Feature flags admin** (`feature_flags_admin_screen.dart`).

### Phase C — Identity + members + roles + permissions (admin side of Lane R + W)

- [ ] **Members admin** (`members_admin_screen.dart`) — admin-side parity of operator-web Team Members. Verify columns, filters, 3-dot menu, search.
- [ ] **Invite member admin** (`invite_member_admin_dialog.dart`) — RP-10 admin side: hierarchy-tree picker (not flat dropdown). Should match the operator-web invite dialog UX.
- [ ] **Roles + Hierarchy + Sessions admin** (`roles_hierarchy_sessions_admin_screen.dart`).
- [ ] **Default Role Catalog admin** (`default_role_catalog_admin_screen.dart`) — RP-9: confirm the `team.roles.default_catalog.edit` permission gates editing. Try editing as super_admin vs support to validate the gate.
- [ ] **Default Role Catalog publish dialog** (`default_role_catalog_publish_dialog.dart`).
- [ ] **W-4 My Account admin parity** (`my_account_admin_screen.dart`) — confirm full surface ships on admin side (debug.md 51 ask: "the same my account tab needs to be there on both the operator web console and admin web console for that specific user, currently the admin console does not have this").

### Phase D — Audit + AC-1 actor_kind labels

- [ ] **Audit log admin** (`audit_log_admin_screen.dart`) — AC-1: verify the actor_kind enum values render as human-readable labels (per `lib/admin/admin_human_labels.dart`), not machine flavoured strings. Test event types: `Sign-in`, `Suspended team member`, `MFA enrolled (authenticator)`, etc. **Watch for MO-5b label drift on admin side too** — the action chip set on operator-web mixed "MFA" + "Two-factor"; check whether admin uses the same chips.
- [ ] **Audited support actions admin** (`audited_support_actions_admin_screen.dart`) — F&F support-team action log; verify human labels + scope clamping.

### Phase E — Operator setup + tier + per-location

- [ ] **Operator picker / location admin** (`operator_picker_screen.dart` + `operator_location_admin_screen.dart`) — confirm F&F admin can switch between operators + per-location detail.
- [ ] **Admin timing setup** (`admin_timing_setup_screen.dart`).
- [ ] **Per-location data accuracy admin** (`per_location_data_accuracy_screen.dart`) — RP-15 admin-undo: drive the override-undo path with the demo Owner who has an override set, validate the admin can undo + the audit row writes.
- [ ] **Polling + pricing admin** (`polling_and_pricing_admin_screen.dart`).
- [ ] **Pricing tier admin** (`pricing_tier_admin_screen.dart`).

### Phase F — Integrations + vendor applicability

- [ ] **Vendor connections admin** (`vendor_connections_admin_mount.dart`) — V-1 rename on admin side; validate "Vendor connections" / "Vendor integrations" copy across this surface.
- [ ] **Vendor applicability admin** (`vendor_applicability_admin_screen.dart`) — OW-13d 3-tab editor (wage / covers / polling). The operator's debug.md 240 ask was: "an editable list for wage, and an editable list for covers and an editable list for polling. Once this list is updated on the admin console it automatically updates on the ops web console in all relevant places". Validate the 3 tabs + edit UX + idempotency-counter writes.
- [ ] **Integration admin** (`integration_admin_screen.dart`).

### Phase G — Support + corpus + admin-only ops

- [ ] **Support operator view admin** (`support_operator_view_admin_screen.dart`).
- [ ] **Corpus admin** (`corpus_admin_screen.dart`).

### Phase H — Cross-cutting consistency checks

- [ ] **HP #11 sweep on admin** — confirm every admin settings surface shows scope / inherited-from / effective value, OR is gated/backend-only with a reason. Same Hard Promise as operator-web.
- [ ] **Demo mode badges (HP #2)** — confirm admin surfaces that show vendor data render the same Demo mode badges as operator-web's Vendor integrations page.
- [ ] **2FA label drift sweep** — same MO-5b check as operator-web. Watch for "MFA" / "2FA" / "Two-factor" mixed labels on admin surfaces.

---

## Admin dev patches

Same pattern as Main's operator-web patches: apply when driving, **revert before commit**. The admin entry has its own `ADMIN_DEMO_AUTH=true` flag (per `run_admin_console_dev.ps1`), so the CSP patch may be the only one needed.

### Patch 1 — CSP relaxation (if admin uses the same `web/index.html`)

The admin build serves the SAME `web/index.html` as operator-web. If the admin DDC bootstrap is blocked by the production CSP the same way, apply the same `unsafe-inline` + `unsafe-eval` relaxation per the master plan's Patch 1. **Revert before commit.**

### Patch 2 — Admin demo fixture-login shortcut

`run_admin_console_dev.ps1 -DemoMode` boots with `--dart-define=ADMIN_DEMO_AUTH=true` which exposes 3 fixture-login users. If you want to skip the user-picker and land directly as a specific user (e.g. `super.admin@`), apply a small patch to the admin demo auth source. See `main_admin.dart` `_resolveAuthSource`.

### Patch 3 (potential) — Admin demo seed with override / MFA factor

To exercise RP-15 admin-undo cleanly, seed an operator with a pre-existing benchmark override in the admin demo fixture. Likewise for OW-8c-equivalent flows, seed an MFA factor.

### .claude/launch.json entry for admin

```json
{
  "name": "admin-console-demo",
  "runtimeExecutable": "flutter",
  "runtimeArgs": [
    "run", "-d", "web-server", "--web-port=8182",
    "--web-hostname=0.0.0.0",
    "-t", "lib/main_admin.dart",
    "--dart-define=ADMIN_DEMO_AUTH=true"
  ],
  "port": 8182
}
```

(Use port 8182 to avoid collision with Main's port 8181 for operator-web.)

---

## Boot procedure — admin console

Same shape as operator-web in the master plan:

```
1. git fetch origin master && git rebase origin/master (sync with Main's commits)
2. Apply Patch 1 (CSP) if needed.
3. preview_start name="admin-console-demo".
4. Bash poll: `until curl -sf http://localhost:8182/main_module.bootstrap.js >/dev/null; do sleep 3; done`
5. preview_eval the manual loader invocation (same as operator-web boot procedure in master plan §Boot procedure).
6. Wait ~30-45s for DDC modules to evaluate.
7. Click flt-semantics-placeholder to enable semantics.
8. Install __ff helper (see master plan §Helper scripts).
9. Drive surfaces.
```

---

## Matrix template for admin lane (paste into verification doc)

Add a new section in `docs/_audits/wave_2/phase_2_walkthrough_verification.md` after the operator-web lane matrix, with this shape:

```markdown
## Phase 2 walkthrough verification matrix (admin console lane)

> Pass started 2026-05-14 evening by Claude2 lane. Same legend as the
> operator-web matrix above. Drove admin via flutter run -d web-server
> at port 8182 with ADMIN_DEMO_AUTH=true.

### Phase A — Login + shell + global affordances
| Surface | Live state | Evidence |
| ... |

### Phase B — Read-back screens
...

### Phase C — Identity + members + roles + permissions (admin side)
...

(etc per the surfaces-to-drive list above)

### Admin gaps surfaced during this pass
(table identical shape to the operator-web Gaps surfaced table)
```

---

## Tracker annotation contract (same as Main lane)

For every admin-relevant row in:
- `WAVE_2_LEDGER.md` — RP-9 / RP-15 / AC-1 / W-4 / OW-4 / OW-13d (admin side) and any other ledger row with admin scope
- `WAVE_EXECUTION_LEDGER.md` — admin backbone rows from Wave 1 (some of B7 / B8 / C-2 / C-9 / C-10 / etc.)
- `DEBUG_MD_IMPLEMENTATION_STATUS.md` — every row under "Admin Console UX" section + every cross-console row with admin scope

Append a one-line annotation in the row's Notes/Source/Citation cell using a `<br>` separator (matches the pattern Main used in PR #739):

```
<br> Phase 2 walkthrough 2026-05-14: <STATE> — <one-line evidence sourced from your admin matrix>
```

State taxonomy is the same as Main's:
- ✅ DONE-LIVE / 🟢 SURFACE-LIVE / 🔧 BACKEND / 🅰 (not used in admin lane — admin lane = your scope) / 📱 MOBILE-DEFERRED / 🐛 GAP-FOUND / ⏳ NOT-DRIVEN

If a row is already annotated by Main (operator-web side validated it from the other console), append a SECOND line on a new `<br>` — don't overwrite Main's annotation.

---

## Acceptance criteria for "admin console lane done"

1. Every surface in the surfaces-to-drive list above is driven + matrix-annotated.
2. Every admin-relevant row in all 3 trackers carries an inline `Phase 2 walkthrough <date>:` annotation.
3. All demo-fidelity bugs surfaced are either fixed via worktree agent PR (merged) OR filed as parked rows.
4. All UX-decision gaps are filed in the master plan Gaps register.
5. Dev patches reverted; tree clean.
6. Status board in master plan flipped: `Admin console: ✅ DONE`.
7. Final commit on `claude2/admin-walkthrough-phase-2` branch + push.
8. Open PR against master with the standard Pattern B audit table.
9. Notify Main (via a `coordination` comment in the master plan or a direct ping to the operator).

---

## Worktree agent contract for Claude2

Identical to Main's per `master_plan` §"Worktree agent contract". Same `isolation: worktree`, same prompt skeleton, same Pattern B half-table self-audit requirement, same no-merge / no-tracker-edit / no-`--no-verify` rules.

Recommended Claude2 agents for the admin lane:

- **A2-annotation** — inline-annotate admin-only rows in the 3 trackers (after Main's PR #739 lands; check via `git log` for the merge commit).
- **A2-rp9-admin-gate-fix** — if Default Role Catalog admin doesn't gate editing correctly per RP-9, ship a focused fix.
- **A2-ac1-label-sweep** — if the admin Audit log surfaces MO-5b-equivalent label drift, ship the canonical-label sweep (operator decision dependency).
- **A2-w4-parity-check** — verify admin My Account parity matches W-4 PR #688 spec.
- **A2-vendor-applicability-3-tab-check** — verify OW-13d's 3-tab editor matches debug.md 240.

---

## Cross-lane coordination snippets

If you need to ping Main / operator about something cross-lane, append to the master plan's "Cross-lane coordination" section (you'll need to add this section if it doesn't exist yet — placement: right after the Status board, before Operator-web lane).

Examples of cross-lane events to ping about:
- "Admin AC-1 actor_kind label sweep needs MO-5b canonical-label decision — same drift on admin side as operator-web My account."
- "RP-9 admin gate fix has touched permission_keys; Main please pull master before driving operator-web Roles next."
- "Admin demo fixture for RP-15 override-undo needs operator to pick a default override scope."

---

## Files Claude2 may edit (whitelist)

```
lib/admin/**                                      (admin source)
lib/main_admin.dart                               (admin entry)
lib/services/auth/admin_*.dart                    (admin auth seams)
test/admin/**                                     (admin tests)
docs/_audits/wave_2/phase_2_walkthrough_verification.md   (admin section only)
docs/_audits/wave_2/phase_2_walkthrough_master_plan.md    (admin status board entry + admin gaps in register)
docs/_indices/WAVE_2_LEDGER.md                    (admin-row annotations only, never State/PR/Gate)
docs/_indices/WAVE_EXECUTION_LEDGER.md            (admin-row annotations only)
docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md   (admin-row annotations only)
.claude/launch.json                               (admin entry — already gitignored)
web/index.html                                    (CSP patch + revert; same file as Main but revert before commit)
```

## Files Claude2 may NOT edit

```
lib/operator_web/**                               (Main owns)
lib/main_operator_web.dart                        (Main owns)
lib/main_forgeflow.dart                           (Main owns mobile)
lib/screens/** that are mobile-specific           (Main owns mobile)
docs/_indices/PHASE_2_WALKTHROUGH_CLAUDE2_HANDOFF.md  (Main authored; if changes needed, ping)
```

---

## When you're done

Commit message format:

```
Phase 2 walkthrough — admin console lane <round>: <surfaces>

<bullet list of surfaces driven this round>
<bullet list of gaps filed>
<bullet list of fixes merged>
<status board update line>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

Open the lane-closure PR with the Pattern B half-table audit + the
matrix delta + the gaps register delta cited in the body.

Then STOP and ping the operator with the PR link.
