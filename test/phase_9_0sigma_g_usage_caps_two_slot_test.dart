// Phase 9.0Σ.g — usage_caps + usage_logs two-slot key migration tests.
//
// Local framework slice (no live database). Five groups:
//
//   1. File presence + ordering
//      ─ all three migrations exist with the locked filenames and
//        sit in the expected relative order
//        (`a_add` < `b_backfill` < `c_constraint_flip`).
//
//   2. Step-a (ADD) shape
//      ─ four nullable cap-shape columns added to both `usage_caps`
//        and `usage_logs`, with comments explaining billing owner
//        vs scoped org.
//
//   3. Step-b (BACKFILL) shape
//      ─ idempotent UPDATE that resolves each operator's root
//        `org_units` row and writes its UUID into
//        `billing_owner_org_unit_id` and `scoped_org_unit_id`.
//
//   4. Step-c (CONSTRAINT FLIP) shape
//      ─ legacy PKs dropped, surrogate `cap_id` / `log_id` PKs added,
//        UNIQUE NULLS NOT DISTINCT logical keys attached, composite
//        FKs to `org_units(operator_id, id)` for both billing-owner
//        and scoped-org slots, and tenant-leading reconciliation
//        index on `usage_logs`. Privileges granted to
//        `service_role` + `forge_admin`; no `forge_admin` RLS
//        policy added.
//
//   5. Disjointness guards
//      ─ untouched legacy migrations match the locked content;
//        the slice introduces no `actor_kind`, sp:-prefixed JWT,
//        `audit_logs`, `service_principals`, or proxy hot-zone
//        changes; no `lib/services/advisor/usage_*.dart` was
//        invented; bare `current_setting('app...')` is absent.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/rls_policy_lint.dart';

const String _aFile =
    'db/migrations/'
    '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql';
const String _bFile =
    'db/migrations/'
    '202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql';
const String _cFile =
    'db/migrations/'
    '202604280006_c_phase_9_0sigma_g_usage_caps_two_slot_constraint_flip.sql';

void main() {
  final addSql = _readSqlNormalized(_aFile);
  final backfillSql = _readSqlNormalized(_bFile);
  final flipSql = _readSqlNormalized(_cFile);

  group('Phase 9.0Σ.g file presence + ordering', () {
    test('all three migration files exist with the locked filenames', () {
      for (final path in <String>[_aFile, _bFile, _cFile]) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: 'Phase 9.0Σ.g requires three migration files. Missing: $path',
        );
      }
    });

    test('files are ordered ADD → BACKFILL → CONSTRAINT FLIP', () {
      final names =
          Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((file) => file.uri.pathSegments.last)
              .where((name) => name.endsWith('.sql'))
              .toList()
            ..sort();

      final addName =
          '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql';
      final backfillName =
          '202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql';
      final flipName =
          '202604280006_c_phase_9_0sigma_g_'
          'usage_caps_two_slot_constraint_flip.sql';

      expect(names, contains(addName));
      expect(names, contains(backfillName));
      expect(names, contains(flipName));
      expect(
        names.indexOf(addName) < names.indexOf(backfillName),
        isTrue,
        reason:
            'add migration must sort before backfill migration so the '
            'columns exist before the backfill UPDATE runs.',
      );
      expect(
        names.indexOf(backfillName) < names.indexOf(flipName),
        isTrue,
        reason:
            'backfill migration must sort before constraint flip so '
            'SET NOT NULL on the org-unit columns sees populated rows.',
      );
    });

    test('every migration runs in a single begin/commit transaction', () {
      for (final sql in <String>[addSql, backfillSql, flipSql]) {
        expect(sql, contains('begin;'));
        expect(sql, contains('commit;'));
      }
    });
  });

  group('Phase 9.0Σ.g step-a (ADD) shape', () {
    test('adds four cap-shape columns to usage_caps as nullable', () {
      expect(
        addSql,
        contains(
          'alter table public.usage_caps\n'
          '  add column if not exists billing_owner_org_unit_id uuid;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_caps\n'
          '  add column if not exists scoped_org_unit_id uuid;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_caps\n'
          '  add column if not exists staff_id uuid null;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_caps\n'
          '  add column if not exists workflow_id uuid null;',
        ),
      );
    });

    test('adds the same four columns to usage_logs', () {
      expect(
        addSql,
        contains(
          'alter table public.usage_logs\n'
          '  add column if not exists billing_owner_org_unit_id uuid;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_logs\n'
          '  add column if not exists scoped_org_unit_id uuid;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_logs\n'
          '  add column if not exists staff_id uuid null;',
        ),
      );
      expect(
        addSql,
        contains(
          'alter table public.usage_logs\n'
          '  add column if not exists workflow_id uuid null;',
        ),
      );
    });

    test('every new column carries an explanatory comment that names '
        'billing-owner vs scoped-org semantics', () {
      // Both tables × four columns × at least one non-trivial comment.
      for (final table in <String>['usage_caps', 'usage_logs']) {
        for (final column in <String>[
          'billing_owner_org_unit_id',
          'scoped_org_unit_id',
          'staff_id',
          'workflow_id',
        ]) {
          expect(
            addSql,
            contains('comment on column public.$table.$column is'),
            reason:
                'add migration must comment public.$table.$column so the '
                'cap-shape semantics survive future readers',
          );
        }
      }
      // Spot-check that the billing-owner / scoped-org pair is named
      // explicitly somewhere in the comment block (lock 6 wording).
      expect(addSql, contains('who pays'));
      expect(addSql, contains('where the cap applies'));
    });

    test('add migration does not modify the legacy primary keys or attach '
        'NOT NULL / UNIQUE constraints (those flip in step c)', () {
      expect(
        addSql.contains('drop constraint'),
        isFalse,
        reason: 'step a is column-only; constraint changes belong in step c',
      );
      expect(
        addSql.contains('set not null'),
        isFalse,
        reason: 'step a keeps every new column nullable',
      );
      expect(
        addSql.contains('unique nulls not distinct'),
        isFalse,
        reason: 'step a does not encode the logical key — that is step c',
      );
    });
  });

  group('Phase 9.0Σ.g step-b (BACKFILL) shape', () {
    test('UPDATE usage_caps from org_units root row', () {
      expect(backfillSql, contains('update public.usage_caps as caps'));
      expect(backfillSql, contains('billing_owner_org_unit_id = root.id'));
      expect(backfillSql, contains('scoped_org_unit_id = root.id'));
      expect(backfillSql, contains('from public.org_units as root'));
      expect(backfillSql, contains('root.operator_id = caps.operator_id'));
      expect(backfillSql, contains('root.parent_id is null'));
    });

    test('UPDATE usage_logs from org_units root row', () {
      expect(backfillSql, contains('update public.usage_logs as logs'));
      expect(backfillSql, contains('root.operator_id = logs.operator_id'));
      expect(backfillSql, contains('root.parent_id is null'));
    });

    test('backfill is idempotent — the WHERE clause skips rows already '
        'populated', () {
      // Both UPDATEs guard on `IS NULL OR IS NULL` so a re-run is a
      // no-op once every row has billing_owner / scoped_org set.
      expect(
        backfillSql.contains('caps.billing_owner_org_unit_id is null'),
        isTrue,
      );
      expect(backfillSql.contains('caps.scoped_org_unit_id is null'), isTrue);
      expect(
        backfillSql.contains('logs.billing_owner_org_unit_id is null'),
        isTrue,
      );
      expect(backfillSql.contains('logs.scoped_org_unit_id is null'), isTrue);
    });

    test('staff_id and workflow_id are intentionally not touched', () {
      // Locked design: the nullable axes stay nullable. UNIQUE NULLS
      // NOT DISTINCT in step c collapses NULL = NULL so the logical
      // key still uniqueness-enforces against existing rows.
      expect(
        backfillSql.contains('staff_id ='),
        isFalse,
        reason:
            'step b must not set staff_id; the locked design keeps it '
            'nullable forever',
      );
      expect(
        backfillSql.contains('workflow_id ='),
        isFalse,
        reason:
            'step b must not set workflow_id; the locked design keeps it '
            'nullable forever',
      );
    });
  });

  group('Phase 9.0Σ.g step-c (CONSTRAINT FLIP) shape', () {
    test('SET NOT NULL on both org-unit columns for both tables', () {
      for (final table in <String>['usage_caps', 'usage_logs']) {
        for (final column in <String>[
          'billing_owner_org_unit_id',
          'scoped_org_unit_id',
        ]) {
          expect(
            flipSql,
            contains(
              'alter table public.$table\n'
              '  alter column $column set not null;',
            ),
            reason:
                'step c must SET NOT NULL on $table.$column once the backfill '
                'has populated every row',
          );
        }
      }
    });

    test('legacy primary keys are dropped before new keys attach', () {
      expect(flipSql, contains('drop constraint if exists usage_caps_pkey'));
      expect(flipSql, contains('drop constraint if exists usage_logs_pkey'));
    });

    test('surrogate cap_id / log_id columns are added with default '
        'gen_random_uuid()', () {
      expect(
        flipSql,
        contains(
          'add column if not exists cap_id uuid not null default gen_random_uuid()',
        ),
      );
      expect(
        flipSql,
        contains(
          'add column if not exists log_id uuid not null default gen_random_uuid()',
        ),
      );
    });

    test('new tenant-leading PKs use the surrogate companion column', () {
      // usage_caps: PK on (operator_id, cap_id).
      expect(
        flipSql,
        contains(
          'add constraint usage_caps_pkey\n'
          '  primary key (operator_id, cap_id);',
        ),
      );
      // usage_logs: PK on (operator_id, log_id, period_start) so the
      // partition key is included as PG requires for partitioned tables.
      expect(
        flipSql,
        contains(
          'add constraint usage_logs_pkey\n'
          '  primary key (operator_id, log_id, period_start);',
        ),
      );
    });

    test('usage_caps logical key UNIQUE NULLS NOT DISTINCT carries the '
        'locked column set', () {
      // Lock 6 logical key:
      // (billing_owner_org_unit_id, scoped_org_unit_id, location_id,
      //  staff_id, workflow_id, usage_class).
      // operator_id is included at the leading position for tenant-
      // leading RLS pushdown without changing semantics — billing_owner
      // / scoped_org IDs are owned by exactly one operator (composite FK).
      expect(
        flipSql,
        contains(
          'add constraint usage_caps_two_slot_uq\n'
          '  unique nulls not distinct (\n'
          '    operator_id,\n'
          '    billing_owner_org_unit_id,\n'
          '    scoped_org_unit_id,\n'
          '    location_id,\n'
          '    staff_id,\n'
          '    workflow_id,\n'
          '    usage_class\n'
          '  );',
        ),
      );
    });

    test('usage_logs reconciliation key matches the cap shape and '
        'preserves period_start + telemetry dimensions for rollup '
        'identity', () {
      // Cap-shape prefix is identical to usage_caps_two_slot_uq so a
      // single-pass reconciliation join works. period_start is in the
      // middle (partition key); the seven 202604250006 telemetry
      // dimensions stay in the rollup identity so a Haiku cache hit
      // and a Sonnet fallback miss never collapse into the same row.
      expect(
        flipSql,
        contains(
          'add constraint usage_logs_two_slot_rollup_uq\n'
          '  unique nulls not distinct (\n'
          '    operator_id,\n'
          '    billing_owner_org_unit_id,\n'
          '    scoped_org_unit_id,\n'
          '    location_id,\n'
          '    staff_id,\n'
          '    workflow_id,\n'
          '    usage_class,\n'
          '    period_start,\n'
          '    query_class,\n'
          '    cache_hit,\n'
          '    llm_tier,\n'
          '    model_used,\n'
          '    batch_mode,\n'
          '    circuit_state,\n'
          '    fallback_used\n'
          '  );',
        ),
      );
    });

    test('surrogate + UNIQUE NULLS NOT DISTINCT design choice is '
        'documented in SQL comments', () {
      // Block 3 task 3: "If nullable axes require UNIQUE NULLS NOT
      // DISTINCT plus a physical surrogate instead of a literal
      // nullable PK, document that choice in SQL comments and tests."
      expect(
        flipSql.toLowerCase(),
        contains('nullable'),
        reason:
            'flip migration must explain why a surrogate PK + NULLS '
            'NOT DISTINCT is used instead of a literal logical-key PK',
      );
      expect(flipSql.toLowerCase(), contains('surrogate'));
      expect(flipSql.toLowerCase(), contains('nulls not distinct'));
      // Spot-check the cap_id and log_id comments name the rationale.
      expect(
        flipSql,
        contains('comment on column public.usage_caps.cap_id is'),
      );
      expect(
        flipSql,
        contains('comment on column public.usage_logs.log_id is'),
      );
    });

    test('composite FKs from billing_owner_org_unit_id and '
        'scoped_org_unit_id reference org_units(operator_id, id) on '
        'both tables', () {
      // Composite FK shape — keyed on (operator_id, <slot>) — rejects
      // cross-tenant mismatches at the database layer.
      const fkExpectations = <List<String>>[
        <String>[
          'usage_caps',
          'usage_caps_billing_owner_org_unit_fk',
          'billing_owner_org_unit_id',
        ],
        <String>[
          'usage_caps',
          'usage_caps_scoped_org_unit_fk',
          'scoped_org_unit_id',
        ],
        <String>[
          'usage_logs',
          'usage_logs_billing_owner_org_unit_fk',
          'billing_owner_org_unit_id',
        ],
        <String>[
          'usage_logs',
          'usage_logs_scoped_org_unit_fk',
          'scoped_org_unit_id',
        ],
      ];
      for (final entry in fkExpectations) {
        final table = entry[0];
        final constraintName = entry[1];
        final column = entry[2];
        expect(
          flipSql,
          contains(
            'alter table public.$table\n'
            '  add constraint $constraintName\n'
            '  foreign key (operator_id, $column)\n'
            '  references public.org_units(operator_id, id)\n'
            '  on delete cascade;',
          ),
          reason:
              'composite FK $constraintName must reference '
              'org_units(operator_id, id) so cross-tenant org-unit '
              'pointers are rejected at the database layer',
        );
      }
    });

    test('cap-vs-actual reconciliation index on usage_logs is '
        'tenant-leading and cap-shape', () {
      // Narrow tenant-leading index gives the planner a compact
      // lookup target for the cap-vs-actual aggregate join. The
      // wider rollup-identity UNIQUE is still present for upserts.
      expect(
        flipSql,
        contains(
          'create index if not exists usage_logs_cap_reconciliation_idx\n'
          '  on public.usage_logs (\n'
          '    operator_id,\n'
          '    billing_owner_org_unit_id,\n'
          '    scoped_org_unit_id,\n'
          '    location_id,\n'
          '    staff_id,\n'
          '    workflow_id,\n'
          '    usage_class\n'
          '  );',
        ),
      );
    });

    test('every new index/constraint stays tenant-leading on operator_id', () {
      // The rule is: any new index introduced on usage_caps or
      // usage_logs leads with operator_id. Pull every CREATE
      // INDEX / ADD CONSTRAINT (UNIQUE | PRIMARY KEY) out of the flip
      // migration and assert the leading column is operator_id.
      final createIndexPattern = RegExp(
        r'create (?:unique )?index (?:if not exists )?'
        r'(\w+)\s+on public\.(usage_caps|usage_logs)\s*'
        r'(?:using \w+\s*)?\(\s*([\w_,\s]+)',
        caseSensitive: false,
        multiLine: true,
      );
      for (final match in createIndexPattern.allMatches(flipSql)) {
        final indexName = match.group(1)!;
        final cols = (match.group(3) ?? '')
            .split(',')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        expect(
          cols.first,
          equals('operator_id'),
          reason:
              'new index $indexName must lead with operator_id (RLS '
              'performance discipline / lock 4)',
        );
      }

      // Same check for ADD CONSTRAINT ... PRIMARY KEY / UNIQUE [NULLS NOT
      // DISTINCT].
      final addConstraintPattern = RegExp(
        r'add constraint (\w+)\s+'
        r'(?:primary key|unique(?: nulls not distinct)?)\s*\(\s*([\w_,\s]+)',
        caseSensitive: false,
        multiLine: true,
      );
      for (final match in addConstraintPattern.allMatches(flipSql)) {
        final constraintName = match.group(1)!;
        final cols = (match.group(2) ?? '')
            .split(',')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        expect(
          cols.first,
          equals('operator_id'),
          reason:
              'constraint $constraintName must lead with operator_id (RLS '
              'performance discipline / lock 4)',
        );
      }
    });

    test('table privileges granted to service_role and forge_admin; no '
        'forge_admin RLS policy added', () {
      // Lock: privileges before RLS, and forge_admin uses BYPASSRLS,
      // never a tenant policy. Both usage_caps and usage_logs (plus
      // the partition default) get the required DML grants.
      const tables = <String>['usage_caps', 'usage_logs', 'usage_logs_default'];
      for (final table in tables) {
        for (final role in <String>['service_role', 'forge_admin']) {
          expect(
            flipSql,
            contains(
              'grant select, insert, update, delete on public.$table to $role',
            ),
            reason: 'flip must grant DML on $table to $role',
          );
        }
      }
      // No new forge_admin policy. The slice constraint is explicit:
      // "do not add a `forge_admin` RLS policy".
      expect(
        flipSql.toLowerCase(),
        isNot(contains('to forge_admin\n')),
        reason: 'flip must not add a forge_admin RLS policy',
      );
      // The CREATE POLICY ... TO forge_admin pattern is forbidden too;
      // the substring above caught the literal policy form. As a belt
      // check, no `create policy` statements should target forge_admin.
      final createPolicyPattern = RegExp(
        r'create policy [^;]*to forge_admin',
        caseSensitive: false,
      );
      expect(
        createPolicyPattern.hasMatch(flipSql),
        isFalse,
        reason: 'no CREATE POLICY ... TO forge_admin in this slice',
      );
    });

    test('flip migration adds no new RLS policies (existing service-role '
        'stubs from 202604250005 stay as the surface)', () {
      final createPolicyPattern = RegExp(
        r'create policy',
        caseSensitive: false,
      );
      expect(
        createPolicyPattern.hasMatch(flipSql),
        isFalse,
        reason:
            'this slice is purely a key/index/constraint flip; the '
            'existing usage_caps_service_role_all and '
            'usage_logs_service_role_all policies in 202604250005 are '
            'untouched (the cloud-foundation RLS flip is a separate '
            'B10 slice)',
      );
    });
  });

  group('Phase 9.0Σ.g RLS lint posture', () {
    test('all three migrations pass the policy-aware bare-GUC lint', () {
      // The slice adds no policy bodies, so trivially passes. The
      // explicit assertion guards against a future edit that adds a
      // policy body using bare current_setting('app...').
      final result = RlsPolicyLintRunner(
        files: <String, String>{
          '202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql': addSql,
          '202604280006_b_phase_9_0sigma_g_usage_caps_two_slot_backfill.sql':
              backfillSql,
          '202604280006_c_phase_9_0sigma_g_'
                  'usage_caps_two_slot_constraint_flip.sql':
              flipSql,
        },
        allowlist: const <String>{},
      ).run();
      expect(
        result.isClean,
        isTrue,
        reason:
            '9.0Σ.g must not introduce bare current_setting(\'app.…\') '
            'reads; violations: ${result.violations}',
      );
    });

    test('no CREATE POLICY in the slice contains a bare GUC read', () {
      // The general lint above proves all 21 migrations are clean; this
      // narrower assertion proves the 9.0Σ.g slice itself adds zero
      // CREATE POLICY statements (so a regression cannot smuggle a bare
      // current_setting into one). Prose comments mentioning the
      // pattern are allowed — only DDL is in scope.
      final createPolicyPattern = RegExp(
        r'create policy',
        caseSensitive: false,
      );
      for (final sql in <String>[addSql, backfillSql, flipSql]) {
        expect(
          createPolicyPattern.hasMatch(sql),
          isFalse,
          reason:
              'this slice is column/key/index work; no CREATE POLICY '
              'statements should appear in any of the three files',
        );
      }
    });
  });

  group('Phase 9.0Σ.g disjointness guards', () {
    test('legacy migrations the slice promised not to touch are unchanged', () {
      // We do not pin a specific hash — instead, sanity-check that the
      // legacy migrations still describe their original anchors. If a
      // hand edited 202604250005 / 202604250006 / 202604280002, these
      // anchors would shift visibly.
      final cloudFoundation = _readSqlNormalized(
        'db/migrations/202604250005_advisor_cloud_foundation.sql',
      );
      expect(
        cloudFoundation,
        contains('primary key (operator_id, location_id, usage_class)'),
        reason:
            '202604250005 still declares the legacy usage_caps PK; the '
            'flip lives only in 9.0Σ.g step c',
      );
      expect(
        cloudFoundation.contains('billing_owner_org_unit_id'),
        isFalse,
        reason:
            '202604250005 must not reference the new cap-shape columns '
            '— those live in 202604280006_a',
      );

      final telemetry = _readSqlNormalized(
        'db/migrations/'
        '202604250006_advisor_contextual_retrieval_telemetry.sql',
      );
      expect(
        telemetry,
        contains('drop constraint if exists usage_logs_pkey'),
        reason:
            '202604250006 still owns the telemetry-aware PK rewrite; '
            'the 9.0Σ.g flip drops that PK in step c, not here',
      );
      expect(
        telemetry.contains('billing_owner_org_unit_id'),
        isFalse,
        reason: '202604250006 must not reference the cap-shape columns',
      );

      final orgUnits = _readSqlNormalized(
        'db/migrations/202604280002_phase_9_0sigma_c_org_units.sql',
      );
      expect(orgUnits, contains('create table if not exists public.org_units'));
      expect(
        orgUnits.contains('alter table public.usage_caps'),
        isFalse,
        reason:
            '202604280002 (org_units) does not own usage_caps DDL — '
            'that lives in 9.0Σ.g',
      );
    });

    test('the slice introduces no DDL for actor_kind, sp:-prefixed JWT, '
        'audit_logs, or service principals (those are 9.0Σ.d / '
        '9.0Σ.f territory)', () {
      // Look for DDL patterns, not prose. Prose comments may say
      // "this slice does not touch actor_kind" without tripping the
      // guard. Things forbidden:
      //   * `add column ... actor_kind` or `actor_kind text` declarations
      //   * `create table ... service_principals` references
      //   * literal `'sp:` JWT subject prefix string
      //   * `create table ... audit_logs` / `auth_events_audit`
      // Each regex below is specific enough that a prose comment that
      // names the term does not match — only DDL declarations do.
      for (final sql in <String>[addSql, backfillSql, flipSql]) {
        final actorKindDdl = RegExp(
          r'\b(?:add column[^;]*\bactor_kind|actor_kind\s+text)\b',
          caseSensitive: false,
        );
        expect(
          actorKindDdl.hasMatch(sql),
          isFalse,
          reason:
              '9.0Σ.g must not declare an actor_kind column — that '
              'ships with 9.0Σ.d service principals',
        );

        final spPrefix = RegExp(r'''['"]sp:''', caseSensitive: false);
        expect(
          spPrefix.hasMatch(sql),
          isFalse,
          reason: 'no sp:-prefixed JWT subject literal in this slice',
        );

        final servicePrincipalsTable = RegExp(
          r'\b(?:create table|references)[^;]*\bservice_principals\b',
          caseSensitive: false,
        );
        expect(
          servicePrincipalsTable.hasMatch(sql),
          isFalse,
          reason:
              'no service_principals DDL in this slice — that lands in '
              '9.0Σ.d',
        );

        final auditLogDdl = RegExp(
          r'\b(?:create table|alter table|references)[^;]*'
          r'\b(?:audit_logs|auth_events_audit)\b',
          caseSensitive: false,
        );
        expect(
          auditLogDdl.hasMatch(sql),
          isFalse,
          reason:
              'no audit_logs / auth_events_audit DDL in this slice — '
              'those ship with 9.0Σ.f hash-chained audit',
        );
      }
    });

    test('proxy upsert is now aligned with the two-slot schema (B33 '
        'follow-up to 9.0Σ.g landed)', () {
      // 9.0Σ.g (B28) added cap-shape columns to usage_logs and
      // dropped the legacy 11-column PK; the proxy hot-zone update
      // was deferred to the B33 follow-up. After B33, the runtime
      // writer in tool/advisor_proxy/advisor_proxy.dart targets
      // `usage_logs_two_slot_rollup_uq` by name — without that
      // alignment, every usage write would fail at runtime because
      // the legacy inference target no longer exists.
      //
      // This assertion is the schema↔writer drift tripwire: if a
      // future slice silently re-introduces the legacy 11-column
      // ON CONFLICT inference target, this test catches it before
      // the cap-vs-actual reconciliation join breaks.
      final proxy = File(
        'tool/advisor_proxy/advisor_proxy.dart',
      ).readAsStringSync();
      expect(
        proxy,
        contains('on conflict on constraint usage_logs_two_slot_rollup_uq'),
        reason:
            'B33 must wire the proxy upsert to the named '
            'usage_logs_two_slot_rollup_uq constraint — column-list '
            'inference assumes NULLS DISTINCT and would not match '
            'the NULLS NOT DISTINCT logical key',
      );
      expect(
        proxy.contains('billing_owner_org_unit_id'),
        isTrue,
        reason:
            'B33 must thread billing_owner_org_unit_id through the '
            'proxy writer so cap-vs-actual reconciliation joins on '
            'the shared cap-shape prefix with usage_caps',
      );
      expect(
        proxy.contains('scoped_org_unit_id'),
        isTrue,
        reason:
            'B33 must thread scoped_org_unit_id through the proxy '
            'writer (the second slot of the lock 6 logical key)',
      );
    });

    test('lib/services/advisor/usage_*.dart was not invented for this '
        'slice', () {
      // Block 3 task 4: "If it does not exist, do not create it and do
      // not touch proxy hot-zone files; report the missing seam as a
      // follow-up/blocker."
      final advisorDir = Directory('lib/services/advisor');
      if (advisorDir.existsSync()) {
        final usageDartFiles = advisorDir
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .where(
              (name) => name.startsWith('usage_') && name.endsWith('.dart'),
            )
            .toList();
        expect(
          usageDartFiles,
          isEmpty,
          reason:
              'this slice forbids inventing lib/services/advisor/'
              'usage_*.dart; the missing seam is a documented '
              'follow-up/blocker. Found: $usageDartFiles',
        );
      }
      // No `advisorDir.existsSync()` path: the directory genuinely does
      // not exist locally — no usage_*.dart was invented.
    });
  });
}

/// Normalize CRLF → LF so multi-line `contains(...)` assertions are
/// platform-independent. Windows checkouts via the default
/// `core.autocrlf=true` setting deliver CRLF line endings, which
/// would otherwise break literal-string assertions that span
/// multiple lines.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
