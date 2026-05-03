# Phase 9.8 — Inbound-Vendor T&Cs Draft

Updated: 2026-05-03
Status: Engineering / product draft pending legal review
Owner: Phase 9.8 lane (parallel to email-provider slice)

This is a **product draft for legal review** — copy and click-through flow for the inbound-vendor T&Cs operators agree to before connecting any POS / Reservation / Scheduling vendor. **Final version requires lawyer signoff before V1 launch.**

## Why this exists

Per Hard Promise #6 (advisor speaks in recommendations) and `cutover.2` non-negotiable ("no customer data is loaded before T&Cs acceptance is captured"), the operator must explicitly authorize Forge & Flow to access their vendor data before any inbound integration fires. This authorization needs:

- Plain-English summary the operator can read in under 90 seconds.
- Specific named data scopes per category (POS / Reservation / Scheduling).
- Sub-processor disclosure (vendors named, F&F backend named).
- Data retention + deletion rights.
- Legal binding via clickwrap acceptance.

The version below is the **product draft** — content + flow shape — for legal counsel to revise into final binding language.

## Click-through flow

Two click-through points:

### Point 1 — Universal authorization (during onboarding, Phase 11W.0)

Shown after password set + MFA enrolled, before operator lands on dashboard:

```
┌─────────────────────────────────────────────────────────────┐
│ Forge & Flow — Authorization to Access Your Business Data   │
│                                                             │
│ To run Forge & Flow, we need permission to read data from   │
│ your existing systems. By continuing, you authorize Forge & │
│ Flow Inc. to do the following ON YOUR BEHALF for [Business  │
│ Name]:                                                      │
│                                                             │
│ • Connect to your POS, reservation, and scheduling systems  │
│   when you click "Connect" on each one.                     │
│ • Read sales, covers, reservation, and labor data.          │
│ • Store this data in a secure database operated by F&F      │
│   (Microsoft Azure, Canada Central) for use in the F&F      │
│   product.                                                  │
│ • Stop reading data and delete what we've stored within     │
│   30 days of your written request.                          │
│                                                             │
│ We will never:                                              │
│ • Write back to your systems without a separate, explicit   │
│   approval flow (that's a future feature, not V1).          │
│ • Sell your data, share it with third parties for marketing │
│   purposes, or use it to train AI models for other          │
│   customers.                                                │
│ • Access guest names, emails, or other personally           │
│   identifiable details unless you opt in to that feature    │
│   later.                                                    │
│                                                             │
│ This authorization continues until you revoke it. You can   │
│ revoke at any time from Settings → Account → Privacy.       │
│                                                             │
│ See the full Terms of Service and Privacy Policy:           │
│ [Read Terms of Service]   [Read Privacy Policy]             │
│                                                             │
│ ☐ I have read and agree to the Terms of Service, Privacy    │
│   Policy, and the authorizations above.                     │
│                                                             │
│                              [Continue to Forge & Flow →]   │
└─────────────────────────────────────────────────────────────┘
```

Acceptance writes a row to `tos_acceptances` with: version, timestamp, IP, user-agent, operator_id, user_id, scope = `inbound_vendor_universal`.

### Point 2 — Per-vendor authorization (at first connect, Phase 8 vendor-connections widget)

Shown immediately before redirecting to a vendor's OAuth flow (or before validating a key-paste):

```
┌─────────────────────────────────────────────────────────────┐
│ Connect to {{Vendor Name}}                                  │
│                                                             │
│ You're about to authorize Forge & Flow to read data from    │
│ {{Vendor Name}} on behalf of [Business Name].               │
│                                                             │
│ Forge & Flow will read:                                     │
│ {{vendor-specific data scope list}}                         │
│                                                             │
│ Forge & Flow will not write any data back to {{Vendor Name}}│
│ Forge & Flow stores this data securely; you can disconnect  │
│ at any time.                                                │
│                                                             │
│ Sub-processors involved in handling this data:              │
│ • {{Vendor Name}} (the source you're connecting to)         │
│ • Microsoft Azure (database — Canada Central)               │
│ • Google Cloud Run (application runtime)                    │
│ • Firebase Authentication (your account)                    │
│                                                             │
│ ☐ I authorize Forge & Flow to read the listed data from     │
│   {{Vendor Name}} on behalf of [Business Name].             │
│                                                             │
│        [Cancel]                  [Authorize and Connect →]  │
└─────────────────────────────────────────────────────────────┘
```

Acceptance writes to `tos_acceptances` with scope = `inbound_vendor_{{vendor_id}}`. Then the OAuth (or key-paste) flow proceeds.

## Per-vendor data scope text (for the per-vendor click-through)

These are the lists shown in the per-vendor click-through {{vendor-specific data scope list}} placeholder. Each is plain English, not legal jargon — the legal binding lives in the universal T&Cs accepted at onboarding.

### POS vendors (Toast / Lightspeed / Square / Clover / Revel / Aloha / Oracle Simphony)

```
• Sales transactions for the last 60 days and ongoing
• Order timestamps (when orders open, close, get paid)
• Guest counts / covers when your POS records them
• Voids, refunds, and corrections
• Revenue centers and dining options when available
```

### Reservation vendors (Libro / OpenTable / SevenRooms / Tock)

```
• Reservation list for the last 60 days and ongoing
• Reservation status (booked, confirmed, arrived, seated, completed,
  cancelled, no-show)
• Party size and reservation time
• Status transition timestamps
• We do NOT read guest names, emails, or phone numbers at this time.
```

### Scheduling vendors (7shifts / QuickBooks Time / Agendrix / Humanity / Push Operations / ADP)

```
• Published schedule shifts for the last 60 days and ongoing
• Actual time punches (clock-in, clock-out, breaks)
• Employee role and department assignments
• Wage rates per role or per employee, when your scheduling system
  exposes them
• Approved-hours signal (when payroll periods are closed)
• We do NOT read employee Social Security numbers, addresses, or
  banking details. Those live in your payroll system, not ours.
```

## T&Cs version management

```sql
-- T&Cs version tracking
tos_versions (
  version_id UUID PRIMARY KEY,
  scope TEXT NOT NULL,                  -- 'inbound_vendor_universal' / 'inbound_vendor_toast' / etc.
  version_number TEXT NOT NULL,         -- '1.0.0' format
  effective_date DATE NOT NULL,
  body_markdown TEXT NOT NULL,          -- the actual copy
  superseded_by_version_id UUID,        -- nullable; references the next version
  created_at TIMESTAMPTZ DEFAULT now(),
  created_by UUID
)

-- Operator/user acceptance log
tos_acceptances (
  acceptance_id UUID PRIMARY KEY,
  operator_id UUID NOT NULL,
  user_id UUID NOT NULL,
  version_id UUID REFERENCES tos_versions,
  scope TEXT NOT NULL,                  -- mirrors tos_versions.scope
  ip_address INET,
  user_agent TEXT,
  accepted_at TIMESTAMPTZ DEFAULT now()
)
```

## Re-acceptance flow

When a T&Cs version is superseded:

1. F&F admin uploads new T&Cs version via Phase 11A.10 (status page family) or new admin route.
2. New version becomes effective on `effective_date`.
3. On operator's next session, app gates app-entry on re-acceptance of the new version (universal scope).
4. Per-vendor scope re-acceptance only when the vendor-specific data scope changes — not for universal copy edits.

## Acceptance Criteria for the Phase 9.8 inbound-vendor-T&Cs slice

- T&Cs draft above reviewed by counsel; final binding copy committed to repo.
- `tos_versions` + `tos_acceptances` schemas migrated.
- Onboarding-welcome screen (Phase 11W.0) gates app-entry on universal acceptance.
- Per-vendor click-through screen (Phase 8 vendor-connections widget) gates each first-connect on vendor-specific acceptance.
- Settings → Account → Privacy section (Phase 11W.7) renders acceptance history.
- T&Cs version uploader admin route (under Phase 11A) lets F&F admin publish new versions.
- Email notification fires (`tos_version_updated_notice`) when a new version supersedes.

## Cross-references

- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md` — parent Phase 9.8 plan.
- `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md` — email provider that fires `tos_version_updated_notice`.
- `docs/phases/phase_11W/operator_onboarding_flow.md` — flow that gates onboarding on universal T&Cs.
- `docs/phases/phase_8/vendor_connections_admin_surface.md` — vendor-connections widget that gates first-connect on per-vendor T&Cs.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — Phase 11A surfaces (T&Cs version uploader).
