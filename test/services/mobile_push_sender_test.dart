import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/mobile_push_notifications.dart';

void main() {
  group('MobilePushSendRequest', () {
    test('builds FCM HTTP v1 iOS payload with notification and safe data', () {
      final request = MobilePushSendRequest(
        token: 'device-token',
        platform: 'ios',
        title: 'Shift updated',
        body: 'The posted schedule changed.',
        deeplink: '/schedule',
        data: const <String, Object?>{'event_id': 'evt-1', 'badge_count': 3},
      );

      final json = request.toFcmHttpV1Json();
      final message = json['message']! as Map<String, Object?>;
      expect(message['token'], equals('device-token'));
      expect(
        message['notification'],
        equals(<String, Object?>{
          'title': 'Shift updated',
          'body': 'The posted schedule changed.',
        }),
      );
      expect(message['data'], containsPair('event_id', 'evt-1'));
      expect(message['data'], containsPair('badge_count', '3'));
      expect(message['data'], containsPair('deeplink', '/schedule'));
      expect(message, contains('apns'));
      expect(message, isNot(contains('android')));
    });

    test('builds FCM HTTP v1 Android priority payload', () {
      final request = MobilePushSendRequest(
        token: 'device-token',
        platform: 'android',
        title: 'Approval needed',
        body: 'A workflow gate is waiting.',
        data: const <String, Object?>{'event_id': 'evt-2'},
      );

      final message =
          request.toFcmHttpV1Json()['message']! as Map<String, Object?>;
      expect(message['android'], equals(<String, Object?>{'priority': 'HIGH'}));
      expect(message, isNot(contains('apns')));
    });

    test(
      'rejects secret-shaped data keys before building provider payload',
      () {
        expect(
          () => MobilePushSendRequest(
            token: 'device-token',
            platform: 'android',
            title: 'Nope',
            body: 'Nope',
            data: const <String, Object?>{'refresh_token': 'secret'},
          ),
          throwsA(
            isA<MobilePushGatewayException>().having(
              (e) => e.code,
              'code',
              'push_payload_contains_secret_key',
            ),
          ),
        );
      },
    );
  });

  group('Flutter client secret lint', () {
    test('Flutter-facing files do not embed server push credentials', () {
      final roots = <String>[
        'lib/forge_flow_app.dart',
        'lib/main_forgeflow.dart',
        'lib/main_operator_web.dart',
        'lib/screens',
        'lib/widgets',
      ];
      final banned = <RegExp>[
        RegExp('FCM_SERVER_KEY', caseSensitive: false),
        RegExp('FIREBASE_ADMINSDK', caseSensitive: false),
        RegExp('GOOGLE_APPLICATION_CREDENTIALS', caseSensitive: false),
        RegExp('private_key', caseSensitive: false),
        RegExp('client_email', caseSensitive: false),
      ];

      final hits = <String>[];
      for (final root in roots) {
        final type = FileSystemEntity.typeSync(root);
        final files = type == FileSystemEntityType.directory
            ? Directory(root)
                  .listSync(recursive: true)
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.dart'))
            : <File>[File(root)].where((f) => f.existsSync());
        for (final file in files) {
          final source = file.readAsStringSync();
          for (final pattern in banned) {
            if (pattern.hasMatch(source)) {
              hits.add('${file.path}: ${pattern.pattern}');
            }
          }
        }
      }

      expect(
        hits,
        isEmpty,
        reason:
            'mobile clients must not carry Firebase Admin/FCM server credentials',
      );
    });
  });
}
