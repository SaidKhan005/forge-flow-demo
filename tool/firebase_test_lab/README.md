# Firebase Test Lab — Q-2c push round-trip soak

Wave 2 slice **Q-2c**. Drives real-device mobile push round-trip
testing through Firebase Test Lab on both Android (FCM) and iOS
(APNs via FCM).

This directory holds the **test-time-only** harness:

- `firebase_test_lab_matrix.dart` — Dart model of the Android + iOS
  device + OS pairs the soak fans out over.
- `firebase_test_lab_runner.dart` — `gcloud firebase test {android,
  ios} run` wrapper. Reads `FIREBASE_TEST_LAB_PROJECT_ID` from env;
  skips with a clear message when unset (no CI cost).
- `firebase_test_lab_orchestrator.dart` — CLI entrypoint. Drives the
  runner once per lane, emits a Markdown report with per-lane and
  per-device coverage plus the exact gcloud argv.

Companion integration test lives under
`integration_test/push_delivery/`. Webhook receiver for matrix
completion callbacks lives at
`tool/advisor_proxy/firebase_test_lab_webhook_routes.dart`.

## Default matrix

| Lane    | Device   | OS         |
|---------|----------|------------|
| Android | Pixel6   | API 30     |
| Android | Pixel6   | API 33     |
| Android | Pixel6   | API 34     |
| iOS     | iphone14 | 16.0       |
| iOS     | iphone14 | 17.0       |

All entries pinned to `en_US` and `portrait`. Five device-runs per
soak. Pixel 6 is the cheapest Test Lab virtual device that exposes
Google Play Services — FCM delivery requires Google APIs, so the
matrix excludes the no-Play-Services AOSP emulators. iPhone 14 is
the cheapest Test Lab physical device that supports APNs.

The matrix is hard-coded in `firebase_test_lab_matrix.dart`. Add
entries by editing `kDefaultFirebaseTestLabMatrix` — the
orchestrator picks the constant up automatically.

## Build the demo APK / IPA

The harness assumes the binary is built with `kDemoMode=true` so
the same seed path the Q-2b in-app notification soak exercises is
the one Test Lab drives. **Do not** check the binaries into the
repo — they are reproducible from the build commands and large.

### Android

```sh
flutter build apk --release \
  --flavor forgeflow \
  --dart-define=kDemoMode=true \
  --target=integration_test/push_delivery/push_delivery_cold_start_test.dart
```

Artifact path: `build/app/outputs/flutter-apk/app-forgeflow-release.apk`.

Build the matching test APK (instrumentation):

```sh
pushd android
./gradlew app:assembleForgeflowReleaseAndroidTest
popd
```

Artifact path: `build/app/outputs/apk/androidTest/forgeflow/release/
app-forgeflow-release-androidTest.apk`.

### iOS

```sh
flutter build ipa --release \
  --flavor forgeflow \
  --dart-define=kDemoMode=true \
  --target=integration_test/push_delivery/push_delivery_cold_start_test.dart \
  --export-options-plist=ios/ExportOptions.plist
```

Artifact path: `build/ios/ipa/forge_and_flow.ipa`.

Build the XCTest .zip:

```sh
pushd ios
xcodebuild build-for-testing \
  -workspace Runner.xcworkspace \
  -scheme forgeflow \
  -configuration Release \
  -derivedDataPath build/
pushd build/Build/Products
zip -r ../../../forge_and_flow_xctest.zip Release-iphoneos *.xctestrun
popd
popd
```

Artifact path: `ios/forge_and_flow_xctest.zip`.

## Invoke the orchestrator

When `FIREBASE_TEST_LAB_PROJECT_ID` is unset on the host, the
orchestrator skips both lanes with a clear message and the run
report records a structural-only matrix validation. No gcloud
invocation, no cloud cost.

```sh
export FIREBASE_TEST_LAB_PROJECT_ID=forge-flow-test-lab-prod
# Optional: pin a results bucket (otherwise gcloud uses the project default)
# export FIREBASE_TEST_LAB_RESULTS_BUCKET=gs://forge-flow-test-lab-results
# Optional: override gcloud binary path
# export FIREBASE_TEST_LAB_GCLOUD=/usr/local/google-cloud-sdk/bin/gcloud

dart run tool/firebase_test_lab/firebase_test_lab_orchestrator.dart \
  --output-dir=test/firebase_test_lab \
  --run-id=local-q2c-2026-05-14 \
  --android-app=build/app/outputs/flutter-apk/app-forgeflow-release.apk \
  --android-test=build/app/outputs/apk/androidTest/forgeflow/release/app-forgeflow-release-androidTest.apk \
  --ios-app=build/ios/ipa/forge_and_flow.ipa \
  --ios-test=ios/forge_and_flow_xctest.zip
```

The orchestrator writes:

- `test/firebase_test_lab/firebase_test_lab_<run-id>.md` — Markdown
  report with per-lane + per-device coverage plus the gcloud argv.
- `test/firebase_test_lab/firebase_test_lab_<run-id>_raw.jsonl` —
  one JSON envelope per lane, suitable for downstream parsing.

## Webhook receiver for matrix completion

The runner invokes gcloud synchronously, but Test Lab also supports
asynchronous matrix-completion callbacks. The proxy hosts a sibling
route at:

```
POST /v1/test-lab/webhook/matrix-complete
```

Gated by a shared-secret header
(`X-Firebase-Test-Lab-Webhook-Secret`) validated against the env
var `FIREBASE_TEST_LAB_WEBHOOK_SECRET`. When the env var is unset
on the proxy, the route returns `503 firebase_test_lab_webhook_disabled`
so production deploys are inert by default. No operator-facing
permission key — the route is test-lab infra, server-to-server.

Request body shape (JSON):

```json
{
  "matrix_id": "matrix-abcd-1234",
  "project_id": "forge-flow-test-lab-prod",
  "state": "FINISHED",
  "outcome": "success",
  "results_url": "https://console.firebase.google.com/.../matrices/matrix-abcd-1234",
  "completed_at": "2026-05-14T18:23:11Z"
}
```

Required fields: `matrix_id`, `state`, `outcome`. Other fields are
optional. The proxy records the matrix outcome in an in-memory
store (`InMemoryFirebaseTestLabMatrixStore`) keyed by `matrix_id`;
the store survives the process lifetime, not restarts. A future
slice can swap a SQLite-backed store if soak runs need persistence
across proxy restarts.

Response on success: `204 No Content`. On a missing or mismatched
secret: `401 bad_secret`. On a missing required field: `400
missing_field`. Idempotent — a replay with the same `matrix_id` is
overwritten with the most recent payload.

## Interpreting matrix results

A pass (`gcloud` exit 0) means every device in the lane reported
the instrumentation test passed. A fail (non-zero exit) means at
least one device reported a failure; check the per-device Firebase
console links printed in the gcloud stdout. A skip means
`FIREBASE_TEST_LAB_PROJECT_ID` was unset on the invoking host (the
matrix file was structurally validated but no cloud invocation ran).

## Cost discipline

A 5-entry matrix typically completes in 12 minutes of device-time
across both lanes. The default poll budget is 30 minutes (doubled
to absorb cloud queue spikes). Do NOT run the matrix on a per-PR
schedule — invoke it before phase close or on operator request.
