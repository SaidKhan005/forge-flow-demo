# Forge & Flow Tracker Archive

Archived from `PROJECT_TRACKER.md` on 2026-03-30 so the working tracker can stay concise.

Use this file for:
- completed prompt history
- detailed progress notes
- older implementation decisions that still matter later

The active roadmap, watchlist, and next prompts now live in [PROJECT_TRACKER.md](C:/Git%20Local%20Repos/forge_flow_demo/PROJECT_TRACKER.md).

## Completed Prompt History

| Prompt | Objective | Status | Notes |
| --- | --- | --- | --- |
| Prompt 0 | Software engineering plan | Done | Architecture and sequencing defined |
| Prompt 1 | Canonical domain foundation | Done | Foundation files added; no UI adoption yet |
| Prompt 2 | History from real tracked shift facts | Done | Runtime teaching summary now flows through stored closed-shift records |
| Prompt 3 | closeShift ingest path | Done | Canonical ingest path landed; one WTD follow-up remains |
| Prompt 3.1 | WTD source-fact plumbing fix | Done | WTD now carries stored closed-shift labor dollars with fallback preserved |
| Prompt 4 | Target consistency + OPZ cleanup | Done | Core target swaps landed across Schedule, Shift, and OPZ surfaces |
| Prompt 4.1 | OPZ source-of-truth + test stabilization | Done | ZoneStatusCard gauge centralized and Prompt 4 tests hardened |
| Prompt 4.2 | Baseline OPZ graph catch-up | Done | Attempted graph catch-up, but visual intent was clarified afterward |
| Prompt 4.3 | Baseline target-line visual correction | Done | Direction improved, but Chapter 9 to 12 intent was clarified again afterward |
| Prompt 4.4 | Baseline range + OPZ + recommended target visual correction | Done | Direction tightened, but runtime OPZ source mismatch remained |
| Prompt 4.5 | Baseline graph visual refinement | Done | Graph moved closer to intended composition |
| Prompt 4.6a | Baseline graph semantics truth pass | Done | Added truthful range graph model from existing historical source set |
| Prompt 4.6b | Baseline graph paint pass | Done | Widget now paints from the graph model, but OPZ source still diverged across tabs at that point |
| Prompt 4.7 | Historically derived OPZ unification | Done | Baseline, Shift, and the range graph now read the same OPZ source from selected historical records |
| Prompt 4.8 | Baseline graph visual polish | Done | Full-width graph and Shift-graph-style palette/emphasis landed without changing logic |
| Prompt 5 | Baseline Manager from history | Done | History-backed selection flow landed with persisted selection and runtime override path |
| Prompt 5.1 | Baseline manager screen contract fix | Done | Draft preview and zero-selection clear behavior are in place |
| Prompt 5.2 | Phase 5 continuation under propagation/debug guardrails | Done | Override visibility and cross-tab propagation now behave through the existing revision-based update path |
| Prompt 6 | Variance visual overhaul | Done | Variance readability, typography, and visual hierarchy improved without changing formulas or data sourcing |
| Prompt 6.1 | Baseline context + benchmark-range alignment | Done | Historical context metrics are separated, best/worst cards removed, and Baseline range-quality messaging now uses benchmark-range states |
| Prompt 6.2 | Baseline historical-range honesty pass | Done | Baseline graph now keeps historical outer anchors, renders the benchmark range inside that context, and displays total covers as a count |
| Prompt 7 | Learn layer | Done | Variance now includes a Learn tab that combines recurring history patterns with active Baseline benchmark truth |
| Prompt 7.1 | Learn teaching-copy alignment | Done | Learn copy now stays pinned to analyzer-owned text and existing Jim-aligned repo teaching sources |
| Prompt 7.11 | Shift dynamic truth alignment | Done | Shift hero-card emphasis and the bottom teaching line now follow the runtime active lever instead of static demo wiring |
| Prompt 7.12 | Shift readability + OPZ presentation polish | Done | Shift presentation now reads more clearly while preserving the runtime active-lever truth from Prompt 7.11 |
| Prompt 7.13 | Variance coaching layout cleanup | Done | Variance now uses cleaner coaching groupings, stronger readability, and a single consistent dollar-summary treatment |
| Prompt 7.14 | Learn depth from structured teaching sources | Done | Learn now teaches deeper recurring-leak and benchmark-pattern guidance from analyzers plus existing lever-card content |
| Prompt 7.15 | History + Learn premium surface alignment | Done | History drill-ins now use the grouped premium Variance table language and Learn/History styling now matches the upgraded This Week surface |
| Prompt 7.15a | History drill-in dollar-impact sign fix | Done | Fixed the annualized sign-formatting issue in the History detail `DOLLAR IMPACT` card |
| Prompt 7.5a | Persistence and scope alignment | Done | Restaurant scope, SQLite bootstrap/DAO/repo split, additive migration/backfill, raw import tracking, and compatibility delegation landed |
| Prompt 7.5a.1 | 7.5a correctness follow-up | Done | Fixed destructive v7 migration behavior and explicit restaurantId propagation through the close-shift domain path |
| Prompt 7.5a.2 | week_records scoped migration fix | Done | Upgraded pre-v7 week_records now rebuild into restaurant-scoped uniqueness with real upgrade-path coverage |
| Prompt 7.5a.3 | 7.5a contract completion cleanup | Done | DatabaseHelper now delegates and fixture replay raw import metadata carries true business-date semantics |
| Prompt 7.5a.4 | raw import businessDate fallback fix | Done | Fixture replay business_date now always resolves to a real ISO date string |
| Prompt 7.5b | Target-state alignment | Done | Active target profile persistence, immutable target-profile versions, locked historical target truth, and explicit WTD target injection landed |
| Prompt 7.5b.1 | historical target fallback removal | Done | WeekRecord, week rollups, and WeekData no longer drift back to current-global target state |
| Prompt 7.5b.2 | target provenance backfill + upgrade coverage | Done | Legacy historical shifts now receive compat target-profile provenance and pre-v8 upgrade coverage was added |
| Prompt 7.5b.3 | partial migration provenance repair | Done | Partially migrated rows now repair missing target-profile identity and upgrade-path tests rehydrate migrated model rows |
| Prompt 7.5c | Live-state and replay alignment | Done | Open/current-state persistence, Shift dashboard read models, and repository-backed Full Week state landed |
| Prompt 7.5c.1 | live current-week + open-row semantics fix | Done | Live WTD now resolves the persisted current week and open rows stay open in merged Full Week state |
| Prompt 7.5c.2 | final current-state contract cleanup | Done | Current-week fallback is deterministic and repository-backed, and open rows no longer show projected-only copy |

## Archived Progress Log

Use one line per meaningful session.

| Date | Phase | What changed | Result | Next |
| --- | --- | --- | --- | --- |
| 2026-03-28 | Planning | Software plan completed | Prompt order revised around integration foundation | Run Prompt 1 |
| 2026-03-28 | Phase 1 | Canonical domain foundation added | ClosedShiftInput, TargetSnapshot, ShiftFact, and builders landed without UI rewiring | Run Prompt 2 |
| 2026-03-28 | Phase 2 | History teaching pipeline rewired to stored closed shifts | Runtime History summary now reads pattern records through the data layer instead of seeded manual pattern records | Run Prompt 3 |
| 2026-03-28 | Phase 3 | closeShift ingest path landed | Raw closed-shift input now persists source facts, replaces projected slots, and can create completed week records | Run Prompt 3.1 |
| 2026-03-28 | Phase 3 | WTD source-fact plumbing completed | This Week now carries stored closed-shift labor dollars through WeekData instead of config-only fallback math | Run Prompt 4 |
| 2026-03-28 | Phase 4 | Target consistency and OPZ framework landed | Schedule and Shift now use baseline-derived targets; OPZ validation is centralized, but one gauge/test follow-up remains | Run Prompt 4.1 |
| 2026-03-28 | Phase 4 | OPZ source-of-truth and test stabilization completed | ZoneStatusCard gauge now routes through BaselineData and Prompt 4 tests now validate framework behavior with widget coverage | Run Prompt 5 |
| 2026-03-28 | Verification | Full test suite completed | 209 tests passed (23 Prompt 4/4.1 related, 186 pre-existing) | Run Prompt 5 |
| 2026-03-28 | Phase 4 | Baseline OPZ graph drift identified | BaselineTracker message/rows are OPZ-aware, but the graph still needed a hybrid model: 60-day low/high scale with OPZ band and selected target overlaid | Run Prompt 4.2 |
| 2026-03-28 | Phase 4 | Baseline graph visual intent clarified | The primary graph should be a 60-day low-to-high line with a recommended target marker; OPZ should support the recommendation rather than dominate the graph | Run Prompt 4.3 |
| 2026-03-28 | Phase 4 | Jim Taylor Chapters 9 to 12 re-read applied | The graph should show the full 60-day lived range, define the sustainable OPZ within that range, and place the recommended target in that context | Run Prompt 4.4 |
| 2026-03-28 | Phase 4 | Baseline graph semantics corrected | Added a truthful graph read-model using true historical CPLH min/max while keeping the existing derived target intact | Run Prompt 4.6b |
| 2026-03-28 | Phase 4 | Baseline graph paint pass landed | Baseline graph now renders from the read-model, but exposed that OPZ was still config-driven while baseline range was historical-derived | Run Prompt 4.7 |
| 2026-03-28 | Phase 4 | Historically derived OPZ unification completed | Baseline, Shift, and the graph now share the same OPZ source from selected historical records | Run Prompt 4.8 |
| 2026-03-28 | Phase 4 | Baseline graph visual polish completed | The graph now reads full-width and aligns more closely with the Shift graph palette while keeping the math frozen | Run Prompt 5 |
| 2026-03-28 | Phase 5 | Baseline manager selection flow landed | Dedicated manager page, stored-history candidate pool, persistence, and cross-tab rebuild path are in place; one UI-contract follow-up remained | Run Prompt 5.1 |
| 2026-03-29 | Planning | Pre-Phase-8 alignment gate formalized | Added explicit Phase 7.5 and created repo-wide refactor plan so live adapters remain transport-only work | Finish Prompt 5.1, then Phases 6, 7, and 7.5 |
| 2026-03-29 | Planning | Phase 7.5 and 8 implementation details expanded | Trackers now define onboarding, backfill, continuous sync, raw import tracking, restaurant scope, and live/finalization lanes at implementation level | Finish Prompt 5.1, then Phases 6, 7, 7.5a-c, and 8.1-8.3 |
| 2026-03-29 | Planning | Pre-7.5 debugging guardrails added for Phases 5-6 | Current feature work now has trusted-surface rules so mixed demo-backed UI does not create false negatives while logic is still being finished | Continue Prompt 5.2, then Phase 6 under the same guardrails |
| 2026-03-29 | Phase 5 | Baseline manager flow completed | Stored-history candidate selection, persisted manager override, override banner, and revision-based propagation now work end to end; only minor button-label casing cleanup remains | Run Prompt 6 |
| 2026-03-29 | Phase 6 | Variance visual overhaul completed | Variance is easier to scan with larger type, stronger blue/teal hierarchy, and cleaner table/layout treatment while formulas stayed frozen | Run Prompt 6.1 |
| 2026-03-30 | Phase 6 | Baseline context split and benchmark-range validation landed | Historical context is now separate from active selected star shifts, Baseline top cards use historical context, and Baseline range-quality messaging replaced live Shift-style OPZ wording; one honesty follow-up remained for graph anchors and total-cover formatting | Run Prompt 6.2 |
| 2026-03-30 | Phase 6 | Baseline historical-range honesty pass completed | Baseline graph now keeps the 60-day historical outer range visible, shows the active benchmark range inside it, and renders total covers as a count | Run Prompt 7 |
| 2026-03-30 | Phase 7 | Learn layer landed with one teaching-copy follow-up | Variance now has a Learn tab that combines recurring history patterns with Baseline benchmark truth, but one narrow pass remained to remove newly authored prose where fixed Jim-aligned copy already existed | Run Prompt 7.1 |
| 2026-03-30 | Phase 7 | Learn teaching-copy alignment completed | Learn now stays pinned to analyzer-owned text and existing lever-card teaching copy, with no new UI-authored teaching prose in the Learn surface | Pause for bug review, then start Prompt 7.11 |
| 2026-03-30 | Stabilization | Shift dynamic truth alignment completed | Shift now derives its active lever, hero card, and bottom teaching line from runtime lever truth; small delta-format cleanup can roll into 7.12 | Run Prompt 7.12 |
| 2026-03-30 | Stabilization | Shift readability and OPZ presentation polish completed | Shift header, OPZ teaching widget, metric cards, and labor-variance strip are easier to read while keeping the runtime truth from 7.11 intact | Run Prompt 7.13 |
| 2026-03-30 | Stabilization | Variance coaching layout cleanup completed | WTD now reads as Conditions / Execution / Outcomes, duplicate dollar wording was removed, and History readability improved | Run Prompt 7.14 |
| 2026-03-30 | Stabilization | Learn depth pass completed | Learn now teaches deeper recurring-leak and repeatable-win patterns from History summaries, Baseline truth, and existing lever-card content | Start Phase 7.5 alignment gate |
| 2026-03-30 | Stabilization | History + Learn premium alignment completed | History list, week-detail drill-ins, and Learn now visually match the upgraded This Week Variance system without changing the underlying logic | Fix one tiny History dollar-impact sign issue in 7.15a |
| 2026-03-30 | Stabilization | History drill-in dollar-impact sign fix completed | The annualized value in the History detail `DOLLAR IMPACT` card now follows the same sign-format convention as the weekly value | Resume Phase 7.5 alignment gate |
| 2026-03-30 | Phase 7.5a | Persistence and scope alignment completed in small follow-ups | Restaurant scope, repository/DAO boundaries, additive migrations, import tracking, compatibility delegation, and raw-import date accuracy now align with the 7.5a contract | Run Prompt 7.5b |
| 2026-03-30 | Phase 7.5b | Target-state alignment completed in small follow-ups | Active target profile persistence, immutable target-profile versions, locked historical target truth, provenance backfill, and explicit WTD target injection now align with the 7.5b contract | Run Prompt 7.5c |
| 2026-03-30 | Phase 7.5c | Live-state and replay alignment completed in small follow-ups | Shift, Zone status hero, and Variance Full Week now read repository-backed current state, and fixture replay can drive the aligned app end to end | Run Prompt 8.1 |
| 2026-03-30 | Audit | Post-7.5 readiness review reopened the Phase 8 gate | Structural alignment landed, but remaining closed-shift drift, `BaselineData` bridge authority, missing vendor docs, and missing runnable-env proof require a short `7.51` closeout first | Run Prompt 7.51a |
| 2026-03-30 | Audit | Post-7.51 verification refined the remaining blockers | `7.51a` verified complete, but `7.51b/c` remained only partially closed due compatibility-bridge scope, pending replay states, TBD vendor profiles, and missing runnable Flutter proof | Run Prompt 7.51d |
| 2026-03-30 | Audit | Final code-side Phase 8 readiness pass completed | Connector-config persistence is safe, visible restaurant identity is scope-backed, Shift empty-state is truthful, and the repo is structurally ready for connector work; the remaining gate work is vendor selection plus rerunning the current 28-file corpus from the checked-in manifest | Run Prompt 7.51e |
| 2026-03-30 | Planning | Shift from 7.51e to 7.52 cleanup and private-build prep | 7.51e is complete on the app side; while Phase 8 waits on vendor selection, the next useful work is repo cleanup, product identity clarification, and a private Barrio layer inside the same repo | Run Prompt 7.52 |
| 2026-03-30 | Planning | Expanded 7.52 into an execution sequence for Barrio shell and private content | 7.52 is now broken into tracker lock, product identity cleanup, private boundary creation, dual-build prep, Barrio shell work, structured interactive content, and a clean Phase 9 handoff | Run Prompt 7.52a |
| 2026-03-30 | Planning | 7.52a execution contract locked | Added `docs/phase_7_52_execution_plan.md` so the Barrio shell vision, pre-auth role-aware structure, structured-content rule, and handoff into 7.52b-h are frozen in one place | Run Prompt 7.52b |
| 2026-03-30 | Phase 7.52b | Public product identity cleanup completed | Forge & Flow now appears as the public product across package/module naming, README, Android, iOS, and Windows visible app strings; the app title no longer reads restaurant scope as product identity; stale `Forge & Flow Demo` restaurant scope rows now normalize back to the demo restaurant name | Run Prompt 7.52c |
| 2026-03-30 | Phase 7.52c | Legacy naming cleanup and private root file relocation completed | `meridian_data.dart` renamed to `legacy_fixture_data.dart`, `demo_data.dart` renamed to `fixture_seed_data.dart`, private Barrio root files (`Barrio Legado Business Plan.pdf`, `jim_taylor_labor_model_deep_dive.html`, `Logo.png`) moved into `docs/internal/barrio/` and `assets/internal/barrio/branding/`; all imports and doc references updated | Run Prompt 7.52d |

## Archived Decision Log

Record only decisions that affect future implementation.

| Date | Decision | Why it matters |
| --- | --- | --- |
| 2026-03-28 | Build canonical domain layer before more History/Learn work | Avoid rework when live POS/labor integrations arrive |
| 2026-03-28 | This Week stays decision-forward; History/Learn stay educator-forward | Keeps product roles clear |
| 2026-03-28 | For Prompts 5 to 7, let Claude lead visual direction while Codex focuses on logic, structure, and review | Keeps visual quality strong without loosening architectural discipline |
| 2026-03-29 | Treat data alignment and decoupling as a formal Phase 7.5 gate after feature completion and before live adapters | Keeps Phase 8 focused on connector transport instead of forcing a product-logic rewrite |
| 2026-03-29 | Execute Phase 7.5 and Phase 8 in narrower implementation blocks | Makes onboarding, backfill, and continuous sync trackable instead of leaving them implicit inside one large phase label |
| 2026-03-29 | Before Phase 7.5, use trusted-surface debugging instead of whole-UI debugging | Prevents mixed demo-backed screens from being mistaken for logic failures during Phase 5-6 work |
| 2026-03-29 | Keep Phase 8 focused on one restaurant/location and treat cross-device shared login and override sync as a later explicit phase | Prevents local SQLite assumptions from being mistaken for a full multi-device source of truth |
| 2026-03-29 | Keep Phase 9 auth fully app-managed, with onboarding-created credentials that mirror the restaurant's POS-style login setup | Keeps login simple for operators without depending on unsupported vendor credential flows |
| 2026-03-29 | Split future auth/login from future shared multi-device sync, and keep corporate structure as a later placeholder phase | Makes each future layer smaller, easier to reason about, and less likely to blur restaurant truth with cross-device or cross-store concerns |
| 2026-03-30 | Use 7.11 to 7.14 as a short stabilization sequence before Phase 7.5 | Keeps bug and polish work contained without diluting the larger alignment gate |
| 2026-03-30 | Keep Baseline naming frozen during stabilization | Avoids reopening a wide visible-label surface while focus stays on behavior and teaching accuracy |
| 2026-03-30 | Finish 7.5a fully before starting 7.5b | Avoid carrying persistence-contract debt into target-state alignment |
| 2026-03-30 | Finish 7.5b fully before starting 7.5c | Prevents mixed target-state fallback or weak migration coverage from leaking into live-state alignment |
| 2026-03-30 | Treat Phase 7.5 as the final internal state-boundary gate before connectors | Keeps Phase 8 focused on onboarding and adapter transport rather than another round of demo-truth unwinding |
| 2026-03-30 | Reopen the post-7.5 gate as `Phase 7.51` before starting live adapters | Keeps the tracker honest by closing the remaining historical-truth drift, `BaselineData` bridge authority, and vendor/gate artifact gaps before connector work begins |
| 2026-03-30 | Split the remaining post-7.51 work into `7.51d` and `7.51e` | Separates code-side bridge/pending-state cleanup from vendor-selection and final runnable gate proof so Phase 8 only starts once both are truly closed |
| 2026-03-30 | Track the live test corpus by the repo's actual *_test.dart file count and rerun it from checked-in tooling before marking the Phase 8 gate passed | Prevents stale test counts from making the gate docs say passed on an outdated corpus |
| 2026-03-30 | Keep Barrio as a private layer inside Forge & Flow rather than a forked repo | Lets future Forge & Flow updates and vendor integrations flow into the internal Barrio build without maintaining two divergent codebases |
| 2026-03-30 | Build the Barrio shell before Phase 9 auth, but keep real gating out of 7.52 | Lets the private internal app experience, information architecture, and visual system settle before login and permissions are added |
| 2026-03-30 | Treat handbook PDFs and source documents as source material rather than the final runtime UX | Keeps private content maintainable, interactive, searchable, and ready for later role-based access instead of locking the app into raw document viewers |
| 2026-03-30 | Prepare Forge & Flow and Barrio as separate build identities from one shared codebase | Supports different app names, icons, and private content without splitting the product into multiple repos |
| 2026-03-30 | Lock the Barrio shell and content contract in a dedicated 7.52 execution doc before renaming or build work begins | Keeps the cleanup/build sequence deterministic and prevents Phase 9 auth concerns from leaking into the shell/content phase |
