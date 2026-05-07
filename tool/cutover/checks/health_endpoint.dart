// `cutover.0` pre-flight — proxy `/health` endpoint smoke.
//
// Confirms the production Cloud Run proxy responds to `/health` with
// HTTP 200 and a body containing a known marker string. The probe
// proves three things at once:
//
//   1. The proxy revision is reachable from the harness's network
//      egress (DNS + TLS + Cloud Run routing).
//   2. The proxy can talk to its dependencies — the `/health` route's
//      production implementation pings Postgres before returning 200.
//   3. The deployed revision is the production proxy (not staging) —
//      the marker substring is documented in
//      `tool/advisor_proxy/proxy_bootstrap.dart` and never changes
//      across deploys, so a stale staging proxy responding under the
//      production hostname would still emit the marker BUT a non-proxy
//      service answering on the wrong path would not.
//
// Like every other check, the live behavior is fully injected: an
// abstract `HealthHttpProbe` returns the status code + body string
// (or throws), and tests pass a deterministic stub.

import 'dart:async';

import 'check_result.dart';

/// Default marker substring that the proxy `/health` route always
/// includes in its 200 response body. Mirrors the literal
/// `tool/advisor_proxy/proxy_bootstrap.dart` emits on a healthy
/// startup.
const String kDefaultHealthBodyMarker = 'forge-flow';

/// Shape of an HTTP response captured by [HealthHttpProbe]. Kept
/// minimal so the harness never has to depend on a specific HTTP
/// client at the seam level.
class HealthProbeResponse {
  const HealthProbeResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

/// Signature for the HTTP probe used by [HealthEndpointCheck]. The
/// harness CLI binds this to a `package:http` GET against
/// `${PROXY_BASE_URI}/health`; tests pass a deterministic stub.
typedef HealthHttpProbe = Future<HealthProbeResponse> Function(Uri uri);

class HealthEndpointCheck {
  HealthEndpointCheck({
    required this.healthUri,
    required this.probe,
    this.bodyMarker = kDefaultHealthBodyMarker,
  });

  /// Fully-qualified URI to the proxy's `/health` route. Threaded
  /// from the CLI's `--proxy-base-uri` flag (or `PROXY_BASE_URI`
  /// env var).
  final Uri healthUri;

  /// HTTP probe. CLI binds to a real client; tests inject a fake.
  final HealthHttpProbe probe;

  /// Substring the response body must contain. Defaults to
  /// [kDefaultHealthBodyMarker].
  final String bodyMarker;

  static const String checkName = 'health_endpoint';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    final HealthProbeResponse response;
    try {
      response = await probe(healthUri);
    } catch (error) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_health_endpoint: probe to $healthUri '
            'threw ${error.runtimeType}',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'health_uri': healthUri.toString(),
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
    stopwatch.stop();
    if (response.statusCode != 200) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_health_endpoint: $healthUri returned '
            'status ${response.statusCode} (expected 200)',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'health_uri': healthUri.toString(),
          'status_code': response.statusCode,
        },
      );
    }
    if (!response.body.contains(bodyMarker)) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_health_endpoint: 200 response from '
            '$healthUri did not contain marker "$bodyMarker"',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'health_uri': healthUri.toString(),
          'status_code': response.statusCode,
          'body_marker': bodyMarker,
          'body_length': response.body.length,
        },
      );
    }
    return CheckResult(
      name: checkName,
      status: CheckStatus.green,
      message:
          'health_endpoint: $healthUri returned 200 with body marker '
          '"$bodyMarker"',
      elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      details: <String, Object?>{
        'health_uri': healthUri.toString(),
        'status_code': response.statusCode,
        'body_marker': bodyMarker,
      },
    );
  }
}
