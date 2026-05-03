// Phase 9 live-closeout - staging proxy deploy script contract tests.
//
// These are text-level guards for the PowerShell deploy helpers. They do not
// execute gcloud, read secrets, or mutate Cloud Run. The goal is to keep the
// local deploy contract aligned with ProxySecretNames.required so the next
// deploy (staging or production) cannot silently omit a required env name.
//
// As of the multi-environment refactor, secret names are derived from a
// stable suffix map combined with a -SecretPrefix parameter (default
// 'forge-flow-staging-'). The contract here asserts both pieces — suffix
// map presence + default prefix — which together preserve the original
// staging guarantee while extending it to production deploys via the
// same parameterization pattern as scripts/deploy_audit_anchor_job.ps1.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('proxy Dockerfile', () {
    late String dockerfile;

    setUpAll(() {
      dockerfile = File('Dockerfile').readAsStringSync();
    });

    test('copies db/migrations into the build and runtime images', () {
      expect(dockerfile, contains('COPY db/migrations ./db/migrations'));
      expect(
        dockerfile,
        contains(
          'COPY --from=build --chown=app:app '
          '/workspace/db/migrations /app/db/migrations',
        ),
      );
    });
  });

  group('deploy_staging_proxy.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_staging_proxy.ps1').readAsStringSync();
    });

    test('declares -SecretPrefix parameter with staging default + dash guard',
        () {
      expect(
        script,
        contains("[string] \$SecretPrefix = 'forge-flow-staging-'"),
      );
      expect(
        script,
        contains("BLOCKED: -SecretPrefix '\$SecretPrefix' must end with '-'."),
      );
    });

    test('declares -ProxyBaseUriEnvVarName parameter with staging default',
        () {
      expect(
        script,
        contains(
          "[string] \$ProxyBaseUriEnvVarName = 'FORGE_FLOW_PROXY_BASE_URI'",
        ),
      );
    });

    test('declares -FirebaseGoogleServicesPath parameter (empty default)', () {
      expect(
        script,
        contains("[string] \$FirebaseGoogleServicesPath = ''"),
      );
    });

    test('supports optional VPC connector flags for first production deploys',
        () {
      expect(script, contains("[string] \$VpcConnector = ''"));
      expect(script, contains("[string] \$VpcEgress = 'all-traffic'"));
      expect(
        script,
        contains('BLOCKED: -VpcEgress is required when -VpcConnector is set.'),
      );
      expect(script, contains("'--vpc-connector', \$VpcConnector"));
      expect(script, contains("'--vpc-egress', \$VpcEgress"));
      expect(script, contains('VPC connector: \$VpcConnector (\$VpcEgress)'));
    });

    test('requires FIREBASE_WEB_API_KEY for the Phase 9 route bindings', () {
      expect(script, contains("'FIREBASE_WEB_API_KEY'"));
      expect(
        script,
        matches(
          RegExp(
            r"'FIREBASE_WEB_API_KEY'\s+=\s+'firebase-web-api-key'",
          ),
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
        matches(
          RegExp(
            r"'SERVICE_PRINCIPAL_JWT_SECRET'\s+=\s+'service-principal-jwt-secret'",
          ),
        ),
      );
      expect(script, contains("Write-Host ' - SERVICE_PRINCIPAL_JWT_SECRET'"));
      expect(
        script,
        isNot(contains(r'Write-Host $env:SERVICE_PRINCIPAL_JWT_SECRET')),
      );
    });

    test('derives secret names from -SecretPrefix + suffix map', () {
      expect(script, contains(r'$secretSuffix = [ordered] @{'));
      expect(script, contains(r'$secretEnv = [ordered] @{}'));
      // Loop body assertions — kept as separate substrings so the test
      // is line-ending agnostic (CRLF on Windows checkouts, LF on Unix).
      expect(
        script,
        contains(r'foreach ($entry in $secretSuffix.GetEnumerator()) {'),
      );
      expect(
        script,
        contains(r'$secretEnv[$entry.Key] = "$SecretPrefix$($entry.Value)"'),
      );
    });

    test('deploys secret values through Secret Manager references', () {
      expect(script, contains('secretmanager.googleapis.com'));
      expect(script, contains('function Sync-SecretManagerSecret'));
      expect(script, contains('gcloud secrets versions add'));
      expect(script, contains('roles/secretmanager.secretAccessor'));
      expect(script, contains("'--set-secrets', \$secretAssignments"));
      expect(script, contains("'--env-vars-file', \$envVarsFile"));
      expect(script, contains(r'& $gcloud @deployArgs'));
      expect(script, contains("'PROXY_ENVIRONMENT' = \$ProxyEnvironment"));
      expect(script, contains("'ADMIN_CORS_ALLOWED_ORIGINS'"));
      expect(
        script,
        contains(
          "Write-Host ' - Cloud Run secret env refs backed by Secret "
          "Manager'",
        ),
      );
      expect(script, isNot(contains('--set-env-vars \$envAssignments')));
    });

    test('derives FIREBASE_WEB_API_KEY from forgeflow google-services when '
        'local env omits it (default branch)', () {
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

    test('FIREBASE_WEB_API_KEY resolver honors -FirebaseGoogleServicesPath '
        'override for non-staging deploys', () {
      expect(
        script,
        contains(
          r'if ([string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)) {',
        ),
      );
      expect(
        script,
        contains(r'$googleServicesPath = $FirebaseGoogleServicesPath'),
      );
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
