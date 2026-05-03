# Walkthroughs Index

Each accepted slice that ships operator-visible behavior writes a walkthrough
here. The walkthrough is the demo-mode evidence + contract cross-link
required by Hard Promise #10 (every backend phase ships its operator-facing
UX before phase close).

A complete walkthrough has three parts:
1. **Demo-mode entry steps** — the click path that reproduces the new
   behavior in `flutter run -d chrome` (or the admin console).
2. **Evidence** — DOM-text snippet, screenshot path, or test reference
   that proves the change shipped.
3. **Contract / plan cross-link** — points back to the authority doc
   the slice closes against.

For browser-exposed slices, include a short Browser Acceptance block from
`runbooks/browser_use_acceptance_harness_runbook.md`: exact origin,
routes swept, primary click path, desktop/mobile evidence, and safe-action
boundary.

When a slice has both an audit pass and a fix pass, both walkthroughs
live here side-by-side (e.g. `7.58.0.md` audit + `7.58.UX.5.md` fix).

## Phase 7.58 — Primary Driver

| File | Slice | Notes |
|---|---|---|
| [`7.58.0.md`](7.58.0.md) | `7.58.0` | Contract pin; 31/32 rules MET; F-1 deferred to UX.5 |
| [`7.58.5.md`](7.58.5.md) | `7.58.5` | Variance row purity (drop daypart driver carry-forward) |
| [`7.58.UX.5.md`](7.58.UX.5.md) | `7.58.UX.5` | Variance day-row renderer honesty (F-1 / F-6 / F-7 closed) |

## Phase 7.61 — Driver-Key Audit (Phase-8 gate)

| File | Slice | Notes |
|---|---|---|
| [`7.61.0.md`](7.61.0.md) | `7.61.0` | Driver-key audit + contract pin; 21+1 tests; F-1/F-2/F-3 follow-ups identified |
| [`7.61.1.md`](7.61.1.md) | `7.61.1` | HistoryTeachingAnalyzer lookup honesty; unknown ids degrade without summary/daypart escape |

## Phase 9.UX — Auth & Settings UX

| File | Slice | Notes |
|---|---|---|
| [`9.UX.0.md`](9.UX.0.md) + [audit](9.UX.0.audit.md) | `9.UX.0` | Permission-key + insertEvent audit walkthrough |
| [`9.UX.1.md`](9.UX.1.md) + [audit](9.UX.1.audit.md) | `9.UX.1` | MFA event_outbox enqueue audit |
| [`9.UX.2.md`](9.UX.2.md) | `9.UX.2` | Settings Team Roles catalog viewer + custom-role editor |
| [`9.UX.3.md`](9.UX.3.md) | `9.UX.3` | Settings Team "Explain permissions" surface |
| [`9.UX.4.md`](9.UX.4.md) + [audit](9.UX.4.audit.md) | `9.UX.4` | user_roles scope-payload CHECK + inheritance hint audit |
| [`9.UX.5.md`](9.UX.5.md) | `9.UX.5` | Settings Account Active Sessions viewer |
| [`9.UX.6.md`](9.UX.6.md) | `9.UX.6` | Self-service Audit Log surface |
| [`9.UX.7.md`](9.UX.7.md) | `9.UX.7` | Self-service password reset |
| [`9.UX.account-info.md`](9.UX.account-info.md) | `9.UX.account-info` | Settings Account info surface |
| [`9.UX.grant-payload.0.md`](9.UX.grant-payload.0.md) | `9.UX.grant-payload` | Per-grant scope + role label on team-users gateway |
| [`9.UX.inheritance-hint.0.md`](9.UX.inheritance-hint.0.md) | `9.UX.inheritance-hint` | Role-change dialog per-grant inheritance hints |

## Phase 10.5 — Shift Daypart

| File | Slice | Notes |
|---|---|---|
| [`10.5.0.md`](10.5.0.md) | `10.5.0` | Daypart toggle scaffold on Shift dashboard |
| [`10.5.1.md`](10.5.1.md) | `10.5.1` | Daypart bucketing engine (pure-function `DaypartBucketer`) |
| [`10.5.2.md`](10.5.2.md) | `10.5.2` | Per-period read service, Shift service-period cards, time-into-service, and Variance daypart lens |

## Phase 10a — Realtime Push Channel

| File | Slice | Notes |
|---|---|---|
| [`10a.0.md`](10a.0.md) | `10a.0` | Realtime push scaffold (NOTIFY → claim → in-process publisher → WebSocket) |

## Phase 11A — Operations Console

| File | Slice | Notes |
|---|---|---|
| [`11A.0.md`](11A.0.md) | `11A.0` | Flutter-for-Web bootstrap + brand styling + admin auth gate |
| [`11A.1.md`](11A.1.md) | `11A.1` | Operator + location management |
| [`11A.2.md`](11A.2.md) | `11A.2` | Pricing tier admin |
| [`11A.3a.md`](11A.3a.md) | `11A.3a` | Corpus admin + operator-picker unblock |
| [`11A.3b.md`](11A.3b.md) | `11A.3b` | Graphify candidate review console |
| [`11A.4.md`](11A.4.md) | `11A.4` | Integration management + KMS-stubbed key rotation |
| [`11A.5.md`](11A.5.md) | `11A.5` | Debug console request log + opt-in full-content gate + bounded live-tail |
| [`11A.6.md`](11A.6.md) | `11A.6` | Observability dashboard: bounded cost telemetry, dormancy, margins, cap events, graph, Cloud Run |

## Phase 9 Foundation Producers (B-series)

| File | Slice | Notes |
|---|---|---|
| [`B44.md`](B44.md) | `B44` | Graph health producer family (9 metrics; Decision-30 + Lock-3 thresholds) |

## Boundary Monitors

| File | Slice | Notes |
|---|---|---|
| [`E.3.md`](E.3.md) | `E.3` | (boundary monitor walkthrough) |
| [`F.1.md`](F.1.md) | `F.1` | (boundary monitor walkthrough) |

---

**Maintenance.** When you add a new walkthrough, add a row above. When a
phase fully closes (all sub-slices accepted, archive moved), move its
section to `docs/archive/walkthroughs/` and remove it here.
