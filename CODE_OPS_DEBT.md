# Code Ops Debt Report — Closed

**Audit date:** 2026-05-07
**Last update:** 2026-05-08 (final closeout — both sweeps complete).

This doc is the operational-debt sibling to `CODE_HEALTH.md`:
- `CODE_HEALTH.md` = original 2026-05-06 audit + closeout + 2026-05-07
  fact-check addendum (now archived).
- `CODE_OPS_DEBT.md` = doc-vs-code drift findings.

## Status: closed

Both fix sweeps complete. **~50 of 50 audit findings resolved across
21 PRs + 1 closed-redundant.**

Detail in `docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md`.

### Sweep 1 — audit-batch (2026-05-07 morning)

13-lane parallel fix sweep. 12 PRs merged + 1 closed-redundant
(parallel master slice shipped equivalent work). All 7 P0
launch-blockers resolved. Closed Themes B#2-4, C, E, F#1-2, F#4, G
(all 7 rows), H#1-7,9, I#3-4, J#1-2.

### Sweep 2 — operator-decision (2026-05-07 evening → 2026-05-08)

8 lanes dispatched after the operator gave decisions on the 9
remaining items. All 8 with PRs merged. Item 9 (Theme H#8 first-backfill
status null shape) self-closes via the Phase 8 framework finishing push
already in flight.

Closed Themes A, B#1, B#5, D, I#1-2, J#3, J#4, J#5.

| Item | Theme | PR | What landed |
|---|---|---|---|
| 1 | A — session-claim resolver | [#384](https://github.com/SaidKhan005/forge-flow-demo/pull/384) | 1hr MFA freshness via Firebase `auth_time` claim; 4 admin actions un-pinned; redirect-to-login on stale |
| 2 | B#1 — single-admin erasure | [#377](https://github.com/SaidKhan005/forge-flow-demo/pull/377) | 3 erasure routes + grace-expiry worker + 24h reverse window; uses item 1's fresh-MFA gate |
| 3 | B#5 — server-side audit-log CSV | [#378](https://github.com/SaidKhan005/forge-flow-demo/pull/378) | Streamed CSV respecting same UX filters; time filter already end-to-end; replaces 100k-row client renderer |
| 4 | I#1-2 — kDemoMode end-to-end audit | [#379](https://github.com/SaidKhan005/forge-flow-demo/pull/379) | Zero drift found; 2 carve-outs documented in CLAUDE.md + new `demo_mode_contract.md`; regression test in `test/integration/demo_mode_writer_side_test.dart` |
| 5 | D — Pub/Sub realtime | [#380](https://github.com/SaidKhan005/forge-flow-demo/pull/380) | Default-off (\$0 cost); 5-min retention; per-pod subscription with TTL auto-cleanup; <\$1/pod/month when enabled |
| 6 | J#3 — Browser Use Codex reframing | [#368](https://github.com/SaidKhan005/forge-flow-demo/pull/368) | Runbook rewritten to clarify Codex-driven, not in-repo binary |
| 7 | J#4 — slice-acceptance relaxation | [#381](https://github.com/SaidKhan005/forge-flow-demo/pull/381) | Contract softened to advisory; no CI lint built |
| 8 | J#5 — graphify backlog | [#369](https://github.com/SaidKhan005/forge-flow-demo/pull/369) | 503 message rewritten to surface paused-by-design under AI freeze |
| 9 | H#8 — first-backfill status null | n/a | Self-closes via Phase 8 framework push (already in flight) |

## What's NOT in this doc (excluded scope)

- Anything in `CODE_HEALTH.md` Closed / Deferred / Out-of-scope /
  Addendum sections (now archived).
- The Phase 8 framework finishing pushes (vendor-credential broker,
  sink production binder, OAuth refresh worker, per-vendor OAuth
  descriptors, `8.framework.*`, `8.gap-*`, `8.transport.*`,
  `8.spine-bridge-sink-fanout.*`, etc.).

## Open follow-ups (out-of-scope or carry-over)

These are the only items that remain — none of them were in the
original audit's scope; they're carry-overs noted by the implementing
agents:

- ~~**Frontend listener for `redirect_uri` payload** (from N1)~~ —
  closed. The admin shell registers its `AdminAuthSource` as the
  `AdminHttpFreshnessRedirectDispatcher` listener; the operator-web
  `FirebaseOperatorWebAuthSource` registers itself on
  `OperatorWebProxyClient`. Both detect the
  `mfa_freshness_required` 403, sign out via the existing Firebase
  Auth path, and emit a needs-sign-in state carrying the
  proxy-supplied `redirect_uri`. Parser + listener seam:
  `lib/auth/mfa_freshness_redirect_listener.dart`.
- **Visible grace-window countdown chip** (from N2) — the
  audited-support-actions screen captures `_lastErasure` but doesn't
  yet render a countdown chip during the 24h grace window. Small
  follow-up slice.
- ~~**Restaurant-local IANA-tz business-date resolution** (from N2) —
  PII erasure rows currently use UTC for `business_date`; future
  improvement to use restaurant-local TZ. Column drives partition
  routing only, so impact is small.~~ **Closed 2026-05-08** — landed
  `PiiBusinessDateResolver` callback on `UserPiiErasureService` +
  `buildPiiBusinessDateResolver` helper that reads
  `(timezone, business_day_rollover_hour)` from `public.locations`
  and projects through `IanaTimezoneConverter.toBusinessDate`. Proxy
  POST `.../erase-pii` no longer truncates UTC inline; the service
  resolves restaurant-local business_date when a resolver is bound.
  Falls back to UTC when no resolver / unknown tz so erasure writes
  never block on tz reads. Coverage:
  `test/services/auth/pii_business_date_resolver_test.dart`,
  `test/services/auth/user_pii_erasure_service_test.dart`
  (`IANA-tz business_date resolver` group).
- **Theme H#8 first-backfill status null shape** — owned by the Phase
  8 framework finishing push; will close naturally when that lane
  touches the route.

None of these block V1 launch.

## Cross-references

- `docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md` — full lane
  scoreboard + per-finding closeout markers (both sweeps).
- `docs/_execution/2026-05-05_v1_launch_punchlist.md` — operator-blocked V1 launch items.
- `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items from the 2026-05-02 deep audit.
- `PROJECT_TRACKER.md` — routing.
- `CLAUDE.md` — Hard Promises (this audit found violations of #2; closed via PR #379).
- `docs/contracts/demo_mode_contract.md` — kDemoMode end-to-end architecture (new from PR #379).
