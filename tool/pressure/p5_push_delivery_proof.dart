// Pressure preview v1 — Slice C-11 (R4 §4B + §7C) — push-delivery proof
// harness STUB. The slice spec calls for a Patrol two-device test that
// asserts the bell-badge invalidation SLO (≤ 5s mark-read across two
// connected mobile devices, per inventory rollup §11.b + R4 §3B).
//
// Sprint authority:
//   * Slice spec: `docs/_execution/lane_c_parity/03_execution_slices.md`
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
// Current state: STUB (Patrol/Flutter mobile test infra NOT wired)
// -----------------------------------------------------------------
// Patrol is NOT a declared dev_dependency in `pubspec.yaml`. The Flutter
// mobile test infrastructure required to drive a two-device proof
// (Patrol + `nativeAutomatorConfig`, plus connected Android/iOS test
// hardware) is not present in this repo. Shipping a speculative Patrol
// harness body here would either (a) fail to compile (Patrol imports
// resolve to nothing) or (b) require expanding the dev_dependency graph
// for code that cannot run without external test hardware — both
// anti-`Build-Toward-Production` per the F&F doctrine (`feedback_production_not_backlog.md`).
//
// Instead, this file ships the env-gated-inert posture: when invoked,
// it emits ONE structured "deferred" log line citing the missing
// infrastructure and exits 0. The PR body + lane evidence doc disclose
// the deferral honestly so the operator's pressure-test inventory is
// not misled by a fabricated "green" record.
//
// What unblocks the full harness
// ------------------------------
//   1. Add `patrol: ^<version>` + `patrol_finders` to the
//      `dev_dependencies` block in `pubspec.yaml`.
//   2. Add `patrol` CLI tooling to the CI runners (Patrol's own
//      `setup-patrol` GitHub Action or equivalent).
//   3. Wire two test devices (emulators or physical) accessible to the
//      preview deployment's FCM project.
//   4. Provision two operator-test accounts whose `mobile_push_tokens`
//      can be observed in the preview Postgres instance.
//   5. Add a `PATROL_DEVICE_A_ID` + `PATROL_DEVICE_B_ID` env var pair
//      so the harness knows which two adb / xcode devices to target.
//   6. Wire `MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` dart-define for
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
//   { "ts": "<iso>", "metric": "push_delivery.skipped",
//     "reason": "Patrol/Flutter mobile test infra not wired" }
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
  final urlOk = kPushDeliveryAllowedProxySubstrings
      .any((sub) => proxyUrl.contains(sub));
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
/// in sync with `pubspec.yaml`'s `dev_dependencies` block — when Patrol
/// is added there, append `'patrol'` here (and the harness gains
/// access to the `ready` branch).
///
/// Why static instead of parsing pubspec.yaml at runtime: parsing YAML
/// from a CLI tool would require pulling in `package:yaml`, which is
/// already a transitive dep but cleanly avoiding the import keeps this
/// harness self-contained. The two-line maintenance cost is paid by the
/// PR that wires Patrol.
const List<String> kDeclaredDevDependencies = <String>[
  // Synced with `pubspec.yaml` `dev_dependencies` at C-11 land time
  // (2026-05-13). Patrol is intentionally absent — see file header.
  'flutter_test',
  'flutter_driver',
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
  // When Patrol lands, this branch fans out into the two-device proof:
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
  // STUB: we still emit a single "ready-but-unimplemented" line so the
  // operator sees the harness reached the active branch without
  // running. A follow-up slice replaces this body with the actual
  // Patrol calls.
  output.writeln(jsonEncode(<String, Object?>{
    'ts': clock().toIso8601String(),
    'metric': 'push_delivery.skipped',
    'state': 'ready_but_unimplemented',
    'reason': 'Patrol is wired and env is set, but the two-device proof '
        'body has not been ported yet. Follow-up slice required.',
  }));
  return 0;
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
