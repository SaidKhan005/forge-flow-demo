# Admin Console Browser QA Runbook

Purpose: test the 11A Flutter Web admin console in the in-app browser
using the same built assets shape that Cloud Run serves.

Use this runbook together with
`runbooks/browser_use_codex_acceptance_workflow.md`. That workflow defines the
repeatable Browser Use evidence shape (Codex-driven, out-of-repo); this file
adds admin-console-specific build, origin, and safety notes.

## Default Local QA Path

Use a static web build for browser QA:

```powershell
flutter build web -t lib\main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=<proxy-base-uri>
Set-Location build\web
python -m http.server 7358 --bind 127.0.0.1
```

Open:

```text
http://127.0.0.1:7358/
```

This path is the preferred local proxy-backed QA route because it tests
compiled web assets close to the Cloud Run admin-service shape.

Always pass `-t lib\main_admin.dart`. A plain `flutter build web`
compiles the operator app shell, not the Operations Console.

If the same local port previously served the operator shell or another
entrypoint, use a fresh port or clear that origin's Flutter service
worker/cache before retesting. Otherwise the browser can keep serving
the stale shell even after the admin bundle has been rebuilt.

## Debug Web-Server Fallback

If `flutter run -d web-server` opens a blank or splash-only page in the
in-app browser, switch to the static build path above before filing a
product bug. The debug web-server can fail during local browser
bootstrap even when the production-style static build is healthy.

Record both facts in the QA note:

- debug web-server result
- static build result

Only treat it as a product blocker if the static build also fails.

## Corpus Graph Candidates

If Corpus -> Graph candidates returns `graph_candidates_not_configured`
or the safe "graphify candidate artifacts are not on disk" message,
verify the advisor proxy image includes
`tool/advisor_proxy/graphify_candidates` copied to `/app/graphify-out`.
The branch-fixed packaging path ships only sanitized JSONL candidates and
the manifest. Do not copy or commit raw `graphify-out/graph.json`,
Graphify cache files, or converted source material.

## Safe Live Testing

- Opening dialogs is safe.
- Do not submit operator onboarding, pricing caps, corpus commits,
  provider rotations, feature-flag toggles, suspend/reactivate, delete,
  or rebuild actions without action-time approval.
- Do not include secrets, emails, OTPs, passwords, or bearer tokens in
  screenshots or notes.

## Admin Route Sweep

For admin-console slices, sweep the touched route plus any adjacent route that
shares its gateway, health producer, or side-nav shell. For full acceptance
passes, cover the current side-nav keys:

- `admin_nav_item_home`
- `admin_nav_item_operators`
- `admin_nav_item_pricing`
- `admin_nav_item_corpus`
- `admin_nav_item_integrations`
- `admin_nav_item_health`
- `admin_nav_item_feature_flags`
- `admin_nav_item_debug`
- `admin_nav_item_observability`

Record the exact origin, build/revision, route result, screenshot or DOM/text
evidence, and whether any action stopped for approval.
