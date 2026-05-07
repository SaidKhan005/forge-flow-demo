// Forge & Flow — AdvisorModelConfigService.
//
// 7.57.3a-review-fix. Persists dev-only overrides for the advisor
// answer model ids via SharedPreferences and exposes an injected online
// check.
//
// Hard rules:
//   * No API keys are persisted, read, or shipped. Hard Promise #7
//     ("F&F holds all provider keys server-side. No BYO-key.") forbids
//     a `--dart-define=ANTHROPIC_API_KEY=...` path on the client; the
//     online check probes the F&F proxy (no client-held credentials)
//     and returns [AnthropicModelCheckStatus.cannotCheck] when the
//     proxy isn't reachable.
//   * Embedding/rerank models are pinned in `AdvisorProviderConstants`
//     and are not editable here — only Claude answer model overrides
//     (quick / nuanced) round-trip through this service.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/services/advisor_model_routing.dart';

// ─── Online check result ─────────────────────────────────────────────────────

/// Outcome of an advisor model availability probe.
///
/// In the BYO-key era the default check called Anthropic's
/// `GET /v1/models` directly and reported `available` /
/// `unavailable` based on the returned catalog. After Hard Promise #7
/// (no client-held provider keys), the default check is a proxy
/// liveness probe and returns [cannotCheck] regardless — the proxy
/// does not currently expose Anthropic's catalog to clients. Tests
/// (which inject fakes) still exercise [available] / [unavailable]
/// to keep the result contract honest.
enum AnthropicModelCheckStatus {
  /// Probe succeeded and confirmed both effective ids are present in
  /// the returned model list. Reachable today only via injected fakes.
  available,

  /// Probe succeeded and confirmed at least one effective id is NOT
  /// in the returned model list. Reachable today only via injected
  /// fakes.
  unavailable,

  /// Could not verify availability — proxy unreachable, returned a
  /// non-2xx, or doesn't expose model listings. The dev should NOT
  /// interpret this as "model is dead".
  cannotCheck,
}

class AnthropicModelCheckResult {
  final AnthropicModelCheckStatus status;

  /// Human-readable status line for the dev to read in Settings.
  final String message;

  /// Model ids returned by Anthropic, if the call succeeded. Empty for
  /// `cannotCheck`. Stable order from the API response.
  final List<String> seenModelIds;

  /// True when [status] is `available` AND a newer same-family model id
  /// was seen in [seenModelIds] (e.g. configured `claude-sonnet-4-6` with
  /// `claude-sonnet-4-7` listed). Always false for `unavailable` /
  /// `cannotCheck`.
  final bool updateAvailable;

  /// Newer Haiku-family candidate seen in the response, if any.
  /// Null when no newer same-family id was found, or when the call did
  /// not succeed.
  final String? latestQuickCandidate;

  /// Newer Sonnet-family candidate seen in the response, if any.
  /// Null when no newer same-family id was found, or when the call did
  /// not succeed.
  final String? latestNuancedCandidate;

  const AnthropicModelCheckResult({
    required this.status,
    required this.message,
    this.seenModelIds = const <String>[],
    this.updateAvailable = false,
    this.latestQuickCandidate,
    this.latestNuancedCandidate,
  });

  const AnthropicModelCheckResult.cannotCheck(String reason)
      : status = AnthropicModelCheckStatus.cannotCheck,
        message = reason,
        seenModelIds = const <String>[],
        updateAvailable = false,
        latestQuickCandidate = null,
        latestNuancedCandidate = null;
}

/// Find the family-greatest same-family id in [seenIds] that is
/// strictly greater than [configured] (i.e. an actual update
/// candidate).
///
/// Returns null when:
///   * no id in [seenIds] matches [inFamily], or
///   * the family-greatest id is `<=` [configured] under the
///     segment-aware ordering below.
///
/// Ordering: ids are split on `-`, then compared segment by segment.
/// When both segments parse as integers, the numeric value wins
/// (so `claude-sonnet-4-10` ranks above `claude-sonnet-4-6` instead
/// of below it under naive lex). Otherwise the segments fall back
/// to plain string comparison. This handles both id shapes
/// Anthropic uses today:
///   * versioned suffix: `claude-sonnet-4-6` vs `claude-sonnet-4-10`
///   * date-stamped: `claude-3-5-haiku-20241022` vs
///     `claude-3-5-haiku-20250307`
///
/// Family detection (e.g. `id.contains('haiku')`) is the caller's
/// responsibility so this helper stays format-agnostic.
String? findUpdateCandidate(
  List<String> seenIds,
  String configured,
  bool Function(String) inFamily,
) {
  final family = seenIds.where(inFamily).toList()
    ..sort(_compareModelIds);
  if (family.isEmpty) return null;
  final latest = family.last;
  if (_compareModelIds(latest, configured) <= 0) return null;
  return latest;
}

/// Segment-aware comparator for Anthropic-style model ids. Splits
/// each id on `-`, then for each pair of segments:
///   * if both parse as integers, compare numerically (so `10` > `6`)
///   * otherwise, compare as strings
/// Ties in matched segments break by length: shorter id is "less".
int _compareModelIds(String a, String b) {
  final aSegs = a.split('-');
  final bSegs = b.split('-');
  final maxLen = aSegs.length > bSegs.length ? aSegs.length : bSegs.length;
  for (var i = 0; i < maxLen; i++) {
    if (i >= aSegs.length) return -1;
    if (i >= bSegs.length) return 1;
    final aSeg = aSegs[i];
    final bSeg = bSegs[i];
    final aNum = int.tryParse(aSeg);
    final bNum = int.tryParse(bSeg);
    if (aNum != null && bNum != null) {
      if (aNum != bNum) return aNum.compareTo(bNum);
    } else {
      final cmp = aSeg.compareTo(bSeg);
      if (cmp != 0) return cmp;
    }
  }
  return 0;
}

/// Online-check function the service delegates to. Production wires
/// [defaultAnthropicOnlineCheck]; tests inject a fake.
typedef AnthropicOnlineCheckFn = Future<AnthropicModelCheckResult> Function({
  required String quickModelId,
  required String nuancedModelId,
});

// ─── Default production online check ────────────────────────────────────────

/// Compile-time proxy base URI. Mirrors the same dart-define that
/// `main_forgeflow.dart` already reads when wiring the live sync proxy
/// client. A URL is environment config (not a secret), so threading it
/// through `String.fromEnvironment` does not violate Hard Promise #7
/// the way an API key would. Empty when unset — the online check then
/// returns [AnthropicModelCheckStatus.cannotCheck] with a clear
/// message rather than a fabricated availability claim.
const String _kProxyBaseUri =
    String.fromEnvironment('FORGE_FLOW_PROXY_BASE_URI', defaultValue: '');

/// Proxy liveness probe path. `/healthz` is unauthenticated, returns
/// 200 OK with `{status: 'ok'}` when the proxy process is up, and 5xx
/// (or network errors) when it's not. The probe doesn't tell us
/// anything about Anthropic's model catalog — that endpoint isn't
/// exposed to clients today (Hard Promise #7) — so a 200 still maps to
/// [AnthropicModelCheckStatus.cannotCheck], NOT `available`. Returning
/// `available` here would fabricate a claim about Anthropic's catalog
/// that the client has no way to verify.
const String kForgeFlowProxyHealthPath = '/healthz';

/// Default per-call timeout for the proxy liveness probe. Bounds how
/// long Settings spends spinning when the proxy is unreachable.
const Duration kForgeFlowProxyProbeTimeout = Duration(seconds: 5);

/// Probes the F&F proxy's `/healthz` endpoint and returns a
/// `cannotCheck` result either way — `cannotCheck` because the proxy
/// does not currently expose Anthropic's model catalog to clients
/// (Hard Promise #7). The message differs so the dev can tell apart:
///   * proxy reachable + 2xx → "reachable but catalog not exposed"
///   * proxy returned 5xx → "infra problem"
///   * proxy unreachable → "network error"
///
/// Exposed (instead of inlined) so the unit test can drive it against
/// an in-process `HttpServer` without mutating the compile-time
/// `FORGE_FLOW_PROXY_BASE_URI` dart-define.
Future<AnthropicModelCheckResult> probeForgeFlowProxyHealth({
  required Uri? proxyBaseUri,
  HttpClient Function()? httpClientFactory,
  Duration timeout = kForgeFlowProxyProbeTimeout,
}) async {
  if (proxyBaseUri == null) {
    return const AnthropicModelCheckResult.cannotCheck(
      'FORGE_FLOW_PROXY_BASE_URI not configured. Re-launch with the '
      'proxy URL passed via '
      '`--dart-define=FORGE_FLOW_PROXY_BASE_URI=...` so the advisor '
      'model probe can reach the F&F proxy.',
    );
  }
  // Resolve the health path against the configured base. Use
  // `replace` rather than `Uri.resolve` so any prefix path on the base
  // (e.g. `https://host/api/`) is preserved instead of silently
  // replaced.
  final probeUri = proxyBaseUri.replace(path: kForgeFlowProxyHealthPath);
  HttpClient? client;
  try {
    client = (httpClientFactory ?? HttpClient.new)();
    final req = await client.getUrl(probeUri).timeout(timeout);
    final res = await req.close().timeout(timeout);
    // Drain the body so the connection can be reused / closed cleanly,
    // even when we don't parse it — `/healthz` returns a small JSON
    // object we don't currently inspect.
    await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return AnthropicModelCheckResult.cannotCheck(
        'F&F proxy returned HTTP ${res.statusCode} from '
        '$kForgeFlowProxyHealthPath. Cannot verify advisor model '
        'availability.',
      );
    }
    return const AnthropicModelCheckResult.cannotCheck(
      'F&F proxy is reachable but does not currently expose Anthropic '
      'model availability to clients (Hard Promise #7). Configured '
      'advisor model ids are assumed valid; check the proxy logs to '
      'confirm.',
    );
  } on TimeoutException catch (e) {
    return AnthropicModelCheckResult.cannotCheck(
        'F&F proxy probe timed out: $e');
  } catch (e) {
    return AnthropicModelCheckResult.cannotCheck(
        'F&F proxy probe failed: $e');
  } finally {
    client?.close(force: true);
  }
}

Future<AnthropicModelCheckResult> defaultAnthropicOnlineCheck({
  required String quickModelId,
  required String nuancedModelId,
}) async {
  // The model ids are accepted to satisfy the [AnthropicOnlineCheckFn]
  // typedef but no longer flow into the probe — the proxy doesn't
  // expose Anthropic's catalog, so there is nothing to compare them
  // against. Tests that need to assert availability/unavailability
  // inject a fake [AnthropicOnlineCheckFn].
  final base = _kProxyBaseUri.isEmpty ? null : Uri.tryParse(_kProxyBaseUri);
  if (_kProxyBaseUri.isNotEmpty && base == null) {
    return const AnthropicModelCheckResult.cannotCheck(
      'FORGE_FLOW_PROXY_BASE_URI is not a valid URI.',
    );
  }
  return probeForgeFlowProxyHealth(proxyBaseUri: base);
}

// ─── Service ─────────────────────────────────────────────────────────────────

class AdvisorModelConfigService {
  static const String quickKey = 'advisor_quick_model_override';
  static const String nuancedKey = 'advisor_nuanced_model_override';

  final Future<SharedPreferences> Function() _prefsLoader;
  final AnthropicOnlineCheckFn _onlineCheckFn;

  AdvisorModelConfigService({
    Future<SharedPreferences> Function()? prefsLoader,
    AnthropicOnlineCheckFn? onlineCheckFn,
  })  : _prefsLoader = prefsLoader ?? SharedPreferences.getInstance,
        _onlineCheckFn = onlineCheckFn ?? defaultAnthropicOnlineCheck;

  /// Resolve the current effective routing from persisted overrides.
  Future<AdvisorModelRouting> currentRouting() async {
    final prefs = await _prefsLoader();
    return AdvisorModelRouting.resolve(
      quickOverride: prefs.getString(quickKey),
      nuancedOverride: prefs.getString(nuancedKey),
    );
  }

  Future<void> saveQuickOverride(String modelId) async {
    final prefs = await _prefsLoader();
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(quickKey);
    } else {
      await prefs.setString(quickKey, trimmed);
    }
  }

  Future<void> saveNuancedOverride(String modelId) async {
    final prefs = await _prefsLoader();
    final trimmed = modelId.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(nuancedKey);
    } else {
      await prefs.setString(nuancedKey, trimmed);
    }
  }

  /// Drop both overrides, returning the routing to its pinned defaults.
  Future<void> resetOverrides() async {
    final prefs = await _prefsLoader();
    await prefs.remove(quickKey);
    await prefs.remove(nuancedKey);
  }

  /// Run the injected (or default) online check against Anthropic
  /// `GET /v1/models`. Routes the current effective ids in.
  Future<AnthropicModelCheckResult> checkAvailableModels() async {
    final routing = await currentRouting();
    return _onlineCheckFn(
      quickModelId: routing.effectiveQuickModelId,
      nuancedModelId: routing.effectiveNuancedModelId,
    );
  }
}
