# Barrio Staff Companion — Behavior Specification

## Context

This document defines the behavior, placement, and screen architecture for every feature in the Barrio Staff Companion. It was produced by walking through each feature in `barrio_staff_companion_build_plan.md` and locking in decisions with the product owner (April 2026).

**Identity:** Barrio Staff Companion is a staff-facing extension of Barrio. Forge & Flow remains manager/operator-first — no change. Staff become daily Barrio users, not daily Forge & Flow users. Phase 9 auth role model is unchanged.

---

## Barrio Home Hub — Destination Map

The Barrio home hub (orbital bubble layout) gains two new destinations. Existing destinations are unchanged.

| Bubble | Audience | Status |
|--------|----------|--------|
| **Team Board** (new) | allStaff, supervisor, manager, admin | New — 9.75a |
| **Schedule** (new) | allStaff, supervisor, manager, admin | New — 9.75b/8.xa |
| **El Podio** (existing) | allStaff, supervisor, manager, admin | Extended — badge collection added |
| **Forge & Flow** (existing) | manager, admin | Unchanged |
| **Company Handbook** (existing) | allStaff, supervisor, manager, admin | Unchanged |
| **AI Chat Bubble** (Phase 10) | allStaff, supervisor, manager, admin | Floating overlay on home — Phase 10 |

Role-dependent center bubble: staff see **Schedule** as primary, managers see **Forge & Flow** as primary.

---

## Team Board — Screen Architecture

**Destination:** Team Board bubble on Barrio home hub.
**Layout:** Horizontal tabs across the top.

### Staff Tabs

| Tab | Content |
|-----|---------|
| **Daily Board** | Rolling 3-day view, today pinned at top. Sections: 86'd items, specials, VIPs, service notes. Expected Volume section (plain language label + numbers on tap). Posts are structured, timestamped, attributed. |
| **Announcements** | Longer-form manager posts. Rolling 2-week auto-archive, pinned items override. Read tracking visible to both sides — staff sees "Read" checkmark, manager sees full read list. Push notification on new post. |
| **Focus** | Weekly Focus display. Shows the current week's focus area. One per week per restaurant. Also appears as persistent banner on My Shift pre-shift view. |
| **Recognition** | View received recognition. Manager triggers recognition from this tab via "+" button. Staff earns collectible badges (e.g., "Sales Star", "Team Player"). Push notification on receipt. Badge collection lives in El Podio. |

### Manager-Only Tabs (hidden from staff)

| Tab | Content |
|-----|---------|
| **Coaching Dashboard** | Support-first framing — sorted by biggest gap from target. "Who needs extra coaching this week" lens. No rankings or leaderboards. Aggregate view of staff performance + coaching trends. |

### Manager Controls (inline on existing tabs)

| Control | Location | Behavior |
|---------|----------|----------|
| **Briefing Composer** (H1) | Daily Board tab | Manager sees Edit/+ button that opens composer inline (bottom sheet). Structured template sections (86'd, Specials, VIPs, Service Notes). Auto-save drafts — WIP saves automatically, manager can return later. Read receipts visible to manager. |
| **Weekly Focus Setter** (H2) | Focus tab | Edit control at top of Focus tab. Shows F&F variance recommendation from previous closed week + custom text input option. |
| **Recognition Sender** (H3) | Recognition tab | "+" button to pick staff member and award a badge. Push notification sent to recipient. |

### Killed from Team Board

- **Team Readiness (H5)** — not needed.

---

## Schedule — Screen Architecture

**Destination:** Schedule bubble on Barrio home hub.
**Layout:** Vertical menu list (mirrors vendor app pattern — see Push Operations screenshot reference).

### Menu Items

```
[Staff Name]
[Restaurant] | Clock ID: XXXXX

My Shift              →  Pre-shift briefing, coaching, post-shift recap
Personal Trends       →  PPA trends, focus history, streaks, full transparency
My Schedule           →  Upcoming shifts, today highlighted, status badges
Daily Schedule        →  Team day view, grouped by daypart, role filter
Hours Worked          →  Rolling hours, clock-in/out log, OT indicator
Availability          →  Coming Soon (dimmed)
Shift Swaps           →  Coming Soon (dimmed)
Shift Releases        →  Coming Soon (dimmed)
Settings              →  Notification preferences
Log Out
```

Deferred items (Availability, Shift Swaps, Shift Releases) appear **dimmed + "Coming Soon"** until Phase 8.xa write paths ship.

---

## My Shift — Screen Architecture

**Access:** First menu item inside Schedule bubble.
**Layout:** Two sub-views — Pre-Shift and Post-Shift. Pre-Shift is default. Post-Shift populates after shift ends (push notification directs here).

### Pre-Shift View (scrollable, top to bottom)

| # | Section | Spec |
|---|---------|------|
| 1 | **Last Shift Takeaway** (F3) | Motivational one-liner from previous shift. Bridges shifts together. Upbeat tone regardless of outcome. |
| 2 | **Shift Header** (E1) | Shift time + role (no station — too vendor-specific early). Target context integrated: "Your goal tonight: beat $42 PPA (you averaged $39 last week)" — goal framing with context. Off-day: shows next shift preview + Weekly Focus + announcements. Demo data initially, vendor data after 8.xa. |
| 3 | **Busyness Signal** (E2) | Small card below header. Plain language label ("Busy Night") + covers detail on tap. Compares forecast vs historical average. |
| 4 | **Manager Note** (E4) | Urgent/highlighted items only from Daily Board. Staff checks full board in Team Board for routine details. Omitted if no board data (pre-9.75a). |
| 5 | **Weekly Focus Banner** (B3) | Persistent banner showing this week's focus area. Same content as Focus tab in Team Board. |
| 6 | **Focus Prompt** (E5) | Deterministic coaching nudge. Shows one concrete tactic + brief reason why. "Show me another" swap button for alternative tactic within same focus area. Deterministic fallback chain: graph edge rule -> template -> static content. |

### Post-Shift View (push notification triggers)

| # | Section | Spec |
|---|---------|------|
| 1 | **Post-Shift Summary** (F1) | Key metrics + daypart breakdown. PPA vs target, covers served, broken down by daypart when available. Restaurant-level initially; per-employee after 8.xb. Push notification: "Your shift recap is ready" directs here. |
| 2 | **Focus Outcome** (F2) | Separate card. Shows the focus area, the actual result, and a hit/close/missed verdict. |
| 3 | *(Takeaway carries forward to next pre-shift — not shown here)* | |

### Degradation Rules

| Condition | Behavior |
|-----------|----------|
| No vendor data (pre-8.xa) | Show demo shift data with `[DEMO]` badge |
| No per-employee attribution (pre-8.xb) | Show restaurant-level metrics labeled "Restaurant average" |
| No board data (pre-9.75a) | Omit manager daily note section |
| Graph uncurated | Fall through to template (level 3) or static content (level 4) |

---

## Personal Trends — Screen Architecture

**Access:** Second menu item inside Schedule bubble.
**Dependency:** Phase 8.xb (per-employee POS attribution).

| Section | Spec |
|---------|------|
| **Performance Trend Charts** (G1) | Rolling PPA, coached metric trends. Full transparency — staff sees raw numbers + comparison to restaurant averages. |
| **Focus History** (G2) | Coaching focus log with hit/miss pattern over time. |
| **Streak & Consistency** (G3) | Extends existing `BarrioStreakService`. |

---

## El Podio — Extended

**Existing destination** on Barrio home hub. Extended to house the **badge collection** from Recognition (H3). Staff sees all earned badges over time — the persistent home for recognition.

---

## Notifications (9.75c) — Cross-Cutting

**Not a screen — infrastructure layer.**

| Notification | Trigger | Timing |
|-------------|---------|--------|
| Pre-shift briefing | Scheduled shift start | **60 min before** (fixed) |
| New announcement | Manager posts announcement | Immediate |
| Recognition received | Manager awards badge | Immediate |
| Post-shift recap ready | Shift end time passes | After shift ends |
| Schedule change | Shift add/change/cancel | Immediate (wired when 8.xa ships) |

- **No DND system** — staff mutes specific notification types via per-user preferences
- Per-user notification preferences stored in Firestore
- Settings accessible from Schedule bubble menu -> Settings
- `firebase_messaging` + `flutter_local_notifications`

---

## Staff Lifecycle Admin (9.75d)

**Access:** Shared restaurant-level settings area accessible from both Barrio and Forge & Flow.
**Audience:** Admin role only.

| Workflow | Spec |
|----------|------|
| Onboarding | Admin creates account, assigns role, invites to restaurant. **Multi-add form** for seasonal hiring (add sequentially, submit batch). |
| Termination | Deactivate account, revoke access, archive data. |
| Role change | Promote/demote with permission key cascade. |
| Password reset | Standard Firebase credential reset. |
| Staff roster | View with active/deactivated/pending status. |
| Audit trail | Log of all account changes. |

---

## Phase 10 — AI Coaching Agent

**Access:** Floating chat bubble on Barrio home screen (not global).
**Dependency:** 9.75b shipped and proven useful.

| Spec | Detail |
|------|--------|
| Input | **Guided prompts shown by default + free typing available**. Suggested prompts like "Why was my PPA low?", staff can also type freely. |
| Audience | **Staff + manager**. Staff AI = coaching. Manager AI = operational (P&L summary, variance explanation, briefing drafts). |
| Source | Graph-grounded answers citing knowledge base (Jim Taylor, company handbook). |
| Infra | Cloud Function proxy (API key never on device). Rate limiting, cost management, response caching. |
| Fallback | If budget exceeded or API unavailable, fall back to deterministic coaching (9.75b). |

---

## Weekly Focus — Data Flow Detail

The Weekly Focus (B3/H2) has a unique integration point between Forge & Flow and Barrio:

1. **Source:** F&F's previous closed-week variance data generates a recommendation (e.g., "PPA was 2% below target last week" -> suggests sales focus)
2. **Manager action:** Manager opens Focus tab in Team Board, sees the recommendation, can accept it or type a custom focus
3. **Staff visibility:** Focus appears in Team Board Focus tab AND as persistent banner on My Shift pre-shift view
4. **Coaching alignment:** Deterministic coaching engine (E5) aligns focus prompt tactics to the active Weekly Focus
5. **Cadence:** One focus per week per restaurant

---

## Recognition — Badge System Detail

1. **Manager awards:** From Recognition tab in Team Board, manager taps "+", picks staff member, selects badge type
2. **Staff receives:** Push notification + in-app card on Recognition tab
3. **Collection:** All earned badges accumulate in **El Podio** (existing Barrio home destination)
4. **Badge types:** Collectible icons (e.g., "Sales Star", "Team Player") — curated list, potentially expandable

---

## Killed / Deferred Summary

| Item | Decision | Reason |
|------|----------|--------|
| Team Readiness (H5) | **Killed** | Not needed |
| Messenger (Surface C) | **Killed** | Staff use WhatsApp/iMessage |
| Pay Stubs & Files (Surface D) | **Killed** | Compliance-heavy, low-value |
| Floor Announcements (B5) | **Killed** | Real-time push is chat in disguise |
| Availability / Swaps / Releases | **Deferred** | 8.xa write paths, shown dimmed + "Coming Soon" |
| Personal Trends (Surface G) | **Deferred** | 8.xb, vendor-dependent |
| Schedule Hub (Surface A) | **Deferred** | 8.xa, vendor-dependent |
| AI Coaching (Phase 10) | **Deferred** | After 9.75b proven useful |

---

## Phase Sequence

```
9.75a  Team Board (Daily Board + Announcements + Focus + Recognition + Coaching Dashboard)
9.75b  My Shift (Pre-Shift + Post-Shift + Focus Prompt + Coaching Engine)
9.75c  Notifications (FCM + local scheduled)
  -- all three above can be built in parallel --
9.75d  Staff Lifecycle Admin (requires 9.75a — staff accounts need board access to be useful)
8.xa   Schedule Hub read paths (requires vendor adapter)
8.xb   Personal Trends (requires per-employee POS attribution)
10     AI Coaching Agent (requires 9.75b proven useful)
```

---

## Key Codebase Integration Points

| Existing Pattern | Reused In |
|-----------------|-----------|
| `BarrioDestination` + `BarrioBubbleHub` | Home IA — new Team Board + Schedule destinations |
| `BarrioRouteMap` + `barrio_destinations.dart` | Routing — 3-file pattern |
| `BarrioPreviewRole` + audience filtering | Role-dependent hub rendering + manager-only tabs |
| `BarrioStreakService` | 8.xb streak extension in Personal Trends |
| `BarrioSourceMaterial` pattern | Coaching tactic library |
| `ImportRun` / `SyncWatermark` | 8.xa sync-and-cache for schedule data |
| `ActiveTargetProfile` / `ActiveTargetProfileNotifier` | 9.75b target context in shift header |
| `LaborModel` | 9.75b busyness signal calculations |
| `ShiftRecord` / `ShiftRecordDao` | 9.75b historical average queries |
| Knowledge graph (`graphify-out/graph.json`) | 9.75b deterministic coaching focus selection |
| `fl_chart` (in pubspec) | 8.xb trend charts |
| `el_podio_screen.dart` + `el_podio_demo_data.dart` | Badge collection display |

---

## Key Files to Modify

| File | Change |
|------|--------|
| `lib/internal/barrio/routes/barrio_destinations.dart` | Add `team_board` + `schedule` destinations, role-dependent primary logic |
| `lib/internal/barrio/routes/barrio_route_map.dart` | Add routes for new screens |
| `lib/internal/barrio/widgets/barrio_bubble_hub.dart` | Add bubbles, role-dependent center |
| `lib/internal/barrio/screens/el_podio_screen.dart` | Extend with badge collection display |

## Key Files to Create

| File | Purpose |
|------|---------|
| `lib/internal/barrio/screens/team_board_screen.dart` | Tabbed Team Board container |
| `lib/internal/barrio/screens/my_shift_screen.dart` | Pre-shift / post-shift sub-views |
| `lib/internal/barrio/screens/schedule_hub_screen.dart` | Schedule menu list |
| `lib/internal/barrio/screens/personal_trends_screen.dart` | PPA trends, focus history, streaks |
| `lib/internal/barrio/screens/staff_admin_screen.dart` | Staff lifecycle admin |
| `lib/domain/models/board_post.dart` | Daily Board post model |
| `lib/domain/models/announcement.dart` | Announcement model |
| `lib/domain/models/weekly_focus.dart` | Weekly focus model |
| `lib/domain/models/recognition.dart` | Recognition + badge model |
| `lib/domain/models/focus_assignment.dart` | Coaching focus assignment |
| `lib/domain/models/coaching_tactic.dart` | Coaching tactic model |
| `lib/domain/models/notification_preference.dart` | Per-user notification prefs |
| `lib/domain/models/staff_lifecycle_event.dart` | Staff account event model |
| `lib/domain/services/coaching_focus_selector.dart` | Deterministic coaching engine |
| `lib/internal/barrio/content/coaching_tactic_library.dart` | Tactic templates |
| `lib/services/notification_service.dart` | FCM + local notification service |

---

## Verification Approach

| Slice | Verification |
|-------|-------------|
| 9.75a | Manager posts to Daily Board, staff sees it read-only in Team Board tab. Announcement posted with read tracking — staff sees checkmark, manager sees read list. Weekly Focus set from F&F variance recommendation, visible on Focus tab + My Shift banner. Recognition badge awarded, push delivered, badge appears in El Podio. Coaching Dashboard shows support-first sorted view (manager only). |
| 9.75b | Staff opens My Shift from Schedule menu, sees pre-shift briefing with demo data. Shift header shows time + role + goal framing. Busyness signal card renders. Focus prompt shows tactic + why, "show me another" cycles to alternative. Post-shift recap populates after shift end, push notification fires. Focus outcome card shows hit/close/missed. Takeaway appears at top of next pre-shift. Fallback chain degrades correctly when graph unavailable. |
| 9.75c | Pre-shift push fires 60min before shift. Announcement push on post. Recognition push on award. Post-shift recap push after shift. Per-type muting honored in preferences. |
| 9.75d | Admin creates staff account via multi-add form, staff logs in, sees Team Board. Admin deactivates, access revoked. Role change cascades permissions. Accessible from both Barrio and F&F settings. |
| 8.xa | Staff sees real schedule from vendor in My Schedule. Daily Schedule shows team view. Hours Worked matches vendor data. Schedule change push fires. Deferred items remain dimmed. |
| 8.xb | Staff sees PPA trend chart with full transparency in Personal Trends. Focus history log accurate. Streaks extend BarrioStreakService. |
| 10 | Chat bubble on Barrio home. Guided prompts + free typing. Staff coaching + manager operational queries. Graph-grounded answers citing Jim Taylor / handbook. Falls back to deterministic on budget exceeded. |
