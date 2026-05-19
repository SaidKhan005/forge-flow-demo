# Phase 9.8 — Email Provider Slice

Updated: 2026-05-03
Status: New slice; launch-blocking for operator-onboarding flow
Owner: Phase 9.8 lane (parallel to inbound-vendor T&Cs draft)

Transactional email infrastructure for Forge & Flow. Without this, operator-onboarding invites cannot fire, password-reset cannot complete, and vendor-sync error alerts cannot reach operators.

## Goal

Stand up a transactional email pipeline integrated with the Cloud Run proxy backend that can send branded transactional emails to operator users on demand and on cron triggers.

## Provider Decision

**SendGrid** (Twilio SendGrid). Reasoning:

- Strongest restaurant-industry SaaS familiarity (used by Toast, 7shifts, OpenTable, etc. — operators recognize sender domain reputation).
- Per-month pricing scales cheaper than alternatives at expected V1 volume (low-thousands of operators × low-tens of emails/month).
- Marketing API available (Phase 12+ when promotional emails are needed) without a second integration.
- Webhook event delivery (sent / opened / bounced / complaint) supports `mail_event` audit row for delivery tracking.
- Canadian-resident sender option available for PIPEDA-aware operators.

Alternatives considered + rejected:

- **Postmark** — strong reputation but higher per-email cost at our volume; no marketing API.
- **AWS SES** — cheapest but requires DKIM/SPF/DMARC setup overhead and no built-in template management; viable for V2 if SendGrid cost becomes an issue.
- **Resend** — modern API but smaller deliverability footprint; reconsider if SendGrid migration is ever needed.

Provider can be swapped via the `EmailProvider<T>` abstraction (mirrors `LLMProvider`/`EmbeddingProvider` shape per HP #8).

## Scope

`9.8.email-provider` owns:

- `EmailProvider<T>` abstraction in `lib/services/email/email_provider.dart` (server-side only — proxy / Cloud Run).
- SendGrid concrete implementation `lib/services/email/sendgrid_email_provider.dart`.
- `email_credentials` schema (single row for the F&F-platform-wide SendGrid API key, encrypted at rest, rotatable via existing Phase 11A.4 pattern).
- Cloud Run admin endpoint `POST /v1/admin/integrations/email/test` to send a test email.
- Outbound email worker — `pg_cron` job picking up `email_outbox` rows and dispatching via `EmailProvider`.
- `email_outbox` table — durable email queue with retry/idempotency (mirrors `event_outbox` pattern from Phase 10a).
- `email_event` table — delivery tracking from SendGrid webhooks.
- Domain authentication setup: DKIM + SPF + DMARC records on `mail.forgeflow.app` subdomain.
- Email templates: `operator_invite_first_admin`, `operator_member_invite`, `password_reset_request`, `mfa_factor_changed_notice`, `vendor_sync_error_alert`, `vendor_webhook_signature_alert`, `vendor_connection_auto_disabled`, `tos_version_updated_notice`. Templates rendered from Markdown to HTML at send time; brand-styled wrapper. Supersession note: `operator_admin_invite` was the old template name; active role language uses operator owner/manager/member.
- Phase 11A.4 integration: SendGrid API key visible in "Connected services" tab as a rotatable provider key (alongside Anthropic, Voyage, Azure DB, Gemini).

Does not own:

- Marketing emails (V2 scope).
- SMS / push notifications (separate channels; out of scope for V1).
- Operator-facing inbox UI (operators receive emails in their own inbox, not in F&F app).

## Schema

```sql
-- Outbound email queue (durable; retry-aware)
email_outbox (
  email_id UUID PRIMARY KEY,
  operator_id UUID,                   -- nullable for system / F&F-internal emails
  user_id UUID,                       -- recipient
  recipient_email TEXT NOT NULL,
  template_id TEXT NOT NULL,
  template_data JSONB NOT NULL,       -- variables for template rendering
  scheduled_for TIMESTAMPTZ NOT NULL DEFAULT now(),
  status TEXT NOT NULL DEFAULT 'pending',  -- 'pending' / 'sending' / 'sent' / 'failed' / 'bounced' / 'complaint'
  attempt_count INT DEFAULT 0,
  last_attempt_at TIMESTAMPTZ,
  last_error TEXT,
  provider_message_id TEXT,           -- SendGrid X-Message-Id
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
)

-- Delivery event log from provider webhooks
email_event (
  event_id UUID PRIMARY KEY,
  email_id UUID REFERENCES email_outbox,
  event_kind TEXT NOT NULL,           -- 'delivered' / 'opened' / 'clicked' / 'bounced' / 'complaint' / 'unsubscribed'
  event_payload JSONB,                -- raw provider payload
  occurred_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ DEFAULT now()
)
```

`pg_cron` worker picks up `email_outbox` rows where `status = 'pending'` and `scheduled_for <= now()`, sets `status = 'sending'`, calls SendGrid API, updates `status = 'sent'` or `failed` with retry. 3-strike rule: `attempt_count >= 3` → `status = 'failed'` with admin alert.

## Templates (V1 set)

| Template ID | Subject pattern | Trigger |
|---|---|---|
| `operator_invite_first_admin` | "Welcome to Forge & Flow — set up your account" | Phase 11A.1 operator creation |
| `operator_member_invite` | "{{Inviter}} invited you to join {{Business}}" | Phase 11W.1.write member invite |
| `password_reset_request` | "Reset your Forge & Flow password" | Phase 9 password reset |
| `mfa_factor_changed_notice` | "Your Forge & Flow MFA has been updated" | Phase 9 MFA enroll/remove |
| `vendor_sync_error_alert` | "Forge & Flow couldn't sync from {{Vendor}}" | Connector status `error` ≥ 1h |
| `vendor_webhook_signature_alert` | "Suspicious webhook activity from {{Vendor}}" | Repeated signature verification failures |
| `vendor_connection_auto_disabled` | "{{Vendor}} connection disabled" | OAuth refresh fails 3× |
| `tos_version_updated_notice` | "Forge & Flow Terms of Service updated" | T&Cs new version |

Templates committed to repo at `tool/advisor_proxy/email_templates/*.md` (Markdown source; HTML rendering at send time with brand wrapper).

## Domain Authentication

Required before any production email can send:

- DKIM record on `mail.forgeflow.app`.
- SPF record `v=spf1 include:sendgrid.net ~all`.
- DMARC record `v=DMARC1; p=quarantine; rua=mailto:dmarc@forgeflow.app`.
- Verified sender identity in SendGrid dashboard.

Operator action: provision DNS records before slice spawn.

## Acceptance Criteria

- `EmailProvider` abstraction in place; SendGrid concrete implementation tested against SendGrid sandbox.
- `email_outbox` + `email_event` schemas migrated.
- `pg_cron` worker dispatches pending emails on 1-min cadence.
- `POST /v1/admin/integrations/email/test` sends a test email and surfaces in 11A.4.
- All 8 V1 templates rendered correctly (preview + actual send).
- Bounce / complaint webhook from SendGrid lands in `email_event` and updates `email_outbox.status` accordingly.
- Operator-onboarding walkthrough (operator_invite_first_admin) end-to-end green.

## Dependencies

- **Phase 11A.4** Integration management (already accepted) — SendGrid API key rotation lives here.
- **Phase 9** auth (already accepted) — recipient resolution comes from `users` table.
- **Phase 9.8 inbound-vendor T&Cs draft** — T&Cs version-update template depends on T&Cs surface.
- **DNS records** for `mail.forgeflow.app` (operator action).
- **SendGrid account** + API key (operator action).

## Cost Estimate

SendGrid pricing as of 2026-05-03:

- Free tier: 100 emails/day forever.
- Essentials 50K: $19.95/mo for 50K emails.
- Pro 100K: $89.95/mo for 100K emails.

V1 expected volume: ~50 operators × ~30 emails/month per operator = 1,500/month. Free tier covers V1 with margin. Upgrade to Essentials at ~50 operators / ~150 emails/day; cap-event-style alert when nearing free-tier ceiling.

## Cross-references

- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md` — parent Phase 9.8 plan.
- `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md` — sibling slice; T&Cs new-version template depends on T&Cs surface.
- `docs/phases/phase_11W/operator_onboarding_flow.md` — onboarding flow that fires the first email.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — Phase 11A.4 integration management hosts SendGrid key rotation.
