// CODE_HEALTH L11 — pool size env override.
//
// Covers `resolvePostgresMaxConnectionsPerPool` exclusively. The
// resolver is the only env-driven knob exposed by the seam; pool
// adapters and call sites continue to depend on the resolved int.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

void main() {
  group('resolvePostgresMaxConnectionsPerPool', () {
    test('falls back to default when env var is unset', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{},
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
    });

    test('falls back to default when env var is empty / whitespace', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '',
          },
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '   ',
          },
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
    });

    test('returns parsed value when env var is a positive int', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '12',
          },
        ),
        equals(12),
      );
    });

    test('trims surrounding whitespace before parsing', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '  8  ',
          },
        ),
        equals(8),
      );
    });

    test('falls back to default when env var is unparsable', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: 'not-a-number',
          },
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
    });

    test('falls back to default when env var is zero or negative', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '0',
          },
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: const <String, String>{
            kPostgresPoolMaxConnectionsEnvVar: '-5',
          },
        ),
        equals(kPostgresDefaultMaxConnectionsPerPool),
      );
    });

    test(
      'falls back to default when env var exceeds the upper bound',
      () {
        expect(
          resolvePostgresMaxConnectionsPerPool(
            environment: <String, String>{
              kPostgresPoolMaxConnectionsEnvVar:
                  '${kPostgresMaxConnectionsPerPoolUpperBound + 1}',
            },
          ),
          equals(kPostgresDefaultMaxConnectionsPerPool),
        );
      },
    );

    test('accepts a value exactly at the upper bound', () {
      expect(
        resolvePostgresMaxConnectionsPerPool(
          environment: <String, String>{
            kPostgresPoolMaxConnectionsEnvVar:
                '$kPostgresMaxConnectionsPerPoolUpperBound',
          },
        ),
        equals(kPostgresMaxConnectionsPerPoolUpperBound),
      );
    });

    test('default constant is unchanged at 4', () {
      expect(kPostgresDefaultMaxConnectionsPerPool, equals(4));
      expect(
        kPostgresPoolMaxConnectionsEnvVar,
        equals('POSTGRES_POOL_MAX_CONNECTIONS'),
      );
    });
  });
}
