// Tests for `tool/audit_logs_update_lint.dart`.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/audit_logs_update_lint.dart';

void main() {
  group('audit_logs_update_lint', () {
    test('flags UPDATE audit_logs outside the allowlist', () {
      final result = AuditLogsUpdateLintRunner(
        files: const <String, String>{
          'db/migrations/202606010000_bad.sql': '''
begin;
update public.audit_logs
   set payload = payload || '{"bad":true}'::jsonb;
commit;
''',
        },
        allowlist: const <String>{},
      ).run();

      expect(result.isClean, isFalse);
      expect(result.violations, hasLength(1));
      expect(result.violations.single.line, 2);
      expect(result.violations.single.path, endsWith('202606010000_bad.sql'));
    });

    test('allows the explicitly allowlisted historical migration', () {
      final result = AuditLogsUpdateLintRunner(
        files: const <String, String>{
          'db/migrations/202605131010_admin_audit_logs_business_date.sql': '''
update public.audit_logs
   set business_date = chain_date
 where business_date is null;
''',
        },
        allowlist: const <String>{
          'db/migrations/202605131010_admin_audit_logs_business_date.sql',
        },
      ).run();

      expect(result.isClean, isTrue);
      expect(result.allowlistedFileCount, 1);
    });

    test('ignores line and block comments mentioning UPDATE audit_logs', () {
      final result = AuditLogsUpdateLintRunner(
        files: const <String, String>{
          'db/migrations/202606010001_comments.sql': '''
-- update public.audit_logs set payload = '{}';
/*
update audit_logs
   set payload = '{}';
*/
select 1;
''',
        },
        allowlist: const <String>{},
      ).run();

      expect(result.isClean, isTrue);
    });

    test('does not match similarly named audit tables', () {
      final result = AuditLogsUpdateLintRunner(
        files: const <String, String>{
          'db/migrations/202606010002_anchor.sql': '''
update public.audit_chain_anchors
   set anchored_at = now();
''',
        },
        allowlist: const <String>{},
      ).run();

      expect(result.isClean, isTrue);
    });
  });
}
