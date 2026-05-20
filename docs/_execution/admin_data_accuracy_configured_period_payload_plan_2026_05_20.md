# Admin Data Accuracy Configured Period Payload Plan - 2026-05-20

## Plain English Gap

- Admin Data Accuracy can already display configured service periods.
- Operator Web already reads the operator's timing setup, including custom period names such as Brunch or Late service.
- The live Admin Data Accuracy server row does not send those configured periods.
- Result: Admin can show generic period behavior even when the business has a custom timing setup.

## Fix Plan

- Keep the Admin UI unchanged.
- Add the configured service periods to each live Admin Data Accuracy row.
- Read them from the current business timing profile chain for the row's operator and location.
- Preserve inheritance: if a location profile does not define service periods, use the nearest inherited profile that does.
- Emit the periods as `service_period_definitions`, the shape the Admin gateway already parses.
- Keep legacy covers write/read compatibility unchanged.

## Scope Guardrails

- No database migration.
- No mobile change.
- No Operator Web change.
- No new fallback UI.
- No provenance-label decision in this pass.

## Verification

- Add a focused proxy regression test proving Admin rows include configured service periods from the business timing tables.
- Run the focused test.
- Run analyzer for the touched proxy/test files.
- Run UX copy lint and `git diff --check`.
- Use the repo pre-merge gate before merging because this touches the proxy runtime.
