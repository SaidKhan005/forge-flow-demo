import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Describes how a client version relates to the server's requirements.
enum VersionCompatibility {
  /// Client is current — no action needed.
  current,

  /// Client is behind the current release but still works (soft update).
  softUpdateAvailable,

  /// Client is below the minimum supported version (hard block).
  forceUpdateRequired,
}

/// Snapshot of the `/v1/system-info` response plus derived compatibility.
class SystemInfoSnapshot {
  const SystemInfoSnapshot({
    required this.minimumClientVersion,
    required this.currentClientVersion,
    required this.forceUpdateBelow,
    required this.iosAppStoreId,
    required this.androidPackageId,
    required this.clientVersion,
    required this.compatibility,
  });

  final String minimumClientVersion;
  final String currentClientVersion;
  final String forceUpdateBelow;
  final String iosAppStoreId;
  final String androidPackageId;

  /// The version string reported by the running app (from package_info_plus).
  final String clientVersion;

  /// Derived compatibility classification.
  final VersionCompatibility compatibility;

  /// True when the app must block the user and force an update.
  bool get mustForceUpdate =>
      compatibility == VersionCompatibility.forceUpdateRequired;

  /// True when a soft-update banner should be shown (but app is usable).
  bool get shouldSoftUpdate =>
      compatibility == VersionCompatibility.softUpdateAvailable;
}

/// Polls `GET /v1/system-info` on launch and on lifecycle resume.
///
/// Notifies listeners whenever a new [SystemInfoSnapshot] is received.
/// When the proxy URI is not configured (demo mode) the service is a no-op.
class SystemInfoService extends ChangeNotifier {
  SystemInfoService({
    required Uri? proxyBaseUri,
    http.Client? httpClient,
    Duration pollInterval = const Duration(hours: 1),
  }) : _proxyBaseUri = proxyBaseUri,
       _httpClient = httpClient ?? http.Client(),
       _pollInterval = pollInterval;

  final Uri? _proxyBaseUri;
  final http.Client _httpClient;
  final Duration _pollInterval;

  SystemInfoSnapshot? _latest;
  Timer? _pollTimer;

  SystemInfoSnapshot? get latest => _latest;

  /// Call once on app launch (after Firebase init).
  Future<void> initialize() async {
    await _fetchAndNotify();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _fetchAndNotify());
  }

  /// Call from [WidgetsBindingObserver.didChangeAppLifecycleState] on resume.
  Future<void> onResume() => _fetchAndNotify();

  Future<void> _fetchAndNotify() async {
    final base = _proxyBaseUri;
    if (base == null) return;
    try {
      final uri = base.resolve('/v1/system-info');
      final response = await _httpClient
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final clientVersion = await _resolveClientVersion();
      final snapshot = _parse(data, clientVersion);
      _latest = snapshot;
      notifyListeners();
    } catch (_) {
      // Network errors are best-effort; app continues normally.
    }
  }

  static Future<String> _resolveClientVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  static SystemInfoSnapshot _parse(
    Map<String, dynamic> data,
    String clientVersion,
  ) {
    final minimum = data['minimum_client_version'] as String? ?? '0.0.0';
    final current = data['current_client_version'] as String? ?? '0.0.0';
    final forceBelow = data['force_update_below'] as String? ?? '0.0.0';
    final iosId = data['ios_app_store_id'] as String? ?? '';
    final androidId = data['android_package_id'] as String? ?? '';

    final compatibility = _classify(
      clientVersion: clientVersion,
      minimumClientVersion: minimum,
      currentClientVersion: current,
      forceUpdateBelow: forceBelow,
    );

    return SystemInfoSnapshot(
      minimumClientVersion: minimum,
      currentClientVersion: current,
      forceUpdateBelow: forceBelow,
      iosAppStoreId: iosId,
      androidPackageId: androidId,
      clientVersion: clientVersion,
      compatibility: compatibility,
    );
  }

  static VersionCompatibility _classify({
    required String clientVersion,
    required String minimumClientVersion,
    required String currentClientVersion,
    required String forceUpdateBelow,
  }) {
    final client = _parseVersion(clientVersion);
    final forceBelow = _parseVersion(forceUpdateBelow);
    final currentServer = _parseVersion(currentClientVersion);

    if (_isLessThan(client, forceBelow)) {
      return VersionCompatibility.forceUpdateRequired;
    }
    if (_isLessThan(client, currentServer)) {
      return VersionCompatibility.softUpdateAvailable;
    }
    return VersionCompatibility.current;
  }

  /// Parses a semver string into a list of ints, e.g. "1.2.3" → [1, 2, 3].
  static List<int> _parseVersion(String version) {
    return version
        .split('.')
        .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  static bool _isLessThan(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai < bi) return true;
      if (ai > bi) return false;
    }
    return false;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _httpClient.close();
    super.dispose();
  }
}
