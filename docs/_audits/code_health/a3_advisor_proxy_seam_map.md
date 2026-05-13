# A3.1 — Advisor-Proxy Seam Map + Bleed-Stop Policy

**Slice:** A3.1 (Lane A code-health, see
`docs/_execution/lane_a_code_health/03_execution_slices.md` §"Slice
A3.1 — Monolith Seam-Map + Bleed-Stop Lint").

**Authority:** `CLAUDE.md` Hard Promise #4 ("RLS-ready") + the
"Build Toward Production" doctrine. The seam map is consumed by the
formal proxy-split phase whose 25-step extraction sequence lives at
`docs/_audits/code_health/a3_proxy_monolith_decomposition.md` (the
decomposition doc, "Decomp" below).

**Snapshot:** Captured 2026-05-12 against the worktree
`agent-a98d1d831e522f7b2`, rebased onto `origin/master` commit
`6ab8f73c` (which absorbed PR #522 mid-flight: the A11.1
session-record-gauge slice added 131 lines to the monolith — the
`SessionRecordIncompleteGauge` class plus a re-exporting import).
The monolith file `tool/advisor_proxy/advisor_proxy.dart` is **18,871
lines** at this snapshot, with monolith-content blob hash
`f8965f7c1ef91c0e862f4e48c81e8fe9c92d6ff4`.

This doc is purely informational. The lint
(`tool/advisor_proxy_size_lint.dart`) is the operative gate; the seam
map is the planning artifact the lint protects.

---

## Section 1 — Cluster table

Twelve clusters, top to bottom. Boundaries follow natural type /
function / blank-line breaks confirmed by inspecting the source on
2026-05-12. Line numbers are inclusive on both ends. "Future
extraction target" names the file (or sub-tree) the cluster lands in
once the formal proxy-split phase runs; these are aligned with the
decomp doc's Section 3 "Target file layout" wherever they overlap.

| #  | Cluster                                                                | Start | End   | LoC    | Theme                                              | Future extraction target                                                          |
| -: | ---------------------------------------------------------------------- | ----: | ----: | -----: | -------------------------------------------------- | --------------------------------------------------------------------------------- |
|  1 | File header + imports                                                  |     1 |   256 |    256 | Library setup + dependency surface                 | stays in `advisor_proxy.dart` (post-split bootstrap header)                       |
|  2 | Secret + config name registry, `ProxyConfig`, vendor app credentials   |   257 |  1120 |    864 | Config + secrets value classes                     | new `tool/advisor_proxy/config/proxy_config.dart` (not in Decomp; new home)       |
|  3 | JWT verification (claims, verifier ifaces, Firebase, OperatorContext, ProxyAuthError, ProxyRequestGuard) |  1122 |  2291 |  1,170 | Bearer-token auth                                  | `tool/advisor_proxy/jwt/` sub-tree (Decomp Step 12)                               |
|  4 | Policy / usage / Service Principals / accounting (Postgres impl)       |  2292 |  3670 |  1,379 | Cost discipline + SP issuance + accounting writes  | `tool/advisor_proxy/policy/` sub-tree + `routes/service_principals.dart` (Decomp Steps 10 & 13) |
|  5 | Health surface (registry store, dependency probe, migration apply)     |  3671 |  5596 |  1,926 | Health envelope + dependency probes                | `tool/advisor_proxy/health/` sub-tree (Decomp Step 15)                            |
|  6 | LLM provider plumbing (Anthropic / Gemini / breaker / pipeline / cache builder / log SQL) |  5597 |  6514 |    918 | AI provider plumbing                               | `tool/advisor_proxy/llm/` sub-tree (Decomp Step 14)                               |
|  7 | Auth lockout machinery + A11.1 `SessionRecordIncompleteGauge`          |  6516 |  7060 |    545 | Login lockout + MFA-retry counters + session-record completeness gauge | `tool/advisor_proxy/routes/auth_lockout.dart` (Decomp Step 6) for lockout types; `routes/_shared/session_record_gauge.dart` carve-out for the A11.1 gauge |
|  8 | Path constants + admin gateway abstractions + idempotency store        |  7061 |  8511 |  1,451 | Every route path + admin gateways (interface only) | `tool/advisor_proxy/routes/_paths.dart` (Decomp Step 0) + admin gateway homes in `lib/services/proxy/admin/` |
|  9 | `routeRequest` mega-function (dispatch + inline handler bodies)        |  8512 | 14910 |  6,399 | Request dispatch + every inline route              | `tool/advisor_proxy/routes/*.dart` per family (Decomp Steps 2-9, 11, 16-24)       |
| 10 | Top-level admin route delegate functions (`_routeXxxAdmin`)            | 14911 | 17391 |  2,481 | Admin route delegates (operator/location, integrations, pricing, data accuracy, corpus, debug, observability, feature flags, graph candidates, mobile op-sync) | `tool/advisor_proxy/routes/admin_*.dart` (Decomp Steps 16-22) |
| 11 | Predicate matchers + path matcher classes + admin permission guards + helper functions | 17392 | 18581 |  1,190 | Path matchers + permission/scope guards            | `tool/advisor_proxy/routes/_shared/` (Decomp Step 1) + `routes/auth_team_admin.dart` (Decomp Step 23) for the 1,470-line beast's matchers |
| 12 | CORS + JSON body + response writer + error type tail                   | 18582 | 18871 |    290 | Shared response/CORS                               | `tool/advisor_proxy/routes/_shared/cors.dart` + `_shared/response.dart` + `_shared/json_body.dart` (Decomp Step 1) |

**Total:** 12 clusters, 18,871 lines (the entire file).

**Notes on cluster 7's growth.** PR #522 (slice A11.1) added the
`SessionRecordIncompleteGauge` class at lines ~6969-7060 — structurally
inside cluster 7's auth-lockout neighborhood but conceptually a
separate concern (not lockout, not MFA, not retry counters; it's a
proxy-side response-completeness observer for the session-finalizing
routes). Future extraction should split it into its own
`routes/_shared/session_record_gauge.dart` rather than fold it into
`routes/auth_lockout.dart`. The cluster table flags this with the
"+ A11.1 gauge" suffix on the cluster name and the dual extraction
target.

### Cluster anchor markers

The boundaries above are anchored to specific lines so a future
extraction can verify it has the right block before moving anything.

| # | Anchor at start                                                                       | Anchor at end                                                              |
| -:| ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| 1 | `// Forge & Flow advisor proxy — pure scaffold.` (line 1)                             | last `import` / `export` declaration before the secret-name banner (line 256) |
| 2 | `// ─── Secret name registry ───` banner (line 251) → `abstract class ProxySecretNames` (line 257) | `}` closing `ProxyConfig` (line 1120)                                      |
| 3 | `class ProxyJwtClaims` (line 1126)                                                    | `}` closing `ProxyRequestGuard` (line 2291)                                |
| 4 | `// ─── 11a.10b — Usage policy / counter / guard ───` (line 2298) → `class PolicyTier` (line 2312) | `}` closing `ScaffoldFailingProxyAccountingStore` (line 3670)              |
| 5 | `abstract class ProxyHealthCheckStore` (line 3672)                                    | `}` closing `ProxyMigrationApplyRegistryWriter` (line 5596)                |
| 6 | `enum ProxyLlmTier` (line 5589) → `class ProxyLlmModelRouting` (line 5598)            | end of `ProxyUsageLogSql` constants (line 6514)                            |
| 7 | `class AuthLockoutEvaluation` (line 6516)                                             | `}` closing `SessionRecordIncompleteGauge` (line 7060)                     |
| 8 | `const String healthPath = '/healthz';` (line 7061)                                   | `}` closing `InMemoryPermissionVersionChecker` (line 8511)                 |
| 9 | `Future<void> routeRequest(` (line 8512)                                              | `}` closing `routeRequest` (line 14910)                                    |
| 10 | `bool _isFfOperatorLocationAdminCaller(...)` (line 14912)                             | `}` closing `_routeOperatorDataAccuracySettingsWrite` (line 17428)         |
| 11 | `bool _isAdminAuthOperation(...)` (line 17798) and matchers / `class _MobileOperationalPath` (line 17577) — interleaved | last `_nonBlankString` helper (line 18574)                                 |
| 12 | `List<String> _nonBlankStrings(...)` (line 18577) → `class _MalformedJsonBodyError` (line 18593) → CORS tail | end-of-file (line 18871, helper `_nonBlankOr`)                             |

Clusters 10 and 11 interleave slightly: the predicate helpers
(`_isAdminAuthOperation`, `_isMfaOperation`, `_servicePrincipalJwtIssueId`)
sit at ~17577-17958, structurally between the last admin delegate
(`_routeOperatorDataAccuracySettingsWrite` ends at 17428) and the next
helper run. Treating 14911-17391 as "delegate cluster" and 17392-18581
as "matcher cluster" keeps the boundary aligned with the next blank
line; the actual extraction order separates them naturally because
delegates land in `routes/admin_*.dart` while matchers land in
`routes/_shared/`.

---

## Section 2 — Bleed-stop policy

The lint is `tool/advisor_proxy_size_lint.dart`. It freezes the
monolith's growth at a small, justified headroom budget so future
contributions go into decomposed files instead of accreting into the
one-place-everyone-reaches-for.

### 2.1 Ceiling

- **Captured count (2026-05-12, master commit `6ab8f73c` post-PR-#522):** 18,871 lines.
- **Ceiling:** 19,071 lines (`kAdvisorProxyMaxLines` in the lint
  source).
- **Headroom:** 200 lines.

### 2.2 Headroom rationale

- 200 lines is enough to absorb the small in-flight slices that
  legitimately need to land a change in the monolith before a larger
  extraction is feasible. Concrete examples:
  - **A3.2 / A3.3 / A3.4 typed-catch tail chunks** (4-6 sites each
    per `proxy_split_plan.md`). Each typed-catch arm replacement
    nets ~10-15 lines. Three chunks at 4-6 sites is ~120-270 lines
    in aggregate but lands across separate slices, none of which
    individually breach the ceiling.
  - **Password-reset short-window counter wiring** if the per-IP
    counter slot needs threading through `routeRequest` ahead of
    the Step 7 extraction.
- 200 lines is **too small** to accommodate routine "just one more
  route" growth. A new POST handler with body validation + audit
  emission + idempotency gate runs 80-150 lines minimum; two of those
  in one PR breaches the ceiling. The lint then forces the
  contribution into `tool/advisor_proxy/routes/<family>.dart` where
  it belongs.

### 2.3 Ratchet rule

When a Decomp slice extracts a cluster, the next slice MUST drop the
ceiling by the LoC the extraction removed. The monolith count goes
DOWN; the ceiling tracks the new count plus the same 200-line
headroom. Concretely:

- Before Decomp Step 0: ceiling = 19,071 (current count + 200).
- After Decomp Step 0 lands (`routes/_paths.dart` extracts ~1,450
  LoC of path constants from cluster 8): new monolith count ≈ 17,420;
  new ceiling ≈ 17,620.
- And so on, until post-split the monolith is ~1,200-1,500 lines (per
  Decomp Section 3.2) and the ceiling settles at ~1,500 + 200 = 1,700.

The ratchet direction is enforced by reviewer judgment, not by the
lint itself. The lint catches the "ceiling-up" mistake at PR review
time because the constant change is human-visible in the diff.

### 2.4 Adjusting the ceiling

- **Down (extraction landed):** straightforward. Update
  `kAdvisorProxyMaxLines` in `tool/advisor_proxy_size_lint.dart` to
  `<new line count> + 200`. Cite the extraction PR and the new line
  count in the constant's docstring + this section's table.
- **Up (rare, requires justification):** disallowed by default. If a
  one-off slice genuinely needs more headroom (e.g. an
  emergency-rollback patch that has to land before extraction is
  feasible), the reviewer documents the headroom expansion in the
  constant's docstring AND in this section, AND opens an immediate
  follow-up to extract the offending block. The monolith MUST shrink,
  not grow, on the steady state.

---

## Section 3 — Recommended extraction ordering

The 25-step Decomp sequence already nails this; this section is the
seam-map-side cross-walk so the bleed-stop ceiling can be ratcheted
predictably. Order is the same as Decomp Section 4 ("Migration
sequencing"). LoC moved is per the decomp's "Sequencing summary"
table.

| Decomp step | Cluster(s) drained                                                                | LoC moved out of monolith | Ceiling delta after step | Notes                                                                |
| ----------- | --------------------------------------------------------------------------------- | ------------------------: | -----------------------: | -------------------------------------------------------------------- |
| Step 0      | Cluster 8 (path-constants portion only, ~1,340 of 1,283 LoC)                      |                    ~1,340 |              -1,340      | Mechanical move; transparent re-export from monolith for back-compat |
| Step 1      | Cluster 11 (CORS, JSON body, response, scope/permission/idempotency guards) + Cluster 12 (CORS tail + JSON body + response writer) |                    ~1,200 |              -1,200      | `routes/_shared/` foundation                                         |
| Step 2      | Cluster 9 (health/smoke handler block 8653-8794, 9131-9544)                       |                      ~530 |               -530       | First end-to-end dispatch test                                       |
| Step 3      | Cluster 9 (push-token handler block 9613-9782)                                    |                      ~170 |               -170       | Single-gateway smoke                                                 |
| Step 4      | Cluster 9 (auth-account + permissions snapshot 9545-9612)                         |                       ~70 |                -70       | Read-only                                                            |
| Step 5      | Cluster 9 (MFA TOTP block 10319-10588) + a `routes/_shared/fresh_auth.dart` carve-out from Cluster 11 |                  ~270 |               -270       | First medium-risk audit-touching extraction                          |
| Step 6      | Cluster 7 (auth lockout types + counters 6511-7117)                               |                      ~610 |               -610       | Audit row writes preserved; sink interface unchanged                 |
| Step 7      | Cluster 9 (password / magic-link / MFA recovery 9783-10318)                       |                      ~540 |               -540       | Rate-limit counters thread through new module                        |
| Step 8      | Cluster 9 (auth session login/refresh/revoke 12120-13150)                         |                    ~1,030 |              -1,030      | High-risk; A1 scope-mismatch defect lives here                       |
| Step 9      | Cluster 9 (auth audit-log read + CSV export 12420-12654)                          |                      ~410 |               -410       | Bare-catch at 12566 is one of the 16 from `proxy_split_plan.md`      |
| Step 10     | Cluster 4 (service principals value types + Postgres gateway + handler at 10589-10650) |                  ~620 |               -620       | Postgres gateway is pure file move                                   |
| Step 11     | Cluster 9 (auth-location integrations 12310-12412)                                |                      ~100 |               -100       | Read-only                                                            |
| Step 12     | Cluster 3 (entire JWT verification subtree 1118-2287)                             |                    ~1,200 |              -1,200      | Touched by 100% of routes; transparent re-export required            |
| Step 13     | Cluster 4 (policy / usage / accounting remainder 2288-3666 minus SP)              |                    ~1,500 |              -1,500      | Postgres-backed accounting stays intact                              |
| Step 14     | Cluster 6 (LLM provider plumbing 5593-6510)                                       |                    ~2,000 |              -2,000      | Phase 12 reuses these abstractions per HP #8                         |
| Step 15     | Cluster 5 (health surface classes 3667-5592)                                      |                    ~1,900 |              -1,900      | Audit-chain anchor metrics (read-only) move with                     |
| Step 16     | Cluster 9 (admin operator/location 14049-14171) + Cluster 10 (`_routeOperatorLocationAdmin` 14806-15007) |                  ~480 |               -480       | Audit row writes on suspend/reactivate/archive                       |
| Step 17     | Cluster 9 (admin pricing 13313-13422) + Cluster 10 (`_routePricingAdmin` 15719-...) |                    ~310 |               -310       |                                                                      |
| Step 18     | Cluster 9 (admin data-accuracy 13424-13525) + Cluster 10 (`_routeDataAccuracyAdmin` 15325-...) |              ~490 |               -490       |                                                                      |
| Step 19     | Cluster 9 (admin corpus + graph-candidates 13526-13763) + Cluster 10 (`_routeCorpusAdmin` 15923-..., `_routeGraphCandidates` 16657-...) |          ~660 |               -660       | 16 MB body cap carve-out stays in `_shared/`                         |
| Step 20     | Cluster 9 (feature flags + debug + observability 13764-14047) + Cluster 10 (`_routeFeatureFlagsAdmin` 16320-..., `_routeDebugConsoleAdmin` 16046-..., `_routeObservabilityAdmin` 16270-...) |     ~770 |               -770       |                                                                      |
| Step 21     | Cluster 9 (admin integrations 13144-13311) + Cluster 10 (`_routeIntegrationsAdmin` 15195-...) |               ~300 |               -300       | High-risk: `provider_credentials` + audit + fresh-MFA gate           |
| Step 22     | Cluster 10 (mobile operational sync `_routeMobileOperationalSync` 17040-..., `_routeOperatorDataAccuracySettingsWrite` 17175-...) + Cluster 11 (`_MobileOperationalPath` matcher 17446-...) |          ~620 |               -620       |                                                                      |
| Step 23     | Cluster 9 (`_isAdminAuthOperation` branch 10652-12119) + Cluster 11 (predicate, canonical-path map, JSON converters 17667-18139) |                ~2,400 |              -2,400      | **Largest extraction.** Last because every mutating branch writes audit |
| Step 24     | Cluster 9 (realtime mount cleanup 8767-8794)                                      |                       ~40 |                -40       |                                                                      |
| Step 25     | Cluster 1 (header trimming) + final dead-code sweep                               |                       ~50 |                -50       | Re-export removal + analyzer pass                                    |

Drain order is identical to Decomp's order — the seam map does not
re-sequence. The bleed-stop ceiling ratchets after every step in this
table.

---

## Section 4 — Cross-reference: clusters → Decomp steps

For the future proxy-split executor: which of the 25 Decomp steps
touch each cluster, and which Decomp Section 5 ("Shared seams")
sub-section governs the cross-cluster helpers.

| Cluster                                                     | Decomp steps that drain it                            | Decomp Section 5 sub-section governing shared seams      |
| ----------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------- |
| 1. Header + imports                                         | Step 25 (cleanup)                                     | n/a                                                      |
| 2. Config + secrets                                         | (not in Decomp's 25 steps; new sub-tree)              | n/a — config is not shared across routes                 |
| 3. JWT verification                                         | Step 12                                               | §5.1                                                     |
| 4. Policy / usage / accounting + Service Principals         | Steps 10, 13                                          | (per-route; SP gateway has no cross-cluster deps)        |
| 5. Health surface                                           | Step 15                                               | (none — health doesn't share types with route handlers)  |
| 6. LLM provider plumbing                                    | Step 14                                               | (none — pipeline composes via DI)                        |
| 7. Auth lockout                                             | Step 6                                                | (sink interface stable; routes import via DI)            |
| 8. Admin gateways + path constants + idempotency store      | Step 0 (paths) + admin gateway homes per route family | n/a — gateways are interface-only                        |
| 9. `routeRequest` mega-function                             | Steps 2-9, 11, 16-24                                  | §5.1, §5.2, §5.3, §5.4, §5.5, §5.6, §5.7, §5.8, §5.9, §5.10 |
| 10. Admin route delegates                                   | Steps 16-22                                           | §5.6, §5.7, §5.8, §5.12                                  |
| 11. Predicate matchers + helpers                            | Step 1 (helpers) + Step 23 (matchers internal to auth-team-admin) | §5.2, §5.3, §5.4, §5.5, §5.7, §5.9, §5.11, §5.12 |
| 12. CORS + JSON body + response tail                        | Step 1                                                | §5.3, §5.4, §5.5                                         |

When a Decomp step lands, look up the cluster(s) it drains here, then
look up the §5 governance to know which `routes/_shared/*.dart` file
the cross-cluster helper lands in. The two-doc system keeps cluster
boundaries (this doc) separate from "how to compose extracted route
files" (the Decomp doc).

---

## Section 5 — How to refresh this map

When a future contributor runs the next extraction:

1. Re-run `wc -l tool/advisor_proxy/advisor_proxy.dart` to capture
   the new line count.
2. Update Section 2.1 with the new count + the new ceiling
   (`<new count> + 200`).
3. Re-spot-check the cluster boundaries (anchor markers in the
   "Cluster anchor markers" table). Most boundaries shift downward by
   the LoC the extraction removed; any cluster whose anchor markers
   no longer match needs its row updated.
4. Append a row to the Section 3 table showing the actual LoC moved
   vs the estimate, and whether the ratchet held.
5. Update `kAdvisorProxyMaxLines` in `tool/advisor_proxy_size_lint.dart`
   to the new ceiling and cite the extraction PR in the constant's
   docstring.

The seam map is intentionally light on prose — the heavy lifting (per-
route line ranges, dependency tables, test reorg plan) is in the
Decomp doc. This doc's job is the cluster-level view + the bleed-stop
contract.
