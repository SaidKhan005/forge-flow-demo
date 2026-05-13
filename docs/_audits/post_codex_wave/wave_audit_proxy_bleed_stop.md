# Wave Audit — Proxy + Bleed-Stop Discipline

**Master tip:** `63ec00d6` (the orchestrator brief named `63b67753`; the live tree at this worktree's HEAD is `63ec00d6` — `git log --oneline -1`. Both belong to the same wave; the brief's hash appears to predate the B8 merge by minutes. The audit below evaluates state at `63ec00d6` because that is what the wave has shipped.)
**Pre-wave baseline:** master `6ab8f73c` (post-A11.1 PR #522 merge — the A3.1 ceiling slice captured this exact line count as its "current" reading on 2026-05-12).
**Auditor:** read-only agent (3 of 8)
**Dimension:** Proxy + Bleed-Stop Discipline

## Verdict

`clean-with-findings`

The wave-over-wave bleed-stop discipline held in the sense that no slice violated CI (`advisor_proxy_size_lint.dart` is clean at HEAD). All six new wave-introduced proxy route surfaces shipped to sibling files (no slice inlined a route block of meaningful size into the monolith). `pubspec.yaml` was not touched. `package:postgres` containment held. Worker boundaries (`tool/oauth_refresh_worker/`, `tool/integration_sync_worker/`) did not acquire net-new advisor_proxy imports.

The findings cluster in two areas: (1) the ceiling was raised three times during the wave — each raise was defensible at the per-slice level but the doctrine ("monolith must shrink, not grow") drifted, with cumulative growth of +941 LoC on `advisor_proxy.dart` itself; (2) one wave slice (B2.1, default role catalog publish) requires `Idempotency-Key` as a 400-gate but does not actually consult `proxy_requests` for replay despite the audit doc's claim that it does — making the contract a half-promise.

## Bleed-stop ceiling state

| Measurement | Value |
|---|---|
| Pre-wave baseline (`6ab8f73c`, 2026-05-12 — A3.1 ceiling capture) | 18,871 |
| Current (`63ec00d6`, HEAD) | 19,812 |
| Ceiling (`kAdvisorProxyMaxLines`) | 19,900 |
| Headroom | 88 |
| Wave cumulative delta to `advisor_proxy.dart` | **+941 LoC** (`+1,012 / −71` per `git diff --numstat 6ab8f73c HEAD -- tool/advisor_proxy/advisor_proxy.dart`) |

### Ceiling raises during the wave (three discrete events)

| Commit | Date | From | To | Δ | Rationale (from commit message) |
|---|---|---|---|---|---|
| `bc9b28b5` (A3.1, **wave start**) | 2026-05-12 | (n/a — slice added the lint) | **19,071** | (+200 headroom) | A3.1 set the initial ceiling at baseline + 200 lines. |
| `2baf9bcc` (Bundle 33, B10.1 fallout) | 2026-05-13 02:57 | 19,071 | **19,600** | +529 | B10.1 (PR #576) added ~400 lines without raising; master at 19,458 / 19,071 was 387 over and bleed-stop lint would FAIL. After A3.4's +78 (PR #581): 19,543. New ceiling gives 57 headroom. |
| `7f0ebd4c` (Bundle 34, B2.1 merged) | 2026-05-13 03:16 | 19,600 | **19,700** | +100 | B2.1 added +85 to `advisor_proxy.dart` (necessary dispatch envelope: import + 12-symbol re-export block + dispatcher block). Worker 1 already factored 422 lines into `admin_default_role_catalog_routes.dart`. Same precedent as Bundle 33 (Option A: raise ceiling when a slice needs it). |
| `ada53195` (Bundle 38, C-4 merged) | 2026-05-13 07:45 | 19,700 | **19,900** | +200 | C-4 added +120 to `advisor_proxy.dart` (auth posture mirror of B11.1/B11.2.b: scope check + idempotency-key gate + tenant-tx flip + audit + completion). |

**Net ceiling movement during the wave: 19,071 → 19,900 (+829 lines of granted headroom).** The bleed-stop doctrine explicitly forbids upward movement: "The monolith MUST shrink, not grow" (`tool/advisor_proxy_size_lint.dart:64`). Each individual raise had a per-slice justification in the commit message, but cumulatively the ratchet ran the wrong way — finding **W-1** below.

## Sibling-file decompositions in wave

Six new files were created under `tool/advisor_proxy/` during the wave. Two distinct mount patterns are visible:

### Pattern A — pure pre-check sibling (router fully owns the request lifecycle)

The orchestrator brief described this as the canonical pattern: "file exports a `XxxRouter` with `tryHandle(HttpRequest request)` returning `Future<bool>`; mounted via pre-check in `tool/advisor_proxy/main.dart` before `routeRequest`." Two wave-new files use this pattern verbatim:

| File | Slice | Mount site (`main.dart`) | LoC | Idempotency? |
|---|---|---|---|---|
| `audit_log_hierarchy_routes.dart` | B8 (`ba6363fc`) | `main.dart:1635` (`region: lane_b_b8_audit_log_hierarchy_filter`) | 598 | N/A (read-only `GET`) |
| `sendgrid_events_webhook.dart` | C-1 (`2aa90b47`) | `main.dart:1620-1624` (`region: lane_c_c_1_sendgrid_events_webhook`) | 827 | ECDSA signature + `provider_event_id` partial UNIQUE INDEX (replays land harmlessly via `ON CONFLICT DO NOTHING`). |

Both expose `static bool matches(path, method)` + instance `Future<bool> tryHandle(HttpRequest)`. The shape is uniform; `main.dart`'s pre-check loop is the single mount site. The B8 commit message explicitly disclosed: "`advisor_proxy.dart` is intentionally NOT touched (bleed-stop ceiling discipline)". The B8 PR added exactly 0 lines to `advisor_proxy.dart` (`git show ba6363fc --numstat -- tool/advisor_proxy/advisor_proxy.dart` returns nothing).

### Pattern B — hybrid sibling (router code in sibling, dispatcher fragment still in monolith)

Three wave-new files use this pattern: the router class + audit sink + gateway interfaces live in the sibling, but `routeRequest` in `advisor_proxy.dart` carries a 60–120 line dispatcher block that calls `router.handle(...)` or `router.dispatch(...)` with locally-resolved request envelope:

| File | Slice | Sibling LoC | `advisor_proxy.dart` delta | Mount call site |
|---|---|---|---|---|
| `admin_default_role_catalog_routes.dart` | B2.1 (`03776afb` + `5094aed7` + `1599f25d`) | 620 | +85 (PR #584 disclosure) | `advisor_proxy.dart:11295-11351` |
| `auth_step_up_routes.dart` + `auth_step_up_gate.dart` | B11.2 (`a5df9d08`) + B11.2.b wiring (`8af2a0c0`) | 1,194 + 132 | +60 (`runStepUpGate` invocation at top of `routeRequest`) | `advisor_proxy.dart:9061-9075` |
| `demo_mode_master_switch_routes.dart` | C-4 (`e4425f91`) | 192 | +120 (auth + scope + idempotency-key gate + handler invocation) | `advisor_proxy.dart:9528-9620` |

The hybrid pattern is acceptable when the dispatcher block needs locally-scoped helpers (`_resolveOperatorContextOrWrite`, `_readJsonBody`, `_writeJson`, `_maybeWriteDependencyTimeout`, `_logProxyUnhandled`, `authGuard`, `businessScopeGateway`) that are still file-local to `advisor_proxy.dart`. The B2.1 audit doc (PR #584) acknowledged this explicitly: "remaining 85 are inseparable from `routeRequest`'s local-state dependencies".

**Observation:** the hybrid pattern is the proximate cause of three of the four ceiling raises (B10.1 worker dispatcher, B2.1, C-4). The "shrink, not grow" doctrine requires these helpers to be promoted to sibling status (or exported) so the dispatcher block can move out entirely. The seam map at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` is the planned-but-not-executed home for this work; the wave consumed +829 ceiling lines on hybrid blocks without taking a corresponding subtractive step.

### Cross-reference with the wave's auxiliary file additions

The diff `git diff --name-only --diff-filter=A 6ab8f73c HEAD -- tool/advisor_proxy/` returns exactly the six sibling files above. No new email templates were added during the wave (the `_brand_wrapper.html` and the eight `*.md` templates listed by `ls tool/advisor_proxy/email_templates/` are all pre-wave — confirmed by `git log --diff-filter=A`). Four templates were **deleted** in the wave (C-2-Del cleanup `ec60e06f`): `operator_admin_invite.md`, `password_reset_request.md`, `tos_version_updated_notice.md`, `vendor_webhook_signature_alert.md`.

Total `tool/advisor_proxy/` file count growth: +6 source files (no auxiliary additions). Reasonable for a 14-commit wave touching the proxy surface.

## Findings

### W-1 — Cumulative ceiling drift contradicts the bleed-stop doctrine (medium severity)

**Authority:** `tool/advisor_proxy_size_lint.dart:64-80`: *"Adjusting the ceiling DOWN as decomposition lands is expected; the constant moves with the seam map. Adjusting it UP requires the reviewer to justify the headroom — the monolith MUST shrink, not grow."*

**Evidence:** Three ceiling raises in 5 hours of wall time on 2026-05-13:
- Bundle 33 (`2baf9bcc`, 02:57 UTC-2:30): 19,071 → 19,600 (+529).
- Bundle 34 (`7f0ebd4c`, 03:16): 19,600 → 19,700 (+100).
- Bundle 38 (`ada53195`, 07:45): 19,700 → 19,900 (+200).

Net: 19,071 → 19,900 (+829 lines of granted headroom). The `advisor_proxy.dart` file grew from 18,871 → 19,812 over the same window (+941 lines).

**Why this matters:** the A3.1 ceiling slice (`bc9b28b5`) explicitly framed the lint as a one-way ratchet downward. Three upward moves in one wave normalizes the escape hatch. Each individual raise was defensible per its commit message, but cumulatively the wave demonstrated that the lint as currently calibrated is treated as a check the orchestrator can satisfy by editing the constant rather than by decomposing.

**Severity:** medium because (a) CI is dark until 2026-06-01 per `feedback_ci_dark_until_2026_06_01.md` so the lint had no enforcement during the wave anyway, and (b) every raise was disclosed in its orchestrator bundle commit message with a Pattern A precedent citation, but the cumulative trend is the wrong direction.

**Recommended remediation (next wave):** before any new mutating route lands in `routeRequest`, extract one or both of:
- The `_resolveVerifiedClaimsOrWrite` / `_resolveOperatorContextOrWrite` / `_resolveLocationReadContextOrWrite` family to a sibling auth-helpers file with explicit `authGuard` injection — this single extraction would let B2.1's +85 LoC dispatcher move to `admin_default_role_catalog_routes.dart` entirely, ratcheting the ceiling DOWN by ~85.
- The `_writeJson` / `_readJsonBody` / `_maybeWriteDependencyTimeout` / `_logProxyUnhandled` envelope helpers to a sibling response-helpers file.

The seam map at `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` already identifies these clusters as extraction targets.

### W-2 — B2.1 default role catalog publish requires Idempotency-Key but does not consult `proxy_requests` (medium severity)

**Authority:**
- CLAUDE.md "Proxy & API Conventions" → *"Every proxy write is idempotent. Clients carry an idempotency key; proxy stores keys in `proxy_requests` (UNIQUE)."*
- `lib/infrastructure/persistence/postgres/repositories/default_role_catalog_versions_repository.dart:196-198`: *"Use the proxy idempotency layer (`Idempotency-Key` header + `proxy_requests` UNIQUE) to coalesce retries — this repository does not idempotently handle replays."*

**Evidence:** `tool/advisor_proxy/admin_default_role_catalog_routes.dart:370-391` validates that `idempotencyKeyHeader` is non-null and ≤200 chars, returning 400 on either failure. But the key is then **discarded** — the dispatcher path (`admin_default_role_catalog_routes.dart:404-440` calling `_publish` at line 439, which runs `repository.publishVersion(...)` at line 592) never consults `proxy_requests` or `admin_request_idempotency`. The advisor_proxy.dart dispatcher block (`advisor_proxy.dart:11320-11334`) likewise passes `idempotencyKeyHeader` straight to `dispatch()` without wrapping the call in `runOrReplay(...)`.

For comparison:
- `demo_mode_master_switch_routes.dart` threads `idempotencyKey` + body hash into `DemoModeStateRepository.flipAllDemoRowsToLive(...)`, which DOES `INSERT … ON CONFLICT … FROM public.proxy_requests` (`demo_mode_state_repository.dart:213`) for replay.
- `advisor_proxy.dart` line 14031, 14142, 14244 etc. show that gated admin routes (vendor applicability, business scope, integration admin) thread `adminRequestIdempotencyStore` into their gateways for the cross-tenant case.

The B2.1 dispatcher does neither. Two consecutive `POST /v1/admin/auth/role-catalogs` calls with the same `Idempotency-Key` and same payload will produce two new catalog versions (version 1 and version 2) instead of replaying the first response. This is the inverse of the contract the operator-side client expects.

**Why this matters:** the publish operation is high-blast-radius (every operator that follows "current" rolls forward to the new version). A retry storm during a flaky deploy could create a stream of duplicate versions that are then visible in the catalog history.

**Cross-reference:** `docs/archive/_audits/post_codex_wave_2026-05-13/pr_584_b2_1_default_role_catalog_audit.md:96` asserts "Idempotency on publish ✓ — `Idempotency-Key` required + max 200 chars + **replay via `proxy_requests` UNIQUE**". The "replay via proxy_requests" claim is unverified by the code at HEAD — the route validates header presence but does not implement the replay.

**Severity:** medium. Operationally bounded because (a) the publish dispatcher requires `super_admin` / `ff_support` role (very few callers), and (b) the catalog publish is rare (once per material role-template change, hand-driven from an admin UI). But the contract gap is real.

**Recommended remediation:** wrap the dispatcher in `_defaultAuthIdempotencyCache.runOrReplay(route: '/v1/admin/auth/role-catalogs', key: idempotencyKeyHeader!, compute: () async { ... })` — same pattern the auth-ops routes use 17 times in `advisor_proxy.dart`. Or thread `adminRequestIdempotencyStore` through to `DefaultRoleCatalogAdminRouter.dispatch` and reserve/complete around the `publishVersion` call.

### W-3 — Worker boundary intact, but `integration_sync_worker/main.dart` imports `advisor_proxy.dart` (low severity, pre-existing — confirmed not regressed in wave)

**Authority:** "Worker-vs-proxy boundary — `tool/oauth_refresh_worker/` and `tool/integration_sync_worker/` are SEPARATE Cloud Run binaries from `tool/advisor_proxy/`. Their bootstraps should NOT import the proxy."

**Evidence:** `tool/integration_sync_worker/main.dart:95-96`:
```
import '../advisor_proxy/advisor_proxy.dart'
    show CloverAppCredentials, SquareAppCredentials;
```

This import is **pre-existing** (not introduced in the wave — `git log --oneline 6ab8f73c..HEAD -- tool/integration_sync_worker/main.dart` shows only `1fef0389` and `7c85e5a4`, neither of which touched lines 95–96). The import is narrow: only two vendor-credential bean classes. Lines 97–106 of the same file disclose the design choice explicitly: the worker pulls the per-vendor factory builder directly from `phase_8_vendor_integration_factories.dart` "(not through `phase_8_production_binder.dart`) so the worker compile graph stays clear of `proxy_bootstrap.dart`'s admin-pool / Firebase / LLM machinery."

**Wave impact:** the wave did NOT broaden the worker → proxy import surface. C-2-D (`1fef0389`) only added a typedef `VendorSyncOutageObserver` and threaded it through `runSyncWorkerOnce` / `IntegrationSyncWorkerLoop` — no new proxy imports.

`tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart` (added in wave `0e3f61a2`) does NOT import advisor_proxy at all — only `lib/infrastructure/persistence/postgres/` repos + `lib/services/email/email_template_renderer.dart`. Boundary clean.

**Severity:** low. Flagged for awareness only because the pre-existing leak should be tracked as future debt (move `CloverAppCredentials` + `SquareAppCredentials` to `lib/services/integration/` so worker + proxy both consume from a shared neutral location). NOT a wave regression.

### W-4 — `pubspec.yaml` discipline held (no finding — positive observation)

`git diff 6ab8f73c HEAD -- pubspec.yaml` returns nothing. The wave introduced no new package dependencies. Authority: CLAUDE.md + memory `feedback_production_not_backlog.md` — no new deps unless explicitly justified.

### W-5 — Permission-snapshot resolver consistency held (no finding — positive observation)

Wave-new sibling files use role-gate sets (`{super_admin, ff_support}`, `kOperatorWriteRoles`, `kDefaultRoleCatalogAdminWriteRoles`, `kAuditLogHierarchyReadRoles`) — none reads `lib/auth/permission_keys.dart` constants directly. The `ProxyPermissionSnapshotResolver`-cached paths remain the only gates for permission-keyed routes; the new wave routes are role-gated (admin-side) or operator-write-role-gated (C-4). Search: `grep -n "kPermission\|permission_keys"` across the six new sibling files returns only a docstring reference in `sendgrid_events_webhook.dart:49` clarifying the webhook is a server-to-server caller and bypasses both Firebase JWT and `permission_keys.dart` (signature-gate only).

### W-6 — `postgres_import_lint` containment held (no finding — positive observation)

`grep -rn "^import 'package:postgres" tool/advisor_proxy/` returns no hits. The mentions in `admin_default_role_catalog_routes.dart:190` and `sendgrid_events_webhook.dart:80` are docstring-only references explaining the design choice. Wave-introduced files defer all Postgres I/O to repositories under `lib/infrastructure/persistence/postgres/`.

### W-7 — Step-up router writes are protected by predicate-protected atomic consume, not Idempotency-Key (no finding — design-correct)

`auth_step_up_routes.dart` performs two writes per request cycle: (1) `persistChallenge` on emit, (2) `consume` on redeem. Neither uses `Idempotency-Key`. Per the file's own design comments (`auth_step_up_routes.dart:28-37`), the `challenge_id` itself IS the one-shot consume token — atomic `UPDATE ... RETURNING` with predicate `consumed_at IS NULL AND expires_at > now() AND route_path = $route AND user_id = $user AND operator_id = app_current_operator()` provides exactly-once semantics. Re-issued emits on retries produce a new challenge_id; the client always uses the latest one. This is RFC 9470 standard behavior — no Idempotency-Key needed.

### W-8 — C-1 SendGrid webhook idempotency uses `provider_event_id` UNIQUE (no finding — contractually-bound)

`sendgrid_events_webhook.dart:75-91` disclosed the design: SendGrid does not supply `Idempotency-Key` (server-to-server caller), so `provider_event_id` (= `sg_event_id`) IS the equivalent — partial UNIQUE INDEX + `ON CONFLICT (provider_event_id) WHERE provider_event_id IS NOT NULL DO NOTHING`. Replays of full batches land harmlessly. CLAUDE.md "Proxy & API Conventions" requires "every proxy write is idempotent" — this slice satisfies the requirement with a different mechanism appropriate to the vendor contract.

## Aggregate observations

1. **Ceiling drift trend.** The ceiling moved upward 4× over a 9-hour window on 2026-05-13 (1 initial set + 3 raises). Headroom started at 200 (A3.1 baseline) and ended at 88 (HEAD). The intent of A3.1 was for the ceiling to ratchet downward as decomposition land; the wave did the opposite. **Net cumulative growth: +941 LoC on `advisor_proxy.dart`** despite **6 new sibling-file decompositions** (a total of 3,563 LoC of router code that DID land outside the monolith). The decomposition pattern worked — but the dispatcher bleed-through (averaging +94 LoC per slice that touches `routeRequest`) overwhelmed it.

2. **Sibling-file pattern usage breakdown.** Of 6 new sibling files:
   - 2 (sendgrid, audit_log_hierarchy) used Pattern A (pure pre-check mount, 0 LoC into `advisor_proxy.dart`).
   - 4 (default_role_catalog, step_up_routes, step_up_gate, demo_mode_master_switch) used Pattern B (hybrid — sibling holds router + audit sink + gateway; monolith holds the 60–120 LoC dispatcher envelope).
   - The Pattern A files are 25% of new sibling files but 0% of `advisor_proxy.dart` growth. The Pattern B files are 75% of new sibling files but ~100% of `advisor_proxy.dart` growth.

3. **Idempotency contract uniformity gap.** Four wave slices added mutating proxy routes (C-1 SendGrid, B2.1 catalog publish, C-4 demo→live switch, the implicit step-up persist/consume on B11.2.b). Of these:
   - C-1 uses `provider_event_id` UNIQUE (vendor-bound mechanism, justified).
   - C-4 threads `Idempotency-Key` + body hash all the way through to `proxy_requests` via the demo_mode repo.
   - B11.2.b uses predicate-protected one-shot consume (RFC 9470-bound mechanism, justified).
   - **B2.1 requires the header but discards it** — the only true contract gap of the four.

4. **Worker boundary held.** Despite C-2-F adding `vendor_connection_auto_disabled_dispatcher.dart` to `tool/oauth_refresh_worker/` (591 new LoC) and C-2-D adding the outage-observer typedef to `tool/integration_sync_worker/main.dart` (+71 LoC), no new cross-worker → proxy import was introduced. The one pre-existing import (`CloverAppCredentials`, `SquareAppCredentials`) was not regressed.

5. **No `pubspec.yaml` movement.** Zero wave commits modified `pubspec.yaml`. Clean.

6. **No new raw `package:postgres` import in `tool/advisor_proxy/` or anywhere outside the persistence layer.** `postgres_import_lint.dart` would pass.

## Recommendations for next wave

Ordered by leverage (highest first):

1. **Mandatory pre-flight extraction before any new `routeRequest` block lands.** When a slice's dispatcher block requires `_resolveOperatorContextOrWrite` / `_writeJson` / `_readJsonBody` / `_maybeWriteDependencyTimeout` / `_logProxyUnhandled`, the slice's first move is to extract those helpers to `tool/advisor_proxy/route_helpers.dart` (or similar). The dispatcher block then moves to the sibling file entirely. This single change converts Pattern B back into Pattern A and unblocks the ceiling ratchet.

2. **Ratchet the ceiling DOWN, not up, by default.** After the next 2-3 sibling-file decompositions land, the orchestrator should drop the ceiling in the same bundle commit. The current 88-LoC headroom is barely enough for one routine slice; the next time a slice needs +90, the wrong pattern (raise + commit) will repeat. A deliberate "phase 7.57.bleed-stop" slice should: (a) extract the four helper clusters above, (b) move B2.1 / B11.2.b / C-4 / B10.1 dispatcher blocks into their sibling files, (c) ratchet the ceiling to whatever the new line count is + 50.

3. **Fix the B2.1 idempotency gap.** Either wrap the publish dispatcher in `_defaultAuthIdempotencyCache.runOrReplay(...)` or thread `adminRequestIdempotencyStore` through `DefaultRoleCatalogAdminRouter.dispatch`. Update `docs/archive/_audits/post_codex_wave_2026-05-13/pr_584_b2_1_default_role_catalog_audit.md:96` to reflect actual code state. Pattern: copy from `advisor_proxy.dart:11509` (where `authOpsCache.runOrReplay(...)` wraps an admin write).

4. **Promote `CloverAppCredentials` + `SquareAppCredentials` out of `tool/advisor_proxy/advisor_proxy.dart`.** The pre-existing worker → proxy import surface is narrow but still violates the stated boundary. Move both classes to `lib/services/integration/vendor_credentials.dart` (or similar) so both binaries import from a neutral location. Estimated cost: ~50 LoC. Side benefit: ratchets the ceiling DOWN by 50.

5. **Add `tool/advisor_proxy_size_lint.dart` rule: ceiling raises require operator approval.** Mirror CLAUDE.md "Agent-Led Slices" gate language: "Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict." Ceiling raises during this wave were orchestrator-decided; the doctrine says the ceiling MUST move down. Make the raise path explicit and operator-gated.

## Authority anchors

- **Bleed-stop lint:** `tool/advisor_proxy_size_lint.dart` (especially lines 56-80 — "the monolith MUST shrink, not grow"; "Adjusting it UP requires the reviewer to justify the headroom"; "the next slice MUST drop this ceiling by the LoC the extraction removed").
- **Seam map (not yet executed):** `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` (planned home for the dispatcher-helper extraction described in recommendation #1).
- **Decomposition sequence:** `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` (25-step extraction sequence; the wave consumed ceiling without taking any of the 25 steps).
- **CLAUDE.md "Proxy & API Conventions":** *"Every proxy write is idempotent. Clients carry an idempotency key; proxy stores keys in `proxy_requests` (UNIQUE)."* — finding W-2 anchor.
- **CLAUDE.md "Service-Layer Split":** raw `package:postgres` imports are confined to `lib/infrastructure/persistence/postgres/`. — finding W-6 (clean).
- **`tool/postgres_import_lint.dart` (specifically lines 20-26):** "`tool/` is NOT exempt. The Cloud Run workers under `tool/` … talk to Postgres through the `PostgresExecutor` seam by design".
- **CI dark posture:** `feedback_ci_dark_until_2026_06_01.md` (memory) — `ci.yml` gated to `workflow_dispatch` only; advisor_proxy_size_lint had no CI enforcement during the wave, which is the proximate enabler of the ceiling drift in W-1.
- **B2.1 audit doc:** `docs/archive/_audits/post_codex_wave_2026-05-13/pr_584_b2_1_default_role_catalog_audit.md:96` (contains the "replay via proxy_requests UNIQUE" assertion contradicted by code state).
- **Per-slice baseline:** master `6ab8f73c` (post-A11.1 PR #522 merge; A3.1 captured `advisor_proxy.dart` at 18,871 lines on this commit).
- **Master tip evaluated:** `63ec00d6` (most recent merge on `master`; brief mentions `63b67753`; both belong to the same wave).
