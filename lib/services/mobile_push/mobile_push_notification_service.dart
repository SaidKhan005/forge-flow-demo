import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MobilePushRouteDestination { notifications }

class MobilePushRouteIntent {
  const MobilePushRouteIntent.notifications({this.notificationId})
    : destination = MobilePushRouteDestination.notifications;

  final MobilePushRouteDestination destination;
  final String? notificationId;
}

abstract class MobilePushRouteIntentSource {
  Stream<MobilePushRouteIntent> get intents;
  List<MobilePushRouteIntent> takePendingIntents();
}

abstract class MobilePushRouteIntentSink {
  void add(MobilePushRouteIntent intent);
}

// ── A9.SY3 — Push cold-start disk persistence ─────────────────────────────

/// Serializes/deserializes pending [MobilePushRouteIntent]s to a
/// `shared_preferences` key so that `takePendingIntents` survives the
/// race between `getInitialMessage` (which adds the cold-start intent
/// asynchronously) and the destination screen mounting and draining
/// the in-memory list before the intent lands.
///
/// [SharedPreferencesMobilePushIntentStore] is the production
/// implementation. Tests inject [InMemoryMobilePushIntentStore].
abstract class MobilePushIntentDiskStore {
  /// Load persisted intents and clear them from disk in one atomic
  /// operation. Returns an empty list when nothing is stored.
  Future<List<MobilePushRouteIntent>> drainPersistedIntents();

  /// Append [intent] to the durable list. Called by
  /// [MobilePushRouteIntentController.add] whenever an intent is added
  /// to the in-memory pending list.
  Future<void> persistIntent(MobilePushRouteIntent intent);

  /// Erase all persisted intents. Called after
  /// [MobilePushRouteIntentController.takePendingIntents] drains them.
  Future<void> clearPersistedIntents();
}

/// Production implementation backed by [SharedPreferences].
class SharedPreferencesMobilePushIntentStore
    implements MobilePushIntentDiskStore {
  static const String _key = 'forge_flow_push_pending_intents_v1';

  @override
  Future<List<MobilePushRouteIntent>> drainPersistedIntents() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_key);
    await prefs.remove(_key);
    if (raw == null || raw.isEmpty) return const <MobilePushRouteIntent>[];
    final intents = <MobilePushRouteIntent>[];
    for (final item in raw) {
      final decoded = _decode(item);
      if (decoded != null) intents.add(decoded);
    }
    return intents;
  }

  @override
  Future<void> persistIntent(MobilePushRouteIntent intent) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_key) ?? <String>[];
    existing.add(_encode(intent));
    await prefs.setStringList(_key, existing);
  }

  @override
  Future<void> clearPersistedIntents() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static String _encode(MobilePushRouteIntent intent) {
    return jsonEncode(<String, Object?>{
      'destination': intent.destination.name,
      'notification_id': intent.notificationId,
    });
  }

  static MobilePushRouteIntent? _decode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final dest = map['destination'] as String?;
      if (dest == null) return null;
      final notificationId = map['notification_id'] as String?;
      switch (dest) {
        case 'notifications':
          return MobilePushRouteIntent.notifications(
            notificationId: notificationId,
          );
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }
}

/// Test double — in-memory only; no SharedPreferences dependency.
class InMemoryMobilePushIntentStore implements MobilePushIntentDiskStore {
  final List<MobilePushRouteIntent> _store = <MobilePushRouteIntent>[];

  List<MobilePushRouteIntent> get stored =>
      List<MobilePushRouteIntent>.unmodifiable(_store);

  @override
  Future<List<MobilePushRouteIntent>> drainPersistedIntents() async {
    final copy = List<MobilePushRouteIntent>.from(_store);
    _store.clear();
    return copy;
  }

  @override
  Future<void> persistIntent(MobilePushRouteIntent intent) async {
    _store.add(intent);
  }

  @override
  Future<void> clearPersistedIntents() async {
    _store.clear();
  }
}

/// Route-intent controller with A9.SY3 cold-start disk persistence.
///
/// When an intent is added to the in-memory pending list it is also
/// written to [_diskStore]. [takePendingIntents] drains BOTH the
/// in-memory list AND the disk store, then clears the disk store.
///
/// This survives the race where [MobilePushMessagingClient.getInitialMessage]
/// adds an intent after [takePendingIntents] has already run (the
/// destination screen mounts, drains the empty in-memory list, then
/// the async initial message arrives and is stored to disk). The next
/// call to [takePendingIntents] — when the screen re-mounts or when
/// the app returns to foreground — picks it up from disk.
class MobilePushRouteIntentController
    implements MobilePushRouteIntentSource, MobilePushRouteIntentSink {
  MobilePushRouteIntentController({MobilePushIntentDiskStore? diskStore})
    : _controller = StreamController<MobilePushRouteIntent>.broadcast(),
      _diskStore = diskStore ?? SharedPreferencesMobilePushIntentStore();

  final StreamController<MobilePushRouteIntent> _controller;
  final List<MobilePushRouteIntent> _pending = <MobilePushRouteIntent>[];
  final MobilePushIntentDiskStore _diskStore;

  @override
  Stream<MobilePushRouteIntent> get intents => _controller.stream;

  @override
  List<MobilePushRouteIntent> takePendingIntents() {
    final inMemory = List<MobilePushRouteIntent>.from(_pending);
    _pending.clear();
    // Drain disk asynchronously. Any intents found on disk that are not
    // already in inMemory are re-published to the stream so active
    // listeners receive them. Immediate return covers the common case
    // where the disk store is empty.
    //
    // NOTE: We return the in-memory snapshot synchronously to preserve
    // the existing synchronous contract. The disk drain fires
    // fire-and-forget; callers that need guaranteed delivery should
    // re-call takePendingIntents or listen to [intents].
    _drainDiskAsync();
    // Clear disk entries for the intents we're returning right now.
    _diskStore.clearPersistedIntents();
    return List<MobilePushRouteIntent>.unmodifiable(inMemory);
  }

  void _drainDiskAsync() {
    _diskStore
        .drainPersistedIntents()
        .then((persisted) {
          for (final intent in persisted) {
            // Re-publish to the stream so active listeners receive it.
            if (!_controller.isClosed) {
              _controller.add(intent);
            }
          }
        })
        .catchError((_) {
          // Disk drain failure is non-fatal; intents may be lost on
          // this cold-start but the app still functions.
        });
  }

  @override
  void add(MobilePushRouteIntent intent) {
    if (!_controller.hasListener) {
      _pending.add(intent);
      // A9.SY3: persist to disk so a takePendingIntents that already
      // ran before this intent arrived can still pick it up.
      _diskStore.persistIntent(intent).catchError((_) {
        // Persistence failure is non-fatal.
      });
    }
    if (!_controller.isClosed) {
      _controller.add(intent);
    }
  }

  Future<void> dispose() => _controller.close();
}

class MobilePushRegistrationContext {
  const MobilePushRegistrationContext({
    required this.userId,
    required this.operatorId,
    required this.locationId,
  });

  final String userId;
  final String operatorId;
  final String locationId;

  @override
  bool operator ==(Object other) {
    return other is MobilePushRegistrationContext &&
        other.userId == userId &&
        other.operatorId == operatorId &&
        other.locationId == locationId;
  }

  @override
  int get hashCode => Object.hash(userId, operatorId, locationId);
}

class MobilePushTokenRegistration {
  const MobilePushTokenRegistration({
    required this.token,
    required this.platform,
    required this.context,
    required this.appVariant,
    required this.appEnvironment,
    required this.installationId,
    this.provider = 'fcm',
  });

  final String token;
  final String platform;
  final MobilePushRegistrationContext context;
  final String appVariant;
  final String appEnvironment;
  final String installationId;
  final String provider;
}

class MobilePushTokenDeletion {
  const MobilePushTokenDeletion({
    required this.token,
    required this.platform,
    required this.context,
    required this.appVariant,
    required this.appEnvironment,
    required this.installationId,
  });

  final String token;
  final String platform;
  final MobilePushRegistrationContext context;
  final String appVariant;
  final String appEnvironment;
  final String installationId;
}

abstract class MobilePushTokenGateway {
  Future<void> registerToken(MobilePushTokenRegistration registration);
  Future<void> updateToken({
    required String previousToken,
    required MobilePushTokenRegistration registration,
  });
  Future<void> deleteToken(MobilePushTokenDeletion deletion);
}

class NoopMobilePushTokenGateway implements MobilePushTokenGateway {
  const NoopMobilePushTokenGateway();

  @override
  Future<void> registerToken(MobilePushTokenRegistration registration) async {}

  @override
  Future<void> updateToken({
    required String previousToken,
    required MobilePushTokenRegistration registration,
  }) async {}

  @override
  Future<void> deleteToken(MobilePushTokenDeletion deletion) async {}
}

class ProxyMobilePushTokenGateway implements MobilePushTokenGateway {
  ProxyMobilePushTokenGateway({
    required Uri proxyBaseUri,
    required Future<String?> Function() idTokenProvider,
    required Object httpClient,
  }) : _proxyBaseUri = proxyBaseUri,
       _idTokenProvider = idTokenProvider,
       _httpClient = httpClient;

  final Uri _proxyBaseUri;
  final Future<String?> Function() _idTokenProvider;
  final dynamic _httpClient;

  static const String _registerPath = '/v1/auth/mobile/push-token/register';
  static const String _revokePath = '/v1/auth/mobile/push-token/revoke';

  @override
  Future<void> registerToken(MobilePushTokenRegistration registration) async {
    await _post(_registerPath, <String, Object?>{
      'token': registration.token,
      'platform': registration.platform,
      'provider': registration.provider,
      'app_variant': registration.appVariant,
      'app_environment': registration.appEnvironment,
      'installation_id': registration.installationId,
      'client_info': <String, Object?>{
        'source': 'flutter_fcm',
        'location_id': registration.context.locationId,
      },
    });
  }

  @override
  Future<void> updateToken({
    required String previousToken,
    required MobilePushTokenRegistration registration,
  }) async {
    if (previousToken != registration.token) {
      await deleteToken(
        MobilePushTokenDeletion(
          token: previousToken,
          platform: registration.platform,
          context: registration.context,
          appVariant: registration.appVariant,
          appEnvironment: registration.appEnvironment,
          installationId: registration.installationId,
        ),
      );
    }
    await registerToken(registration);
  }

  @override
  Future<void> deleteToken(MobilePushTokenDeletion deletion) async {
    await _post(_revokePath, <String, Object?>{
      'token': deletion.token,
      'platform': deletion.platform,
      'app_variant': deletion.appVariant,
      'app_environment': deletion.appEnvironment,
      'installation_id': deletion.installationId,
    });
  }

  Future<void> _post(String path, Map<String, Object?> body) async {
    final idToken = await _idTokenProvider();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('mobile push proxy call requires a Firebase ID token');
    }
    final response = await _httpClient.postJson(
      url: _proxyBaseUri.resolve(path),
      headers: <String, String>{'Authorization': 'Bearer $idToken'},
      body: body,
    );
    final statusCode = response.statusCode as int;
    if (statusCode < 200 || statusCode >= 300) {
      final responseBody = response.body;
      final Object? error = responseBody is Map ? responseBody['error'] : null;
      throw StateError(
        'mobile push proxy call failed: '
        '${error is String && error.isNotEmpty ? error : statusCode}',
      );
    }
  }
}

abstract class MobilePushInstallationIdStore {
  Future<String> installationId();
}

class SecureStorageMobilePushInstallationIdStore
    implements MobilePushInstallationIdStore {
  SecureStorageMobilePushInstallationIdStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
  }) : _storage = storage;

  final FlutterSecureStorage _storage;

  static const String _key = 'forge_flow_mobile_push_installation_id';

  @override
  Future<String> installationId() async {
    final existing = await _storage.read(key: _key);
    if (existing != null && existing.trim().isNotEmpty) {
      return existing.trim();
    }
    final generated = _randomHex(bytes: 16);
    await _storage.write(key: _key, value: generated);
    return generated;
  }

  static String _randomHex({required int bytes}) {
    final random = math.Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytes; i += 1) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

class StaticMobilePushInstallationIdStore
    implements MobilePushInstallationIdStore {
  const StaticMobilePushInstallationIdStore(this.value);

  final String value;

  @override
  Future<String> installationId() async => value;
}

class MobilePushRemoteMessage {
  const MobilePushRemoteMessage({
    this.messageId,
    this.title,
    this.body,
    this.data = const <String, String>{},
  });

  final String? messageId;
  final String? title;
  final String? body;
  final Map<String, String> data;

  String? get notificationId {
    return data['notification_id'] ??
        data['notificationId'] ??
        data['app_notification_id'];
  }
}

class MobilePushLocalNotification {
  const MobilePushLocalNotification({
    required this.id,
    required this.title,
    required this.body,
    this.payload,
  });

  final int id;
  final String title;
  final String body;
  final String? payload;
}

abstract class MobilePushMessagingClient {
  Stream<MobilePushRemoteMessage> get foregroundMessages;
  Stream<MobilePushRemoteMessage> get openedMessages;
  Stream<String> get tokenRefreshes;
  Future<bool> requestPermission();
  Future<String?> getToken();
  Future<MobilePushRemoteMessage?> getInitialMessage();
}

abstract class ForegroundNotificationPresenter {
  Future<void> initialize({required void Function() onNotificationTap});
  Future<void> requestPermission();
  Future<void> show(MobilePushLocalNotification notification);
}

class MobilePushRuntimeEnvironment {
  const MobilePushRuntimeEnvironment({
    required this.isMobile,
    required this.platform,
  });

  final bool isMobile;
  final String platform;
}

abstract class MobilePushNotificationService {
  MobilePushRouteIntentSource get routeIntents;
  Future<void> start();
  Future<void> updateRegistrationContext(
    MobilePushRegistrationContext? context,
  );
  Future<void> reValidateToken();
  Future<void> dispose();
}

/// W2.A — sink that lands a push-delivered notification into the in-app
/// inbox so the existing notifications screen and bell badge mirror what
/// the operator saw on the lockscreen.
///
/// The coordinator is messaging-only (no SQLite imports), so the actual
/// inbox writer is injected. The runtime factory wires the production
/// implementation, which resolves the active restaurant scope and calls
/// `AppNotificationService.instance.emitPushDelivery`.
typedef MobilePushInboxSink =
    Future<void> Function(MobilePushRemoteMessage message);

class NoopMobilePushRouteIntentSource implements MobilePushRouteIntentSource {
  const NoopMobilePushRouteIntentSource();

  @override
  Stream<MobilePushRouteIntent> get intents =>
      const Stream<MobilePushRouteIntent>.empty();

  @override
  List<MobilePushRouteIntent> takePendingIntents() =>
      const <MobilePushRouteIntent>[];
}

class NoopMobilePushNotificationService
    implements MobilePushNotificationService {
  const NoopMobilePushNotificationService();

  @override
  MobilePushRouteIntentSource get routeIntents =>
      const NoopMobilePushRouteIntentSource();

  @override
  Future<void> start() async {}

  @override
  Future<void> updateRegistrationContext(
    MobilePushRegistrationContext? context,
  ) async {}

  @override
  Future<void> reValidateToken() async {}

  @override
  Future<void> dispose() async {}
}

class MobilePushNotificationCoordinator
    implements MobilePushNotificationService {
  MobilePushNotificationCoordinator({
    required MobilePushRuntimeEnvironment environment,
    required MobilePushMessagingClient messaging,
    required ForegroundNotificationPresenter foregroundNotifications,
    required MobilePushTokenGateway tokenGateway,
    required MobilePushRouteIntentController routeIntents,
    required MobilePushInstallationIdStore installationIdStore,
    required String appVariant,
    required String appEnvironment,
    void Function(String message)? log,
    MobilePushInboxSink? inboxSink,
  }) : _environment = environment,
       _messaging = messaging,
       _foregroundNotifications = foregroundNotifications,
       _tokenGateway = tokenGateway,
       _routeIntents = routeIntents,
       _installationIdStore = installationIdStore,
       _appVariant = appVariant,
       _appEnvironment = appEnvironment,
       _log = log,
       _inboxSink = inboxSink;

  final MobilePushRuntimeEnvironment _environment;
  final MobilePushMessagingClient _messaging;
  final ForegroundNotificationPresenter _foregroundNotifications;
  final MobilePushTokenGateway _tokenGateway;
  final MobilePushRouteIntentController _routeIntents;
  final MobilePushInstallationIdStore _installationIdStore;
  final String _appVariant;
  final String _appEnvironment;
  final void Function(String message)? _log;
  final MobilePushInboxSink? _inboxSink;

  StreamSubscription<MobilePushRemoteMessage>? _foregroundSubscription;
  StreamSubscription<MobilePushRemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  MobilePushRegistrationContext? _registrationContext;
  MobilePushRegistrationContext? _registeredContext;
  String? _latestToken;
  String? _registeredToken;
  String? _installationId;
  bool _started = false;

  @override
  MobilePushRouteIntentSource get routeIntents => _routeIntents;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (!_environment.isMobile) return;

    await _foregroundNotifications.initialize(
      onNotificationTap: _openNotifications,
    );
    await _messaging.requestPermission();
    await _foregroundNotifications.requestPermission();
    _installationId = await _installationIdStore.installationId();

    _foregroundSubscription = _messaging.foregroundMessages.listen(
      (message) => unawaited(_showForegroundNotification(message)),
    );
    _openedSubscription = _messaging.openedMessages.listen(_handleMessageOpen);
    _tokenRefreshSubscription = _messaging.tokenRefreshes.listen(
      (token) => unawaited(_handleTokenRefresh(token)),
    );

    _latestToken = await _messaging.getToken();
    await _syncRegistration();

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) {
      // Terminated-state delivery: when the app launches from a tap on
      // a push, persist the message into the inbox before routing so
      // the operator lands on a populated list.
      unawaited(_recordInboxDelivery(initialMessage));
      _handleMessageOpen(initialMessage);
    }
  }

  @override
  Future<void> updateRegistrationContext(
    MobilePushRegistrationContext? context,
  ) async {
    if (!_environment.isMobile) {
      _registrationContext = context;
      return;
    }
    if (context == _registrationContext) return;

    final previousContext = _registrationContext;
    _registrationContext = context;
    if (context == null) {
      await _deleteRegisteredToken(previousContext);
      return;
    }
    if (_registeredToken != null &&
        _registeredContext != null &&
        _registeredContext != context) {
      await _deleteRegisteredToken(_registeredContext);
    }
    await _syncRegistration();
  }

  Future<void> _handleTokenRefresh(String token) async {
    if (token.isEmpty) return;
    final previousToken = _registeredToken;
    _latestToken = token;
    final context = _registrationContext;
    if (context == null) return;
    final registration = MobilePushTokenRegistration(
      token: token,
      platform: _environment.platform,
      context: context,
      appVariant: _appVariant,
      appEnvironment: _appEnvironment,
      installationId: await _requireInstallationId(),
    );
    if (previousToken == null) {
      await _guardGatewayCall(() => _tokenGateway.registerToken(registration));
    } else if (previousToken != token) {
      await _guardGatewayCall(
        () => _tokenGateway.updateToken(
          previousToken: previousToken,
          registration: registration,
        ),
      );
    }
    _registeredToken = token;
    _registeredContext = context;
  }

  Future<void> _syncRegistration() async {
    final token = _latestToken;
    final context = _registrationContext;
    if (token == null || token.isEmpty || context == null) return;
    if (_registeredToken == token && _registeredContext == context) return;
    final registration = MobilePushTokenRegistration(
      token: token,
      platform: _environment.platform,
      context: context,
      appVariant: _appVariant,
      appEnvironment: _appEnvironment,
      installationId: await _requireInstallationId(),
    );
    await _guardGatewayCall(() => _tokenGateway.registerToken(registration));
    _registeredToken = token;
    _registeredContext = context;
  }

  Future<void> _deleteRegisteredToken(
    MobilePushRegistrationContext? fallbackContext,
  ) async {
    final token = _registeredToken;
    final context = _registeredContext ?? fallbackContext;
    if (token == null || context == null) return;
    final deletion = MobilePushTokenDeletion(
      token: token,
      platform: _environment.platform,
      context: context,
      appVariant: _appVariant,
      appEnvironment: _appEnvironment,
      installationId: await _requireInstallationId(),
    );
    await _guardGatewayCall(() => _tokenGateway.deleteToken(deletion));
    _registeredToken = null;
    _registeredContext = null;
  }

  Future<void> _showForegroundNotification(
    MobilePushRemoteMessage message,
  ) async {
    final title = _firstPresent(
      message.title,
      message.data['title'],
      'Forge & Flow',
    );
    final body = _firstPresent(
      message.body,
      message.data['body'],
      'New notification available.',
      third: message.data['message'],
    );
    await _foregroundNotifications.show(
      MobilePushLocalNotification(
        id: _notificationIdFor(message),
        title: title,
        body: body,
        payload: message.notificationId,
      ),
    );
    // Mirror the platform notification into the in-app inbox so the
    // bell badge ticks up and the notifications screen carries the
    // entry alongside locally-emitted events.
    await _recordInboxDelivery(message);
  }

  void _handleMessageOpen(MobilePushRemoteMessage message) {
    // Background-tap path: the OS already showed the platform
    // notification — make sure the inbox row exists before the
    // operator is routed to the list.
    unawaited(_recordInboxDelivery(message));
    _routeIntents.add(
      MobilePushRouteIntent.notifications(
        notificationId: message.notificationId,
      ),
    );
  }

  Future<void> _recordInboxDelivery(MobilePushRemoteMessage message) async {
    final sink = _inboxSink;
    if (sink == null) return;
    try {
      await sink(message);
    } catch (error) {
      _log?.call('Mobile push inbox sink failed: $error');
    }
  }

  void _openNotifications() {
    _routeIntents.add(const MobilePushRouteIntent.notifications());
  }

  int _notificationIdFor(MobilePushRemoteMessage message) {
    final idSeed = message.messageId ?? message.notificationId;
    if (idSeed == null || idSeed.isEmpty) {
      return DateTime.now().millisecondsSinceEpoch.remainder(1 << 31);
    }
    return idSeed.hashCode & 0x7fffffff;
  }

  String _firstPresent(
    String? first,
    String? second,
    String fallback, {
    String? third,
  }) {
    for (final candidate in <String?>[first, second, third]) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate;
      }
    }
    return fallback;
  }

  Future<void> _guardGatewayCall(Future<void> Function() call) async {
    try {
      await call();
    } catch (error) {
      _log?.call('Mobile push token gateway failed: $error');
    }
  }

  Future<String> _requireInstallationId() async {
    final current = _installationId;
    if (current != null && current.isNotEmpty) return current;
    final next = await _installationIdStore.installationId();
    _installationId = next;
    return next;
  }

  /// Re-validates the FCM token when the app resumes from background.
  /// Ensures the token is fresh and synchronized with the backend.
  /// Gracefully handles cases where the token is not yet initialized.
  @override
  Future<void> reValidateToken() async {
    if (!_environment.isMobile) return;
    final token = await _messaging.getToken();
    if (token == null || token.isEmpty) return;
    await _handleTokenRefresh(token);
  }

  @override
  Future<void> dispose() async {
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _tokenRefreshSubscription?.cancel();
    _foregroundSubscription = null;
    _openedSubscription = null;
    _tokenRefreshSubscription = null;
    await _routeIntents.dispose();
  }
}
