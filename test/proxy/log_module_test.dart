// HARD-G observability — log module tests.
//
// Verifies the JSON envelope shape, Cloud Logging severity mapping,
// sensitive-field redaction, and UUID v4 helpers. The log module
// writes to an injectable IOSink so tests can capture lines without
// touching real stdout.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/log.dart';

class _CapturingSink implements IOSink {
  final List<String> lines = <String>[];

  @override
  Encoding encoding = utf8;

  @override
  void writeln([Object? object = '']) {
    lines.add(object?.toString() ?? '');
  }

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
}

Map<String, Object?> _firstEnvelope(_CapturingSink sink) {
  expect(
    sink.lines,
    isNotEmpty,
    reason: 'expected at least one log line to be emitted',
  );
  final decoded = jsonDecode(sink.lines.first);
  return Map<String, Object?>.from(decoded as Map);
}

void main() {
  group('log module envelope shape', () {
    test('emits ts, severity, event, fields by default', () {
      final sink = _CapturingSink();
      final fixedNow = DateTime.utc(2026, 5, 2, 18, 23, 41, 123);
      log(
        LogSeverity.info,
        'auth.login.ok',
        fields: <String, Object?>{'user_id_hash': 'abc'},
        sink: sink,
        now: () => fixedNow,
      );
      final envelope = _firstEnvelope(sink);
      expect(envelope['ts'], equals(fixedNow.toIso8601String()));
      expect(envelope['severity'], equals('INFO'));
      expect(envelope['event'], equals('auth.login.ok'));
      expect(envelope['fields'], equals({'user_id_hash': 'abc'}));
      // No correlation_id / request_id when there is no context.
      expect(envelope.containsKey('correlation_id'), isFalse);
      expect(envelope.containsKey('request_id'), isFalse);
    });

    test('explicit context populates correlation_id, request_id, '
        'operator_id', () {
      final sink = _CapturingSink();
      log(
        LogSeverity.warning,
        'auth.session.refreshed',
        context: const ProxyLogContext(
          correlationId: '11111111-1111-4111-8111-111111111111',
          requestId: '22222222-2222-4222-8222-222222222222',
          operatorId: '33333333-3333-4333-8333-333333333333',
        ),
        sink: sink,
        now: () => DateTime.utc(2026, 5, 2),
      );
      final envelope = _firstEnvelope(sink);
      expect(envelope['severity'], equals('WARNING'));
      expect(
        envelope['correlation_id'],
        equals('11111111-1111-4111-8111-111111111111'),
      );
      expect(
        envelope['request_id'],
        equals('22222222-2222-4222-8222-222222222222'),
      );
      expect(
        envelope['operator_id'],
        equals('33333333-3333-4333-8333-333333333333'),
      );
    });

    test('zone-scoped context flows into nested log calls', () async {
      final sink = _CapturingSink();
      await withProxyLogContext(
        const ProxyLogContext(
          correlationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          requestId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        ),
        () async {
          log(
            LogSeverity.error,
            'proxy.unhandled_error',
            sink: sink,
            now: () => DateTime.utc(2026, 5, 2),
          );
        },
      );
      final envelope = _firstEnvelope(sink);
      expect(
        envelope['correlation_id'],
        equals('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),
      );
      expect(
        envelope['request_id'],
        equals('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
      );
    });

    test('bindOperatorIdToLogContext threads operator_id into '
        'subsequent log calls in the same zone', () async {
      final sink = _CapturingSink();
      addTearDown(() async => sink.close());
      await withProxyLogContext(
        const ProxyLogContext(
          correlationId: '11111111-1111-4111-8111-111111111111',
          requestId: '22222222-2222-4222-8222-222222222222',
        ),
        () async {
          log(LogSeverity.info, 'before_auth',
              sink: sink, now: () => DateTime.utc(2026, 5, 2));
          bindOperatorIdToLogContext(
            '33333333-3333-4333-8333-333333333333',
          );
          log(LogSeverity.info, 'after_auth',
              sink: sink, now: () => DateTime.utc(2026, 5, 2));
        },
      );
      expect(sink.lines.length, equals(2));
      final before =
          jsonDecode(sink.lines[0]) as Map<String, dynamic>;
      final after = jsonDecode(sink.lines[1]) as Map<String, dynamic>;
      expect(before['operator_id'], isNull);
      expect(
        after['operator_id'],
        equals('33333333-3333-4333-8333-333333333333'),
      );
      // Correlation + request ids stay stable across the bind.
      expect(before['correlation_id'], equals(after['correlation_id']));
      expect(before['request_id'], equals(after['request_id']));
    });
  });

  group('Cloud Logging severity mapping', () {
    test('every LogSeverity has a non-empty Cloud Logging string', () {
      for (final value in LogSeverity.values) {
        expect(value.cloudLoggingValue, isNotEmpty);
      }
    });

    test('expected mappings match Cloud Logging vocabulary', () {
      expect(LogSeverity.debug.cloudLoggingValue, equals('DEBUG'));
      expect(LogSeverity.info.cloudLoggingValue, equals('INFO'));
      expect(LogSeverity.notice.cloudLoggingValue, equals('NOTICE'));
      expect(LogSeverity.warning.cloudLoggingValue, equals('WARNING'));
      expect(LogSeverity.error.cloudLoggingValue, equals('ERROR'));
      expect(LogSeverity.critical.cloudLoggingValue, equals('CRITICAL'));
    });
  });

  group('sensitive-field redaction', () {
    test('drops contract-listed sensitive keys', () {
      final sink = _CapturingSink();
      log(
        LogSeverity.info,
        'auth.password_change.completed',
        fields: <String, Object?>{
          'password': 'super-secret-1',
          'current_password': 'super-secret-1',
          'new_password': 'super-secret-2',
          'recovery_code': 'XXXX-YYYY',
          'recovery_codes': const <String>['a', 'b'],
          'mfa_code': '123456',
          'totp_code': '654321',
          'totp_secret': 'JBSWY3DPEHPK3PXP',
          'authorization': 'Bearer …',
          'authorization_id_token': 'eyJ…',
          'id_token': 'eyJ…',
          'access_token': 'ya29.…',
          'refresh_token': '1//04…',
          'jwt': 'eyJ…',
          'jwt_body': 'eyJ…',
          'bearer_token': 'eyJ…',
          'prompt': 'top-secret system prompt',
          'raw_prompt': 'top-secret raw prompt',
          'vendor_payload': const <String, String>{'cipher': 'x'},
          'raw_vendor_payload': 'opaque',
          'plaintext': 'super-secret-rotated-value',
          'email': 'admin@example.com',
          'user_email': 'admin@example.com',
          'primary_email': 'admin@example.com',
          'safe_field': 'shown',
        },
        sink: sink,
        now: () => DateTime.utc(2026, 5, 2),
      );
      final envelope = _firstEnvelope(sink);
      final fields = Map<String, Object?>.from(
        envelope['fields'] as Map,
      );
      const sensitive = <String>{
        'password',
        'current_password',
        'new_password',
        'recovery_code',
        'recovery_codes',
        'mfa_code',
        'totp_code',
        'totp_secret',
        'authorization',
        'authorization_id_token',
        'id_token',
        'access_token',
        'refresh_token',
        'jwt',
        'jwt_body',
        'bearer_token',
        'prompt',
        'raw_prompt',
        'vendor_payload',
        'raw_vendor_payload',
        'plaintext',
        'email',
        'user_email',
        'primary_email',
      };
      for (final name in sensitive) {
        expect(
          fields.containsKey(name),
          isFalse,
          reason: 'sensitive field "$name" must be redacted',
        );
      }
      expect(fields['safe_field'], equals('shown'));
      // Defense in depth: the raw line cannot contain any of the
      // redacted values.
      final raw = sink.lines.single;
      expect(raw.contains('super-secret-1'), isFalse);
      expect(raw.contains('super-secret-2'), isFalse);
      expect(raw.contains('XXXX-YYYY'), isFalse);
      expect(raw.contains('super-secret-rotated-value'), isFalse);
      expect(raw.contains('admin@example.com'), isFalse);
    });

    test('recursively redacts nested maps and lists', () async {
      final sink = _CapturingSink();
      addTearDown(() async => sink.close());
      log(
        LogSeverity.info,
        'audit.write_failed',
        fields: <String, Object?>{
          'context': <String, Object?>{
            'password': 'leak-1',
            'note': 'safe',
          },
          'history': <Object?>[
            <String, Object?>{'mfa_code': '000000', 'kept': 'yes'},
          ],
        },
        sink: sink,
        now: () => DateTime.utc(2026, 5, 2),
      );
      final raw = sink.lines.single;
      expect(raw.contains('leak-1'), isFalse);
      expect(raw.contains('000000'), isFalse);
      expect(raw.contains('safe'), isTrue);
      expect(raw.contains('"kept":"yes"'), isTrue);
    });
  });

  group('UUID helpers', () {
    test('generateUuidV4 returns a valid v4 UUID', () {
      final value = generateUuidV4();
      expect(isValidUuidV4(value), isTrue, reason: 'generated: $value');
    });

    test('isValidUuidV4 rejects non-v4 / malformed values', () {
      expect(
        isValidUuidV4('11111111-1111-1111-8111-111111111111'),
        isFalse,
        reason: 'version nibble is 1, not 4',
      );
      expect(
        isValidUuidV4('11111111-1111-4111-7111-111111111111'),
        isFalse,
        reason: 'variant nibble is 7, not [89ab]',
      );
      expect(isValidUuidV4('not-a-uuid'), isFalse);
      expect(isValidUuidV4(''), isFalse);
    });

    test('correlationIdHeaderName is exactly X-Correlation-Id', () {
      expect(correlationIdHeaderName, equals('X-Correlation-Id'));
    });
  });
}
