<!-- converted from forge_flow_engineering_timeline.docx -->

Delivery Timeline

| Timeframe | What Ships | Engineering Phase |
| --- | --- | --- |
| Apr 1- May 2 2026 | Foundation closeout | •  Phase 7.55o extraction lane (shared surface primitives, shell splits) complete
•  Phase 7.55j vendor endpoint readiness complete
•  Phase 7.55R foundation closeout and Phase 7.56 reservation book signal ship
•  Phase 8 Gate vendor-readiness package signed off |
| May 4 -May 9 2026 | Advisor infrastructure + compliance groundwork | •  Phase 11a Part 1: founder methodology corpus converted to Markdown and ingested into Apache AGE graph + pgvector store
•  MCP tool layer (knowledge + operational tools) scaffolded and live against seeded data
•  Phase 9.8 compliance groundwork: privacy policy, ToS, DPAs drafted with legal counsel |
| May 11 -May 23 2026 | Backend, auth, and vendor connectors | •  Phase 9: authentication via Firebase Auth, role-based permissions, Postgres Row-Level Security per-location isolation
•  Phase 8 and 8R: live Toast POS, 7shifts Labor, and OpenTable reservation transport; canonical operational facts populated from real vendor APIs
•  Phase 10a: Supabase shared multi-device state with Realtime sync, polling fallback, and audit trail
•  Phase 9.5: El Podio learning identity on Postgres replacing demo users and per-device state |
| May 25 -May 30 2026 | Product surfaces | •  Phase 10.5: additive daypart view on the Shift surface with real-labor bucketing
•  Phase 11a Part 2: advisor infrastructure wired to live data with per-operator JWT scoping
•  Phase 11b: stateless agent runtime and Forge & Flow manager chat UI with provenance surfacing
•  Phase 9.75: Barrio V1.1 Team Board and Schedule surfaces scaffolded |
| June 1 -June 13 2026 | Integration and pre-launch hardening | •  Phase 11b and Phase 9.75 wired to live data; push triggers, read receipts, pinned announcements live
•  Phase 9.8 final compliance signoff (privacy policy, ToS, DPAs executed against live stack)
•  External security audit (RLS policy review, Firebase Auth config audit, per-operator isolation tests)
•  App store final submissions, beta testing cycles, operator staff training |
| June 15 -June 30 | Pilot Launch milestone | •  Pilot restaurant cuts over to the production stack
•  Forge & Flow (manager) and Barrio V1.1 (staff) live with real POS, labor, and reservation data
•  Secure multi-user access; agentic advisor serving manager chat |
| 2026 H2 and Beyond | Post-launch expansion | •  Phase 11b additional surfaces: Barrio manager chat and Barrio staff chat
•  Phase 10b: full offline sync with optimistic concurrency
•  Operations El Podio: operational leaderboards (sales, PPA, CPLH) once Phase 8 attribution matures |