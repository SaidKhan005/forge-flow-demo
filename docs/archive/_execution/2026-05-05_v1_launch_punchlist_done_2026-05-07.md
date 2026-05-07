# V1 Launch Punchlist — Items closed before 2026-05-07 trim

Captured from `docs/_execution/2026-05-05_v1_launch_punchlist.md` when the
working punchlist was trimmed to "open-only" on 2026-05-07. This file is
history; do not re-read mid-execution. Original commit history is
authoritative.

## Operator critical path — done

- [x] GCP / Cloud Run / Secret Manager / VPC provisioning.
- [x] Firebase project (`forge-flow-production1`) + mobile + web + admin
      app registration.
- [x] Production1 Postgres CMK (`forge-flow-production1-pg-cmk`, Canada
      Central, PG 16); `cutover.0a` / `0a.pg` closed 2026-05-01.
- [x] DNS + TLS for `app.forgeflow.app` (operator-web production
      domain) and `mail.forgeflow.app` (production email domain).
- [x] SendGrid domain auth + DKIM / SPF / DMARC for the production
      sender. `noreply@feflow.org` is V1-clean; no rebrand to
      `noreply@forgeflow.app` required.
- [x] 18 of 20 follow-up Postgres migrations applied + verified on
      staging.

## Engineering kickoff — done

- [x] **`11W.0` / `.7` / `.8` ACCEPT 2026-05-06.** Operator web shell +
      Account / Business Timing editors + Vendor Connections mount.
- [x] **Claude V1 closure dispatch — all 7 lanes (V1.A–V1.G) MERGED.**
      See `docs/archive/_execution/2026-05-06_v1_closure_dispatch_plan_CLOSED_2026-05-07.md`.

## Engineering critical path — done

- [x] **`11W.0` — Web shell + magic-link onboarding** (PR ACCEPT
      2026-05-06, A1).
- [x] **`11W.7` — Account / Business setup** (A2).
- [x] **`11W.8` — Vendor Connections widget mount** (A3).
- [x] **`8.spine-bridge-sink-fanout` (14 of 14 lanes).** All POS,
      reservation, and labor sinks landed (AL, TC, HM, SQ, TS, PU, AG,
      CL, ADP, RV, SR, LSK, OT, SP) plus the 7S capability extension
      and the 2 reservation-side sinks (Oracle Simphony PR #218,
      OpenTable PR #219).
- [x] **Phase 7.58 depth wave — closed 2026-05-05.**

## Cutover — done

- [x] `cutover.0a` + `0a.pg` — CMK provisioning. Done 2026-05-01.

## Phase work — done for V1

- [x] Phase 10a real-time infrastructure (`.0`–`.5` + `UX.0`/`UX.1`
      ACCEPT 2026-05-06). Phase 10b deferred post-launch.
- [x] Phase 11W parity slices `.1`–`.6` ACCEPT 2026-05-06.
- [x] Phase 11A cross-operator parity `.12`/`.13`/`.14` ACCEPT
      2026-05-06.
- [x] `8.business_date_denorm` ACCEPT 2026-05-06.
- [x] `8.first-connect-backfill-wire-in` ACCEPT 2026-05-06 (PR #195).
- [x] `8.spine-bridge-live` + closed timing provenance — components +
      production wire-in CLOSED via `8.first-connect-backfill-wire-in`.
- [x] `8.star-target-server-truth` MERGED 2026-05-06.
- [x] `8.weekly-plan-server-truth` MERGED 2026-05-07 (PR #226).
- [x] `8.business-scope-selector` mobile foundation MERGED 2026-05-07
      (PR #236).

## Tech debt — done

- [x] 4 "unused public classes" — verified-keep, not dead (Wave B4,
      2026-05-06; see updated P3 in `docs/POST_HARDENING_FOLLOWUPS.md`).
- [x] `business_date DATE` denormalized columns on Phase 8 integration
      tables. Closed 2026-05-06 via `c61c2ea7`
      (`8.business_date_denorm`).

## CODE_HEALTH closeout

CODE_HEALTH remediation closed 2026-05-07 — 16 PRs across 5 critical +
~22 high findings. Resolution log:
[CODE_HEALTH.md](../../CODE_HEALTH.md). Skipped: L5 sync worker, L6 OAuth
refresh (now closed by parallel onboarding lanes per the addendum).
