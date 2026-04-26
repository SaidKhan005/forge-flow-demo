// Forge & Flow — AdvisorModelConfigService.
//
// 7.57.3a-review-fix. Persists dev-only overrides for the advisor
// answer model ids via SharedPreferences and exposes an injected online
// check against Anthropic's `GET /v1/models` endpoint.
//
// Hard rules:
//   * No API keys are persisted. The Anthropic API key for the online
//     check comes from the compile-time env (`--dart-define=
//     ANTHROPIC_API_KEY=...`).
//   * Embedding/rerank models are pinned in `AdvisorProviderConstants`
//     and are not editable here — only Claude answer model overrides
//     (quick / nuanced) round-trip through this service.

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/services/advisor_model_routing.dart';

// ─── Online check result ─────────────────────────────────────────────────────

/// Outcome of a `GET /v1/models` request.
enum AnthropicModelCheckStatus {
  /// API call succeeded; both effective ids are present in the returned
  /// model list.
  available,

  /// API call succeeded; one or both effective ids are NOT in the
  /// returned model list (likely because Anthropic deprecated the id).
  unavailable,

  /// Could not reach Anthropic — missing API key, network error, or
  /// non-2xx response. The dev should not interpret this as
  /// "model is dead".
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

bool _isHaikuFamily(String id) => id.toLowerCase().contains('haiku');
bool _isSonnetFamily(String id) => id.toLowerCase().contains('sonnet');

/// Online-check function the service delegates to. Production wires
/// [defaultAnthropicOnlineCheck]; tests inject a fake.
typedef AnthropicOnlineCheckFn = Future<AnthropicModelCheckResult> Function({
  required String quickModelId,
  required String nuancedModelId,
});

// ─── Default production online check ────────────────────────────────────────

/// Compile-time API key. Provided at build via
/// `--dart-define=ANTHROPIC_API_KEY=...`. Empty when not provided —
/// the check then returns [AnthropicModelCheckStatus.cannotCheck].
const String _kAnthropicApiKey =
    String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '');

const String _kAnthropicModelsUrl = 'https://api.anthropic.com/v1/models';

Future<AnthropicModelCheckResult> defaultAnthropicOnlineCheck({
  required String quickModelId,
  required String nuancedModelId,
}) async {
  if (_kAnthropicApiKey.isEmpty) {
    return const AnthropicModelCheckResult.cannotCheck(
      'ANTHROPIC_API_KEY not provided. Re-launch with '
      'scripts/run_flutter_dev.ps1 -App forgeflow, or pass '
      '--dart-define=ANTHROPIC_API_KEY=...',
    );
  }
  HttpClient? client;
  try {
    client = HttpClient();
    final req = await client.getUrl(Uri.parse(_kAnthropicModelsUrl));
    req.headers.set('x-api-key', _kAnthropicApiKey);
    req.headers.set('anthropic-version', '2023-06-01');
    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return AnthropicModelCheckResult.cannotCheck(
          'Anthropic returned HTTP ${res.statusCode}.');
    }
    final body = await res.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    final ids = <String>[];
    if (decoded is Map && decoded['data'] is List) {
      for (final item in decoded['data'] as List) {
        if (item is Map && item['id'] is String) {
          ids.add(item['id'] as String);
        }
      }
    }
    final hasQuick = ids.contains(quickModelId);
    final hasNuanced = ids.contains(nuancedModelId);
    if (hasQuick && hasNuanced) {
      final latestQuick =
          findUpdateCandidate(ids, quickModelId, _isHaikuFamily);
      final latestNuanced =
          findUpdateCandidate(ids, nuancedModelId, _isSonnetFamily);
      final hasUpdate = latestQuick != null || latestNuanced != null;
      final message = hasUpdate
          ? 'Both configured models are listed, but newer same-family '
              'candidates exist: '
              '${[
              if (latestQuick != null) 'Haiku=$latestQuick',
              if (latestNuanced != null) 'Sonnet=$latestNuanced',
            ].join(', ')}.'
          : 'Both configured models are listed by Anthropic and are the '
              'latest in their family (${ids.length} models in response).';
      return AnthropicModelCheckResult(
        status: AnthropicModelCheckStatus.available,
        message: message,
        seenModelIds: ids,
        updateAvailable: hasUpdate,
        latestQuickCandidate: latestQuick,
        latestNuancedCandidate: latestNuanced,
      );
    }
    final missing = <String>[
      if (!hasQuick) quickModelId,
      if (!hasNuanced) nuancedModelId,
    ].join(', ');
    return AnthropicModelCheckResult(
      status: AnthropicModelCheckStatus.unavailable,
      message: 'Missing from Anthropic response: $missing.',
      seenModelIds: ids,
    );
  } catch (e) {
    return AnthropicModelCheckResult.cannotCheck(
        'Anthropic check failed: $e');
  } finally {
    client?.close(force: true);
  }
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
