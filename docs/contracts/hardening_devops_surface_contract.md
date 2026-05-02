# Hardening — DevOps Surface Contract

> **Status (2026-05-02):** Closed. Shipped commit `efad2fd` (PR #43).
> Contract is retained as historical authority; no further implementation
> work owed.


Updated: 2026-05-02
Owner: HARD-E (DevOps surface sprint)
Status: Active authority

## Why This Exists

Five DevOps surfaces ship inconsistent posture: the staging-DB setup script
documents migrations only through `202604250005` (fresh staging silently
misses 50 newer migrations), the MFA removal worker has no deployment
manifest in the repo (delayed removals stall), iOS schemes rely on Flutter
flavor inference for entrypoint correctness, the release builds do not
assert auth flag presence, root and worker Dockerfiles run as root with
unpinned base images, and GitHub Actions reference floating tags. This
contract pins each surface so deploys are reproducible and auditable.

Handoff between:

- `scripts/postgres_staging_setup.ps1` — staging DB runbook.
- `tool/mfa_removal_worker/` — new Dockerfile + cloudbuild.
- `ios/Runner.xcodeproj/xcshareddata/xcschemes/Barrio.xcscheme`,
  `ForgeFlow.xcscheme`.
- `Dockerfile` (root, proxy image) and `tool/mfa_removal_worker/Dockerfile`.
- `.github/workflows/ci.yml`, `apple-platform-verify.yml`.

Disagreement rule: when this contract and a script disagree on which
migrations / images / flags to use, this contract wins; update the script.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Staging DB script reflects current migration cutoff | yes | manual SQL drift checks |
| MFA-removal worker has Dockerfile + cloudbuild + Scheduler manifest | yes | adding new worker capabilities |
| iOS schemes pin `FLUTTER_TARGET` | yes | code-signing identity, App Store Connect changes |
| Release CI asserts `FORGE_FLOW_USE_FIREBASE_AUTH=true` | yes | flag value validation per environment |
| Dockerfile runs as non-root | yes | seccomp / AppArmor profiles |
| Dockerfile pins base images by digest | yes | upgrading the underlying image |
| GitHub Actions pinned to commit SHA | yes | replacing actions wholesale |

Out of scope: Cloud Run revision-rollback runbook (HARD-G), KMS startup
warning (HARD-G), iOS physical-device QA matrix (already deferred per
PROJECT_TRACKER.md).

## Required — Staging DB Script

`scripts/postgres_staging_setup.ps1` must replace the literal migration
range (currently "starts at `202604250000` … through `202604250005`")
with one of:

- A pointer that defers to a canonical migration runner, e.g. "applies
  every migration under `db/migrations/**` in lexicographic order via
  `dart run tool/postgres_apply_migrations.dart --target staging`"; or
- A literal current cutoff that includes the latest migration filename on
  master (today: `202605020400_phase_11A_7_feature_flags_admin_columns.sql`).

A passing change matches one of those two shapes. If a literal cutoff is
chosen, also add a CI lint that fails when `db/migrations/` contains a
file lexicographically newer than the script's literal — see Test
Surface.

## Required — MFA Removal Worker Manifest

New files under `tool/mfa_removal_worker/`:

`Dockerfile`:

- Base image: `dart:stable-sha256:<digest>` (pinned digest, not floating tag).
- Multi-stage build: build stage runs `dart pub get` + `dart compile exe`;
  runtime stage runs the AOT binary on `gcr.io/distroless/cc:nonroot` (or
  `debian:bookworm-slim` digest-pinned with explicit `useradd` + `USER`).
- No build secrets baked into final image.
- Default `CMD ["mfa_removal_worker"]`.
- `HEALTHCHECK` not required (Cloud Run Job, not Service).

`cloudbuild.yaml`:

- Builds image, tags with `$SHORT_SHA`, pushes to artifact registry.
- Step gated on `dart analyze --fatal-infos` and `dart test
  test/mfa/` passing.

`README.md` (or runbook addition under `docs/runbooks/`):

- Cloud Run Job spec: image, region (`northamerica-northeast1`), min/max
  retries, parallelism, timeout (5 min).
- Cloud Scheduler trigger: `every 10 minutes`, OIDC-authenticated invoker,
  retry config exponential 1m/30m.
- Failure alarms point to existing `forgeflow-cmk-alerts` Action Group.

Acceptance: `gcloud run jobs deploy mfa-removal-worker ...` from the
runbook produces a runnable Job; Scheduler triggers it; delayed MFA
removal records process within their 24h+10min window.

## Required — iOS Scheme Pinning

Both `Barrio.xcscheme` and `ForgeFlow.xcscheme` must add explicit
`FLUTTER_TARGET` to ArchiveAction (and LaunchAction for parity):

```xml
<CommandLineArguments>
  <CommandLineArgument
     argument="--flavor barrio"
     isEnabled="YES">
  </CommandLineArgument>
  <CommandLineArgument
     argument="--dart-define=FLUTTER_TARGET=lib/main_barrio.dart"
     isEnabled="YES">
  </CommandLineArgument>
</CommandLineArguments>
```

Adjust per scheme: ForgeFlow uses `--flavor forgeflow` and
`lib/main_forgeflow.dart`.

Acceptance: archiving from Xcode produces an IPA whose first screen
matches the scheme's brand. Verify by post-archive smoke (manual today;
add in Phase 11b CI).

## Required — Release CI Auth-Flag Assertion

`.github/workflows/ci.yml` (or whichever workflow runs the release
flutter build) must include a step before the release build:

```yaml
- name: Assert FORGE_FLOW_USE_FIREBASE_AUTH=true in release dart-defines
  run: |
    grep -F 'FORGE_FLOW_USE_FIREBASE_AUTH=true' release.dart-defines.txt \
      || (echo "::error::Release build missing FORGE_FLOW_USE_FIREBASE_AUTH=true"; exit 1)
```

Implementation may differ (env-driven, build-script driven), but the
guarantee is: a release build that does not pass
`--dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true` MUST fail CI before
artifact emission.

## Required — Dockerfile Posture

Both root `Dockerfile` (proxy) and worker `Dockerfile`:

- Pin every `FROM` to a `@sha256:<digest>` reference.
- Add `RUN useradd --create-home --uid 10001 app && chown -R app:app /app`
  (or use `distroless:nonroot`).
- Final stage: `USER app` (or `USER nonroot`) before `CMD`.
- No `--privileged`, no extra capabilities.
- Layer cache friendly: copy `pubspec.*` first, run `pub get`, then copy
  source.

## Required — GitHub Actions SHA Pinning

`.github/workflows/*.yml` references to public actions (`actions/checkout`,
`actions/setup-java`, `actions/cache`, etc.) must be replaced with
commit-SHA references. Floating-tag refs to external orgs are a SLSA-3
violation. Internal/Anthropic-owned actions may stay on tags.

Example replacement:

```yaml
- uses: actions/checkout@a5ac7e51b41094c92402da3b24376905380afc29  # v4
```

Acceptance: `Grep "uses: actions/.*@v[0-9]" .github/workflows/` returns
zero hits except internal allow-listed actions.

## Out of Scope

- Cloud Armor enforcement promotion (preview-only by tracker policy).
- iOS physical-device matrix (deferred).
- Release-binary signing/notarization changes.

## Test Surface

- Lint: new `tool/migration_cutoff_lint.dart` (if literal cutoff chosen)
  asserts script literal matches `db/migrations/` newest filename.
- Smoke: `docker build -f tool/mfa_removal_worker/Dockerfile .` succeeds.
- Smoke: `docker run --rm <image> --version` (or equivalent) prints worker
  version as `app` user, not `root`.
- CI dry-run: missing `FORGE_FLOW_USE_FIREBASE_AUTH` in release defines
  fails the workflow.
- `Grep "@v[0-9]+" .github/workflows/` covered by allow-list.
- `dart analyze --fatal-infos`.

## Codex Acceptance

- [ ] Staging script reflects current migration cutoff or defers to a
      canonical runner.
- [ ] `tool/mfa_removal_worker/Dockerfile` exists, multi-stage, non-root,
      digest-pinned base.
- [ ] `tool/mfa_removal_worker/cloudbuild.yaml` exists.
- [ ] Cloud Run Job + Scheduler runbook documents deploy + trigger.
- [ ] Both `.xcscheme` files pin `FLUTTER_TARGET`.
- [ ] Release CI step fails when `FORGE_FLOW_USE_FIREBASE_AUTH=true` is
      missing from release defines.
- [ ] Root + worker Dockerfiles pin base by digest, add non-root user,
      `USER app` (or distroless `USER nonroot`) before `CMD`.
- [ ] All `actions/*@v<n>` floating refs in `.github/workflows/`
      replaced with SHA (allow list documented).
- [ ] All listed tests / lints pass.
