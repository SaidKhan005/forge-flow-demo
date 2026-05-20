# Gap Fix Wave 4 Execution Plan - 2026-05-20

## Plain English Findings

- The older high-risk gaps are now fixed on master: admin Data Accuracy writes require idempotency, source labels travel through the read path, impossible manual-cover dates fail before write, keyed-only saves no longer create hidden lunch/dinner/late-night rows, star shifts now travel from mobile with service-period rows, and active admin/operator role gates no longer accept phantom roles.
- The remaining safe gap for this wave is truth in the app: some admin pages say "read-only" or "admin never writes" even though super admins can use audited repair or support actions.
- Mobile Covers Setup is intentionally simple usage. Full setup stays in Operator Web, per operator direction, so it is not a gap for this wave.

## Fix Now

- Update the Admin route labels for Data Accuracy so the app says support can review rows and super admins can apply audited overrides.
- Update the Admin route labels for Vendor Integrations so the app says support can review location-scoped connections and super admins can run audited connect, test, disconnect, and log actions.
- Update the Admin route labels and comments for Timing so the UI remains read-only, while the code comments honestly say server-side super-admin repair routes exist.
- Update Data Accuracy read-only banner copy so support users understand they can review the rows, while override actions are hidden for their role.
- Update the route-copy tests so this truth is pinned.

## Deferred Decisions To Revisit Later

- Admin custom service-period keys: keep the current migration/support repair escape hatch until product decides whether admin must be configured-period-only.
- Explicit legacy trio payloads: new clients no longer emit or synthesize old lunch/dinner/late-night keys, but the proxy still accepts explicit legacy payloads for compatibility until product decides to reject them.
- Star target service-period fallback: mobile now sends service-period rows, but the broader "one row for every configured period with fallback" behavior remains a deeper architecture follow-up.
- Hidden server-only admin POST routes: heap snapshot capture and vendor lifecycle promotion stay documented as operational endpoints until product decides whether they need visible Admin UI affordances.

## Verification

- Run the focused admin copy test.
- Run focused analyzer on the edited app, proxy, and test files.
- Run the UX em-dash lint, diff whitespace check, pre-merge gate, and post-merge landed verification.
