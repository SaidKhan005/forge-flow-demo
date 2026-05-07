# Status Page Setup — `status.forgeflow.app`

Version: 1.0 (2026-05-07).
Owner: F&F engineering.
Target: live before `cutover.4` traffic flip (requirement for the stability watch).

## Purpose

`status.forgeflow.app` gives operators a real-time view of F&F service health without
requiring them to contact support. It also gives the on-call team a public-facing
communication channel for incident updates — reducing inbound support volume during outages.

---

## Vendor Recommendation: BetterStack (Uptime)

**Recommended vendor: BetterStack (https://betterstack.com/better-uptime)**

One-liner pros/cons:

| | BetterStack | Statuspage (Atlassian) | Instatus | Roll our own |
|--|------------|------------------------|----------|--------------|
| Setup time | < 1 day | 1–2 days | < 1 day | 2–4 weeks |
| Custom domain | Yes (free) | Yes (paid tier) | Yes | N/A |
| Incident updates | Yes | Yes | Yes | Build it |
| API for auto-posting | Yes | Yes | Yes | N/A |
| Price (V1 scale) | Free tier available | $29+/mo | Free tier | Engineering cost |
| GCP/Azure native | No (generic) | No | No | Yes |
| Monitors built-in | Yes (HTTP/TCP) | Via 3rd-party | Yes | Build it |
| **Verdict** | **Best fit for V1** | Overkill for V1 scale | Viable alternative | Not recommended pre-launch |

**Why BetterStack:**
- Free tier covers our V1 scale (5 monitors, 1 status page, 3 team members).
- Custom domain via CNAME in < 30 minutes.
- REST API lets the proxy post incident updates automatically when P1 alerts fire.
- Built-in uptime monitors replace the manual Cloud Monitoring uptime check dependency.
- Upgrade path is clear as operator count grows.

---

## Setup Steps

### 1. Create BetterStack Account

Go to https://betterstack.com and sign up. Use the F&F engineering email.

### 2. Create Status Page

In BetterStack → Status Pages → New:
- Name: `Forge & Flow Status`
- Subdomain: `forgeflow` (gives `forgeflow.betteruptime.com` as default)
- Custom domain: `status.forgeflow.app`

### 3. Configure Custom Domain (DNS)

Add a CNAME record in the `forgeflow.app` DNS zone:

```
status.forgeflow.app  CNAME  forgeflow.betteruptime.com
```

TTL: 300s initially; extend to 3600s once stable.

BetterStack issues a TLS certificate via Let's Encrypt automatically after DNS propagates.

### 4. Add Service Components

Create the following components in BetterStack → Status Page → Components:

| Component name | Description |
|----------------|-------------|
| Operator Web Console | `app.forgeflow.app` — web dashboard for operators |
| Mobile Sync | Push notifications and real-time sync to mobile app |
| Vendor Integrations | POS, scheduling, and reservation data connectors |
| AI Advisor | Labor cost advisor and recommendations |
| Authentication | Login, MFA, and session management |

### 5. Add Uptime Monitors

Create HTTP monitors for each critical endpoint:

| URL | Check interval | Alert after |
|-----|---------------|-------------|
| `https://app.forgeflow.app/` | 30s | 2 failures |
| `https://api.forgeflow.app/health` | 30s | 2 failures |

Each monitor should be linked to its corresponding status page component so failures
automatically update the component status.

### 6. Connect PagerDuty Alerts to Status Page

BetterStack supports PagerDuty integration. Configure:
- P1 alerts → auto-create "Investigating" incident on the status page.
- On PagerDuty incident resolve → auto-resolve the status page incident.

This ensures operators see real-time status without requiring manual on-call action
during every P1 event.

### 7. Configure Notification Subscribers

Enable subscriber notifications:
- Email subscription for operators who opt in.
- RSS feed for automated monitoring.
- Webhook for internal Slack `#status-updates` channel.

---

## Incident Communication Template

When an incident is active, use this template for status page updates:

**Investigating:**
```
We are investigating reports of [component] issues affecting some operators. 
Our team has been notified and is actively investigating. 
Next update in 30 minutes.
```

**Identified:**
```
We have identified the cause of the [component] issue: [one-line root cause]. 
We are working on a fix. 
Estimated resolution: [time].
Next update in 30 minutes or sooner.
```

**Resolved:**
```
The [component] issue has been resolved. 
Root cause: [brief description].
Duration: [X] minutes.
We have implemented [mitigation] to prevent recurrence.
We apologize for the disruption.
```

---

## Maintenance Windows

Planned maintenance should be pre-announced on the status page at least 30 minutes before
the window opens. In BetterStack: Status Page → Maintenance → Schedule Maintenance.

Maintenance window procedure:
1. Schedule the window in BetterStack before starting any maintenance.
2. Post to `#eng-oncall` Slack channel simultaneously.
3. After maintenance completes, close the window in BetterStack.
4. Add a post-maintenance note confirming the work completed successfully.

---

## Apply History

This plan is implemented at `cutover.4` preflight. Record the go-live date here
once `status.forgeflow.app` DNS is confirmed propagated and the status page is live:

| Date | Action | Operator |
|------|--------|----------|
| TODO | DNS propagated; status page live | — |
