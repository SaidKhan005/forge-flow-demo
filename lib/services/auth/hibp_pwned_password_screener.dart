// Phase 9.5 - HIBP k-anonymity pwned-password screener.
//
// HIBP exposes the Pwned Passwords API as a k-anonymity range
// lookup: client SHA-1s the candidate password, sends the first 5
// hex characters of the digest, and gets back every breached SHA-1
// suffix that begins with that prefix. The client compares its own
// suffix against the response and decides locally whether the
// candidate is pwned. The full SHA-1 (and the password) never
// leaves the client.
//
// Endpoint: `https://api.pwnedpasswords.com/range/{prefix}`
// Docs: https://haveibeenpwned.com/API/v3#PwnedPasswords
//
// Slice 9.5 ships:
//   - The hashing + range-prefix logic (pure, fully tested).
//   - An abstract [HibpRangeFetcher] seam so the screener can be
//     unit-tested with a fake response.
//   - A production [HttpHibpRangeFetcher] that the proxy can wire
//     once the operator approves outbound HTTPS to api.pwnedpasswords.com.
//   - A [PwnedPasswordResult] enum that distinguishes
//     `notPwned` / `pwned` / `screenerUnavailable`, so the
//     password-change service can decide policy (we default to
//     "fail-open + audit" when the screener is unavailable, per
//     the plan's UX-friendly stance).
//
// The screener intentionally does NOT enforce a per-IP rate limit
// here. The plan's "100/min/IP" cap belongs in the proxy's
// outbound HTTP client (Cloud Armor on the inbound side); this
// file is the screener primitive.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../observability/dependency_timeout_exception.dart';
import '../observability/log.dart';

enum PwnedPasswordResult {
  /// Candidate is not in any HIBP-known breach.
  notPwned,

  /// Candidate appears in a HIBP-known breach. Caller refuses the
  /// password change with a NIST-aligned error message.
  pwned,

  /// HIBP could not be reached. Per the plan we fail-open here to
  /// avoid blocking legitimate password changes during HIBP
  /// outages — the proxy logs an `auth.hibp_unavailable` audit
  /// event so risk + ops can review.
  screenerUnavailable,
}

/// HTTP fetch seam for the HIBP range endpoint. Production binding
/// uses [HttpHibpRangeFetcher]; tests use deterministic fakes.
abstract class HibpRangeFetcher {
  /// Returns the raw text body for `range/{prefix}`. The body is a
  /// list of `SUFFIX:COUNT` lines (35 hex chars + colon + integer
  /// count), one per matching breach hash.
  Future<String> fetchRange(String hexPrefix);
}

/// Production HTTP impl. Honors a pessimistic timeout so the
/// password-change path stays responsive when HIBP is slow.
///
/// HARD-G observability default: 15 s. Time-outs surface in
/// [HibpPwnedPasswordScreener.screen] as
/// [PwnedPasswordResult.screenerUnavailable] (the existing fail-open
/// path). The contract pins this value.
class HttpHibpRangeFetcher implements HibpRangeFetcher {
  HttpHibpRangeFetcher({
    HttpClient? httpClient,
    Duration timeout = const Duration(seconds: 15),
    String userAgent = 'forge-and-flow-auth/1.0',
  }) : _httpClient = httpClient ?? HttpClient(),
       _timeout = timeout,
       _userAgent = userAgent;

  static final Uri _baseUri = Uri.parse('https://api.pwnedpasswords.com/range/');

  final HttpClient _httpClient;
  final Duration _timeout;
  final String _userAgent;

  @override
  Future<String> fetchRange(String hexPrefix) async {
    try {
      final request = await _httpClient
          .getUrl(_baseUri.resolve(hexPrefix))
          .timeout(_timeout);
      // Add-Padding header asks HIBP to pad responses with synthetic
      // entries so the wire-byte count does not leak the candidate's
      // breach status — a defense-in-depth measure HIBP documents.
      request.headers.set('Add-Padding', 'true');
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close().timeout(_timeout);
      if (response.statusCode != 200) {
        // Drain the socket so it stays reusable on the pool.
        await response.drain<void>();
        throw HttpException(
          'HIBP range fetch failed with status ${response.statusCode}',
        );
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(_timeout);
    } on TimeoutException {
      // HARD-G observability: emit the structured timeout log line
      // before surfacing the typed exception. The screener catches
      // anything thrown here and maps it to
      // `PwnedPasswordResult.screenerUnavailable`, preserving the
      // contract-pinned fail-open behavior; the log line is what
      // gives operators the timing signal.
      final timeoutException = DependencyTimeoutException(
        surface: 'hibp',
        operation: 'range_fetch',
        elapsedMs: _timeout.inMilliseconds,
      );
      log(
        LogSeverity.error,
        'request.dependency_timeout',
        fields: <String, Object?>{
          'surface': timeoutException.surface,
          'operation': timeoutException.operation,
          'elapsed_ms': timeoutException.elapsedMs,
        },
      );
      throw timeoutException;
    }
  }
}

class HibpPwnedPasswordScreener {
  HibpPwnedPasswordScreener({required HibpRangeFetcher fetcher})
    : _fetcher = fetcher;

  final HibpRangeFetcher _fetcher;

  /// Returns the screening verdict for [candidate]. Never throws —
  /// network/parse failures map to [PwnedPasswordResult.screenerUnavailable]
  /// so the caller can decide policy.
  Future<PwnedPasswordResult> screen(String candidate) async {
    final hash = sha1.convert(utf8.encode(candidate)).toString().toUpperCase();
    final prefix = hash.substring(0, 5);
    final suffix = hash.substring(5);
    final String body;
    try {
      body = await _fetcher.fetchRange(prefix);
    } catch (_) {
      return PwnedPasswordResult.screenerUnavailable;
    }
    return _matchesAny(body: body, suffix: suffix)
        ? PwnedPasswordResult.pwned
        : PwnedPasswordResult.notPwned;
  }

  static bool _matchesAny({required String body, required String suffix}) {
    final upperSuffix = suffix.toUpperCase();
    for (final line in const LineSplitter().convert(body)) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      final candidate = line.substring(0, colon).trim().toUpperCase();
      if (candidate == upperSuffix) return true;
    }
    return false;
  }
}

/// Hard-fail-closed default. For HIBP specifically "fail closed"
/// means refusing to give a verdict, not refusing the password —
/// the password-change service then decides whether to fail-open
/// (default) or fail-closed (high-security operator profile).
class ScaffoldFailingHibpRangeFetcher implements HibpRangeFetcher {
  const ScaffoldFailingHibpRangeFetcher();

  @override
  Future<String> fetchRange(String hexPrefix) async {
    throw StateError(
      '9.5 scaffold: real HibpRangeFetcher is not wired — bind '
      '`HttpHibpRangeFetcher` (with operator-approved outbound HTTPS '
      'allowlist) in the proxy bootstrap before serving real password '
      'changes.',
    );
  }
}
