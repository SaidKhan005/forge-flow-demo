# Deep Audit Gap Closure Plan - 2026-05-19

## Plain English Summary

- Three merged fixes closed the first batch of surface gaps.
- The next audit pass found three real remaining gaps:
  - new operators and new locations still do not get canonical Business Timing at creation;
  - clearing a manual cover entry can look cleared locally but survive on the server;
  - projection retry evidence needs a readable failure stage and stronger hard-delete evidence retention.
- The fixes should land as separate worktree PRs so each risk can be reviewed cleanly.

## Gap 1 - Business Timing Onboarding Bootstrap

- Problem: admin onboarding creates `operators`, the root org unit, and a primary `locations` row, but it does not create a `business_timing_profiles` row.
- Problem: adding a location still writes only a `locations` row.
- Why it matters: fresh operators can reach vendor sync paths before they have canonical business-day start and service-period settings.
- Fix:
  - keep `locations.timezone` as the location-owned timezone source;
  - seed a starter operator-scope Business Timing profile during admin operator onboarding;
  - use the same starter service-period set the Business Timing editor presents for first save;
  - when adding a location, inherit from the operator profile and flag/fail clearly if the operator has none;
  - keep legacy rollover-hour edits blocked.
- Verification:
  - proxy/repository tests prove onboarding creates a resolvable profile;
  - location-create tests prove the new location inherits existing operator timing;
  - existing Account and Business Timing editor tests still pass.

## Gap 2 - Manual Covers Clear Semantics

- Problem: Operator Web removes a manual cover slot locally when the field is blank, but the server-side merge keeps old nested manual entries when the key is omitted.
- Why it matters: an operator can clear a manual count, reload, and see the old number come back.
- Fix:
  - add explicit clear intent for `(business_date, service_period_key)`;
  - make Operator Web send that clear intent when the operator blanks a saved manual value;
  - keep unrelated manual entries intact;
  - update the small user-facing "daypart" wording in vendor relativity labels to "service period".
- Verification:
  - Operator Web test proves blanking a saved value sends clear intent;
  - proxy/repository tests prove one cleared slot is removed and neighboring slots survive.

## Gap 3 - Projection Retry Evidence

- Problem: pre-input projection failures are now durable, but the stage is only inferable, not readable.
- Problem: hard-deleting parent connector/location rows could cascade-delete retry evidence.
- Why it matters: support needs to tell whether a failed row is replayable, and terminal evidence should not vanish during cleanup.
- Fix:
  - add an additive `failure_stage` column with values like `pre_input` and `post_input`;
  - write `post_input` for normal retry rows and `pre_input` for pre-input dead-letter rows;
  - expose the stage in admin observability rows;
  - add immutable original-id snapshot columns or an equivalent non-cascading evidence shape before weakening hard-delete evidence.
- Verification:
  - migration guardrails pass;
  - retry repository tests prove stage write/read behavior;
  - admin observability tests prove the stage appears in the read-only view;
  - migration shape tests prove hard-delete evidence is no longer silently erased.

## Execution Order

1. Land this plan doc.
2. Run Business Timing and Manual Covers lanes in parallel.
3. Run Projection Retry as its own schema lane after the first two PRs are stable, because it touches migrations and cutoff docs.
4. Gate every PR with the repo pre-merge gate when it touches app, proxy, schema, or runtime code.
5. After each merge, run `tool/verify_pr_landed.sh` with symbols that prove the expected content is on `origin/master`.

## Out Of Scope

- No product rename of old wire literals like `operator_manual_entry_per_daypart` unless a migration-safe compatibility plan is added.
- No graph refresh; the existing graph output is used read-only.
- No live cloud, Firebase, billing, vendor, or production database mutation.
