# F.1 Walkthrough — Health admin surface (HP #10 cleanup)

**Slice:** Phase 11A.UX.health (F.1) — read-only Health surface for the
operations console.
**Mode:** `-DemoMode` (admin Flutter Web client + in-memory health
gateway seeded with `kHealthAdminDemoEnvelope`, no live Cloud Run
advisor proxy required).
**Date:** 2026-05-02

This walkthrough closes Hard Promise #10 — every backend phase ships
its operator-facing UX before phase close. Today the only way to
verify staging health is shell access into the proxy host; F.1 puts
the same envelope behind a Firebase-gated admin console view.

The screen is a pure consumer of the proxy `/health` envelope
(`docs/contracts/proxy_health_contract.md`). It performs **no
mutations** — there is no edit pencil, no rotate button, no apply
button. The only affordances are a Refresh button and a tab switcher.

## Authority files exercised

- `lib/main_admin.dart` — production binds
  `HttpHealthAdminGateway` against
  `--dart-define=ADMIN_PROXY_BASE_URI=...` and wraps
  `AdminConsoleApp` in `AdminConsoleServicesScope` with the new
  `healthGateway` field. Demo falls back to the seeded in-memory
  envelope in `admin_routes.dart`.
- `lib/admin/admin_routes.dart` — Health route added live (no
  placeholder phase). The route is read-only and shows the same
  surface to `super_admin` and `ff_support`. The default in-memory
  fallback gateway is constructed from `kHealthAdminDemoEnvelope`
  (mixed green/yellow signals) so the walkthrough renders rich
  fixtures without a backend.
- `lib/admin/screens/health_admin_screen.dart` — the Health admin
  surface. Three tabs (Retrieval, Proxy, Infra), top-of-page
  dependencies strip, conditional tier-1 / dependencies-unavailable
  red banners, severity chip, refresh button, 30s auto-poll.
- `lib/admin/models/health_admin_models.dart` —
  `HealthEnvelope`, `HealthMetric`, `HealthSurface`,
  `HealthDependency`, `HealthSeverity` parsers. Promotes the proxy
  contract's metric envelope into typed Dart records and derives
  `hasTier1Failure` / `hasTier2Failure` for the screen banners.
- `lib/admin/services/health_admin_gateway.dart` — HTTP +
  in-memory gateway implementations + the `kHealthAdminDemoEnvelope`
  seed. `HttpHealthAdminGateway` treats both 200 and 503 as
  "envelope received" and promotes 503 to
  `HealthEnvelope.dependenciesUnavailable: true` so the screen can
  render the top-of-page red banner regardless of which dependency
  probe failed.
- `tool/advisor_proxy/advisor_proxy.dart` (already present) — the
  `/health` route producing the envelope this surface consumes. F.1
  does not add or modify proxy code.

## Demo identities

The Health surface is read-only for both admin roles. No
`editingEnabled` flag exists; the screen has no mutate
affordances to gate. `operator@forgeflow.test` lands on the
forbidden card before the route catalog runs (the auth gate sits
above the routes).

| Email                         | Roles            | Admit decision     | Health view |
| ----------------------------- | ---------------- | ------------------ | ----------- |
| `super.admin@forgeflow.test`  | `super_admin`    | Admin shell        | Yes         |
| `support@forgeflow.test`      | `ff_support`     | Admin shell        | Yes         |
| `operator@forgeflow.test`     | `operator_owner` | Forbidden surface  | n/a         |

## Click path (text trace)

### Step 1 — Sign in as a demo super-admin

Launch the admin console with `-DemoMode -Device chrome` and sign in
as `super.admin@forgeflow.test`.

**Expected:** branded admin shell renders with the side nav
including a `Health` item between Integrations and Debug.

### Step 2 — Open Health

Click `Health` in the side nav.

**Expected:**

- Body region renders the new Health surface
  (`Key('admin_health_screen')`).
- Header reads `Health` with a one-line subtitle explaining the
  surface mirrors the D.1 contract tiers and auto-refreshes every
  30 seconds.
- Top-right shows a `Refresh` button
  (`Key('admin_health_refresh_button')`) and a `Last refreshed:`
  timestamp pinned to the most recent fetch.
- Dependencies strip (`Key('admin_health_dependencies')`) shows
  three chips — `postgres · select_1 · green`,
  `age · cypher_match · green`,
  `pgvector · similarity · green`.
- Overall severity chip
  (`Key('admin_health_overall_severity')`) reads
  `Overall severity: yellow · status degraded` for the seeded
  envelope (one tier-1 yellow signal).
- Because the seed has a tier-1 yellow signal
  (`circuit_breaker_anthropic_state` half-open), the top-of-page
  red banner (`Key('admin_health_tier1_banner')`) renders with the
  `Failing tier-1 metrics: circuit_breaker_anthropic_state`
  caption.
- Three tab labels render: `Retrieval`, `Proxy`, `Infra`
  (`Key('admin_health_tab_retrieval')` /
  `..._tab_proxy` / `..._tab_infra`).

### Step 3 — Retrieval tab (default)

The Retrieval tab is selected by default. Three sections render:

- **Corpus / rollup freshness** — two tiles: a yellow chip on
  `rollup_freshness_per_grain` (T2 · yellow) showing 4218 seconds
  with thresholds `yellow: 3600 · red: 21600`; a green chip on
  `rollup_refresh_lag_seconds`.
- **AGE graph traversal** — six tiles. Healthy fixtures: AGE p95
  92 ms, AGE p99 184 ms, graph node count 1245, graph edge count
  4218. The `graph_traversal_timeout_rate`,
  `graph_projection_age_seconds` tiles render as `T2 · unknown`
  grey chips because the seed does not populate them — the screen
  surfaces the absence rather than silently dropping them.
- **Vector search** — six tiles. Healthy fixtures: vector p50
  38 ms, p99 124 ms, recall 0.94, index size 24180. Unpopulated
  signals render as `T2 · unknown` grey chips.

Every populated tile shows: signal name (or short label like
`AGE p95`), value with unit, threshold caption (when present),
last-observed UTC timestamp, and a tier chip.

### Step 4 — Proxy tab

Click the `Proxy` tab.

**Expected:** four sections render:

- **Circuit breakers** — `circuit_breaker_anthropic_state` shows a
  red `T1 · yellow` chip on a `half_open` value (the tier-1 fail
  drives the top banner from Step 2). `circuit_breaker_voyage_state`
  shows a green `T1 · green` chip on `closed`.
- **Cache hit ratios** — three tiles for `prompt_cache_hit_rate`
  (0.62), `response_cache_hit_rate` (0.41),
  `semantic_cache_hit_rate` (0.36). All grey `T3 · green` chips
  (tier-3 informational).
- **Tier routing & cost levers** — six tiles for
  `cost_per_query_class_haiku` (0.0008 USD),
  `cost_per_query_class_sonnet` (0.012 USD),
  `cost_per_query_class_voyage` (unpopulated, grey),
  `batch_api_pending_count` (8),
  `fallback_chain_usage_count_anthropic` (12),
  `fallback_chain_usage_count_voyage` (0).
- **Idempotency & caps** — four tiles for
  `proxy_idempotency_cache_alive` (true),
  `usage_caps_breach_count` (0), `proxy_request_p99_latency_ms`
  (740 ms), `proxy_request_5xx_rate` (0.001).

### Step 5 — Infra tab

Click the `Infra` tab.

**Expected:** three sections render:

- **Database extensions & jobs** — seven tiles. Healthy fixtures:
  `azure_extensions_present` (7), `pg_cron_scheduler_alive` (true),
  `pg_cron_jobs_failed_24h` (0), `partition_count_active` (18),
  `partition_maintenance_last_run_age_seconds` (1820 s),
  `migration_apply_drift_count` (0).
- **Audit chain & event outbox** — six tiles. Healthy fixtures:
  `audit_chain_lag_seconds` (12 s),
  `event_outbox_undelivered_count` (7),
  `event_outbox_lag_seconds` (4 s), and a few unpopulated
  tier-2/tier-3 grey-chip tiles for fields the seed did not exercise.
- **Identity & runtime** — three tiles:
  `firebase_jwks_fetch_alive` (true),
  `service_principal_jwt_alive` (true),
  `cloud_run_instance_count` (2).

### Step 6 — Refresh button updates the timestamp

Click the `Refresh` button.

**Expected:** the gateway fetch is re-issued; the
`Last refreshed:` line bumps to a new UTC timestamp; tile
`observed:` lines refresh against the same fixtures (the in-memory
gateway returns the same envelope until
`InMemoryHealthAdminGateway.setEnvelope(...)` is called from a
debug shell).

### Step 7 — `ff_support` lands on the same read-only view

Sign out, sign in as `support@forgeflow.test`.

**Expected:** the admin shell still renders (`ff_support` is
admitted by `kAdminConsoleRoles`). Click `Health`. The same
three-tab surface renders, identical to the super-admin view —
there are no edit affordances to gate (read parity is the whole
point of F.1). Asserted by `test/admin/health_admin_screen_test.dart`
which drives the screen against an `InMemoryHealthAdminGateway`
without an `editingEnabled` flag (none exists).

### Step 8 — Tier-1 failure path (forced drift)

Forcing a tier-1 failure exercises the global red banner. The
recommended way in dev is to mutate the seeded envelope before
launch:

```dart
// in `lib/admin/admin_routes.dart` (dev-only edit)
_defaultHealthDemoGateway = InMemoryHealthAdminGateway(envelope: {
  ...kHealthAdminDemoEnvelope,
  'metrics': {
    ...kHealthAdminDemoEnvelope['metrics']! as Map<String, Object?>,
    'migration_apply_drift_count': {
      'status': 'red',
      'value': 4,
      'unit': 'count',
      'description': 'Migration files not yet recorded as applied.',
      'owner': 'B42',
      'observed_at': '2026-05-02T12:00:00.000Z',
      'thresholds': {'red': 1},
      'metadata': {'tier': 1},
    },
  },
});
```

**Expected:** the top-of-page red banner
(`Key('admin_health_tier1_banner')`) reads
`Failing tier-1 metrics: circuit_breaker_anthropic_state,
migration_apply_drift_count`; the `migration_apply_drift_count`
tile on the Infra tab shows a red `T1 · red` chip with value `4`
and threshold caption `red: 1`. Asserted by
`test/admin/health_admin_screen_test.dart`
test `tier-1 metric failure surfaces the red top-of-page banner`.

### Step 9 — Edge: HTTP 503 dependencies-unavailable path

To exercise the 503 path in demo mode, mount the gateway with
`InMemoryHealthAdminGateway(envelope: ..., dependenciesUnavailable:
true)`. In production this happens automatically when
`HttpHealthAdminGateway.fetch()` receives an HTTP 503 from the
proxy.

**Expected:** the top-of-page red banner
(`Key('admin_health_dependencies_unavailable')`) replaces the
tier-1 banner with the message `Dependencies unavailable — proxy
/health returned HTTP 503...`; the dependencies strip and the
metric tabs still render against the body the proxy returned
before tipping to 503. Asserted by
`test/admin/health_admin_screen_test.dart` test `HTTP 503 path
renders the dependencies-unavailable banner`.

### Step 10 — Verify non-admin fail-closed

Sign out, sign in as `operator@forgeflow.test`.

**Expected:** the branded forbidden card renders. The Health
surface, side nav, and header bar are absent. Asserted by the
existing `test/admin_auth_gate_test.dart` test that gates the
entire admin console against `kAdminConsoleRoles`.

## Trace summary (text evidence)

```
signin    super.admin@forgeflow.test                      -> admin shell        (PASS)
nav       /health                                         -> health screen       (PASS)
seed      deps strip green; tier-1 yellow banner visible  -> half-open breaker   (PASS)
tabs      Retrieval / Proxy / Infra render                -> 3 tabs             (PASS)
retrieval rollup_freshness_per_grain shows yellow chip    -> T2 · yellow        (PASS)
proxy     circuit_breaker_anthropic_state half_open red   -> T1 · yellow chip   (PASS)
infra     extensions present + cron alive + audit lag 12s -> all green          (PASS)
refresh   Refresh button bumps Last refreshed timestamp   -> gateway re-fetch   (PASS — screen test)
forced    tier-1 fail (migration drift) → red banner      -> tier1_banner shown (PASS — screen test)
edge      HTTP 503 → dependencies_unavailable banner      -> red banner shown   (PASS — screen test)
ff_support same surface, no editing affordances           -> read parity        (PASS — screen test)
operator  forbidden card                                  -> auth gate fail-closed (PASS — gate test)
```

## Permission gating evidence

- Client side (admin console): the Health route is only reachable
  when the auth gate admits the caller (`super_admin` or
  `ff_support`); `operator@forgeflow.test` lands on the forbidden
  card. The route exposes the gateway via
  `AdminConsoleServicesScope.healthGatewayOf(context)`; there is
  no `editingEnabled` flag because the surface has no mutate
  affordances.
- Server side (proxy): `/health` is a public unauthenticated
  endpoint per `docs/contracts/proxy_health_contract.md`. The
  envelope is intentionally tenant-free so it is safe to expose
  without an admin session, but in F.1 the surface is still
  reachable only through the admin console (gated by Firebase
  custom claims) — operators do not see this surface from the
  operator app.

## Tenant-identifier invariant

The proxy `/health` envelope MUST NOT carry tenant or operator
identifiers (`docs/contracts/proxy_health_contract.md` is explicit
about this). The admin screen is a pure consumer of that envelope,
but a careless code change could still leak a smuggled identifier
out of the metric `metadata` slot. Asserted by
`test/admin/health_admin_no_tenant_identifier_test.dart` test
`rendered text contains no operator_id/tenant_id-shaped values`,
which seeds three sentinel identifiers
(`00000000-0000-4000-8000-000000000fff`, `tenant-abc-123`,
`device-xyz-789`) and the metadata key names `operator_id`,
`tenant_id`, `device_id` into a metric's `metadata`, walks every
rendered `Text` widget, and asserts none of the sentinels appear.

## Tests run

- `dart analyze lib/admin lib/main_admin.dart test/admin/health_admin_*` —
  clean (`No issues found!`).
- `flutter test test/admin/health_admin_gateway_test.dart` —
  passes (10 tests: envelope parser, severity promotion,
  tier-1/tier-2 failure detection, 503 path, in-memory gateway
  round-trip, threshold caption rendering).
- `flutter test test/admin/health_admin_screen_test.dart` —
  passes (5 tests: 3-tab render, tier-1 banner path, 503 banner
  path, tier-2 chip rendering, manual refresh re-fetch).
- `flutter test test/admin/health_admin_no_tenant_identifier_test.dart`
  — passes (1 test: smuggled-identifier sentinels never reach
  rendered output).
- `flutter test test/admin_console_test.dart
  test/admin_shell_widget_test.dart test/admin_auth_gate_test.dart` —
  passes (43 regression tests on the admin shell + auth gate; F.1
  added a Health route to the catalog and grew
  `AdminConsoleServicesScope` with a `healthGateway` field, so the
  shell + gate regression check covers that the existing routes
  still admit/render correctly).

## Boundary checks

- F.1 does NOT touch the proxy `/health` producer code or the
  envelope contract. The screen is a pure consumer of the existing
  `tool/advisor_proxy/advisor_proxy.dart` route.
- F.1 does NOT touch operator-facing app code. The Health surface
  lives entirely under `lib/admin/` and the admin entrypoint
  (`lib/main_admin.dart`).
- The 11A.1 / 11A.2 / 11A.3a / 11A.4 admin routes
  (`/operators`, `/pricing`, `/corpus`, `/integrations`) are
  untouched. The new Health route is appended after Integrations
  and before the Debug placeholder.
- No tenant identifiers leak into the rendered surface — asserted
  by `test/admin/health_admin_no_tenant_identifier_test.dart`.
- The screen has no mutate affordances. There is no edit pencil,
  rotate button, apply-template button, or input field. The only
  user-driven action is the `Refresh` button.
- Auto-polling defaults to 30 seconds (`kHealthAdminPollInterval`
  in `health_admin_screen.dart`). The widget tests disable
  polling via `autoRefresh: false` so periodic timers cannot leak
  into the test runner.
- `AdminConsoleServicesScope` grows a `healthGateway` field next
  to the existing 11A.1–11A.4 gateways. The fallback
  (`_defaultHealthDemoGateway`) is the in-memory variant seeded
  with `kHealthAdminDemoEnvelope`; production binds
  `HttpHealthAdminGateway` against
  `--dart-define=ADMIN_PROXY_BASE_URI=...` (the same proxy host
  serves admin-gated `/v1/admin/*` and the public `/health`).
- No tracker updates and no commits.
