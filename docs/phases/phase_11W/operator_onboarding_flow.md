# Operator Onboarding — End-to-End Flow

Updated: 2026-05-03
Status: Spec'd as part of Phase 11W `11W.0` shell + Phase 11A `11A.1` operator/location create
Owner: Phase 11W lane (with handoff points to Phase 11A `11A.1`, Phase 9 auth, Phase 8 connect flows)

This doc specifies the full operator onboarding lifecycle from the moment F&F decides to onboard a new operator through to first vendor connection. Without this end-to-end spec, individual slices ship correctly but the seams between them break.

## Lifecycle phases

```
[F&F sales close] → [F&F creates operator] → [Operator first login] →
[Operator self-serves vendor connections] → [V1 live]
```

## Phase 1 — F&F creates operator (Phase 11A.1)

Already accepted. F&F admin uses Phase 11A Operations Console:

1. Sign in to `admin.forgeflow.app` as `forge_admin`.
2. Operators → Create new operator.
3. Form: legal business name, primary location name, primary location timezone (IANA), business-day rollover hour, preferred currency, subscription tier.
4. Form continues: first admin user details — email, full name.
5. Submit → backend creates rows: `operators`, `locations` (primary), `users` (first admin), `user_roles` (operator_owner), `operator_admins` (scope_type = `operator_owner`).
6. Backend sets `operators.tos_accepted_at = NULL` (T&Cs gate active).
7. Backend sets all canonical fact tables for this operator to `kDemoMode = true` until first vendor connects.
8. Backend triggers Phase 9.8 invitation email (see Phase 2).

**Output of Phase 1**: operator + primary location + first admin user exist; demo-mode is the default; admin invite email is in flight.

## Phase 2 — Operator first login (Phase 9 auth + Phase 11W.0 shell)

The first admin user receives an invite email and lands on the Operator Web Console.

1. Email arrives via SendGrid (Phase 9.8 email-provider slice). Subject: "Welcome to Forge & Flow — set up your account."
2. Email body: "F&F has provisioned an account for [Business Name]. Click below to set your password and sign in." Magic-link with single-use token.
3. Operator clicks link → lands at `app.forgeflow.app/onboarding/welcome?token=...`.
4. Welcome screen: business name, primary location, "Set your password" CTA.
5. Operator sets password (validates HIBP — Phase 9 already-built feature) → `users.password_hash` written.
6. MFA enrollment screen — operator scans TOTP QR or enrolls SMS. MFA factor row written. Recovery codes shown once.
7. T&Cs acceptance screen — Phase 9.8 inbound-vendor T&Cs draft text. Operator clicks "I agree." Acceptance row written to `tos_acceptances` with version + IP + UA + operator_id.
8. Operator lands on Operator Web Console dashboard. Empty state: "Welcome to Forge & Flow. Connect your POS, Reservation, and Scheduling systems below to get started." Three "Connect" buttons (one per category).

**Output of Phase 2**: operator authenticated, MFA enrolled, T&Cs accepted, sees empty dashboard with clear next-action.

## Phase 3 — Operator self-serves vendor connections (Phase 8 + 8R + 8.S widgets via Phase 11W mount)

For each category (POS, Reservation, Scheduling), operator:

1. Click "Connect a POS" (or Reservation, or Scheduling). Vendor picker dialog appears.
2. Pick vendor from dropdown (e.g., Lightspeed K-Series). If module disambiguation needed (ADP, QuickBooks), sub-dialog asks which module.
3. Multi-location step (only if operator has >1 location): "Apply this connection to which locations?" with checkboxes.
4. OAuth flow (or key-paste for legacy auth): vendor login → consent → callback → `vendor_credentials` row written.
5. Card flips to "Connecting" status while first backfill runs (60-day default).
6. Operator clicks "Test connection" — heavy diagnostic pulls a real sample order/reservation/punch and renders a confirmation modal with field mapping.
7. Card flips to "Connected" once backfill completes; per-(operator, location, category) demo-mode flag flips to `false` for that location and category.

Steps 1-7 repeat for the other two categories. After all three are connected for at least one location, operator's dashboard transitions from "empty state" to "live state."

**Output of Phase 3**: operator has live data flowing for at least one location across one POS, one Reservation, and one Scheduling vendor.

## Phase 4 — V1 live state (Phase 9 + Phase 8 + Phase 11W operational)

Demo-mode banner clears (per location per category). Operator app shows live data on Shift screen, Variance, History, etc.

F&F internal monitoring (Phase 11A.6 observability dashboard) shows the new operator's sync health. F&F support has the cross-operator parity views (Phase 11A.12/13/14) for support escalations.

## Demo-mode-to-live transition (key spec)

Demo-mode lives at the per-(operator, location, category) granularity, not per-operator:

```
demo_mode_state (
  operator_id UUID,
  location_id UUID,
  category TEXT,                  -- 'pos' / 'reservation' / 'scheduling'
  is_demo BOOL DEFAULT true,
  flipped_to_live_at TIMESTAMPTZ,
  PRIMARY KEY (operator_id, location_id, category)
)
```

Flip rule: when an INTEGRATE vendor's connection state for `(operator, location, category)` becomes `connected` and first backfill completes (≥1 record persisted), `is_demo = false` for that (operator, location, category). Banner state is composed in the UI:

- Mobile shell renders demo banner if **any** (location, category) for this operator-user is still demo.
- Operator-app screens that consume per-location data render per-location banners.
- Operator Web Console (Phase 11W) doesn't show a banner — the dashboard surfaces "Connected" badges per category card.

**Reverse transition (disconnect)**: if operator disconnects the only connected vendor in a category for a location, `is_demo` does NOT auto-flip back. Historical facts are kept; banner reads "Disconnected; data may be stale" until reconnect or another vendor connects in that category.

## Email send points (require Phase 9.8 email-provider slice)

Triggers that fire transactional email through the email provider:

| Trigger | Template | When |
|---|---|---|
| Operator creation (Phase 11A.1) | `operator_invite_first_admin` | After first admin user written |
| Add admin user (Phase 11W.1.write) | `operator_admin_invite` | After invite created |
| Password reset request | `password_reset_request` | When user requests reset |
| MFA factor changed | `mfa_factor_changed_notice` | When MFA enrolled / removed |
| Sync error persisting >1h | `vendor_sync_error_alert` | When connector status `error` ≥ 1h |
| Webhook signature verification failed | `vendor_webhook_signature_alert` | When repeated signature failures |
| Connection auto-disabled (3-strike) | `vendor_connection_auto_disabled` | When OAuth refresh fails 3× |
| Daily / weekly summary (V2) | `daily_operations_summary` | Scheduled daily — V2 / not V1 |
| T&Cs version updated | `tos_version_updated_notice` | When T&Cs new version published |

## Slice ownership

- Phase 11A `11A.1` operator/location create — already accepted; minor extension to trigger invite email.
- Phase 9.8 email-provider slice — new; sends transactional email; see `phase_9_8_email_provider_slice.md`.
- Phase 9.8 inbound-vendor T&Cs — new; click-through screen; see `phase_9_8_inbound_vendor_tcs_draft.md`.
- Phase 11W `11W.0` — onboarding-welcome screen + magic-link landing + dashboard empty/live states.
- Phase 9 `9.UX.*` — already accepted; password set + MFA enroll already work in mobile, web mounts the same widgets.
- Phase 8 `8.0` — `demo_mode_state` table + flip logic + Vendor Connections widget hosting empty/connecting/connected states.

## Acceptance test (cross-cutting)

End-to-end onboarding walkthrough captures:

1. F&F admin creates operator + first location + first admin user.
2. Invite email lands in test inbox; magic-link opens onboarding-welcome.
3. Operator sets password (HIBP screened); MFA TOTP enrolled; T&Cs accepted.
4. Operator lands on dashboard empty state.
5. Operator connects Lightspeed K-Series for primary location → backfill → demo-mode flips for (operator, primary_location, 'pos').
6. Operator connects Libro for primary location → backfill → demo-mode flips for (operator, primary_location, 'reservation').
7. Operator connects QuickBooks Time (operator-wide grant) → all locations get scheduling live → demo-mode flips for all (operator, *, 'scheduling').
8. Mobile app banner clears for primary_location once all 3 categories live; remains for any other locations still in demo.

This walkthrough is the V1 launch acceptance gate.

2026-05-04 closeout clarification:

- After Wave B adapter work lands, run `8.integration-mobile-proof` before
  accepting Phase 8 / 8R / 8.S as product-complete engineering. It may use
  fixtures, but must travel through real adapters, canonical facts, and mobile
  business read paths. This is proof-only: do not change app logic, business
  logic, mobile UI, adapter behavior, schema, migrations, or cloud/runtime
  behavior.
- After full live setup is ready, run `8.live.connected-device-smoke` on a
  connected device with one complete POS + reservation + labor/scheduling trio.
  This is the live counterpart to the fixture proof and should precede any
  all-17-vendor live rollout sweep. It is also proof-only; live findings become
  follow-up slices, not same-prompt fixes.
- Evidence and vendor-source context live in
  `docs/_execution/2026-05-04_vendor_api_access_and_mobile_e2e_gap.md`.

## Cross-references

- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` — Operator Web Console plan; `11W.0` shell.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — Phase 11A; `11A.1` operator create (already accepted).
- `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md` — email infrastructure for invites and alerts.
- `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md` — T&Cs click-through copy.
- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md` — parent compliance phase.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — vendor-connections widget hosted in onboarding.
- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — Phase 8 framework + demo-mode flip semantics.
- `docs/contracts/auth_permission_key_catalog.md` — permission keys.
