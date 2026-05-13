# Forge & Flow Frameworks

Status: Active

This folder holds repeatable execution frameworks that apply across feature
work, implementation planning, audits, UX passes, performance passes, and
runtime verification.

Canonical path for every framework doc is `docs/frameworks/<NAME>.md`. There
are no copies at the docs root.

Frameworks in this folder:

- `FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` - use before, during, and
  after adding or changing product functionality so hidden backend, schema,
  auth, deploy, test, and UX seams are not missed.
- `PERFORMANCE_FRAMEWORK.md` - performance, scale, mobile responsiveness,
  web-console timing, load, polling, health, and bundle-size work.
- `UX_ADJUSTMENT_FRAMEWORK.md` - UX polish, copy, navigation, button, modal,
  filter, tooltip, browser-tab, and no-regression admin-console polish.
- `MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` - end-to-end runtime verification
  across mobile and web console seams.
- `deployFramework.md` - deploy, redeploy, preview, staging, Cloud Run, CORS,
  auth, database-mode, and rollback work.
