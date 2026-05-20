// Phase 9 / 9.1 — Advisor proxy JWT-verifier + auth-schema tests.
//
// Bucket 5c-jwt of the 2026-05-20 test-suite tightening audit: split
// out of `test/advisor_proxy_test.dart` (8,328 lines). This file holds
// the Phase 9 auth schema foundation migration, the ScaffoldRejecting /
// ScaffoldFailing default verifiers + signature validators, the live
// PointyCastle RS256 signature validator, and the FirebaseProxyJwtVerifier
// (local Firebase ID-token verifier) tests.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'advisor_proxy_test_helpers.dart';

void main() {
  group('Phase 9 auth schema foundation migration (9.0)', () {
    late String migration;
    late String normalizedMigration;
    late List<String> migrationNames;
    late String permissionKeysSource;
    late String catalogContract;

    const newAuthTables = <String>[
      'permission_keys',
      'roles',
      'role_permissions',
      'user_roles',
      'auth_sessions',
      'mfa_factors',
      'tncs_acceptances',
      'password_history',
      'auth_invites',
      'auth_events_audit',
      'role_audit_log',
      'external_identity_links',
    ];

    const baselineRoleKeys = <String>[
      'super_admin',
      'ff_support',
      'operator_owner',
      'operator_manager',
      'operator_supervisor',
      'operator_staff',
    ];

    setUpAll(() {
      migrationNames =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();
      migration = File(
        'db/migrations/202604250008_auth_schema_foundation.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      normalizedMigration = migration.replaceAll(RegExp(r'\s+'), ' ');
      permissionKeysSource = File(
        'lib/auth/permission_keys.dart',
      ).readAsStringSync();
      catalogContract = File(
        'docs/contracts/auth_permission_key_catalog.md',
      ).readAsStringSync();
    });

    test(
      'migration is the next deterministic file after 11a.11c.6 hardening',
      () {
        expect(
          migrationNames,
          contains('202604250008_auth_schema_foundation.sql'),
        );
        expect(
          migrationNames.indexOf('202604250008_auth_schema_foundation.sql'),
          equals(
            migrationNames.indexOf(
                  '202604250007_advisor_rls_index_hardening.sql',
                ) +
                1,
          ),
        );
      },
    );

    test('every new auth table is created with `if not exists`', () {
      for (final table in newAuthTables) {
        expect(
          migration,
          contains('create table if not exists public.$table'),
          reason: 'missing create table for $table',
        );
      }
    });

    test('users table is extended with the 9.0 auth + identity columns', () {
      const expectedColumns = <String>[
        'firebase_uid text not null default gen_random_uuid()::text',
        'external_id text null',
        "status text not null default 'invited'",
        'deleted_at timestamptz null',
        'roles_version integer not null default 0',
        'mfa_required boolean not null default false',
        'last_login_at timestamptz null',
        'last_active_at timestamptz null',
        'password_set_at timestamptz null',
        'email_verified_at timestamptz null',
        'first_name text null',
        'last_name text null',
        'display_name text null',
        'primary_role_id uuid null',
        'preferred_locale text null',
        'avatar_url text null',
      ];
      for (final column in expectedColumns) {
        expect(
          migration,
          contains('add column if not exists $column'),
          reason: 'missing users column $column',
        );
      }
      // status check covers the documented lifecycle states.
      for (final state in <String>[
        'invited',
        'active',
        'suspended',
        'dormant_30',
        'dormant_60',
        'dormant_90',
        'deleted',
      ]) {
        expect(
          migration,
          contains("'$state'"),
          reason: 'missing users.status state $state',
        );
      }
      // firebase_uid uniqueness + primary_role_id FK to roles.
      expect(
        migration,
        contains('add constraint users_firebase_uid_key unique (firebase_uid)'),
      );
      expect(
        migration,
        contains('add constraint users_external_id_key unique (external_id)'),
      );
      expect(
        normalizedMigration,
        contains(
          'add constraint users_primary_role_fk foreign key '
          '(primary_role_id) references public.roles(role_id) '
          'on delete set null',
        ),
      );
    });

    test(
      'operator_admins is extended and gets a composite scope-location FK',
      () {
        expect(migration, contains('add column if not exists scope_type text'));
        // scope_type is added nullable, backfilled, then SET NOT NULL so
        // existing rows do not violate NOT NULL on first apply.
        expect(
          normalizedMigration,
          contains('alter column scope_type set not null'),
        );
        for (final scope in <String>[
          'super_admin',
          'ff_support',
          'operator_owner',
          'operator_manager',
        ]) {
          expect(
            migration,
            contains("'$scope'"),
            reason: 'missing operator_admins.scope_type value $scope',
          );
        }
        expect(
          migration,
          contains('add column if not exists scope_location_id uuid null'),
        );
        expect(
          migration,
          contains(
            'add column if not exists valid_from timestamptz not null '
            'default now()',
          ),
        );
        expect(
          migration,
          contains('add column if not exists valid_until timestamptz null'),
        );
        // Composite FK rejects (operator_a, location_b) cross-tenant
        // mismatches at the DB layer.
        expect(
          normalizedMigration,
          contains(
            'add constraint operator_admins_scope_location_fk foreign key '
            '(operator_id, scope_location_id) references '
            'public.locations(operator_id, location_id) on delete cascade',
          ),
        );
      },
    );

    test(
      'legacy users.role column is migrated into user_roles and dropped',
      () {
        // The DO block guards the backfill on column existence so re-runs
        // after the column was already dropped are safe.
        expect(
          normalizedMigration,
          contains(
            "where table_schema = 'public' and table_name = 'users' "
            "and column_name = 'role'",
          ),
        );
        expect(migration, contains('insert into public.user_roles'));
        expect(
          migration,
          contains('alter table public.users drop column role'),
        );
      },
    );

    test('roles uses partial unique indexes to handle null operator_id', () {
      // Plain UNIQUE treats NULL as distinct, so global (operator_id IS
      // NULL) seeded roles need a separate partial unique index from
      // operator-scoped custom roles.
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists roles_operator_role_key_idx '
          'on public.roles (operator_id, role_key) where operator_id '
          'is not null',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists roles_global_role_key_idx '
          'on public.roles (role_key) where operator_id is null',
        ),
      );
    });

    test('user_roles_active_grant_idx is tenant-leading and supports the same '
        'user holding the same role across different operators', () {
      // Tenant-leading composite blocks duplicate active grants within
      // one (operator, user, role, location) scope while permitting
      // the same user to hold the same role across different
      // operators. COALESCE collapses NULL location_id (operator-wide
      // grant) into a single uniqueness slot.
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists user_roles_active_grant_idx '
          'on public.user_roles ( operator_id, user_id, role_id, '
          "coalesce(location_id, '00000000-0000-0000-0000-000000000000'"
          '::uuid) ) where revoked_at is null',
        ),
      );
      // The drop-then-create pattern is required so a re-apply over the
      // pre-fix shape (where the index led with user_id) replaces it
      // rather than skipping via `if not exists`.
      expect(
        normalizedMigration,
        contains('drop index if exists public.user_roles_active_grant_idx'),
      );
      // Regression guard: the old user_id-leading composite must not
      // resurface. A revert to the pre-fix shape would fail this check
      // because operator_id would no longer be the first column.
      expect(
        normalizedMigration,
        isNot(
          contains(
            'user_roles_active_grant_idx on public.user_roles '
            '( user_id, role_id,',
          ),
        ),
      );
    });

    test(
      'auth_events_audit actor/target lookup indexes lead with operator_id',
      () {
        // Tenant-leading actor lookup. The pre-fix shape led with
        // actor_user_id and ignored operator_id, which forced RLS to
        // re-filter on every probe.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_actor_occurred_idx '
            'on public.auth_events_audit '
            '(operator_id, actor_user_id, occurred_at desc) '
            'where operator_id is not null and actor_user_id is not null',
          ),
        );
        // Tenant-leading target lookup, same shape contract.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_target_occurred_idx '
            'on public.auth_events_audit '
            '(operator_id, target_user_id, occurred_at desc) '
            'where operator_id is not null and target_user_id is not null',
          ),
        );
        // Regression guards: the pre-fix user_id-leading shapes must
        // not resurface. Reverting either index to leading with the
        // user-id column alone would fail these checks.
        expect(
          normalizedMigration,
          isNot(
            contains(
              'auth_events_audit_actor_occurred_idx on '
              'public.auth_events_audit (actor_user_id, occurred_at desc)',
            ),
          ),
        );
        expect(
          normalizedMigration,
          isNot(
            contains(
              'auth_events_audit_target_occurred_idx on '
              'public.auth_events_audit (target_user_id, occurred_at desc)',
            ),
          ),
        );
        // The global `operator_id is null` partial index must remain so
        // system-wide events (Firebase JWKS rotations, etc.) stay
        // queryable by occurred_at without leaking into the
        // per-operator lookup indexes.
        expect(
          normalizedMigration,
          contains(
            'create index if not exists auth_events_audit_global_occurred_idx '
            'on public.auth_events_audit (occurred_at desc) '
            'where operator_id is null',
          ),
        );
      },
    );

    test('operator-scoped tables carry tenant-leading indexes per RLS '
        'performance discipline', () {
      const tenantLeadingIndexes = <String>[
        'user_roles_tenant_lookup_idx on public.user_roles (operator_id, location_id, user_id)',
        'tncs_acceptances_operator_user_idx on public.tncs_acceptances (operator_id, user_id, accepted_at)',
        'auth_invites_operator_expires_idx on public.auth_invites (operator_id, expires_at)',
        'auth_events_audit_operator_occurred_idx on public.auth_events_audit (operator_id, occurred_at desc) where operator_id is not null',
        'external_identity_links_operator_user_idx on public.external_identity_links (operator_id, user_id)',
        'users_operator_status_idx on public.users (operator_id, status) where deleted_at is null',
      ];
      for (final fragment in tenantLeadingIndexes) {
        expect(
          normalizedMigration,
          contains(fragment),
          reason: 'missing tenant-leading index fragment: $fragment',
        );
      }
    });

    test('external_identity_links carries vendor-scoped composite UNIQUE '
        'partials (NOT auth source-of-truth, but per-vendor identity is '
        'unique within an operator)', () {
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists external_identity_links_labor_idx '
          'on public.external_identity_links '
          '(operator_id, vendor, labor_employee_id) where '
          'labor_employee_id is not null',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'create unique index if not exists external_identity_links_pos_idx '
          'on public.external_identity_links '
          '(operator_id, vendor, pos_employee_id) where '
          'pos_employee_id is not null',
        ),
      );
    });

    test(
      'every new auth table has RLS enabled and a service-role policy stub',
      () {
        for (final table in newAuthTables) {
          expect(
            migration,
            contains('alter table public.$table enable row level security'),
            reason: 'RLS must be enabled on $table',
          );
          // Either a `*_service_role_all` stub (writable) or the
          // append-only INSERT/SELECT split for audit tables. Both
          // forms include the table name as a policy-name prefix.
          expect(
            migration,
            contains('${table}_service_role_'),
            reason: 'service-role policy stub must exist for $table',
          );
        }
        // Every policy stub targets the service_role role.
        expect(migration, contains('to service_role'));
      },
    );

    test('audit tables are append-only by grant shape', () {
      // auth_events_audit: REVOKE UPDATE, DELETE FROM PUBLIC + service_role;
      // GRANT INSERT, SELECT TO service_role.
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.auth_events_audit from public',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.auth_events_audit from service_role',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'grant insert, select on public.auth_events_audit to service_role',
        ),
      );
      // role_audit_log: same grant shape.
      expect(
        normalizedMigration,
        contains('revoke update, delete on public.role_audit_log from public'),
      );
      expect(
        normalizedMigration,
        contains(
          'revoke update, delete on public.role_audit_log from service_role',
        ),
      );
      expect(
        normalizedMigration,
        contains(
          'grant insert, select on public.role_audit_log to service_role',
        ),
      );
      // The RLS policy stubs for the audit tables are SELECT/INSERT
      // only — no FOR ALL stub that would tempt a future change to
      // also grant UPDATE / DELETE.
      expect(migration, contains('auth_events_audit_service_role_append_only'));
      expect(migration, contains('auth_events_audit_service_role_select'));
      expect(migration, contains('role_audit_log_service_role_append_only'));
      expect(migration, contains('role_audit_log_service_role_select'));
    });

    test('six baseline roles are seeded with deterministic UUIDs', () {
      expect(migration, contains('insert into public.roles'));
      for (final key in baselineRoleKeys) {
        expect(
          migration,
          contains("'$key'"),
          reason: 'baseline role $key must be seeded',
        );
      }
      // is_seeded = true; super_admin and ff_support are not editable.
      expect(migration, contains('true, false'));
      expect(migration, contains("'F&F Super Admin'"));
      expect(migration, contains("'F&F Support'"));
    });

    test('permission catalog seed is a single insert into permission_keys '
        'and includes one key per documented category', () {
      expect(migration, contains('insert into public.permission_keys'));
      // Sample one key per category to confirm coverage.
      const samplePerCategory = <String, String>{
        'product': 'product.forgeflow.access',
        'forgeflow': 'forgeflow.shift.view',
        'barrio': 'barrio.handbook.view',
        'admin': 'admin.users.view',
        'billing': 'billing.invoice.view',
        'integration': 'integration.toast.view',
        'workflow': 'workflow.catalog.view',
      };
      samplePerCategory.forEach((category, key) {
        expect(
          migration,
          contains("'$key'"),
          reason: 'category $category sample key $key not seeded',
        );
      });
    });

    test(
      'every key from PermissionKeys.all is seeded into permission_keys',
      () {
        // Pull `'literal'` strings out of the constants file. The
        // PermissionKeys class is constants-only so every quoted literal
        // is a permission key (or a baseline role key). Filtering on
        // the catalog category prefixes keeps role-key strings out.
        final keyPattern = RegExp(r"'([a-z][a-z0-9_]*\.[a-z0-9_.]+)'");
        final keys = keyPattern
            .allMatches(permissionKeysSource)
            .map((m) => m.group(1)!)
            .where(
              (key) =>
                  key.startsWith('product.') ||
                  key.startsWith('forgeflow.') ||
                  key.startsWith('barrio.') ||
                  key.startsWith('admin.') ||
                  key.startsWith('team.') ||
                  key.startsWith('billing.') ||
                  key.startsWith('integration.') ||
                  // Phase 8.0 added `integrations.configure` (plural)
                  // for the Vendor Connections category gate. Distinct
                  // from the per-vendor `integration.*` keys above.
                  key.startsWith('integrations.') ||
                  key.startsWith('workflow.'),
            )
            .toSet();
        // Sanity floor — the constants file must declare at least the
        // ~80 keys the plan calls for. If this trips, the constants
        // file lost coverage somewhere.
        expect(
          keys.length,
          greaterThanOrEqualTo(75),
          reason:
              'PermissionKeys.dart should declare ~80 permission keys; '
              'found ${keys.length}',
        );
        // Some catalog keys are seeded by follow-up migrations rather
        // than by the 9.0 foundation seed (so the foundation migration
        // stays a fixed-shape historical record). The h2 slice
        // (2026-04-28) added `admin.audit_privacy.read` via
        // `202604280014_phase_9_0sigma_h2_audit_privacy_role.sql`;
        // the assertion below scans every migration in `db/migrations/`
        // so a follow-up seed counts as "seeded into permission_keys"
        // for the purposes of this contract test.
        final allMigrations = StringBuffer();
        for (final entry in Directory('db/migrations').listSync()) {
          if (entry is File && entry.path.endsWith('.sql')) {
            allMigrations.write(
              entry.readAsStringSync().replaceAll('\r\n', '\n'),
            );
            allMigrations.write('\n');
          }
        }
        final allMigrationsContent = allMigrations.toString();
        // Every key declared in constants must be seeded by some
        // migration in db/migrations/.
        for (final key in keys) {
          expect(
            allMigrationsContent,
            contains("'$key'"),
            reason:
                'PermissionKeys constant $key not seeded by any '
                'db/migrations/*.sql file',
          );
        }
      },
    );

    test('MFA-required keys are flagged in the migration with requires_mfa '
        'true and documented in the catalog contract', () {
      const mfaRequiredKeys = <String>[
        'admin.users.erase_pii',
        'admin.roles.edit_seeded',
        'admin.pricing_tier.edit',
        'admin.service_principal.issue_token',
        'billing.subscription.manage',
        'billing.payment_method.manage',
        'billing.usage_caps.edit',
        'integration.key_rotate',
      ];
      for (final key in mfaRequiredKeys) {
        // The seed row for an MFA-required key carries `true, true` at
        // the (requires_mfa, frozen) tail of the values tuple.
        final escapedKey = RegExp.escape(key);
        final pattern = RegExp("'$escapedKey',[\\s\\S]*?true,\\s*true\\b");
        expect(
          pattern.hasMatch(migration),
          isTrue,
          reason: 'MFA-required key $key not flagged with requires_mfa=true',
        );
        expect(
          catalogContract,
          contains(key),
          reason: 'MFA-required key $key missing from catalog contract doc',
        );
      }
    });

    test('role grants seed super_admin with every key and other roles with '
        'enumerated key lists', () {
      // super_admin gets every key via cross join + role_key filter.
      expect(
        normalizedMigration,
        contains(
          'insert into public.role_permissions (role_id, permission_key, '
          "effect) select r.role_id, pk.key, 'allow' from public.roles r "
          'cross join public.permission_keys pk where r.role_key = '
          "'super_admin' and r.operator_id is null",
        ),
      );
      // Other roles have an enumerated `pk.key in (...)` list.
      for (final roleKey in <String>[
        'ff_support',
        'operator_owner',
        'operator_manager',
        'operator_supervisor',
        'operator_staff',
      ]) {
        expect(
          migration,
          contains("where r.role_key = '$roleKey'"),
          reason: 'role-permission seed missing for $roleKey',
        );
      }
    });

    test('migration uses TIMESTAMPTZ throughout — no `timestamp without '
        'time zone` (operator-scoped silent-DST hazard banned)', () {
      expect(
        migration.toLowerCase().contains('timestamp without time zone'),
        isFalse,
        reason:
            'TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped '
            'tables — silent DST corruption is unrecoverable.',
      );
    });

    test(
      'migration does not introduce pgmq, Firebase config, or live calls',
      () {
        // pgmq is not exposed by Azure flexible server; the queue-provider
        // choice is locked to FOR UPDATE SKIP LOCKED + Cloud Tasks (see
        // CLAUDE.md). The 9.0 schema must not reintroduce it.
        expect(migration.toLowerCase(), isNot(contains('pgmq')));
        // 9.0 is schema-only/local-first. Firebase wiring belongs to 9.1.
        expect(migration.toLowerCase(), isNot(contains('firebase_admin')));
        expect(migration.toLowerCase(), isNot(contains('http://')));
        expect(migration.toLowerCase(), isNot(contains('https://')));
      },
    );
  });


  group('ScaffoldRejectingJwtVerifier (hard-fail-closed default)', () {
    test('rejects every token with a verification error', () {
      const verifier = ScaffoldRejectingJwtVerifier();
      expect(
        verifier.verify('any.token.value'),
        throwsA(isA<ProxyJwtVerificationError>()),
      );
    });

    test('used by ProxyRequestGuard, surfaces as 401', () async {
      final guard = ProxyRequestGuard(
        verifier: const ScaffoldRejectingJwtVerifier(),
      );

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer any.token.value',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(401));
      expect(thrown.message, contains('11a.10a scaffold'));
    });
  });


  group('ScaffoldFailingRs256SignatureValidator (9.1 fail-closed default)', () {
    test('throws StateError on every call so production fails closed', () {
      const validator = ScaffoldFailingRs256SignatureValidator();
      expect(
        () => validator.verify(
          signedInput: Uint8List.fromList(<int>[1, 2, 3]),
          signature: Uint8List.fromList(<int>[4, 5, 6]),
          keyMaterial: const JwtKeyMaterial(
            pemX509Certificate: 'placeholder-cert',
            kid: 'kid-x',
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'integrated with FirebaseProxyJwtVerifier surfaces as 401 path',
      () async {
        // The verifier catches StateError from the validator and
        // re-throws as ProxyJwtVerificationError so the request guard
        // returns 401 instead of bubbling up as a 500. This is the
        // fail-closed contract: a misconfigured RSA backend must never
        // turn into a silent allow OR a leaky 500.
        final verifier = FirebaseProxyJwtVerifier(
          projectId: 'forge-flow-staging',
          keySource: FixedJwksKeySource(<String, JwtKeyMaterial>{
            'kid-x': const JwtKeyMaterial(
              pemX509Certificate: 'placeholder',
              kid: 'kid-x',
            ),
          }),
          signatureValidator: const ScaffoldFailingRs256SignatureValidator(),
          now: () => DateTime.utc(2026, 4, 26, 12),
        );
        final token = firebaseTestToken(
          kid: 'kid-x',
          projectId: 'forge-flow-staging',
          sub: 'user_abc',
          issuedAt: DateTime.utc(2026, 4, 26, 11, 59),
          expiresAt: DateTime.utc(2026, 4, 26, 13),
        );

        ProxyJwtVerificationError? thrown;
        try {
          await verifier.verify(token);
        } on ProxyJwtVerificationError catch (error) {
          thrown = error;
        }
        expect(thrown, isNotNull);
        expect(thrown!.message, contains('signature verification unavailable'));
      },
    );
  });


  group('PointyCastleRs256SignatureValidator (9.1 live crypto)', () {
    test(
      'verifies a real RS256 signature from x509 certificate key material',
      () {
        const validator = PointyCastleRs256SignatureValidator();
        final signedInput = Uint8List.fromList(utf8.encode('header.payload'));
        final signature = signRs256(signedInput, rsaFixturePrivateKey());

        expect(
          validator.verify(
            signedInput: signedInput,
            signature: signature,
            keyMaterial: JwtKeyMaterial(
              pemX509Certificate: rsaFixtureCertificatePem(),
              kid: 'fixture-kid',
            ),
          ),
          isTrue,
        );
      },
    );

    test('returns false for a tampered RS256 signature', () {
      const validator = PointyCastleRs256SignatureValidator();
      final signedInput = Uint8List.fromList(utf8.encode('header.payload'));
      final signature = signRs256(signedInput, rsaFixturePrivateKey());
      signature[signature.length - 1] ^= 0x01;

      expect(
        validator.verify(
          signedInput: signedInput,
          signature: signature,
          keyMaterial: JwtKeyMaterial(
            pemX509Certificate: rsaFixtureCertificatePem(),
            kid: 'fixture-kid',
          ),
        ),
        isFalse,
      );
    });

    test('throws a non-State error for malformed PEM so verifier returns '
        'generic signature failure', () {
      const validator = PointyCastleRs256SignatureValidator();
      expect(
        () => validator.verify(
          signedInput: Uint8List.fromList(<int>[1, 2, 3]),
          signature: Uint8List.fromList(<int>[4, 5, 6]),
          keyMaterial: const JwtKeyMaterial(
            pemX509Certificate: 'not a pem block',
            kid: 'bad-kid',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });


  group('FirebaseProxyJwtVerifier (9.1 local Firebase ID-token verifier)', () {
    const projectId = 'forge-flow-staging';
    final fixedNow = DateTime.utc(2026, 4, 26, 12);
    const goodKid = 'kid-good';
    final keySource = FixedJwksKeySource(<String, JwtKeyMaterial>{
      goodKid: const JwtKeyMaterial(
        pemX509Certificate: 'placeholder-cert',
        kid: goodKid,
      ),
    });

    FirebaseProxyJwtVerifier buildVerifier({
      JwtRs256SignatureValidator? signatureValidator,
      JwksKeySource? overrideKeySource,
      DateTime? now,
    }) {
      return FirebaseProxyJwtVerifier(
        projectId: projectId,
        keySource: overrideKeySource ?? keySource,
        signatureValidator:
            signatureValidator ?? const AlwaysAcceptRs256Validator(),
        now: () => now ?? fixedNow,
      );
    }

    test(
      'happy path returns ProxyJwtClaims projected from custom claims',
      () async {
        final verifier = buildVerifier();
        final token = firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_abc',
          operatorId: 'op_777',
          locationId: 'loc_999',
          isSuperAdmin: false,
          isFfSupport: false,
          rolesVersion: 7,
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
          authTime: fixedNow.subtract(const Duration(minutes: 2)),
        );

        final claims = await verifier.verify(token);
        expect(claims.userId, equals('user_abc'));
        expect(claims.operatorId, equals('op_777'));
        expect(claims.locationId, equals('loc_999'));
        expect(claims.roles, equals(<String>['roles_version:7']));
      },
    );

    test(
      'happy path resolves super_admin + ff_support flags into roles',
      () async {
        final verifier = buildVerifier();
        final token = firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_admin',
          operatorId: 'op_777',
          locationId: 'loc_999',
          isSuperAdmin: true,
          isFfSupport: true,
          rolesVersion: 1,
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
        );

        final claims = await verifier.verify(token);
        expect(claims.roles, contains('super_admin'));
        expect(claims.roles, contains('ff_support'));
        expect(claims.roles, contains('roles_version:1'));
      },
    );

    test('rejects malformed JWT with fewer than 3 segments', () async {
      final verifier = buildVerifier();
      await expectVerifierError(
        verifier.verify('not.a-jwt'),
        contains('malformed JWT'),
      );
    });

    test('rejects unsupported alg (HS256)', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        algOverride: 'HS256',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('unsupported JWT alg'),
      );
    });

    test('rejects token with missing kid header', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: '',
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('missing kid'),
      );
    });

    test('rejects wrong issuer', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        issuerOverride: 'https://securetoken.google.com/wrong-project',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('unexpected issuer'),
      );
    });

    test('rejects wrong audience', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        audienceOverride: 'wrong-audience',
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('unexpected audience'),
      );
    });

    test('rejects expired token (exp before now beyond leeway)', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(hours: 2)),
        expiresAt: fixedNow.subtract(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('JWT expired'),
      );
    });

    test('rejects future iat (iat ahead of now beyond leeway)', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.add(const Duration(hours: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 2)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('iat is in the future'),
      );
    });

    test('rejects future auth_time when present', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
        authTime: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('auth_time is in the future'),
      );
    });

    test('rejects missing sub', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: '',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(verifier.verify(token), contains('sub'));
    });

    test('rejects unknown kid (no JWK in source for given kid)', () async {
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: 'kid-unknown',
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('no matching JWK'),
      );
    });

    test('rejects invalid signature (validator returns false)', () async {
      final verifier = buildVerifier(
        signatureValidator: const AlwaysRejectRs256Validator(),
      );
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
      );
      await expectVerifierError(
        verifier.verify(token),
        contains('signature did not verify'),
      );
    });

    test(
      'rejects invalid signature (validator throws non-State error)',
      () async {
        // Real RSA backends may surface format/parse failures as
        // arbitrary exceptions. The verifier must NOT propagate the
        // raw exception (could carry internal state); it surfaces a
        // generic "signature verification failed" reason instead.
        final verifier = buildVerifier(
          signatureValidator: const BoomRs256Validator(),
        );
        final token = firebaseTestToken(
          kid: goodKid,
          projectId: projectId,
          sub: 'user_abc',
          issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
          expiresAt: fixedNow.add(const Duration(hours: 1)),
        );
        await expectVerifierError(
          verifier.verify(token),
          contains('signature verification failed'),
        );
      },
    );

    test('rejects header that is not valid base64url', () async {
      final verifier = buildVerifier();
      const badToken = 'not-base64!!.payload.signature';
      await expectVerifierError(
        verifier.verify(badToken),
        contains('header is not valid base64url'),
      );
    });

    test('verified token without operator scope still surfaces as 403 via '
        'request guard', () async {
      // The verifier returns claims with operator_id NULL when the
      // custom claim is absent. ProxyRequestGuard then rejects as
      // 403 because the scope contract requires both operator and
      // location. Cross-tenant denial happens at the scope/RLS layer
      // (9.2+); the verifier itself is scope-agnostic.
      final verifier = buildVerifier();
      final token = firebaseTestToken(
        kid: goodKid,
        projectId: projectId,
        sub: 'user_abc',
        issuedAt: fixedNow.subtract(const Duration(minutes: 1)),
        expiresAt: fixedNow.add(const Duration(hours: 1)),
        operatorId: null,
        locationId: null,
      );
      final guard = ProxyRequestGuard(verifier: verifier);

      ProxyAuthError? thrown;
      try {
        await guard.requireOperatorContext(
          authorizationHeader: 'Bearer $token',
        );
      } on ProxyAuthError catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(403));
    });
  });

}
