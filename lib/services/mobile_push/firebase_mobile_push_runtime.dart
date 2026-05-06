import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'mobile_push_notification_service.dart';

const String kForgeFlowNotificationChannelId = 'forge_flow_app_notifications';
const String kForgeFlowNotificationChannelName = 'Forge & Flow notifications';
const String kForgeFlowNotificationChannelDescription =
    'Operational app notifications from Forge & Flow.';

@pragma('vm:entry-point')
Future<void> forgeFlowFirebaseMessagingBackgroundHandler(
  RemoteMessage _,
) async {
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
  } catch (_) {
    // Background delivery is best-effort; app launch/open handling
    // still routes through getInitialMessage/onMessageOpenedApp.
  }
}

@pragma('vm:entry-point')
void forgeFlowLocalNotificationTapBackground(NotificationResponse _) {}

MobilePushNotificationService createFirebaseMobilePushNotificationService({
  MobilePushTokenGateway? tokenGateway,
  MobilePushInstallationIdStore? installationIdStore,
  FirebaseMessaging? messaging,
  FlutterLocalNotificationsPlugin? localNotifications,
  String appVariant = 'forgeflow',
  String appEnvironment = 'staging',
  void Function(String message)? log,
}) {
  final environment = FlutterMobilePushRuntimeEnvironment.current();
  if (!environment.isMobile || Firebase.apps.isEmpty) {
    return const NoopMobilePushNotificationService();
  }
  FirebaseMobilePushMessagingClient.registerBackgroundHandler();
  return MobilePushNotificationCoordinator(
    environment: environment,
    messaging: FirebaseMobilePushMessagingClient(
      messaging: messaging ?? FirebaseMessaging.instance,
    ),
    foregroundNotifications: FlutterLocalNotificationPresenter(
      plugin: localNotifications ?? FlutterLocalNotificationsPlugin(),
    ),
    tokenGateway: tokenGateway ?? const NoopMobilePushTokenGateway(),
    routeIntents: MobilePushRouteIntentController(),
    installationIdStore:
        installationIdStore ?? SecureStorageMobilePushInstallationIdStore(),
    appVariant: appVariant,
    appEnvironment: appEnvironment,
    log: log,
  );
}

class FlutterMobilePushRuntimeEnvironment {
  const FlutterMobilePushRuntimeEnvironment._();

  static MobilePushRuntimeEnvironment current() {
    if (kIsWeb) {
      return const MobilePushRuntimeEnvironment(
        isMobile: false,
        platform: 'web',
      );
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => const MobilePushRuntimeEnvironment(
        isMobile: true,
        platform: 'android',
      ),
      TargetPlatform.iOS => const MobilePushRuntimeEnvironment(
        isMobile: true,
        platform: 'ios',
      ),
      TargetPlatform.fuchsia ||
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => MobilePushRuntimeEnvironment(
        isMobile: false,
        platform: defaultTargetPlatform.name,
      ),
    };
  }
}

class FirebaseMobilePushMessagingClient implements MobilePushMessagingClient {
  FirebaseMobilePushMessagingClient({required FirebaseMessaging messaging})
    : _messaging = messaging;

  final FirebaseMessaging _messaging;
  static bool _backgroundHandlerRegistered = false;

  static void registerBackgroundHandler() {
    if (_backgroundHandlerRegistered) return;
    FirebaseMessaging.onBackgroundMessage(
      forgeFlowFirebaseMessagingBackgroundHandler,
    );
    _backgroundHandlerRegistered = true;
  }

  @override
  Stream<MobilePushRemoteMessage> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(_fromRemoteMessage);

  @override
  Stream<MobilePushRemoteMessage> get openedMessages =>
      FirebaseMessaging.onMessageOpenedApp.map(_fromRemoteMessage);

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<MobilePushRemoteMessage?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _fromRemoteMessage(message);
  }

  @override
  Future<String?> getToken() => _messaging.getToken();

  @override
  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  static MobilePushRemoteMessage _fromRemoteMessage(RemoteMessage message) {
    return MobilePushRemoteMessage(
      messageId: message.messageId,
      title: message.notification?.title,
      body: message.notification?.body,
      data: <String, String>{
        for (final entry in message.data.entries)
          entry.key: entry.value.toString(),
      },
    );
  }
}

class FlutterLocalNotificationPresenter
    implements ForegroundNotificationPresenter {
  FlutterLocalNotificationPresenter({
    required FlutterLocalNotificationsPlugin plugin,
  }) : _plugin = plugin;

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize({required void Function() onNotificationTap}) async {
    const initializationSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );
    await _plugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (_) => onNotificationTap(),
      onDidReceiveBackgroundNotificationResponse:
          forgeFlowLocalNotificationTapBackground,
    );
    await _ensureAndroidChannel();
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      onNotificationTap();
    }
  }

  @override
  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  @override
  Future<void> show(MobilePushLocalNotification notification) {
    return _plugin.show(
      id: notification.id,
      title: notification.title,
      body: notification.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          kForgeFlowNotificationChannelId,
          kForgeFlowNotificationChannelName,
          channelDescription: kForgeFlowNotificationChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: notification.payload,
    );
  }

  Future<void> _ensureAndroidChannel() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            kForgeFlowNotificationChannelId,
            kForgeFlowNotificationChannelName,
            description: kForgeFlowNotificationChannelDescription,
            importance: Importance.high,
          ),
        );
  }
}
