// Lane B B11.2 — RFC 9470 step-up challenge tests.
//
// Pins the contract for:
//
//   * the sensitive-route registry (lookupStepUpRoute matcher)
//   * the policy classifier (StepUpPolicy.evaluate)
//   * the WWW-Authenticate header shape (buildWwwAuthenticateHeader)
//   * the dispatch router (StepUpChallengeRouter.dispatch):
//       - emits 401 + 9470 challenge when auth_time stale
//       - emits 401 + 9470 challenge when auth_time missing
//       - admits when auth_time fresh
//       - admits when actor is service principal (V1 skip)
//       - admits when not a sensitive route
//       - replays: presented challenge_id + still-stale auth_time +
//                  successful consume -> admit
//       - replay protection: consumed challenge_id -> 410
//       - cross-operator isolation: challenge from op-1 cannot be
//                  replayed by op-2
//       - route-path binding: challenge from /v1/auth/password/change
//                  cannot be replayed against an admin role mutation
//
// Authority:
//   * tool/advisor_proxy/auth_step_up_routes.dart (the file under
//     test)
//   * RFC 9470 (the wire shape)
//   * docs/archive/_execution/lane_b_features/03_execution_slices.md
//     ("B11.2 — RFC 9470 step-up challenge on sensitive routes")

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/auth_step_up_routes.dart';

const String _opA = 'op-1';
const String _opB = 'op-2';
const String _locA = 'loc-1';
const String _userA = 'user-1';
const String _userB = 'user-2';

void main() {
  group('lookupStepUpRoute', () {
    test('matches an exact-path registry entry', () {
      final spec = lookupStepUpRoute(
        method: 'POST',
        path: '/v1/auth/password/change',
      );
      expect(spec, isNotNull);
      expect(spec!.path, '/v1/auth/password/change');
      expect(spec.acr, kStepUpDefaultAcr);
      expect(spec.maxAge, kStepUpDefaultFreshness);
    });

    test('matches a prefix-path registry entry', () {
      final spec = lookupStepUpRoute(
        method: 'PATCH',
        path: '/v1/admin/auth/roles/role-uuid-123',
      );
      expect(spec, isNotNull);
      expect(spec!.isPrefix, isTrue);
      expect(spec.path, '/v1/admin/auth/roles/');
    });

    test('does not match a different method on the same path', () {
      // POST /v1/admin/auth/roles is sensitive, but a GET on the same
      // path is read-only and not flagged.
      final spec = lookupStepUpRoute(
        method: 'GET',
        path: '/v1/admin/auth/roles',
      );
      expect(spec, isNull);
    });

    test('returns null for an unflagged route', () {
      final spec = lookupStepUpRoute(
        method: 'GET',
        path: '/v1/operator/account',
      );
      expect(spec, isNull);
    });

    test('matches every distinct sensitive surface listed in the slice doc',
        () {
      // Sanity check that the V1 registry covers the four surfaces
      // the slice doc enumerates: account edits, password change,
      // MFA enroll, role mutations, billing, vendor applicability.
      // Picks one canonical path per surface.
      final probes = <(String, String)>[
        ('PATCH', '/v1/operator/account'),
        ('POST', '/v1/auth/password/change'),
        ('POST', '/v1/auth/mfa/totp/begin'),
        ('POST', '/v1/admin/auth/roles'),
        ('PATCH', '/v1/admin/auth/roles/abc'),
        ('POST', '/v1/auth/team/role-grants'),
        ('PATCH', '/v1/admin/pricing/operators/op-1'),
        ('PATCH', '/v1/admin/pricing/usage-caps'),
        ('POST', '/v1/admin/vendor-applicability/wage'),
      ];
      for (final probe in probes) {
        final spec =
            lookupStepUpRoute(method: probe.$1, path: probe.$2);
        expect(
          spec,
          isNotNull,
          reason: '${probe.$1} ${probe.$2} should be flagged sensitive',
        );
      }
    });
  });

  group('StepUpPolicy.evaluate', () {
    const policy = StepUpPolicy();
    final now = DateTime.utc(2026, 5, 13, 14, 0);
    final spec = StepUpRouteSpec(
      method: 'POST',
      path: '/v1/auth/password/change',
      isPrefix: false,
      acr: kStepUpDefaultAcr,
      maxAge: kStepUpDefaultFreshness,
      challengeTtl: kStepUpDefaultChallengeTtl,
      label: 'pw',
    );

    test('returns NotSensitive when spec is null', () {
      final out = policy.evaluate(
        spec: null,
        authTime: now,
        actorKind: 'user',
        now: now,
      );
      expect(out, isA<StepUpRequirementNotSensitive>());
    });

    test('returns SkipServicePrincipal for service_principal actor_kind', () {
      final out = policy.evaluate(
        spec: spec,
        authTime: null,
        actorKind: 'service_principal',
        now: now,
      );
      expect(out, isA<StepUpRequirementSkipServicePrincipal>());
    });

    test('returns SkipServicePrincipal for sp:-prefixed actor_kind', () {
      final out = policy.evaluate(
        spec: spec,
        authTime: null,
        actorKind: 'sp:integration_oauth',
        now: now,
      );
      expect(out, isA<StepUpRequirementSkipServicePrincipal>());
    });

    test('returns ChallengeNeeded(missing_auth_time) when auth_time is null',
        () {
      final out = policy.evaluate(
        spec: spec,
        authTime: null,
        actorKind: 'user',
        now: now,
      );
      expect(out, isA<StepUpRequirementChallengeNeeded>());
      final needed = out as StepUpRequirementChallengeNeeded;
      expect(needed.reason, 'missing_auth_time');
    });

    test('returns FreshEnough when auth_time is inside the freshness window',
        () {
      final out = policy.evaluate(
        spec: spec,
        // 60 seconds ago (well inside the 5-minute window).
        authTime: now.subtract(const Duration(seconds: 60)),
        actorKind: 'user',
        now: now,
      );
      expect(out, isA<StepUpRequirementFreshEnough>());
    });

    test('returns ChallengeNeeded(auth_time_stale) when auth_time is older '
        'than the window', () {
      final out = policy.evaluate(
        spec: spec,
        // 6 minutes ago (1 minute past the 5-minute window).
        authTime: now.subtract(const Duration(minutes: 6)),
        actorKind: 'user',
        now: now,
      );
      expect(out, isA<StepUpRequirementChallengeNeeded>());
      final needed = out as StepUpRequirementChallengeNeeded;
      expect(needed.reason, 'auth_time_stale');
    });

    test('treats auth_time exactly at the boundary as fresh', () {
      final out = policy.evaluate(
        spec: spec,
        authTime: now.subtract(spec.maxAge),
        actorKind: 'user',
        now: now,
      );
      expect(out, isA<StepUpRequirementFreshEnough>());
    });
  });

  group('buildWwwAuthenticateHeader', () {
    test('formats the standard 9470 challenge value', () {
      final header = buildWwwAuthenticateHeader(
        acr: 'urn:mfa',
        maxAge: const Duration(seconds: 300),
        label: 'Changing your password requires a fresh sign-in.',
      );
      // RFC 9470: Bearer + comma-separated params; quoted strings for
      // strings, bare numeric for max_age.
      expect(header, startsWith('Bearer '));
      expect(
        header,
        contains('error="insufficient_user_authentication"'),
      );
      expect(header, contains('acr_values="urn:mfa"'));
      expect(header, contains('max_age=300'));
      expect(
        header,
        contains(
          'error_description="Changing your password requires a fresh '
          'sign-in."',
        ),
      );
      // No trailing whitespace, no leading whitespace inside Bearer
      // params.
      expect(header.trim(), header);
    });

    test('escapes quotes + backslashes in the label', () {
      final header = buildWwwAuthenticateHeader(
        acr: 'urn:mfa',
        maxAge: const Duration(seconds: 300),
        label: r'a "quoted" \value',
      );
      expect(header, contains(r'error_description="a \"quoted\" \\value"'));
    });
  });

  group('StepUpChallengeRouter.dispatch', () {
    final now = DateTime.utc(2026, 5, 13, 14, 0);

    StepUpChallengeRouter buildRouter({
      _FakeStepUpGateway? gateway,
      _RecordingStepUpAuditSink? auditSink,
    }) {
      return StepUpChallengeRouter(
        gateway: gateway ?? _FakeStepUpGateway(),
        auditSink: auditSink ?? _RecordingStepUpAuditSink(),
      );
    }

    test('admits an unflagged route without touching the gateway', () async {
      final gateway = _FakeStepUpGateway();
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'GET',
        path: '/v1/operator/account',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: null,
        presentedChallengeId: null,
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchAdmit>());
      expect(gateway.emitCalls, isEmpty);
      expect(gateway.consumeCalls, isEmpty);
    });

    test('admits a sensitive route when actor is a service principal', () async {
      final gateway = _FakeStepUpGateway();
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'service_principal',
        authTime: null,
        presentedChallengeId: null,
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchAdmit>());
      expect(gateway.emitCalls, isEmpty);
    });

    test('admits a sensitive route when auth_time is fresh', () async {
      final gateway = _FakeStepUpGateway();
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: now.subtract(const Duration(seconds: 60)),
        presentedChallengeId: null,
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchAdmit>());
      expect(gateway.emitCalls, isEmpty);
    });

    test(
        'emits 401 + RFC 9470 challenge when auth_time is stale and no '
        'replay header is present', () async {
      final gateway = _FakeStepUpGateway(
        emitReturning: 'CHALLENGE_AAAA_BBBB_CCCC',
      );
      final auditSink = _RecordingStepUpAuditSink();
      final router = buildRouter(gateway: gateway, auditSink: auditSink);

      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: null,
        sourceDeviceFingerprint: 'fp-1',
        now: () => now,
      );

      expect(result, isA<StepUpDispatchChallenge>());
      final challenge = result as StepUpDispatchChallenge;
      expect(challenge.statusCode, 401);
      expect(
        challenge.headers[kStepUpWwwAuthenticateHeader],
        contains('error="insufficient_user_authentication"'),
      );
      expect(
        challenge.headers[kStepUpWwwAuthenticateHeader],
        contains('acr_values="urn:mfa"'),
      );
      expect(
        challenge.headers[kStepUpWwwAuthenticateHeader],
        contains('max_age=300'),
      );

      // Body carries the operator-friendly message + the challenge id
      // so the client can replay.
      expect(challenge.body['error'], kStepUpErrorCode);
      expect(challenge.body['challenge_id'], 'CHALLENGE_AAAA_BBBB_CCCC');
      expect(challenge.body['required_acr'], 'urn:mfa');
      expect(challenge.body['max_age_seconds'], 300);
      expect(challenge.body['challenge_expires_in_seconds'], 300);
      expect(challenge.body['reason'], 'auth_time_stale');

      // Gateway saw exactly one emit.
      expect(gateway.emitCalls, hasLength(1));
      expect(gateway.emitCalls.single.operatorId, _opA);
      expect(gateway.emitCalls.single.userId, _userA);
      expect(gateway.emitCalls.single.routePath, '/v1/auth/password/change');
      expect(gateway.emitCalls.single.requiredAcr, 'urn:mfa');
      expect(gateway.emitCalls.single.requiredFreshnessSeconds, 300);
      expect(
        gateway.emitCalls.single.sourceDeviceFingerprint,
        'fp-1',
      );

      // Audit sink saw exactly one challenge_emitted event.
      expect(auditSink.emitted, hasLength(1));
      expect(
        auditSink.emitted.single.challengeId,
        'CHALLENGE_AAAA_BBBB_CCCC',
      );
      expect(auditSink.emitted.single.reason, 'auth_time_stale');
      expect(auditSink.consumed, isEmpty);
    });

    test('emits a fresh challenge when auth_time is missing entirely',
        () async {
      final gateway = _FakeStepUpGateway(emitReturning: 'CID_MISSING');
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: null,
        presentedChallengeId: null,
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchChallenge>());
      final challenge = result as StepUpDispatchChallenge;
      expect(challenge.body['reason'], 'missing_auth_time');
      expect(challenge.body['challenge_id'], 'CID_MISSING');
    });

    test('admits when a presented challenge_id consumes successfully', () async {
      final consumedAt = now.add(const Duration(seconds: 30));
      final gateway = _FakeStepUpGateway(
        consumeReturning: StepUpChallengeConsumed(
          challengeId: 'CID_REPLAYED',
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          requiredAcr: 'urn:mfa',
          requiredFreshnessSeconds: 300,
          consumedAt: consumedAt,
        ),
      );
      final auditSink = _RecordingStepUpAuditSink();
      final router = buildRouter(gateway: gateway, auditSink: auditSink);

      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        // Still stale — but the presented id should win.
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: 'CID_REPLAYED',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchAdmit>());
      expect(gateway.emitCalls, isEmpty);
      expect(gateway.consumeCalls, hasLength(1));
      expect(auditSink.consumed, hasLength(1));
      expect(auditSink.consumed.single.challengeId, 'CID_REPLAYED');
    });

    test(
        'replay protection: presenting a CONSUMED challenge_id returns 410',
        () async {
      final gateway = _FakeStepUpGateway(
        consumeReturning: null,
        replayState: StepUpChallengeState(
          operatorId: _opA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          expiresAt: now.add(const Duration(minutes: 4)),
          // Consumed earlier.
          consumedAt: now.subtract(const Duration(minutes: 1)),
        ),
      );
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: 'CID_REPLAY',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchReject>());
      final reject = result as StepUpDispatchReject;
      expect(reject.statusCode, 410);
      expect(reject.body['error'], 'step_up_challenge_already_consumed');
    });

    test(
        'cross-operator isolation: challenge minted in op-2 cannot be '
        'replayed by op-1', () async {
      // Predicate fails (op mismatch) -> consume returns null.
      // lookupForReplayCheck returns the cross-tenant snapshot but its
      // operatorId != caller.operatorId so the classifier emits 401
      // (oracle-safe; no information leak about cross-operator
      // existence).
      final gateway = _FakeStepUpGateway(
        consumeReturning: null,
        replayState: StepUpChallengeState(
          operatorId: _opB,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          expiresAt: now.add(const Duration(minutes: 4)),
          consumedAt: null,
        ),
      );
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: 'CID_CROSS_TENANT',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchReject>());
      final reject = result as StepUpDispatchReject;
      expect(reject.statusCode, 401);
      expect(reject.body['error'], kStepUpErrorCode);
    });

    test(
        'route-binding: challenge minted for /password/change cannot be '
        'replayed against an admin role mutation', () async {
      // The Postgres consume predicate would reject this (route_path
      // mismatch); we simulate by returning null from consume and
      // having lookupForReplayCheck return the original-route state.
      // The classifier sees consumedAt is null and routePath !=
      // caller's route path, so it falls through to the 401 branch.
      final gateway = _FakeStepUpGateway(
        consumeReturning: null,
        replayState: StepUpChallengeState(
          operatorId: _opA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          expiresAt: now.add(const Duration(minutes: 4)),
          consumedAt: null,
        ),
      );
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/admin/auth/roles',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: 'CID_WRONG_ROUTE',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchReject>());
      final reject = result as StepUpDispatchReject;
      expect(reject.statusCode, 401);
      expect(reject.body['error'], kStepUpErrorCode);
    });

    test('user-binding: challenge minted for user-A cannot be replayed '
        'by user-B', () async {
      final gateway = _FakeStepUpGateway(
        consumeReturning: null,
        replayState: StepUpChallengeState(
          operatorId: _opA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          expiresAt: now.add(const Duration(minutes: 4)),
          consumedAt: null,
        ),
      );
      final router = buildRouter(gateway: gateway);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        // Different user!
        userId: _userB,
        actorKind: 'user',
        authTime: now.subtract(const Duration(minutes: 10)),
        presentedChallengeId: 'CID_WRONG_USER',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchReject>());
      final reject = result as StepUpDispatchReject;
      expect(reject.statusCode, 401);
    });

    test(
        'fresh caller that nonetheless presents a challenge_id has it '
        'consumed best-effort (defense-in-depth) and is admitted',
        () async {
      final consumedAt = now.add(const Duration(seconds: 5));
      final gateway = _FakeStepUpGateway(
        consumeReturning: StepUpChallengeConsumed(
          challengeId: 'CID_DEFENSE',
          operatorId: _opA,
          locationId: _locA,
          userId: _userA,
          routePath: '/v1/auth/password/change',
          requiredAcr: 'urn:mfa',
          requiredFreshnessSeconds: 300,
          consumedAt: consumedAt,
        ),
      );
      final auditSink = _RecordingStepUpAuditSink();
      final router = buildRouter(gateway: gateway, auditSink: auditSink);
      final result = await router.dispatch(
        method: 'POST',
        path: '/v1/auth/password/change',
        operatorId: _opA,
        locationId: _locA,
        userId: _userA,
        actorKind: 'user',
        // Fresh.
        authTime: now.subtract(const Duration(seconds: 30)),
        presentedChallengeId: 'CID_DEFENSE',
        sourceDeviceFingerprint: null,
        now: () => now,
      );
      expect(result, isA<StepUpDispatchAdmit>());
      // Best-effort consume happened.
      expect(gateway.consumeCalls, hasLength(1));
      // Audit row emitted for the consume.
      expect(auditSink.consumed, hasLength(1));
    });

    test('isSensitive helper agrees with lookupStepUpRoute', () {
      final router = buildRouter();
      expect(
        router.isSensitive(
          method: 'POST',
          path: '/v1/auth/password/change',
        ),
        isTrue,
      );
      expect(
        router.isSensitive(method: 'GET', path: '/v1/operator/account'),
        isFalse,
      );
    });
  });

  group('hashStepUpChallengeIdForAudit', () {
    test('hashes deterministically', () {
      final a = hashStepUpChallengeIdForAudit('CID_FOO');
      final b = hashStepUpChallengeIdForAudit('CID_FOO');
      final c = hashStepUpChallengeIdForAudit('CID_BAR');
      expect(a, b);
      expect(a, isNot(c));
      // SHA-256 hex is 64 chars.
      expect(a.length, 64);
    });
  });
}

// ─── fakes ──────────────────────────────────────────────────────────

class _EmitCall {
  const _EmitCall({
    required this.operatorId,
    required this.userId,
    required this.routePath,
    required this.requiredAcr,
    required this.requiredFreshnessSeconds,
    required this.sourceDeviceFingerprint,
  });

  final String operatorId;
  final String userId;
  final String routePath;
  final String requiredAcr;
  final int requiredFreshnessSeconds;
  final String? sourceDeviceFingerprint;
}

class _ConsumeCall {
  const _ConsumeCall({
    required this.callerOperatorId,
    required this.callerUserId,
    required this.callerRoutePath,
    required this.challengeId,
  });

  final String callerOperatorId;
  final String callerUserId;
  final String callerRoutePath;
  final String challengeId;
}

class _FakeStepUpGateway implements StepUpChallengesGateway {
  _FakeStepUpGateway({
    this.emitReturning = 'DEFAULT_TEST_CID',
    this.consumeReturning,
    this.replayState,
  });

  final String emitReturning;
  final StepUpChallengeConsumed? consumeReturning;
  final StepUpChallengeState? replayState;

  final List<_EmitCall> emitCalls = <_EmitCall>[];
  final List<_ConsumeCall> consumeCalls = <_ConsumeCall>[];
  final List<String> replayCheckCalls = <String>[];

  @override
  Future<String> emit({
    required String operatorId,
    required String locationId,
    required String userId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required Duration challengeTtl,
    required String sourceActorKind,
    required String? sourceDeviceFingerprint,
  }) async {
    emitCalls.add(_EmitCall(
      operatorId: operatorId,
      userId: userId,
      routePath: routePath,
      requiredAcr: requiredAcr,
      requiredFreshnessSeconds: requiredFreshnessSeconds,
      sourceDeviceFingerprint: sourceDeviceFingerprint,
    ));
    return emitReturning;
  }

  @override
  Future<StepUpChallengeConsumed?> consume({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String callerRoutePath,
    required String challengeId,
  }) async {
    consumeCalls.add(_ConsumeCall(
      callerOperatorId: callerOperatorId,
      callerUserId: callerUserId,
      callerRoutePath: callerRoutePath,
      challengeId: challengeId,
    ));
    return consumeReturning;
  }

  @override
  Future<StepUpChallengeState?> lookupForReplayCheck({
    required String callerOperatorId,
    required String challengeId,
  }) async {
    replayCheckCalls.add(challengeId);
    return replayState;
  }
}

class _RecordedEmitted {
  const _RecordedEmitted({
    required this.challengeId,
    required this.reason,
    required this.routePath,
  });

  final String challengeId;
  final String reason;
  final String routePath;
}

class _RecordedConsumed {
  const _RecordedConsumed({
    required this.challengeId,
    required this.routePath,
  });

  final String challengeId;
  final String routePath;
}

class _RecordingStepUpAuditSink implements StepUpAuditSink {
  final List<_RecordedEmitted> emitted = <_RecordedEmitted>[];
  final List<_RecordedConsumed> consumed = <_RecordedConsumed>[];

  @override
  Future<void> recordChallengeEmitted({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String actorKind,
    required String challengeId,
    required String routePath,
    required String requiredAcr,
    required int requiredFreshnessSeconds,
    required String reason,
    required DateTime occurredAt,
  }) async {
    emitted.add(_RecordedEmitted(
      challengeId: challengeId,
      reason: reason,
      routePath: routePath,
    ));
  }

  @override
  Future<void> recordChallengeConsumed({
    required StepUpChallengeConsumed row,
    required DateTime occurredAt,
  }) async {
    consumed.add(_RecordedConsumed(
      challengeId: row.challengeId,
      routePath: row.routePath,
    ));
  }
}
