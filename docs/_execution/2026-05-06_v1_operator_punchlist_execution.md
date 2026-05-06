# V1 Operator Punchlist — Execution Evidence

Date: 2026-05-06
Owner: Operator (Vanessa / founder)
Status: Production1 runtime is live behind staging-style chrome; one DNS
switch + four validation checks remain to flip the action surface to
production-branded.

This doc captures what's done, what's left, and how the operator
resumes after a context break. It pairs with the engineering-side V1
closure dispatch plan at
`docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`.

## Current Production1 runtime status

- **GCP / Cloud Run.** Production1 services are deployed and reachable
  through the production proxy URL. Static egress VPC + Cloud Run +
  Secret Manager namespace `forge-flow-production-*` are provisioned
  and Browser-Use-verified against staging-parity behavior.
- **Firebase project.** `forge-flow-production1` is the live Firebase
  app. Mobile + web + admin builds resolve `firebase-config.js` to
  `forge-flow-production1` for every domain whose DNS already points
  there.
- **Postgres / Azure.** `forge-flow-production1-pg-cmk` (Canada
  Central, PG 16, CMK-enabled) is the live database.
  10 of 12 follow-up migrations are applied + verified on staging;
  the 2 remaining need an explicit operator decision before apply
  (see "Remaining non-DNS blockers" below).
- **DNS + TLS — production app domain.** `app.forgeflow.app` is
  resolving and TLS is live. The operator-web console renders against
  Production1 from this domain.
- **DNS + TLS — production email domain.** `mail.forgeflow.app` is
  resolving with DKIM/SPF/DMARC published. SendGrid domain auth is
  green for the production sender. Outbound mail is functional from
  the cleaner `noreply@feflow.org` sender — that's already good
  enough for V1 launch; template body styling polish is gated on
  Firebase's template gate (nice-to-have, not blocking).
- **DNS + TLS — Firebase Auth action domain.** `auth.feflow.org`
  currently resolves to `forge-flow-staging.web.app`. **This is the
  one remaining production switch.** See "Main remaining DNS action"
  below.

## Main remaining DNS action

Switch `auth.feflow.org` from staging to Production1 and finalize the
Firebase Auth action surface.

### Step 1 — DNS switch

- [ ] Repoint `auth.feflow.org` from `forge-flow-staging.web.app` to
      `forge-flow-production1.web.app` in the DNS provider.
- [ ] Wait for propagation (typical 15–60 min; verify via
      `nslookup auth.feflow.org` or `dig auth.feflow.org +short`).

### Step 2 — Firebase Auth config switch (after propagation)

- [ ] In the Firebase console for `forge-flow-production1`, set the
      Auth action handler (callbackUri) to:
      `https://auth.feflow.org/auth/action`
- [ ] Save and confirm the new URI is reflected in the action-handler
      verification panel.

### Step 3 — Validation (after Steps 1 + 2)

- [ ] **Branded production page.**
      `https://auth.feflow.org/auth/action` loads the branded
      production action page (not the staging chrome).
- [ ] **Production firebase-config.js.** Inspect the page and confirm
      `firebase-config.js` resolves to `forge-flow-production1` (not
      staging).
- [ ] **Branded reset link.** Trigger a password reset for a
      production user; the email link opens the branded production
      action page.
- [ ] **Production proxy receives confirmation.** Complete the
      password reset and confirm the proxy log shows the password
      reset confirmation hitting the production proxy URL (not the
      staging proxy).

### Notes on cosmetic polish

- **Template body styling is a nice-to-have.** Custom body styling for
  Firebase Auth emails is gated on Firebase's email template
  customization gate (Auth product) and is not part of the launch
  critical path.
- **Sender domain.** `noreply@feflow.org` is already clean enough; no
  rebrand to `noreply@forgeflow.app` is needed for V1.

## Remaining non-DNS blockers

### Decide and approve the two Production1 migration applies

Two of the 12 follow-up migrations remain pending an explicit
operator decision before staging-apply + Production1-apply runs. Both
are code-ready and queued in the runbook
`runbooks/phase_9_production1_migration_apply_runbook.md`.

- [ ] **`202605061800_phase_8_first_connection_backfill_jobs.sql`.**
      Operator-scoped durable first-connection backfill job table —
      the server-side enqueue / claim / status seam shipped by
      `8.first-connect-backfill-wire-in` (PR #195, ACCEPT 2026-05-06).
      Decision required: approve staging apply + Production1 apply
      sequencing. Mobile remains a cache; no worker logic activates
      from this migration alone.
- [ ] **`202605070000_phase_11W_7_operator_account_fields.sql`.**
      Additive editable business-identity columns the operator-web
      `PATCH /v1/operator/account` route writes (`logo_url`,
      `locale_tag`, `week_start_day`, `rollover_hour`) plus format
      CHECK constraints + `business_name` length CHECK. RLS unchanged
      on `public.operators`. Decision required: approve staging apply
      + Production1 apply.

After approval: run the runbook live-mutation gate, then the apply
order section. The runbook codifies the BLOCKED checklist; following
it is sufficient.

### Send inbound T&Cs to counsel

- [ ] **Escalate inbound-vendor T&Cs to lawyer.** Draft is in
      `docs/phases/phase_9_8/`. Suggested deadlines: first pass
      2026-05-10, final 2026-05-13. Without signed T&Cs there is no
      `tos_acceptances` row, so `cutover.2` (first operator
      onboarding) cannot run. _Effort: 3–7 days external._

### Provision live-trio vendor sandbox credentials

Each of the three trio vendors needs sandbox credentials before its
matching `*.live.sandbox` slice can run. None gates the V1 product
proof — they gate the lifecycle promotion to `sandbox_verified`.

- [ ] **Lightspeed K-Series sandbox.** Apply at
      `developer.lightspeedhq.com` and capture the sandbox client
      id/secret + tenant id. Store in GCP Secret Manager namespace
      `forge-flow-production-*` per the credential rotation runbook.
- [ ] **Libro sandbox.** Request a test account from the Libro
      partner contact; capture API key + base URL. Store in Secret
      Manager.
- [ ] **QuickBooks Time sandbox.** Create an Intuit developer sandbox
      and OAuth app; capture client id/secret. Store in Secret
      Manager.

_Effort: 2–3 days, mostly waiting on vendor turnaround. Soft-blocks:
`8.LSK.live.sandbox`, `8.LB.live.sandbox`, `8.QBT.live.sandbox`.
Engineering scaffolding is ready; the slice runs the moment creds
land._

## What is fully complete (no operator action needed)

- GCP / Cloud Run / Secret Manager / VPC provisioning.
- Firebase project + mobile + web + admin app registration.
- Production1 Postgres CMK provisioning (`cutover.0a` / `0a.pg`
  closed 2026-05-01).
- DNS + TLS for `app.forgeflow.app` and `mail.forgeflow.app`.
- SendGrid domain auth + DKIM/SPF/DMARC for the production sender.
- 10 of 12 follow-up Postgres migrations applied + verified on
  staging.

## How to resume after a context break

1. Open this doc.
2. If the DNS switch step is still open, follow "Main remaining DNS
   action" Steps 1, 2, 3 in order.
3. If the migration applies are still open, follow
   `runbooks/phase_9_production1_migration_apply_runbook.md`
   live-mutation gate.
4. If T&Cs are still open, ping counsel.
5. If trio sandbox creds are still open, ping vendor portals.
6. The four boxes above are the entire operator critical path between
   today and `cutover.0` pre-flight.

## Cross-references

- `docs/_execution/2026-05-05_v1_launch_punchlist.md` Section 0 —
  short-form mirror of this doc for at-a-glance status.
- `runbooks/phase_9_production1_migration_apply_runbook.md` — the
  apply-time runbook to execute.
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
  — `cutover.0` → `cutover.4` sequence that begins after this
  punchlist closes.
- `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md` —
  engineering-side seven-lane dispatch (V1.A/B/C/D/E/F/G).
