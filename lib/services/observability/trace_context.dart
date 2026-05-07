// Forge & Flow — W3C Trace Context (traceparent) support.
//
// Implements W3C Trace Context Level 1 (https://www.w3.org/TR/trace-context/)
// WITHOUT pulling in the OpenTelemetry SDK. The spec is small enough to
// implement manually: a 16-byte trace ID, an 8-byte span ID, and a 1-byte
// flags field, all encoded as lowercase hex in the `traceparent` header.
//
// Format:
//   traceparent: <version>-<trace-id>-<parent-id>-<flags>
//   version   : "00"             (2 hex chars — only version defined)
//   trace-id  : 32 hex chars     (128-bit unique trace identifier)
//   parent-id : 16 hex chars     (64-bit span identifier for this hop)
//   flags     : "01"             (sampled) | "00" (not sampled)
//
// How it threads through the proxy:
//   1. The request handler extracts the incoming `traceparent` header via
//      [TraceContext.fromHeader]. If absent, it generates a fresh one via
//      [TraceContext.generate].
//   2. The [ProxyLogContext] is extended with [TraceContext] so every
//      structured log line from [log()] includes `trace_id` and `span_id`.
//   3. When a Postgres connection is acquired, the bootstrap calls:
//        SET LOCAL application_name = 'op:<operator_id>;trace:<trace_id>'
//      so database logs carry the trace id for correlation.
//   4. Outbound HTTP calls to vendor adapters and AI providers include the
//      `traceparent` header propagated from the active [TraceContext].
//
// Thread safety: [TraceContext] is immutable; new [TraceContext] instances
// are created for child spans via [childSpan].

import 'dart:math' as math;
import 'dart:typed_data';

/// An immutable W3C Trace Context (traceparent) value.
///
/// Use [TraceContext.generate] to create a root span.
/// Use [TraceContext.fromHeader] to parse an incoming traceparent header.
/// Use [childSpan] to create a new span within the same trace.
class TraceContext {
  /// Creates a [TraceContext] with the given raw byte values.
  ///
  /// [traceId] must be 16 bytes; [spanId] must be 8 bytes.
  /// [sampled] controls the flags byte: `true` → 0x01, `false` → 0x00.
  const TraceContext._({
    required this.traceIdBytes,
    required this.spanIdBytes,
    required this.sampled,
  });

  /// The 128-bit (16-byte) trace identifier. Shared across the entire trace.
  final Uint8List traceIdBytes;

  /// The 64-bit (8-byte) span identifier for this particular hop/span.
  final Uint8List spanIdBytes;

  /// Whether this trace is sampled (flags bit 0 = 1).
  final bool sampled;

  // ── Accessors ──────────────────────────────────────────────────────────────

  /// The trace ID as a 32-character lowercase hex string (no dashes).
  String get traceId => _bytesToHex(traceIdBytes);

  /// The span ID as a 16-character lowercase hex string (no dashes).
  String get spanId => _bytesToHex(spanIdBytes);

  /// The flags byte as a 2-character hex string: `"01"` (sampled) or `"00"`.
  String get flags => sampled ? '01' : '00';

  /// The full `traceparent` header value per W3C spec version 00.
  ///
  /// Example: `"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"`
  String get headerValue => '00-$traceId-$spanId-$flags';

  // ── Constructors ───────────────────────────────────────────────────────────

  /// Generates a fresh root-level [TraceContext] with a new trace ID and span ID.
  ///
  /// Always sampled. Use this for requests that arrive without a `traceparent`
  /// header (i.e. requests originating from mobile clients or health checks).
  factory TraceContext.generate() {
    return TraceContext._(
      traceIdBytes: _randomBytes(16),
      spanIdBytes: _randomBytes(8),
      sampled: true,
    );
  }

  /// Parses a `traceparent` header value.
  ///
  /// Returns `null` if the header is absent, malformed, or uses an unsupported
  /// version prefix. Malformed headers should be treated as if absent —
  /// generate a fresh [TraceContext] via [TraceContext.generate].
  ///
  /// Per W3C spec: a parser MUST accept and forward any version, but may treat
  /// an unrecognised version as opaque (we do: forward the trace-id, generate
  /// a new span-id, preserve flags).
  static TraceContext? fromHeader(String? headerValue) {
    if (headerValue == null || headerValue.isEmpty) return null;
    // Expected format: <version(2)>-<trace-id(32)>-<parent-id(16)>-<flags(2)>
    final parts = headerValue.split('-');
    if (parts.length < 4) return null;
    final version = parts[0];
    // Version "ff" is explicitly invalid per W3C spec.
    if (version == 'ff') return null;
    // Validate lengths.
    if (parts[1].length != 32) return null;
    if (parts[2].length != 16) return null;
    if (parts[3].length != 2) return null;
    // All-zero trace-id is invalid per spec.
    if (parts[1] == '0' * 32) return null;
    // All-zero parent-id is invalid per spec.
    if (parts[2] == '0' * 16) return null;
    // Parse hex.
    final traceIdBytes = _hexToBytes(parts[1]);
    if (traceIdBytes == null) return null;
    final flagsByte = int.tryParse(parts[3], radix: 16);
    if (flagsByte == null) return null;
    final sampled = (flagsByte & 0x01) == 0x01;
    // Generate a new span ID for this hop (the incoming parent-id becomes our
    // "parent-span-id" in a full OTel model, but we only track one level).
    return TraceContext._(
      traceIdBytes: traceIdBytes,
      spanIdBytes: _randomBytes(8),
      sampled: sampled,
    );
  }

  // ── Child span ─────────────────────────────────────────────────────────────

  /// Creates a child span within the same trace. The [traceId] is preserved;
  /// a new [spanId] is generated. Used when the proxy makes an outbound call
  /// on behalf of the same inbound request.
  TraceContext childSpan() {
    return TraceContext._(
      traceIdBytes: traceIdBytes,
      spanIdBytes: _randomBytes(8),
      sampled: sampled,
    );
  }

  // ── Postgres application_name value ────────────────────────────────────────

  /// Formats the Postgres `application_name` value to be set via
  /// `SET LOCAL application_name = '<value>'` at the start of each
  /// tenant transaction.
  ///
  /// Format: `op:<operator_id>;trace:<trace_id>` — stays under 63 chars
  /// (Postgres `NAMEDATALEN` limit minus one for the null terminator).
  ///
  /// [operatorId] should be the UUID string (36 chars). If null, the
  /// operator segment is omitted: `sys;trace:<trace_id>`.
  String postgresApplicationName({String? operatorId}) {
    final opSegment =
        operatorId != null ? 'op:$operatorId' : 'sys';
    // Full format: "op:<uuid(36)>;trace:<trace_id(32)>" = 76 chars — over limit.
    // Truncate trace_id to first 16 chars (still unique enough for correlation).
    final shortTrace = traceId.substring(0, 16);
    return '$opSegment;tr:$shortTrace';
  }

  // ── Equality ───────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TraceContext &&
        traceId == other.traceId &&
        spanId == other.spanId &&
        sampled == other.sampled;
  }

  @override
  int get hashCode => Object.hash(traceId, spanId, sampled);

  @override
  String toString() => 'TraceContext($headerValue)';

  // ── Private helpers ────────────────────────────────────────────────────────

  static final math.Random _rng = math.Random.secure();

  static Uint8List _randomBytes(int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = _rng.nextInt(256);
    }
    return bytes;
  }

  static String _bytesToHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Parses a 32-char or 16-char hex string into a [Uint8List].
  /// Returns null if the string contains non-hex characters.
  static Uint8List? _hexToBytes(String hex) {
    if (hex.length.isOdd) return null;
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte == null) return null;
      bytes[i ~/ 2] = byte;
    }
    return bytes;
  }
}

/// The W3C `traceparent` HTTP header name.
const String traceParentHeaderName = 'traceparent';

/// The W3C `tracestate` HTTP header name (carried through but not modified).
const String traceStateHeaderName = 'tracestate';
