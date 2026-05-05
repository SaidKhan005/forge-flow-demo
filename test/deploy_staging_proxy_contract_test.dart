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

  group('admin console Dockerfile', () {
    late String dockerfile;

    setUpAll(() {
      dockerfile = File('Dockerfile.admin_console').readAsStringSync();
    });

    test('serves Flutter web assets with no-store cache headers', () {
      expect(
        dockerfile,
        contains('add_header Cache-Control "no-store, max-age=0" always;'),
      );
    });

    test('precompresses large static assets for nginx gzip_static serving', () {
      expect(dockerfile, contains('gzip -9 -c "\$1" > "\$1.gz"'));
      expect(dockerfile, contains('gzip_static on;'));
    });

    test('passes Firebase web config dart-defines into Flutter build', () {
      for (final arg in <String>[
        'FIREBASE_WEB_API_KEY',
        'FIREBASE_WEB_APP_ID',
        'FIREBASE_MESSAGING_SENDER_ID',
        'FIREBASE_PROJECT_ID',
        'FIREBASE_AUTH_DOMAIN',
        'FIREBASE_STORAGE_BUCKET',
      ]) {
        expect(dockerfile, contains('ARG $arg='));
        expect(dockerfile, contains('--dart-define=$arg='));
      }
      expect(
        dockerfile,
        contains('--dart-define=ADMIN_SHARE_PREVIEW=\${ADMIN_SHARE_PREVIEW}'),
      );
    });
  });

  group('operator web Dockerfile', () {
    late String dockerfile;

    setUpAll(() {
      dockerfile = File('Dockerfile.operator_web').readAsStringSync();
    });

    test('passes Firebase web config dart-defines into Flutter build', () {
      for (final arg in <String>[
        'FIREBASE_WEB_API_KEY',
        'FIREBASE_WEB_APP_ID',
        'FIREBASE_MESSAGING_SENDER_ID',
        'FIREBASE_PROJECT_ID',
        'FIREBASE_AUTH_DOMAIN',
        'FIREBASE_STORAGE_BUCKET',
      ]) {
        expect(dockerfile, contains('ARG $arg='));
        expect(dockerfile, contains('--dart-define=$arg='));
      }
    });
  });

  group('deploy_admin_console.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_admin_console.ps1').readAsStringSync();
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
  });

  group('deploy_staging_proxy.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_staging_proxy.ps1').readAsStringSync();
    });

    test(
      'declares -SecretPrefix parameter with staging default + dash guard',
      () {
        expect(
          script,
          contains("[string] \$SecretPrefix = 'forge-flow-staging-'"),
        );
        expect(
          script,
          contains(
            "BLOCKED: -SecretPrefix '\$SecretPrefix' must end with '-'.",
          ),
        );
      },
    );

    test('declares -ProxyBaseUriEnvVarName parameter with staging default', () {
      expect(
        script,
        contains(
          "[string] \$ProxyBaseUriEnvVarName = 'FORGE_FLOW_PROXY_BASE_URI'",
        ),
      );
    });

    test('declares -FirebaseGoogleServicesPath parameter (empty default)', () {
      expect(script, contains("[string] \$FirebaseGoogleServicesPath = ''"));
    });

    test('declares production source env overrides with project guard', () {
      expect(script, contains("[string] \$PostgresUrlEnvVarName = ''"));
      expect(script, contains("[string] \$PostgresAdminUrlEnvVarName = ''"));
      expect(script, contains("[string] \$FirebaseProjectId = ''"));
      expect(
        script,
        contains('BLOCKED: FIREBASE_PROJECT_ID does not match deploy project.'),
      );
      expect(
        script,
        contains(
          'Pass -FirebaseProjectId for production deploys when the shared '
          'secrets loader defaults to another environment.',
        ),
      );
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

    test(
      'supports optional VPC connector flags for first production deploys',
      () {
        expect(script, contains("[string] \$VpcConnector = ''"));
        expect(script, contains("[string] \$VpcEgress = 'all-traffic'"));
        expect(
          script,
          contains(
            'BLOCKED: -VpcEgress is required when -VpcConnector is set.',
          ),
        );
        expect(script, contains("'--vpc-connector', \$VpcConnector"));
        expect(script, contains("'--vpc-egress', \$VpcEgress"));
        expect(script, contains('VPC connector: \$VpcConnector (\$VpcEgress)'));
      },
    );

    test('supports bounded instance count and deferred preview DB startup', () {
      expect(script, contains('[int] \$MaxInstances = 2'));
      expect(script, contains('[switch] \$DeferStartupDatabase'));
      expect(script, contains('BLOCKED: -MaxInstances must be at least 1.'));
      expect(
        script,
        contains(
          'BLOCKED: -DeferStartupDatabase is not allowed with '
          '-ProxyEnvironment prod.',
        ),
      );
      expect(
        script,
        contains("\$envAssignments['PROXY_DEFER_STARTUP_DATABASE'] = 'true'"),
      );
      expect(script, contains("'--max-instances', \$MaxInstances"));
      expect(
        script,
        contains('Cloud Run min/max instances: \$MinInstances/\$MaxInstances'),
      );
    });

    test('requires FIREBASE_WEB_API_KEY for the Phase 9 route bindings', () {
      expect(script, contains("'FIREBASE_WEB_API_KEY'"));
      expect(
        script,
        matches(RegExp(r"'FIREBASE_WEB_API_KEY'\s+=\s+'firebase-web-api-key'")),
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

    test('promotes source deploy traffic to the latest revision', () {
      expect(script, contains('run services update-traffic'));
      expect(script, contains(r'--to-latest'));
    });

    test(
      'unions Firebase auth action hosts into the proxy CORS allow-list',
      () {
        expect(script, contains('function Get-UriOrigin'));
        expect(script, contains('function Join-AdminCorsAllowedOrigins'));
        expect(script, contains('FORGE_FLOW_AUTH_ACTION_URL'));
        expect(script, contains(r'"https://$Project.firebaseapp.com"'));
        expect(script, contains(r'"https://$Project.web.app"'));
        expect(script, contains(r'$authActionOrigin'));
        expect(script, contains(r'$firebaseActionCorsOrigins += $authActionOrigin'));
        expect(script, contains(r'$effectiveAdminCorsAllowedOrigins'));
        expect(
          script,
          contains(
            r"$PSBoundParameters.ContainsKey('AdminCorsAllowedOrigins')",
          ),
        );
        expect(
          script,
          contains(
            'ADMIN_CORS_ALLOWED_ORIGINS includes Firebase auth action hosts',
          ),
        );
      },
    );

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
      expect(
        script,
        contains(
          'BLOCKED: Firebase google-services config not found: '
          r'$googleServicesPath',
        ),
      );
      expect(
        script,
        contains(
          'BLOCKED: Firebase google-services project_id does not match '
          'deploy project.',
        ),
      );
      expect(
        script,
        contains(r'[string]::IsNullOrWhiteSpace($FirebaseGoogleServicesPath)'),
      );
    });
  });

  group('deploy_preview_stack.ps1', () {
    late String script;

    setUpAll(() {
      script = File('scripts/deploy_preview_stack.ps1').readAsStringSync();
    });

    test('prints cache-busted share URL with the admin origin intact', () {
      expect(script, contains(r'${adminUrl}?cache_bust=preview-$safeName-'));
      expect(
        script,
        isNot(contains(r'$adminUrl?cache_bust=preview-$safeName-')),
      );
    });

    test('runtime checks include admin-auth CORS preflight', () {
      expect(script, contains(r'$ProxyUrl/v1/admin/auth/users'));
      expect(script, contains('admin-auth CORS preflight'));
      expect(script, contains('AdminAuthCorsPreflightStatusCode'));
    });

    test('passes preview DB-deferred startup and max-instance cap through', () {
      expect(script, contains('[int] \$ProxyMaxInstances = 1'));
      expect(script, contains('[switch] \$DeferProxyStartupDatabase'));
      expect(script, contains('MaxInstances = \$ProxyMaxInstances'));
      expect(script, contains('\$proxyArgs.DeferStartupDatabase = \$true'));
      expect(
        script,
        contains(
          'Would pass -DeferStartupDatabase to the proxy deploy script.',
        ),
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
