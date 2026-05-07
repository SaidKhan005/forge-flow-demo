// `cutover.0` pre-flight — firewall reachability check.
//
// Confirms two things about the Production1 firewall posture:
//
//   1. The Postgres host accepts TCP connections from the configured
//      app subnet (the Cloud Run static-egress NAT IP). The check
//      records that the configured DSN connected successfully — if
//      the live `connectivityProbe` returned a green result for the
//      configured pool, the firewall lets the tester through; if
//      not, this check is yellow (the test environment may not be
//      whitelisted yet) but never red on its own.
//
//   2. The Postgres host REFUSES connections from `127.0.0.1` /
//      arbitrary unallowlisted IPs. Verifying this from inside the
//      harness requires the harness to ALREADY be running from a
//      not-on-allowlist origin, which is hard to guarantee. We
//      record this as a documentation-only requirement: the
//      runbook tells the operator to verify it via the Azure
//      portal rule list.
//
// Because firewall verification outside of a real network test is
// best-effort, the check is designed to either:
//
//   * Run a "connectivity probe" against the provided pool (a
//     trivial `select 1`) and report green if it succeeds; OR
//   * Skip and report yellow if `--skip-firewall` is set.
//
// The check is INJECTED with a `connectivityProbe` callback so unit
// tests can simulate connection success/failure without standing up
// real Postgres.

import 'dart:async';

import 'check_result.dart';

/// Signature for the connectivity probe. The harness CLI binds this
/// to a `pool.beginTransaction() → SELECT 1 → ROLLBACK` sequence;
/// tests pass a deterministic stub.
typedef ConnectivityProbe = Future<bool> Function();

class FirewallReachabilityCheck {
  FirewallReachabilityCheck({
    required this.connectivityProbe,
    this.allowlistedSubnetCidr,
  });

  /// Closure that opens a connection and runs `select 1`. Returns
  /// true if the round-trip succeeds, false otherwise.
  final ConnectivityProbe connectivityProbe;

  /// Optional documentation: the CIDR the operator says is
  /// allowlisted. We only echo it back into the JSON so the report
  /// includes the operator's stated posture; we don't try to
  /// re-verify it from inside the harness.
  final String? allowlistedSubnetCidr;

  static const String checkName = 'firewall_reachability';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    bool connected;
    try {
      connected = await connectivityProbe();
    } catch (error) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_firewall_reachability: probe threw '
            '${error.runtimeType}',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'allowlisted_subnet_cidr': allowlistedSubnetCidr,
        },
      );
    }
    stopwatch.stop();
    if (!connected) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_firewall_reachability: probe returned '
            'no rows or false',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'allowlisted_subnet_cidr': allowlistedSubnetCidr,
        },
      );
    }
    return CheckResult(
      name: checkName,
      status: CheckStatus.green,
      message:
          'firewall_reachability: TCP probe to Postgres succeeded; verify '
          '127.0.0.1 / non-allowlist origins are blocked via Azure portal '
          'firewall rule list (see runbook)',
      elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      details: <String, Object?>{
        if (allowlistedSubnetCidr != null)
          'allowlisted_subnet_cidr': allowlistedSubnetCidr,
      },
    );
  }
}
