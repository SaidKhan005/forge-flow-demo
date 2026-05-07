# Operator Web Contact Email + Management Context Picker

Date: 2026-05-07

Worktree: `.codex_worktrees/operator-web-full-verification`

Branch: `codex/operator-web-contact-context-picker`

Source commit: `6ff7c2d8` (`origin/master` after rebase)

## Summary

- Renamed admin-console user-facing `Owner email` copy to `Contact email`.
- Renamed `Admin user email` onboarding copy to `Owner login email`.
- Added helper copy explaining that contact email is business metadata, while owner login email receives the invite and signs in.
- Added an operator-web header `Managing` selector backed by the team hierarchy gateway.
- Selector options include business-wide, org-unit groups, and locations. Location-scoped tabs require a location selection and show a clear stop for business/group scopes.
- Business setup, Business timing editor, Vendor connections, and Data accuracy now use the selected location instead of always using `session.primaryLocationId`.
- Members invite/filter location options now come from the loaded hierarchy location catalog when available.

## UX Notes

- Toast-style pattern followed: keep the structural hierarchy in the Locations surface, but expose a compact top-level context selector for day-to-day management.
- Business/group scopes are intentionally not faked on location-only routes. Vendor connections and Data accuracy remain location-scoped.
- The header hides lower-priority identity/role details at narrow widths so the selector and sign-out control remain reachable.

## Verification

- `flutter analyze`
- `flutter test test\operator_web`
- `flutter test test\admin_operator_location_screen_test.dart`
- `flutter test test\operator_web\operator_web_router_test.dart` after rebasing onto latest `origin/master`
- `flutter build web --release --target=lib\main_operator_web.dart` with `OPERATOR_WEB_PROXY_BASE_URI` set
- Browser Use local demo smoke at `http://127.0.0.1:8196/?token=demo-magic-link-token&codexQa=scope-picker-local`:
  - completed demo onboarding
  - opened `Managing`
  - verified business-wide, region, and location options were visible
  - selected `Downtown`
  - verified Vendor connections rendered for `Downtown`
  - selected `All locations`
  - verified Vendor connections showed the `Choose a location` stop
  - console warning only: existing Flutter viewport replacement warning

## Residual Risks

- Org-unit and business-wide scopes are available in the selector but are intentionally gated on location-only tabs until those backend capabilities have route-level UX semantics.
- Members list reads still use the existing team-users list command and then local filters; this pass only replaces the location catalog with hierarchy-backed options.
