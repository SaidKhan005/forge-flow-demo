<!-- converted from forge_flow_engineering_timeline_personal.docx -->


Engineering Phases


| Engineering Phase | What Ships |
| --- | --- |
| Phase 7.55o | •  Shared surface primitives extracted across core tabs
•  Variance, Schedule, and Settings shell splits complete
•  Baseline Manager decomposition and candidate-truth cleanup |
| Phase 7.55j | •  Vendor endpoint checklist template complete
•  Vendor gap report closed
•  Pre-Phase 8 vendor readiness authority established |
| Phase 7.55R | •  Service-period runtime wiring closed
•  WeekDayOrder hardcoding removed
•  UTC metadata timestamp normalization
•  DataAlignmentAuditPanel service wrap and non-locked WTD business-date membership |
| Phase 7.56 | •  Reservation book signal on Shift screen (in-the-books covers)
•  App-owned data model reused later by Phase 8R |
| Phase 8 Gate | •  Vendor capability profiles (POS + Labor)
•  Source ownership matrix, replay readiness matrix, compatibility bridge scope
•  Phase 8 readiness signoff |
| Phase 11a | •  Founder methodology corpus converted to Markdown (Jim Taylor, Preston Lee, Vanessa SOPs)
•  Ingestion pipeline live; Apache AGE graph schema and pgvector embedding model locked
•  Full corpus ingested into graph + vector store
•  MCP tool layer (knowledge + operational tools) live with per-operator scoping via Phase 9 JWT |
| Phase 9.8 | •  Privacy policy rewritten for Firebase Auth and Supabase as data processors
•  ToS and DPAs drafted, reviewed, and executed
•  SOC2 inheritance documented
•  Legal signoff against live production stack |
| Phase 9 | •  Email and password authentication via Firebase Auth
•  Role-based permissions (seeded and custom roles)
•  Postgres Row-Level Security per-location isolation
•  Firebase Auth JWT integrated with Supabase (OIDC third-party auth) |
| Phase 8 | •  Live Toast POS transport
•  Live 7shifts Labor transport
•  Canonical operational facts populated from real vendor APIs replacing demo transport |
| Phase 8R | •  Live OpenTable reservation transport
•  Covers-in-the-books flows into Shift and Plan from the live platform |
| Phase 10a | •  Supabase Postgres shared-state tables with RLS per-operator scoping
•  Supabase Realtime subscription + polling fallback for cross-device sync
•  Last-write-wins ordering with append-only audit trail
•  Editable timezone and timing controls |
| Phase 10.5 | •  Additive daypart tab alongside whole-day Shift (no replacement)
•  Bucketing engine against real labor data
•  Service-period math on Toast guest counts and 7shifts clock data
•  Jim Taylor minutes-in-period split |
| Phase 9.5 | •  Real authenticated users replace demo users
•  Shared learning leaderboard on Supabase Postgres replaces per-device state
•  Learning points model per event type |
| Phase 11b | •  Stateless agent runtime with per-query context assembly and tool orchestration
•  Forge & Flow manager chat UI with provenance surfacing
•  Answer confidence tiers and refusal policy
•  Wired to live 11a tools and per-operator authentication |
| Phase 9.75 | •  Barrio V1.1 Team Board (Daily Board, Announcements, Focus, Recognition, Coaching Dashboard)
•  Schedule surfaces (My Shift pre-shift, post-shift, off-day, Personal Trends)
•  Push notification triggers (post-shift recap, pinned announcement, Focus change)
•  Badge catalog and coaching content served from 11a retrieval |
| Security audit | •  External RLS policy review
•  Firebase Auth configuration audit
•  Per-operator isolation integration tests
•  Connection-pooling vulnerability (CVE-2024-10976) check
•  Signoff against live production stack |
| Launch milestone | •  Vanessa’s restaurant cuts over to the production stack
•  Forge & Flow (manager tool) and Barrio V1.1 (staff companion) in production
•  Live POS, labor, and reservation data with secure multi-user access |
| Phase 11b Part 2 | •  Barrio manager chat surface
•  Barrio staff chat surface (after Phase 9.5 staff identity proven in production) |
| Phase 10b | •  Full offline sync with concurrency
•  Offline write queue with reconciliation
•  Multi-user conflict UI |
| Operations El Podio | •  Total sales leaderboard
•  PPA leaderboard
•  CPLH leaderboard (once Phase 8 attribution rules prove in production) |