// Forge & Flow advisor proxy — structured JSON logging.
//
// HARD-G observability baseline. Every log event is one JSON object
// per stdout line, shaped for Google Cloud Logging:
//   {
//     "ts":"2026-05-02T18:23:41.123Z",
//     "severity":"INFO",
//     "event":"auth.login.ok",
//     "correlation_id":"…",
//     "request_id":"…",
//     "operator_id":"…",
//     "trace_id":"…",   ← W3C trace-id from traceparent header
//     "span_id":"…",    ← W3C span-id for this hop
//     "fields":{ … domain payload … }
//   }
//
// Sensitive fields are dropped before serialization (see
// [_sensitiveFieldNames]). The list mirrors the contract: passwords,
// recovery codes, raw prompts, raw vendor payloads, JWT bodies, TOTP
// secrets, MFA codes, and full email addresses. Plaintext from KMS
// rotations is also dropped.
//
// Distributed tracing: [ProxyLogContext] carries an optional
// [TraceContext]. When present, [log] emits `trace_id` and `span_id`
// fields in every envelope, enabling cross-service trace correlation
// in Cloud Logging and Cloud Trace.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'trace_context.dart';

/// Severity tier. Names map to Cloud Logging textual severity.
enum LogSeverity {
  debug,
  info,
  notice,
  warning,
  error,
  critical;

  String get cloudLoggingValue {
    switch (this) {
      case LogSeverity.debug:
        return 'DEBUG';
      case LogSeverity.info:
        return 'INFO';
      case LogSeverity.notice:
        return 'NOTICE';
      case LogSeverity.warning:
        return 'WARNING';
      case LogSeverity.error:
        return 'ERROR';
      case LogSeverity.critical:
        return 'CRITICAL';
    }
  }
}

/// Per-request context. Set on the current zone via
/// [withProxyLogContext] so every nested log call picks up the IDs
/// without threading them through call sites.
///
/// [traceContext] carries the W3C `traceparent` state for the active
/// request. When present, [log] emits `trace_id` and `span_id` in
/// every log envelope. Bind it via [withTraceContext] after extracting
/// the `traceparent` header from the inbound HTTP request.
class ProxyLogContext {
  const ProxyLogContext({
    required this.correlationId,
    required this.requestId,
    this.operatorId,
    this.traceContext,
  });

  final String correlationId;
  final String requestId;
  final String? operatorId;

  /// W3C Trace Context for this request. Extracted from the inbound
  /// `traceparent` header, or generated fresh if the header is absent.
  final TraceContext? traceContext;

  ProxyLogContext withOperatorId(String? operatorId) {
    return ProxyLogContext(
      correlationId: correlationId,
      requestId: requestId,
      operatorId: operatorId,
      traceContext: traceContext,
    );
  }

  /// Returns a new [ProxyLogContext] with [traceContext] bound.
  ProxyLogContext withTraceContext(TraceContext traceContext) {
    return ProxyLogContext(
      correlationId: correlationId,
      requestId: requestId,
      operatorId: operatorId,
      traceContext: traceContext,
    );
  }
}

/// Mutable holder for the per-request log context. Threaded through
/// the zone (instead of the immutable [ProxyLogContext] directly) so
/// that after authentication resolves an operator id, the route
/// handler can call [bindOperatorIdToLogContext] to update the active
/// scope and have every later [log] call automatically include
/// `operator_id`.
class _ProxyLogContextRef {
  _ProxyLogContextRef(this.context);

  ProxyLogContext context;
}

const Object _proxyLogContextZoneKey = #proxy_log_context_ref;

_ProxyLogContextRef? _currentProxyLogContextRef() {
  final value = Zone.current[_proxyLogContextZoneKey];
  return value is _ProxyLogContextRef ? value : null;
}

/// Returns the current zone's proxy log context, or `null` if none.
ProxyLogContext? currentProxyLogContext() =>
    _currentProxyLogContextRef()?.context;

/// Runs [body] with [context] as the active proxy log context. Calls
/// to [log] inside [body] (and any awaited continuations) pick up the
/// context's correlation_id / request_id / operator_id automatically.
Future<T> withProxyLogContext<T>(
  ProxyLogContext context,
  Future<T> Function() body,
) {
  final ref = _ProxyLogContextRef(context);
  return runZoned<Future<T>>(
    body,
    zoneValues: <Object?, Object?>{_proxyLogContextZoneKey: ref},
  );
}

/// Binds [operatorId] onto the active zone's log context. No-op when
/// no zone is active or the operator id is already at the same value.
/// After this call, every [log] from this point forward in the
/// request inherits the bound operator id.
void bindOperatorIdToLogContext(String? operatorId) {
  final ref = _currentProxyLogContextRef();
  if (ref == null) return;
  if (ref.context.operatorId == operatorId) return;
  ref.context = ref.context.withOperatorId(operatorId);
}

/// Emit one JSON log line.
///
/// [context] overrides the zone-scoped context (handy for the startup
/// banner where there is no per-request zone). [now] and [sink] are
/// injectable for tests.
void log(
  LogSeverity severity,
  String event, {
  Map<String, Object?> fields = const <String, Object?>{},
  ProxyLogContext? context,
  DateTime Function()? now,
  IOSink? sink,
}) {
  final clock = now ?? DateTime.now;
  final effectiveContext = context ?? currentProxyLogContext();
  final envelope = <String, Object?>{
    'ts': clock().toUtc().toIso8601String(),
    'severity': severity.cloudLoggingValue,
    'event': event,
    if (effectiveContext != null) ...<String, Object?>{
      'correlation_id': effectiveContext.correlationId,
      'request_id': effectiveContext.requestId,
      if (effectiveContext.operatorId != null)
        'operator_id': effectiveContext.operatorId,
      // W3C Trace Context — emitted when a traceparent is active so Cloud
      // Logging can correlate log lines to a distributed trace.
      if (effectiveContext.traceContext != null) ...<String, Object?>{
        'trace_id': effectiveContext.traceContext!.traceId,
        'span_id': effectiveContext.traceContext!.spanId,
        // Cloud Trace integration: the `logging.googleapis.com/trace` field
        // links the log line to the Cloud Trace UI entry for this trace.
        'logging.googleapis.com/trace':
            'projects/__PROJECT__/traces/${effectiveContext.traceContext!.traceId}',
        'logging.googleapis.com/spanId':
            effectiveContext.traceContext!.spanId,
        'logging.googleapis.com/traceSampled':
            effectiveContext.traceContext!.sampled,
      },
    },
    'fields': _redactFields(fields),
  };
  (sink ?? stdout).writeln(jsonEncode(envelope));
}

/// Sensitive-field names to drop before serialization. Lower-cased
/// match. Email-flavored keys (`*email*`) are also dropped.
const Set<String> _sensitiveFieldNames = <String>{
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
};

Map<String, Object?> _redactFields(Map<String, Object?> fields) {
  if (fields.isEmpty) return const <String, Object?>{};
  final out = <String, Object?>{};
  for (final entry in fields.entries) {
    if (_isSensitiveKey(entry.key)) {
      continue;
    }
    final value = entry.value;
    if (value is Map<String, Object?>) {
      out[entry.key] = _redactFields(value);
    } else if (value is Map) {
      out[entry.key] = _redactFields(
        value.map((k, v) => MapEntry(k.toString(), v)),
      );
    } else if (value is List) {
      out[entry.key] = value.map((item) {
        if (item is Map<String, Object?>) return _redactFields(item);
        if (item is Map) {
          return _redactFields(
            item.map((k, v) => MapEntry(k.toString(), v)),
          );
        }
        return item;
      }).toList(growable: false);
    } else {
      out[entry.key] = value;
    }
  }
  return out;
}

bool _isSensitiveKey(String key) {
  final lower = key.toLowerCase();
  if (_sensitiveFieldNames.contains(lower)) return true;
  // Drop full email addresses. Hashed / derived forms
  // (`*_email_hash`, `email_domain`) are allowed because they are
  // not full PII — operators MUST hash before logging when an
  // email-flavored field is genuinely needed.
  if (lower == 'email' ||
      lower == 'email_address' ||
      lower.endsWith('_email') ||
      lower.endsWith('_email_address')) {
    return true;
  }
  return false;
}

/// UUID v4 validation (case-insensitive). Used by the route-level
/// correlation handler to reject malformed inbound IDs.
final RegExp _uuidV4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool isValidUuidV4(String value) => _uuidV4Pattern.hasMatch(value);

final math.Random _uuidRng = math.Random.secure();

/// Generates a fresh RFC-4122 v4 UUID.
String generateUuidV4() {
  final bytes = Uint8List(16);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = _uuidRng.nextInt(256);
  }
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => bytes
      .sublist(start, end)
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-'
      '${hex(8, 10)}-${hex(10, 16)}';
}

/// Header name carrying the inbound correlation id. Per contract this
/// MUST be exactly `X-Correlation-Id` — case-insensitive at the HTTP
/// layer but emitted on responses with this casing.
const String correlationIdHeaderName = 'X-Correlation-Id';

/// Returns the first frame of [stack] for inclusion in error log
/// envelopes. Full stack traces are not emitted to keep log lines
/// bounded; operators view full traces in Cloud Logging via
/// `jsonPayload.fields.error_message` plus the request's correlation
/// id.
String firstStackFrame(StackTrace stack) {
  final text = stack.toString();
  final newline = text.indexOf('\n');
  return newline == -1 ? text : text.substring(0, newline);
}
