# Account Screen Field Parity Audit
> Wave 2 Phase 2 Closeout — OW-2a — 2026-05-14

## Purpose

Enumerate every field on the admin-side Account-related surfaces and the
operator-web Account screen. For each field identify:

- Whether both screens expose it
- Whether one screen hides it (and why)
- Whether the field is editable, view-only, or restricted
- Whether HP #11 hierarchy scope (Business / Region / Location) is honored

This audit informs V1.1 priorities. Any gap flagged as "should be added to
operator-web" goes into the ledger. Gaps flagged as "intentional admin-only"
stay as-is.

## Methodology

Walked each Account-related screen on both consoles via code inspection.
Cross-referenced data shapes against the proxy gateway contract
(`WebAccountGateway` + `OperatorLocationAdminGateway`), the
`OperatorWebSession` projection, and the
`OperatorAdminRecord` / `LocationAdminRecord` schema mirrors.

There is **no single "Account" screen on the admin console.** The
admin-side surface area splits across three places:

1. **`MyAccountAdminScreen`** — the F&F-admin user's own sign-in identity
   (display name, email, role, MFA, sessions). The user-identity sibling
   to the operator-web `MyAccountScreen`. **Not** a business-account
   editor.
2. **`OperatorLocationAdminScreen`** detail panel (`_OperatorDetail`) +
   the `_EditOperatorDialog` ("Account profile") + the
   `_OnboardOperatorDialog` ("New operator") — where the admin reads and
   writes the customer business's identity, currency, subscription tier,
   primary location.
3. **`OperatorLocationAdminScreen`** location dialogs
   (`_LocationDialog`) — where the admin reads and writes a customer
   location's timezone + business-day rollover hour.

The operator-web `AccountScreen` is the customer-facing analogue of #2
and #3 combined (no per-user identity — that lives on `MyAccountScreen`).

This audit therefore walks the operator-web `AccountScreen` field set
against the admin's #2 + #3 surfaces. The per-user `MyAccountAdminScreen`
vs `MyAccountScreen` comparison is **out of scope** here (it is a
different parity question, already addressed by Wave 2 W-3 + W-4).

## Account / Business identity fields

The admin shows these on `_OperatorDetail` (read) +
`_EditOperatorDialog` ("Account profile") (write) +
`_OnboardOperatorDialog` ("New operator") (create).

| Field | Admin (read on detail / write in dialogs) | Operator-web Account | Editable in admin? | Editable in ops-web? | HP #11 scope | Notes |
|---|---|---|---|---|---|---|
| `business_name` | ✓ detail row "Business name" + edit dialog field `admin_edit_business_name` | ✓ "Business name" `operator_web_account_business_name` | ✓ | ✓ (Business only) | Business-wide; Location scope disables editor with "set at the Business level" helper text | Single business name doctrine — no per-location override column |
| `logo_url` | ✗ (no field on admin onboard/edit dialog or detail row) | ✓ "Logo URL (https only)" `operator_web_account_logo_url` + `BusinessLogoUploadSection` (Azure Blob file upload, W-5) | ✗ | ✓ (Business only) | Business-wide; disabled at Location scope | **Operator-web-only.** Admin cannot set the customer's logo today. |
| `owner_email` (admin model) / "Contact email" (admin UI label) | ✓ detail row "Contact email" + edit dialog `admin_edit_owner_email` | ✓ "Contact email" `operator_web_account_contact_email` (renders Business or Location scope) | ✓ | ✓ (Business + Location) | Business-wide on `operators.owner_email`; per-location override on `location_account_overrides.contact_email` (U-FU-hp11-account-schema) | Operator-web exposes an additional **per-location** override that admin cannot edit |
| `contact_phone` | ✗ (no admin field for business contact phone; admin only collects login+contact email) | ✓ "Contact phone" `operator_web_account_contact_phone` | ✗ | ✓ (Business + Location) | Per-location override + business default on `location_account_overrides.contact_phone` | **Operator-web-only.** No admin write path exists. |
| `operator_id` | ✓ implicit (admin selects by id; not rendered as a labeled detail row) | ✗ | ✗ | ✗ | N/A — opaque internal id | Admin-only by design |
| `suspended_at` (status) | ✓ "suspended" status pill + Suspend / Reactivate action buttons | ✗ | ✓ (Suspend/Reactivate buttons) | ✗ | N/A | Admin-only; operator cannot suspend their own account |
| `created_at` / `updated_at` | ✗ (not rendered in detail card) | ✗ | ✗ | ✗ | N/A | Backend audit columns; neither console exposes |
| `primary_location_id` | ✓ detail row "Primary location" + edit dialog `_PrimaryLocationDropdown` | ✗ (operator-web reads `session.primaryLocationId` for routing but does not let the operator edit which location is primary from the Account screen) | ✓ | ✗ | Business-wide pointer | **Gap — see "Open questions".** |
| `admin_user_email` (onboard-only) | ✓ onboard dialog field `admin_onboard_admin_email` ("Owner login email") | ✗ | ✓ on create | ✗ | N/A — provisioning-time only | Admin-only; operator-web `AccountScreen` does not control admin invites |

## Region + formatting fields

| Field | Admin | Operator-web Account | Editable in admin? | Editable in ops-web? | HP #11 scope | Notes |
|---|---|---|---|---|---|---|
| `preferred_currency` / `currencyCode` | ✓ detail row "Currency" + edit dialog `_CurrencyDropdown` + onboard `_CurrencyDropdown` | ✓ `operator_web_account_currency` dropdown (6-entry shortlist USD/CAD/EUR/GBP/AUD/MXN) | ✓ | ✓ (Business + Location) | Business default on `operators.preferred_currency`; per-location override on `location_account_overrides.currency_code` | Operator-web exposes Location override that admin cannot edit |
| `locale_tag` / `localeCode` | ✗ (no admin picker) | ✓ `operator_web_account_locale` dropdown (6-entry shortlist en-US/en-CA/fr-CA/en-GB/en-AU/es-MX) | ✗ | ✓ (Business + Location) | Business default on `operators` projection; per-location override on `location_account_overrides.locale_code` | **Operator-web-only.** Admin cannot set the customer's locale today. |

## Business week + rollover fields

| Field | Admin | Operator-web Account | Editable in admin? | Editable in ops-web? | HP #11 scope | Notes |
|---|---|---|---|---|---|---|
| `week_start_day` | ✗ (no admin picker; the admin's "Effective timing" preview only displays the value via `BusinessTimingProfileResolver`, no edit dialog) | ✓ `operator_web_account_week_start` dropdown (7 days) | ✗ | ✓ (Business only) | Business-wide; explicitly disabled at Location scope per slice scope ("no per-location override column for the first day of the week") | **Operator-web-only.** Admin can read it on the effective-timing preview but has no write path. |
| `business_day_rollover_hour` (operator default) | ✓ onboard dialog `_RolloverHourDropdown` (per-location seed) | ✓ `operator_web_account_rollover_hour` dropdown (0–23, "04:00 (recommended)") | ✓ on onboard only | ✓ (Business + Location) | Business default on `operators` projection; per-location override on `location_account_overrides.business_day_rollover_hour` | The admin onboard form only seeds the **primary location's** rollover hour; once onboarded, the admin edits rollover per-location in `_LocationDialog`. |

## Location-level fields (timezone + rollover)

These come from the admin's `_LocationDialog` (add + edit location) and
the operator-web Account screen's `_LocationTimezoneSection` (W-6).

| Field | Admin (`_LocationDialog`) | Operator-web Account | Editable in admin? | Editable in ops-web? | HP #11 scope | Notes |
|---|---|---|---|---|---|---|
| `location.name` | ✓ `admin_location_name_field` (also onboard `admin_onboard_location_name`) | ✗ (operator-web shows `session.primaryLocationName` in copy strings but no editor on the Account screen — location names live on the Locations screen surface elsewhere) | ✓ | ✗ on Account screen | Location-only | Operator-web Account screen does not own location naming |
| `location.address` | ✓ admitted by the gateway (LocationCreate/PatchCommand carry it), but `_LocationDialog` does **not** render an address field — the form only edits name + timezone + rollover | ✗ | ✗ in current admin UI | ✗ | Location-only | **Latent column on both sides.** Schema supports it (`locations.address`); neither screen exposes a writer. |
| `location.timezone` (IANA) | ✓ `admin_location_timezone_field` + `admin_onboard_location_timezone` | ✓ `operator_web_account_timezone_shortlist` + `operator_web_account_timezone_custom` (W-6) | ✓ | ✓ (Location scope — saves via `patchLocationTimezone` against the primary location) | Location-only; HP #11 notice says "Set here. Does not inherit from a higher scope." | The operator-web editor writes the **primary** location's tz only; non-primary locations require admin or Locations screen |
| `location.business_day_rollover_hour` | ✓ `_RolloverHourDropdown` in `_LocationDialog` | ✓ (covered by the Business-day card; per-location override above) | ✓ | ✓ (Business + Location) | Location override + Business default | See Business week + rollover row |
| `location.parent_org_unit_id` | ✓ admin passes `parentOrgUnitId` on `LocationCreateCommand` (`_OperatorLocationAdminScreenState` resolves it from the hierarchy panel) | ✗ | ✓ on create | ✗ | Hierarchy plumbing | Admin-only — operator-web does not own the org-unit tree |
| `location.suspended_at` / `deleted_at` | ✓ admin can remove a location (`onRemoveLocation`) | ✗ | ✓ | ✗ | Location lifecycle | Admin-only |

## Subscription + billing fields

| Field | Admin | Operator-web Account | Editable in admin? | Editable in ops-web? | HP #11 scope | Notes |
|---|---|---|---|---|---|---|
| `subscription_tier` (a.k.a. "Forge & Flow AI plan" in the UI) | ✓ detail row "Forge & Flow AI plan" + `_SubscriptionTierDropdown` on both onboard + edit dialogs | ✗ | ✓ | ✗ | Business-wide | **Intentional admin-only.** Plan selection is a billing decision the operator self-serves through F&F sales today, not the Account screen. |
| Billing payment method / invoices / payment status | ✗ (not on admin My Account or operator/location admin screen) | ✗ | ✗ | ✗ | N/A | Neither console exposes — billing UX is not in scope for V1. |

## Identity-card sibling fields (admin My Account ↔ operator-web My Account)

Listed for completeness; the bulk of the parity check above lives in
**business-account** territory. This row table only flags fields the
two **personal** Account screens diverge on, in case the operator wants
both surfaces audited.

| Field | Admin My Account (`my_account_admin_screen.dart`) | Operator-web My Account (`my_account_screen.dart`) | Notes |
|---|---|---|---|
| `display_name` | ✓ read + Edit identity dialog (W-3) | ✓ read + Edit profile dialog (W-3) | Parity reached at Wave 2 W-3 |
| `email` | ✓ read + Edit identity dialog | ✓ read + Edit profile dialog | Parity reached at Wave 2 W-3 |
| `phone` | ✗ (no admin column) | ✓ read-only, with copy pointer to mobile app for edits | Admin has no analogue (admins are F&F-internal staff; no contact phone column on `admin_users`) |
| `role` | ✓ Ecosystem admin / Support access role badge | ✓ Owner / Admin / Manager role badge | Different role taxonomies — F&F-internal admin roles vs. operator-internal roles |
| MFA status + factors | ✓ read-only; changes routed to sign-in page | ✓ Enroll / View backup codes flow (W-3) | Admin MFA enrollment intentionally stays on sign-in; operator-web exposes inline mutations |
| Active sessions | ✓ single "this device" row + sign-out, with note that a richer list is not exposed yet | ✓ full per-session list with "sign out all other sessions" (Phase 11W.7) | Admin sessions gateway not yet implemented — intentional per W-4 brief |
| Scope label | ✓ "Global — cross-operator" | ✓ Business / Region / Location via Managing picker | Different by design (admin is cross-operator; operator-web is scoped) |

## Intentional gaps (admin-only by design)

- **`operator_id`** — internal opaque id, never user-facing on either console.
- **`subscription_tier`** — billing-class field. Sales-led process at V1; the operator-web Account screen would mislead the operator into thinking they can self-change a plan. Stays admin-only.
- **`suspended_at` + Suspend / Reactivate buttons** — F&F-internal trust-and-safety control.
- **`admin_user_email`** on onboard — provisioning seed; operator-web "Members" surface owns ongoing invites.
- **`parent_org_unit_id`** on locations — the org-unit tree is admin-managed at V1.
- **`location.suspended_at` / `deleted_at`** — lifecycle controls live with the admin who handles offboarding.
- **`admin_users` schema differences (no phone, different role taxonomy)** — admins are F&F-internal staff; the schema diverges intentionally.

## Operator-web-only fields (admin has no write path today)

These are **not** gaps to backfill into admin unless the operator says
otherwise — they are operator self-serve features that F&F support
ordinarily would not change on the customer's behalf.

- **`logo_url`** — operator-web only via `BusinessLogoUploadSection` (Azure Blob) + URL-paste fallback. Admin has no upload path.
- **`locale_tag` / `localeCode`** — operator-web only. Admin can see the value indirectly on the effective-timing preview but has no editor.
- **`week_start_day`** — operator-web only. Admin reads the rolled-up effective value but has no editor.
- **`contact_phone`** — operator-web only (per-location override + business default).
- **Per-location overrides** (`location_account_overrides.*`) for `currency_code`, `locale_code`, `business_day_rollover_hour`, `contact_email`, `contact_phone` — operator-web only via the U-FU-hp11-account-schema slice. Admin's `_EditOperatorDialog` and `_LocationDialog` do not touch the override table.

## Unintentional gaps (candidates for V1.1 ledger)

Conservative list. Each item is a field that an operator could plausibly
expect to manage from their own Account screen but cannot today:

- *(none flagged with high confidence)* — every operator-web-only field above is genuinely operator-self-serve and the absence on admin is fine. The reverse direction (admin-only fields missing from operator-web) is either intentionally admin-only (suspension, plan, org-unit tree) or already covered by a different operator-web surface (location naming on the Locations screen, primary-location selection on the Locations screen, member management on Members).

## Open questions for operator

1. **Primary-location selection** — admin's `_EditOperatorDialog` lets the F&F admin re-point the operator's primary location via `_PrimaryLocationDropdown`. Operator-web has no equivalent affordance on the Account screen (operators can rename locations on the Locations screen, but cannot mark a different one as primary). Options:
   - (a) Keep admin-only — primary location designation has cascading effects (default scope on cold start, default deep links, mobile shell default).
   - (b) Add a "Primary location" picker on the operator-web Locations screen (not on Account — Account is business-identity, Locations is the place).
   - (c) Add it on operator-web Account screen at Business scope.

   Audit-author recommendation: **(b)** if the operator wants self-serve; otherwise **(a)**.

2. **Logo upload on admin** — should F&F support staff be able to upload a customer's logo on the customer's behalf (e.g. during onboarding, before the operator signs in)? Today the admin onboard dialog does not accept a logo; the operator must upload it themselves post-sign-in via operator-web. Options:
   - (a) Keep operator-self-serve only — the current state.
   - (b) Add a logo URL paste field to admin onboard (mirroring operator-web's URL paste).
   - (c) Wire admin onboard to the same `BusinessLogoUploadSection` Azure Blob uploader.

   Audit-author recommendation: **(a)** unless onboarding feedback reveals operators frequently delay logo upload — in which case **(b)** is the cheap follow-up.

3. **Locale + week-start on admin** — operator-web exposes locale and week-start day editors but admin has no equivalents. Should the admin's `_EditOperatorDialog` mirror those fields so F&F support can fix a misconfigured operator without asking them to sign in? Options:
   - (a) Keep operator-only — locale and week-start are settings the operator owns; F&F should not change them.
   - (b) Add read-only mirrors to admin (visibility-only).
   - (c) Add edit mirrors to admin (full parity).

   Audit-author recommendation: **(b)** — operator owns the value but F&F should be able to *see* what the operator chose during support escalations.

## Authority anchors

Every claim above maps to one of these locations.

- `lib/operator_web/screens/account_screen.dart:65-215` — `AccountScreen` widget signature, HP #11 scope handling.
- `lib/operator_web/screens/account_screen.dart:255-306` — region / locale / week-start shortlists + custom-tz sentinel.
- `lib/operator_web/screens/account_screen.dart:308-415` — `initState` + `_loadLocationOverrides` envelope wiring.
- `lib/operator_web/screens/account_screen.dart:431-510` — `_handleSave` routes Business vs. Location scope to `patchAccount` vs. `patchLocationAccountOverrides`.
- `lib/operator_web/screens/account_screen.dart:523-572` — `_handleSaveTimezone` for the per-location IANA tz writer.
- `lib/operator_web/screens/account_screen.dart:982-1163` — `_BusinessIdentitySection` (business name, logo URL + upload, contact email, contact phone).
- `lib/operator_web/screens/account_screen.dart:1215-1312` — `_RegionSection` (currency + locale).
- `lib/operator_web/screens/account_screen.dart:1314-1438` — `_BusinessDaySection` (week-start day + rollover hour).
- `lib/operator_web/screens/account_screen.dart:1459-1667` — `_LocationTimezoneSection`.
- `lib/admin/screens/my_account_admin_screen.dart:57-174` — `MyAccountAdminScreen` skeleton (identity / security / sessions).
- `lib/admin/screens/my_account_admin_screen.dart:311-437` — `_AdminIdentityCard` (display name, email, role, scope).
- `lib/admin/screens/my_account_admin_screen.dart:473-530` — `_AdminSecurityCard` (MFA status, read-only).
- `lib/admin/screens/my_account_admin_screen.dart:593-703` — `_AdminActiveSessionsCard` (single "this device" row + sign-out).
- `lib/admin/screens/my_account_admin_screen.dart:738-996` — `_AdminEditIdentityDialog` (display name + email).
- `lib/admin/screens/operator_location_admin_screen.dart:1052-1128` — `_OperatorDetail` profile card (business name, contact email, AI plan, currency, primary location).
- `lib/admin/screens/operator_location_admin_screen.dart:4170-4313` — `_OnboardOperatorDialog` (business name, owner email, admin login email, subscription tier, currency, primary location name, location timezone, rollover hour).
- `lib/admin/screens/operator_location_admin_screen.dart:4315-4441` — `_EditOperatorDialog` ("Account profile") (business name, contact email, subscription tier, currency, primary location).
- `lib/admin/screens/operator_location_admin_screen.dart:4443-4570` — `_LocationDialog` (location name, timezone, rollover hour).
- `lib/admin/models/operator_location_admin_models.dart:24-74` — `OperatorAdminRecord` (operator_id, business_name, owner_email, subscription_tier, preferred_currency, primary_location_id, suspended_at).
- `lib/admin/models/operator_location_admin_models.dart:76-136` — `LocationAdminRecord` (location_id, operator_id, parent_org_unit_id, name, address, timezone, business_day_rollover_hour, suspended_at, deleted_at).
- `lib/admin/models/operator_location_admin_models.dart:168-247` — `OperatorOnboardCommand` + `OperatorPatchCommand` wire shapes.
- `lib/admin/models/operator_location_admin_models.dart:249-315` — `LocationCreateCommand` + `LocationPatchCommand` wire shapes.
- `lib/operator_web/services/web_account_gateway.dart:31-86` — `WebAccountGateway` interface (getAccount / patchAccount / patchLocationTimezone / patchSelfProfile / get+patchLocationAccountOverrides).
- `lib/operator_web/services/web_account_gateway.dart:473-511` — `AccountIdentityPatch` (businessName, logoUrl, currencyCode, localeTag, weekStartDay, rolloverHour).
- `lib/operator_web/services/web_account_gateway.dart:537-572` — `AccountLocationTimezone` + patch.
- `lib/operator_web/services/web_account_gateway.dart:576-634` — `AccountIdentity` resolved row.
- `lib/operator_web/services/web_account_gateway.dart:793-857` — `LocationAccountOverridesPatchPayload` (ianaTimezone, localeCode, currencyCode, businessDayRolloverHour, contactEmail, contactPhone + clear flags).
- `lib/operator_web/services/web_account_gateway.dart:863-965` — `LocationAccountOverridesEnvelope` + `LocationAccountOverridesFieldSet`.
- `lib/auth/auth_session.dart:17-172` — mobile-shell `AuthSession` (no business-account writer fields; logo_url projection only).
- `lib/operator_web/auth/operator_web_auth_source.dart:46-127` — `OperatorWebSession` carries the read-side projection the Account screen seeds from.
- `debug.md:116-122` — operator request that prompted this audit ("Business account: -> Need to first do an audit of what is not exposed when business is being setup vs what is exposed as editable.").
