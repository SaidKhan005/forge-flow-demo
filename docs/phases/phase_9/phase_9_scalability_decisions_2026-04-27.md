# Phase 9 Scalability Decisions - 2026-04-27

Status: RECONCILED - Stress-test rollout decisions merged 2026-04-27.

Source: 4-agent research sweep on 2026-04-27, follow-up user decisions in
`decision.md`, and AI architecture reconciliation in `AI_RECONCILE.md`.

Decision authority order: user-confirmed answers in this document win unless
contradicted by an earlier locked contract.

---

## Operating Principle

User-stated framing for every decision in this doc:

1. **Scale-first.** Design for the largest plausible operator count, not the
   MVP. Single-tenant shortcuts are dead.
2. **Lowest user friction.** Pick the path humans do not trip over.
3. **Highly intuitive.** UX weighs as much as backend correctness.
4. **Foundation now, explicit deferral only when chosen.** Build schema hooks,
   provider abstractions, health visibility, audit trails, and migration paths
   now. Large enterprise features may be deferred only when the decision says
   exactly what triggers them later and what must be built now to avoid a
   rewrite.

This replaces the earlier "nothing deferred" wording. Some items are
intentionally deferred because the user judged them overkill for launch
restaurants, provided the foundation remains safe to extend.

---

## Tier 1 - Foundation

### Q1. Multi-operator User Identity

**Asked:** 2026-04-27.

**Decision:** Build multi-operator identity now.

- **Operator selection UX:** web supports both `app.forgeflow.app` login with
  in-app picker and operator subdomains like `{operator}.forgeflow.app`; mobile
  uses the picker only. DNS wildcard and ACME wildcard cert work lands in
  Phase 10.
- **Permission evaluation:** per-operator only. RLS keys on `operator_id`;
  unified cross-operator permission evaluation is incompatible with the storage
  model.
- **Email uniqueness:** global unique. One human has one identity record even
  if they belong to multiple operators.
- **FF staff principal model:** F&F staff access uses the internal admin/dev
  control plane with F&F-controlled dynamic roles and explicit audit trails.
- **Audit attribution:** every audit row stamps `actor_user_id`,
  `active_operator_id`, and `acting_as_operator_id` or `target_operator_id`
  where relevant.

#### Q1 FF Internal Admin/Dev Access - Revised 2026-04-27

F&F staff authenticate into the internal F&F admin/dev dashboard with their
own F&F user account, including MFA at dashboard login. The same universal
dynamic role/permission system used for operators also controls F&F staff
access, using the internal F&F role definitions locked elsewhere in Phase 9.
F&F roles may have broader platform or cross-operator scope than operator
roles.

Operators remain scoped to their own operator account. F&F internal roles may
access operator backend/admin views across operators according to F&F-controlled
permissions. This supports onboarding operators, creating/configuring
locations, setting up users/roles, checking integration health, reviewing sync
failures, inspecting reporting/rollup freshness, resolving billing/usage
issues, running rebuild/retry tools, and reviewing audit/debug logs.

F&F internal access must pass through the authorization layer and an explicit
`target_operator_id` context. It must not rely on raw database bypass, hidden
JWT flags, or unaudited direct access for normal support/dev operations. RLS
remains the default tenant-isolation model for operator-facing access; F&F
internal roles receive explicit cross-operator permissions through the central
permission system.

This is not operator impersonation by default. Normal F&F support/dev work
happens through the internal admin/dev control plane, similar to Oracle-style
vendor administration. True operator-user impersonation, if ever built, is a
separate stricter mode and should be rare, visibly labeled, and separately
audited.

Existing magic JWT bypass flags such as `is_super_admin` / `is_ff_support` are
deprecated in favor of real dynamic roles and auditable permissions.

### Q2. Operator Hierarchy Depth

**Decision:** recursive `org_units` hierarchy with Postgres `ltree`.

- **Storage pattern:** `org_units.path` is an `ltree` materialized path,
  GiST-indexed. Subtree queries use `path <@ ancestor_path`.
- **Max depth cap:** 6 levels via `CHECK (nlevel(path) <= 6)`.
- **Permission inheritance:** grants at any node apply to descendants.
  Explicit deny at a descendant overrides inherited access.
- **Naming:** `unit_type` enum is `corp | region | district | location_group`.
  `location_group` is nestable and may repeat. Brand identity lives in
  `brand_name` / display fields, not in `unit_type`.
- **Relationship to locations:** `locations` keeps physical attributes and has
  `parent_org_unit_id NOT NULL` plus denormalized `org_unit_path ltree`.
- **Effective-access lookup:** RLS uses `ltree` subtree checks directly; UI hot
  paths read `user_effective_locations(user_id, operator_id, location_id)`.

#### Q2 Additions

**Historical hierarchy provenance.** Hierarchy changes must not rewrite
historical reporting truth. If a location moves from one org unit to another,
future reports use the new hierarchy, but historical reports remain explainable
under the hierarchy active at the time. Hierarchy changes are audited, and
rollups/history preserve the relevant `org_unit_path` or hierarchy version used
for the reporting period. Historical rollup rebuilds must use the hierarchy
version or `org_unit_path` active during the reporting period being rebuilt,
not the current hierarchy at rebuild time.

**Permission explainability.** Because deny-wins inheritance can be confusing,
the admin/operator UX must explain effective access. When a user has inherited
access from a parent org unit but is blocked at a child org unit/location, the
UI shows both the inherited grant source and the explicit deny source.

**`unit_type` is structural, not branding.** `unit_type` describes where a node
sits in the reporting/permission hierarchy. Brand, concept, or marketing
identity lives in `brand_name` / display fields.

**`location_group` naming discipline.** Because `location_group` replaces
brand, sub-region, and `other`, the admin UX requires a clear display name and
discourages vague labels such as "Other," "Misc," or "Group 1."

### Q3. Aggregation / Rollup Architecture

Q2 locks recursive `org_units`. The reporting question is how F&F can show
Region/District/Brand/Location reporting quickly without recomputing millions
of raw facts on every page load.

#### Q3.1 Rollup Refresh Strategy - Locked

Use incremental batch via `pg_cron`, not synchronous write triggers. Refresh
interval is 60s for hot grains such as today/this week and 300s for colder
grains such as month/quarter. Jobs use sequence-watermarked
`aggregation_state(rollup_table, grain, last_processed_seq)`. This avoids
write-time lock contention on hierarchy ancestors. UI freshness labels tell the
truth about bounded staleness.

#### Q3.2 Storage Form - Locked

Use a hybrid strategy with physical rollup tables as the default storage form
for operator-facing reporting, hierarchy rollups, usage/billing summaries,
variance summaries, History, Learn, and compliance-sensitive metrics.

Usage caps are enforced from a real-time usage ledger/counter before allowing
additional usage. Rollup tables summarize usage for dashboards, billing review,
reporting, and historical analysis, but delayed rollups are not the primary
real-time enforcement source.

Materialized views are allowed only for internal/admin helper analytics,
rebuild diagnostics, and non-authoritative computation stages. They must not be
directly exposed as operator-facing truth.

Rollup rows include `operator_id`, `scoped_org_unit_id`, optional
`location_id`, grain, period, metric values, source watermark, `rule_version`,
`computed_at`, and freshness/status fields. RLS applies directly to physical
rollup tables.

TargetCycle, WeeklyPlanSnapshot, closed shift/week history, Variance, and Learn
remain snapshot/fact-based. Rollup refreshes may summarize them but must never
rewrite locked historical truth.

#### Q3.3 Rollup Grain Set - Locked

F&F standardizes rollup grains across all operators: `daypart`,
`business_day`, `week`, `accounting_period`, `month`, `quarter`, and `year`.
Operators may configure the calendar rules behind those grains, including
business-day boundary, daypart definitions, week start day, fiscal year start,
and accounting-period pattern. If not configured, F&F applies default
restaurant-safe settings.

The grain set itself is not custom per operator. Hourly/minute-level summaries
are excluded from the main web-reporting rollup architecture at launch and
remain live-operational views only when needed.

#### Q3.4 Rollup Dimensions - Locked

F&F standardizes the restaurant reporting slices used across web reporting:
operator, org hierarchy scope, location, time period, daypart, revenue center,
sales category, ordering/service channel, labor role/group, and vendor/source
where relevant.

Operators may configure names and mappings for dayparts, revenue centers, sales
categories, channels, and labor roles. If not configured, F&F uses
vendor-imported defaults and safe fallback buckets.

Plan, Variance, History, and Learn store locked-truth references behind the
scenes, including `weekly_plan_snapshot_id`, `target_cycle_id`, and
`rule_version`, so F&F can explain which plan and target the numbers were judged
against.

#### Q3.5 Late-arriving Data - Locked

Late-arriving or corrected vendor data updates reporting rollups through
bounded recomputation. F&F identifies the affected operator, location/scope,
source system, metric family, and business-date window, marks related rollups
stale, and rebuilds only affected grains.

Reporting totals may be corrected when source facts change. Locked business
snapshots are never silently rewritten. TargetCycle, WeeklyPlanSnapshot, closed
shift target snapshots, closed week history, advisor evidence, and audit records
retain the version in force at the time unless an explicit correction workflow
is used.

#### Q3.6 Rollup Idempotency - Locked

All rollup jobs are idempotent. Re-running the same aggregation window produces
the same final rollup row and must never double-count metrics. Rollups use
deterministic keys based on operator, scope/location, metric family, grain,
period, and relevant dimensions. Jobs write with UPSERT/replace semantics.

#### Q3.7 Freshness UI - Locked

All operator-facing reporting surfaces backed by rollups expose freshness when
data may be delayed. The UX uses plain labels such as "Updated just now,"
"Updated 5 minutes ago," or "Data delayed." If a rollup is stale or failed, F&F
serves the last known good result with a visible stale-data warning instead of
fabricating fresh numbers or blocking unrelated reports.

#### Q3.8 Rollup Rebuild Strategy - Locked

Rollups are rebuildable derived data, not source truth. Rebuilds run by bounded
scope: operator, org unit/location, metric family, date range, grain, and
`rule_version`. Rebuilds write to staging or versioned targets first, validate
totals/row counts, then promote atomically.

#### Q3.9 Rollup Error Handling - Locked

When a rollup job fails, F&F serves the last known good rollup where available
and marks the affected report stale. Bad source rows are quarantined when
possible so one malformed vendor record does not stop unrelated rollups.

#### Q3.10 Rollup Observability - Locked

Rollup Health is part of the F&F Dev/Admin Health UX standard. It monitors
freshness, failed jobs, retry count, source-system lag, last processed
watermark, row-count anomalies, rebuild status, promotion status, quarantined
source records, and affected reports.

---

## Stress-Test Rollout Queue

### Revised Locked Decisions

1. **Q2 unit_type enum tightening - Locked 2026-04-27.** Replaced
   `operator | brand | region | district | other` with
   `corp | region | district | location_group`. Brand identity is a
   `brand_name` / display field, not a tree level.

2. **Q1 FF internal admin/dev access - Locked 2026-04-27.** F&F support/dev
   work uses F&F-controlled internal admin/dev access through the universal
   dynamic role/permission system. No hidden JWT bypass
   for normal support/dev work; all actions require `target_operator_id`,
   central authorization, and audit rows.

3. **Decision F restore MarginEdge / R365 inbound to Phase 8 - Locked
   2026-04-27.** Outbound finance remains deferred to post-launch Phase 8.5.
   Inbound invoice/vendor-bill ingestion from MarginEdge and R365 is restored
   to the launch vendor list as read-only data ingestion.

4. **Decision C RLS STABLE LEAKPROOF UUID wrapper functions - Locked
   2026-04-27.** RLS policy bodies use `app_current_operator()`,
   `app_current_location()`, `app_current_actor_user()`, and
   `app_acting_as_operator()` instead of inline
   `current_setting('app.operator_id')::uuid`. The wrappers are
   `LANGUAGE sql STABLE LEAKPROOF PARALLEL SAFE`; CI lint forbids literal
   `current_setting('app.` in policy bodies.

5. **Hard Promise #6 advisor_conversation_log - Locked 2026-04-27.** Every
   advisor turn writes one provenance row through the proxy. Raw question and
   recommendation text are encrypted at rest and gated by a restricted
   audit-privacy / privacy-compliance permission. Hashes and non-sensitive
   metadata remain queryable for audit readers. Quebec Law 25 is only a future
   Quebec-market compliance mapping, not the launch rationale.

6. **Decision C usage_caps two-slot key - Locked 2026-04-27.** `usage_caps`
   uses `(billing_owner_org_unit_id, scoped_org_unit_id, location_id,
   staff_id, workflow_id, usage_class)`. The billing owner is who pays; scoped
   org is where the cap applies. This supports company-wide, brand/sub-org,
   location, staff, workflow, and usage-class caps in the same table.

### Launch Requirements And Future Market Gates

7. **Anthropic + Voyage ZDR/privacy posture - Locked 2026-04-27.** ZDR remains
   the preferred/required privacy and operator-IP posture if still desired by
   F&F. Phase 9.8 gates on general vendor privacy/security readiness unless
   Quebec market entry is activated. Quebec cross-border PIAs become required
   before offering the product in Quebec. `vendor_integrations` includes
   `zdr_status`.

8. **CMK at provisioning / cutover.0a - Locked 2026-04-27.** CMK remains
   required if needed for security, SOC 2, operator IP protection, or
   Enterprise buyer trust. Production2 is provisioned in the selected launch
   region, not automatically Canada Central. Canadian residency is not a
   general launch gate. CMK is enabled at server creation time, with Key Vault
   rotation policy, migration replay, logical replication, smoke tests, cutover
   runbook, rollback path, observation window, immutable snapshot, and retire
   path.

9. **Quebec Law 25 Privacy Officer - Future Quebec-market gate.** F&F may keep
   a general privacy contact at launch. Operator-side Quebec Privacy Officer
   onboarding is required only when an operator has Quebec locations or F&F
   launches in Quebec.

10. **Bill 96 French UI - Future Quebec-market gate.** Full operator-facing
    fr-CA UI, sworn/legal French translation, and Quebec-specific language
    controls are required before Quebec launch, not as a general launch
    blocker. Optional future-proofing remains allowed: `users.locale`,
    `operators.default_locale`, notification locale axis,
    `methodology_chunks.lang`, and string-catalog discipline.

11. **Phase 8 PCI DSS v4.0.1 PAN exclusion - Locked 2026-04-27.** F&F is not a
    card-payment processor and never wants PAN. Vendor agreements exclude PAN;
    ingest-time validation blocks PAN-shaped strings before Postgres; near
    misses create audit alerts. Implementation should prefer field/record
    quarantine or redaction over blocking the entire connector when safe, so
    PCI protection does not create avoidable vendor integration friction.

12. **Anthropic prompt-cache TTL pin - Locked 2026-04-27.** Every cached block
    must explicitly set `cache_control: {"type": "ephemeral", "ttl": "1h"}`
    so cost assumptions do not silently break if vendor defaults change.
    Assert this in proxy unit tests.

13. **SHA-256 hash-chained audit log + daily Azure Blob immutable anchor -
    Locked 2026-04-27.** Add `prev_row_hash` and `row_hash`; each insert hashes
    `prev_row_hash || payload`. A daily job anchors the latest hash to
    immutable Blob storage. Rationale: SOC 2, security forensics, dispute
    reconstruction, and future privacy compliance.

14. **service_principals in Phase 9 schema - Locked 2026-04-27.** Add
    `service_principals` now for workflow runtime, vendor webhooks, scheduled
    jobs, system-health probes, and F&F internal automation. JWT subjects use
    `sp:` prefix and audit rows have a non-human attribution slot.

### Identity, Authorization, Isolation, DR

15. **Q4 Identity Provider - Locked 2026-04-27.** Firebase Identity Platform is
    the launch IdP. Launch scope covers Firebase-backed email/social login,
    admin MFA, invite/deactivate flows, and F&F-owned authorization tables.
    Firebase UID is stored as an external identity reference behind an
    `AuthProvider` abstraction so WorkOS/Auth0/SCIM can be added later.

16. **Q5 SCIM trigger - Locked / deferred until trigger.** Enterprise SSO/SCIM
    is post-launch and triggered by a signed enterprise operator requirement.
    No WorkOS/Auth0/SCIM implementation in Phase 9.7 or Phase 11B. Pricing
    treats SSO/SCIM as Enterprise-tier functionality or paid enterprise add-on.

17. **Q6 Authorization model - Locked 2026-04-27.** Launch authorization is
    RBAC with permission keys and scoped grants, not Zanzibar/OpenFGA. Phase 9
    schema supports operator/org-unit/location/workflow-scoped grants and
    central permission evaluation. Do not hardcode role names as authorization
    logic; check permission keys through the authorization layer. Keep room for
    future relationship tuples.

18. **Q7 Tenant isolation - Locked 2026-04-27.** Launch isolation is
    shared-schema Postgres with strict RLS for standard operators.
    Schema-per-tenant and DB-per-tenant are not launch defaults. Enterprise
    operators may later receive a dedicated database/server when scale,
    privacy, residency, backup/restore, contract, or compliance requirements
    justify it. Routing and schema must avoid assuming one database forever.

19. **Q8 Multi-region future-proofing - Locked 2026-04-27.** Launch uses a
    single production region selected for the initial market. Quebec/Canada
    residency is not a launch gate. Phase 9 remains region-ready by adding
    `data_region` / `residency_region` metadata at operator/org-unit scope,
    centralizing tenant-to-region routing, and ensuring migrations, backups,
    exports, jobs, audit anchoring, and connection selection do not assume one
    region forever.

20. **Q9 Audit log retention - Locked 2026-04-27.** Tamper-evident audit logs
    retain for 7 years by default. Legal hold overrides expiry. Per-operator
    overrides are allowed for Enterprise/regulatory cases. JSONL is canonical
    export for evidence/replay; Parquet is secondary analytics format.
    `pg_partman` handles time partitioning and retention jobs audit archive,
    hold, purge, and failed purge attempts.

21. **Q10 RTO / RPO targets - Locked 2026-04-27.** Standard launch DR target is
    RTO <= 4 hours and RPO <= 15 minutes for core production data. Enterprise
    may contract for RTO <= 1 hour and RPO <= 5 minutes with paid dedicated
    infrastructure and tested regional failover. No zero-data-loss or
    active-active promise at launch. DR exercises run semi-annually before
    Enterprise commitments and quarterly once Enterprise DR SLOs are sold.

### AI, Compliance, Billing, Integrations

22. **Q11 Multi-LLM fallback - Locked 2026-04-27.** Anthropic is primary at
    launch. Keep `LLMProvider` abstraction and log `model_id` /
    `model_version`, but automatic cross-provider fallback is disabled unless
    the fallback provider has approved privacy/ZDR terms, cost ceilings,
    prompt-portability tests, and advisor quality evals. On Anthropic 5xx or
    rate-limit, retry/backoff then fail gracefully instead of silently switching
    models.

23. **Q12 Dual-index re-embedding strategy - Locked 2026-04-27.** Voyage is
    primary at launch, but embeddings are provider-versioned from day one. Keep
    canonical chunk text separate from embeddings. Store embeddings by
    provider/model/version/dimensions/lang/chunk. Build vector indexes per
    provider/model. Fallback embeddings are generated only when contract,
    pricing, ZDR, quality, or availability triggers require it.

24. **Q13 Predictive scheduling compliance - Out of scope for launch / reopen
    if scheduling becomes system-of-record.** F&F does not create, publish,
    approve, or modify binding employee schedules. Planning views are proposed,
    non-binding, on-demand planning aids. If F&F becomes a native scheduler or
    employee-schedule system of record, reopen before design/build.

25. **Q14 FLSA tip-credit + meal-break premium pay - Locked 2026-04-27.** F&F
    is not the payroll system of record and does not determine legal wage
    compliance. If TargetCycle, WeeklyPlanSnapshot, or Variance estimate labor
    cost, they use a versioned `labor_cost_rules` library selected by each
    location's compensation profile. Snapshots store `rule_version`, inputs,
    assumptions, and calculated output.

26. **Q15 Multi-currency billing - Locked 2026-04-27.** Launch billing supports
    CAD and USD only. EUR/GBP are deferred until EU/UK market entry or signed
    customer demand. Each subscription has `billing_currency` and
    `reporting_currency`; invoices, usage charges, credits, refunds, taxes, and
    revenue events store original currency amounts plus `fx_rate_id` and
    converted home-currency amounts. Price books are currency-specific, not
    live-FX converted at invoice time.

27. **Q16 Integration connection scoping and vendor-location mapping - Locked
    2026-04-27.** F&F must not assume one integration equals one operator or
    exactly one location. Connect the vendor account, then map vendor locations
    to F&F locations. Integration connections are operator-owned and may be
    scoped to org units/locations; a mapping table links vendor restaurant/site
    IDs to F&F `location_id`s. This keeps Downtown sales out of Airport reports
    and lets location managers edit only their own integration scope.

28. **Q17 Accessibility target - Locked 2026-04-27.** Operator console and
    phone app target WCAG 2.2 AA. This is launch-quality work driven by
    AODA/EU EAA readiness, enterprise procurement, and inclusive quality, not
    Quebec as launch rationale. CI runs automated accessibility checks for key
    web flows. Each release covers keyboard navigation, focus order, labels,
    contrast, forms, errors, and reduced motion. Manual screen-reader testing
    is required before launch and semi-annually after launch.

29. **Q18 Webhook signing-key rotation - Deferred / not launch requirement.**
    F&F verifies signed vendor webhooks where signatures exist, stores secrets
    securely, and logs/alerts signature failures. Formal scheduled rotation,
    active/previous/next key states, and dual-key windows are deferred to avoid
    early integration friction. Rotate manually if a secret is compromised,
    leaked, or vendor-required.

### Health, Scale, Deletion, Eventing

30. **Q19 AGE graph scale tripwire + rebuildable projection - Locked
    2026-04-27.** Apache AGE remains the launch graph query engine, but AGE is
    not the source of truth. Canonical graph data lives in ordinary Postgres
    `graph_nodes` and `graph_edges` tables with stable IDs, scope/version keys,
    edge type, confidence/source metadata, active dates, and soft-delete/archive
    markers. AGE graphs are rebuildable projections.

    Graph Health shows green/yellow/red status, edge count, vertex count,
    high-degree nodes, p95/p99 traversal latency, timeout rate, failed
    traversals, slowest queries, growth projection, last projection build, last
    benchmark, affected advisor functionality, and recommended action. Yellow
    fires at 3M active edges in one AGE graph or sustained latency regression.
    Red fires at 4M active edges, repeated timeouts, or projected 90-day growth
    crossing 5M. Rollover actions are non-destructive: repartition projections,
    prune/archive stale edges from active projections without deleting
    canonical data, rebuild AGE, shadow-query Neo4j/managed graph, and cut over
    only after validation.

31. **Q20 Vector Index Health + HNSW to DiskANN switch trigger - Locked
    2026-04-27.** HNSW is default for active corpora. DiskANN is installed but
    not default until scale/performance requires it. Treat ~10M vectors in one
    searchable embedding space as the internal HNSW risk line. Vector Index
    Health shows active vectors, index type, size, build status, last build,
    benchmarks, p50/p95/p99 latency, timeout rate, recall score, filtered
    search behavior, growth projection, affected functionality, and recommended
    action. Yellow fires at 5M vectors, latency regression, rebuilds exceeding
    maintenance window, or memory pressure. Red fires at 8M vectors, projected
    growth crossing 10M, repeated timeouts, unacceptable recall/latency, or
    operationally unsafe rebuilds. DiskANN cutover is non-destructive and uses
    shadow query, benchmark, canary routing, and 14-day rollback window.

32. **Q21 Sensitive information deletion/redaction - Locked 2026-04-27.** F&F
    does not implement broad hard-delete of all subject-linked business history
    as a launch requirement. Privacy deletion focuses on sensitive personal
    information and unnecessary raw content while preserving required records,
    auditability, billing history, usage history, dispute evidence, and
    aggregate analytics.

    Sensitive information includes direct identifiers and high-risk raw content
    such as SIN/SSN, government IDs, full dates of birth where not required,
    personal phone/email where no longer needed, home address, bank/payment
    details, health/accessibility notes, emergency contacts, identity documents,
    raw free text containing personal details, and PAN/card data that should
    never have been ingested.

    Advisor replay keeps hashes, `model_id`, `model_version`,
    `system_prompt_hash`, retrieved chunk IDs, graph paths, timestamps,
    `query_class`, token counts, latency, and other non-sensitive metadata.
    Raw encrypted question/recommendation text may be retained only when there
    is a valid retention basis. If raw text is redacted/deleted, the redaction
    ledger records that full deterministic replay is limited and why.

    Sensitive deletion/redaction applies to advisor learning candidates,
    approved lessons, generated Markdown lesson documents, promoted corpus
    chunks, embeddings, graph projections, and search indexes. Approved
    non-sensitive operational lessons may be retained only if they no longer
    contain sensitive personal information and keep safe provenance. Source
    redactions force linked lessons to be reviewed, amended, expired, or
    re-promoted from sanitized text.

33. **Q22 Postgres NOTIFY to Cloud Pub/Sub scale boundary - Locked
    2026-04-27.** `NOTIFY` is only a lightweight wake-up signal for durable
    `event_outbox`; it is never the source of truth. Every event is written to
    `event_outbox` in the same transaction as the business change; the bridge
    reads outbox, publishes to Pub/Sub, and marks delivered only after Pub/Sub
    accepts. This is internal reliability work and must not create vendor
    integration friction.

    Yellow fires when bridge lag exceeds 60s, undelivered outbox rows exceed
    10,000, publish error rate exceeds 1%, or `pg_notification_queue_usage()`
    exceeds 0.10. Red fires at 5 minutes lag, 100,000 undelivered rows,
    repeated publish failures, or queue usage above 0.25. Fallback is polling
    by shard, increasing workers, dead-lettering repeated failures, and slowing
    non-critical producers if needed.

34. **Q3.2 Storage form - Locked 2026-04-27.** Physical rollup tables are the
    operator-facing standard; materialized views are internal helpers only.

35. **Q3.3 through Q3.10 rollup architecture - Locked 2026-04-27.** Grain set,
    dimensions, late data, idempotency, freshness UI, rebuild strategy, error
    handling, and observability are locked in the Q3 section above.

36. **Tracker rollout pass - Pending implementation.** PROJECT_TRACKER.md must
    pick up the reconciled decisions: Phase 9.0 schema additions, Q1 internal
    admin/dev model, Q3 rollups, Q4/Q5 launch/deferred identity decisions,
    Q7/Q8 isolation/region hooks, Q9/Q10 audit/DR, Q11/Q12 AI provider and
    embedding abstractions, Q16 integration mapping, Q19/Q20 health panels,
    Q21 deletion/redaction, Q22 outbox bridge, Quebec future-market gates,
    MarginEdge/R365 inbound, PCI PAN exclusion, Anthropic TTL pin, CMK
    cutover.0a, and Phase 12 service-principal dependency.

### Status Tracker

| # | Item | Status | Locked Date |
| - | ---- | ------ | ----------- |
| 1 | Q2 unit_type enum tightening | Locked | 2026-04-27 |
| 2 | Q1 FF internal admin/dev access | Locked | 2026-04-27 |
| 3 | Decision F restore MarginEdge/R365 | Locked | 2026-04-27 |
| 4 | RLS UUID wrapper functions | Locked | 2026-04-27 |
| 5 | Advisor conversation log | Locked | 2026-04-27 |
| 6 | usage_caps two-slot | Locked | 2026-04-27 |
| 7 | Anthropic/Voyage ZDR/privacy readiness | Locked | 2026-04-27 |
| 8 | CMK at provisioning / cutover.0a | Locked | 2026-04-27 |
| 9 | Quebec Privacy Officer future gate | Locked | 2026-04-27 |
| 10 | Bill 96 French UI future gate | Locked | 2026-04-27 |
| 11 | PCI PAN exclusion | Locked | 2026-04-27 |
| 12 | Anthropic prompt-cache TTL pin | Locked | 2026-04-27 |
| 13 | Hash-chained audit log | Locked | 2026-04-27 |
| 14 | service_principals in Phase 9 | Locked | 2026-04-27 |
| 15 | Q4 IdP choice | Locked | 2026-04-27 |
| 16 | Q5 SCIM trigger | Deferred-with-trigger | 2026-04-27 |
| 17 | Q6 RBAC vs ReBAC | Locked | 2026-04-27 |
| 18 | Q7 Tenant isolation | Locked | 2026-04-27 |
| 19 | Q8 Multi-region future-proofing | Locked | 2026-04-27 |
| 20 | Q9 Audit retention | Locked | 2026-04-27 |
| 21 | Q10 RTO/RPO | Locked | 2026-04-27 |
| 22 | Q11 Multi-LLM fallback | Locked | 2026-04-27 |
| 23 | Q12 Dual-index embeddings | Locked | 2026-04-27 |
| 24 | Q13 Predictive scheduling | Deferred-with-trigger | 2026-04-27 |
| 25 | Q14 Labor-cost rules | Locked | 2026-04-27 |
| 26 | Q15 Multi-currency billing | Locked | 2026-04-27 |
| 27 | Q16 Integration connection mapping | Locked | 2026-04-27 |
| 28 | Q17 WCAG 2.2 AA | Locked | 2026-04-27 |
| 29 | Q18 Webhook key rotation | Deferred-with-trigger | 2026-04-27 |
| 30 | Q19 AGE graph tripwire | Locked | 2026-04-27 |
| 31 | Q20 HNSW/DiskANN switch trigger | Locked | 2026-04-27 |
| 32 | Q21 Sensitive deletion/redaction | Locked | 2026-04-27 |
| 33 | Q22 NOTIFY/outbox/Pub/Sub | Locked | 2026-04-27 |
| 34 | Q3.2 Storage form | Locked | 2026-04-27 |
| 35 | Q3.3-Q3.10 remaining | Locked | 2026-04-27 |
| 36 | Tracker rollout pass | Pending implementation | - |

---

## Cross-Phase Reconciliation

Source: Operations Console scope brain dump 2026-04-27, Phase 11A operations
console plan, Phase 8.5 external integrations plan, `decision.md`, and
`AI_RECONCILE.md`.

### 7.58 / 7.61 Behavior-Validation Gates

7.58 and 7.61 remain behavior-validation gates. Phase 9 scalability decisions
define the architecture hooks for rollups, advisor answers, learned insights,
event delivery, and health/freshness telemetry. 7.58 locks the Primary Driver /
dollar-impact / History-Learn behavior contract before 11b advisor UX. 7.61
locks per-screen freshness behavior before Phase 8 vendor transports. These
audits may refine thresholds, labels, and explanation contracts, but they
should not require rebuilding the Phase 9 scalability architecture.

### Decision A - Three-surface Admin Structure, Shared Backend

Three UI surfaces sit over the same proxy `/v1/admin/*` API and same RLS /
authorization layer:

1. **F&F web console - Phase 11A** (`admin.forgeflow.app`). F&F internal
   super-admin/dev/support surface with cross-operator admin and health tools
   controlled by dynamic F&F roles.
2. **Operator web console - Phase 11B** (`{operator}.forgeflow.app`).
   Operator-facing org hierarchy management, users/roles/invitations,
   marketplace, billing setup, deep reports, scoped audit logs, exports, and
   debug visibility appropriate for the operator.
3. **Operator phone app.** Daily operations, light reporting, profile/MFA/
   notification settings, and in-the-moment workflows.

Same backend, same auth model, same RLS, same hierarchy data, and same audit
trail across all three surfaces.

### Decision B - Marketplace Pattern Generalized Across Vendor Lanes

The catalog + connection instance + onboarding wizard pattern covers all
vendor integrations. Phase 8 POS/labor inbound, Phase 8R reservations inbound,
Phase 8 MarginEdge/R365 inbound, and Phase 8.5 outbound finance all use the
same catalog and marketplace model.

### Vendor Integration Friction Guardrail

Scalability work must not make vendor integrations harder. The Phase 8 vendor
approach remains the same from the vendor/operator point of view: connect the
vendor account, receive data through the vendor's normal API/webhook/export
path, and map the returned vendor locations/resources to F&F locations inside
F&F.

The improved hierarchy, `integration_connections` scoping, vendor-location
mapping table, health UX, and marketplace UX are internal F&F improvements.
They should make integrations easier for F&F to operate, debug, and explain;
they must not require vendors to change their API behavior, add unusual setup
steps, or accept extra launch friction beyond normal credential/API/webhook
setup.

Where a scalability feature could add friction, the low-friction path wins for
launch. Examples:

- Vendor connection remains account-first, then F&F maps vendor locations to
  F&F locations.
- Connection scoping is enforced inside F&F permissions/RLS, not by asking the
  vendor to understand F&F's hierarchy.
- Webhook signing is verified where vendors provide signatures, but formal
  scheduled signing-key rotation is deferred unless compromised, leaked, or
  vendor-required.
- Vendor Integration Health explains freshness, sync failures, mapping gaps,
  and next actions in the F&F dev/admin UX without blocking normal vendor
  onboarding.
- Additional compliance/security controls should be hidden behind F&F's
  internal tooling wherever possible and surfaced to operators only when action
  is truly needed.

### Vendor Integration Guardrail Test - 2026-04-27

Result: PASS, with targeted implementation guardrails.

The scalability decisions are allowed to make F&F's backend, permissions,
health UX, auditability, and reporting more powerful. They are not allowed to
make Phase 8 vendor onboarding feel harder than the original vendor plan.

**AI / advisor / learned insights:** pass. AI consumes canonical facts,
rollups, health state, corpus, graph, and vector indexes after data lands.
It does not ask POS/labor/reservation/invoice vendors to change behavior.
Advisor learned insights are F&F review/corpus workflow, not a vendor setup
requirement.

**Hierarchy / tenant isolation / RLS:** pass. Org hierarchy,
`integration_connections` scope, vendor-location mapping, RLS, and historical
provenance are F&F-side structures. Vendors still expose their normal account,
restaurant/location/site IDs, webhooks, and exports. F&F maps those IDs into
its hierarchy internally.

**Rollups / freshness / event delivery:** pass. Rollup tables, freshness
labels, `event_outbox`, Pub/Sub delivery, late-data recomputation, and Rollup
Health are downstream of ingestion. They make F&F more honest and reliable
after vendor data arrives, without changing vendor integration setup.

**Security / privacy / audit:** pass with care. CMK, hash-chained audit logs,
RLS wrapper functions, service principals, audit retention, sensitive-data
redaction, and ZDR/privacy readiness are F&F security controls. They should be
implemented behind F&F infrastructure and contracts, not exposed as extra setup
steps for normal restaurant operators.

**PAN exclusion:** pass with guardrail. F&F must never store PAN. The low-
friction implementation is to block, redact, or quarantine the offending
field/record before Postgres and alert F&F, not fail an entire connector unless
the payload cannot be safely separated or the vendor is repeatedly violating
the contract.

**Webhook signing:** pass. F&F verifies vendor signatures where vendors provide
them. Formal scheduled signing-key rotation is deferred at launch so early
integrations are not slowed by vendor-specific rotation ceremonies.

**Multi-region / residency:** pass. Region metadata and tenant-to-region
routing are internal readiness hooks. Vendors should keep using the normal F&F
integration endpoint for the selected launch region unless F&F later
productizes region-specific endpoints.

**MarginEdge / R365 inbound finance:** pass. Launch scope is read-only
inbound data. F&F does not write back, approve bills, pay bills, post journals,
or mutate accounting records at launch, so the integration stays lower-risk.

**Rule:** if any future implementation detail conflicts with this test, choose
the path that preserves normal vendor API/webhook/export setup and moves the
complexity into F&F internal tooling, mapping, health UX, or runbooks.

### Scale Pressure-Test Guardrails - Locked 2026-04-27

The scalability direction is accepted, but it only survives real scale if the
implementation treats the following as non-negotiable engineering guardrails.

1. **Audit logs must not use one global write chain.** A single global
   `prev_row_hash -> row_hash` chain would serialize every audit write and
   become a bottleneck. Hash chains must be partitioned by practical scope,
   such as operator/day, table/day, or another bounded partition, then anchored
   to immutable storage.

2. **Rollup jobs must be shardable and observable.** `pg_cron` can schedule
   rollup work, but rollup processing must support bounded windows, leasing,
   retries, worker concurrency, and Rollup Health alerts so one large operator
   or bad source window does not stall every report.

3. **`event_outbox` must behave like a real durable queue.** Outbox rows need
   partitions, lease/claim fields, idempotency keys, retry state, dead-letter
   status, delivery timestamps, and retention cleanup. `NOTIFY` remains only a
   wake-up signal.

4. **Usage caps must be enforced from real-time counters/ledger checks.**
   Delayed rollups are allowed for dashboards, billing review, and history, but
   never as the primary source for deciding whether more usage is allowed.

5. **Vendor sync failures must be isolated.** Each vendor/operator/location
   connection needs its own sync cursor, rate-limit state, retry/backoff state,
   token-refresh state, and health status. One broken or noisy connector must
   not jam other operators, vendors, or locations.

6. **RLS and rollup query plans must be benchmarked with Tier-M synthetic
   data.** Leading indexes, `SET LOCAL`, and leakproof wrappers are required,
   but not enough by themselves. Before launch, representative large-operator
   queries must be EXPLAINed and timed for RLS, joins, partition pruning,
   rollups, admin/debug views, and advisor/reporting tools.

7. **Graph, vector, search, and AGE data must stay rebuildable projections.**
   Canonical source data lives in ordinary Postgres tables and source
   documents/chunks. AGE graphs, vector indexes, DiskANN/HNSW indexes, search
   indexes, and embeddings may be rebuilt, swapped, or pruned without losing
   source truth.

8. **F&F internal admin access needs blast-radius controls.** Internal access
   remains F&F-controlled, but broad access must be split by permission type:
   read, write, destructive, billing, privacy/audit, integration secret, and
   emergency/debug actions. Dangerous actions require clear UX confirmation and
   audit rows.

9. **Region-ready does not mean multi-region is solved.** `data_region`,
   `residency_region`, routing metadata, and migration discipline are required
   now, but future US/EU/UK/Canada expansion still requires explicit work for
   routing, backups, jobs, exports, audit anchors, vendor endpoints, and support
   tooling.

10. **Health UX must include actions, not only status.** Every red/yellow
    health item must name the affected F&F functionality and provide safe next
    actions such as retry, rebuild, quarantine, pause ingestion, remap vendor
    location, rotate secret, replay outbox, rebuild index, or escalate via
    runbook. A dashboard without safe actions is not considered complete.

### Performance At Scale Audit - Locked 2026-04-27

Detailed artifact:
`docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`.

Result: CONDITIONAL PASS. The architecture is scale-shaped, but it is not
scale-proven until the implementation satisfies the gates below with Tier-M
synthetic data and live-like worker/load tests.

**Shared Postgres + RLS:** conditional pass. RLS can scale only if every hot
operator-scoped query uses tenant-leading indexes, partition pruning, and the
leakproof wrapper functions. Cross-operator F&F admin views are the danger
path; they must use pagination, keyset scans, summaries, or explicit admin
read models instead of scanning all tenant data interactively. Gate: EXPLAIN
and time representative tenant queries, admin/debug queries, rollup reads, and
advisor/reporting tool queries before launch.

**High-volume table partitioning:** required. The following tables cannot
remain unbounded heap tables at scale: `audit_logs`, `auth_events_audit`,
`event_outbox`, `usage_logs`, `advisor_conversation_log`, vendor raw/import
tables, rollup tables, and high-volume fact tables. Gate: each has a partition
strategy, retention/archive path, tenant/time indexes, and tested drop/archive
procedure before production scale.

**Org hierarchy / `ltree`:** pass with limits. Depth 6 and GiST subtree
queries are fine. The performance risk is subtree reparenting, because moving a
large branch can update many paths and invalidate caches/rollups. Gate:
hierarchy reparenting is audited, bounded, preferably async for large
subtrees, and preserves historical hierarchy versions for reports.

**Vendor-location mapping:** pass with indexes. Mapping keeps integrations
simple, but sync performance fails if every imported row does slow mapping
lookups. Gate: vendor mappings have unique lookup indexes such as
`(operator_id, vendor_id, vendor_location_id)` / connection-aware variants, and
unmapped records are quarantined with health alerts instead of repeatedly
retrying expensive lookups.

**Vendor ingestion / backfill:** conditional pass. One noisy vendor or one
large historical import must not block others. Gate: every connection has
sync cursors, idempotency keys, batch limits, rate-limit state, retry/backoff,
token-refresh isolation, and priority separation between live incremental sync
and historical backfill.

**Rollups:** conditional pass. Physical rollup tables are correct, but
dimension explosion can create too many rows and hot updates can create
contention. Gate: rollup dimensions have cardinality budgets, deterministic
keys, bounded recomputation windows, partitioning by period/operator where
needed, worker leasing, retry/dead-letter behavior, and freshness lag alerts.

**Usage caps:** conditional pass. Enforcement must never scan raw logs or wait
for rollups. Gate: usage checks use atomic bucket counters or an equivalent
real-time ledger path keyed by billing owner, scoped org/location/staff/
workflow/usage class, with contention tests for high-volume AI/workflow usage.

**Audit logs:** conditional pass. Append-only audit is correct, but global
hash chaining is not. Gate: hash chains are partitioned by bounded scope,
write path is append-only, indexes cover operator/actor/target/time lookups,
JSON payload indexing is limited to known query needs, and partition
archive/drop is tested with hash-anchor verification.

**Advisor conversation logs:** conditional pass. The table can grow fast once
advisor UX is live. Gate: metadata columns are queryable without decrypting raw
payloads, raw encrypted question/recommendation content is kept off hot query
paths, table is partitioned by time/operator, and retention/legal-hold behavior
is tested.

**AI provider calls:** conditional pass. Anthropic/Voyage rate limits,
latency, and cost can become the bottleneck even if F&F's database is healthy.
Gate: proxy has per-operator/model/query-class concurrency limits, retry/
backoff, circuit breakers, graceful temporary-unavailable responses, prompt
cache TTL assertions, token/cost caps, and provider latency/error health.

**Embeddings / vector search:** conditional pass. HNSW is fine early, but
filtered vector search can degrade before the raw vector count looks scary.
Gate: vector indexes are scoped by corpus/provider/model/lang where needed,
filtered-search benchmarks are part of Vector Index Health, DiskANN shadow
builds run side-by-side before cutover, and canonical chunk text remains the
source of truth.

**Graph / AGE:** conditional pass. AGE is acceptable as a launch query
projection, not as source truth. Gate: graph queries go through a provider
interface, high-degree nodes and traversal latency are monitored, canonical
`graph_nodes` / `graph_edges` can rebuild projections, and red tripwires have
non-destructive rollover actions.

**Dev/Admin Health UX:** conditional pass. Health dashboards can become noisy
or useless at scale. Gate: alerts are deduplicated, scoped, severity-ranked,
actionable, and tied to runbooks/actions. Each alert must state affected
functionality, current impact, next action, owner, and whether customer-facing
data is stale or unsafe.

**F&F internal admin/debug views:** conditional pass. Cross-operator tooling is
a major performance risk because it can accidentally query everything. Gate:
all admin list/search pages use pagination/keyset pagination, explicit filters,
bounded date windows, export jobs for large result sets, and read models where
interactive joins would be expensive.

**Multi-region readiness:** conditional pass. Metadata does not make
multi-region cheap. Gate: all jobs, exports, backups, audit anchors, vendor
connection selection, and support tools accept a region context even while
launch runs in one selected region.

**Performance acceptance rule:** a scalability feature is not considered
implementation-complete until it has load tests or synthetic Tier-M proof for
the hot path it introduces, plus a Dev/Admin Health signal for when that hot
path degrades.

### Decision C - Phase 9 Schema Scope

Phase 9 schema lands:

- Multi-operator identity, global users, user/operator memberships, F&F
  internal dynamic roles, external identity references, and central permission
  evaluation.
- `org_units` ltree hierarchy, denormalized `locations.org_unit_path`, and
  `user_effective_locations` cache.
- Hierarchy provenance/versioning enough for historical rollup rebuilds.
- `vendor_integrations` with `zdr_status`; onboarding steps;
  `integration_connections` scoped by operator/org unit/location where
  appropriate; encrypted `integration_secrets`; vendor-location mapping table.
- Subscription/billing tables, `usage_caps` two-slot key, real-time usage
  ledger/counter enforcement, usage logs, overage rules, and reporting rollups.
- `advisor_conversation_log`.
- `advisor_learning_candidates` and approved-lesson-to-corpus promotion support
  if included in the Phase 11b advisor build path.
- `audit_logs` hash-chain columns and immutable anchor job state.
- `service_principals`.
- Privacy/compliance contact fields as general launch contact support; Quebec
  operator Privacy Officer enforcement only when Quebec market/location scope
  is active.
- Locale fields and `methodology_chunks.lang` as optional future-proofing; full
  fr-CA launch work only before Quebec launch.
- Q3 rollup tables and `aggregation_state`.
- `event_outbox` for durable internal events.
- Vector/graph index registry and health telemetry tables needed for Q19/Q20.
- Redaction/erasure ledger needed for Q21.

All operator-scoped tables are RLS-scoped from creation.

RLS performance discipline holds on three legs:

1. **Leading-column rule:** every fact-table index leads with `operator_id` or
   `(operator_id, location_id)`.
2. **Session injection rule:** proxy injects tenant/user context via
   transaction-scoped `SET LOCAL`, never session-scoped `SET`.
3. **Wrapper-function rule:** RLS policy bodies use STABLE LEAKPROOF wrapper
   functions, never inline `current_setting(...)::uuid` casts.

### Decision D - Billing Ownership Per Group Or Operator

`operator_subscriptions.billing_owner_org_unit_id` references any `org_unit`
row. Locations inherit effective subscription from the nearest billed ancestor.
Holding companies may bill at the root; multi-region operators may bill per
region; single-location operators bill at the operator root.

### Decision E - Phase 11A / 11B Extensions

- 11A.1 flat operator/location CRUD becomes hierarchy-aware org-unit CRUD.
- 11A.2 subscription tier management becomes billing-owner-aware.
- 11A.4 marketplace uses `vendor_integrations`,
  `integration_connections`, and vendor-location mapping.
- New Phase 11B operator web console exposes operator-facing hierarchy,
  integrations, billing, reporting, users/roles, and scoped audit/debug views.

### Decision F - Inbound Finance Restored, Outbound Finance Deferred

Outbound finance (GL writeback, AP execution, bank transaction fetch, journal
posting, payments, accounting-record mutation) remains deferred to Phase 8.5
post-launch.

Inbound invoice/vendor-bill ingestion from MarginEdge and R365 is restored to
Phase 8 launch scope as read-only ingestion of invoice, vendor-bill, AP,
inventory/export, and vendor-cost data where available. F&F may use this data
to improve COGS and Weekly P&L reporting, but does not approve bills, pay
bills, post journals, write back to the GL, or move money at launch.

Launch Weekly P&L must be labeled honestly. It may include sales, labor, and
connected COGS/vendor-cost data. It excludes overhead, rent, utilities,
insurance, depreciation, tax/accounting adjustments, and other GL-only
allocations until accounting GL integrations ship.

COGS and Weekly P&L surfaces show source coverage and freshness, such as "COGS
synced through April 25 from MarginEdge," "Vendor bills pending sync," or "COGS
unavailable until invoice integration is connected."

### F&F Dev/Admin Health UX Standard

Any internal tripwire, health alert, scale threshold, compliance gate, or
operational warning must be visible in the F&F dev/admin UX, not only in logs
or metrics dashboards.

Each health item shows status, affected tenant/operator/org unit/location/
corpus/vendor where applicable, signal that triggered the alert, affected F&F
functionality, user-visible risk, recommended next action, owner/team,
severity, first seen, last seen, last checked, runbook/docs links, and audit
trail of acknowledgement/override/resolution.

Alerts use plain operational language and answer:

1. What is happening?
2. Why does it matter?
3. What part of F&F can be affected?
4. What should we do next?

This standard applies across Graph Health, Vector Index Health, Vendor
Integration Health, RLS/Database Health, Audit Log Health, Billing/Usage
Health, Rollup Health, Event Bridge Health, Compliance Gate Health, and future
internal health panels. Logs and external metrics remain required, but they
are not enough by themselves; the F&F dev/admin UX is the canonical
F&F-internal view for platform health.

---

## AI Advisor Reconciliation

Purpose: ensure the AI in the phone app, operator web console, and F&F
dev/admin web console answers the right kind of question in the right fashion.

### Current Reality

The AI foundation exists, but the finished advisor does not. Existing
architecture has corpus storage, chunks, embeddings, BM25/vector retrieval,
Voyage/Anthropic abstractions, and Phase 11a infrastructure direction. The gap
is the answering layer: how the product decides which tools, facts, health
states, and evidence an answer is allowed to use.

### Required Architecture

F&F uses one shared advisor backend through the proxy. Every advisor request
carries a `surface` field:

- `phone_app`
- `operator_web`
- `ff_dev_web`

The `AdvisorAnswerRouter` uses `surface`, `query_class`, actor permissions,
operator/location/org scope, freshness state, and authoritative tool registry
to choose retrieval, SQL/reporting tools, health tools, model tier, response
depth, evidence detail, and allowed recommended actions.

Phone app answers are short, practical, and daily-operations oriented.
Operator web answers are report-aware, evidence-backed, and include relevant
locked plan/target/freshness provenance. F&F dev/admin web answers are
technical, health-aware, and include affected functionality, safe actions,
runbook pointers, and escalation state.

### Advisor Build Sequence

1. Define advisor request/response contract.
2. Add surface modes.
3. Expand query-class taxonomy.
4. Add `AdvisorAnswerRouter`.
5. Add tool registry.
6. Add operator reporting tools.
7. Add dev/admin health tools.
8. Add real `/v1/advisor/query` endpoint.
9. Add structured response format.
10. Add `advisor_conversation_log` table and writer.
11. Build phone app advisor UI.
12. Build operator web "ask this report" UI.
13. Build F&F dev/admin ask-health/debug UI.
14. Add advisor learned-insights candidate table.
15. Build F&F dev/admin learned-insights review/search/approval UX.
16. Add approved-lesson-to-corpus promotion workflow.

### AI Advisor Surface-Aware Answering - Locked

All advisor turns return structured metadata and write an
`advisor_conversation_log` row for deterministic replay. The advisor must know:

1. Who is asking?
2. Which surface they are asking from?
3. What kind of question this is?
4. Which facts/tools are authoritative?
5. How fresh and trustworthy the data is?

If it does not know those things, it should say what is missing instead of
guessing.

### Advisor Learned Insights - Locked

The model remains stateless and does not silently retain memory. F&F owns the
memory.

F&F persists AI-proposed learned insights as reviewable, operator-scoped
learning candidates. Candidates appear in the F&F dev/admin UX categorized by
topic, operator, org unit, location, source surface, query class, status,
confidence, sensitivity, evidence strength, created date, updated date, and
approver.

The product flow is:

```text
advisor conversation / report pattern / operator feedback / closed outcome
-> learning candidate generated
-> candidate appears in F&F dev/admin UX
-> categorized by topic
-> searchable by keyword and semantic meaning
-> F&F staff edits or amends the lesson
-> F&F staff approves, rejects, expires, or keeps pending
-> approved lesson is promoted into the advisor corpus
-> corpus pipeline chunks, embeds, indexes, and versions it
-> future advisor answers can retrieve it with citations/provenance
```

The Learned Insights searchbar uses hybrid search: BM25/text search for exact
terms, vector semantic search for meaning, filters for topic/operator/location/
status/confidence/source/sensitivity, and optional rerank when result sets are
large.

Suggested schema:

- `advisor_learning_candidates`
- optional `advisor_approved_lessons`, or direct promotion into
  `advisor_source_documents` / `advisor_source_chunks` through generated
  Markdown.

The safer pattern is:

```text
advisor_learning_candidates
-> approval
-> generated Markdown lesson document
-> existing corpus ingestion pipeline
-> advisor_source_documents / advisor_source_chunks
-> embeddings / BM25 / graph projection
```

Approved lessons keep provenance, evidence links, approver, version, scope, and
audit history. Operator-specific lessons remain scoped to that operator,
location, or org unit and never become global methodology unless explicitly
promoted by F&F.

Guardrails:

- Do not put raw sensitive personal information into approved lessons.
- Do not mix operator-specific lessons into global F&F methodology.
- Do not let the AI auto-approve lessons.
- Do not let learned lessons override locked facts such as TargetCycle,
  WeeklyPlanSnapshot, closed shifts, audit logs, rollups, billing records, or
  vendor source facts.
- If source conversations are redacted under Q21, the candidate keeps safe
  metadata and records that full replay is limited.

---

## Merge Accounting

`decision.md` has been accounted for in:

- usage caps (#6)
- Quebec future-market handling (#7-#10, #13, #17, #19, #28, #32)
- Firebase launch IdP (#15)
- post-launch SCIM trigger (#16)
- RBAC-first authorization (#17)
- shared-schema RLS with future Enterprise DB option (#18)
- single launch region with region-ready hooks (#19)
- audit retention (#20)
- RTO/RPO (#21)
- multi-LLM fallback (#22)
- dual-index embeddings (#23)
- predictive scheduling out-of-scope (#24)
- labor-cost rules (#25)
- multi-currency billing (#26)
- integration connection mapping (#27)
- accessibility (#28)
- webhook key rotation deferred (#29)
- AGE graph tripwire (#30)
- vector index health (#31)
- sensitive deletion/redaction (#32)
- NOTIFY/outbox/Pub/Sub (#33)
- rollup decisions Q3.2-Q3.10 (#34-#35)
- Q2 additions
- Q1 internal admin/dev access
- Decision F guardrails

`AI_RECONCILE.md` has been accounted for in the AI Advisor Reconciliation
section and in schema/health/Q21 references for advisor conversation logs,
surface-aware answering, health-aware dev/admin answers, learned insights,
hybrid search, approval workflow, corpus promotion, and deletion/redaction
rules.
