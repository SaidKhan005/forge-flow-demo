// Phase 9 live-closeout - staging proxy deploy script contract tests.
//
// These are text-level guards for the PowerShell deploy helpers. They do not
// execute gcloud, read secrets, or mutate Cloud Run. The goal is to keep the
// local deploy contract aligned with ProxySecretNames.required so the next
// staging deploy cannot silently omit a required env name.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deploy_staging_proxy.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_staging_proxy.ps1').readAsStringSync();
    });

    test('requires FIREBASE_WEB_API_KEY for the Phase 9 route bindings', () {
      expect(script, contains("'FIREBASE_WEB_API_KEY'"));
      expect(
        script,
        contains(
          "'FIREBASE_WEB_API_KEY' = "
          "'forge-flow-staging-firebase-web-api-key'",
        ),
      );
      expect(script, contains('--set-secrets'));
      expect(script, isNot(contains('"FIREBASE_WEB_API_KEY: ')));
      expect(script, contains("Write-Host ' - FIREBASE_WEB_API_KEY'"));
    });

    test('requires SERVICE_PRINCIPAL_JWT_SECRET for B41 JWT issuance', () {
      expect(script, contains("'SERVICE_PRINCIPAL_JWT_SECRET'"));
      expect(
        script,
        contains(
          "'SERVICE_PRINCIPAL_JWT_SECRET' = "
          "'forge-flow-staging-service-principal-jwt-secret'",
        ),
      );
      expect(script, contains("Write-Host ' - SERVICE_PRINCIPAL_JWT_SECRET'"));
      expect(
        script,
        isNot(contains(r'Write-Host $env:SERVICE_PRINCIPAL_JWT_SECRET')),
      );
    });

    test('deploys secret values through Secret Manager references', () {
      expect(script, contains('secretmanager.googleapis.com'));
      expect(script, contains('function Sync-SecretManagerSecret'));
      expect(script, contains('gcloud secrets versions add'));
      expect(script, contains('roles/secretmanager.secretAccessor'));
      expect(script, contains('--set-secrets \$secretAssignments'));
      expect(script, contains('--set-env-vars \$envAssignments'));
      expect(
        script,
        contains(
          "Write-Host ' - Cloud Run secret env refs backed by Secret "
          "Manager'",
        ),
      );
      expect(script, isNot(contains('--env-vars-file')));
    });

    test('derives FIREBASE_WEB_API_KEY from forgeflow google-services when '
        'local env omits it', () {
      expect(script, contains('function Resolve-FirebaseWebApiKey'));
      expect(
        script,
        contains(
          r"Join-Path $repoRoot 'android\app\src\forgeflow\google-services.json'",
        ),
      );
      expect(script, contains('ConvertFrom-Json'));
      expect(script, contains(r'$apiKey.current_key'));
      expect(
        script,
        contains(
          "[Environment]::SetEnvironmentVariable('FIREBASE_WEB_API_KEY', "
          r"$key, 'Process')",
        ),
      );
      expect(
        script,
        contains('. \$SecretsFile'),
        reason: 'the script should load non-repo env before deriving fallback',
      );
      expect(script, contains('Resolve-FirebaseWebApiKey'));
    });
  });

  group('use_forge_flow_secrets.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/use_forge_flow_secrets.ps1').readAsStringSync();
    });

    test('reports FIREBASE_WEB_API_KEY by name only', () {
      expect(script, contains("'FIREBASE_WEB_API_KEY'"));
      expect(script, contains('PRESENT (name only - value not inspected)'));
      expect(script, isNot(contains(r'Write-Host $env:FIREBASE_WEB_API_KEY')));
    });

    test('reports SERVICE_PRINCIPAL_JWT_SECRET by name only', () {
      expect(script, contains("'SERVICE_PRINCIPAL_JWT_SECRET'"));
      expect(script, contains('PRESENT (name only - value not inspected)'));
      expect(
        script,
        isNot(contains(r'Write-Host $env:SERVICE_PRINCIPAL_JWT_SECRET')),
      );
    });

    test('shares the google-services fallback with the deploy script', () {
      expect(
        script,
        contains(
          r"Join-Path $repoRoot 'android\app\src\forgeflow\google-services.json'",
        ),
      );
      expect(script, contains('ConvertFrom-Json'));
      expect(script, contains(r'$apiKey.current_key'));
      expect(
        script,
        contains(
          "[Environment]::SetEnvironmentVariable('FIREBASE_WEB_API_KEY', "
          r"$key, 'Process')",
        ),
      );
    });
  });
}
