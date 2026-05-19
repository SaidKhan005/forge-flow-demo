------------------------------------------------------------------------------
##local vs preview vs staging vs production
In Forge & Flow, think of it as source control, preview/staging runtime, then production runtime. The database is separate from the code and the Cloud Run service. A deploy changes what code is running; a mutation changes whichever database that running proxy is pointed at.

Local / Source Control

You work in a branch or worktree, like codex/preview-environment or claude/romantic-carson-bbf99f. Code changes happen locally first. Before anything is trusted, we run gates like:

powershell



flutter analyze
flutter test ...
flutter build web --release --target=lib\main_admin.dart ...



Then we commit, push to origin, and create or update a PR.

Database note: a PR does not change staging or production data by itself. Even migration files do nothing until a migration apply runbook or deploy step actually runs them against a database. Local code only mutates a real database if you run the app/proxy with real POSTGRES_URL secrets and submit write actions.

Preview / Staging Runtime

Staging is the live test environment. The shared staging admin stack uses:

text



Frontend: forge-flow-admin-console
Backend/proxy: forge-flow-staging-proxy



The repo deploy scripts are:

powershell



scripts\deploy_staging_proxy.ps1
scripts\deploy_admin_console.ps1 -AdminProxyBaseUri https://forge-flow-staging-proxy-rf7nosnoka-pd.a.run.app



The new preview stack we added uses separate Cloud Run services:

text



Frontend: forge-flow-preview-admin-console
Backend/proxy: forge-flow-preview-proxy



Preview deploy script:

powershell



scripts\deploy_preview_stack.ps1



Important frontend detail: the admin frontend has ADMIN_PROXY_BASE_URI compiled into the Flutter web bundle. So if the proxy URL changes, CORS changes, or we move between preview/staging/prod proxy URLs, the frontend usually needs a fresh deploy too.

Database note: the frontend never talks directly to Postgres. All real reads and writes go through the proxy/backend. The proxy decides which database it writes to based on the Secret Manager prefix passed at deploy time.

Current preview default:

powershell



-SecretPrefix forge-flow-staging-



That means preview has its own Cloud Run services, but currently shares the staging database. So read-only UX testing is safe for staging users, but write actions in preview still mutate staging data.

Fully isolated preview requires preview secrets:

text



forge-flow-preview-postgres-url
forge-flow-preview-postgres-admin-url



Then deploy preview with:

powershell



-SecretPrefix forge-flow-preview-



After that, preview writes affect only the preview database.

Production Runtime

Production should come after preview/staging is accepted, PR is merged, and production is explicitly unfrozen. In the tracker/runbooks, Production1 is gated, so we should not silently deploy there.

Production is the same shape as staging, but with production-specific project/service names, secrets, Firebase config, CORS origins, domains, migrations, and cutover gates.

The production flow is:

text



Merge accepted PR to master.
Confirm production unfreeze and release intent.
Create backup or release tag.
Apply required production migrations safely.
Deploy production proxy with production secrets and production CORS origins.
Deploy production frontend pointed at the production proxy.
Verify production Cloud Run traffic, health, browser smoke, and no unintended data writes.



Database note: production writes only happen when the production proxy is pointed at production POSTGRES_URL secrets and a mutation is submitted through the production app/proxy. Staging and preview deploys should never point at production secrets.

Repo anchors:


scripts/deploy_preview_stack.ps1

runbooks/preview_environment_runbook.md

scripts/deploy_staging_proxy.ps1

scripts/deploy_admin_console.ps1


Short version: local proves the code, preview proves branch runtime without touching shared staging traffic, staging proves the release candidate, and production ships only after explicit approval. Database mutations go wherever the deployed proxy’s POSTGRES_URL secret points.




------------------------------------------------------
##App integration:
How Integrations Will Work End-to-End — Plain English
After the spine-bridge sprint lands, here's what actually happens when an operator connects their POS, scheduler, and reservation system.

The Setup (one time, by the operator)
The operator opens the Forge & Flow web console at app.forgeflow.app on their laptop. They go to Vendor Connections. They see three categories: POS, Reservations, Scheduling — each with a list of supported vendors (17 total today: Toast, Square, Lightspeed, Oracle, Libro, OpenTable, QuickBooks Time, ADP, etc.).

They click Connect on their POS (let's say Toast). A vendor sign-in page opens. They log in to Toast, click "Authorize Forge & Flow," and get bounced back. Same for their reservation system and labor system. Three connections, three logins. Done.

That's the operator's job. Everything else happens server-side.

What Happens the Moment They Connect
The instant Toast confirms the OAuth grant, three things kick off:

A 60-day backfill starts. Forge & Flow asks Toast for every closed check from the last 60 days. Toast returns thousands of rows — checks, covers, sales totals, open/close timestamps. Each row gets parsed by the Toast adapter (one of the 17 we built), which produces a clean canonical-fact dictionary with the same shape regardless of vendor.
A poll cadence begins. Every 60 seconds, the integration sync worker (built in 8.spine-bridge.0) wakes up, looks at the connector_connection table, sees Toast is connected, and asks Toast: "Anything new since 5 minutes ago?" Toast returns deltas; the adapter parses them.
A webhook URL gets registered. For vendors that support real-time webhooks (Toast does; Square, Clover, most modern POSes do), Forge & Flow tells Toast "send all order events to this URL." From that point on, the moment a check closes in Toast, Toast pushes the event to Forge & Flow within seconds.
Same flow happens in parallel for the reservation vendor (Libro fires webhooks for new bookings) and the labor vendor (QuickBooks Time gets polled because it doesn't do webhooks).

What Happens to Each Vendor Event
Take one example: a $124.85 dinner check for 5 people closes at 9:32 PM in Toast. Here's the full path:

Step 1 — Toast pushes a webhook
Toast hits Forge & Flow's webhook endpoint with a signed payload. The framework's inbound webhook handler (already in place) does four things automatically before the adapter ever sees it:

Verifies the HMAC signature (rejects forgeries)
Checks the replay window (rejects events older than 24 hours)
Confirms the operator binding (Toast says "this is for restaurant_guid X" — F&F confirms operator A actually owns that)
Checks idempotency (if the same vendor_event_id already arrived 10 seconds ago via the poll loop, dedupe — don't double-count)
If any of those fail, the event lands in inbound_webhook_dead_letter for forensics and the canonical fact is never written.

Step 2 — The Toast adapter parses the payload
The adapter reads the Toast-specific fields (numberOfGuests, closedDate, totalAmount, gratuity, etc.) and produces a vendor-agnostic canonical fact:

{
  vendor_id: "toast",
  vendor_entity_id: "check_412901",
  vendor_modified_at: 2026-05-04T21:32:14Z,
  covers: 5,
  actual_sales: 124.85,
  opened_at: 2026-05-04T19:45:00Z,
  closed_at: 2026-05-04T21:32:14Z,
  business_date: 2026-05-04,
  covers_source: "direct",  // because Toast exposes covers; Square would say "forecast_fallback"
  raw_payload: { ... full Toast JSON ... }
}
It also runs the sanity hook — if the timestamps are nonsense (closed before opened, dated 6 months in the future, dated 2 years ago), the event drops into sanity_log and never becomes a fact. The operator's dashboard never gets polluted by garbage timestamps.

Step 3 — The Toast Postgres sink writes it
Built in 8.spine-bridge.1.OR/QBT/LB (one per trio vendor). The sink takes that canonical-fact dictionary, opens a tenant-scoped Postgres transaction (OperatorScopedRepository.withTenant(operator_A, location_X)), and INSERTS one row into cover_facts. The idempotency UNIQUE index means if Toast retries (which they do — webhooks can fire twice), the second INSERT is a no-op.

The watermark advances. The sync log gets a row. If this is the very first canonical fact for this operator, the demo-mode flip policy evaluates: connection status connected? Yes. First backfill committed? Yes. Records written ≥ 1? Yes. Flip demo_mode_state.is_demo = false. The operator's app now knows it has real data.

Step 4 — The aggregator runs
Built in 8.spine-bridge.2. Once a daypart finishes (e.g., the dinner service rolls past midnight or the next-day rollover hour), the aggregator wakes up. For (operator_A, location_X, business_date=2026-05-04, daypart=dinner), it walks Postgres and pulls:

Every cover_facts row for that daypart from Toast → sums covers (147), sums sales ($4,231.55)
Every labor_punches row from QuickBooks Time → sums FOH hours (38), BOH hours (24), labor dollars where present ($1,420.50)
Every reservation_facts row from Libro → sums party-sizes for in-the-books demand (89 covers reserved)
It then asks two important honesty questions:

Did the POS actually expose covers? If yes (Toast does) → covers source = direct. If no (Square doesn't) → covers source = forecast_fallback, pull covers from the forecast snapshot, mark the metric as "fallback" so the dashboard pill flags it.
Did the labor system actually expose dollar amounts? If yes → labor dollars source = vendor. If no → fall back to target_wage × hours, mark the metric as "fallback."
The aggregator emits a ClosedShiftInput — the same typed shape that ShiftService.closeShift() has been consuming since Phase 7.55. It's the interface boundary the existing app already speaks.

Step 5 — ShiftFactBuilder runs (existing pure code)
This is the part that's been there forever. ShiftFactBuilder.fromClosedShiftInput(input, targetSnapshot) is a pure function: input goes in, ShiftFact comes out, no I/O. It computes CPLH, SPLH, PPA, blended wage, primary lever id, variance points. It locks in the active target profile (target CPLH, target SPLH, target PPA, theoretical labor pct, etc.) at the moment of close so historical compares are always against the targets that were in force.

The builder doesn't change because of integrations. It just gets fed real vendor-derived inputs instead of demo-seeded inputs.

Step 6 — The ShiftRecord gets written to Postgres
The PostgresShiftRecordWriter (built in 8.spine-bridge.2) takes the ShiftFact, converts it to a ShiftRecord row, and writes to shift_records on operator-scoped Postgres. Replace-for-slot semantics: if Toast re-pushes corrected data 10 minutes later (a manager voided a check), re-aggregation overwrites the prior row. The dashboard always reflects the latest closed truth.

The row's source_system column carries "toast" (or "oracle_micros_simphony", or whichever POS) — not "demo" anymore.

Step 7 — Server emits a change signal
A Postgres NOTIFY fires on the shift_record_changed channel. Existing Phase 10a infrastructure picks it up: NOTIFY → Pub/Sub → WebSocket bridge. A short envelope containing {operator_id, location_id, business_date, daypart} rides down to every connected operator app.

What the Operator Sees on Their Phone
Step 8 — Mobile receives the signal
The operator app's WebSocket connection (already alive) sees the change envelope. Phase 10a infrastructure routes it to the right tenant.

Step 9 — Mobile pulls fresh ShiftRecord rows
Built in 8.spine-bridge.3. The mobile sync service hits the proxy: GET /v1/operators/A/locations/X/shift_records?modified_since=<cursor>. The proxy enforces RLS (operator A can only see operator A's rows), returns the new ShiftRecord, advances the cursor.

Step 10 — Mobile writes to local SQLite
The sync service writes the row to local SQLite via the existing SqliteShiftRecordRepository.replaceShiftForSlot() — the same write path the close-shift flow has used since Phase 7.55. The schema already accepts the row; only the source_system column reads "toast" instead of "demo".

It also pulls demo_mode_state rows in the same sweep — so the operator's "demo mode" banner clears automatically the moment the first backfill commits server-side. No app restart, no redeploy.

Step 11 — The dashboard refreshes
The sync service fires AppRuntimeInvalidationBus.notifyRuntimeWriteCompleted() — the same signal ShiftService.closeShift() has been firing since Phase 7.55. Every screen subscribed to it (Shift dashboard, Variance, History, Learn, Schedule baseline) re-reads from SQLite and renders.

The operator unlocks their phone, opens Forge & Flow, taps Shift. They see:

Real CPLH calculated from Toast covers + QuickBooks Time hours
Real PPA from Toast sales / Toast covers
Real labor dollars from QuickBooks Time (or wage × hours fallback if QBT didn't surface dollars)
The metric honesty pill is absent because every source is live. Clean dashboard.
If something IS on a fallback (e.g., they connected Square instead of Toast, and Square doesn't expose covers), there's ONE pill, top-left: "Square: covers via forecast". Tap it, see the detail sheet listing each source + state. Cards stay clean numbers; chrome stays minimal.

If something is genuinely unavailable (e.g., they haven't connected a labor system yet), the CPLH card renders MetricCardNotYetAvailable — a dash and "Not yet available" — never a phantom zero.

What the 60-Day Backfill Does to Benchmarks
The backfill writes 60 days of historical ShiftRecords. The benchmark/baseline manager picks the best comparable shifts from those 60 days. The TargetCycle uses them to recommend tighter or looser CPLH targets. The DemandForecastContext uses them to project tomorrow's covers. The SchedulePlan uses them to recommend FOH/BOH hours for next week.

The operator wakes up the next morning and the entire app feels lived-in. Two months of history. Real benchmarks. Real targets. Real plan recommendations. Not an empty shell asking them to type covers in by hand.

What Happens When Things Go Wrong
Vendor returns a malformed payload. Drops at the adapter boundary, logs to connector_sync_log, never writes a phantom canonical fact.
Vendor goes down. Poll loop sees the error, increments consecutive_refresh_failures. After 3, connection flips to error status, operator sees it in the Vendor Connections widget. Existing facts stay queryable.
Webhook signature is forged. Drops at the framework boundary, lands in inbound_webhook_dead_letter. Forensic record only; no operator impact.
Cloud Run sync worker crashes mid-backfill. Watermark per batch saved its place; restart resumes from the last successful cursor. No double-counting, no gaps.
Operator disconnects then reconnects. Watermark preserved. Reconnect picks up from where disconnect dropped. No data gap.
Operator never connects a POS. Demo mode persists. The dashboard works, banner stays visible, every metric still has honest state. They can use the app to plan future weeks even with zero live data.
What Stays the Same
A surprising amount, and that's the design point:

ShiftFactBuilder never changes. It's a pure function; it doesn't care if its ClosedShiftInput came from a demo seeder or from Toast.
ShiftService.closeShift() stays as the manual-close path for operators who want to override or backfill manually.
The mobile dashboard read path stays identical. ShiftService.getShiftDashboard() reads SQLite the same way it has since Phase 7.55.
Demo mode stays first-class post-launch. Same tables, same reads, same UI. The kDemoMode writer-side switch decides who's putting data in; everything downstream is identical.
The 17 vendor adapters built in Wave B don't change. The spine bridge plugs them into the runtime; the adapters themselves stay frozen at lifecycle = documented.
The Honest Sequencing
After spine-bridge lands and 8.integration-mobile-proof.v2 passes:

Phase 8 / 8R / 8.S close as engineering-complete. The framework + 17 adapters + spine + mobile sync are all done.
*.live.sandbox slices fire as each vendor's sandbox credentials arrive (rolling, never sprints). Promote each adapter from documented → sandbox_verified. Diff observed-vs-documented field shapes. Update the per-vendor doc pack if the vendor changed shape since the slice landed.
*.live.prod slices fire as each vendor's partnership clears (Toast Standard Tier, Oracle PIP, ADP Marketplace, etc.). Promote sandbox_verified → production_credentialed. Connect button goes live in the picker.
First operator connects in production. Auto-promotes that vendor to live_with_operators. The "1 operator connected" chip appears on the F&F Ops Console.
Phase 8.live closes when the last vendor reaches production_credentialed.
That last step is months away — partnership lead times are weeks-to-months and outside engineering control. But the engineering itself is complete the moment spine-bridge + mobile-proof.v2 land.

The One-Sentence Version
The operator clicks Connect once per vendor, and from that moment on, every check that closes in their POS, every punch in their scheduler, and every reservation in their reservation system flows through a vendor adapter, lands as a clean canonical fact on operator-scoped Postgres, gets aggregated into a daypart-level shift, builds a ShiftFact through the same pure function the demo path uses, syncs down to mobile SQLite, and renders on the operator's dashboard within seconds — with honest fallback when a vendor doesn't expose a field, and a "Not yet available" widget instead of a phantom zero when something is genuinely missing
--------------------------------------------------------------------------------------------------------------
##database migrations
Best practice is to separate code deploy from database migration apply, but make both explicit, repeatable, and hard to forget.

What These Pieces Mean
Migration
A SQL file that changes the database shape or rules. Example: users.firebase_uid uuid -> text. It is code for the database.

Deploy script
A script that ships application code somewhere, usually Cloud Run. Your scripts/deploy_staging_proxy.ps1 builds/deploys the proxy service and syncs secrets. It does not currently apply DB migrations.

Migration runner
A tool/script whose job is: “look at db/migrations/, figure out what has already been applied, apply the missing ones in order, record success.” This avoids manually picking files forever.

CI hook
A GitHub Actions / build check that runs before merge or deploy. It should not normally mutate production DBs. It should verify things like:

migration filenames are ordered
migrations are parseable
RLS lint passes
latest migration is recorded in docs/contract
no migration slot collisions
Release gate
The human or automated checklist that says: code is built, migrations applied, smoke tests passed, then traffic can move.

Best Practice Flow
For staging:

Merge code to master.
CI validates code and migrations.
Apply DB migrations to staging.
Deploy Cloud Run services/jobs.
Run smoke tests.
Confirm health/logs.
For production:

Apply migrations first if they are backward-compatible.
Deploy app code after schema is ready.
Smoke test.
Monitor logs.
Why Migrations Usually Go Before Code
If new code expects a column/type/table that is not live yet, the app can fail. For this MFA case, code expects firebase_uid to support real Firebase UID strings, so schema should be applied before relying on the new worker/proxy behavior.

What You Have Today
You have:

SQL migrations in db/migrations/
manual apply runbooks
deploy scripts for Cloud Run
lint/tests that check migration quality
You do not yet have:

a general migration runner that tracks applied files
an automatic deploy step that applies pending migrations before Cloud Run deploy
a CI gate that fails if a new migration exists but the deploy/migration contract was not updated
What I’d Recommend
Lean and safe version:

Add a schema_migrations table.
Add tool/postgres_apply_migrations.dart or scripts/apply_postgres_migrations.ps1.
Runner scans db/migrations/*.sql in filename order.
Runner skips already-applied files.
Runner applies each new file in a transaction.
Runner records filename, checksum, applied_at, applied_by.
CI checks that migrations are valid and sorted, but does not touch live DB.
Deploy runbook says:
run migration runner
then deploy proxy/job
then smoke test
I would not hide migration apply inside every app deploy yet. For launch, I’d make it a deliberate release step so we can see it clearly and avoid surprise live DB mutations. Later, once the runner is trusted, staging can auto-apply; production should still require approval.


--------------------------------------------------------------------
C:\Users\saidu\.forge_flow\secrets_inventory.md

This file does not store secret values. It stores a map of where secrets live, what they are for, and how to access them.
Verify whether ~/.forge_flow/secrets_inventory.md is an accurate current map of the Forge & Flow stack. Do not print secret values and do not mutate anything.

Check local off-repo files, Azure, GCP, Firebase, Cloud Run, Secret Manager, Key Vault, Postgres, storage buckets, backup locations, IAM/RBAC grants, alerts, diagnostic settings, domains/certs/load balancer resources, deployed jobs, CI/GitHub secrets or variables, and reference docs.

For each item, report:
- PRESENT AND ACCURATE
- MISSING FROM INVENTORY
- STALE / NEEDS UPDATE
- INTENTIONALLY ABSENT / TBD

Also call out any transient secret copies or backup files that still exist.
--------------------------------------------------------------------
#staging vs production
1. API / Proxy Domain
Right now staging uses:

https://staging-api.feflow.org
Production should have its own domain, likely something like:

https://api.feflow.org
The app talks to this through:

FORGE_FLOW_PROXY_BASE_URI
So staging build says:

FORGE_FLOW_PROXY_BASE_URI=https://staging-api.feflow.org
Production/App Store build should say:

FORGE_FLOW_PROXY_BASE_URI=https://api.feflow.org
2. Cloud Run Proxy
Staging currently has:

forge-flow-staging-proxy
Production needs its own Cloud Run service, for example:

forge-flow-production-proxy
Same code, separate deployment, separate secrets, separate database URL.

3. Firebase Project
Your current Firebase config points to:

forge-flow-staging
Production should have a separate Firebase project, for example:

forge-flow-production
That means production needs its own:

google-services.json        Android
GoogleService-Info.plist    iOS
firebase-config.js          Web/action pages
Firebase Web API key
Firebase Auth settings
Authorized domains
MFA/TOTP settings
Email action URLs
Right now your Android/iOS Firebase files are staging Firebase files, even though the app package names are production-like.

4. Database
Staging database and production database must be separate.

From your docs, staging/production look like:

staging:     forge-flow-staging-pg
production:  forge-flow-production1-pg
Each proxy environment needs its own:

POSTGRES_URL
POSTGRES_ADMIN_URL
The app never connects directly to Postgres. The proxy does.

5. DNS / HTTPS / Certs
You need separate DNS and certs:

staging-api.feflow.org  -> staging proxy edge
api.feflow.org          -> production proxy edge
Each needs HTTPS, load balancer or Cloud Run mapping, and certificate.

6. Secrets
Staging secrets and production secrets should be separate:

POSTGRES_URL
POSTGRES_ADMIN_URL
FIREBASE_PROJECT_ID
FIREBASE_WEB_API_KEY
SERVICE_PRINCIPAL_JWT_SECRET
ANTHROPIC_API_KEY
VOYAGE_API_KEY
Some third-party keys can technically be reused, but production should ideally have its own where possible.

7. App Identity
Current app IDs are:

com.forgeflow.app
com.forgeflow.barrio
Those are production-style IDs. If you want staging and production installed side-by-side on a phone, staging should have different IDs, like:

com.forgeflow.app.staging
com.forgeflow.barrio.staging
If you do not need side-by-side installs, you can keep one app ID and just be very careful which flavor/config you build.

Plainly: production needs its own API domain, proxy service, Firebase project, database, secrets, and mobile Firebase config. Staging is not copied into production; the same tested code is pointed at production’s own clean infrastructure.
------------------------------------------------------------------------------------------------------------
#Github

git status: What is happening?
git add: Choose what to save.
git commit: Save it locally.
git push: Send it to GitHub.
git fetch: Check what GitHub has.
git pull: Bring GitHub changes here.
git rebase: Put my work on top of newer work.
git merge: Combine branches.

----------------------------------------------------------------------------------------------------
#psotgres
The Big Idea
When something is sensitive or shared, the app should not decide it alone.

For example, the Flutter app should not be trusted to say:

"I am an admin."
"I can see this operator's data."
"This audit event happened."
"This workflow is allowed to run."
Instead, the app asks the proxy, and the proxy talks to Postgres.

Flutter app
  -> proxy
  -> Postgres
  -> verified answer
That is why Postgres is the shared filing cabinet.

Where The Postgres Code Lives
lib/infrastructure/persistence/postgres/
Plain English: this is the app/backend code that knows how to talk to Postgres safely.

It contains wrappers so the rest of the app does not throw raw SQL everywhere. The goal is: if code needs Postgres, it goes through approved patterns.

db/migrations/
Plain English: these are the database blueprints.

A migration says:

Create this table.
Add this column.
Add this index.
Enable this security policy.
Create this function.
Migrations are how the database structure changes over time in a controlled way.

The Managed Postgres Platform
Azure Database for PostgreSQL Flexible Server
Plain English: Microsoft hosts and manages the Postgres server.

Instead of you running a database manually on a VM, Azure handles the managed database service: server hosting, backups, upgrades, networking, scaling options, monitoring hooks, and availability features.

Canada Central
Plain English: the database is hosted in the Canada Central Azure region.

That matters for latency, data residency, compliance, and keeping services geographically close.

PostgreSQL 16
Plain English: this is the version of Postgres.

Like saying “iOS 17” or “Windows 11,” Postgres 16 tells you which database features and behavior are available.

Postgres Abstractions
These are code-layer concepts that make database access safer and more consistent.

PostgresExecutor
Plain English: “something that can run a Postgres query.”

It is an interface/abstraction. Code can ask it to run SQL without caring whether the query is running through a real database pool, a transaction, or a test fake.

What it does:

repository code
  -> asks PostgresExecutor to run SQL
  -> gets rows/results back
Why it exists: it keeps database execution consistent and testable.

PostgresTransaction
Plain English: a safe bundle of database work.

A transaction means several database actions either all succeed together or all fail together.

Example:

create user
add user role
write audit event
If step 3 fails, the transaction can roll back steps 1 and 2 so the database does not end up half-changed.

PostgresPool
Plain English: a shared checkout desk for database connections.

Opening a new database connection every time is expensive. A pool keeps reusable connections ready.

What it does:

request comes in
  -> borrow database connection
  -> run work
  -> return connection to pool
Why it matters: better performance, fewer connection problems.

TenantContext
Plain English: the identity label for the current database operation.

It says:

Which operator is this for?
Which location is this for?
Which user is acting?
Example:

operator_id = restaurant group A
location_id = downtown location
user_id = manager Sarah
Why it matters: Postgres can use this context to make sure Sarah only sees data she is allowed to see.

OperatorScopedRepository
Plain English: a database access class for operator-owned data.

A repository is code that knows how to read/write one kind of data. OperatorScopedRepository means: “this data belongs to an operator, so every query must run with an operator context.”

It helps prevent unsafe code like:

Give me all audit logs from every operator.
and pushes code toward:

Give me audit logs for this operator context.
Important Execution Patterns
runInTenantContext
Plain English: “run this database work as this operator/location/user.”

It starts a transaction and tells Postgres:

For this transaction, the current operator is X.
The current location is Y.
The current user is Z.
Then Postgres Row Level Security can use that context to filter rows.

Flow:

proxy verifies user
  -> builds TenantContext
  -> runInTenantContext
  -> set current operator/location/user inside Postgres
  -> run query
  -> RLS only allows matching rows
This is one of the main safety rails.

runAsSystem
Plain English: “run this as a trusted backend/system operation.”

Some work is not naturally tied to one normal user action. For example:

maintenance job
audit repair
background worker
admin-controlled system process
runAsSystem allows carefully scoped system work, usually with an explicit reason.

This should be used carefully because it has more power than normal tenant-scoped access.

Raw package:postgres
Plain English: this is the low-level Dart library that actually talks to Postgres.

The repo rule is: do not sprinkle raw database driver calls everywhere.

Instead:

raw package:postgres
  -> package adapter
  -> repository abstractions
  -> app/proxy code
Why: it keeps security, transactions, tenant context, and testing consistent.

Postgres Extensions
Postgres extensions are add-ons. They give the database extra powers beyond basic tables and SQL.

pgcrypto
Plain English: cryptography tools inside Postgres.

What it does here:

create hashes
support UUID helpers
build audit hash chains
Why it matters: audit logs can become tamper-evident. Each audit row can include a hash connected to prior rows.

pgvector
Plain English: lets Postgres store and search AI embeddings.

An embedding is a list of numbers that represents meaning. Similar meanings have similar vectors.

Used for advisor search:

question meaning
  -> compare against document chunk meanings
  -> find relevant docs
pg_diskann
Plain English: a more advanced vector-search indexing option.

It helps with fast approximate nearest-neighbor search when the vector dataset gets large.

Think of it as a future scaling path for AI retrieval.

AGE
Plain English: graph database features inside Postgres.

A normal table is good for rows. A graph is good for relationships.

Example graph questions:

This labor issue relates to which schedule pattern?
Which document explains this workflow?
Which metric caused this alert?
AGE helps query connected nodes and edges.

pg_cron
Plain English: scheduled jobs inside Postgres.

Like a database-native scheduler.

Example:

Every hour, refresh rollups.
Every day, run summary maintenance.
pg_partman
Plain English: partition management.

Partitioning means splitting a huge table into smaller chunks, often by date or tenant.

Example:

audit_logs_2026_04_29
audit_logs_2026_04_30
audit_logs_2026_05_01
Why it matters: large audit or event tables stay faster and easier to manage.

pg_stat_statements
Plain English: query performance tracking.

It lets you see which SQL queries are slow, frequent, expensive, or suspicious.

Useful for debugging:

Which query is hammering the database?
Which endpoint got slow?
Which index do we need?
ltree
Plain English: hierarchy paths.

Useful for organization structures like:

company
company.region
company.region.location
company.region.location.department
In Forge Flow, this supports operator/location/org-unit structures.

Why pgmq Is Mentioned
pgmq is a Postgres-based queue extension.

Plain English: it would let Postgres act more like a message queue.

But Azure's selected Postgres platform does not support it, so the repo uses a different pattern.

Instead of:

pgmq queue
the system uses:

SELECT ...
FOR UPDATE SKIP LOCKED
Plain English: workers safely claim available rows without fighting each other.

Example:

event_outbox has 100 undelivered events

worker A claims rows 1-10
worker B skips locked rows and claims 11-20
worker C skips locked rows and claims 21-30
That lets multiple workers process jobs safely.

The Real Request Flow
A typical secure request looks like this:

Flutter app sends request
  -> proxy verifies Firebase JWT
  -> proxy builds TenantContext
  -> repository calls runInTenantContext
  -> Postgres transaction starts
  -> tenant variables are set
  -> SQL runs
  -> RLS filters rows
  -> result returns to proxy
  -> proxy returns safe response to app
In plain English:

The app asks. The proxy checks identity. Postgres enforces tenant boundaries. The app only gets back what it is allowed to see.
---------------------------------------------------------------------------------------------------------------------------------------------------
#Search
The two “searches” are basically two different ways of asking the knowledge base questions.

**Vector search** is meaning-based search.

It asks: “What chunks of text are semantically similar to this question?”

Example:

> “What do I do if an appointment runs late?”

Vector search might find handbook chunks about schedule delays, client communication, buffer time, cancellations, or late arrivals, even if the exact words “appointment runs late” are not used.

It is good for:
- fuzzy questions
- natural language search
- finding relevant policy text
- advisor answers grounded in documents

**Graph search** is relationship-based search.

It asks: “What things are connected to this thing, and how?”

Example:

> “Show me everything connected to this operator’s location.”

Graph search might traverse:

> operator → location → staff → services → booking rules → pricing policy → affected clients

It is good for:
- relationship traversal
- dependency chains
- “what is connected to what?”
- multi-hop questions like “which locations are affected by this policy?”

So in plain English:

- **Vector search finds relevant text by meaning.**
- **Graph search follows structured relationships.**

---------------------------------------------------------------------------------------------------------------------------------------
#Proxy auth dns public -> private services

You’re building a secure front door for the app. The pieces are separate, but they form one chain:

User/app
  -> DNS
  -> Google load balancer / edge
  -> HTTPS certificate
  -> Cloud Armor / reCAPTCHA
  -> staging proxy
  -> authentication services
  -> database / ledger / cleanup
The key thing to know: each layer answers a different question.

DNS answers: “Where should this hostname go?”
HTTPS cert answers: “Can the browser/client trust this hostname?”
Proxy answers: “How should outside requests reach internal services?”
Auth answers: “Who is this user, and what are they allowed to do?”
Database/RLS/ledger answers: “What records can they access, and what happened?”

Right now, your current status sounds like this:

DNS: fixed
HTTP route: working
Load balancer: wired correctly
HTTPS cert: still catching up
App/auth tests: passing
Production: untouched
The remaining open item is HTTPS certificate activation.

DNS

DNS is just the address book. It does not run your app and does not secure your app.

When you set:

staging-api.feflow.org -> 34.54.204.29
you told the internet: “send traffic for this staging API hostname to this Google IP.”

Important DNS ideas:

A record points a hostname directly to an IP.

CNAME points a hostname to another hostname.

TTL controls how long other systems may cache the old answer.

DNS can be “correct” for you before it is correct everywhere, because different resolvers cache records differently.

HTTPS Certificate

The Google managed certificate proves that Google is allowed to serve HTTPS for:

staging-api.feflow.org
The cert cannot become active until Google can see that the domain points to the right Google infrastructure.

FAILED_NOT_VISIBLE usually means: “Google’s cert system cannot currently confirm that this hostname reaches the expected Google load balancer.”

In your case, that probably happened because the domain used to point to Porkbun parking. Since DNS is now fixed, waiting is reasonable. If it stays stuck, recreating or reattaching the cert is the next staging-only move.

Important: HTTPS is not the same as login. HTTPS encrypts the pipe. Authentication identifies the user.

Proxy

The proxy is the controlled entry point between public traffic and your backend.

It can do things like:

accept public API requests
check headers/tokens
normalize requests
forward to internal services
hide private infrastructure
enforce staging/prod separation
log attempts
protect sensitive endpoints
Think of the proxy as the public-facing receptionist and security desk for the backend.

A staging proxy lets you test real internet behavior without touching production.

Load Balancer / Edge

The load balancer is Google’s public traffic router.

It listens on ports:

80  = HTTP
443 = HTTPS
For HTTPS, the path needs several things to line up:

DNS hostname
  -> Google load balancer IP
  -> HTTPS frontend on port 443
  -> attached certificate
  -> backend/proxy service
Your note says that wiring is correct. That is good. The cert just has to finish becoming valid.

Cloud Armor / reCAPTCHA

Cloud Armor is protection at the edge before traffic reaches your app.

It can block or challenge traffic based on rules like:

bad IPs
suspicious request patterns
rate limits
geography
bot-like behavior
reCAPTCHA result
reCAPTCHA helps distinguish humans from automated abuse.

This matters especially for auth endpoints, because login, MFA, recovery codes, and account creation are common attack targets.

Authentication

Authentication is the “who are you?” layer.

In your system, it sounds like this includes:

Firebase auth
MFA begin
MFA confirm
recovery-code consume
Apple verification workflow
durable attempt ledger
MFA begin means starting a multi-factor login challenge.

MFA confirm means verifying the code/challenge response.

recovery-code consume means using a backup code and marking it as used so it cannot be reused.

durable attempt ledger means auth attempts are recorded reliably, usually for abuse prevention, auditing, lockouts, or debugging.

Apple verification likely checks Apple Sign-In or Apple-related auth/build configuration in GitHub Actions.

Database / RLS

Postgres stores app data.

RLS, or Row-Level Security, means the database itself helps enforce rules like:

this user can only see their own records
this admin can see records for their tenant
this anonymous user sees nothing sensitive
That is important because app-level checks can have bugs. RLS gives you another layer of defense.

Secrets

Secret Manager means sensitive values are not hardcoded in config files or source code.

Examples of secrets:

API keys
OAuth client secrets
database passwords
signing keys
Firebase credentials
Apple private keys
The staging proxy now references secrets from Secret Manager, which is the right direction.

The Most Important Operational Idea

When something fails, isolate which layer is failing.

For example:

DNS fails:
domain does not resolve to the expected IP

HTTP fails:
load balancer or backend route may be wrong

HTTPS fails:
certificate, port 443, SNI, or frontend config issue

Auth fails:
token, MFA, Firebase, Apple, session, or user-state issue

Database fails:
permissions, RLS policy, migration, connection, or cleanup issue
Right now, your problem is specifically in the HTTPS certificate layer, not DNS, not the proxy, and apparently not app auth.

What You Should Keep An Eye On

Make sure staging and production secrets are separate.

Make sure staging DNS cannot accidentally point at production.

Make sure production was not modified during staging maintenance.

Make sure HTTP either redirects to HTTPS or is only used intentionally for health checks.

Make sure recovery codes are one-time use.

Make sure auth attempts are logged without leaking secrets.

Make sure Cloud Armor rules do not block legitimate auth flows.

Make sure Apple/GitHub workflows use the same environment assumptions as staging.

The simple mental model: you are building a public, secure, testable path from staging-api.feflow.org to your backend auth system. DNS gets traffic there, HTTPS protects it, the proxy controls it, auth verifies users, and the database enforces what they can access.

You’re building a secure front door for the app. The pieces are separate, but they form one chain:

User/app
  -> DNS
  -> Google load balancer / edge
  -> HTTPS certificate
  -> Cloud Armor / reCAPTCHA
  -> staging proxy
  -> authentication services
  -> database / ledger / cleanup
The key thing to know: each layer answers a different question.

DNS answers: “Where should this hostname go?”
HTTPS cert answers: “Can the browser/client trust this hostname?”
Proxy answers: “How should outside requests reach internal services?”
Auth answers: “Who is this user, and what are they allowed to do?”
Database/RLS/ledger answers: “What records can they access, and what happened?”

Right now, your current status sounds like this:

DNS: fixed
HTTP route: working
Load balancer: wired correctly
HTTPS cert: still catching up
App/auth tests: passing
Production: untouched
The remaining open item is HTTPS certificate activation.

DNS

DNS is just the address book. It does not run your app and does not secure your app.

When you set:

staging-api.feflow.org -> 34.54.204.29
you told the internet: “send traffic for this staging API hostname to this Google IP.”

Important DNS ideas:

A record points a hostname directly to an IP.

CNAME points a hostname to another hostname.

TTL controls how long other systems may cache the old answer.

DNS can be “correct” for you before it is correct everywhere, because different resolvers cache records differently.

HTTPS Certificate

The Google managed certificate proves that Google is allowed to serve HTTPS for:

staging-api.feflow.org
The cert cannot become active until Google can see that the domain points to the right Google infrastructure.

FAILED_NOT_VISIBLE usually means: “Google’s cert system cannot currently confirm that this hostname reaches the expected Google load balancer.”

In your case, that probably happened because the domain used to point to Porkbun parking. Since DNS is now fixed, waiting is reasonable. If it stays stuck, recreating or reattaching the cert is the next staging-only move.

Important: HTTPS is not the same as login. HTTPS encrypts the pipe. Authentication identifies the user.

Proxy

The proxy is the controlled entry point between public traffic and your backend.

It can do things like:

accept public API requests
check headers/tokens
normalize requests
forward to internal services
hide private infrastructure
enforce staging/prod separation
log attempts
protect sensitive endpoints
Think of the proxy as the public-facing receptionist and security desk for the backend.

A staging proxy lets you test real internet behavior without touching production.

Load Balancer / Edge

The load balancer is Google’s public traffic router.

It listens on ports:

80  = HTTP
443 = HTTPS
For HTTPS, the path needs several things to line up:

DNS hostname
  -> Google load balancer IP
  -> HTTPS frontend on port 443
  -> attached certificate
  -> backend/proxy service
Your note says that wiring is correct. That is good. The cert just has to finish becoming valid.

Cloud Armor / reCAPTCHA

Cloud Armor is protection at the edge before traffic reaches your app.

It can block or challenge traffic based on rules like:

bad IPs
suspicious request patterns
rate limits
geography
bot-like behavior
reCAPTCHA result
reCAPTCHA helps distinguish humans from automated abuse.

This matters especially for auth endpoints, because login, MFA, recovery codes, and account creation are common attack targets.

Authentication

Authentication is the “who are you?” layer.

In your system, it sounds like this includes:

Firebase auth
MFA begin
MFA confirm
recovery-code consume
Apple verification workflow
durable attempt ledger
MFA begin means starting a multi-factor login challenge.

MFA confirm means verifying the code/challenge response.

recovery-code consume means using a backup code and marking it as used so it cannot be reused.

durable attempt ledger means auth attempts are recorded reliably, usually for abuse prevention, auditing, lockouts, or debugging.

Apple verification likely checks Apple Sign-In or Apple-related auth/build configuration in GitHub Actions.

Database / RLS

Postgres stores app data.

RLS, or Row-Level Security, means the database itself helps enforce rules like:

this user can only see their own records
this admin can see records for their tenant
this anonymous user sees nothing sensitive
That is important because app-level checks can have bugs. RLS gives you another layer of defense.

Secrets

Secret Manager means sensitive values are not hardcoded in config files or source code.

Examples of secrets:

API keys
OAuth client secrets
database passwords
signing keys
Firebase credentials
Apple private keys
The staging proxy now references secrets from Secret Manager, which is the right direction.

The Most Important Operational Idea

When something fails, isolate which layer is failing.

For example:

DNS fails:
domain does not resolve to the expected IP

HTTP fails:
load balancer or backend route may be wrong

HTTPS fails:
certificate, port 443, SNI, or frontend config issue

Auth fails:
token, MFA, Firebase, Apple, session, or user-state issue

Database fails:
permissions, RLS policy, migration, connection, or cleanup issue