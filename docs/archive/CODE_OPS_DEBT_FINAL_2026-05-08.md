# Code Ops Debt Report — ARCHIVED 2026-05-08

**Status:** archived. Every finding either landed or transferred to
the right living doc. Use as historical reference only.

**Audit date:** 2026-05-07
**Final closeout:** 2026-05-08 — both sweeps complete + every
carry-over either merged or moved to its proper home.

This doc was the operational-debt sibling to the (also-archived)
`CODE_HEALTH.md`:
- `CODE_HEALTH.md` — see `docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`
- `CODE_OPS_DEBT.md` (this file) — doc-vs-code drift findings.

## Final state

Both fix sweeps complete. **~50 of 50 audit findings resolved across
21 PRs + 1 closed-redundant.**

All four carry-over follow-ups closed:
- ✅ Frontend `redirect_uri` listener — PR [#392](https://github.com/SaidKhan005/forge-flow-demo/pull/392) (2026-05-08).
- ✅ Visible grace-window countdown chip — PR [#389](https://github.com/SaidKhan005/forge-flow-demo/pull/389) (2026-05-08).
- ✅ Restaurant-local IANA-tz `business_date` for PII erasure — PR [#390](https://github.com/SaidKhan005/forge-flow-demo/pull/390) (2026-05-08).
- ↪︎ Theme H#8 first-backfill status null shape — transferred to `docs/phases/phase_8/phase_8_spine_bridge_plan.md` § "Deferred from CODE_HEALTH remediation" (closes when the Phase 8 framework lane next touches the route).

Sweep history detail: `docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md`.

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

## Carry-over follow-ups — all closed or transferred 2026-05-08

(See top of doc for the closeout summary table.)

### Frontend listener for `redirect_uri` payload — CLOSED PR #392

The admin shell registers its `AdminAuthSource` as the
`AdminHttpFreshnessRedirectDispatcher` listener; the operator-web
`FirebaseOperatorWebAuthSource` registers itself on
`OperatorWebProxyClient`. Both detect the `mfa_freshness_required`
403, sign out via the existing Firebase Auth path, and emit a
needs-sign-in state carrying the proxy-supplied `redirect_uri`.
Parser + listener seam: `lib/auth/mfa_freshness_redirect_listener.dart`.

### Visible grace-window countdown chip — CLOSED PR #389

`_GraceWindowChip` on `audited_support_actions_admin_screen.dart`
renders "Erasure reversible — Xh Ym remaining" + "Reverse erasure"
button during the grace window, flips to "Erasure final" past the
boundary. 1-min `Timer.periodic` started on issue-erasure / cancelled
in `dispose` / on reverse / on grace expiry. Reverse affordance hits
the existing `gateway.reversePiiErasure` seam — no new state plumbing.
Test-only `graceWindowClock` + `graceWindowTickInterval` props pin
the countdown deterministically.

### Restaurant-local IANA-tz `business_date` for PII erasure — CLOSED PR #390

Landed `PiiBusinessDateResolver` callback on `UserPiiErasureService` +
`buildPiiBusinessDateResolver` helper that reads
`(timezone, business_day_rollover_hour)` from `public.locations` and
projects through `IanaTimezoneConverter.toBusinessDate`. Proxy POST
`.../erase-pii` no longer truncates UTC inline; the service resolves
restaurant-local business_date when a resolver is bound. Falls back
to UTC when no resolver / unknown tz so erasure writes never block on
tz reads. Coverage: `test/services/auth/pii_business_date_resolver_test.dart`,
`test/services/auth/user_pii_erasure_service_test.dart`
(`IANA-tz business_date resolver` group).

### Theme H#8 first-backfill status null shape — TRANSFERRED to Phase 8 plan

Moved 2026-05-08 to `docs/phases/phase_8/phase_8_spine_bridge_plan.md`
§ "Deferred from CODE_HEALTH remediation" → "`fetchFirstBackfillStatus`
null-shape conflation". Closes when the Phase 8 framework finishing
lane next touches `tool/advisor_proxy/proxy_bootstrap.dart:2102-2137`
+ `lib/services/sync/http_sync_proxy_client.dart:281-296`.

None of the above blocked V1 launch.

## Cross-references

- `docs/archive/CODE_OPS_DEBT_RESOLVED_2026-05-07.md` — full lane
  scoreboard + per-finding closeout markers (both sweeps).
- `docs/_execution/2026-05-05_v1_launch_punchlist.md` — operator-blocked V1 launch items.
- `docs/POST_HARDENING_FOLLOWUPS.md` — open P0–P3 items from the 2026-05-02 deep audit.
- `PROJECT_TRACKER.md` — routing.
- `CLAUDE.md` — Hard Promises (this audit found violations of #2; closed via PR #379).
- `docs/contracts/demo_mode_contract.md` — kDemoMode end-to-end architecture (new from PR #379).
