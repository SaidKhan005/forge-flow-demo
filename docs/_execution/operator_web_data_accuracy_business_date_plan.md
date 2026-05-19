# Operator Web Data Accuracy Business Date Plan

## Plain-English Goal

- Data Accuracy should use the same Business Timing rules as Shift and Covers.
- A live Operator Web build should not fall back to the old rollover-hour field when choosing the default effective date.
- If live timing resolution is not wired, Data Accuracy should fail visibly instead of letting the operator save rows to the wrong date.

## Scope

- Use the selected location's Business Timing resolution for the current business date.
- Keep demo and widget-test fixtures working with their existing fallback.
- Add focused router and adapter tests for sub-hour business-day starts.

## Guardrails

- Do not change Data Accuracy save payloads except the default date supplied by the router.
- Do not touch mobile Covers, star-shift writes, projection retry code, or account settings in this slice.
- Run focused tests, analyzer, UX copy lint, and diff whitespace checks before PR.
