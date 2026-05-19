// Lane B B2.2 - Default Role catalog publish dialog widget tests.
//
// Pins the dialog contract documented in
// `lib/admin/screens/default_role_catalog_publish_dialog.dart`:
//
//   * Stage 1 (awareness) shows the prior current version + blast-radius
//     plain-English notice + optional notes field; "Continue" advances.
//   * Stage 2 (type-confirm) requires typing the new version number;
//     "Publish" stays disabled until the typed value matches.
//   * Stage 3 (publishing) shows a progress indicator.
//   * Stage 4 (success) reports the new version number; Done returns
//     the new row to the caller.
//   * Stage 5 (error) surfaces the gateway error inline + offers retry.
//   * Cancel returns null.
//   * Genesis path (priorCurrent == null) shows the first-publish copy.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/default_role_catalog_publish_dialog.dart';
import 'package:forge_and_flow/admin/services/default_role_catalog_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  void sizeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  DefaultRoleCatalogVersionView priorCurrent({
    int versionNumber = 3,
    List<Object?> payload = const <Object?>[
      <String, Object?>{
        'role_key': 'operator_owner',
        'display_name': 'Operator Owner',
        'description': 'Owner of the business.',
        'permissions': <Object?>[],
      },
    ],
  }) {
    return DefaultRoleCatalogVersionView(
      versionId: 'prior-version-id',
      versionNumber: versionNumber,
      publishedAt: DateTime.utc(2026, 5, 1, 10, 0),
      publishedByUserId: 'super-admin-uuid',
      payload: payload,
      payloadSha256: 'a' * 64,
      isCurrent: true,
      supersededAt: null,
      notes: 'Prior version notes',
    );
  }

  testWidgets('genesis path: priorCurrent null shows first-publish copy', (
    tester,
  ) async {
    sizeViewport(tester);
    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    DefaultRoleCatalogPublishResult? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showDefaultRoleCatalogPublishDialog(
                  context: context,
                  gateway: gateway,
                  priorCurrent: null,
                  nextVersionNumber: 1,
                  proposedPayload: const <Object?>[
                    <String, Object?>{
                      'role_key': 'operator_owner',
                      'display_name': 'Operator Owner',
                      'description': 'Owner.',
                      'permissions': <Object?>[],
                    },
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_dialog')),
      findsOneWidget,
    );
    expect(find.text('Publish the first default catalog?'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_blast_notice')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_cancel')),
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('two-stage flow: continue → type-confirm → publish → success', (
    tester,
  ) async {
    sizeViewport(tester);
    final gateway = InMemoryDefaultRoleCatalogAdminGateway(
      now: () => DateTime.utc(2026, 5, 13, 12, 0),
      versionIdGenerator: () => 'new-version-id',
    );
    DefaultRoleCatalogPublishResult? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open'),
              onPressed: () async {
                result = await showDefaultRoleCatalogPublishDialog(
                  context: context,
                  gateway: gateway,
                  priorCurrent: priorCurrent(versionNumber: 3),
                  nextVersionNumber: 4,
                  proposedPayload: const <Object?>[
                    <String, Object?>{
                      'role_key': 'operator_general_manager',
                      'display_name': 'General Manager',
                      'description': 'General manager role.',
                      'permissions': <Object?>[],
                    },
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    // Stage 1: awareness shows prior version + blast notice.
    expect(find.text('Publish a new default catalog version?'), findsOneWidget);
    expect(find.textContaining('version 3'), findsOneWidget);
    expect(find.textContaining('version 4'), findsOneWidget);

    // Fill optional notes.
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_publish_notes')),
      'Added General Manager role per ENG-123.',
    );
    await tester.pump();

    // Continue → Stage 2 type-confirm.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_continue')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Confirm version 4'), findsOneWidget);
    final publishBtn = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_confirm')),
    );
    // Button disabled until type matches.
    expect(publishBtn.onPressed, isNull);

    // Type wrong number first.
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_publish_typed')),
      '5',
    );
    await tester.pump();
    final stillDisabled = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_confirm')),
    );
    expect(stillDisabled.onPressed, isNull);

    // Type correct number.
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_publish_typed')),
      '4',
    );
    await tester.pump();
    final enabled = tester.widget<FilledButton>(
      find.byKey(const Key('admin_default_role_catalog_publish_confirm')),
    );
    expect(enabled.onPressed, isNotNull);

    // Publish.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_confirm')),
    );
    await tester.pumpAndSettle();

    // Success stage.
    expect(find.textContaining('Published version 1'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_success_body')),
      findsOneWidget,
    );

    // Done → resolves with the new row.
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_done')),
    );
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.versionNumber, 1); // in-memory genesis
    expect(result!.versionId, 'new-version-id');
  });

  testWidgets('error path: gateway error surfaces inline + retry available', (
    tester,
  ) async {
    sizeViewport(tester);
    final gateway = _ThrowingGateway(
      DefaultRoleCatalogAdminGatewayError(
        statusCode: 403,
        errorCode: 'permission_denied',
        message: 'role gate',
      ),
    );
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open'),
              onPressed: () async {
                await showDefaultRoleCatalogPublishDialog(
                  context: context,
                  gateway: gateway,
                  priorCurrent: priorCurrent(),
                  nextVersionNumber: 4,
                  proposedPayload: const <Object?>[
                    <String, Object?>{
                      'role_key': 'rk',
                      'display_name': 'Display',
                      'description': '',
                      'permissions': <Object?>[],
                    },
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_continue')),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_publish_typed')),
      '4',
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_confirm')),
    );
    await tester.pumpAndSettle();

    // Error stage.
    expect(find.text('Publish failed'), findsOneWidget);
    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_error_text')),
      findsOneWidget,
    );
    // Friendly translation of permission_denied.
    expect(find.textContaining('only ecosystem admins'), findsOneWidget);
    // Retry returns to type-confirm stage.
    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_error_retry')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_error_retry')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirm version 4'), findsOneWidget);
  });

  // ─── B2.3 — blast-radius copy variants ──────────────────────────

  testWidgets(
    'B2.3 numeric copy renders when gateway returns non-zero counts',
    (tester) async {
      sizeViewport(tester);
      final prior = priorCurrent(versionNumber: 3);
      final gateway = InMemoryDefaultRoleCatalogAdminGateway(
        blastRadiusByVersionId: <String, DefaultRoleCatalogBlastRadius>{
          prior.versionId: DefaultRoleCatalogBlastRadius(
            versionId: prior.versionId,
            versionNumber: 3,
            operatorCount: 47,
            locationCount: 312,
            userCount: 1403,
          ),
        },
      );
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('open'),
                onPressed: () async {
                  await showDefaultRoleCatalogPublishDialog(
                    context: context,
                    gateway: gateway,
                    priorCurrent: prior,
                    nextVersionNumber: 4,
                    proposedPayload: const <Object?>[
                      <String, Object?>{
                        'role_key': 'r',
                        'display_name': 'R',
                        'description': '',
                        'permissions': <Object?>[],
                      },
                    ],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      // Numeric copy folds the three counts into one sentence.
      expect(
        find.byKey(const Key('admin_default_role_catalog_publish_headline')),
        findsOneWidget,
      );
      expect(find.textContaining('47 businesses'), findsOneWidget);
      expect(find.textContaining('312 locations'), findsOneWidget);
      expect(find.textContaining('1403 users'), findsOneWidget);
      // No error chip rendered on the happy path.
      expect(
        find.byKey(
          const Key('admin_default_role_catalog_publish_blast_error_chip'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('B2.3 zero counts → plain-English fallback (no numeric counts)', (
    tester,
  ) async {
    sizeViewport(tester);
    final prior = priorCurrent(versionNumber: 3);
    // Default in-memory gateway returns zero counts for any version.
    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    // Seed the prior version into the in-memory store so the lookup
    // succeeds (and returns zero counts via the orElse path).
    await gateway.publishVersion(payload: prior.payload);
    // The published version has a fresh versionId; we pass the
    // original prior with a known id, so the in-memory gateway
    // returns a 404 in `getBlastRadius` — but that's the error-chip
    // path, not zero-counts. Use a configured seed instead:
    final gatewayWithSeed = InMemoryDefaultRoleCatalogAdminGateway(
      blastRadiusByVersionId: <String, DefaultRoleCatalogBlastRadius>{
        prior.versionId: DefaultRoleCatalogBlastRadius(
          versionId: prior.versionId,
          versionNumber: 3,
          operatorCount: 0,
          locationCount: 0,
          userCount: 0,
        ),
      },
    );
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open'),
              onPressed: () async {
                await showDefaultRoleCatalogPublishDialog(
                  context: context,
                  gateway: gatewayWithSeed,
                  priorCurrent: prior,
                  nextVersionNumber: 4,
                  proposedPayload: const <Object?>[
                    <String, Object?>{
                      'role_key': 'r',
                      'display_name': 'R',
                      'description': '',
                      'permissions': <Object?>[],
                    },
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    // Plain-English fallback renders; no numeric counts.
    expect(
      find.byKey(const Key('admin_default_role_catalog_publish_headline')),
      findsOneWidget,
    );
    expect(find.textContaining('0 businesses'), findsNothing);
    expect(find.textContaining('replace the current default'), findsOneWidget);
    // No error chip because the fetch resolved successfully.
    expect(
      find.byKey(
        const Key('admin_default_role_catalog_publish_blast_error_chip'),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'B2.3 gateway error → plain-English fallback + error chip surfaces code',
    (tester) async {
      sizeViewport(tester);
      // Throw on the blast-radius fetch only. publishVersion / listCatalogs
      // are not exercised by this test, but the throwing-gateway fake
      // throws the same error there too — that's fine; the dialog never
      // reaches those paths in this flow.
      final gateway = _ThrowingGateway(
        DefaultRoleCatalogAdminGatewayError(
          statusCode: 503,
          errorCode: 'default_role_catalog_admin_unavailable',
          message: 'transient backend hiccup',
        ),
        blastRadiusError: DefaultRoleCatalogAdminGatewayError(
          statusCode: 503,
          errorCode: 'default_role_catalog_admin_unavailable',
          message: 'transient backend hiccup',
        ),
      );
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('open'),
                onPressed: () async {
                  await showDefaultRoleCatalogPublishDialog(
                    context: context,
                    gateway: gateway,
                    priorCurrent: priorCurrent(versionNumber: 3),
                    nextVersionNumber: 4,
                    proposedPayload: const <Object?>[
                      <String, Object?>{
                        'role_key': 'r',
                        'display_name': 'R',
                        'description': '',
                        'permissions': <Object?>[],
                      },
                    ],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      // Plain-English fallback renders.
      expect(
        find.textContaining('replace the current default'),
        findsOneWidget,
      );
      // Error chip renders the proxy error code.
      expect(
        find.byKey(
          const Key('admin_default_role_catalog_publish_blast_error_chip'),
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('default_role_catalog_admin_unavailable'),
        findsOneWidget,
      );
      // Cancel still resolves to null — publish path not blocked by
      // a blast-radius preview failure.
      await tester.tap(
        find.byKey(const Key('admin_default_role_catalog_publish_cancel')),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'B2.3 genesis publish skips blast-radius fetch (priorCurrent null)',
    (tester) async {
      sizeViewport(tester);
      // Throw on getBlastRadius — if the dialog accidentally calls it
      // during the genesis path the test will fail with a stack trace.
      final gateway = _ThrowingGateway(
        DefaultRoleCatalogAdminGatewayError(
          statusCode: 500,
          errorCode: 'should_not_be_called',
          message: 'genesis publish must not call getBlastRadius',
        ),
        blastRadiusError: StateError('getBlastRadius called on genesis path'),
      );
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) => Center(
              child: FilledButton(
                key: const Key('open'),
                onPressed: () async {
                  await showDefaultRoleCatalogPublishDialog(
                    context: context,
                    gateway: gateway,
                    priorCurrent: null,
                    nextVersionNumber: 1,
                    proposedPayload: const <Object?>[
                      <String, Object?>{
                        'role_key': 'r',
                        'display_name': 'R',
                        'description': '',
                        'permissions': <Object?>[],
                      },
                    ],
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();

      // Genesis-first-publish copy + no error chip.
      expect(
        find.textContaining('the first version of the default role catalog'),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('admin_default_role_catalog_publish_blast_error_chip'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('back from type-confirm returns to awareness stage', (
    tester,
  ) async {
    sizeViewport(tester);
    final gateway = InMemoryDefaultRoleCatalogAdminGateway();
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const Key('open'),
              onPressed: () async {
                await showDefaultRoleCatalogPublishDialog(
                  context: context,
                  gateway: gateway,
                  priorCurrent: priorCurrent(),
                  nextVersionNumber: 4,
                  proposedPayload: const <Object?>[
                    <String, Object?>{
                      'role_key': 'rk',
                      'display_name': 'Display',
                      'description': '',
                      'permissions': <Object?>[],
                    },
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_continue')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirm version 4'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_back')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Publish a new default catalog version?'), findsOneWidget);
  });
}

/// Test gateway used by the publish dialog tests. The `publishVersion`
/// + `listCatalogs` calls throw [error]; B2.3 adds [blastRadiusError]
/// so the dialog's blast-radius preview can be exercised in the error
/// path. When [blastRadiusError] is null the fake returns deterministic
/// zero counts so the dialog renders its plain-English fallback.
class _ThrowingGateway implements DefaultRoleCatalogAdminGateway {
  _ThrowingGateway(this.error, {this.blastRadiusError});

  final Object error;
  final Object? blastRadiusError;

  @override
  Future<DefaultRoleCatalogListing> listCatalogs({int historyLimit = 20}) {
    throw error;
  }

  @override
  Future<DefaultRoleCatalogVersionView> publishVersion({
    required List<Object?> payload,
    String? notes,
  }) {
    throw error;
  }

  @override
  Future<DefaultRoleCatalogBlastRadius> getBlastRadius({
    required String versionId,
  }) async {
    final err = blastRadiusError;
    if (err != null) throw err;
    // No error configured — return zero state so the dialog renders
    // the plain-English fallback.
    return DefaultRoleCatalogBlastRadius(
      versionId: versionId,
      versionNumber: 0,
      operatorCount: 0,
      locationCount: 0,
      userCount: 0,
    );
  }
}
