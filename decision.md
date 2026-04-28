# Decision Notes

## Launch Requirements And Launch Decisions

### 6. usage_caps Caps Can Be Set

For 6 is this true? Yes. These caps can be set at multiple levels using the same usage_caps table.
In plain English, you can set limits like:
Holding/company-wide cap: “This whole billing owner can use at most 1,000,000 tokens/month.”
Brand/sub-org cap: “This brand under the holding company gets 250,000 tokens/month.”
Location cap: “This specific location gets 10,000 advisor calls/day.”
Staff cap: “This staff member can run 100 workflow actions/day.”
Workflow cap: “This workflow can only spend $50/day.”
Usage class cap: “AI advisor usage is capped separately from SMS usage.”
The important thing is that each cap says two things:
Who owns/pays for the cap?
Where does this cap apply?

So if Head Office pays for everything, but wants Brand A or Location 12 to have its own limits, it can do that.
The system then checks usage against the relevant caps before allowing more usage.

## Future Market Entry Requirements

### 10. Bill 96 / Quebec Future Consideration

Quebec / Law 25 / Bill 96 Future Market Entry — Locked 2026-04-27.

Quebec is not a near-term launch assumption. F&F is not launching in Quebec in the near future, so Quebec Law 25, Bill 96, Quebec Privacy Officer onboarding, Quebec cross-border PIAs, Canadian residency, and full fr-CA UI are future market-entry requirements, not general pre-launch gates.

F&F still keeps technical controls that are valuable for SOC 2, operator IP protection, auditability, security forensics, dispute reconstruction, and general privacy. Quebec-specific laws may be mapped to those controls later, but they are not the launch rationale unless Quebec market entry is activated.

Hard Promise #6 advisor_conversation_log remains required for deterministic replay and dispute reconstruction. Raw advisor question and recommendation access is controlled by a generic privacy/compliance officer permission key or restricted audit-privacy permission. Quebec Law 25 is only a future Quebec-market compliance mapping.

Anthropic + Voyage ZDR remains the preferred/required privacy and operator-IP protection posture if still desired by F&F. Phase 9.8 gates on general vendor privacy/security readiness unless Quebec market entry is activated. Quebec cross-border PIAs become required before offering the product in Quebec.

CMK remains required if still needed for security, SOC 2, or operator IP protection. Production2 should be provisioned in the selected launch region, not automatically Canada Central. Canadian residency is not a general launch gate.

F&F may keep a general privacy contact at launch. Operator-side Quebec Privacy Officer onboarding is required only when an operator has Quebec locations or F&F launches in Quebec.

Bill 96 French UI is required before Quebec launch, not as a general launch blocker. Optional future-proofing may remain if aligned with product architecture: users.locale, operators.default_locale, notification locale axis, methodology_chunks.lang, and string-catalog discipline. Sworn/legal French translation and full fr-CA UI are not required for non-Quebec launch.

SHA-256 hash-chained audit logs remain required for SOC 2, security forensics, dispute reconstruction, and future privacy compliance. Quebec Law 25 may be a future mapped benefit.

Q7 tenant isolation remains shared-schema RLS for launch with future DB-per-tenant Enterprise option. Residency is future/enterprise/market-entry driven, not Quebec-now.

Q8 multi-region remains single launch region now, with region-ready architecture for later. data_region / residency_region metadata and centralized tenant-to-region routing are future-proofing requirements. Customer-region selection can be hidden/defaulted at launch. Canada/Quebec, US, EU, and UK regions are added later when market entry, contract, latency, residency, or compliance requires them.

## Launch Identity And Authorization Decisions

### 15. Decision 15: Firebase Identity Platform for Launch; Enterprise SSO/SCIM Deferred Until Operator Demand

15 **Decision 15: Firebase Identity Platform for launch; enterprise SSO/SCIM deferred until operator demand.**

Plain version:

F&F will use **Firebase Identity Platform** for launch because it is enough for the expected restaurant operators: email/social login, mobile-friendly auth, MFA support, and fast implementation.

F&F will **not build WorkOS/Auth0/SCIM upfront**. Enterprise identity features like Okta/Microsoft Entra SSO, SCIM provisioning, multi-IdP federation, and IdP-side audit logs become future Enterprise-tier work, triggered by a real operator requirement or signed deal.

But the system must be designed so this is not a painful rewrite later:

- Keep F&F’s own user, role, operator, and location model.
- Treat Firebase UID as an external identity reference.
- Keep auth provider logic behind an abstraction.
- Add schema room for future enterprise identity metadata.
- Make manual invite/deactivate/role management strong for launch.

Short locked wording:

```text
Decision 15 Identity Provider — Locked 2026-04-27.
Firebase Identity Platform remains the launch IdP. Enterprise SSO/SCIM is deferred until real operator demand or signed enterprise deal. Launch scope covers Firebase-backed email/social login, admin MFA, invite/deactivate flows, and F&F-owned user/role/operator/location authorization tables. Firebase UID is stored as an external identity reference behind an AuthProvider abstraction so WorkOS/Auth0/SCIM can be added later for Enterprise tier without replacing the product authorization model.
```

### 17. Q6 Authorization Model

17) Start with RBAC + scoped grants, but design the schema so ReBAC/OpenFGA can be added later. Do not build Zanzibar/OpenFGA before launch.
Why:
For restaurants, simple roles plus operator/location/org-unit scope should cover most launch needs.
Full ReBAC adds complexity.
OpenFGA is powerful, but it becomes another core infrastructure system to run and understand.
Phase 12 workflow approval chains may need relationship logic later, but that can be added when workflow complexity is real.
What to do now:
Keep permission keys.
Add grants that can be scoped to operator/org unit/location/workflow.
Keep audit logs of permission changes.
Avoid hardcoding “owner/manager/staff” checks everywhere.
Use a central authorization service/function.
Leave room for future relationship tuples like:
user Jane is manager_of location A
user Mark is regional_director_of brand B
user Sarah is author_of document X

Locked wording:
Q6 Authorization Model — Locked 2026-04-27.
Launch authorization remains RBAC with permission keys and scoped grants, not Zanzibar/OpenFGA. Phase 9 schema must support operator/org-unit/location/workflow-scoped grants and central permission evaluation so Phase 11B can ship without ReBAC infrastructure. ReBAC/OpenFGA is deferred until workflow approval chains or enterprise org complexity prove RBAC insufficient. Do not hardcode role names as authorization logic; check permission keys through the authorization layer. Schema keeps room for future relationship tuples without replacing the launch RBAC model.

Short version: RBAC now, ReBAC later if workflows or enterprise hierarchy actually need it.

### 18. Q7 Tenant Isolation

18) Plain meaning:
F&F will launch with the current shared-schema RLS model because it is cheaper, simpler, and realistic for normal restaurant operators. But the architecture should not assume one database forever. Large Enterprise operators can later be moved to a dedicated database/server if scale, privacy, residency, backup/restore, or contract requirements justify it.
Locked wording:
Q7 Tenant Isolation — Locked 2026-04-27.
Launch tenant isolation remains shared-schema Postgres with strict RLS for standard operators. Schema-per-tenant and DB-per-tenant are not launch defaults. Enterprise operators may later receive a dedicated database/server when scale, privacy, residency, backup/restore, contract, or compliance requirements justify the added cost and operational complexity. Phase 9 schema and routing must avoid assuming one database forever, but launch implementation optimizes for shared-schema RLS.

Plain version:
F&F will launch with one shared Postgres system for normal restaurant operators. Each operator’s data is separated using strict RLS, meaning the database enforces: “this operator can only see its own data.” F&F will not build one schema per restaurant or one database per restaurant at launch, because that would make the product more expensive and harder to operate too early. But the system should be built so that later, if a very large Enterprise customer needs it, F&F can move that customer to a dedicated database/server. Shared database with strict RLS for launch. Dedicated database is a future Enterprise option, not the default.

### 19. Q8 Multi-Region Future-Proofing

19) Q8 Multi-Region Future-Proofing — Locked 2026-04-27.
Launch uses a single production region selected for the initial market; Quebec/Canada residency is not a launch gate because F&F is not launching in Quebec in the near term. Full multi-region, active-active replication, and region-specific database fleets are deferred. Phase 9 remains region-ready by adding data_region / residency_region metadata at operator/org_unit scope, centralizing tenant-to-region routing, and ensuring migrations, backups, exports, jobs, audit anchoring, and connection selection do not assume one region forever. Customer-region selection at signup can be hidden or defaulted at launch, then exposed when F&F enters Canada/Quebec, US, EU, or UK markets. Backups stay in the tenant’s assigned data_region once multiple regions exist; no silent cross-region customer-data replication except documented DR flows approved by policy/contract.

## Audit, DR, AI, And Compliance Decisions

### 20. Q9 Audit Log Retention

20) Q9 Use 7 years by default, with legal hold override, JSONL as canonical export, Parquet for analytics, and per-operator overrides for Enterprise/regulatory cases.
Why 7 years: 3 years is a little short for disputes, security investigations, tax/payroll-adjacent issues, and enterprise trust. 10 years is heavier than needed for normal restaurant operators. 7 years is a practical middle ground. Some regulated financial contexts use 3/6/7-year patterns, so allow longer contract-driven overrides where needed. See examples from SEC, FINRA, and 17 CFR § 210.2-06.
Locked wording:
Q9 Audit Log Retention — Locked 2026-04-27.
Tamper-evident audit logs retain for 7 years by default. Legal hold overrides retention expiry and prevents partition deletion/export purge until the hold is released. Per-operator retention overrides are allowed for Enterprise or regulated operators, with 7 years as the standard baseline and longer periods such as 10 years available by contract/compliance requirement. Canonical export format is JSONL for faithful replay and evidence production; Parquet is generated as a secondary analytics format for reporting and large-scale review. audit_logs are partitioned by time through pg_partman; retention enforcement must archive/seal eligible partitions, verify hash-chain anchors, and only then drop expired partitions that are not under legal hold. Retention jobs write audit rows for every archive, hold, purge, and failed purge attempt.

Plain version: keep audit logs 7 years, never delete anything under legal hold, export in JSONL first, use Parquet for analytics, and let big regulated customers pay for longer retention.

### 21. Q10 RTO / RPO Targets

21) Set realistic launch targets, then offer stronger targets for Enterprise later.
Locked wording:
Q10 RTO / RPO Targets — Locked 2026-04-27.
Launch DR target is Standard tier RTO <= 4 hours and RPO <= 15 minutes for core production data. Enterprise tier may contract for stronger targets, initially RTO <= 1 hour and RPO <= 5 minutes, subject to paid dedicated infrastructure and tested regional failover. No zero-data-loss or active-active availability promise at launch. DR exercises run semi-annually before Enterprise commitments and quarterly once Enterprise DR SLOs are sold. Failover region is selected based on the tenant's assigned data_region and residency constraints; until multi-region is active, launch DR relies on point-in-time restore, tested backups, infrastructure-as-code rebuild, and documented manual failover. Customer-facing SLO language must match tested recovery evidence, not aspirational architecture.

Plain version:
Normal launch promise: recover within 4 hours, lose at most 15 minutes of data.
Enterprise option later: recover within 1 hour, lose at most 5 minutes.
Do not promise zero downtime or zero data loss.
Test disaster recovery at least twice per year.
Move to quarterly tests once you sell Enterprise DR promises.
Only publish recovery promises that you have actually tested.

### 22. Q11 Multi-LLM Fallback

22)Anthropic primary at launch, with provider abstraction now; no automatic cross-model fallback until compliance and quality checks are ready.
Why:
If the advisor silently switches from Anthropic to OpenAI or Gemini, answers may change. Prompt format may behave differently. Cost may change. ZDR/vendor privacy contracts may not be equivalent. For a liability-sensitive advisor, silent fallback is risky.
Better model:
Anthropic is primary for launch.
Build the LLMProvider abstraction now.
Support a controlled fallback mode later.
Fallback provider must have signed ZDR/privacy terms first.
Fallback must pass advisor evals.
The log must record which model answered.
If no approved provider is available, fail gracefully instead of silently using an unapproved model.
Locked wording:
Q11 Multi-LLM Fallback — Locked 2026-04-27.
Launch advisor uses Anthropic as the primary LLM. Phase 11a must keep an LLMProvider abstraction and model_id/model_version logging, but automatic cross-provider fallback is disabled at launch unless the fallback provider has approved ZDR/privacy terms, cost ceilings, prompt-portability tests, and advisor quality evals. On Anthropic 5xx/rate-limit, the proxy may retry/backoff and then return a graceful temporary-unavailable response rather than silently switching models. OpenAI or Gemini fallback may be enabled later as an Enterprise/resilience feature only after compliance approval and deterministic advisor replay logging cover the provider used, prompt version, retrieved context, and model output.

Plain version: do not silently swap models at launch. Keep the code ready for it, but only enable fallback once privacy, cost, and answer-quality controls are real.

### 23. Q12 Dual-Index Re-Embedding Strategy

23) Use Voyage as primary, but design the schema for provider-versioned embeddings and allow a parallel fallback index. Do not compute every fallback embedding at launch unless needed.
Locked wording:
Q12 Dual-Index Re-Embedding Strategy — Locked 2026-04-27.
Voyage is the primary embedding provider at launch, but embeddings are provider-versioned from day one. methodology_chunks and other embedded corpus tables must not store a single anonymous vector as the permanent source of truth. Store canonical chunk text separately from embeddings, and store embeddings in a provider/model/version-aware table or columns keyed by embedding_provider, embedding_model, embedding_version, dimensions, lang, and chunk_id. Vector indexes are built per provider/model. OpenAI or Cohere fallback embeddings are generated through the existing EmbeddingProvider abstraction only when contract, pricing, ZDR, quality, or availability triggers require it. Re-embedding jobs must support side-by-side backfill, validation, query shadowing, and cutover without deleting the old Voyage index until the fallback index passes retrieval evals.


Plain version:
Use Voyage first.
Keep the original text chunks as the source of truth.
Store embeddings with provider/model/version labels.
Build vector indexes per provider.
If Voyage becomes a problem, backfill OpenAI/Cohere embeddings in parallel.
Test the new index before switching.
Do not make the database assume “there is only one embedding forever.”

### 25. FLSA Tip-Credit + Meal-Break Premium Pay

25)
F&F is not the payroll system of record and does not determine legal wage compliance. However, TargetCycle, WeeklyPlanSnapshot, and Variance may estimate labor cost, so Phase 10.5 / 10b need a versioned labor_cost_rules library selected by each location’s compensation profile. Rules may model tip-credit assumptions, tipped/non-tipped roles, minimum wage floors, paid/unpaid break assumptions, and meal-break premium estimates where applicable. Actual payroll/imported wage data remains the source of truth. Every calculated snapshot stores rule_version, location_id, role/wage inputs, assumptions used, and calculated output so historical variance can be reproduced. Do not hardcode wage-law math in UI or reports.
Plain version:

F&F should not become a payroll-law engine, but if it estimates labor cost, it must record which wage assumptions it used.

### 26. Q15 Multi-Currency Billing

26) Launch with CAD and USD only. Keep the billing schema multi-currency ready. Add EUR/GBP later when those markets open.
Locked wording:
Q15 Multi-Currency Billing — Locked 2026-04-27.
Launch billing supports CAD and USD only. EUR and GBP are deferred until EU/UK market entry or signed customer demand. Each operator/subscription has a billing_currency and reporting_currency; invoices, usage charges, credits, refunds, taxes, and revenue events store original currency amounts plus fx_rate_id and converted home-currency amounts for finance reporting. Price books are currency-specific rather than live-FX converted at invoice time, so plan prices are explicitly approved per currency. Stripe/Paddle integration must map each plan to provider price IDs per currency. fx_rates remains the canonical internal table for reporting and revenue-recognition conversion, not for silently changing customer invoice prices. Operator dashboards display in reporting_currency, with source-currency drilldown when different.

Plain version:
Bill launch customers in CAD or USD.
Do not support EUR/GBP until actually entering those markets.
Store the original invoice currency forever.
Also store the FX rate used for internal reporting.
Do not dynamically convert plan prices every invoice.
Create approved prices per currency.
Let operators choose or default their reporting currency.

### 27. Integration Connection Location Mapping

27)F&F should not assume:
one integration = one whole operator

and should not assume:
one integration = exactly one location

The better model is:
Connect the vendor account.
Then map vendor locations to F&F locations.

Example:
A restaurant group has 3 F&F locations:
Downtown
Airport
Mall

They connect Toast.
Toast sends back 3 restaurant IDs:
Toast location A
Toast location B
Toast location C

F&F needs a mapping table that says:
Toast location A = F&F Downtown
Toast location B = F&F Airport
Toast location C = F&F Mall

For OpenTable, same idea:
OpenTable Restaurant 123 = F&F Downtown
OpenTable Restaurant 456 = F&F Airport

Why this matters:
Sales from Downtown should not show up under Airport.
A manager for one location should not edit another location’s integration.
A group admin should be able to see all locations.
Some integrations may be shared across the whole operator.
Some integrations may belong only to one location.
So the answer is:
Add connection-level scoping, plus a location-mapping table.
Plain version of the decision:
F&F integrations are operator-owned, but each vendor connection can be mapped to one or more specific location

### 28. Q17 Accessibility Target

28)Q17 Accessibility Target — Locked 2026-04-27.
F&F operator console and phone app target WCAG 2.2 AA. Accessibility is a launch-quality requirement for Phase 11B operator console and mobile app, driven by AODA/EU EAA readiness, enterprise procurement, and inclusive product quality; Quebec Law 25 is not used as the primary accessibility rationale. Automated accessibility checks run in CI using axe-core or platform equivalent for key web flows. Each release requires accessibility smoke coverage for keyboard navigation, focus order, labels, contrast, forms, errors, and reduced-motion behavior. Manual screen-reader testing is required before launch and semi-annually after launch, plus whenever major navigation or workflow changes ship. Exceptions require a documented accessibility exemption with owner, reason, user impact, workaround, remediation date, and approval by product/compliance.
Plain version: build the app so disabled users can actually use it, test it automatically every release, do human screen-reader checks before launch and twice a year, and do not allow “we skipped accessibility” without a written exception.

## Dev/Admin Health And Scale Decisions

### 30. Q19 AGE Graph Scale Tripwire + Rebuildable Projection

30)Decision
F&F should use Apache AGE for launch, but AGE should not be the permanent source of truth.
The real graph data should live in normal Postgres tables:
graph_nodes
graph_edges

AGE should be treated like a rebuildable projection, similar to a search index.
That means:
Postgres canonical graph tables = real data
Apache AGE graph = fast query copy
Neo4j later = optional future copy if AGE gets too big

This is the right move because it keeps future options open without forcing Neo4j or another graph database into launch.
Why
AGE is convenient because it sits inside Postgres. But if the graph grows too large or traversal queries get slow, you do not want to be trapped.
If Postgres stores the original nodes and edges, then later you can safely:
split one big graph into smaller graphs
rebuild AGE projections
archive old graph relationships from active search
test Neo4j side-by-side
move only heavy graph queries to Neo4j
roll back if the new graph engine has issues
without losing the original graph data.
Locked Wording
Q19 AGE Graph Scale Tripwire + Rebuildable Projection — Locked 2026-04-27.
Apache AGE remains the launch graph query engine, but AGE is not the source of truth. Phase 9/11b.2 must store canonical graph nodes and edges in ordinary Postgres tables with stable IDs, operator/org_unit/corpus/domain/lang/version partition keys, edge_type, confidence/source metadata, active_from/active_until, and soft-delete/archive markers. AGE graphs are rebuildable projections generated from those canonical tables.

Phase 11b.2 adds graph health telemetry and a developer/admin Graph Health panel showing per-graph green/yellow/red status, edge count, vertex count, high-degree nodes, p95/p99 traversal latency, timeout rate, failed traversals, slowest graph queries, growth projection, last projection build, last benchmark, and recommended action.

Yellow tripwire fires at 3M active edges in any single AGE graph or sustained traversal latency regression. Red tripwire fires at 4M active edges, repeated traversal timeouts, or projected 90-day growth crossing 5M edges. Red may pause high-volume ingestion into that AGE projection unless overridden by admin reason and audit log.

Rollover actions must be non-destructive: repartition projections by operator/org_unit/corpus/domain/lang/version, prune/archive stale edges from active projections without deleting canonical data, rebuild AGE graphs from source tables, shadow-query a Neo4j/managed-graph projection, and cut query routing over only after validation. Postgres remains the canonical source of truth so fallback, rebuild, export, and rollback do not require data loss or risky one-way migrations. No Neo4j cutover is required at launch.

Risks To Avoid Now
Do not write important graph data only into AGE.
Do not let the app dual-write separately to Postgres and AGE in ways that can drift. The clean pattern is: write canonical Postgres rows first, then projection jobs build/update AGE.
Do not delete canonical graph rows just because you prune an AGE projection. Pruning should remove data from the active graph copy, not from the permanent record.
Do not hardcode queries directly to AGE everywhere. Put graph queries behind a GraphQueryProvider or similar interface so Neo4j can be added later.
Do not build Neo4j now. Just make it possible later.
Do not wait until 5M edges to care. Make the dev/admin Graph Health panel visible early.
Short version:
Build the real graph in Postgres, query it through AGE, monitor it visibly, and keep future graph engines replaceable.

### F&F Dev/Admin Health UX Standard

F&F Dev/Admin Health UX Standard — Locked 2026-04-27.
Any internal tripwire, health alert, scale threshold, compliance gate, or operational warning must be visible in the F&F dev/admin UX, not only in logs or metrics dashboards. Each health item must show: status (green/yellow/red), affected tenant/operator/org unit/location/corpus/vendor where applicable, what signal triggered the alert, what F&F functionality is affected, user-visible risk, recommended next action, owner/team, severity, first_seen_at, last_seen_at, last_checked_at, links to runbook/docs, and audit trail of acknowledgement/override/resolution.

Alerts must be written in plain operational language. They must answer: “What is happening?”, “Why does it matter?”, “What part of F&F can be affected?”, and “What should we do next?” For example, graph alerts must explain advisor graph traversal impact; vector alerts must explain advisor retrieval/search impact; webhook alerts must explain vendor-data freshness impact; RLS/database alerts must explain tenant isolation or query performance impact.

This standard applies across Graph Health, Vector Index Health, Vendor Integration Health, RLS/Database Health, Audit Log Health, Billing/Usage Health, Compliance Gate Health, and future internal health panels. Logs and external metrics remain required, but they are not enough by themselves; the F&F dev/admin UX is the canonical F&F-internal view for platform health.

### Q20 Vector Index Health + HNSW → DiskANN Switch Trigger

Q20, the UX should explain three things clearly:
What is happening
What F&F functionality is affected
What action to take
Plain English:
This alert watches the size and health of F&F’s vector search indexes.
Vector search powers things like:
advisor retrieval
methodology search
SOP/document search
finding relevant chunks for AI answers
semantic matching between a question and stored knowledge
possibly future recommendation/context features
If the vector index gets too large or slow, the advisor may:
retrieve worse context
answer more slowly
time out
miss relevant documents
cost more to operate
become harder to reindex safely
So the dev/admin UX should not just say:
HNSW index warning

It should say something like:
Advisor retrieval is approaching HNSW scale limits for the Core Methodology corpus.
Current index: 5.4M vectors.
Risk: slower advisor answers, missed relevant chunks, longer reindex windows.
Recommended action: build DiskANN shadow index and run recall/latency benchmark.

Use this updated Q20:
Q20 Vector Index Health + HNSW → DiskANN Switch Trigger — Locked 2026-04-27.
HNSW remains the default launch vector index for active corpora. DiskANN is installed but not the default until corpus scale or performance requires it. Treat ~10M vectors in a single searchable embedding space as the internal HNSW risk line, not a vendor hard limit.

Phase 11a/11b dev-admin UX must include a Vector Index Health panel. For each corpus/provider/model/lang scope, it shows active vectors, index type, index size, build status, last successful build, last benchmark, p50/p95/p99 retrieval latency, timeout rate, recall benchmark score, filtered-search behavior, 30/60/90-day growth projection, and current status: green/yellow/red.

Each alert must include a human-readable explanation of what F&F functionality is affected: advisor retrieval, methodology/SOP search, document chunk lookup, semantic recommendations, or any workflow depending on vector search. Each alert must include recommended actions: tune HNSW, partition corpus, build DiskANN shadow index, run recall/latency benchmark, start canary routing, pause high-volume ingestion, or roll back to HNSW.

Yellow tripwire fires at 5M active vectors in one embedding space, sustained vector-search latency regression, HNSW index build/reindex time exceeding the maintenance window, or index memory pressure. Yellow requires a visible UX warning and a DiskANN shadow-index readiness task.

Red tripwire fires at 8M active vectors, projected 90-day growth crossing 10M, repeated vector query timeouts, unacceptable recall/latency after HNSW tuning, or HNSW rebuilds becoming operationally unsafe. Red requires a DiskANN dual-index transition plan unless explicitly deferred with an audited admin reason.

The switch runbook is non-destructive: keep canonical chunk text and embeddings unchanged, build DiskANN side-by-side, keep HNSW serving production traffic, shadow-query DiskANN against real queries, compare recall@k, latency, cost, and filtered-search behavior, then canary routing from 5% → 25% → 50% → 100%. Keep HNSW available for rollback for at least 14 days after full cutover. vector_index_registry records active index type, provider/model/version, dimensions, corpus/lang scope, build status, benchmark results, affected product surfaces, recommended action, and cutover time.

Plain version:
Yes, add a dev/admin UX for it. The alert should say: “this vector index supports advisor/search retrieval, it is getting too big or slow, here is what could break, and here is the next action.”

### Q21 Sensitive Information Deletion / Redaction

Q21

Instead of “delete everything about a person,” make Q21 about:

**sensitive-data deletion/redaction**, while keeping required business records, audit history, and aggregates.

Use this revised wording:

```text
Q21 Sensitive Information Deletion / Redaction — Locked 2026-04-27.
F&F does not implement broad hard-delete of all subject-linked business history as a launch requirement. Privacy deletion focuses on sensitive personal information and unnecessary raw content while preserving legally/operationally required records, auditability, billing history, usage history, dispute evidence, and aggregate analytics.

Sensitive information includes direct identifiers and high-risk raw content such as SIN/SSN, government IDs, full dates of birth where not required, personal phone/email where no longer needed, home address, bank/payment details, health/accessibility notes, emergency contacts, uploaded identity documents, raw free-text containing personal details, and any PAN/card data that should never have been ingested.

Erasable/redactable surfaces: public/profile display fields, optional staff/customer personal fields, uploaded files, raw advisor question/recommendation payloads where retention basis does not apply, searchable personal references, graph/vector/search projections derived from sensitive content, and vendor-ingested raw fields not required for product function.

Preserved surfaces: audit logs, billing/tax records, usage records, operational history, variance/analytics aggregates, fraud/abuse/security records, legal-hold records, and advisor_conversation_log metadata needed for dispute reconstruction. Where raw sensitive text is not needed, redact or encrypt/restrict it rather than deleting the whole event.

Advisor replay rule: advisor_conversation_log keeps hashes, model_id, model_version, system_prompt_hash, retrieved_chunk_ids, retrieved_graph_paths, timestamps, query_class, token counts, latency, and other non-sensitive metadata needed for dispute reconstruction. Raw encrypted question/recommendation text may be retained only when there is a valid retention basis. If raw text is redacted or deleted, the redaction ledger must record that full deterministic replay is limited and why.

Advisor learned-insights rule: sensitive deletion/redaction applies to advisor_learning_candidates, approved lessons, generated Markdown lesson documents, promoted corpus chunks, embeddings, graph projections, and search indexes. Approved non-sensitive operational lessons may be retained after raw source text is redacted, but only if the lesson no longer contains sensitive personal information and keeps safe provenance. If a source conversation is redacted, linked learned insights must be reviewed, amended, expired, or re-promoted from sanitized text, and the redaction ledger must record the outcome.

Projection rule: AGE graphs, vector indexes, search indexes, and embeddings are not sources of truth. When sensitive source content is redacted or deleted, projections must be rebuilt, removed, or re-embedded from sanitized source data.

Backups are not rewritten in place. Sensitive-deletion actions write to an erasure/redaction ledger. If a backup is restored, the ledger must be replayed before the restored environment is used for production or customer access.

Every request records subject/scope, fields redacted/deleted, retention basis for anything preserved, projection rebuild status, vendor/ZDR status, reviewer, timestamp, and audit row. Dev/admin Compliance Health UX must show blocked sensitive fields, legal-hold conflicts, projection rebuild status, and required next action.
```

Plain version:

**F&F should delete or redact sensitive raw personal data, but not erase the business/audit record.**

So:

- Remove sensitive fields.
- Redact raw text if it contains sensitive info.
- Rebuild search/vector/graph copies.
- Keep audit, billing, usage, and dispute history.
- Keep aggregates.
- Keep records under legal hold.
- Log exactly what was removed and why.

### Q22 Postgres NOTIFY → Cloud Pub/Sub Scale Boundary

Q22) F&F will have internal events after data changes.
Example:
vendor data imported
dashboard needs refresh
usage counter needs update
notification needs sending
audit event needs forwarding
workflow step completed
Postgres NOTIFY can wake a worker up when something happened, but it is not a durable queue. If the listener is down or the queue backs up, relying on NOTIFY alone can lose or delay events.
So F&F should use NOTIFY as a signal only.
Answer
Q22 Postgres NOTIFY → Cloud Pub/Sub Scale Boundary — Locked 2026-04-27.
Phase 10a may use Postgres NOTIFY only as a lightweight wake-up signal for a durable event_outbox table. NOTIFY must never be the source of truth for events. Every event is first written to event_outbox in the same transaction as the business change; the NOTIFY payload contains only an outbox partition/key, not full event data. The bridge reads event_outbox, publishes to Cloud Pub/Sub, and marks rows delivered only after Pub/Sub accepts the message.

This is an internal reliability safeguard and must not create vendor integration friction. Vendors continue sending data through their normal APIs/webhooks; Q22 only controls F&F’s internal event delivery after data lands.

Yellow tripwire fires when bridge lag exceeds 60 seconds, undelivered outbox rows exceed 10,000, publish error rate exceeds 1%, or pg_notification_queue_usage() exceeds 0.10. Red tripwire fires when bridge lag exceeds 5 minutes, undelivered rows exceed 100,000, publish failures repeat, or pg_notification_queue_usage() exceeds 0.25.

Fallback when bridge backlogs: workers switch from NOTIFY wakeups to polling event_outbox by shard, worker count is increased, repeated failures move to dead-letter status, and non-critical event producers may be slowed if needed. Business writes remain safe because event_outbox is durable.

F&F dev/admin Health UX must include Event Bridge Health showing outbox lag, undelivered rows, retry/dead-letter count, publish error rate, notification queue usage, active workers, affected F&F functionality, and recommended action.

Reason
This protects F&F from losing internal events.
It does not affect vendor setup. It only makes F&F safer after vendor data is received.
Plain version:
NOTIFY = wake-up bell
event_outbox = reliable event record
Cloud Pub/Sub = internal delivery system

If the bell fails, F&F can still read the checklist and continue.

## Rollup Architecture Decisions

### Q3.2 Storage Form

Q3.2 Full Answer
Q3.2 is asking:
When F&F needs fast dashboard/reporting numbers, should those summaries live in real tables, materialized views, or both?
The answer should be:
Hybrid, but physical rollup tables are the standard for anything operator-facing.
In plain English: F&F should store important precomputed business summaries in real database tables, not rely mainly on materialized views.
Context
F&F has several layers of truth:
Raw vendor imports
↓
Canonical cleaned facts
↓
60-day benchmark
↓
TargetCycle
↓
WeeklyPlanSnapshot
↓
Closed shift / week history
↓
Variance, Learn, dashboards, rollups

The important rule is:
F&F should never let refreshed reporting logic quietly rewrite what the operator saw, planned, or closed.
So if a dashboard shows labor, sales, variance, usage, billing, regional performance, or historical results, those numbers should come from controlled physical tables with clear timestamps, scope, and freshness state.
The Decision
Use:
Physical rollup tables = default
Materialized views = internal helper only

Physical rollup tables should be used for:
operator dashboards
region / district / brand / location reporting
weekly variance summaries
usage caps
billing usage
History
Learn/advisor evidence summaries
anything compliance-sensitive
anything the operator might dispute later
Materialized views can still be used for:
internal admin analytics
temporary helper summaries
diagnostics
rebuild checks
non-authoritative engineering views
But they should not be the direct source of truth for operator-facing numbers.
How It Works
Example: a regional manager opens:
Region East → Last Week

F&F should not calculate that live from millions of raw sales/labor/reservation rows.
Instead:
Vendor data lands as raw imports.
F&F cleans it into canonical facts.
A scheduled aggregation job runs every 60 seconds or 5 minutes, depending on the metric.
That job updates physical rollup tables.
The dashboard reads the already-prepared rollup rows.
The UI shows freshness, like “updated 42 seconds ago.”
So the app is fast, explainable, and auditable.
Recommended Locked Wording
Q3.2 Storage form — Locked.

F&F uses a hybrid rollup strategy with physical rollup tables as the default storage form for operator-facing reporting, hierarchy rollups, usage/billing summaries, variance summaries, History, Learn, and compliance-sensitive metrics.

Usage caps are enforced from a real-time usage ledger/counter before allowing additional usage. Rollup tables summarize usage for dashboards, billing review, reporting, and historical analysis, but delayed rollups are not the primary real-time enforcement source.

Materialized views are allowed only for internal/admin helper analytics, rebuild diagnostics, and non-authoritative computation stages. They must not be directly exposed as operator-facing truth.

Rollup tables are written by the Q3.1 incremental pg_cron aggregation pipeline using aggregation_state watermarks. Rollup rows include operator_id, scoped_org_unit_id, optional location_id, grain, period, metric values, source watermark, rule_version, computed_at, and freshness/status fields. RLS applies directly to the physical rollup tables.

TargetCycle, WeeklyPlanSnapshot, closed Shift/Week history, Variance, and Learn remain snapshot/fact-based. Rollup refreshes may summarize them, but must never rewrite locked historical truth.

The F&F Dev UX must include Rollup Health showing freshness lag, failed refreshes, last processed sequence, affected dashboards/reports, owner, and recommended action.

Why This Is The Right Move
Physical rollup tables match F&F’s architecture because the product depends on stable operating truth.
Materialized views are convenient, but they are riskier for customer-facing reporting because refresh timing can make numbers change unexpectedly, security/RLS is harder to reason about, and freshness is less explicit unless you build extra tracking around it.
So the clean answer is:
Use real rollup tables for the business. Use materialized views only as engineering helpers.

### Q3.3–Q3.10 Rollup Architecture

Q3.3–Q3.10 Rollup architecture — Locked.


Q3.3 Rollup grain set — Locked.

F&F standardizes rollup grains across all operators: daypart, business_day, week, accounting_period, month, quarter, and year.

Operators may configure the calendar rules behind those grains, including business-day boundary, daypart definitions, week start day, fiscal year start, and accounting-period pattern. If an operator does not configure these values, F&F applies default restaurant-safe settings.

The grain set itself is not custom per operator. Only the calendar/daypart definitions behind the grains are configurable. This keeps reporting consistent across F&F while still supporting restaurant-specific calendars.

Hourly/minute-level summaries are excluded from the main web-reporting rollup architecture at launch and remain live-operational views only when needed.

Q3.4 Rollup dimensions — Locked.

F&F standardizes the restaurant reporting slices used across web reporting: operator, org hierarchy scope, location, time period, daypart, revenue center, sales category, ordering/service channel, labor role/group, and vendor/source where relevant.

Operators may configure their own names and mappings for dayparts, revenue centers, sales categories, channels, and labor roles. If they do not configure them, F&F uses vendor-imported defaults and safe fallback buckets.

Rollup dimensions are applied only where useful for the report family. Sales reports use sales dimensions, labor reports use labor dimensions, COGS reports use vendor/category dimensions, and usage/billing reports use usage dimensions.

Plan, Variance, History, and Learn store locked-truth references behind the scenes, including weekly_plan_snapshot_id, target_cycle_id, and rule_version, so F&F can later explain which plan and target the numbers were judged against.

The operator UX should expose simple restaurant reporting filters, not an overloaded BI-style filter system.

Q3.5 Late-arriving data — Locked.

Late-arriving or corrected vendor data updates reporting rollups through bounded recomputation. F&F identifies the affected operator, location/scope, source system, metric family, and business-date window, marks related rollups stale, and rebuilds only the affected grains.

Reporting totals may be corrected when source facts change. Locked business snapshots are never silently rewritten. TargetCycle, WeeklyPlanSnapshot, closed shift target snapshots, closed week history, advisor evidence, and audit records retain the version that was in force at the time unless an explicit correction workflow is used.

Every recomputation records source system, affected date range, prior watermark, new watermark, job_run_id, computed_at, and correction reason when available.

The F&F Dev UX shows late-arriving data events, stale rollups, affected reports, recompute status, and recommended action.

Q3.6 Rollup idempotency — Locked.

All F&F rollup jobs must be idempotent. Re-running the same aggregation window must produce the same final rollup row and must never double-count metrics.

Rollups use deterministic keys based on operator, scope/location, metric family, grain, period, and relevant dimensions. Jobs write with UPSERT/replace semantics rather than additive duplicate inserts.

Aggregation progress is tracked with aggregation_state watermarks and job_run_id metadata. Retries resume from the last safe watermark or recompute the affected bounded window and replace the target rows.

The F&F Dev UX shows duplicate-prevention state, last safe watermark, retry count, and whether a job is replaying, recomputing, or promoting new rollups.



Q3.7 Freshness UI — Locked.

All operator-facing reporting surfaces backed by rollups must expose freshness when the data may be delayed. The UX uses simple language such as “Updated just now,” “Updated 5 minutes ago,” or “Data delayed.”

Freshness is tracked by metric family and source where relevant, because sales, labor, reservations, COGS, and usage data may refresh at different times.

If a rollup is stale or failed, F&F serves the last known good result with a visible stale-data warning instead of fabricating fresh numbers or blocking the report.

The F&F Dev UX provides the detailed operational view: source system, metric family, last processed watermark, freshness lag, failed job, retry count, affected dashboards/reports, and recommended action.

Q3.8 Rollup rebuild strategy — Locked.

F&F rollups are rebuildable derived data, not source truth. Canonical facts, locked TargetCycles, WeeklyPlanSnapshots, closed shift/week records, and audit evidence remain the authority.

Rebuilds run by bounded scope: operator, org unit/location, metric family, date range, grain, and rule_version. Rebuilds write to a staging or versioned target first, validate totals and row counts, then promote atomically.

Rebuilds must not rewrite locked business snapshots. They may update reporting summaries that derive from those snapshots, but the original plan, target, closeout, and audit records remain preserved.

The F&F Dev UX shows rebuild status, affected reports, rule version, validation result, promotion state, rollback option, and recommended action.

Q3.9 Rollup error handling — Locked.

When a rollup job fails, F&F serves the last known good rollup where available and marks the affected report stale. The app must not fabricate fresh numbers, silently hide the failure, or block unrelated reports.

Rollup failures are scoped by operator, org unit/location, metric family, grain, date window, source system, job_run_id, and last safe watermark. Retries are idempotent and resume from the last safe checkpoint or bounded recomputation window.

Operator-facing UX uses simple stale-data language, such as “Data delayed. Last updated 14 minutes ago.” F&F Dev UX shows technical detail: failure reason, retry count, last safe watermark, affected dashboards/reports, recommended action, and escalation state.

Repeated failures create alerts. Bad source rows are quarantined when possible so one malformed vendor record does not stop unrelated rollups.

Q3.10 Rollup observability — Locked.

Rollup Health is part of the F&F Dev UX standard. It actively monitors rollup freshness, failed jobs, retry count, source-system lag, last processed watermark, row-count anomalies, rebuild status, promotion status, quarantined source records, and affected reports.

Every rollup alert must explain what is happening, which operator/scope is affected, which metric family is affected, which dashboards or advisor surfaces may show stale data, what the customer-facing impact is, and what action F&F should take.

Rollup observability does not replace operator-facing freshness labels. Operator UX stays simple; Dev UX carries the operational detail and safe actions such as retry, rebuild affected range, quarantine bad source row, or promote validated rebuild.

This is the F&F standard for reporting health.

## Q2 Additions

### Historical Hierarchy Provenance

Q2) Addition — Historical hierarchy provenance.

Hierarchy changes must not rewrite historical reporting truth. If a location moves from one org unit to another, future reports use the new hierarchy, but historical reports remain explainable under the hierarchy that was active at the time. Hierarchy changes are audited, and rollups/history preserve the relevant org_unit_path or hierarchy version used for the reporting period.

Historical rollup rebuilds must use the hierarchy version or org_unit_path that was active during the reporting period being rebuilt, not the current hierarchy at rebuild time.

### Permission Explainability

Q2) Addition — Permission explainability.

Because deny-wins inheritance can be confusing, the admin/operator UX must explain effective access. When a user has inherited access from a parent org unit but is blocked at a child org unit/location, the UI should show both: the inherited grant source and the explicit deny source.

### unit_type Is Structural, Not Branding

Q2 Addition — unit_type is structural, not branding.

unit_type describes where a node sits in the reporting/permission hierarchy. Brand, concept, or marketing identity must live in brand_name/display fields, not in unit_type.

### location_group Naming Discipline

Q2 Addition — location_group naming discipline.

Because location_group replaces brand, sub-region, and other, the admin UX must require a clear display name and discourage vague labels such as "Other," "Misc," or "Group 1." Reports and permissions should remain understandable to humans.

## Q1 FF Internal Admin/Dev Access

Q1 FF internal admin/dev access — Revised 2026-04-27.

Stripe-style operator-approved support sessions are replaced with an F&F-controlled internal admin/dev access model. F&F staff do not rely on permanent JWT bypass flags, and ordinary support/debug access does not require operator pre-approval, per-session reason codes, or short-lived support-session TTLs.

F&F staff authenticate into the internal F&F admin/dev dashboard with their own F&F user account, including MFA at dashboard login. The same universal dynamic role/permission system used for operators also controls F&F staff access, using the internal F&F role definitions locked elsewhere in Phase 9. F&F roles may have broader platform or cross-operator scope than operator roles.

Operators remain scoped to their own operator account. F&F internal roles may access operator backend/admin views across operators according to F&F-controlled permissions. This supports normal platform operations such as onboarding operators, creating/configuring locations, setting up users/roles, checking integration health, reviewing sync failures, inspecting reporting/rollup freshness, resolving billing/usage issues, running rebuild/retry tools, and reviewing audit/debug logs.

F&F internal access must still pass through the authorization layer and an explicit target_operator_id context. It must not rely on raw database bypass, hidden JWT flags, or unaudited direct access for normal support/dev operations. RLS remains the default tenant-isolation model for operator-facing access; F&F internal roles receive explicit cross-operator permissions through the same central permission system and every action is audited.

This is not operator impersonation by default. Normal F&F support/dev work happens through the internal admin/dev control plane, similar to Oracle-style vendor administration. True operator-user impersonation, if ever built, is a separate stricter mode and should be rare, visibly labeled, and separately audited.

Every internal admin action is audited with actor_user_id, target_operator_id, source surface, action, timestamp, and affected resource. Existing magic JWT bypass flags such as is_super_admin / is_ff_support are deprecated in favor of real dynamic roles and auditable permissions.

## Decision F Additions

### Inbound Finance Is Read-Only At Launch

Decision F Addition — inbound finance is read-only at launch.

MarginEdge and R365 launch scope is strictly read-only ingestion of invoice, vendor-bill, AP, inventory/export, and vendor-cost data where available. F&F may use this data to improve COGS and Weekly P&L reporting, but F&F does not approve bills, pay bills, post journal entries, modify accounting records, write back to the GL, or move money at launch.

### Weekly P&L Must Be Labeled Honestly

Decision F Addition — Weekly P&L must be labeled honestly.

Launch Weekly P&L may include sales, labor, and connected COGS/vendor-cost data from MarginEdge or R365. It must clearly show what is included and excluded. At launch, overhead, rent, utilities, insurance, depreciation, tax/accounting adjustments, and other GL-only allocations remain excluded until accounting GL integrations ship.

### COGS Freshness And Coverage Guardrail

Decision F Addition — COGS freshness and coverage guardrail.

Because invoice/vendor-bill data can arrive late or be incomplete, COGS and Weekly P&L surfaces must show source coverage and freshness. Example labels: "COGS synced through April 25 from MarginEdge," "Vendor bills pending sync," or "COGS unavailable until invoice integration is connected."

### No Outbound Finance Actions At Launch

Decision F Addition — no outbound finance actions at launch.

Any outbound finance capability, including GL writeback, journal posting, AP approval, payment execution, bank transaction fetch, or accounting-record mutation, remains outside launch scope and belongs to the later finance/accounting integration phase.

## Deferred / Reopen Later Decisions

### 16. Q5 SCIM Trigger

16 For your current direction, Q5 becomes:

**Decision Q5: SCIM/Enterprise SSO is post-launch, triggered by a real enterprise deal.**

In plain English:

F&F will **not** build WorkOS, SCIM, Okta/Microsoft Entra SSO, or multi-IdP federation before launch. Those features are useful for large enterprise restaurant groups, but they are likely overkill for the first normal restaurant operators.

The trigger is:

```text
Build enterprise SSO/SCIM when a signed enterprise operator requires it.
```

Until then, launch uses Firebase Identity Platform with strong manual account management:

- invite users
- deactivate users
- assign roles
- require MFA for admins/owners
- audit login/account changes
- support email/social login

Pricing implication:

- Standard/Pro tiers use Firebase login and manual user management.
- Enterprise tier can include SSO/SCIM as an add-on or requirement.
- SSO/SCIM does not need to block launch.

Locked wording:

```text
Q5 SCIM Trigger — Locked 2026-04-27.
Enterprise SSO/SCIM is deferred until post-launch and triggered by a signed enterprise operator requirement. No WorkOS/Auth0/SCIM implementation in Phase 9.7 or Phase 11B. Launch identity remains Firebase Identity Platform with F&F-owned user/role/operator/location authorization, admin MFA, invite/deactivate flows, and audit logging. Pricing defines SSO/SCIM as Enterprise-tier functionality or paid enterprise add-on. AuthProvider abstraction and external identity references remain required so WorkOS/Auth0/SCIM can be added later without replacing the authorization model.
```

### 24. Q13 Predictive Scheduling Compliance

24)Q13 Predictive Scheduling Compliance — Out of Scope for Launch / Reopen if Scheduling Becomes System-of-Record.
F&F does not create, publish, approve, or modify binding employee schedules. Any planning view in F&F is a proposed, non-binding, on-demand planning aid, not the employer’s fixed schedule or scheduling system of record. Predictive scheduling laws are therefore not in product scope for launch. F&F will not build jurisdiction-specific scheduling rule libraries, predictability-pay calculations, right-to-rest checks, employee-consent flows, or schedule-change premium events. If future roadmap work turns F&F into a native scheduler or system-of-record for employee schedules, this question must be reopened before design/build. Imported schedule data, if any, remains read-only/contextual unless explicitly promoted to scheduling system-of-record scope.

### Q18 Webhook Signing-Key Rotation

Q18 Webhook Signing-Key Rotation — Deferred / Not a Launch Requirement.
F&F verifies signed vendor webhooks where vendors provide signatures, stores webhook secrets securely, and logs/alerts on signature verification failures. Formal signing-key rotation workflows, active/previous/next secret states, dual-key rotation windows, and scheduled rotation cadence are deferred because they add integration friction and may depend on vendor-specific support flows. Rotation is handled manually if a secret is suspected compromised, leaked, or required by the vendor. Reopen after launch when webhook volume, vendor mix, SOC 2 readiness, or enterprise security requirements justify a standardized rotation process.
