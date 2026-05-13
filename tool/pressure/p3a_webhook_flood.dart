// Phase 3A — webhook flood load harness against the preview proxy.
//
// Sprint: `pressure.preview.v1` Phase 3 of 4 stack levels (Phase 3A
// of three load lanes — see `test/pressure/README.md`).
//
// Purpose
// -------
// Drive realistic vendor webhook traffic at the preview Cloud Run
// proxy at controlled concurrency, capturing per-request status and
// latency, and surface holes that synthetic / unit tests miss. The
// preview proxy is runtime-isolated (separate Cloud Run revision) but
// shares staging Postgres — operator-approved for bounded load (see
// `docs/_execution/2026-05-08_pressure_preview_v1_plan.md`).
//
// What this lane proves (or surfaces holes in)
// ---------------------------------------------
//   1. Idempotency under retry storms — the same fixture POSTed N
//      times produces ONE row written; replays return the cached
//      response pattern. (Framework idempotency UNIQUE on
//      `(vendor_id, operator_id, vendor_event_id)`; harness-side
//      `Idempotency-Key` header is reserved for admin write routes.
//      For webhooks the test for idempotency is whether replays of
//      the same body produce the same response code class.)
//   2. Proxy stability — no 5xx errors under sustained load; p95
//      latency stays under a documented budget (default 2000 ms).
//   3. Per-vendor signature verification holds — forged-signature
//      fixtures (`scenario_a_forged_signature.json`) return 401/403,
//      NOT 5xx (verifier MUST NOT crash on adversarial input).
//   4. DB connection pool doesn't exhaust — under smoke scale, no
//      `connection_acquire_timeout` patterns surface. Mode posture
//      is documented in `runbooks/preview_environment_runbook.md`
//      (`proxy.startup.deferred`).
//
// Design
// ------
// * Per-(operator, vendor) loop emits one event per `--rate` slot.
// * Synthetic operators are UUID-stable per run so the load lane is
//   isolated from real staging tenants. The harness does NOT clean
//   up rows it writes — vendor verification rejects the requests
//   before they touch fact tables (placeholder secrets), so no
//   teardown is required at this layer. Phase 3B (backfill flood)
//   owns synthetic-tenant cleanup.
// * Signature is computed against a per-vendor PLACEHOLDER secret
//   that does NOT match what staging Secret Manager holds. That
//   means the proxy's signature verifier WILL reject (401/403) —
//   which is exactly the test surface for assertion #3 above.
// * Per-vendor signature header conventions are sourced directly
//   from `lib/integrations/<category>/<vendor>_webhook_signature_verifier.dart`
//   constants (header names captured 2026-05-08).
//
// Output
// ------
//   * `test/pressure/p3a_webhook_flood_raw.jsonl` — per-request
//     JSON line (vendor, operator_id, route, status, latency_ms,
//     idempotency_key, retry_attempt, response_excerpt). Gitignored.
//   * `test/pressure/p3a_webhook_flood_findings.jsonl` —
//     aggregated per-finding entries (one per detected category +
//     vendor). Gitignored.
//   * `test/pressure/p3a_webhook_flood_summary.md` — markdown
//     summary table (totals, latency p50/p95/p99, status breakdown,
//     per-finding rows). Gitignored.
//
// Hard rules
// ----------
// * Never include real vendor secrets — placeholders only.
// * Never write to production — the preview proxy URL is the only
//   target; `--proxy-url` flag MUST start with the preview URL.
// * Never auto-rerun on failure — if a 5xx storm starts, STOP and
//   record the finding.
// * Keep smoke under 5 min wall-clock. Full-scale documented in PR.
//
// Usage
// -----
//   dart run tool/pressure/p3a_webhook_flood.dart \
//     --ops=10 --duration=5min --rate=2 --vendors=all
//
//   dart run tool/pressure/p3a_webhook_flood.dart \
//     --ops=100 --duration=30min --rate=10 --retry-each=3   # full-scale

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

// ─── Constants ────────────────────────────────────────────────────

const String kDefaultPreviewProxyUrl =
    'https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app';

/// Hard guard: the harness REFUSES to run unless the proxy URL
/// matches a known preview / staging substring. This is a belt-and-
/// suspenders defense against accidental Production1 hits.
const List<String> kAllowedProxyHostSubstrings = <String>[
  'forge-flow-preview-',
  'forge-flow-staging-',
];

/// Default p95 budget (milliseconds). Documented starting budget per
/// the prompt; tighten as the proxy gets faster.
const int kDefaultP95BudgetMs = 2000;

/// Default smoke knobs.
const int kDefaultOps = 10;
const String kDefaultDuration = '5min';
const int kDefaultRate = 2;
const int kDefaultRetryEach = 1;

/// `User-Agent` so staging log filters can isolate pressure traffic.
const String kHarnessUserAgent =
    'forge-flow-pressure-preview-v1/p3a-webhook-flood';

// ─── Per-vendor signature header registry ────────────────────────
//
// Mirrors the `kXxxSignatureHeader` / `kXxxTimestampHeader` constants
// in `lib/integrations/<category>/<vendor>_webhook_signature_verifier.dart`.
// Captured 2026-05-08.
//
// `signatureScheme` controls how the placeholder digest is encoded:
//   * `b64`  — base64-encoded HMAC-SHA256 (Toast, Square, Clover, etc.)
//   * `hex`  — hex-encoded HMAC-SHA256 (7shifts, ADP, Intuit-style)
//   * `none` — vendor has no documented signature header (Oracle).
//
// The harness picks a scheme that's reasonable for the vendor; the
// proxy will reject either way because the placeholder secret doesn't
// match staging Secret Manager. The point is to NOT crash the verifier
// (assertion #3).

class VendorWebhookProfile {
  const VendorWebhookProfile({
    required this.vendorId,
    required this.signatureHeader,
    this.timestampHeader,
    this.signatureScheme = 'b64',
    this.extraHeaders = const <String, String>{},
  });

  final String vendorId;
  final String? signatureHeader;
  final String? timestampHeader;
  final String signatureScheme;
  final Map<String, String> extraHeaders;
}

const List<VendorWebhookProfile> kVendorProfiles = <VendorWebhookProfile>[
  // POS
  VendorWebhookProfile(
    vendorId: 'square',
    signatureHeader: 'x-square-hmacsha256-signature',
    timestampHeader: 'square-initial-delivery-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'toast',
    signatureHeader: 'toast-signature',
    timestampHeader: 'toast-webhook-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'clover',
    signatureHeader: 'x-clover-auth-signature',
    timestampHeader: 'x-clover-auth-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'lightspeed_lsk',
    signatureHeader: 'x-lightspeed-signature',
    timestampHeader: 'x-lightspeed-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'oracle_micros_simphony',
    signatureHeader: null,
    timestampHeader: null,
    signatureScheme: 'none',
  ),
  VendorWebhookProfile(
    vendorId: 'aloha_ncr_voyix',
    signatureHeader: 'ncr-webhook-signature',
    timestampHeader: 'ncr-webhook-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'revel',
    signatureHeader: 'x-revel-signature',
    timestampHeader: null,
    signatureScheme: 'hex',
    extraHeaders: <String, String>{
      'x-revel-instance': 'pressure-preview',
      'x-revel-event-type': 'order.closed',
    },
  ),
  // Labor
  VendorWebhookProfile(
    vendorId: 'adp',
    signatureHeader: 'adp-signature',
    timestampHeader: 'adp-signature-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'agendrix',
    signatureHeader: 'x-agendrix-signature',
    timestampHeader: 'x-agendrix-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'humanity',
    signatureHeader: 'x-humanity-signature',
    timestampHeader: 'x-humanity-timestamp',
    signatureScheme: 'hex',
  ),
  VendorWebhookProfile(
    vendorId: 'push_operations',
    signatureHeader: 'x-push-signature',
    timestampHeader: 'x-push-timestamp',
    signatureScheme: 'hex',
  ),
  VendorWebhookProfile(
    vendorId: 'quickbooks_time',
    signatureHeader: 'intuit-signature',
    timestampHeader: 'intuit-t-hash',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'seven_shifts',
    signatureHeader: 'x-7shifts-hmac-sha256',
    timestampHeader: 'x-7shifts-timestamp',
    signatureScheme: 'hex',
  ),
  // Reservation
  VendorWebhookProfile(
    vendorId: 'libro',
    signatureHeader: 'x-libro-signature',
    timestampHeader: null,
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'opentable',
    signatureHeader: 'x-opentable-signature',
    timestampHeader: 'x-opentable-timestamp',
    signatureScheme: 'b64',
  ),
  VendorWebhookProfile(
    vendorId: 'sevenrooms',
    signatureHeader: 'x-sevenrooms-signature',
    timestampHeader: 'x-sevenrooms-timestamp',
    signatureScheme: 'hex',
  ),
  VendorWebhookProfile(
    vendorId: 'tock',
    signatureHeader: 'x-tock-signature',
    timestampHeader: 'x-tock-webhook-timestamp',
    signatureScheme: 'b64',
  ),
];

/// Placeholder per-vendor secret. NEVER a real secret. The harness
/// uses this to compute HMAC digests so the verifier doesn't trip on
/// missing header (which would be a different code path than
/// signature-mismatch).
const String kPlaceholderSecret =
    'PLACEHOLDER-PRESSURE-PREVIEW-V1-NOT-A-REAL-SECRET';

// ─── CLI parsing ─────────────────────────────────────────────────

class HarnessOptions {
  HarnessOptions({
    required this.proxyUrl,
    required this.ops,
    required this.durationSeconds,
    required this.rate,
    required this.vendors,
    required this.retryEach,
    required this.outputDir,
    required this.p95BudgetMs,
    required this.warmup,
  });

  final String proxyUrl;
  final int ops;
  final int durationSeconds;
  final int rate;
  final List<String> vendors;
  final int retryEach;
  final String outputDir;
  final int p95BudgetMs;
  final bool warmup;
}

/// Parse a duration string of the form `5min`, `30min`, `90s`,
/// `1h`. Returns seconds. Throws on malformed input.
int _parseDurationSeconds(String raw) {
  final m = RegExp(r'^(\d+)(s|sec|min|m|h)$').firstMatch(raw.trim());
  if (m == null) {
    throw FormatException('cannot parse duration: "$raw"');
  }
  final n = int.parse(m.group(1)!);
  final unit = m.group(2)!;
  switch (unit) {
    case 's':
    case 'sec':
      return n;
    case 'min':
    case 'm':
      return n * 60;
    case 'h':
      return n * 3600;
  }
  throw FormatException('unknown duration unit: "$unit"');
}

HarnessOptions _parseArgs(List<String> args) {
  String proxyUrl =
      _envOr('FF_PRESSURE_PROXY_URL', kDefaultPreviewProxyUrl).trim();
  int ops = kDefaultOps;
  int durationSeconds = _parseDurationSeconds(kDefaultDuration);
  int rate = kDefaultRate;
  List<String> vendors = <String>['all'];
  int retryEach = kDefaultRetryEach;
  String outputDir = 'test/pressure';
  int p95Budget = kDefaultP95BudgetMs;
  bool warmup = true;

  for (final raw in args) {
    if (!raw.startsWith('--')) continue;
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(2, eq);
    final value = raw.substring(eq + 1);
    switch (key) {
      case 'proxy-url':
        proxyUrl = value.trim();
        break;
      case 'ops':
        ops = int.parse(value);
        break;
      case 'duration':
        durationSeconds = _parseDurationSeconds(value);
        break;
      case 'rate':
        rate = int.parse(value);
        break;
      case 'vendors':
        vendors = value
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (vendors.isEmpty) vendors = <String>['all'];
        break;
      case 'retry-each':
        retryEach = int.parse(value);
        break;
      case 'output-dir':
        outputDir = value;
        break;
      case 'p95-budget-ms':
        p95Budget = int.parse(value);
        break;
      case 'warmup':
        warmup = value.toLowerCase() != 'false';
        break;
      default:
        stderr.writeln('warning: unknown flag --$key');
    }
  }

  if (vendors.contains('all')) {
    vendors = kVendorProfiles.map((p) => p.vendorId).toList();
  }

  return HarnessOptions(
    proxyUrl: proxyUrl,
    ops: ops,
    durationSeconds: durationSeconds,
    rate: rate,
    vendors: vendors,
    retryEach: retryEach,
    outputDir: outputDir,
    p95BudgetMs: p95Budget,
    warmup: warmup,
  );
}

String _envOr(String key, String fallback) =>
    Platform.environment[key]?.trim().isNotEmpty == true
        ? Platform.environment[key]!
        : fallback;

// ─── Fixture loading ─────────────────────────────────────────────

class VendorFixturePack {
  VendorFixturePack({
    required this.vendorId,
    required this.profile,
    required this.happyPath,
    required this.forgedSignature,
  });

  final String vendorId;
  final VendorWebhookProfile profile;
  final List<LoadedFixture> happyPath;
  final LoadedFixture? forgedSignature;
}

class LoadedFixture {
  LoadedFixture({required this.relPath, required this.body});
  final String relPath;
  final Uint8List body;
}

/// Walk every fixture directory and split into (happy_path_*, scenario_a_*)
/// buckets. Other scenarios are intentionally ignored at this layer —
/// 3A is about webhook flood, not adapter divergence (Phase 2A).
Future<Map<String, VendorFixturePack>> _loadFixtures({
  required List<String> vendorIds,
}) async {
  final root = _findFixtureRoot();
  final out = <String, VendorFixturePack>{};
  for (final vendorId in vendorIds) {
    final profile = kVendorProfiles.firstWhere(
      (p) => p.vendorId == vendorId,
      orElse: () => throw StateError('no profile for vendor $vendorId'),
    );
    final dir = Directory('$root/$vendorId');
    if (!dir.existsSync()) {
      stderr.writeln('warning: fixture dir missing for $vendorId — '
          'will skip vendor');
      continue;
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final happy = <LoadedFixture>[];
    LoadedFixture? forged;
    for (final f in files) {
      final name = f.uri.pathSegments.last;
      final loaded = LoadedFixture(
        relPath: '$vendorId/$name',
        body: Uint8List.fromList(await f.readAsBytes()),
      );
      if (name.startsWith('happy_path_')) {
        happy.add(loaded);
      } else if (name == 'scenario_a_forged_signature.json') {
        forged = loaded;
      }
    }
    if (happy.isEmpty) {
      stderr.writeln('warning: no happy_path fixtures for $vendorId');
    }
    out[vendorId] = VendorFixturePack(
      vendorId: vendorId,
      profile: profile,
      happyPath: happy,
      forgedSignature: forged,
    );
  }
  return out;
}

String _findFixtureRoot() {
  final cwd = Directory.current.path.replaceAll('\\', '/');
  return '$cwd/test/fixtures/vendor_payloads';
}

// ─── Synthetic operator/location IDs ─────────────────────────────

/// Deterministic synthetic UUIDs for the run — derived from a salt
/// per ordinal. No real operator data is used. The framework's webhook
/// route accepts any well-formed UUID; the binding cross-check would
/// reject the request as `connection_not_found` after signature, but
/// the harness expects rejection at signature first because the
/// secret is a placeholder.
String _syntheticOperatorId(int ordinal, String runSalt) =>
    _deterministicUuid('operator', ordinal, runSalt);

String _syntheticLocationId(int ordinal, String runSalt) =>
    _deterministicUuid('location', ordinal, runSalt);

String _deterministicUuid(String role, int ordinal, String salt) {
  final raw = '$role-$ordinal-$salt';
  final digest = sha256.convert(utf8.encode(raw)).bytes;
  // Produce a UUIDv4-shaped string (variant + version bits set).
  final hex = digest
      .sublist(0, 16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  // Force version 4 + variant bits.
  final mutable = hex.codeUnits.toList();
  mutable[12] = '4'.codeUnitAt(0);
  // Variant bits: 8/9/a/b
  mutable[16] = '8'.codeUnitAt(0);
  final fixed = String.fromCharCodes(mutable);
  return '${fixed.substring(0, 8)}-'
      '${fixed.substring(8, 12)}-'
      '${fixed.substring(12, 16)}-'
      '${fixed.substring(16, 20)}-'
      '${fixed.substring(20, 32)}';
}

/// Per-run idempotency key. Distinct per (request, retry) when
/// retry_attempt = 0; identical across retries when retry_attempt > 0
/// so the proxy can replay the cached response (admin route shape;
/// for webhook routes the test is whether replays of the same body
/// produce the same response code class).
String _idempotencyKey({
  required String runSalt,
  required String vendorId,
  required String operatorId,
  required int eventOrdinal,
  required int retryAttempt,
}) {
  final raw = retryAttempt == 0
      ? 'p3a-$runSalt-$vendorId-$operatorId-$eventOrdinal-fresh'
      : 'p3a-$runSalt-$vendorId-$operatorId-$eventOrdinal-replay';
  return sha256
      .convert(utf8.encode(raw))
      .toString()
      .substring(0, 32);
}

// ─── Signing ─────────────────────────────────────────────────────

class _SignedHeaders {
  _SignedHeaders(this.headers);
  final Map<String, String> headers;
}

_SignedHeaders _signRequest({
  required VendorWebhookProfile profile,
  required Uint8List body,
  required DateTime now,
  required String userAgent,
  required String idempotencyKey,
}) {
  final headers = <String, String>{
    'content-type': 'application/json',
    'user-agent': userAgent,
    // The webhook route does NOT require the admin Idempotency-Key
    // header (the framework idempotency UNIQUE is `(vendor_id,
    // operator_id, vendor_event_id)`). We send one anyway as a
    // tracer so staging logs can correlate per-request flow.
    'idempotency-key': idempotencyKey,
    'x-pressure-test-lane': 'p3a-webhook-flood',
    ...profile.extraHeaders,
  };

  if (profile.signatureScheme == 'none' || profile.signatureHeader == null) {
    return _SignedHeaders(headers);
  }

  final ts = (now.millisecondsSinceEpoch ~/ 1000).toString();
  if (profile.timestampHeader != null) {
    headers[profile.timestampHeader!] = ts;
  }

  // Sign over `<timestamp>.<body>` for vendors that include timestamp
  // in the signed payload; sign over body only otherwise. The exact
  // construction differs per vendor — for a placeholder secret it
  // doesn't matter (the verifier rejects either way) so we pick the
  // most common shape (`<ts>.<body>`).
  final List<int> signedBytes = profile.timestampHeader != null
      ? <int>[
          ...utf8.encode('$ts.'),
          ...body,
        ]
      : body.toList();

  final hmac = Hmac(sha256, utf8.encode(kPlaceholderSecret));
  final digest = hmac.convert(signedBytes);

  final encoded = profile.signatureScheme == 'hex'
      ? digest.toString()
      : base64Encode(digest.bytes);
  headers[profile.signatureHeader!] = encoded;
  return _SignedHeaders(headers);
}

// ─── Per-request record ──────────────────────────────────────────

class _RequestRecord {
  _RequestRecord({
    required this.vendor,
    required this.operatorId,
    required this.locationId,
    required this.route,
    required this.statusCode,
    required this.latencyMs,
    required this.idempotencyKey,
    required this.retryAttempt,
    required this.scenario,
    required this.responseExcerpt,
    required this.timestamp,
    required this.errorKind,
  });

  final String vendor;
  final String operatorId;
  final String locationId;
  final String route;
  final int statusCode;
  final int latencyMs;
  final String idempotencyKey;
  final int retryAttempt;
  final String scenario;
  final String responseExcerpt;
  final DateTime timestamp;

  /// `network_error`, `timeout`, or empty for HTTP responses.
  final String errorKind;

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': timestamp.toIso8601String(),
        'vendor': vendor,
        'operator_id': operatorId,
        'location_id': locationId,
        'route': route,
        'status_code': statusCode,
        'latency_ms': latencyMs,
        'idempotency_key': idempotencyKey,
        'retry_attempt': retryAttempt,
        'scenario': scenario,
        'response_excerpt': responseExcerpt,
        'error_kind': errorKind,
      };
}

// ─── Finding sink ────────────────────────────────────────────────

class _Finding {
  _Finding({
    required this.category,
    required this.vendor,
    required this.detail,
    required this.evidence,
  });

  /// One of the categories listed in the prompt.
  final String category;
  final String vendor;
  final String detail;
  final Map<String, Object?> evidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'category': category,
        'vendor': vendor,
        'detail': detail,
        'evidence': evidence,
      };
}

// ─── HTTP client wrapper ─────────────────────────────────────────

/// Posts a single webhook event and returns the record. Catches
/// network errors so the harness keeps running.
Future<_RequestRecord> _postOne({
  required HttpClient client,
  required Uri url,
  required String vendor,
  required String operatorId,
  required String locationId,
  required Uint8List body,
  required Map<String, String> headers,
  required String idempotencyKey,
  required int retryAttempt,
  required String scenario,
  required Duration timeout,
}) async {
  final start = DateTime.now();
  try {
    final req = await client.postUrl(url).timeout(timeout);
    headers.forEach((k, v) => req.headers.set(k, v));
    req.add(body);
    final resp = await req.close().timeout(timeout);
    final responseBytes = <int>[];
    await for (final chunk in resp) {
      responseBytes.addAll(chunk);
      if (responseBytes.length > 4096) break;
    }
    final excerpt = utf8
        .decode(responseBytes, allowMalformed: true)
        .replaceAll('\n', ' ')
        .trim();
    final latency = DateTime.now().difference(start).inMilliseconds;
    return _RequestRecord(
      vendor: vendor,
      operatorId: operatorId,
      locationId: locationId,
      route: url.path,
      statusCode: resp.statusCode,
      latencyMs: latency,
      idempotencyKey: idempotencyKey,
      retryAttempt: retryAttempt,
      scenario: scenario,
      responseExcerpt: excerpt.length > 240 ? excerpt.substring(0, 240) : excerpt,
      timestamp: start.toUtc(),
      errorKind: '',
    );
  } on TimeoutException {
    final latency = DateTime.now().difference(start).inMilliseconds;
    return _RequestRecord(
      vendor: vendor,
      operatorId: operatorId,
      locationId: locationId,
      route: url.path,
      statusCode: -1,
      latencyMs: latency,
      idempotencyKey: idempotencyKey,
      retryAttempt: retryAttempt,
      scenario: scenario,
      responseExcerpt: 'TIMEOUT',
      timestamp: start.toUtc(),
      errorKind: 'timeout',
    );
  } catch (e) {
    final latency = DateTime.now().difference(start).inMilliseconds;
    return _RequestRecord(
      vendor: vendor,
      operatorId: operatorId,
      locationId: locationId,
      route: url.path,
      statusCode: -1,
      latencyMs: latency,
      idempotencyKey: idempotencyKey,
      retryAttempt: retryAttempt,
      scenario: scenario,
      responseExcerpt: 'ERR: ${e.toString().split('\n').first}',
      timestamp: start.toUtc(),
      errorKind: 'network_error',
    );
  }
}

// ─── Main run ────────────────────────────────────────────────────

Future<int> runHarness(List<String> args) async {
  final opts = _parseArgs(args);

  // Hard URL guard.
  final allowed =
      kAllowedProxyHostSubstrings.any((s) => opts.proxyUrl.contains(s));
  if (!allowed) {
    stderr.writeln(
        'FATAL: proxy URL "${opts.proxyUrl}" is not a preview/staging URL. '
        'Refusing to run pressure load against an unknown target.');
    return 2;
  }

  final base = Uri.parse(opts.proxyUrl);
  final fixtures = await _loadFixtures(vendorIds: opts.vendors);
  if (fixtures.isEmpty) {
    stderr.writeln('FATAL: no fixtures loaded for any requested vendor.');
    return 2;
  }

  final outputDir = Directory(opts.outputDir);
  outputDir.createSync(recursive: true);
  final rawSink = File('${outputDir.path}/p3a_webhook_flood_raw.jsonl')
      .openWrite(mode: FileMode.write);
  final findings = <_Finding>[];

  final runSalt = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[^\w]'), '_');

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  // ── Warmup ─────────────────────────────────────────────────────
  final warmupRecords = <_RequestRecord>[];
  if (opts.warmup) {
    stdout.writeln('=== warmup: one request per vendor (cold-start prime) ===');
    for (final vendorId in fixtures.keys) {
      final pack = fixtures[vendorId]!;
      if (pack.happyPath.isEmpty) continue;
      final operatorId = _syntheticOperatorId(0, runSalt);
      final locationId = _syntheticLocationId(0, runSalt);
      final fixture = pack.happyPath.first;
      final url = base.replace(
          path: '/v1/webhooks/$vendorId/$operatorId/$locationId');
      final idempotencyKey = _idempotencyKey(
        runSalt: runSalt,
        vendorId: vendorId,
        operatorId: operatorId,
        eventOrdinal: -1,
        retryAttempt: 0,
      );
      final signed = _signRequest(
        profile: pack.profile,
        body: fixture.body,
        now: DateTime.now().toUtc(),
        userAgent: kHarnessUserAgent,
        idempotencyKey: idempotencyKey,
      );
      final rec = await _postOne(
        client: client,
        url: url,
        vendor: vendorId,
        operatorId: operatorId,
        locationId: locationId,
        body: fixture.body,
        headers: signed.headers,
        idempotencyKey: idempotencyKey,
        retryAttempt: 0,
        scenario: 'warmup_${fixture.relPath}',
        timeout: const Duration(seconds: 30),
      );
      warmupRecords.add(rec);
      rawSink.writeln(jsonEncode(rec.toJson()));
      stdout.writeln(
          '  $vendorId  ${rec.statusCode}  ${rec.latencyMs}ms  ${rec.errorKind}');
    }
    stdout.writeln('=== warmup complete ===\n');
  }

  // ── Plan: per (operator, vendor) emit `rate`/min for `duration`. ─
  // Build the schedule as a flat list of (eventOrdinal, operator,
  // vendor, fixture) jobs spread across the run window.
  final totalMinutes = opts.durationSeconds / 60.0;
  final eventsPerOpVendor = (totalMinutes * opts.rate).round();
  if (eventsPerOpVendor <= 0) {
    stderr.writeln('FATAL: rate × duration produced 0 events. Increase '
        '--rate or --duration.');
    rawSink.flush();
    rawSink.close();
    client.close(force: true);
    return 2;
  }

  // Forged-signature probes — once per (operator, vendor) at random
  // intervals during the run.
  final forgedProbeFrequency = math.max(1, eventsPerOpVendor ~/ 5);

  final totalRequests = fixtures.length * opts.ops *
      eventsPerOpVendor * (1 + (opts.retryEach > 1 ? 1 : 0));
  stdout.writeln('=== smoke plan ===');
  stdout.writeln('  proxy: ${opts.proxyUrl}');
  stdout.writeln('  vendors: ${fixtures.length}');
  stdout.writeln('  ops: ${opts.ops}');
  stdout.writeln('  duration: ${opts.durationSeconds}s '
      '(~${totalMinutes.toStringAsFixed(1)} min)');
  stdout.writeln('  rate: ${opts.rate}/op/vendor/min');
  stdout.writeln('  events per (op×vendor): $eventsPerOpVendor');
  stdout.writeln('  retry-each: ${opts.retryEach}');
  stdout.writeln('  total fresh requests: '
      '${fixtures.length * opts.ops * eventsPerOpVendor}');
  stdout.writeln('  forged-signature probes: '
      '${(eventsPerOpVendor / forgedProbeFrequency).ceil()} per op×vendor');
  stdout.writeln('  total (fresh + replays): ~$totalRequests');
  stdout.writeln('===\n');

  // Pacing: spread events across `duration` seconds. Each event
  // generates 1 + (retryEach - 1) additional replay POSTs.
  final intervalMs = (opts.durationSeconds * 1000) ~/ eventsPerOpVendor;

  final allRecords = <_RequestRecord>[];
  final runStart = DateTime.now();
  final hardCap = Duration(seconds: opts.durationSeconds + 60);

  // Counter-based concurrency limit. We track inflight count and use
  // a Completer queue to release slots as jobs finish. Simpler and
  // more correct than a `Future`-list-based semaphore that has no
  // way to ask "is this one done yet?".
  final maxInflight = math.min(64, opts.ops * fixtures.length);
  int inflightCount = 0;
  final waiters = <Completer<void>>[];
  bool stormAbort = false;
  // Cumulative 5xx counter for early-abort detection. We sample the
  // ratio over the most-recent N requests (not strictly the last N
  // because async ordering jitters) — for the load-lane's "abort on
  // 5xx storm" hard rule, the ratio is what matters.
  int fivexxCumulative = 0;

  void releaseSlot() {
    inflightCount--;
    if (waiters.isNotEmpty) {
      final w = waiters.removeAt(0);
      if (!w.isCompleted) w.complete();
    }
  }

  Future<void> acquireSlot() async {
    if (inflightCount < maxInflight) {
      inflightCount++;
      return;
    }
    final c = Completer<void>();
    waiters.add(c);
    await c.future;
    inflightCount++;
  }

  Future<void> emitOne({
    required int operatorOrdinal,
    required String vendorId,
    required VendorFixturePack pack,
    required int eventOrdinal,
    required bool forgedProbe,
  }) async {
    final operatorId = _syntheticOperatorId(operatorOrdinal, runSalt);
    final locationId = _syntheticLocationId(operatorOrdinal, runSalt);
    final url = base.replace(
        path: '/v1/webhooks/$vendorId/$operatorId/$locationId');

    // Pick fixture: forged probe uses scenario_a; otherwise rotate
    // through happy_path fixtures.
    final LoadedFixture fixture = forgedProbe && pack.forgedSignature != null
        ? pack.forgedSignature!
        : (pack.happyPath.isEmpty
            ? (pack.forgedSignature ??
                LoadedFixture(
                    relPath: '$vendorId/<empty>',
                    body: Uint8List.fromList(utf8.encode('{}'))))
            : pack.happyPath[eventOrdinal % pack.happyPath.length]);

    for (var retry = 0; retry < opts.retryEach; retry++) {
      final idempotencyKey = _idempotencyKey(
        runSalt: runSalt,
        vendorId: vendorId,
        operatorId: operatorId,
        eventOrdinal: eventOrdinal,
        retryAttempt: retry,
      );
      final signed = _signRequest(
        profile: pack.profile,
        body: fixture.body,
        now: DateTime.now().toUtc(),
        userAgent: kHarnessUserAgent,
        idempotencyKey: idempotencyKey,
      );
      final rec = await _postOne(
        client: client,
        url: url,
        vendor: vendorId,
        operatorId: operatorId,
        locationId: locationId,
        body: fixture.body,
        headers: signed.headers,
        idempotencyKey: idempotencyKey,
        retryAttempt: retry,
        scenario: forgedProbe
            ? 'scenario_a_forged_signature'
            : (fixture.relPath.split('/').last.replaceAll('.json', '')),
        timeout: const Duration(seconds: 15),
      );
      allRecords.add(rec);
      rawSink.writeln(jsonEncode(rec.toJson()));
      if (rec.statusCode >= 500) fivexxCumulative++;
    }
  }

  // Track all spawned futures so we can drain them at the end.
  final spawned = <Future<void>>[];

  // Drive the schedule.
  outerLoop:
  for (var eventOrd = 0; eventOrd < eventsPerOpVendor; eventOrd++) {
    if (stormAbort) break;
    if (DateTime.now().difference(runStart) > hardCap) {
      stderr.writeln('hard cap reached — stopping schedule');
      break;
    }
    for (var op = 0; op < opts.ops; op++) {
      if (stormAbort) break outerLoop;
      for (final vendorId in fixtures.keys) {
        if (stormAbort) break outerLoop;
        final pack = fixtures[vendorId]!;
        // Forged probe trigger — every Nth event ordinal for this
        // vendor, do scenario_a instead of happy path.
        final isForged = (eventOrd % forgedProbeFrequency == 0) &&
            pack.forgedSignature != null;

        await acquireSlot();
        final job = () async {
          try {
            await emitOne(
              operatorOrdinal: op,
              vendorId: vendorId,
              pack: pack,
              eventOrdinal: eventOrd,
              forgedProbe: isForged,
            );
          } finally {
            releaseSlot();
          }
        }();
        spawned.add(job);

        // 5xx storm early-abort. After at least 50 requests have
        // landed, if >75% are 5xx, stop. The ratio threshold is
        // intentionally aggressive — anything above 50% under
        // sustained load means the proxy is unhealthy and continuing
        // wastes staging quota / pollutes metrics.
        if (allRecords.length >= 50) {
          final ratio = fivexxCumulative / allRecords.length;
          if (ratio > 0.75) {
            stderr.writeln('STOP: $fivexxCumulative/${allRecords.length} '
                'requests 5xx (ratio ${(ratio * 100).toStringAsFixed(0)}%). '
                'Aborting per hard rule.');
            findings.add(_Finding(
              category: '5xx_under_load',
              vendor: '<aggregate>',
              detail: 'aborted run after sustained 5xx storm',
              evidence: <String, Object?>{
                'fivexx_count': fivexxCumulative,
                'total_so_far': allRecords.length,
                'ratio_pct': (ratio * 100).toStringAsFixed(1),
              },
            ));
            stormAbort = true;
            break outerLoop;
          }
        }
      }
    }
    // Sleep between event ordinals to honor the rate. The interval
    // is computed across the full duration.
    if (eventOrd < eventsPerOpVendor - 1 && !stormAbort) {
      await Future<void>.delayed(Duration(milliseconds: intervalMs));
    }
  }

  // Drain spawned. eagerError=false so a single network glitch can't
  // mask the rest of the run.
  await Future.wait(spawned, eagerError: false);

  // ── Finding aggregation ───────────────────────────────────────
  _aggregateFindings(allRecords, warmupRecords, opts, findings);

  await rawSink.flush();
  await rawSink.close();

  // Write findings + summary.
  final findingsFile = File('${outputDir.path}/p3a_webhook_flood_findings.jsonl');
  findingsFile.writeAsStringSync(
    findings.map((f) => jsonEncode(f.toJson())).join('\n') +
        (findings.isEmpty ? '' : '\n'),
  );

  final summary = _renderSummary(opts, allRecords, warmupRecords, findings);
  final summaryFile = File('${outputDir.path}/p3a_webhook_flood_summary.md');
  summaryFile.writeAsStringSync(summary);

  stdout.writeln('\n$summary\n');
  stdout.writeln('Findings JSONL: ${findingsFile.path}');
  stdout.writeln('Summary MD: ${summaryFile.path}');
  stdout.writeln('Raw JSONL: ${outputDir.path}/p3a_webhook_flood_raw.jsonl');

  client.close(force: true);
  return 0;
}

// ─── Aggregation ─────────────────────────────────────────────────

void _aggregateFindings(
  List<_RequestRecord> records,
  List<_RequestRecord> warmup,
  HarnessOptions opts,
  List<_Finding> findings,
) {
  if (records.isEmpty) return;

  // 5xx_under_load — any non-warmup 5xx.
  final fivexxByVendor = <String, int>{};
  for (final r in records) {
    if (r.statusCode >= 500) {
      fivexxByVendor.update(r.vendor, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  fivexxByVendor.forEach((vendor, count) {
    findings.add(_Finding(
      category: '5xx_under_load',
      vendor: vendor,
      detail: 'proxy returned 5xx during smoke',
      evidence: <String, Object?>{'count': count},
    ));
  });

  // signature_verifier_crash — scenario_a fixtures got 5xx (instead
  // of expected 401/403).
  final verifierCrashByVendor = <String, int>{};
  for (final r in records) {
    if (r.scenario == 'scenario_a_forged_signature' && r.statusCode >= 500) {
      verifierCrashByVendor.update(r.vendor, (n) => n + 1,
          ifAbsent: () => 1);
    }
  }
  verifierCrashByVendor.forEach((vendor, count) {
    findings.add(_Finding(
      category: 'signature_verifier_crash',
      vendor: vendor,
      detail: 'forged-signature fixture returned 5xx instead of 401/403',
      evidence: <String, Object?>{'count': count},
    ));
  });

  // latency_over_budget — p95 > budget (whole-run).
  final latencies = records
      .where((r) => r.errorKind.isEmpty)
      .map((r) => r.latencyMs)
      .toList()
    ..sort();
  if (latencies.isNotEmpty) {
    final p95 = latencies[(latencies.length * 95) ~/ 100];
    if (p95 > opts.p95BudgetMs) {
      findings.add(_Finding(
        category: 'latency_over_budget',
        vendor: '<aggregate>',
        detail: 'whole-run p95 exceeded budget',
        evidence: <String, Object?>{
          'p95_ms': p95,
          'budget_ms': opts.p95BudgetMs,
        },
      ));
    }
  }

  // idempotency_violation — when retry_each > 1, fresh and replay
  // requests for the same (vendor, op, eventOrdinal) MUST produce the
  // same status code class. Different status classes → finding.
  final retryGroups = <String, List<_RequestRecord>>{};
  for (final r in records) {
    if (opts.retryEach <= 1) break;
    final key = '${r.vendor}|${r.operatorId}|${r.scenario}';
    retryGroups.putIfAbsent(key, () => <_RequestRecord>[]).add(r);
  }
  retryGroups.forEach((key, rs) {
    if (rs.length < 2) return;
    final classes = rs.map((r) => r.statusCode ~/ 100).toSet();
    if (classes.length > 1) {
      findings.add(_Finding(
        category: 'idempotency_violation',
        vendor: rs.first.vendor,
        detail: 'replays produced mixed status classes',
        evidence: <String, Object?>{
          'group': key,
          'classes': classes.toList()..sort(),
          'sample_responses':
              rs.take(3).map((r) => r.responseExcerpt).toList(),
        },
      ));
    }
  });

  // connection_pool_exhaustion — look for proxy responses mentioning
  // pool / connection-acquire timeouts. Real preview proxy emits
  // `DependencyTimeoutException(surface: postgres, operation:
  // acquire_connection, elapsed_ms: ...)` when the pgpool waits past
  // the borrow timeout, so we match that shape too.
  final poolEvidence = <String>{};
  int poolHitCount = 0;
  for (final r in records) {
    final excerpt = r.responseExcerpt.toLowerCase();
    if (excerpt.contains('connection_acquire_timeout') ||
        excerpt.contains('too many connections') ||
        excerpt.contains('pool exhausted') ||
        excerpt.contains('acquire_connection') ||
        excerpt.contains('dependencytimeoutexception')) {
      poolEvidence.add(r.responseExcerpt);
      poolHitCount++;
    }
  }
  if (poolEvidence.isNotEmpty) {
    findings.add(_Finding(
      category: 'connection_pool_exhaustion',
      vendor: '<aggregate>',
      detail: 'proxy responses mention connection pool exhaustion',
      evidence: <String, Object?>{
        'count': poolHitCount,
        'sample_excerpts': poolEvidence.take(5).toList(),
      },
    ));
  }
  final networkErrorCount =
      records.where((r) => r.errorKind == 'network_error').length;
  if (networkErrorCount > records.length ~/ 10 && records.isNotEmpty) {
    findings.add(_Finding(
      category: 'connection_pool_exhaustion',
      vendor: '<aggregate>',
      detail: 'high network_error rate (>10% of all requests) — '
          'possible socket exhaustion or proxy refusal',
      evidence: <String, Object?>{
        'network_errors': networkErrorCount,
        'total_requests': records.length,
      },
    ));
  }

  // vendor_route_404 — proxy responded 404 for a vendor route.
  final route404ByVendor = <String, int>{};
  for (final r in records) {
    if (r.statusCode == 404) {
      route404ByVendor.update(r.vendor, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  route404ByVendor.forEach((vendor, count) {
    findings.add(_Finding(
      category: 'vendor_route_404',
      vendor: vendor,
      detail: 'proxy returned 404 for /v1/webhooks/$vendor/... — '
          'route may not be registered or path shape changed',
      evidence: <String, Object?>{'count': count},
    ));
  });

  // cors_block — preflight (OPTIONS) failure surfaces don't directly
  // arise from POST traffic, but if response excerpts mention CORS we
  // surface it.
  for (final r in records) {
    if (r.responseExcerpt.toLowerCase().contains('cors') ||
        r.responseExcerpt.toLowerCase().contains('preflight')) {
      findings.add(_Finding(
        category: 'cors_block',
        vendor: r.vendor,
        detail: 'proxy mentioned CORS in response body',
        evidence: <String, Object?>{
          'response_excerpt': r.responseExcerpt,
          'status_code': r.statusCode,
        },
      ));
      break;
    }
  }

  // rate_limit_hit — 429s are expected at high volume; record but
  // don't fail.
  final rateLimitByVendor = <String, int>{};
  for (final r in records) {
    if (r.statusCode == 429) {
      rateLimitByVendor.update(r.vendor, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  rateLimitByVendor.forEach((vendor, count) {
    findings.add(_Finding(
      category: 'rate_limit_hit',
      vendor: vendor,
      detail: 'proxy returned 429 (expected at high volume; informational)',
      evidence: <String, Object?>{'count': count},
    ));
  });
}

// ─── Summary rendering ───────────────────────────────────────────

String _renderSummary(
  HarnessOptions opts,
  List<_RequestRecord> records,
  List<_RequestRecord> warmup,
  List<_Finding> findings,
) {
  final out = StringBuffer();
  out.writeln('# Phase 3A Webhook Flood — Smoke Summary');
  out.writeln();
  out.writeln('Generated: ${DateTime.now().toUtc().toIso8601String()}');
  out.writeln('Proxy: `${opts.proxyUrl}`');
  out.writeln('Knobs: '
      'ops=${opts.ops} '
      'duration=${opts.durationSeconds}s '
      'rate=${opts.rate}/op/vendor/min '
      'retry-each=${opts.retryEach} '
      'vendors=${opts.vendors.length}');
  out.writeln();

  // ── Totals ──
  out.writeln('## Totals');
  out.writeln();
  out.writeln('| Metric | Value |');
  out.writeln('|---|---|');
  out.writeln('| Total requests (excl. warmup) | ${records.length} |');
  out.writeln('| Warmup requests | ${warmup.length} |');
  final ok = records.where((r) => r.statusCode >= 200 && r.statusCode < 300).length;
  final clientErr = records
      .where((r) => r.statusCode >= 400 && r.statusCode < 500)
      .length;
  final serverErr = records.where((r) => r.statusCode >= 500).length;
  final networkErr = records.where((r) => r.errorKind == 'network_error').length;
  final timeout = records.where((r) => r.errorKind == 'timeout').length;
  final rateLimited = records.where((r) => r.statusCode == 429).length;
  out.writeln('| 2xx | $ok |');
  out.writeln('| 4xx (excl. 429) | ${clientErr - rateLimited} |');
  out.writeln('| 429 (rate-limited) | $rateLimited |');
  out.writeln('| 5xx | $serverErr |');
  out.writeln('| network errors | $networkErr |');
  out.writeln('| timeouts | $timeout |');
  if (records.isNotEmpty) {
    final successRate =
        ((ok + clientErr) / records.length * 100).toStringAsFixed(1);
    out.writeln('| HTTP-completion rate (2xx+4xx) | $successRate% |');
  }
  out.writeln();

  // ── Latency ──
  final latencies = records
      .where((r) => r.errorKind.isEmpty)
      .map((r) => r.latencyMs)
      .toList()
    ..sort();
  out.writeln('## Latency (ms, excludes errors)');
  out.writeln();
  if (latencies.isEmpty) {
    out.writeln('No completed requests to compute latency.');
  } else {
    final p50 = latencies[latencies.length ~/ 2];
    final p95 = latencies[(latencies.length * 95) ~/ 100];
    final p99 = latencies[(latencies.length * 99) ~/ 100];
    final maxL = latencies.last;
    out.writeln('| p50 | p95 | p99 | max | budget |');
    out.writeln('|---|---|---|---|---|');
    out.writeln('| $p50 | $p95 | $p99 | $maxL | ${opts.p95BudgetMs} |');
  }
  out.writeln();

  // ── Warmup latencies ──
  if (warmup.isNotEmpty) {
    out.writeln('## Warmup latencies (cold-start)');
    out.writeln();
    out.writeln('| Vendor | Status | Latency (ms) | Error |');
    out.writeln('|---|---|---|---|');
    for (final r in warmup) {
      out.writeln(
          '| ${r.vendor} | ${r.statusCode} | ${r.latencyMs} | ${r.errorKind} |');
    }
    out.writeln();
  }

  // ── Per-vendor status breakdown ──
  out.writeln('## Per-vendor status breakdown');
  out.writeln();
  out.writeln('| Vendor | Total | 2xx | 4xx | 5xx | net_err | timeouts |');
  out.writeln('|---|---|---|---|---|---|---|');
  final byVendor = <String, List<_RequestRecord>>{};
  for (final r in records) {
    byVendor.putIfAbsent(r.vendor, () => <_RequestRecord>[]).add(r);
  }
  final vendors = byVendor.keys.toList()..sort();
  for (final v in vendors) {
    final rs = byVendor[v]!;
    final twoxx =
        rs.where((r) => r.statusCode >= 200 && r.statusCode < 300).length;
    final fourxx =
        rs.where((r) => r.statusCode >= 400 && r.statusCode < 500).length;
    final fivexx = rs.where((r) => r.statusCode >= 500).length;
    final ne = rs.where((r) => r.errorKind == 'network_error').length;
    final to = rs.where((r) => r.errorKind == 'timeout').length;
    out.writeln(
        '| $v | ${rs.length} | $twoxx | $fourxx | $fivexx | $ne | $to |');
  }
  out.writeln();

  // ── Findings ──
  out.writeln('## Findings');
  out.writeln();
  if (findings.isEmpty) {
    out.writeln('No findings recorded.');
  } else {
    out.writeln('| Category | Vendor | Detail |');
    out.writeln('|---|---|---|');
    for (final f in findings) {
      final detail = f.detail.replaceAll('|', '\\|');
      out.writeln('| ${f.category} | ${f.vendor} | $detail |');
    }
  }
  out.writeln();
  out.writeln('Total findings: ${findings.length}');
  out.writeln();

  // ── Top response excerpts (first 5 distinct, non-2xx) ──
  out.writeln('## Top non-2xx response excerpts');
  out.writeln();
  final seenExcerpts = <String>{};
  final samples = <_RequestRecord>[];
  for (final r in records) {
    if (r.statusCode >= 200 && r.statusCode < 300) continue;
    if (seenExcerpts.contains(r.responseExcerpt)) continue;
    seenExcerpts.add(r.responseExcerpt);
    samples.add(r);
    if (samples.length >= 8) break;
  }
  if (samples.isEmpty) {
    out.writeln('No non-2xx responses recorded.');
  } else {
    out.writeln('| Vendor | Status | Excerpt |');
    out.writeln('|---|---|---|');
    for (final r in samples) {
      final ex = r.responseExcerpt
          .replaceAll('|', '\\|')
          .replaceAll('\n', ' ');
      out.writeln('| ${r.vendor} | ${r.statusCode} | $ex |');
    }
  }
  out.writeln();
  return out.toString();
}

// ─── Entrypoint ──────────────────────────────────────────────────

Future<void> main(List<String> args) async {
  final exitCode = await runHarness(args);
  exit(exitCode);
}
