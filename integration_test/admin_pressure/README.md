# Admin Console Pressure Suite (v1)

Integration-test pressure suite for the Forge & Flow admin console.
Mirrors `integration_test/mobile_pressure/` but targets the admin web
entrypoint (`lib/main_admin.dart`) in Flutter Web share-preview mode.

The shape, naming, and lane discipline are intentionally identical to
the mobile pressure suite — same `_harness.dart` pattern, same lane
runners, same one-lane-at-a-time rule, same FlutterErrorTap for
overflow / exception guards.

---

## Canonical run command

One lane at a time, Flutter Web only (Chrome).

```powershell
flutter test integration_test/admin_pressure/lane_a_runner.dart `
    -t lib/main_admin.dart `
    --dart-define=ADMIN_SHARE_PREVIEW=true `
    --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
    --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
    -d chrome `
    --timeout 180s
```

Replace `lane_a_runner.dart` with `lane_b`, `lane_c`, `lane_d`, or
`lane_e` for the other lanes.

---

## Non-negotiable rules

All three of these are learned the hard way (same shape as the mobile
suite's `kDemoMode=true` rule):

1. **All three dart-defines are required together.**
   - `ADMIN_SHARE_PREVIEW=true` boots straight into the seeded fixture
     dataset with no Firebase and no proxy.
   - `ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true` picks the
     fully-privileged super-admin fixture identity (omit it and you
     get read-only F&F support, which fails on every write-bearing
     scenario).
   - `ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true` is the release/profile
     fail-closed opt-in. Without it a non-debug build lands on the
     "fixture auth blocked" screen instead of the console.
   - The `_harness.dart` `launchAdminSharePreview` helper throws a
     clear `StateError` if `ADMIN_SHARE_PREVIEW` is not set, so a
     forgotten flag fails loudly instead of silently passing.

2. **Run lanes one at a time, never in parallel.** Parallel runs share
   `build/web/` and produce file-copy conflicts mid-build. The mobile
   suite has the same rule for `build/app/`.

3. **`--timeout 180s`** prevents the 12-minute default from hanging
   the runner on slow Chrome boot.

4. **Flutter Web only.** The admin console does not ship as mobile;
   `-d chrome` is the only supported device. Running with
   `-d emulator-5554` will fail at the launch step.

5. **If a lane times out on first run (Chrome boot race), re-run once
   before diagnosing.** Same workaround as the mobile suite's APK
   install race.

---

## Suite layout

```
integration_test/admin_pressure/
  _harness.dart                # share-preview boot + nav + FlutterErrorTap
  README.md                    # this file
  lane_a_runner.dart           # shell / auth / nav
  lane_b_runner.dart           # operations surfaces
  lane_c_runner.dart           # AI surfaces
  lane_d_runner.dart           # system monitoring + service setup
  lane_e_runner.dart           # account + cross-surface regression
  auth/                        # share-preview boot + identity scenarios
  shell/                       # nav rail / layout flip / overflow guard
  ops_business_accounts/       # Business accounts route + drill-ins
  ops_data_accuracy/           # Data accuracy hidden route
  ops_vendor_applicability/    # Vendor applicability primary route
  ops_polling/                 # Polling Setup primary route
  ops_members/                 # Team members hidden route
  ops_access/                  # Access (Roles / Hierarchy / Sessions)
  ops_security_audit/          # Security & audit hidden route
  ops_vendor_integrations/     # Vendor integrations hidden route
  ops_timing/                  # Timing setup hidden route
  ai_pricing/                  # Plans and limits primary route
  ai_corpus/                   # Knowledge base primary route
  ai_observability/            # AI Metrics primary route
  sysmon_health/               # System health primary route
  sysmon_debug/                # Support logs primary route
  setup_integrations/          # Connected services primary route
  setup_feature_flags/         # Launch controls primary route
  setup_default_roles/         # Default roles primary route
  account_my_account/          # My account primary route
  account_notifications/       # Notifications primary route
  regression/                  # cross-surface regression scenarios
```

---

## Lane-to-scenario map

| Lane | Surfaces | Scenarios |
|---|---|---|
| **A** | Shell, Auth, Navigation | `auth_01`, `auth_02`, `shell_01`–`shell_04` |
| **B** | Operations surfaces (Business accounts, Data accuracy, Vendor applicability, Polling, Members, Access, Security & audit, Vendor integrations, Timing) | `ops_ba_01`–`ops_ba_06`, `ops_da_01`–`ops_da_03`, `ops_va_01`–`ops_va_02`, `ops_pol_01`–`ops_pol_03`, `ops_mem_01`–`ops_mem_03`, `ops_acc_01`, `ops_sa_01`–`ops_sa_02`, `ops_vi_01`, `ops_tim_01` |
| **C** | AI surfaces (Plans and limits, Knowledge base, AI Metrics) | `ai_pri_01`–`ai_pri_03`, `ai_cor_01`–`ai_cor_02`, `ai_obs_01`–`ai_obs_02` |
| **D** | System monitoring + Service setup (System health, Support logs, Connected services, Launch controls, Default roles) | `sysmon_health_01`–`sysmon_health_02`, `sysmon_debug_01`–`sysmon_debug_02`, `setup_int_01`, `setup_ff_01`–`setup_ff_02`, `setup_dr_01`–`setup_dr_02` |
| **E** | Your account + cross-surface regression | `account_ma_01`–`account_ma_02`, `account_not_01`–`account_not_02`, `reg_01`–`reg_04` |

---

## Wired-vs-stub status (v1 baseline)

The v1 slice ships **12 fully-wired scenarios** with real assertions
and roughly 35 **stubs** that boot the shell and leave a
`// TODO(admin-pressure): ...` for the next person to land. The stubs
mean the directory tree is exhaustive (every surface in the runbook is
represented) while the wired set locks in the boot path, the shell,
and the four highest-impact regressions from the 2026-05-22 manual
pressure test.

### Fully wired (12)

| File | What it locks in |
|---|---|
| `auth/scenario_auth_01_share_preview_boot.dart` | Cold boot in share-preview mounts the shell with the demo banner and identity chip. |
| `auth/scenario_auth_02_role_pill_and_identity.dart` | Header identity chip shows the super-admin email; sign-out is hidden in share-preview. |
| `shell/scenario_shell_01_all_nav_routes_mount.dart` | Each of the 12 primary-nav routes mounts cleanly with no overflow. |
| `shell/scenario_shell_03_header_overflow_guard.dart` | Regression — header bar does not RenderFlex-overflow across compact / narrow / wide viewports (the 2026-05-22 76 px overflow). |
| `ops_business_accounts/scenario_ops_ba_01_two_demo_operators_present.dart` | Business accounts route surfaces both seeded operators (Demo Diner Co., Sunset Cafe Group). |
| `ops_business_accounts/scenario_ops_ba_04_suspend_business_requires_confirmation.dart` | Regression — suspend-business is not one-tap; surfaces a confirmation dialog or reason input. |
| `ops_vendor_applicability/scenario_ops_va_02_edit_metadata_dialog_requires_reason.dart` | Regression — edit dialog exposes the admin reason field; empty submit does not silently write. |
| `ops_polling/scenario_ops_pol_03_tier_change_request_visible_at_business_scope.dart` | Regression — tier-change request renders at business scope with Approve/Deny correctly hidden. |
| `ai_pricing/scenario_ai_pri_03_add_usage_limit_validates_required_fields.dart` | Regression — Add usage limit affordance opens an editor (not a silent no-op). |
| `ai_observability/scenario_ai_obs_02_cancel_confirmation_dismisses.dart` | Regression — the AI Metrics run-check Cancel button actually dismisses the dialog (the 2026-05-22 stuck-dialog incident). |
| `regression/scenario_reg_01_no_renderflex_overflow_full_nav_tour.dart` | Regression — full primary-nav tour at 980x900 emits zero RenderFlex overflows. |
| `regression/scenario_reg_02_account_profile_ai_plan_is_actually_disabled.dart` | Regression — the AI-plan detail row is genuinely non-tappable when marked disabled (no role=button affordance lie). |

### Stub (the rest)

Every other scenario file in the directory tree is a stub that boots
the shell and leaves a `// TODO(admin-pressure): ...` comment naming
the surface to flesh out. Stubs intentionally do not have real
assertions beyond `expectAdminShellMounted` so they pass cleanly while
land-able placeholders exist; the team lands them one at a time.

---

## Harness API (`_harness.dart`)

| Function | What it does |
|---|---|
| `bootstrapBinding()` | Initialises the `IntegrationTestWidgetsFlutterBinding`. Call once per scenario file. |
| `pumpUntil(tester, budget: ...)` | Pumps frames until Flutter reports no more scheduled frames, or `budget` elapses. |
| `launchAdminSharePreview(tester)` | Boots the admin app via `main_admin.dart`. Throws a `StateError` if `ADMIN_SHARE_PREVIEW` is not set. |
| `expectAdminShellMounted(tester)` | Waits for `Key('admin_shell_scaffold')` and asserts it is present. |
| `tapAdminNav(tester, routeId)` | Taps `Key('admin_nav_item_<routeId>')`. Use route-id constants from `lib/admin/admin_routes.dart`. |
| `expectAdminRoute(tester, routeId)` | Soft-asserts a route is active (today: shell still mounted). Tighten per-scenario with a screen-specific key check. |
| `tapAdminLabel(tester, label)` | Fallback "tap by visible label" — same shape as the admin runbook's `flt-semantics`-by-text helper. |
| `FlutterErrorTap.install()` | Captures FlutterError.onError. Has `.overflowErrors` and `.all` getters; call `.restore()` from `addTearDown`. |
| `kAdminSharePreview` | `bool.fromEnvironment('ADMIN_SHARE_PREVIEW')`. Mirror of `kDemoMode` in the mobile harness. |
| `kAdminBootBudget` / `kAdminNavBudget` / `kAdminShellMountBudget` | 45 s / 15 s / 20 s timing guards. |

---

## Cross-references

- Admin console manual QA runbook: `runbooks/admin_console_browser_qa_runbook.md`
- Mobile pressure suite (canonical template): `integration_test/mobile_pressure/`
- Operator web manual QA runbook: `runbooks/operator_web_qa_runbook.md`
