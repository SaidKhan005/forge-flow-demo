// ops-debt.mobile-push-gating — guard: production phones must NEVER POST
// to `/v1/auth/mobile/push-token/register` until both
//
//   1. `db/migrations/202605060000_mobile_push_notifications.sql` has
//      been applied to the active Postgres environment, AND
//   2. ops has flipped `MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` on the
//      proxy + ForgeFlow Cloud Run revisions and the mobile build was
//      re-cut with the matching `--dart-define`.
//
// The pre-fix wiring at `firebase_auth_runtime_bindings.dart:183-187`
// unconditionally constructed a [ProxyMobilePushTokenGateway] when
// `proxyBaseUri != null`, so a production phone shipped before the
// migration would 500 the proxy on first FCM token register. These
// tests pin the gated factory's two branches so the regression cannot
// silently come back.
//
// The factory is exercised directly (not the full
// `createFirebaseAuthRuntimeBindings`) because the latter calls
// `Firebase.initializeApp` + `WidgetsFlutterBinding.ensureInitialized`,
// which are not unit-test seams.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_runtime_bindings.dart';
import 'package:forge_and_flow/services/mobile_push/mobile_push_notification_service.dart';

Future<String?> _stubIdToken() async => 'firebase-id-token';

void main() {
  final proxyBaseUri = Uri.parse('https://forge-flow-proxy.example.com');

  group('buildMobilePushTokenGateway', () {
    test(
      'returns NoopMobilePushTokenGateway when MOBILE_PUSH_NOTIFICATIONS_ENABLED=false',
      () {
        final logged = <String>[];

        final gateway = buildMobilePushTokenGateway(
          proxyBaseUri: proxyBaseUri,
          idTokenProvider: _stubIdToken,
          enabled: false,
          logger: logged.add,
        );

        expect(
          gateway,
          isA<NoopMobilePushTokenGateway>(),
          reason:
              'Flag off -> client must use the no-op gateway so token '
              'registration POSTs never reach the proxy.',
        );
        expect(
          gateway,
          isNot(isA<ProxyMobilePushTokenGateway>()),
          reason:
              'Regression guard for unconditional ProxyMobilePushTokenGateway '
              'wiring at firebase_auth_runtime_bindings.dart:183-187.',
        );
        expect(
          logged,
          equals(<String>['mobile_push: feature disabled, tokens not persisted']),
          reason:
              'Disabled path must emit a single startup line so ops can '
              'confirm the gate is closed in Cloud Run logs.',
        );
      },
    );

    test(
      'no-op gateway silently succeeds on registerToken / updateToken / deleteToken',
      () async {
        final gateway = buildMobilePushTokenGateway(
          proxyBaseUri: proxyBaseUri,
          idTokenProvider: _stubIdToken,
          enabled: false,
          logger: (_) {},
        )!;

        const registration = MobilePushTokenRegistration(
          token: 'fcm-token-1',
          platform: 'android',
          context: MobilePushRegistrationContext(
            userId: 'user-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
          ),
          appVariant: 'forgeflow',
          appEnvironment: 'production',
          installationId: 'install-1',
        );

        // Each call must complete without throwing and without any
        // network side effects (the no-op never references an HTTP
        // client). If this ever throws, mobile clients would surface
        // the failure to operators while the migration is still in
        // flight — defeating the whole point of the gate.
        await gateway.registerToken(registration);
        await gateway.updateToken(
          previousToken: 'fcm-token-0',
          registration: registration,
        );
        await gateway.deleteToken(
          const MobilePushTokenDeletion(
            token: 'fcm-token-1',
            platform: 'android',
            context: MobilePushRegistrationContext(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
            ),
            appVariant: 'forgeflow',
            appEnvironment: 'production',
            installationId: 'install-1',
          ),
        );
      },
    );

    test(
      'returns ProxyMobilePushTokenGateway when MOBILE_PUSH_NOTIFICATIONS_ENABLED=true and proxy is wired',
      () {
        final logged = <String>[];

        final gateway = buildMobilePushTokenGateway(
          proxyBaseUri: proxyBaseUri,
          idTokenProvider: _stubIdToken,
          enabled: true,
          logger: logged.add,
        );

        expect(
          gateway,
          isA<ProxyMobilePushTokenGateway>(),
          reason:
              'Flag on + proxy URI -> production gateway lights up so token '
              'register POSTs reach `/v1/auth/mobile/push-token/register`.',
        );
        expect(
          logged,
          isEmpty,
          reason:
              'Enabled path must not emit the disabled-startup line; that '
              'line is the signal the gate is closed.',
        );
      },
    );

    test(
      'returns null when enabled but proxy is not wired (demo build)',
      () {
        final gateway = buildMobilePushTokenGateway(
          proxyBaseUri: null,
          idTokenProvider: _stubIdToken,
          enabled: true,
        );

        expect(
          gateway,
          isNull,
          reason:
              'Demo builds (no proxy) keep the pre-flag null behavior so '
              'the coordinator falls back to its internal no-op default.',
        );
      },
    );
  });
}
