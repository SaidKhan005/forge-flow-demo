// B4 observability — TraceContext W3C trace-context round-trip tests.
//
// Verifies:
//   - [TraceContext.generate] produces a valid traceparent header.
//   - [TraceContext.fromHeader] round-trips the trace_id through the proxy.
//   - [TraceContext.fromHeader] rejects malformed / all-zero / version-ff headers.
//   - [childSpan] preserves trace_id, generates a new span_id.
//   - [postgresApplicationName] stays within 63 chars (Postgres NAMEDATALEN limit).
//   - [ProxyLogContext.withTraceContext] binds the trace so [log()] emits trace_id.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/observability/trace_context.dart';
import 'package:forge_and_flow/services/observability/log.dart';

void main() {
  group('TraceContext.generate', () {
    test('produces a valid traceparent header string', () {
      final ctx = TraceContext.generate();
      final header = ctx.headerValue;

      // Format: 00-<32 hex>-<16 hex>-01
      final parts = header.split('-');
      expect(parts, hasLength(4));
      expect(parts[0], equals('00'));
      expect(parts[1], hasLength(32));
      expect(parts[2], hasLength(16));
      expect(parts[3], equals('01')); // sampled
    });

    test('traceId and spanId are lowercase hex', () {
      final ctx = TraceContext.generate();
      final hexChars = RegExp(r'^[0-9a-f]+$');
      expect(hexChars.hasMatch(ctx.traceId), isTrue,
          reason: 'traceId must be lowercase hex');
      expect(hexChars.hasMatch(ctx.spanId), isTrue,
          reason: 'spanId must be lowercase hex');
    });

    test('each call generates a unique traceId', () {
      final ids = List.generate(10, (_) => TraceContext.generate().traceId);
      expect(ids.toSet().length, equals(10),
          reason: 'Each generated traceId must be unique');
    });

    test('traceId is 32 chars, spanId is 16 chars', () {
      final ctx = TraceContext.generate();
      expect(ctx.traceId.length, equals(32));
      expect(ctx.spanId.length, equals(16));
    });
  });

  group('TraceContext.fromHeader — valid headers', () {
    test('round-trips trace_id from a well-formed header', () {
      final original = TraceContext.generate();
      final headerValue = original.headerValue;

      final parsed = TraceContext.fromHeader(headerValue);

      expect(parsed, isNotNull);
      // trace_id must survive the round-trip unchanged.
      expect(parsed!.traceId, equals(original.traceId));
    });

    test('generates a new span_id (this hop) while preserving trace_id', () {
      final original = TraceContext.generate();
      final parsed = TraceContext.fromHeader(original.headerValue)!;

      expect(parsed.traceId, equals(original.traceId));
      // The new hop should have a different span_id.
      expect(parsed.spanId, isNot(equals(original.spanId)));
    });

    test('preserves sampled flag = true', () {
      const header = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
      final ctx = TraceContext.fromHeader(header)!;
      expect(ctx.sampled, isTrue);
      expect(ctx.flags, equals('01'));
    });

    test('preserves sampled flag = false', () {
      const header = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00';
      final ctx = TraceContext.fromHeader(header)!;
      expect(ctx.sampled, isFalse);
      expect(ctx.flags, equals('00'));
    });

    test('accepts non-00 version prefix (forward compatibility)', () {
      // A future version with same field layout should still parse trace_id.
      const header = '99-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
      final ctx = TraceContext.fromHeader(header);
      expect(ctx, isNotNull);
      expect(ctx!.traceId, equals('4bf92f3577b34da6a3ce929d0e0e4736'));
    });
  });

  group('TraceContext.fromHeader — invalid headers', () {
    test('returns null for null input', () {
      expect(TraceContext.fromHeader(null), isNull);
    });

    test('returns null for empty string', () {
      expect(TraceContext.fromHeader(''), isNull);
    });

    test('returns null for version ff', () {
      const header = 'ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';
      expect(TraceContext.fromHeader(header), isNull);
    });

    test('returns null for all-zero trace-id', () {
      const header = '00-00000000000000000000000000000000-00f067aa0ba902b7-01';
      expect(TraceContext.fromHeader(header), isNull);
    });

    test('returns null for all-zero parent-id', () {
      const header = '00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01';
      expect(TraceContext.fromHeader(header), isNull);
    });

    test('returns null for too-short trace-id', () {
      const header = '00-4bf92f-00f067aa0ba902b7-01';
      expect(TraceContext.fromHeader(header), isNull);
    });

    test('returns null for non-hex trace-id', () {
      const header = '00-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-00f067aa0ba902b7-01';
      expect(TraceContext.fromHeader(header), isNull);
    });

    test('returns null for header with fewer than 4 parts', () {
      expect(TraceContext.fromHeader('00-4bf92f3577b34da6a3ce929d0e0e4736'), isNull);
    });
  });

  group('TraceContext.childSpan', () {
    test('preserves trace_id, generates new span_id', () {
      final parent = TraceContext.generate();
      final child = parent.childSpan();

      expect(child.traceId, equals(parent.traceId));
      expect(child.spanId, isNot(equals(parent.spanId)));
    });

    test('child headerValue uses same trace_id as parent', () {
      final parent = TraceContext.generate();
      final child = parent.childSpan();
      final childParts = child.headerValue.split('-');
      expect(childParts[1], equals(parent.traceId));
    });
  });

  group('TraceContext.postgresApplicationName', () {
    test('stays within 63 chars with a UUID operator_id', () {
      final ctx = TraceContext.generate();
      final appName = ctx.postgresApplicationName(
        operatorId: '550e8400-e29b-41d4-a716-446655440000',
      );
      expect(appName.length, lessThanOrEqualTo(63),
          reason: 'Must fit in Postgres NAMEDATALEN (63 usable chars)');
    });

    test('stays within 63 chars without operator_id', () {
      final ctx = TraceContext.generate();
      final appName = ctx.postgresApplicationName();
      expect(appName.length, lessThanOrEqualTo(63));
    });

    test('includes trace segment when no operator_id', () {
      final ctx = TraceContext.generate();
      final appName = ctx.postgresApplicationName();
      expect(appName, contains('sys'));
      expect(appName, contains('tr:'));
    });

    test('includes operator_id prefix when operator_id given', () {
      final ctx = TraceContext.generate();
      const opId = '550e8400-e29b-41d4-a716-446655440000';
      final appName = ctx.postgresApplicationName(operatorId: opId);
      expect(appName, startsWith('op:$opId'));
    });
  });

  group('ProxyLogContext + log() trace emission', () {
    test('log() emits trace_id and span_id when traceContext is bound', () async {
      final traceCtx = TraceContext.generate();
      final logCtx = ProxyLogContext(
        correlationId: 'corr-001',
        requestId: 'req-001',
        traceContext: traceCtx,
      );

      final captured = StringBuffer();
      final sink = _StringBufferSink(captured);

      log(
        LogSeverity.info,
        'test.trace.emission',
        context: logCtx,
        sink: sink,
        fields: {'foo': 'bar'},
      );
      await sink.close();

      final line = captured.toString().trim();
      expect(line.isNotEmpty, isTrue);
      final Map<String, dynamic> envelope =
          jsonDecode(line) as Map<String, dynamic>;

      expect(envelope['trace_id'], equals(traceCtx.traceId));
      expect(envelope['span_id'], equals(traceCtx.spanId));
    });

    test('log() omits trace fields when traceContext is null', () async {
      final logCtx = ProxyLogContext(
        correlationId: 'corr-002',
        requestId: 'req-002',
        // no traceContext
      );

      final captured = StringBuffer();
      final sink = _StringBufferSink(captured);

      log(
        LogSeverity.info,
        'test.no.trace',
        context: logCtx,
        sink: sink,
      );
      await sink.close();

      final envelope =
          jsonDecode(captured.toString().trim()) as Map<String, dynamic>;
      expect(envelope.containsKey('trace_id'), isFalse);
      expect(envelope.containsKey('span_id'), isFalse);
    });

    test('withTraceContext returns a new context with trace bound', () {
      final traceCtx = TraceContext.generate();
      final base = ProxyLogContext(
        correlationId: 'corr-003',
        requestId: 'req-003',
      );
      final bound = base.withTraceContext(traceCtx);

      expect(bound.traceContext, equals(traceCtx));
      expect(bound.correlationId, equals(base.correlationId));
      expect(bound.requestId, equals(base.requestId));
    });
  });

  group('Constants', () {
    test('traceParentHeaderName is correct W3C name', () {
      expect(traceParentHeaderName, equals('traceparent'));
    });

    test('traceStateHeaderName is correct W3C name', () {
      expect(traceStateHeaderName, equals('tracestate'));
    });
  });
}

/// In-memory [IOSink] substitute for testing [log()].
class _StringBufferSink implements IOSink {
  _StringBufferSink(this._buffer);
  final StringBuffer _buffer;

  @override
  void writeln([Object? obj = '']) {
    _buffer.writeln(obj);
  }

  @override
  void write(Object? obj) => _buffer.write(obj);

  @override
  Encoding get encoding => utf8;

  @override
  set encoding(Encoding value) {}

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    _buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) {
    _buffer.writeCharCode(charCode);
  }
}
