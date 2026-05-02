// HARD-A — `tool/advisor_proxy/main.dart` startup wiring.
//
// The actual `Future<void> main()` binds a socket and falls into a
// request loop, so we exercise the testable surface it delegates to:
// [evaluateProxyStartup] (decides whether prod needs to fail closed)
// and a source-grep over `main.dart` (proves the bindings + diagnostics
// flow through the runtime in the right places).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

ProxyConfig _configFromEnv({
  Map<String, String> overrides = const <String, String>{},
}) {
  final env = <String, String>{
    ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
    ProxySecretNames.voyageApiKey: 'placeholder-voyage',
    ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
    ProxySecretNames.postgresAdminUrl:
        'postgres://admin-role.example/forgeflow',
    ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
    ProxySecretNames.servicePrincipalJwtSecret:
        'placeholder-service-principal-jwt-secret',
    ...overrides,
  };
  return ProxyConfig.fromEnvironment(env);
}

void main() {
  group('evaluateProxyStartup — PROXY_ENVIRONMENT=prod fail-closed', () {
    test(
      'PROXY_ENVIRONMENT=prod with FIREBASE_PROJECT_ID unset returns '
      'EX_CONFIG (78) and the contracted stderr line',
      () {
        final config = _configFromEnv();
        // Sanity: config still parses, FIREBASE_PROJECT_ID is just absent.
        expect(config.firebaseProjectId, isNull);

        final failure = evaluateProxyStartup(
          config: config,
          environment: <String, String>{'PROXY_ENVIRONMENT': 'prod'},
        );

        expect(failure, isNotNull);
        expect(failure!.exitCode, equals(78));
        expect(
          failure.message,
          equals('startup_failure: firebase_project_id_required_in_prod'),
        );
      },
    );

    test(
      'PROXY_ENVIRONMENT=prod with FIREBASE_PROJECT_ID set returns null '
      '(proxy continues to bind)',
      () {
        final config = _configFromEnv(overrides: <String, String>{
          ProxyConfigNames.firebaseProjectId: 'forge-flow-prod',
        });
        expect(config.firebaseProjectId, equals('forge-flow-prod'));

        final failure = evaluateProxyStartup(
          config: config,
          environment: <String, String>{'PROXY_ENVIRONMENT': 'prod'},
        );

        expect(failure, isNull);
      },
    );

    test(
      'PROXY_ENVIRONMENT=staging with FIREBASE_PROJECT_ID unset preserves '
      'the scaffold-fallback (no fail-closed)',
      () {
        final config = _configFromEnv();
        final failure = evaluateProxyStartup(
          config: config,
          environment: <String, String>{'PROXY_ENVIRONMENT': 'staging'},
        );
        expect(failure, isNull);
      },
    );

    test(
      'PROXY_ENVIRONMENT=dev with FIREBASE_PROJECT_ID unset preserves '
      'the scaffold-fallback (no fail-closed)',
      () {
        final config = _configFromEnv();
        final failure = evaluateProxyStartup(
          config: config,
          environment: <String, String>{'PROXY_ENVIRONMENT': 'dev'},
        );
        expect(failure, isNull);
      },
    );

    test(
      'PROXY_ENVIRONMENT unset with FIREBASE_PROJECT_ID unset preserves '
      'the scaffold-fallback (no fail-closed)',
      () {
        final config = _configFromEnv();
        final failure = evaluateProxyStartup(
          config: config,
          environment: const <String, String>{},
        );
        expect(failure, isNull);
      },
    );

    test('PROXY_ENVIRONMENT match is case-insensitive and trims whitespace',
        () {
      final config = _configFromEnv();
      final failure = evaluateProxyStartup(
        config: config,
        environment: <String, String>{'PROXY_ENVIRONMENT': '  PROD  '},
      );
      expect(failure, isNotNull);
      expect(failure!.exitCode, equals(78));
    });
  });

  group('main.dart entrypoint surface (source assertions)', () {
    String readMainSource() =>
        File('tool/advisor_proxy/main.dart').readAsStringSync();

    test(
      'wires productionBindings.usageCounterStore into ProxyUsageGuard',
      () {
        expect(
          readMainSource(),
          contains('store: productionBindings.usageCounterStore'),
        );
      },
    );

    test('wires productionBindings.healthCheckStore into the runtime', () {
      final source = readMainSource();
      expect(source, contains('productionBindings.healthCheckStore'));
      // And the runtime call passes it into routeRequest.
      expect(source, contains('healthCheckStore: healthCheckStore'));
    });

    test(
      'no longer references the scaffold-failing usage / health stores',
      () {
        final source = readMainSource();
        expect(
          source.contains('ScaffoldFailingUsageCounterStore'),
          isFalse,
        );
        expect(
          source.contains('ScaffoldFailingProxyHealthCheckStore'),
          isFalse,
        );
      },
    );

    test('emits gemini_slot_enabled diagnostics line', () {
      final source = readMainSource();
      expect(
        source,
        contains(
          "'gemini_slot_enabled: \${productionBindings.geminiSlotEnabled}'",
        ),
      );
    });

    test(
      'top-of-file comment references real Anthropic primary + optional '
      'real Gemini secondary',
      () {
        final source = readMainSource();
        // The top-of-file block has been retargeted to describe the
        // post-Lock-7 reality: real Anthropic primary + optional real
        // Gemini secondary, not the rejecting scaffold provider.
        // Substrings are kept short so comment line wrapping cannot
        // accidentally break them up.
        expect(source, contains('real Anthropic'));
        expect(source, contains('real Gemini'));
        expect(source, contains('GEMINI_API_KEY'));
        expect(
          source.contains('ScaffoldRejectingProxyLlmProvider'),
          isFalse,
          reason:
              'main.dart top-of-file comment should no longer reference '
              'the removed ScaffoldRejectingProxyLlmProvider',
        );
      },
    );
  });
}
