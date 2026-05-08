// N5 — startup integration smoke for the Pub/Sub realtime cross-pod
// replay env-var contract.
//
// Pinned behavior:
//   * `PUBSUB_REALTIME_ENABLED` unset → `enabled: false`, no
//     project/topic resolution, retention defaults to 300s. No
//     missing-vars list. The bootstrap branch never attempts
//     subscription provisioning (zero new GCP cost).
//   * `PUBSUB_REALTIME_ENABLED=true` with both project + topic set →
//     `enabled: true`, no missing vars, project/topic resolved as
//     written, retention default 300s.
//   * `PUBSUB_REALTIME_ENABLED=true` with project missing → fail-loud
//     (`hasMissingEnvVars: true`, the bootstrap exits 78). Same for
//     topic missing.
//   * Custom retention seconds parse when positive integer; invalid
//     / non-positive values fall back to the 300s default.
//   * The flag is case-insensitive and accepts true/1/yes; everything
//     else (including blank values) is treated as off.

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/main.dart' as proxy_main;
import '../../tool/advisor_proxy/realtime_bridge.dart'
    show pubsubRealtimeEnabledEnvVar;

void main() {
  group('evaluatePubsubRealtimeStartup', () {
    test('default disabled when the flag env var is unset (zero-cost path)',
        () {
      final result = proxy_main.evaluatePubsubRealtimeStartup(
        const <String, String>{},
      );
      expect(result.enabled, isFalse);
      expect(result.hasMissingEnvVars, isFalse);
      expect(result.missingEnvVarNames, isEmpty);
      expect(result.projectId, isNull);
      expect(result.topicName, isNull);
      expect(
        result.retentionSeconds,
        proxy_main.kPubsubRealtimeDefaultRetentionSeconds,
      );
    });

    test('flag = false / 0 / no / unrecognized values stay off', () {
      for (final raw in const <String>['false', '0', 'no', 'maybe', '']) {
        final result = proxy_main.evaluatePubsubRealtimeStartup(
          <String, String>{pubsubRealtimeEnabledEnvVar: raw},
        );
        expect(result.enabled, isFalse, reason: 'raw=$raw');
      }
    });

    test(
      'flag = true with PROJECT + TOPIC set → enabled, no missing vars, '
      'retention defaults to 300s',
      () {
        final result = proxy_main.evaluatePubsubRealtimeStartup(
          const <String, String>{
            'PUBSUB_REALTIME_ENABLED': 'true',
            'PUBSUB_REALTIME_PROJECT': 'forge-prod',
            'PUBSUB_REALTIME_TOPIC': 'forge-realtime',
          },
        );
        expect(result.enabled, isTrue);
        expect(result.hasMissingEnvVars, isFalse);
        expect(result.missingEnvVarNames, isEmpty);
        expect(result.projectId, 'forge-prod');
        expect(result.topicName, 'forge-realtime');
        expect(
          result.retentionSeconds,
          proxy_main.kPubsubRealtimeDefaultRetentionSeconds,
        );
      },
    );

    test('flag = true but PROJECT missing → fails loud with the var name', () {
      final result = proxy_main.evaluatePubsubRealtimeStartup(
        const <String, String>{
          'PUBSUB_REALTIME_ENABLED': 'true',
          'PUBSUB_REALTIME_TOPIC': 'forge-realtime',
        },
      );
      expect(result.enabled, isTrue);
      expect(result.hasMissingEnvVars, isTrue);
      expect(result.missingEnvVarNames, contains('PUBSUB_REALTIME_PROJECT'));
    });

    test('flag = true but TOPIC missing → fails loud with the var name', () {
      final result = proxy_main.evaluatePubsubRealtimeStartup(
        const <String, String>{
          'PUBSUB_REALTIME_ENABLED': 'true',
          'PUBSUB_REALTIME_PROJECT': 'forge-prod',
        },
      );
      expect(result.enabled, isTrue);
      expect(result.hasMissingEnvVars, isTrue);
      expect(result.missingEnvVarNames, contains('PUBSUB_REALTIME_TOPIC'));
    });

    test('flag = true with both names blank → fails loud listing both', () {
      final result = proxy_main.evaluatePubsubRealtimeStartup(
        const <String, String>{
          'PUBSUB_REALTIME_ENABLED': 'TRUE',
          'PUBSUB_REALTIME_PROJECT': '',
          'PUBSUB_REALTIME_TOPIC': '   ',
        },
      );
      expect(result.enabled, isTrue);
      expect(result.hasMissingEnvVars, isTrue);
      expect(
        result.missingEnvVarNames,
        containsAll(<String>[
          'PUBSUB_REALTIME_PROJECT',
          'PUBSUB_REALTIME_TOPIC',
        ]),
      );
    });

    test('custom positive retention seconds wins over the 300s default', () {
      final result = proxy_main.evaluatePubsubRealtimeStartup(
        const <String, String>{
          'PUBSUB_REALTIME_ENABLED': 'true',
          'PUBSUB_REALTIME_PROJECT': 'forge-prod',
          'PUBSUB_REALTIME_TOPIC': 'forge-realtime',
          'PUBSUB_REALTIME_RETENTION_SECONDS': '600',
        },
      );
      expect(result.retentionSeconds, 600);
    });

    test('non-positive / non-numeric retention falls back to 300s default', () {
      for (final raw in const <String>['0', '-5', 'abc', '']) {
        final result = proxy_main.evaluatePubsubRealtimeStartup(
          <String, String>{
            'PUBSUB_REALTIME_ENABLED': 'true',
            'PUBSUB_REALTIME_PROJECT': 'forge-prod',
            'PUBSUB_REALTIME_TOPIC': 'forge-realtime',
            'PUBSUB_REALTIME_RETENTION_SECONDS': raw,
          },
        );
        expect(
          result.retentionSeconds,
          proxy_main.kPubsubRealtimeDefaultRetentionSeconds,
          reason: 'raw=$raw',
        );
      }
    });
  });
}
