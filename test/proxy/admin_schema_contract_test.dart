import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  test('passes when no admin schema objects are missing', () async {
    final verifier = AdminProxySchemaContractVerifier(
      runnerFn: (sql, {parameters = const <String, Object?>{}}) async {
        expect(sql, contains('public.corpus_versions'));
        expect(sql, contains('public.provider_credentials'));
        expect(sql, contains('public.graphify_review_audit'));
        return const <Map<String, Object?>>[];
      },
    );

    await verifier.verify();
  });

  test('throws the missing admin schema object list', () async {
    final verifier = AdminProxySchemaContractVerifier(
      runnerFn: (sql, {parameters = const <String, Object?>{}}) async {
        return const <Map<String, Object?>>[
          <String, Object?>{'object_name': 'table:public.corpus_versions'},
          <String, Object?>{
            'object_name': 'column:public.operators.suspended_at',
          },
          <String, Object?>{
            'object_name':
                'row:public.feature_flags.kms_real_provider_gemini_enabled',
          },
        ];
      },
    );

    expect(
      verifier.verify(),
      throwsA(
        isA<ProxySchemaContractException>().having(
          (error) => error.missingObjects,
          'missingObjects',
          containsAll(<String>[
            'table:public.corpus_versions',
            'column:public.operators.suspended_at',
            'row:public.feature_flags.kms_real_provider_gemini_enabled',
          ]),
        ),
      ),
    );
  });
}
