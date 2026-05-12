// Operator-web deploy script contract tests.
//
// These text-level guards keep preview operator-web deploys aligned with the
// proxy CORS contract. They do not execute gcloud or mutate Cloud Run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deploy_operator_web.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_operator_web.ps1').readAsStringSync();
    });

    test('infers the matching preview proxy service for CORS updates', () {
      expect(script, contains('function Resolve-PreviewProxyCorsServiceName'));
      expect(script, contains("'forge-flow-preview-'"));
      expect(script, contains("'-operator-web'"));
      expect(script, contains("'-proxy'"));
      expect(
        script,
        contains(
          'Resolve-PreviewProxyCorsServiceName -OperatorWebService '
          r'$Service',
        ),
      );
    });

    test('prefers the PowerShell gcloud wrapper for env-var escaping', () {
      expect(script, contains('gcloud.ps1'));
      expect(script, contains('gcloud.cmd'));
    });

    test('supports explicit or skipped proxy CORS updates', () {
      expect(script, contains('[string] \$ProxyCorsService = '));
      expect(script, contains('[switch] \$SkipProxyCorsUpdate'));
      expect(script, contains('Operator-web proxy CORS update skipped.'));
      expect(
        script,
        contains('pass -ProxyCorsService to update a non-preview proxy'),
      );
    });

    test('loads Firebase web config and requires it to match project', () {
      expect(
        script,
        contains("[string] \$FirebaseConfigPath = 'web\\firebase-config.js'"),
      );
      expect(script, contains('function Resolve-FirebaseWebConfig'));
      expect(
        script,
        contains(
          'BLOCKED: Firebase web config projectId does not match '
          'deploy project.',
        ),
      );
      expect(script, contains('-ExpectedProject \$Project'));
    });

    test('blocks mismatched Cloud Run service account project', () {
      expect(script, contains('function Assert-ServiceAccountProject'));
      expect(
        script,
        contains(
          'BLOCKED: Cloud Run service account project does not match '
          'deploy project.',
        ),
      );
      expect(script, contains('-DeployServiceAccount \$ServiceAccount'));
    });

    test('passes Firebase web build args through Cloud Build', () {
      for (final arg in <String>[
        'FIREBASE_WEB_API_KEY',
        'FIREBASE_WEB_APP_ID',
        'FIREBASE_MESSAGING_SENDER_ID',
        'FIREBASE_PROJECT_ID',
        'FIREBASE_AUTH_DOMAIN',
        'FIREBASE_STORAGE_BUCKET',
      ]) {
        expect(script, contains('"$arg='));
      }
    });

    test(
      'appends the operator-web origin without dropping existing origins',
      () {
        expect(script, contains('function Join-CorsOriginList'));
        expect(script, contains('function Get-ProxyCorsAllowedOrigins'));
        expect(script, contains('ADMIN_CORS_ALLOWED_ORIGINS'));
        expect(script, contains('Update-ProxyCorsForOperatorWeb'));
        expect(script, contains(r'$currentOrigins'));
        expect(script, contains(r'$OperatorWebUrl'));
      },
    );

    test('updates Cloud Run env with a comma-safe delimiter', () {
      expect(script, contains('--update-env-vars'));
      expect(
        script,
        contains(r'$updateEnvVarsArg = "^@^ADMIN_CORS_ALLOWED_ORIGINS='),
      );
      expect(script, contains('CORS origin list contains the Cloud SDK env'));
    });

    test('verifies operator auth CORS against the deployed proxy', () {
      expect(script, contains('function Assert-OperatorWebProxyCors'));
      expect(script, contains('/v1/auth/account'));
      expect(script, contains("'Access-Control-Request-Method' = 'GET'"));
      expect(script, contains('Operator-web CORS preflight: 204'));
    });
  });
}
