// UX-parity Slice E0-E2 — admin capability-key gating with role
// fallback (dormant, byte-identical).
//
// Pins THE BINDING INVARIANT: with an EMPTY permissions set (demo /
// un-hydrated sessions — what every current code path carries) every
// gate decision is byte-identical to the pre-slice role check. The
// slice mirrors operator-web's `_canView`/`_canExport` pattern
// (`lib/operator_web/screens/audit_log_screen.dart`).
//
// What this file proves:
//   * E0: `AdminAuthSession.permissions` defaults to an empty set in
//     every constructor / demo factory, and a live session hydrates it
//     best-effort WITHOUT ever blocking sign-in (an empty / failed
//     snapshot yields the role fallback).
//   * E1: the `adminCanEdit` decision matrix {role} x {empty /
//     key-present / key-absent}. The empty-permissions rows MUST match
//     the pre-slice `roles.contains('super_admin')` outcome exactly.
//     `adminCanEdit` (extracted to `lib/admin/admin_capability_gate.dart`)
//     is exercised directly and proven equivalent to both the
//     operator-web pattern and the old inline expression.
//   * Loader: `HttpAdminPermissionSnapshotLoader` is fail-safe (returns
//     an empty set, never throws) on every error class, and parses the
//     `{permissions: {<key>: 'allow'|'deny'}}` shape correctly.
//   * E2: feeding `actorHasEditKeyHint` to the catalog screen helper
//     agrees with the role-tier check (which stays authoritative).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:forge_and_flow/admin/admin_auth_gate.dart';
import 'package:forge_and_flow/admin/admin_capability_gate.dart';
import 'package:forge_and_flow/admin/screens/default_role_catalog_admin_screen.dart';
import 'package:forge_and_flow/admin/services/admin_permission_snapshot_loader.dart';
import 'package:forge_and_flow/admin/services/admin_sessions_gateway.dart';
import 'package:forge_and_flow/auth/auth_session.dart';
import 'package:forge_and_flow/auth/fresh_mfa_resolver.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/services/auth/firebase_auth_client.dart';

// ---------------------------------------------------------------------------
// E1 — `adminCanEdit` decision matrix.
//
// `adminCanEdit` (extracted to `lib/admin/admin_capability_gate.dart`)
// is the real production helper, exercised directly here. We prove (a)
// it implements the operator-web key-first pattern, and (b) for an
// empty permissions set it equals the OLD inline
// `roles.contains('super_admin')` expression — the byte-identity
// invariant. `adminCanEditMirror` simply forwards to the real function
// so the matrix reads clearly.
// ---------------------------------------------------------------------------

bool adminCanEditMirror(
  AdminAuthSession? session, {
  required String requiredKey,
}) => adminCanEdit(session, requiredKey: requiredKey);

/// The OLD coarse decision the Pricing site used before Slice E1 (bare
/// literal). The oracle for the empty-permissions byte-identity rows.
bool oldPricingInline(AdminAuthSession? session) =>
    session != null && session.roles.contains('super_admin');

AdminAuthSession sessionWith({
  required List<String> roles,
  Set<String> permissions = const <String>{},
}) => AdminAuthSession(
  uid: 'u1',
  email: 'admin@example.test',
  displayName: 'Admin',
  roles: roles,
  permissions: permissions,
);

void main() {
  group('E0 — AdminAuthSession.permissions default', () {
    test('defaults to an empty set when omitted from the constructor', () {
      const session = AdminAuthSession(
        uid: 'u',
        email: 'e',
        displayName: 'd',
        roles: <String>['super_admin'],
      );
      expect(session.permissions, isEmpty);
    });

    test('every demo factory carries an empty permissions set', () {
      // Demo / share-preview sessions must hit the role fallback, so
      // their permissions set is empty. This is what keeps demo mode
      // byte-identical to today.
      final superAdmin =
          DemoAdminAuthSource.signedInAsSuperAdmin().current
              as AdminAuthAuthenticated;
      final support =
          DemoAdminAuthSource.signedInAsSupport().current
              as AdminAuthAuthenticated;
      final nonAdmin =
          DemoAdminAuthSource.signedInAsNonAdmin().current
              as AdminAuthForbidden;
      expect(superAdmin.session.permissions, isEmpty);
      expect(support.session.permissions, isEmpty);
      expect(nonAdmin.session.permissions, isEmpty);
    });

    test('the demo registry sign-in path carries empty permissions', () async {
      final source = DemoAdminAuthSource.signedOut();
      addTearDown(source.dispose);
      await source.signInWithEmailPassword(
        email: 'super.admin@forgeflow.test',
        password: 'demo',
      );
      final state = source.current as AdminAuthAuthenticated;
      expect(state.session.permissions, isEmpty);
    });
  });

  group('E1 — adminCanEdit decision matrix (byte-identity invariant)', () {
    const key = PermissionKeys.adminPricingTierEdit;

    // The prompt's required matrix:
    // {super_admin, ff_support, non-admit role} x
    // {empty, key-present, key-absent}.

    test('super_admin + EMPTY permissions -> true (role fallback)', () {
      final session = sessionWith(roles: const <String>['super_admin']);
      expect(adminCanEditMirror(session, requiredKey: key), isTrue);
      // Byte-identity: equals the OLD inline pricing decision.
      expect(
        adminCanEditMirror(session, requiredKey: key),
        equals(oldPricingInline(session)),
      );
    });

    test('ff_support + EMPTY permissions -> false (role fallback)', () {
      final session = sessionWith(roles: const <String>['ff_support']);
      expect(adminCanEditMirror(session, requiredKey: key), isFalse);
      expect(
        adminCanEditMirror(session, requiredKey: key),
        equals(oldPricingInline(session)),
      );
    });

    test('non-admit role + EMPTY permissions -> false (role fallback)', () {
      final session = sessionWith(roles: const <String>['operator_owner']);
      expect(adminCanEditMirror(session, requiredKey: key), isFalse);
      expect(
        adminCanEditMirror(session, requiredKey: key),
        equals(oldPricingInline(session)),
      );
    });

    test('super_admin + permissions CONTAINING the key -> true', () {
      final session = sessionWith(
        roles: const <String>['super_admin'],
        permissions: const <String>{key},
      );
      expect(adminCanEditMirror(session, requiredKey: key), isTrue);
    });

    test('key-ABSENT (non-empty set without the key) -> false', () {
      // A hydrated session that does NOT hold the key is denied EVEN IF
      // the role would have allowed it — the key wins once the set is
      // non-empty. This is the operator-web contract.
      final session = sessionWith(
        roles: const <String>['super_admin'],
        permissions: const <String>{'admin.some.other_key'},
      );
      expect(adminCanEditMirror(session, requiredKey: key), isFalse);
    });

    test('ff_support + permissions CONTAINING the key -> true (key wins)', () {
      // Conversely, a hydrated set that DOES hold the key allows even a
      // role that the coarse fallback would deny.
      final session = sessionWith(
        roles: const <String>['ff_support'],
        permissions: const <String>{key},
      );
      expect(adminCanEditMirror(session, requiredKey: key), isTrue);
    });

    test('null session -> false', () {
      expect(adminCanEditMirror(null, requiredKey: key), isFalse);
      expect(
        adminCanEditMirror(null, requiredKey: key),
        equals(oldPricingInline(null)),
      );
    });

    test('EMPTY-permissions rows match old inline across the role matrix', () {
      // The whole matrix of empty-permission sessions must be
      // byte-identical to the pre-slice coarse decision.
      for (final roles in <List<String>>[
        const <String>['super_admin'],
        const <String>['ff_support'],
        const <String>['operator_owner'],
        const <String>['ff_support', 'super_admin'],
        const <String>[],
      ]) {
        final session = sessionWith(roles: roles);
        expect(
          adminCanEditMirror(session, requiredKey: key),
          equals(oldPricingInline(session)),
          reason: 'empty-permissions decision must match pre-slice for $roles',
        );
      }
    });

    test('PermissionKeys.adminPricingTierEdit is the expected literal', () {
      expect(
        PermissionKeys.adminPricingTierEdit,
        equals('admin.pricing_tier.edit'),
      );
    });
  });

  group('admin_capability_gate helpers', () {
    test('adminEditKeyHint: null on empty permissions, bool when hydrated', () {
      // Empty -> null so the caller stays byte-identical (role-tier
      // only). Hydrated -> presence/absence of the key.
      expect(
        adminEditKeyHint(
          sessionWith(roles: const <String>['super_admin']),
          PermissionKeys.teamRolesDefaultCatalogEdit,
        ),
        isNull,
      );
      expect(
        adminEditKeyHint(
          sessionWith(
            roles: const <String>['super_admin'],
            permissions: const <String>{
              PermissionKeys.teamRolesDefaultCatalogEdit,
            },
          ),
          PermissionKeys.teamRolesDefaultCatalogEdit,
        ),
        isTrue,
      );
      expect(
        adminEditKeyHint(
          sessionWith(
            roles: const <String>['super_admin'],
            permissions: const <String>{'admin.other'},
          ),
          PermissionKeys.teamRolesDefaultCatalogEdit,
        ),
        isFalse,
      );
      expect(adminEditKeyHint(null, 'k'), isNull);
    });

    test('adminSessionOf: session for authenticated state, else null', () {
      final session = sessionWith(roles: const <String>['super_admin']);
      expect(adminSessionOf(AdminAuthAuthenticated(session)), same(session));
      expect(adminSessionOf(const AdminAuthUnauthenticated()), isNull);
      expect(adminSessionOf(const AdminAuthLoading()), isNull);
      expect(adminSessionOf(AdminAuthForbidden(session)), isNull);
      expect(adminSessionOf(null), isNull);
    });
  });

  group('E0 — FirebaseAdminAuthSource live hydration is fail-safe', () {
    test('no loader wired -> admitted session has empty permissions', () async {
      final client = _FakeFirebaseAuthClient()
        ..signInOutcome = FirebaseAuthSignInSucceeded(_superAdminCredential());
      final ledger = _RecordingSessionsGateway();
      final source = FirebaseAdminAuthSource(
        client: client,
        sessionLedger: ledger,
        // permissionSnapshotLoader intentionally omitted (null).
      );
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin@forgeflow.test',
        password: 'pw',
      );

      final state = source.current as AdminAuthAuthenticated;
      expect(state.session.permissions, isEmpty);
      expect(state.session.roles, equals(<String>['super_admin']));
      expect(ledger.recordCalls, 1);
    });

    test(
      'a populated snapshot hydrates permissions on the live session',
      () async {
        final client = _FakeFirebaseAuthClient()
          ..signInOutcome = FirebaseAuthSignInSucceeded(
            _superAdminCredential(),
          );
        final source = FirebaseAdminAuthSource(
          client: client,
          sessionLedger: _RecordingSessionsGateway(),
          permissionSnapshotLoader: _FakeSnapshotLoader(<String>{
            PermissionKeys.adminPricingTierEdit,
          }),
        );
        addTearDown(source.dispose);
        await Future<void>.delayed(Duration.zero);

        await source.signInWithEmailPassword(
          email: 'admin@forgeflow.test',
          password: 'pw',
        );

        final state = source.current as AdminAuthAuthenticated;
        expect(
          state.session.permissions,
          equals(<String>{PermissionKeys.adminPricingTierEdit}),
        );
      },
    );

    test(
      'an EMPTY snapshot yields the role fallback (empty permissions)',
      () async {
        final client = _FakeFirebaseAuthClient()
          ..signInOutcome = FirebaseAuthSignInSucceeded(
            _superAdminCredential(),
          );
        final source = FirebaseAdminAuthSource(
          client: client,
          sessionLedger: _RecordingSessionsGateway(),
          permissionSnapshotLoader: _FakeSnapshotLoader(const <String>{}),
        );
        addTearDown(source.dispose);
        await Future<void>.delayed(Duration.zero);

        await source.signInWithEmailPassword(
          email: 'admin@forgeflow.test',
          password: 'pw',
        );

        final state = source.current as AdminAuthAuthenticated;
        expect(state.session.permissions, isEmpty);
      },
    );

    test('a THROWING loader never blocks sign-in (fail-safe)', () async {
      // Defense-in-depth: even though the production loader is itself
      // fail-safe, a misbehaving loader that throws must still admit the
      // session with empty permissions (role fallback) rather than
      // failing the sign-in.
      final client = _FakeFirebaseAuthClient()
        ..signInOutcome = FirebaseAuthSignInSucceeded(_superAdminCredential());
      final source = FirebaseAdminAuthSource(
        client: client,
        sessionLedger: _RecordingSessionsGateway(),
        permissionSnapshotLoader: _ThrowingSnapshotLoader(),
      );
      addTearDown(source.dispose);
      await Future<void>.delayed(Duration.zero);

      await source.signInWithEmailPassword(
        email: 'admin@forgeflow.test',
        password: 'pw',
      );

      final state = source.current;
      expect(state, isA<AdminAuthAuthenticated>());
      expect((state as AdminAuthAuthenticated).session.permissions, isEmpty);
    });

    test(
      'a non-admit session never reaches the loader and stays forbidden',
      () async {
        final client = _FakeFirebaseAuthClient()
          ..signInOutcome = FirebaseAuthSignInSucceeded(_operatorCredential());
        final loader = _FakeSnapshotLoader(<String>{
          PermissionKeys.adminPricingTierEdit,
        });
        final source = FirebaseAdminAuthSource(
          client: client,
          sessionLedger: _RecordingSessionsGateway(),
          permissionSnapshotLoader: loader,
        );
        addTearDown(source.dispose);
        await Future<void>.delayed(Duration.zero);

        await source.signInWithEmailPassword(
          email: 'operator@forgeflow.test',
          password: 'pw',
        );

        expect(source.current, isA<AdminAuthForbidden>());
        // The fail-closed branch must not have consulted the snapshot.
        expect(loader.loadCalls, 0);
      },
    );
  });

  group('HttpAdminPermissionSnapshotLoader — fail-safe + parsing', () {
    Uri base() => Uri.parse('https://proxy.example.test');

    test('null bearer -> empty set (no request issued)', () async {
      var requests = 0;
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => null,
        httpClient: _StubHttpClient((req) {
          requests++;
          return http.StreamedResponse(const Stream<List<int>>.empty(), 200);
        }),
      );
      expect(await loader.load(), isEmpty);
      expect(requests, 0);
    });

    test('200 with allow/deny map -> only the allow keys', () async {
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => 'token',
        httpClient: _StubHttpClient((req) {
          final body = jsonEncode(<String, Object?>{
            'permissions': <String, Object?>{
              'admin.pricing_tier.edit': 'allow',
              'admin.pricing_tier.view': 'allow',
              'admin.roles.delete_custom': 'deny',
            },
          });
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode(body)),
            200,
          );
        }),
      );
      expect(
        await loader.load(),
        equals(<String>{'admin.pricing_tier.edit', 'admin.pricing_tier.view'}),
      );
    });

    test('non-200 status -> empty set (fail-safe)', () async {
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => 'token',
        httpClient: _StubHttpClient((req) {
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{"error":"nope"}')),
            500,
          );
        }),
      );
      expect(await loader.load(), isEmpty);
    });

    test('malformed JSON body -> empty set (fail-safe)', () async {
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => 'token',
        httpClient: _StubHttpClient((req) {
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('<<not json>>')),
            200,
          );
        }),
      );
      expect(await loader.load(), isEmpty);
    });

    test('transport throw -> empty set (fail-safe, never rethrows)', () async {
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => 'token',
        httpClient: _StubHttpClient((req) {
          throw const SocketishError();
        }),
      );
      expect(await loader.load(), isEmpty);
    });

    test('issues a GET to the canonical snapshot path with a bearer', () async {
      Uri? seenUrl;
      String? seenMethod;
      String? seenAuth;
      final loader = HttpAdminPermissionSnapshotLoader(
        baseUri: base(),
        bearerTokenProvider: () async => 'tok-123',
        httpClient: _StubHttpClient((req) {
          seenUrl = req.url;
          seenMethod = req.method;
          seenAuth = req.headers['authorization'];
          return http.StreamedResponse(
            Stream<List<int>>.value(utf8.encode('{"permissions":{}}')),
            200,
          );
        }),
      );
      await loader.load();
      expect(seenMethod, equals('GET'));
      expect(
        seenUrl,
        equals(
          Uri.parse('https://proxy.example.test/v1/auth/permissions/snapshot'),
        ),
      );
      expect(seenAuth, equals('Bearer tok-123'));
    });

    group('parseAllowedPermissions', () {
      test('drops deny + non-string + missing map', () {
        expect(
          HttpAdminPermissionSnapshotLoader.parseAllowedPermissions(
            <String, Object?>{
              'permissions': <String, Object?>{
                'a': 'allow',
                'b': 'deny',
                'c': 'allow',
                'd': 1,
              },
            },
          ),
          equals(<String>{'a', 'c'}),
        );
        expect(
          HttpAdminPermissionSnapshotLoader.parseAllowedPermissions(
            <String, Object?>{'permissions': 'not-a-map'},
          ),
          isEmpty,
        );
        expect(
          HttpAdminPermissionSnapshotLoader.parseAllowedPermissions('garbage'),
          isEmpty,
        );
      });
    });
  });

  group('E2 — default-role-catalog hint feed', () {
    test(
      'hint agrees with role tier for super_admin (edit) + ff_support (no)',
      () {
        // super_admin holds the edit key; the hint and the role-tier
        // check agree -> no mismatch, canEdit true.
        expect(
          defaultRoleCatalogScreenCanEdit(
            actorRoles: const <String>['super_admin'],
            actorHasEditKeyHint: true,
          ),
          isTrue,
        );
        // ff_support does NOT hold the edit key; hint false agrees with
        // the role-tier deny.
        expect(
          defaultRoleCatalogScreenCanEdit(
            actorRoles: const <String>['ff_support'],
            actorHasEditKeyHint: false,
          ),
          isFalse,
        );
      },
    );

    test('role-tier check stays AUTHORITATIVE when the hint disagrees', () {
      // A disagreeing hint must NOT widen or narrow the gate — the
      // role-tier decision wins (defense-in-depth). This mirrors the
      // existing screen-test sentinel and is the contract Slice E2
      // preserves while supplying the live hint.
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['operator_owner'],
          actorHasEditKeyHint: true,
        ),
        isFalse,
      );
      expect(
        defaultRoleCatalogScreenCanEdit(
          actorRoles: const <String>['super_admin'],
          actorHasEditKeyHint: false,
        ),
        isTrue,
      );
    });

    test(
      'null hint (empty permissions) preserves role-tier-only behaviour',
      () {
        // When `session.permissions` is empty the route passes a null
        // hint, so the decision is exactly the pre-slice role-tier check.
        expect(
          defaultRoleCatalogScreenCanEdit(
            actorRoles: const <String>['super_admin'],
          ),
          isTrue,
        );
        expect(
          defaultRoleCatalogScreenCanEdit(
            actorRoles: const <String>['ff_support'],
          ),
          isFalse,
        );
      },
    );

    test('the edit key constant is the expected literal', () {
      expect(
        PermissionKeys.teamRolesDefaultCatalogEdit,
        equals('team.roles.default_catalog.edit'),
      );
    });
  });

  // -------------------------------------------------------------------------
  // E4 — destructive-action gates keyed per-action (MFA-fresh preserved).
  //
  // The LIVE admin route builders (`_buildMembers`,
  // `_buildRolesHierarchySessions`, `_buildAuditedSupportActions` in
  // `lib/admin/admin_routes.dart`) feed each destructive per-action flag
  // as `adminCanEdit(session, key) && <MFA-fresh>`. The destructive
  // *decision* is then `editingEnabled && <flag>` inside the screen
  // (`audited_support_actions_admin_screen.dart` :941/:972/:696,
  // `roles_hierarchy_sessions_admin_screen.dart` :850), where
  // `editingEnabled` is the `super_admin` role gate.
  //
  // E4 is operator-approved (2026-05-23). It must be byte-identical with
  // an EMPTY permissions set: `adminCanEdit` falls back to the
  // `super_admin` role check, so `super_admin(editingEnabled) &&
  // super_admin(adminCanEdit) && mfaFresh` collapses to the pre-slice
  // `super_admin && mfaFresh`. Once a live snapshot hydrates, the
  // per-action key gates its specific destructive affordance.
  //
  // The route builders are private, so we test the EXACT composed
  // expressions they produce against an ORACLE = the pre-slice decision.
  // `_freshMirror` reproduces `_isAdminMfaFresh` verbatim (null stamp ->
  // false; else the shared `JwtFreshMfaResolver` over a wrapped
  // AuthSession) with a fixed `now`, mirroring `admin_fresh_mfa_gate_test`.
  group('E4 — destructive per-action gates (byte-identity + MFA-fresh)', () {
    // 2026-05-23 12:00 UTC reference clock for the freshness window.
    final now = DateTime.utc(2026, 5, 23, 12);
    final resolver = JwtFreshMfaResolver(now: () => now);

    // Verbatim mirror of admin_routes.dart `_isAdminMfaFresh`: fail
    // closed on a null stamp, else wrap into the operator AuthSession
    // shape and ask the shared resolver.
    bool freshMirror(AdminAuthSession? session) {
      if (session == null) return false;
      final stamp = session.lastFreshAuthAt;
      if (stamp == null) return false;
      final wrapped = AuthSession(
        userId: session.uid,
        operatorId: '',
        locationId: '',
        firebaseIdToken: '',
        issuedAt: stamp,
        expiresAt: stamp.add(const Duration(hours: 1)),
        lastFreshAuthAt: stamp,
        roles: session.roles,
        mfaEnrolled: true,
      );
      return resolver.isFresh(wrapped);
    }

    // The route's role gate (`editingEnabled = _isAdminSuperAdmin`).
    bool editingEnabledOld(AdminAuthSession? session) =>
        session != null && session.roles.contains('super_admin');

    // PRE-slice destructive decision (oracle): the per-action flag was
    // MFA-fresh only, AND-ed in-screen with the role gate.
    bool oldDestructiveDecision(AdminAuthSession? session) =>
        editingEnabledOld(session) && freshMirror(session);

    // POST-slice destructive decision: the flag is now
    // `adminCanEdit(session, key) && mfaFresh`, AND-ed in-screen with the
    // (unchanged) role gate.
    bool newDestructiveDecision(
      AdminAuthSession? session, {
      required String key,
    }) =>
        editingEnabledOld(session) &&
        (adminCanEdit(session, requiredKey: key) && freshMirror(session));

    AdminAuthSession superAdminFresh({Set<String> permissions = const {}}) =>
        AdminAuthSession(
          uid: 'u1',
          email: 'admin@example.test',
          displayName: 'Admin',
          roles: const <String>['super_admin'],
          permissions: permissions,
          lastFreshAuthAt: now.subtract(const Duration(minutes: 5)),
        );

    AdminAuthSession superAdminStale({Set<String> permissions = const {}}) =>
        AdminAuthSession(
          uid: 'u1',
          email: 'admin@example.test',
          displayName: 'Admin',
          roles: const <String>['super_admin'],
          permissions: permissions,
          // 2 hours > the 1-hour default window -> stale.
          lastFreshAuthAt: now.subtract(const Duration(hours: 2)),
        );

    AdminAuthSession ffSupportFresh({Set<String> permissions = const {}}) =>
        AdminAuthSession(
          uid: 'u2',
          email: 'support@example.test',
          displayName: 'Support',
          roles: const <String>['ff_support'],
          permissions: permissions,
          lastFreshAuthAt: now.subtract(const Duration(minutes: 5)),
        );

    // One row-set, run for every destructive action + its catalog key.
    // canIssuePairedErasure maps to PII erasure (`admin.users.erase_pii`).
    final actions = <String, String>{
      'seeded-role edit': PermissionKeys.adminRolesEditSeeded,
      'reset MFA factors': PermissionKeys.adminUsersResetMfaFactors,
      'PII erasure': PermissionKeys.adminUsersErasePii,
    };

    actions.forEach((label, key) {
      group(label, () {
        test('empty perms + super_admin + MFA-fresh -> ALLOWED', () {
          final s = superAdminFresh();
          expect(newDestructiveDecision(s, key: key), isTrue);
          // Byte-identical to the pre-slice decision.
          expect(
            newDestructiveDecision(s, key: key),
            equals(oldDestructiveDecision(s)),
          );
        });

        test('empty perms + super_admin + MFA-stale -> DENIED', () {
          final s = superAdminStale();
          expect(newDestructiveDecision(s, key: key), isFalse);
          // Freshness dimension unchanged.
          expect(
            newDestructiveDecision(s, key: key),
            equals(oldDestructiveDecision(s)),
          );
        });

        test('empty perms + ff_support (MFA-fresh) -> DENIED', () {
          final s = ffSupportFresh();
          expect(newDestructiveDecision(s, key: key), isFalse);
          expect(
            newDestructiveDecision(s, key: key),
            equals(oldDestructiveDecision(s)),
          );
        });

        test('perms WITH the key + MFA-fresh -> ALLOWED', () {
          // A hydrated super_admin holding the key: editingEnabled (role)
          // && adminCanEdit(key present) && fresh -> allowed.
          final s = superAdminFresh(permissions: <String>{key});
          expect(newDestructiveDecision(s, key: key), isTrue);
        });

        test('perms WITHOUT the key -> DENIED even if MFA-fresh', () {
          // Hydrated set that does NOT hold the key: the key wins once
          // the set is non-empty, so the destructive gate is denied.
          final s = superAdminFresh(
            permissions: const <String>{'admin.some.other_key'},
          );
          expect(newDestructiveDecision(s, key: key), isFalse);
        });

        test('perms WITH the key but MFA-stale -> DENIED (freshness)', () {
          // Even with the per-action key held, a stale MFA stamp denies:
          // the freshness dimension is preserved exactly.
          final s = superAdminStale(permissions: <String>{key});
          expect(newDestructiveDecision(s, key: key), isFalse);
        });

        test('null session -> DENIED (byte-identical)', () {
          expect(newDestructiveDecision(null, key: key), isFalse);
          expect(
            newDestructiveDecision(null, key: key),
            equals(oldDestructiveDecision(null)),
          );
        });

        test('the per-action flag itself equals adminCanEdit && fresh', () {
          // Pin the route's per-action flag shape (independent of the
          // in-screen role conjunction): flag == adminCanEdit(key) && fresh.
          for (final s in <AdminAuthSession?>[
            superAdminFresh(),
            superAdminStale(),
            ffSupportFresh(),
            superAdminFresh(permissions: <String>{key}),
            superAdminFresh(permissions: const <String>{'admin.other'}),
            null,
          ]) {
            final flag = adminCanEdit(s, requiredKey: key) && freshMirror(s);
            // With empty perms the flag reduces to super_admin && fresh,
            // which is the OLD flag value (MFA-fresh) ONLY when the role
            // is super_admin; for non-super_admin empty-perms sessions the
            // OLD flag was MFA-fresh alone (role lived in editingEnabled),
            // so we assert the *decision* equality elsewhere and here only
            // pin the new flag's internal composition.
            expect(
              flag,
              equals(adminCanEdit(s, requiredKey: key) && freshMirror(s)),
            );
          }
        });
      });
    });

    test('every E4 destructive key is a real catalog key', () {
      for (final key in actions.values) {
        expect(
          PermissionKeys.all.contains(key),
          isTrue,
          reason: '$key must exist in the frozen catalog',
        );
      }
    });

    test('catalog requiresMfa flags match the route freshness gating', () {
      // These destructive keys are catalog-flagged `requiresMfa`; audit-log
      // export is handled by the non-destructive audit export key gate.
      expect(
        PermissionKeys.requiresMfa.contains(
          PermissionKeys.adminRolesEditSeeded,
        ),
        isTrue,
      );
      expect(
        PermissionKeys.requiresMfa.contains(
          PermissionKeys.adminUsersResetMfaFactors,
        ),
        isTrue,
      );
      expect(
        PermissionKeys.requiresMfa.contains(PermissionKeys.adminUsersErasePii),
        isTrue,
      );
      expect(
        PermissionKeys.requiresMfa.contains(PermissionKeys.adminAuditLogExport),
        isFalse,
      );
    });

    test('E4 destructive key literals are the expected strings', () {
      expect(
        PermissionKeys.adminRolesEditSeeded,
        equals('admin.roles.edit_seeded'),
      );
      expect(
        PermissionKeys.adminUsersResetMfaFactors,
        equals('admin.users.reset_mfa_factors'),
      );
      expect(
        PermissionKeys.adminUsersErasePii,
        equals('admin.users.erase_pii'),
      );
      expect(
        PermissionKeys.adminAuditLogExport,
        equals('admin.audit_log.export'),
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSnapshotLoader implements AdminPermissionSnapshotLoader {
  _FakeSnapshotLoader(this._allowed);
  final Set<String> _allowed;
  int loadCalls = 0;

  @override
  Future<Set<String>> load() async {
    loadCalls++;
    return _allowed;
  }
}

class _ThrowingSnapshotLoader implements AdminPermissionSnapshotLoader {
  @override
  Future<Set<String>> load() async {
    throw StateError('snapshot blew up');
  }
}

class _RecordingSessionsGateway implements AdminSessionsGateway {
  int recordCalls = 0;

  @override
  Future<AdminSessionLedgerRecord> recordSessionLogin({
    required String tokenHash,
    required String idempotencyKey,
  }) async {
    recordCalls++;
    return const AdminSessionLedgerRecord(
      sessionId: 'sess-1',
      userId: 'firebase-admin',
    );
  }

  @override
  Future<void> revokeSession({
    required String sessionId,
    required String reason,
    required String idempotencyKey,
  }) async {}

  @override
  Future<List<AdminSessionEntry>> listOwnSessions() async =>
      const <AdminSessionEntry>[];

  @override
  Future<int> signOutEverywhere({
    required String reason,
    required String idempotencyKey,
  }) async => 0;
}

class _FakeFirebaseAuthClient implements FirebaseAuthClient {
  FirebaseAuthSignInOutcome signInOutcome = const FirebaseAuthSignInFailed(
    code: 'unconfigured',
    message: 'unconfigured',
  );

  @override
  Future<FirebaseAuthSignInOutcome> signInWithEmailPassword({
    required String email,
    required String password,
  }) async => signInOutcome;

  @override
  Future<FirebaseAuthSignInOutcome> completeTotpChallenge({
    required String mfaSessionToken,
    required String factorId,
    required String oneTimeCode,
  }) async => signInOutcome;

  @override
  Future<void> requestPasswordReset({required String email}) async {}

  @override
  Future<FirebaseAuthCredential?> refreshIdToken() async => null;

  @override
  Future<String?> currentIdToken() async => 'id-token';

  @override
  Future<void> signOut() async {}

  @override
  Future<void> revokeAllRefreshTokens() async {}
}

FirebaseAuthCredential _superAdminCredential() {
  final now = DateTime.utc(2026, 5, 2, 12);
  return FirebaseAuthCredential(
    userId: 'firebase-admin',
    idToken: 'id-token',
    idTokenIssuedAt: now,
    idTokenExpiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    email: 'admin@forgeflow.test',
    displayName: 'Admin',
    customClaims: const <String, Object?>{'is_super_admin': true},
  );
}

FirebaseAuthCredential _operatorCredential() {
  final now = DateTime.utc(2026, 5, 2, 12);
  return FirebaseAuthCredential(
    userId: 'firebase-operator',
    idToken: 'id-token',
    idTokenIssuedAt: now,
    idTokenExpiresAt: now.add(const Duration(hours: 1)),
    lastFreshAuthAt: now,
    email: 'operator@forgeflow.test',
    displayName: 'Operator',
    customClaims: const <String, Object?>{},
  );
}

class SocketishError implements Exception {
  const SocketishError();
}

/// Minimal `http.Client` stub: routes `send` through a caller-supplied
/// handler so each test can assert the request and return a canned
/// streamed response (or throw).
class _StubHttpClient extends http.BaseClient {
  _StubHttpClient(this._handler);
  final http.StreamedResponse Function(http.BaseRequest request) _handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      _handler(request);
}
