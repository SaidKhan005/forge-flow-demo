// `cutover.0` pre-flight — Secret Manager reachability check.
//
// Confirms the Cloud Run service account configured for Production1
// can read the Production Secret Manager namespace. The harness
// itself is most often run from an operator workstation that does
// NOT carry production GCP credentials, so the check is designed to
// be SKIPPABLE by default — operator passes `--skip-secrets` to
// skip outright (yellow), or wires up a real `secretRead` callback
// that calls `gcloud secrets versions access` (or an equivalent SDK
// invocation) when production credentials are available.
//
// Like every other check, the live behavior is fully injected:
// `secretRead` returns true for "secret name X is readable" and
// false for "secret name X is not readable / unauthorized." The
// runner aggregates per-name verdicts and reports red if any
// required secret is unreadable.

import 'dart:async';

import 'check_result.dart';

/// Default required secret names. Mirrors the production env vars
/// the proxy wiring binds via `secretFor(...)`.
const List<String> kDefaultRequiredProductionSecrets = <String>[
  'forge-flow-production-postgres-url',
  'forge-flow-production-anthropic-api-key',
  'forge-flow-production-voyage-api-key',
  'forge-flow-production-firebase-web-api-key',
];

/// Signature for the secret-read probe. Returns true if the
/// configured service account can read the named secret, false
/// otherwise. Implementations may throw on transient network
/// errors; the check converts the exception into red.
typedef SecretReadProbe = Future<bool> Function(String secretName);

class SecretManagerReachabilityCheck {
  SecretManagerReachabilityCheck({
    required this.secretRead,
    List<String>? requiredSecrets,
    this.skipped = false,
    this.skipReason,
  }) : requiredSecrets = requiredSecrets ?? kDefaultRequiredProductionSecrets;

  final SecretReadProbe secretRead;
  final List<String> requiredSecrets;
  final bool skipped;
  final String? skipReason;

  static const String checkName = 'secret_manager_reachability';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    if (skipped) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.yellow,
        message:
            'secret_manager_reachability: skipped (${skipReason ?? "no reason given"})',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'skipped': true,
          'required_secret_count': requiredSecrets.length,
        },
      );
    }
    final unreadable = <String>[];
    final errors = <String, String>{};
    for (final name in requiredSecrets) {
      try {
        final ok = await secretRead(name);
        if (!ok) unreadable.add(name);
      } catch (error) {
        unreadable.add(name);
        errors[name] = error.runtimeType.toString();
      }
    }
    stopwatch.stop();
    if (unreadable.isEmpty) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'secret_manager_reachability: all '
            '${requiredSecrets.length} required secrets readable',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'required_secret_count': requiredSecrets.length,
        },
      );
    }
    return CheckResult(
      name: checkName,
      status: CheckStatus.red,
      message:
          'cutover_preflight_red_secret_manager_reachability: '
          '${unreadable.length} of ${requiredSecrets.length} secret(s) '
          'unreadable',
      elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      details: <String, Object?>{
        'unreadable_secret_names': unreadable,
        if (errors.isNotEmpty) 'errors_by_name': errors,
      },
    );
  }
}
