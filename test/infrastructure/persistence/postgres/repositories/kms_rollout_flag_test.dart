// Phase 11A.4c — tests for the per-lane KMS rollout flag.
//
// Acceptance:
//   * `flagNameFor` builds the canonical
//     `kms_real_provider_<keyKind>_enabled` name for every lane
//     (anthropic / voyage / gemini / azure_db).
//   * `FeatureFlagsTableKmsRolloutFlag.isEnabledFor` reads
//     `public.feature_flags` inside the caller's transaction and
//     returns:
//       - true  when the row's `enabled` is true
//       - false when the row's `enabled` is false
//       - false when the row is missing (default OFF — DIFFERENT
//         from the audit-logs cutover's default TRUE)
//   * Multiple sequential calls produce independent SELECTs (one
//     per lookup), each parameterised with the right flag name.
//   * `FixedKmsRolloutFlag` covers the three preset shapes used by
//     scaffolds + tests.
//
// The fake pool / transaction mirrors `_FeatureFlagDrivenPool` from
// `test/repositories/auth_events_audit_cutover_test.dart` so the
// two cutovers are tested with the same shape.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/kms_rollout_flag.dart';

void main() {
  group('FeatureFlagsTableKmsRolloutFlag.flagNameFor', () {
    test('anthropic lane → kms_real_provider_anthropic_enabled', () {
      expect(
        FeatureFlagsTableKmsRolloutFlag.flagNameFor('anthropic'),
        'kms_real_provider_anthropic_enabled',
      );
    });

    test('voyage lane → kms_real_provider_voyage_enabled', () {
      expect(
        FeatureFlagsTableKmsRolloutFlag.flagNameFor('voyage'),
        'kms_real_provider_voyage_enabled',
      );
    });

    test('gemini lane → kms_real_provider_gemini_enabled', () {
      expect(
        FeatureFlagsTableKmsRolloutFlag.flagNameFor('gemini'),
        'kms_real_provider_gemini_enabled',
      );
    });

    test('azure_db lane → kms_real_provider_azure_db_enabled', () {
      expect(
        FeatureFlagsTableKmsRolloutFlag.flagNameFor('azure_db'),
        'kms_real_provider_azure_db_enabled',
      );
    });
  });

  group('FeatureFlagsTableKmsRolloutFlag.isEnabledFor', () {
    test('row enabled=true → returns true', () async {
      final tx = _FeatureFlagDrivenTransaction(featureFlagEnabled: true);
      final flag = const FeatureFlagsTableKmsRolloutFlag();
      final result = await flag.isEnabledFor('anthropic', tx);
      expect(result, isTrue);
      expect(
        tx.executedSql.where((sql) => sql.contains('from public.feature_flags')),
        hasLength(1),
        reason: 'production resolver runs one SELECT per call',
      );
      expect(
        tx.parameters.single['flag_name'],
        'kms_real_provider_anthropic_enabled',
      );
    });

    test('row enabled=false → returns false', () async {
      final tx = _FeatureFlagDrivenTransaction(featureFlagEnabled: false);
      final flag = const FeatureFlagsTableKmsRolloutFlag();
      final result = await flag.isEnabledFor('voyage', tx);
      expect(result, isFalse);
      expect(
        tx.parameters.single['flag_name'],
        'kms_real_provider_voyage_enabled',
      );
    });

    test(
      'missing row → returns false (default OFF — different from '
      'audit-logs cutover, which defaults TRUE)',
      () async {
        final tx = _FeatureFlagDrivenTransaction(featureFlagEnabled: null);
        final flag = const FeatureFlagsTableKmsRolloutFlag();
        final result = await flag.isEnabledFor('gemini', tx);
        expect(
          result,
          isFalse,
          reason: 'default-OFF keeps production on the stub until an '
              'operator explicitly flips the row',
        );
      },
    );

    test(
      'sequential lane lookups run independent SELECTs with the '
      'right flag name each time',
      () async {
        // First call: anthropic enabled. Second: voyage missing
        // (fall-through to default OFF).
        final tx = _PerLaneTransaction(<String, bool?>{
          'kms_real_provider_anthropic_enabled': true,
          'kms_real_provider_voyage_enabled': null,
        });
        final flag = const FeatureFlagsTableKmsRolloutFlag();

        final anthropic = await flag.isEnabledFor('anthropic', tx);
        final voyage = await flag.isEnabledFor('voyage', tx);

        expect(anthropic, isTrue);
        expect(voyage, isFalse);
        expect(
          tx.executedSql.where((sql) => sql.contains('from public.feature_flags')),
          hasLength(2),
          reason: 'each lane lookup runs its own SELECT — no caching',
        );
        expect(tx.parameters[0]['flag_name'], 'kms_real_provider_anthropic_enabled');
        expect(tx.parameters[1]['flag_name'], 'kms_real_provider_voyage_enabled');
      },
    );
  });

  group('FixedKmsRolloutFlag', () {
    final fakeExec = _FeatureFlagDrivenTransaction(featureFlagEnabled: true);

    test('allDisabled() → false for any kind', () async {
      const flag = FixedKmsRolloutFlag.allDisabled();
      expect(await flag.isEnabledFor('anthropic', fakeExec), isFalse);
      expect(await flag.isEnabledFor('voyage', fakeExec), isFalse);
      expect(await flag.isEnabledFor('gemini', fakeExec), isFalse);
      expect(await flag.isEnabledFor('azure_db', fakeExec), isFalse);
    });

    test('allEnabled() → true for any kind', () async {
      const flag = FixedKmsRolloutFlag.allEnabled();
      expect(await flag.isEnabledFor('anthropic', fakeExec), isTrue);
      expect(await flag.isEnabledFor('voyage', fakeExec), isTrue);
      expect(await flag.isEnabledFor('gemini', fakeExec), isTrue);
      expect(await flag.isEnabledFor('azure_db', fakeExec), isTrue);
    });

    test(
      'enabledFor({anthropic, gemini}) → true for those, false for '
      'voyage and azure_db',
      () async {
        const flag = FixedKmsRolloutFlag.enabledFor(<String>{'anthropic', 'gemini'});
        expect(await flag.isEnabledFor('anthropic', fakeExec), isTrue);
        expect(await flag.isEnabledFor('gemini', fakeExec), isTrue);
        expect(await flag.isEnabledFor('voyage', fakeExec), isFalse);
        expect(await flag.isEnabledFor('azure_db', fakeExec), isFalse);
      },
    );
  });
}

/// Captures executed SQL + bound parameters and returns a single
/// canned `feature_flags` row driven by [featureFlagEnabled]:
///
///   * `true`  → SELECT returns `[{enabled: true}]`
///   * `false` → SELECT returns `[{enabled: false}]`
///   * `null`  → SELECT returns `[]` (simulates missing seed row)
///
/// Mirrors `_FeatureFlagDrivenTransaction` from
/// `test/repositories/auth_events_audit_cutover_test.dart`.
class _FeatureFlagDrivenTransaction extends PostgresTransaction {
  _FeatureFlagDrivenTransaction({required this.featureFlagEnabled});

  final bool? featureFlagEnabled;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.feature_flags')) {
      if (featureFlagEnabled == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'enabled': featureFlagEnabled},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}

/// Per-flag-name lookup table so a single transaction can answer
/// different lane queries independently. Map values follow the same
/// `bool?` convention as `_FeatureFlagDrivenTransaction`.
class _PerLaneTransaction extends PostgresTransaction {
  _PerLaneTransaction(this._answers);

  final Map<String, bool?> _answers;
  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.feature_flags')) {
      final flagName = parameters['flag_name'] as String?;
      final answer = _answers[flagName];
      if (answer == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'enabled': answer},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
