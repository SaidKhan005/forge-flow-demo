// 11a.10a — Advisor proxy ProxyConfig + Firebase project-id tests.
//
// Bucket 5c-config of the 2026-05-20 test-suite tightening audit: split
// out of `test/advisor_proxy_test.dart` (8,328 lines). This file holds
// the configuration-parsing groups, including the Phase 11A.4c GCP /
// Cloud Run all-or-nothing rule, Phase 8 vendor app credential bundles,
// and the 9.1 firebaseProjectId getter.

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('ProxyConfig.fromEnvironment', () {
    Map<String, String> environmentWithAllSecrets({String? port}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        ProxySecretNames.pgcryptoEnvelopeKey:
            'placeholder-pgcrypto-envelope-key',
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
        if (port != null) 'PORT': port,
      };
    }

    test('loads all required secrets and reports their names only', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '9090'),
      );

      expect(config.port, equals(9090));
      expect(
        config.loadedSecretNames,
        containsAll(<String>[
          ProxySecretNames.anthropicApiKey,
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresUrl,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
          ProxySecretNames.pgcryptoEnvelopeKey,
          ProxySecretNames.publicBaseUri,
        ]),
      );
      expect(config.hasSecretFor(ProxySecretNames.anthropicApiKey), isTrue);
    });

    test('defaults port to 8080 when PORT is missing or invalid', () {
      final missing = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      final blank = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '   '),
      );
      final negative = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '-7'),
      );
      final huge = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: '70000'),
      );
      final notNumeric = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(port: 'eighty'),
      );

      for (final config in <ProxyConfig>[
        missing,
        blank,
        negative,
        huge,
        notNumeric,
      ]) {
        expect(config.port, equals(8080));
      }
    });

    test('throws ProxyConfigError listing missing secret names', () {
      final partial = <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        // VOYAGE_API_KEY missing
        ProxySecretNames.postgresUrl: 'placeholder-url',
        ProxySecretNames.postgresAdminUrl: '   ', // blank counts
        // FIREBASE_WEB_API_KEY missing
        // SERVICE_PRINCIPAL_JWT_SECRET missing
      };

      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(partial);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<ProxyConfigError>());
      final error = thrown! as ProxyConfigError;
      expect(
        error.missingSecretNames,
        containsAll(<String>[
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
        ]),
      );
      expect(
        error.missingSecretNames,
        isNot(contains(ProxySecretNames.anthropicApiKey)),
      );
      expect(error.message, contains('missing'));
      expect(error.message, contains(ProxySecretNames.voyageApiKey));
    });

    test('toString and ProxyConfigError never echo secret values', () {
      // Marker token chosen so the assertion catches any accidental
      // echo even in partial/derived forms.
      const marker = 'do-not-leak-this-marker-token';
      final environment = <String, String>{
        ProxySecretNames.anthropicApiKey: marker,
        ProxySecretNames.voyageApiKey: marker,
        ProxySecretNames.postgresUrl: marker,
        ProxySecretNames.postgresAdminUrl: marker,
        ProxySecretNames.firebaseWebApiKey: marker,
        ProxySecretNames.servicePrincipalJwtSecret: marker,
        ProxySecretNames.pgcryptoEnvelopeKey: marker,
        // publicBaseUri is required in ProxySecretNames.required, but
        // its [ProxyConfig.publicBaseUri] getter parses + validates the
        // URI shape. Use a real URL here so the loader does not reject
        // boot; the value is still asserted not to leak below.
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
      };

      final config = ProxyConfig.fromEnvironment(environment);
      expect(config.toString(), isNot(contains(marker)));
      expect(config.toString(), contains(ProxySecretNames.anthropicApiKey));

      // Missing-secret exception path also must not leak partial values.
      Object? thrown;
      try {
        ProxyConfig.fromEnvironment(<String, String>{
          ProxySecretNames.anthropicApiKey: marker,
          // others missing
        });
      } catch (error) {
        thrown = error;
      }
      expect(thrown, isA<ProxyConfigError>());
      expect(thrown.toString(), isNot(contains(marker)));
    });

    test('secretFor returns the loaded value but is the only accessor that '
        'returns it (callers must not log it)', () {
      final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());

      // Smoke: the value comes back through the explicit accessor —
      // no toString / no JSON / no iteration. Test reads it once and
      // does not write it anywhere.
      final value = config.secretFor(ProxySecretNames.anthropicApiKey);
      expect(value.isNotEmpty, isTrue);

      expect(
        () => config.secretFor('NEVER_REGISTERED_SECRET'),
        throwsStateError,
      );
    });

    group('Phase 11A.4c — GCP / Cloud Run config is all-or-nothing', () {
      test('all three unset → boots cleanly (dev / scaffold path)', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.gcpProjectId, isNull);
        expect(config.cloudRunRegion, isNull);
        expect(config.cloudRunServiceName, isNull);
      });

      test('all three set → boots cleanly with the values trimmed', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-prod'
          ..[ProxyConfigNames.cloudRunRegion] = 'northamerica-northeast2'
          ..[ProxyConfigNames.cloudRunServiceName] = 'forge-flow-advisor-proxy';

        final config = ProxyConfig.fromEnvironment(env);

        expect(config.gcpProjectId, equals('forge-flow-prod'));
        expect(config.cloudRunRegion, equals('northamerica-northeast2'));
        expect(config.cloudRunServiceName, equals('forge-flow-advisor-proxy'));
      });

      test('only GCP_PROJECT_ID set → throws ProxyConfigError listing the '
          'two missing names (would silently skip Cloud Run restarts)', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'forge-flow-prod';

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          containsAll(<String>[
            ProxyConfigNames.cloudRunRegion,
            ProxyConfigNames.cloudRunServiceName,
          ]),
        );
        expect(error.missingSecretNames, hasLength(2));
        expect(error.message, contains('GCP / Cloud Run config is partial'));
      });

      test('CLOUD_RUN_REGION set without GCP_PROJECT_ID → throws', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.cloudRunRegion] = 'northamerica-northeast2';

        expect(
          () => ProxyConfig.fromEnvironment(env),
          throwsA(isA<ProxyConfigError>()),
        );
      });

      test('two of three set → still throws, names the missing one', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = 'p'
          ..[ProxyConfigNames.cloudRunRegion] = 'r';
        // CLOUD_RUN_SERVICE_NAME deliberately missing.

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          equals(<String>[ProxyConfigNames.cloudRunServiceName]),
        );
      });

      test('blank-string values count as unset', () {
        final env = environmentWithAllSecrets()
          ..[ProxyConfigNames.gcpProjectId] = '   '
          ..[ProxyConfigNames.cloudRunRegion] = 'r'
          ..[ProxyConfigNames.cloudRunServiceName] = 's';

        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          equals(<String>[ProxyConfigNames.gcpProjectId]),
        );
      });
    });

    group('Phase 8 framework — vendor app credentials', () {
      test('PGCRYPTO_ENVELOPE_KEY is required; missing throws and lists '
          'it in missingSecretNames', () {
        final env = <String, String>{
          ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
          ProxySecretNames.voyageApiKey: 'placeholder-voyage',
          ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
          ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
          ProxySecretNames.firebaseWebApiKey:
              'placeholder-firebase-web-api-key',
          ProxySecretNames.servicePrincipalJwtSecret:
              'placeholder-service-principal-jwt-secret',
          // PGCRYPTO_ENVELOPE_KEY intentionally omitted.
        };
        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          contains(ProxySecretNames.pgcryptoEnvelopeKey),
        );
      });

      test('pgcryptoEnvelopeKey getter returns the loaded value', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(
          config.pgcryptoEnvelopeKey,
          equals('placeholder-pgcrypto-envelope-key'),
        );
      });

      test('Aloha NCR Voyix bundle is optional; absence keeps the proxy '
          'booting and `hasAlohaNcrVoyixCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasAlohaNcrVoyixCredentials, isFalse);
        expect(() => config.alohaNcrVoyixCredentials, throwsStateError);
      });

      test('Aloha NCR Voyix bundle materializes the typed record when all '
          'four secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.alohaNcrVoyixClientId] = 'aloha-client-id'
          ..[ProxySecretNames.alohaNcrVoyixClientSecret] = 'aloha-client-secret'
          ..[ProxySecretNames.alohaNcrVoyixApplicationKey] = 'aloha-app-key'
          ..[ProxySecretNames.alohaNcrVoyixOrganizationId] = 'aloha-org-id';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasAlohaNcrVoyixCredentials, isTrue);
        final creds = config.alohaNcrVoyixCredentials;
        expect(creds.clientId, equals('aloha-client-id'));
        expect(creds.clientSecret, equals('aloha-client-secret'));
        expect(creds.applicationKey, equals('aloha-app-key'));
        expect(creds.organizationId, equals('aloha-org-id'));
        // No on-prem relay override / explicit scope from the static
        // bundle — the binder relies on transport defaults.
        expect(creds.scope, isNull);
        expect(creds.baseUriOverride, isNull);
      });

      test('Square bundle materializes the typed record when all three '
          'secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.squareClientId] = 'square-client-id'
          ..[ProxySecretNames.squareClientSecret] = 'square-client-secret'
          ..[ProxySecretNames.squareNotificationUrlHost] =
              'webhooks.example.com';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasSquareAppCredentials, isTrue);
        final creds = config.squareAppCredentials;
        expect(creds.clientId, equals('square-client-id'));
        expect(creds.clientSecret, equals('square-client-secret'));
        expect(creds.notificationUrlHost, equals('webhooks.example.com'));
      });

      test('Square bundle is absent → `hasSquareAppCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasSquareAppCredentials, isFalse);
        expect(() => config.squareAppCredentials, throwsStateError);
      });

      test('Clover bundle materializes the typed record when both secrets '
          'load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.cloverAppToken] = 'clover-app-token'
          ..[ProxySecretNames.cloverAppId] = 'clover-app-id';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasCloverAppCredentials, isTrue);
        final creds = config.cloverAppCredentials;
        expect(creds.appToken, equals('clover-app-token'));
        expect(creds.appId, equals('clover-app-id'));
      });

      test('Clover bundle is absent → `hasCloverAppCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasCloverAppCredentials, isFalse);
        expect(() => config.cloverAppCredentials, throwsStateError);
      });

      test('partial Aloha bundle (one of four set) → '
          '`hasAlohaNcrVoyixCredentials` stays false; `alohaNcrVoyixCredentials` '
          'throws on the first missing secret', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.alohaNcrVoyixClientId] = 'aloha-client-id';
        // remaining three intentionally unset.
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasAlohaNcrVoyixCredentials, isFalse);
        expect(() => config.alohaNcrVoyixCredentials, throwsStateError);
      });

      // ─── Typed-app-credentials amendment ────────────────────────────
      // Mirrors the Aloha / Square / Clover patterns from PR #260 for
      // the four vendors the binder previously read from
      // Platform.environment directly: Humanity, QuickBooks Time,
      // 7shifts, Libro.

      test('Humanity bundle materializes the typed record when both '
          'secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.humanityClientId] = 'humanity-client-id'
          ..[ProxySecretNames.humanityClientSecret] = 'humanity-client-secret';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasHumanityAppCredentials, isTrue);
        final creds = config.humanityAppCredentials;
        expect(creds.clientId, equals('humanity-client-id'));
        expect(creds.clientSecret, equals('humanity-client-secret'));
      });

      test(
        'Humanity bundle is absent → `hasHumanityAppCredentials` is false',
        () {
          final config = ProxyConfig.fromEnvironment(
            environmentWithAllSecrets(),
          );
          expect(config.hasHumanityAppCredentials, isFalse);
          expect(() => config.humanityAppCredentials, throwsStateError);
        },
      );

      test('partial Humanity bundle (one of two set) → '
          '`hasHumanityAppCredentials` stays false', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.humanityClientId] = 'humanity-client-id';
        // client_secret intentionally unset.
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasHumanityAppCredentials, isFalse);
        expect(() => config.humanityAppCredentials, throwsStateError);
      });

      test('QuickBooks Time bundle materializes the typed record when '
          'both secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.quickBooksTimeClientId] = 'qbt-client-id'
          ..[ProxySecretNames.quickBooksTimeClientSecret] = 'qbt-client-secret';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasQuickBooksTimeAppCredentials, isTrue);
        final creds = config.quickBooksTimeAppCredentials;
        expect(creds.clientId, equals('qbt-client-id'));
        expect(creds.clientSecret, equals('qbt-client-secret'));
      });

      test('QuickBooks Time bundle is absent → '
          '`hasQuickBooksTimeAppCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasQuickBooksTimeAppCredentials, isFalse);
        expect(() => config.quickBooksTimeAppCredentials, throwsStateError);
      });

      test('7shifts bundle materializes the typed record when both '
          'secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.sevenShiftsClientId] = 'seven-shifts-client-id'
          ..[ProxySecretNames.sevenShiftsClientSecret] =
              'seven-shifts-client-secret';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasSevenShiftsAppCredentials, isTrue);
        final creds = config.sevenShiftsAppCredentials;
        expect(creds.clientId, equals('seven-shifts-client-id'));
        expect(creds.clientSecret, equals('seven-shifts-client-secret'));
      });

      test('7shifts bundle is absent → '
          '`hasSevenShiftsAppCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasSevenShiftsAppCredentials, isFalse);
        expect(() => config.sevenShiftsAppCredentials, throwsStateError);
      });

      test('Libro bundle materializes the typed record when both '
          'secrets load', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.libroClientId] = 'libro-client-id'
          ..[ProxySecretNames.libroClientSecret] = 'libro-client-secret';
        final config = ProxyConfig.fromEnvironment(env);
        expect(config.hasLibroAppCredentials, isTrue);
        final creds = config.libroAppCredentials;
        expect(creds.clientId, equals('libro-client-id'));
        expect(creds.clientSecret, equals('libro-client-secret'));
      });

      test('Libro bundle is absent → `hasLibroAppCredentials` is false', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        expect(config.hasLibroAppCredentials, isFalse);
        expect(() => config.libroAppCredentials, throwsStateError);
      });

      // ─── publicBaseUri ─────────────────────────────────────────────

      test('publicBaseUri parses the canonical production URL', () {
        final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
        // The shared helper sets `PUBLIC_BASE_URI=https://api.forgeflow.app`.
        expect(
          config.publicBaseUri,
          equals(Uri.parse('https://api.forgeflow.app')),
        );
        expect(config.publicBaseUri.scheme, equals('https'));
        expect(config.publicBaseUri.host, equals('api.forgeflow.app'));
      });

      test('publicBaseUri throws when the value does not parse as an '
          'absolute URI with scheme + host', () {
        final env = environmentWithAllSecrets()
          ..[ProxySecretNames.publicBaseUri] = 'not a url';
        final config = ProxyConfig.fromEnvironment(env);
        expect(() => config.publicBaseUri, throwsStateError);
      });

      test('PUBLIC_BASE_URI is required — boot fails with the missing '
          'secret name when the env var is unset', () {
        final env = environmentWithAllSecrets()
          ..remove(ProxySecretNames.publicBaseUri);
        Object? thrown;
        try {
          ProxyConfig.fromEnvironment(env);
        } catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ProxyConfigError>());
        final error = thrown! as ProxyConfigError;
        expect(
          error.missingSecretNames,
          contains(ProxySecretNames.publicBaseUri),
        );
      });
    });
  });

  group('ProxyConfig.firebaseProjectId (9.1)', () {
    Map<String, String> environmentWithAllSecrets({String? projectId}) {
      return <String, String>{
        ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
        ProxySecretNames.voyageApiKey: 'placeholder-voyage',
        ProxySecretNames.postgresUrl: 'placeholder-postgres-url',
        ProxySecretNames.postgresAdminUrl: 'placeholder-postgres-admin-url',
        ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
        ProxySecretNames.servicePrincipalJwtSecret:
            'placeholder-service-principal-jwt-secret',
        ProxySecretNames.pgcryptoEnvelopeKey:
            'placeholder-pgcrypto-envelope-key',
        ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
        if (projectId != null) ProxyConfigNames.firebaseProjectId: projectId,
      };
    }

    test('FIREBASE_PROJECT_ID absent -> null and proxy config still loads', () {
      final config = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      expect(config.firebaseProjectId, isNull);
      // Required secrets still validated; project ID is optional.
      expect(
        config.loadedSecretNames,
        containsAll(<String>[
          ProxySecretNames.anthropicApiKey,
          ProxySecretNames.voyageApiKey,
          ProxySecretNames.postgresUrl,
          ProxySecretNames.postgresAdminUrl,
          ProxySecretNames.firebaseWebApiKey,
          ProxySecretNames.servicePrincipalJwtSecret,
        ]),
      );
    });

    test('FIREBASE_PROJECT_ID blank -> null (treated like absent)', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: '   '),
      );
      expect(config.firebaseProjectId, isNull);
    });

    test('FIREBASE_PROJECT_ID present -> loaded and trimmed', () {
      final config = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: '  forge-flow-staging  '),
      );
      expect(config.firebaseProjectId, equals('forge-flow-staging'));
    });

    test('toString reports firebase_project_id by SET/UNSET marker only', () {
      const projectId = 'forge-flow-staging';
      final unset = ProxyConfig.fromEnvironment(environmentWithAllSecrets());
      final set = ProxyConfig.fromEnvironment(
        environmentWithAllSecrets(projectId: projectId),
      );
      expect(unset.toString(), contains('firebase_project_id: unset'));
      expect(set.toString(), contains('firebase_project_id: set'));
      // Even though the project ID is a public identifier we keep the
      // toString convention to "names-only" so log audit grep stays
      // simple — no value should appear in toString.
      expect(set.toString(), isNot(contains(projectId)));
    });
  });

}
