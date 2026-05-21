# Operator Web UX Consistency Wave 0 Audit

Date: 2026-05-21

Scope: Operator Web only.

## Summary

Wave 0 confirmed that the top scope picker is the right shared hierarchy
control and should stay. The stale UX is mostly inside page bodies: local card
containers, one-off banners, mixed dialog shells, and full-screen-style date
range behavior.

## Findings

| Surface | Code checked | Finding | Wave action |
|---|---|---|---|
| Shared widgets | `lib/operator_web/widgets/operator_web_section_heading.dart`, `lib/operator_web/widgets/operator_web_info_button.dart` | Section headings and compact info popovers already exist and are active. | Reuse them instead of creating a second heading or help pattern. |
| Tiles and panels | `lib/operator_web/screens/**`, `lib/operator_web/widgets/**` | Most panels hand-roll the same white/cardGlow background, border, radius, and padding. | Wave 1 should add one shared Operator Web panel and migrate a safe proof screen. |
| Banners | `business_setup_screen.dart`, `my_account_screen.dart`, `wage_source_toggle.dart`, `business_logo_upload_section.dart` | Read-only, warning, and error banners are local containers with similar copy rhythm but different structure. | Wave 1 should add one shared compact banner. |
| Dialogs | `business_setup_screen.dart`, `members_screen.dart`, `hierarchy_screen.dart`, `my_account_screen.dart`, `wage_authority_screen.dart`, `operator_web/widgets/**` | Dialogs mix `AlertDialog`, `Dialog`, and custom shells. | Wave 1 should add one compact Operator Web dialog shell before later waves migrate specific flows. |
| Date range | `audit_log_screen.dart` | Audit Log still owns date filtering locally and should move to a compact popup in a later wave. | Wave 1 should provide the reusable compact date-range shell only; Wave 5 should wire it. |
| Business Timing proof target | `business_setup_screen.dart` | It is a safe read surface with local panels, a read-only banner, and a non-mutating safe dialog. | Use it as the Wave 1 proof screen without changing backend behavior. |

## Boundaries

- Data Accuracy remains location-focused.
- Vendor Integrations remains location-focused.
- Logo remains business-level.
- Admin Web and mobile were not inspected beyond confirming they are out of
  scope.
