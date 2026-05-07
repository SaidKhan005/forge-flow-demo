// `cutover.0` pre-flight — DNS resolution check.
//
// Confirms that the production proxy / admin console / operator-web
// hostnames resolve to at least one A/AAAA record. Each hostname is
// resolved via an injected resolver callback; tests pass a
// deterministic stub, the CLI binds the callback to
// `InternetAddress.lookup`. Resolution failure is red; partial
// resolution (some names ok, others not) is also red so the report
// names every offender.

import 'dart:async';

import 'check_result.dart';

/// Signature for the DNS resolver. Returns the list of resolved IP
/// addresses (as strings) for the given hostname, or an empty list
/// if no records exist. May throw on lookup error.
typedef DnsResolver = Future<List<String>> Function(String hostname);

class DnsResolutionCheck {
  DnsResolutionCheck({
    required this.resolver,
    required this.hostnames,
  });

  final DnsResolver resolver;
  final List<String> hostnames;

  static const String checkName = 'dns_resolution';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    final resolved = <String, List<String>>{};
    final unresolved = <String>[];
    final errors = <String, String>{};
    for (final hostname in hostnames) {
      try {
        final addresses = await resolver(hostname);
        if (addresses.isEmpty) {
          unresolved.add(hostname);
        } else {
          resolved[hostname] = addresses;
        }
      } catch (error) {
        unresolved.add(hostname);
        errors[hostname] = error.runtimeType.toString();
      }
    }
    stopwatch.stop();
    if (unresolved.isEmpty) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'dns_resolution: all ${hostnames.length} hostname(s) resolved',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'resolved_hostname_count': resolved.length,
          'address_count_by_hostname':
              resolved.map((k, v) => MapEntry(k, v.length)),
        },
      );
    }
    return CheckResult(
      name: checkName,
      status: CheckStatus.red,
      message:
          'cutover_preflight_red_dns_resolution: '
          '${unresolved.length} of ${hostnames.length} hostname(s) '
          'failed to resolve',
      elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      details: <String, Object?>{
        'unresolved_hostnames': unresolved,
        if (errors.isNotEmpty) 'errors_by_hostname': errors,
      },
    );
  }
}
