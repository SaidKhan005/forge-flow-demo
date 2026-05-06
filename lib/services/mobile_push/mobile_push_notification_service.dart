import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

class MobilePushRouteIntentController
    implements MobilePushRouteIntentSource, MobilePushRouteIntentSink {
  MobilePushRouteIntentController()
    : _controller = StreamController<MobilePushRouteIntent>.broadcast();

  final StreamController<MobilePushRouteIntent> _controller;
  final List<MobilePushRouteIntent> _pending = <MobilePushRouteIntent>[];

  @override
  Stream<MobilePushRouteIntent> get intents => _controller.stream;

  @override
  List<MobilePushRouteIntent> takePendingIntents() {
    final pending = List<MobilePushRouteIntent>.unmodifiable(_pending);
    _pending.clear();
    return pending;
  }

  @override
  void add(MobilePushRouteIntent intent) {
    if (!_controller.hasListener) {
      _pending.add(intent);
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
  Future<void> dispose();
}

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
  }) : _environment = environment,
       _messaging = messaging,
       _foregroundNotifications = foregroundNotifications,
       _tokenGateway = tokenGateway,
       _routeIntents = routeIntents,
       _installationIdStore = installationIdStore,
       _appVariant = appVariant,
       _appEnvironment = appEnvironment,
       _log = log;

  final MobilePushRuntimeEnvironment _environment;
  final MobilePushMessagingClient _messaging;
  final ForegroundNotificationPresenter _foregroundNotifications;
  final MobilePushTokenGateway _tokenGateway;
  final MobilePushRouteIntentController _routeIntents;
  final MobilePushInstallationIdStore _installationIdStore;
  final String _appVariant;
  final String _appEnvironment;
  final void Function(String message)? _log;

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
  }

  void _handleMessageOpen(MobilePushRemoteMessage message) {
    _routeIntents.add(
      MobilePushRouteIntent.notifications(
        notificationId: message.notificationId,
      ),
    );
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
