# Phase 9.8 - Compliance, Privacy, and Legal

Updated: 2026-04-26
Status: Planned
Owner: Future compliance/legal lane

**2026-04-26 — Postgres host re-locked to Microsoft Azure Database for PostgreSQL Flexible Server (`Canada Central`, PG 16).** Replaces Supabase. Mechanical impact on Phase 9.8: covered processor chain swaps Supabase out, Microsoft Azure in. SOC 2 / ISO 27001 inheritance docs reference Azure attestations instead of Supabase. DPA signed with Microsoft (existing customer agreement covers Azure DB) instead of Supabase. Data residency for Canadian operators unchanged (both `ca-central-1` Montreal on Supabase and `Canada Central` Toronto on Azure are Canadian-resident — Quebec PIPEDA / Ontario PHIPA compliance posture preserved). Cyber-liability insurance review now references Azure DB. See `phase_9_auth_plan.md` 2026-04-26 banner for the trigger and broader rationale.

## Decisions Locked (2026-04-23 review)

- **This is a legal + documentation lane, not an engineering lane.**
  Phase 9.8 owns launch-critical compliance artifacts and processor
  paperwork. It does not own app implementation work.

- **Sequencing: Q3-Q4 2026 before first operator live.** This phase lands
  alongside the pre-launch security audit budgeted in E23 and should be
  complete before the first real operator goes live.

- **Dependency shape: after vendor contracts and live auth are real.**
  Phase 9.8 depends on `Phase 8` / `8R` vendor contracts being signed so
  the processor chain is real, and on `Phase 9` auth being live so the
  identity processor is no longer hypothetical.

- **Covered processor chain for V1:** Firebase Auth (identity),
  Microsoft Azure (Database for PostgreSQL Flexible Server in `Canada Central` — primary data layer), Google Cloud Run (agent runtime),
  Toast (POS), 7shifts (Labor), OpenTable (Reservation).

- **Privacy policy freshness is launch-blocking.** The current
  "no third-party integrations" posture cannot survive first live
  production use once these processors are real.

- **SOC2 inheritance documentation must stay honest.** Vendor attestations
  support Forge & Flow's posture; they do not mean Forge & Flow itself is
  independently SOC2 certified unless that later becomes true.

- **Cyber-liability insurance review is part of the same launch package.**
  Budget line E34 already covers this category; Phase 9.8 confirms the
  actual coverage matches the real processor chain and deployment posture.

## Goal

Prepare the compliance and legal package needed for Forge & Flow's first
live operator launch: privacy policy, Terms of Service, processor DPAs,
SOC2 inheritance memo, and cyber-insurance alignment.

## Scope

Phase 9.8 owns:

- **Privacy policy update** covering the real data processors in the
  production chain:
  - Firebase Auth
  - Microsoft Azure Database for PostgreSQL Flexible Server
  - Google Cloud Run
  - Toast
  - 7shifts
  - OpenTable

- **Terms of Service drafting** for the operator SaaS subscription

- **Data Processing Agreements (DPAs)** with each real data processor named
  above

- **SOC2 inheritance documentation**
  - Microsoft Azure Database for PostgreSQL Flexible Server SOC 2 / ISO 27001 attestation context
  - Firebase / Google Cloud compliance inheritance context
  - Forge & Flow's own documented posture layered on top of those vendors

- **Cyber-liability insurance alignment**
  - confirm the policy scope matches the real processor chain
  - confirm the policy assumptions match the planned deployment posture
  - tie the review back to budget line E34

Adjacent work that plugs in:

- the pre-launch security audit in E23 can feed evidence into the launch
  compliance package
- vendor contracting outputs from `Phase 8` / `8R` feed the DPA package

## Scope Does Not Own

Phase 9.8 does not own:

- engineering implementation work
- connector implementation (`Phase 8` / `8R`)
- auth implementation (`Phase 9`)
- legal advice itself; founders and counsel still own the final legal
  review and signoff
- security-audit execution itself; that is adjacent launch work

## Runtime Contract

```text
live processor chain + signed vendor contracts
-> processor inventory + compliance obligations
-> privacy policy + ToS + DPA package + SOC2 inheritance memo
-> cyber-liability coverage check
-> first live-operator launch package
```

## Dependencies

Required before Phase 9.8 can ship real:

- `Phase 8` / `Phase 8R` vendor contracts signed
- `Phase 9` auth live
- processor chain stable enough to enumerate honestly in launch docs

Helpful adjacent inputs:

- E23 pre-launch security audit outputs
- E34 cyber-liability insurance review inputs

## Non-Negotiables

- do not go live with the stale "no third-party integrations" privacy
  posture once processors are real
- every named processor must have matching DPA / terms handling
- SOC2 inheritance documentation must distinguish vendor attestations
  from Forge & Flow's own claims
- do not treat this phase as an engineering backlog
- do not treat legal text as complete until founders and counsel review it

## Adjacent Phases

- `Phase 8` / `8R` make the processor chain real and signable
- `Phase 9` makes the identity processor real in production
- E23 pre-launch security audit provides adjacent launch evidence
- `Phase 10a` / `11a` do not replace 9.8; they merely shape the actual
  processor and infrastructure chain 9.8 documents

## Source Material

- [phase_9_auth_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9/phase_9_auth_plan.md)
- [phase_8_live_pos_labor_adapter_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md)
- [phase_8R_official_reservation_connector_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md)
- [phase_10a_shared_state_v1_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md)
- [phase_11a_advisor_infrastructure_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md)
- [ForgeFlow Project Cost.xlsx](C:/Git%20Local%20Repos/forge_flow_demo/docs/business/ForgeFlow%20Project%20Cost.xlsx)

## Placeholder Notes

- Actual policy text, ToS language, and signed DPAs are human legal work.
- This doc gives the launch-blocking compliance items a concrete phase home.
