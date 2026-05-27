// Pressure preview v1 — Slice C-11 (R4 §4B + §7C) — push-delivery proof
// harness readiness gate. The slice spec calls for a Patrol two-device test that
// asserts the bell-badge invalidation SLO (≤ 5s mark-read across two
// connected mobile devices, per inventory rollup §11.b + R4 §3B).
//
// Sprint authority:
//   * Slice spec: `docs/archive/_execution/lane_c_parity/03_execution_slices.md`
//     C-11 (lines 209-225).
//   * Inventory: `docs/_audits/code_health/c_email_notification_scenario_inventory.md`
//     section 10 (FCM runtime plumbing) + section 11.b (bell badge).
//   * Env-gated-inert precedent: `tool/pressure/p4_heap_snapshot_uploader.dart`.
//
// What this harness WOULD prove (if Patrol were wired)
// ----------------------------------------------------
//   1. Two connected mobile devices observe the same operator inbox.
//   2. Device A's `emitPushDelivery` lands a new notification.
//   3. Device B's bell badge ticks within the SLO budget.
//   4. Device A marks-read → Device B's bell badge decrements within
//      ≤ 5s (R4 §3B SLO).
//   5. Foreground / background / terminated delivery branches each
//      route the correct intent (`forge_flow_app.dart:1342-1409` bell
//      subscribers + `mobile_push_notification_service.dart` foreground
//      banner + `getInitialMessage` cold-start path).
//
// Current state: Patrol dependency present; two-device body pending
// ----------------------------------------------------------------
// Patrol is now a declared dev_dependency in `pubspec.yaml`. The Flutter
// mobile test infrastructure required to drive a two-device proof is
// still gated by test devices and preview credentials. Missing devices
// / credentials still emit a structured deferral and exit 0. Once
// Patrol + all required env vars are present, the harness reaches the
// ready branch and exits non-zero with `push_delivery.not_implemented`
// until the real two-device body replaces the placeholder.
//
// What unblocks the full harness
// ------------------------------
//   1. Add `patrol` CLI tooling to the CI runners (Patrol's own
//      `setup-patrol` GitHub Action or equivalent).
//   2. Wire two test devices (emulators or physical) accessible to the
//      preview deployment's FCM project.
//   3. Provision two operator-test accounts whose `mobile_push_tokens`
//      can be observed in the preview Postgres instance.
//   4. Add a `PATROL_DEVICE_A_ID` + `PATROL_DEVICE_B_ID` env var pair
//      so the harness knows which two adb / xcode devices to target.
//   5. Wire `MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` dart-define for
//      the test build so `firebase_auth_runtime_bindings.dart:117`'s
//      gate selects the FCM-backed gateway.
//
// Env vars consumed when (and only when) the full Patrol harness ships
// ---------------------------------------------------------------------
//   * `PATROL_DEVICE_A_ID` — target device 1 (e.g. `emulator-5554`).
//   * `PATROL_DEVICE_B_ID` — target device 2.
//   * `PROXY_URL` — preview proxy base URL (subject to the same
//     allow-list check as `p5_email_scenario_loopback.dart`).
//   * `PROXY_OPERATOR_TOKEN_A` — operator-A sign-in token.
//   * `PROXY_OPERATOR_TOKEN_B` — operator-B sign-in token.
//   * `BELL_BADGE_SLO_SECONDS` — invalidation SLO budget (default 5s
//     per R4 §3B).
//
// Output line shapes (mirror `p5_email_scenario_loopback.dart`)
// -------------------------------------------------------------
//   { "ts": "<iso>", "metric": "push_delivery.skipped", "state": "..." }
//   { "ts": "<iso>", "metric": "push_delivery.not_implemented",
//     "state": "ready_but_unimplemented" }
//   (future) { "ts": "<iso>", "metric": "push_delivery.case",
//             "device_a": "...", "device_b": "...",
//             "bell_invalidation_ms": <int>, "slo_met": <bool> }

import 'dart:convert';
import 'dart:io';

/// Set of allow-listed substrings for `PROXY_URL`. Identical to the
/// `p5_email_scenario_loopback.dart` allow-list — never drive production.
const Set<String> kPushDeliveryAllowedProxySubstrings = <String>{
  'preview.',
  'staging.',
  'localhost',
  '127.0.0.1',
};

/// Reports the current Patrol-readiness state. Public so a future
/// Dart-test runner can assert the deferral message contract.
enum PushDeliveryHarnessState {
  /// Patrol is wired and all env vars are present. The full two-device
  /// proof would run.
  ready,

  /// Patrol is not in pubspec or the mobile test infra is otherwise
  /// not wired. The harness emits a "skipped" line and exits 0.
  deferredPatrolMissing,

  /// Patrol is wired but `PATROL_DEVICE_A_ID` / `PATROL_DEVICE_B_ID` /
  /// `PROXY_URL` / `PROXY_OPERATOR_TOKEN_A` / `PROXY_OPERATOR_TOKEN_B`
  /// is unset. The harness emits a "skipped" line and exits 0.
  deferredEnvMissing,

  /// Patrol is wired but `PROXY_URL` fails the allow-list check
  /// (a misconfiguration that would otherwise drive production).
  deferredProxyValidationFailed,
}

/// Evaluates the harness state from the supplied [env] + a list of
/// declared dev-dependency identifiers ([devDependencies]). Exposed so
/// unit tests can drive every branch without touching the real
/// `pubspec.yaml` or `Platform.environment`.
PushDeliveryHarnessState evaluatePushDeliveryState({
  required Map<String, String> env,
  required Iterable<String> devDependencies,
}) {
  final patrolWired = devDependencies.any((dep) => dep == 'patrol');
  if (!patrolWired) return PushDeliveryHarnessState.deferredPatrolMissing;
  final required = <String>[
    'PATROL_DEVICE_A_ID',
    'PATROL_DEVICE_B_ID',
    'PROXY_URL',
    'PROXY_OPERATOR_TOKEN_A',
    'PROXY_OPERATOR_TOKEN_B',
  ];
  for (final key in required) {
    final value = env[key]?.trim();
    if (value == null || value.isEmpty) {
      return PushDeliveryHarnessState.deferredEnvMissing;
    }
  }
  final proxyUrl = env['PROXY_URL']!.trim();
  final urlOk = kPushDeliveryAllowedProxySubstrings.any(
    (sub) => proxyUrl.contains(sub),
  );
  if (!urlOk) return PushDeliveryHarnessState.deferredProxyValidationFailed;
  return PushDeliveryHarnessState.ready;
}

/// Builds the structured "skipped" log line for the supplied state.
Map<String, Object?> buildSkippedLine({
  required PushDeliveryHarnessState state,
  required DateTime ts,
}) {
  final reason = switch (state) {
    PushDeliveryHarnessState.deferredPatrolMissing =>
      'Patrol/Flutter mobile test infra not wired — '
          'add patrol + patrol_finders to dev_dependencies, '
          'wire test devices, and re-run',
    PushDeliveryHarnessState.deferredEnvMissing =>
      'one of PATROL_DEVICE_A_ID / PATROL_DEVICE_B_ID / PROXY_URL / '
          'PROXY_OPERATOR_TOKEN_A / PROXY_OPERATOR_TOKEN_B is unset',
    PushDeliveryHarnessState.deferredProxyValidationFailed =>
      'PROXY_URL must contain one of '
          '${kPushDeliveryAllowedProxySubstrings.join(", ")} — '
          'refusing to drive production from a pressure harness',
    PushDeliveryHarnessState.ready =>
      'unreachable: ready state emits push_delivery.case, not '
          'push_delivery.skipped',
  };
  return <String, Object?>{
    'ts': ts.toIso8601String(),
    'metric': 'push_delivery.skipped',
    'state': state.name,
    'reason': reason,
  };
}

/// Statically declared dev-dependency identifiers. The harness reads
/// this list to decide whether Patrol is wired. The list MUST be kept
/// in sync with `pubspec.yaml`'s `dev_dependencies` block so the
/// readiness gate matches the repo's real test dependency posture.
///
/// Why static instead of parsing pubspec.yaml at runtime: parsing YAML
/// from a CLI tool would require pulling in `package:yaml`, which is
/// already a transitive dep but cleanly avoiding the import keeps this
/// harness self-contained. The maintenance cost is paid by the PR that
/// changes the test dependency graph.
const List<String> kDeclaredDevDependencies = <String>[
  // Synced with `pubspec.yaml` `dev_dependencies` as of 2026-05-27.
  'flutter_test',
  'flutter_driver',
  'patrol',
  'fake_async',
  'mockito',
  'build_runner',
  'flutter_lints',
];

/// Runs the harness end-to-end. Exposed so the CLI entry point and
/// future Dart-test invocations can both call it with controlled env +
/// output sink.
Future<int> runPushDeliveryProof({
  required Map<String, String> env,
  required IOSink output,
  required DateTime Function() clock,
  Iterable<String>? declaredDevDependencies,
}) async {
  final state = evaluatePushDeliveryState(
    env: env,
    devDependencies: declaredDevDependencies ?? kDeclaredDevDependencies,
  );

  if (state != PushDeliveryHarnessState.ready) {
    output.writeln(jsonEncode(buildSkippedLine(state: state, ts: clock())));
    // Always exit 0 on deferral so CI does not flag a missing-infra
    // skip as a regression. Operators learn about the deferral via the
    // structured log line; the lane evidence doc carries the prose.
    return 0;
  }

  // ----- READY branch: deliberately left as a placeholder -----
  //
  // When the full proof lands, this branch fans out into the two-device proof:
  //   1. Spin up Device A via `patrol` cli — sign-in operator-A.
  //   2. Spin up Device B — sign-in operator-B for the same operator
  //      tenant (or, for the bell-badge test, the same user across
  //      two devices).
  //   3. Trigger an `emitPushDelivery` from the proxy admin route
  //      (parallel to `p5_email_scenario_loopback.dart`'s
  //      admin-test-send pattern) OR call the push self-test endpoint
  //      `tool\advisor_proxy\mobile_push_notifications.dart`
  //      `RepositoryMobilePushSelfTestGateway`.
  //   4. Assert Device B's bell badge invalidates within
  //      `BELL_BADGE_SLO_SECONDS` (default 5s).
  //   5. Device A marks the inbox item read; assert Device B's bell
  //      decrements within the SLO budget.
  //   6. Emit `push_delivery.case` JSON line per device.
  //
  // STUB: emit a single "ready-but-unimplemented" line and fail the
  // command. Reaching this branch means all prerequisites are present;
  // returning 0 would falsely advertise a proof that did not run.
  output.writeln(
    jsonEncode(<String, Object?>{
      'ts': clock().toIso8601String(),
      'metric': 'push_delivery.not_implemented',
      'state': 'ready_but_unimplemented',
      'reason':
          'Patrol is wired and env is set, but the two-device proof '
          'body has not been ported yet. Follow-up slice required.',
    }),
  );
  return 2;
}

Future<void> main(List<String> args) async {
  final exitCode = await runPushDeliveryProof(
    env: Platform.environment,
    output: stdout,
    clock: () => DateTime.now().toUtc(),
  );
  await stdout.flush();
  exit(exitCode);
}
