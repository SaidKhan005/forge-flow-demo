import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/mobile_push/mobile_push_notification_service.dart';

void main() {
  const context = MobilePushRegistrationContext(
    userId: 'user_1',
    operatorId: 'operator_1',
    locationId: 'location_1',
  );
  const otherContext = MobilePushRegistrationContext(
    userId: 'user_2',
    operatorId: 'operator_2',
    locationId: 'location_2',
  );

  group('MobilePushNotificationCoordinator', () {
    test('leaves non-mobile runtimes as no-op', () async {
      final messaging = _FakeMessagingClient(token: 'token_1');
      final presenter = _FakeForegroundPresenter();
      final gateway = _FakeTokenGateway();
      final coordinator = _buildCoordinator(
        environment: const MobilePushRuntimeEnvironment(
          isMobile: false,
          platform: 'windows',
        ),
        messaging: messaging,
        presenter: presenter,
        gateway: gateway,
      );

      await coordinator.updateRegistrationContext(context);
      await coordinator.start();

      expect(messaging.permissionRequests, 0);
      expect(messaging.tokenReads, 0);
      expect(presenter.initializeCalls, 0);
      expect(gateway.registered, isEmpty);
    });

    test('requests permission and registers the current FCM token', () async {
      final messaging = _FakeMessagingClient(token: 'token_1');
      final presenter = _FakeForegroundPresenter();
      final gateway = _FakeTokenGateway();
      final coordinator = _buildCoordinator(
        messaging: messaging,
        presenter: presenter,
        gateway: gateway,
      );

      await coordinator.updateRegistrationContext(context);
      await coordinator.start();

      expect(messaging.permissionRequests, 1);
      expect(presenter.initializeCalls, 1);
      expect(presenter.permissionRequests, 1);
      expect(gateway.registered, hasLength(1));
      expect(gateway.registered.single.token, 'token_1');
      expect(gateway.registered.single.platform, 'android');
      expect(gateway.registered.single.context, context);
      expect(gateway.registered.single.appVariant, 'forgeflow');
      expect(gateway.registered.single.appEnvironment, 'staging');
      expect(gateway.registered.single.installationId, 'install_1');
    });

    test(
      'updates the backend registration when FCM refreshes the token',
      () async {
        final messaging = _FakeMessagingClient(token: 'token_1');
        final presenter = _FakeForegroundPresenter();
        final gateway = _FakeTokenGateway();
        final coordinator = _buildCoordinator(
          messaging: messaging,
          presenter: presenter,
          gateway: gateway,
        );

        await coordinator.updateRegistrationContext(context);
        await coordinator.start();
        messaging.emitTokenRefresh('token_2');
        await _drainMicrotasks();

        expect(gateway.updates, hasLength(1));
        expect(gateway.updates.single.previousToken, 'token_1');
        expect(gateway.updates.single.registration.token, 'token_2');
        expect(gateway.updates.single.registration.context, context);
      },
    );

    test(
      'resume revalidation rereads FCM and updates a changed token',
      () async {
        final messaging = _FakeMessagingClient(token: 'token_1');
        final presenter = _FakeForegroundPresenter();
        final gateway = _FakeTokenGateway();
        final coordinator = _buildCoordinator(
          messaging: messaging,
          presenter: presenter,
          gateway: gateway,
        );

        await coordinator.updateRegistrationContext(context);
        await coordinator.start();
        messaging.token = 'token_2';

        await coordinator.reValidateToken();

        expect(messaging.tokenReads, 2);
        expect(gateway.updates, hasLength(1));
        expect(gateway.updates.single.previousToken, 'token_1');
        expect(gateway.updates.single.registration.token, 'token_2');
        expect(gateway.updates.single.registration.context, context);
      },
    );

    test('deletes the registered token on sign-out', () async {
      final messaging = _FakeMessagingClient(token: 'token_1');
      final presenter = _FakeForegroundPresenter();
      final gateway = _FakeTokenGateway();
      final coordinator = _buildCoordinator(
        messaging: messaging,
        presenter: presenter,
        gateway: gateway,
      );

      await coordinator.updateRegistrationContext(context);
      await coordinator.start();
      await coordinator.updateRegistrationContext(null);

      expect(gateway.deleted, hasLength(1));
      expect(gateway.deleted.single.token, 'token_1');
      expect(gateway.deleted.single.context, context);
    });

    test('moves the token when the authenticated context changes', () async {
      final messaging = _FakeMessagingClient(token: 'token_1');
      final presenter = _FakeForegroundPresenter();
      final gateway = _FakeTokenGateway();
      final coordinator = _buildCoordinator(
        messaging: messaging,
        presenter: presenter,
        gateway: gateway,
      );

      await coordinator.updateRegistrationContext(context);
      await coordinator.start();
      await coordinator.updateRegistrationContext(otherContext);

      expect(gateway.deleted, hasLength(1));
      expect(gateway.deleted.single.context, context);
      expect(gateway.registered, hasLength(2));
      expect(gateway.registered.last.context, otherContext);
    });

    test('shows a foreground local notification from FCM content', () async {
      final messaging = _FakeMessagingClient(token: 'token_1');
      final presenter = _FakeForegroundPresenter();
      final gateway = _FakeTokenGateway();
      final coordinator = _buildCoordinator(
        messaging: messaging,
        presenter: presenter,
        gateway: gateway,
      );

      await coordinator.start();
      messaging.emitForeground(
        const MobilePushRemoteMessage(
          messageId: 'message_1',
          title: 'Target Cycle Refreshed',
          body: 'A new 60-day target cycle is now active.',
          data: <String, String>{'notification_id': 'notification_1'},
        ),
      );
      await _drainMicrotasks();

      expect(presenter.shown, hasLength(1));
      expect(presenter.shown.single.title, 'Target Cycle Refreshed');
      expect(
        presenter.shown.single.body,
        'A new 60-day target cycle is now active.',
      );
      expect(presenter.shown.single.payload, 'notification_1');
    });

    test(
      'routes opened and initially-opened pushes to Notifications',
      () async {
        final messaging = _FakeMessagingClient(
          token: 'token_1',
          initialMessage: const MobilePushRemoteMessage(
            data: <String, String>{'notification_id': 'from_initial'},
          ),
        );
        final presenter = _FakeForegroundPresenter();
        final gateway = _FakeTokenGateway();
        // Inject the in-memory disk store so the coordinator's
        // initial-message persist/drain path does not hit
        // SharedPreferences (no plugin registered in the unit-test loop;
        // the production store keeps SharedPreferences for mobile boot).
        final routeIntents = MobilePushRouteIntentController(
          diskStore: InMemoryMobilePushIntentStore(),
        );
        final coordinator = _buildCoordinator(
          messaging: messaging,
          presenter: presenter,
          gateway: gateway,
          routeIntents: routeIntents,
        );

        await coordinator.start();

        final pending = routeIntents.takePendingIntents();
        expect(pending, hasLength(1));
        expect(
          pending.single.destination,
          MobilePushRouteDestination.notifications,
        );
        expect(pending.single.notificationId, 'from_initial');

        // Drain the fire-and-forget disk async re-publish from
        // takePendingIntents BEFORE subscribing, so the broadcast
        // stream only carries the genuinely-new "from_opened" intent
        // emitted below. (Production behavior is unchanged; the test
        // just exercises the no-listener cold-start drop semantics.)
        await _drainMicrotasks();

        final streamed = <MobilePushRouteIntent>[];
        final subscription = routeIntents.intents.listen(streamed.add);
        messaging.emitOpened(
          const MobilePushRemoteMessage(
            data: <String, String>{'notification_id': 'from_opened'},
          ),
        );
        await _drainMicrotasks();
        await subscription.cancel();

        expect(streamed, hasLength(1));
        expect(streamed.single.notificationId, 'from_opened');
        expect(routeIntents.takePendingIntents(), isEmpty);
      },
    );
  });
}

MobilePushNotificationCoordinator _buildCoordinator({
  MobilePushRuntimeEnvironment environment = const MobilePushRuntimeEnvironment(
    isMobile: true,
    platform: 'android',
  ),
  required _FakeMessagingClient messaging,
  required _FakeForegroundPresenter presenter,
  required _FakeTokenGateway gateway,
  MobilePushRouteIntentController? routeIntents,
}) {
  return MobilePushNotificationCoordinator(
    environment: environment,
    messaging: messaging,
    foregroundNotifications: presenter,
    tokenGateway: gateway,
    routeIntents: routeIntents ?? MobilePushRouteIntentController(),
    installationIdStore: const StaticMobilePushInstallationIdStore('install_1'),
    appVariant: 'forgeflow',
    appEnvironment: 'staging',
  );
}

Future<void> _drainMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeMessagingClient implements MobilePushMessagingClient {
  _FakeMessagingClient({this.token, this.initialMessage});

  String? token;
  final MobilePushRemoteMessage? initialMessage;
  final StreamController<MobilePushRemoteMessage> _foreground =
      StreamController<MobilePushRemoteMessage>.broadcast();
  final StreamController<MobilePushRemoteMessage> _opened =
      StreamController<MobilePushRemoteMessage>.broadcast();
  final StreamController<String> _tokenRefresh =
      StreamController<String>.broadcast();
  int permissionRequests = 0;
  int tokenReads = 0;

  @override
  Stream<MobilePushRemoteMessage> get foregroundMessages => _foreground.stream;

  @override
  Stream<MobilePushRemoteMessage> get openedMessages => _opened.stream;

  @override
  Stream<String> get tokenRefreshes => _tokenRefresh.stream;

  @override
  Future<MobilePushRemoteMessage?> getInitialMessage() async => initialMessage;

  @override
  Future<String?> getToken() async {
    tokenReads += 1;
    return token;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    return true;
  }

  void emitForeground(MobilePushRemoteMessage message) {
    _foreground.add(message);
  }

  void emitOpened(MobilePushRemoteMessage message) {
    _opened.add(message);
  }

  void emitTokenRefresh(String token) {
    _tokenRefresh.add(token);
  }
}

class _FakeForegroundPresenter implements ForegroundNotificationPresenter {
  int initializeCalls = 0;
  int permissionRequests = 0;
  void Function()? notificationTap;
  final List<MobilePushLocalNotification> shown =
      <MobilePushLocalNotification>[];

  @override
  Future<void> initialize({required void Function() onNotificationTap}) async {
    initializeCalls += 1;
    notificationTap = onNotificationTap;
  }

  @override
  Future<void> requestPermission() async {
    permissionRequests += 1;
  }

  @override
  Future<void> show(MobilePushLocalNotification notification) async {
    shown.add(notification);
  }
}

class _TokenUpdateRecord {
  const _TokenUpdateRecord({
    required this.previousToken,
    required this.registration,
  });

  final String previousToken;
  final MobilePushTokenRegistration registration;
}

class _FakeTokenGateway implements MobilePushTokenGateway {
  final List<MobilePushTokenRegistration> registered =
      <MobilePushTokenRegistration>[];
  final List<_TokenUpdateRecord> updates = <_TokenUpdateRecord>[];
  final List<MobilePushTokenDeletion> deleted = <MobilePushTokenDeletion>[];

  @override
  Future<void> registerToken(MobilePushTokenRegistration registration) async {
    registered.add(registration);
  }

  @override
  Future<void> updateToken({
    required String previousToken,
    required MobilePushTokenRegistration registration,
  }) async {
    updates.add(
      _TokenUpdateRecord(
        previousToken: previousToken,
        registration: registration,
      ),
    );
  }

  @override
  Future<void> deleteToken(MobilePushTokenDeletion deletion) async {
    deleted.add(deletion);
  }
}
