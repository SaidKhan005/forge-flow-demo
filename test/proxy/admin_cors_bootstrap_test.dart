// HARD-C — bootstrap tests for the admin CORS allow-list resolver.
//
// Covers:
//   * ProxyConfig parses ADMIN_CORS_ALLOWED_ORIGINS (comma-split).
//   * ProxyConfig parses PROXY_ENVIRONMENT and lowercases it.
//   * resolveAdminCorsAllowList in dev/staging adds `localhost:*`.
//   * resolveAdminCorsAllowList in prod with empty env throws
//     ProxyConfigError carrying the contract event token
//     `admin_cors_allowlist_missing_in_prod` (translated to exit 78
//     by main.dart).
//   * resolveAdminCorsAllowList unions feature-flag extras.
//   * Cloud Run main.dart wiring — passes adminCorsAllowList into
//     routeRequest and prints the count in the diagnostics line.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

Map<String, String> _baseEnv({
  String? adminCorsAllowedOrigins,
  String? proxyEnvironment,
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
    ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto-envelope-key',
    ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
  };
  if (adminCorsAllowedOrigins != null) {
    env[ProxyConfigNames.adminCorsAllowedOrigins] = adminCorsAllowedOrigins;
  }
  if (proxyEnvironment != null) {
    env[ProxyConfigNames.proxyEnvironment] = proxyEnvironment;
  }
  return env;
}

void main() {
  group('ProxyConfig — admin CORS env parsing', () {
    test('comma-splits ADMIN_CORS_ALLOWED_ORIGINS, trims, drops blanks', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(
          adminCorsAllowedOrigins:
              ' https://admin.forgeandflow.app , https://admin-staging.forgeandflow.app ,, ',
        ),
      );

      expect(
        config.adminCorsAllowedOriginsFromEnv,
        equals(<String>[
          'https://admin.forgeandflow.app',
          'https://admin-staging.forgeandflow.app',
        ]),
      );
    });

    test('empty / unset ADMIN_CORS_ALLOWED_ORIGINS → empty list', () {
      final config = ProxyConfig.fromEnvironment(_baseEnv());
      expect(config.adminCorsAllowedOriginsFromEnv, isEmpty);

      final blankConfig = ProxyConfig.fromEnvironment(
        _baseEnv(adminCorsAllowedOrigins: '   '),
      );
      expect(blankConfig.adminCorsAllowedOriginsFromEnv, isEmpty);
    });

    test('PROXY_ENVIRONMENT trims and lowercases', () {
      final prod = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: 'PROD'),
      );
      expect(prod.proxyEnvironment, equals('prod'));

      final dev = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: ' dev '),
      );
      expect(dev.proxyEnvironment, equals('dev'));

      final unset = ProxyConfig.fromEnvironment(_baseEnv());
      expect(unset.proxyEnvironment, isNull);
    });
  });

  group('loadAdminCorsExtraOrigins — feature-flag-sourced extras', () {
    test('returns origins surfaced by the feature_flags row reader', () async {
      final result = await loadAdminCorsExtraOrigins(
        flag: const FixedAdminCorsOriginsExtraFlag(<String>[
          'https://preview-1.forgeandflow.app',
          'https://preview-2.forgeandflow.app',
        ]),
      );
      expect(
        result,
        equals(<String>[
          'https://preview-1.forgeandflow.app',
          'https://preview-2.forgeandflow.app',
        ]),
      );
    });

    test('returns empty list when flag yields nothing', () async {
      final result = await loadAdminCorsExtraOrigins(
        flag: const FixedAdminCorsOriginsExtraFlag.empty(),
      );
      expect(result, isEmpty);
    });

    test('reads exactly once per call (flag controls round-trip)', () async {
      var reads = 0;
      final flag = _RecordingFlag(
        origins: const <String>['https://preview.forgeandflow.app'],
        onRead: () {
          reads++;
        },
      );
      final result = await loadAdminCorsExtraOrigins(flag: flag);
      expect(result, equals(<String>['https://preview.forgeandflow.app']));
      expect(reads, equals(1));
    });
  });

  group('FeatureFlagsTableAdminCorsOriginsExtraFlag — query shape', () {
    test('production reader queries enabled + description from '
        'feature_flags by flag_name = admin_cors_origins_extra', () {
      // The reader is the contract-named source, so the SQL it
      // issues is part of the contract surface. Source-grep
      // catches drift when someone refactors the column list,
      // table name, or filter.
      final source = File(
        'tool/advisor_proxy/proxy_bootstrap.dart',
      ).readAsStringSync();
      // SELECT clause includes both columns.
      expect(
        source,
        contains('select enabled, description from public.feature_flags'),
      );
      // Filter pins flag_name to the contract-named row.
      expect(
        source,
        contains("flag_name = '\$kAdminCorsOriginsExtraFlagName'"),
      );
      // Constant matches the contract.
      expect(
        source,
        contains(
          "const String kAdminCorsOriginsExtraFlagName = "
          "'admin_cors_origins_extra'",
        ),
      );
      // Global scope only — operator/location-scoped rows do not
      // bleed into the platform allow-list.
      expect(source, contains('and operator_id is null'));
      expect(source, contains('and location_id is null'));
    });
  });

  group('resolveAdminCorsAllowList — dev / staging fallback', () {
    test('dev with no env entries adds local browser origins', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: 'dev'),
      );
      final result = resolveAdminCorsAllowList(config);
      expect(result, contains('http://localhost:*'));
      expect(result, contains('http://127.0.0.1:*'));
    });

    test('staging with env entries unions local browser origins', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(
          adminCorsAllowedOrigins: 'https://admin-staging.forgeandflow.app',
          proxyEnvironment: 'staging',
        ),
      );
      final result = resolveAdminCorsAllowList(config);
      expect(result, contains('https://admin-staging.forgeandflow.app'));
      expect(result, contains('http://localhost:*'));
      expect(result, contains('http://127.0.0.1:*'));
    });

    test('prod with non-empty env entries does NOT add local origins', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(
          adminCorsAllowedOrigins: 'https://admin.forgeandflow.app',
          proxyEnvironment: 'prod',
        ),
      );
      final result = resolveAdminCorsAllowList(config);
      expect(result, equals(<String>['https://admin.forgeandflow.app']));
      expect(result, isNot(contains('http://localhost:*')));
      expect(result, isNot(contains('http://127.0.0.1:*')));
    });

    test('feature-flag extras are merged (de-duplicated)', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(
          adminCorsAllowedOrigins: 'https://admin.forgeandflow.app',
          proxyEnvironment: 'prod',
        ),
      );
      final result = resolveAdminCorsAllowList(
        config,
        featureFlagExtras: const <String>[
          'https://preview.forgeandflow.app',
          'https://admin.forgeandflow.app', // duplicate, must collapse
        ],
      );
      expect(result.length, equals(2));
      expect(result, contains('https://admin.forgeandflow.app'));
      expect(result, contains('https://preview.forgeandflow.app'));
    });
  });

  group('resolveAdminCorsAllowList — prod fail-closed', () {
    test('prod with empty allow-list throws ProxyConfigError carrying '
        'admin_cors_allowlist_missing_in_prod', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: 'prod'),
      );

      Object? thrown;
      try {
        resolveAdminCorsAllowList(config);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProxyConfigError>());
      final err = thrown! as ProxyConfigError;
      expect(err.message, contains('admin_cors_allowlist_missing_in_prod'));
      expect(
        err.missingSecretNames,
        contains(ProxyConfigNames.adminCorsAllowedOrigins),
      );
    });

    test('prod with empty env but feature-flag extras succeeds', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: 'prod'),
      );
      final result = resolveAdminCorsAllowList(
        config,
        featureFlagExtras: const <String>['https://preview.forgeandflow.app'],
      );
      expect(result, equals(<String>['https://preview.forgeandflow.app']));
    });

    test('non-prod environment never fails closed', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(proxyEnvironment: 'dev'),
      );
      final result = resolveAdminCorsAllowList(config);
      // Localhost keeps the list non-empty in dev/staging.
      expect(result, isNotEmpty);
    });

    test('unset PROXY_ENVIRONMENT with empty allow-list fails closed', () {
      // P1 — an unset PROXY_ENVIRONMENT must NOT silently grant the
      // localhost fallback. A misconfigured prod deploy that forgets
      // to set PROXY_ENVIRONMENT must fail closed instead.
      final config = ProxyConfig.fromEnvironment(_baseEnv());
      Object? thrown;
      try {
        resolveAdminCorsAllowList(config);
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyConfigError>());
      final err = thrown! as ProxyConfigError;
      expect(err.message, contains('admin_cors_allowlist_missing_in_prod'));
    });

    test('misspelled PROXY_ENVIRONMENT (e.g. `production`) fails closed', () {
      // P1 — only the canonical `dev` / `staging` strings unlock
      // the localhost fallback. A typo or alternate spelling must
      // be treated as production-equivalent.
      for (final misspelled in const <String>[
        'production',
        'PRD',
        'qa',
        'preview',
        '',
      ]) {
        final config = ProxyConfig.fromEnvironment(
          _baseEnv(proxyEnvironment: misspelled),
        );
        Object? thrown;
        try {
          resolveAdminCorsAllowList(config);
        } catch (error) {
          thrown = error;
        }
        expect(
          thrown,
          isA<ProxyConfigError>(),
          reason:
              'PROXY_ENVIRONMENT="$misspelled" must fail closed when '
              'the env-var allow-list is empty',
        );
      }
    });

    test('unknown PROXY_ENVIRONMENT does NOT add localhost', () {
      final config = ProxyConfig.fromEnvironment(
        _baseEnv(
          adminCorsAllowedOrigins: 'https://admin.forgeandflow.app',
          proxyEnvironment: 'production', // misspelling
        ),
      );
      final result = resolveAdminCorsAllowList(config);
      expect(result, equals(<String>['https://admin.forgeandflow.app']));
      expect(result, isNot(contains('http://localhost:*')));
    });
  });

  group('Cloud Run entrypoint wiring — main.dart', () {
    test('passes adminCorsAllowList into routeRequest', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();

      expect(
        source,
        matches(RegExp(r'adminCorsAllowList:\s*adminCorsAllowList')),
      );
    });

    test('main.dart calls resolveAdminCorsAllowList during startup', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(source, contains('resolveAdminCorsAllowList('));
    });

    test('main.dart awaits loadAdminCorsExtraOrigins from feature flag', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(source, contains('await loadAdminCorsExtraOrigins('));
      expect(source, contains('productionBindings.adminCorsOriginsExtraFlag'));
      expect(source, contains('featureFlagExtras: adminCorsExtraOrigins'));
    });

    test('main.dart logs admin_cors_allow_list_count diagnostics line', () {
      final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
      expect(source, contains('admin_cors_allow_list_count:'));
    });

    test(
      'main.dart catches ProxyConfigError from the resolver and exits 78',
      () {
        // The resolver call sits inside the same try/catch as
        // buildProxyProductionBindings; both paths exit 78 on
        // ProxyConfigError. Verify the resolver runs inside the
        // catch block by source inspection (the resolver runs after
        // buildProxyProductionBindings inside the same try, with
        // the await loadAdminCorsExtraOrigins step in between).
        final source = File('tool/advisor_proxy/main.dart').readAsStringSync();
        expect(
          source,
          matches(
            RegExp(
              r'try\s*\{[\s\S]*?'
              r'buildProxyProductionBindings\([\s\S]*?\);[\s\S]*?'
              r'resolveAdminCorsAllowList\(',
            ),
          ),
        );
        expect(source, contains('exitCode = 78'));
      },
    );
  });
}

/// Recording stub used to verify [loadAdminCorsExtraOrigins] makes
/// exactly one round-trip to the feature_flags source per call.
class _RecordingFlag implements AdminCorsOriginsExtraFlag {
  _RecordingFlag({required this.origins, required this.onRead});

  final List<String> origins;
  final void Function() onRead;

  @override
  Future<List<String>> read() async {
    onRead();
    return origins;
  }
}
