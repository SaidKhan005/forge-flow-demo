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
    expect(
      find.text('Publish the first default catalog?'),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const Key('admin_default_role_catalog_publish_blast_notice'),
      ),
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
                      'role_key': 'operator_admin',
                      'display_name': 'Operator Admin',
                      'description': 'Admin role.',
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
    expect(
      find.text('Publish a new default catalog version?'),
      findsOneWidget,
    );
    expect(find.textContaining('version 3'), findsOneWidget);
    expect(find.textContaining('version 4'), findsOneWidget);

    // Fill optional notes.
    await tester.enterText(
      find.byKey(const Key('admin_default_role_catalog_publish_notes')),
      'Added operator_admin role per ENG-123.',
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
      find.byKey(
        const Key('admin_default_role_catalog_publish_success_body'),
      ),
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
      find.byKey(
        const Key('admin_default_role_catalog_publish_error_text'),
      ),
      findsOneWidget,
    );
    // Friendly translation of permission_denied.
    expect(
      find.textContaining('only ecosystem admins'),
      findsOneWidget,
    );
    // Retry returns to type-confirm stage.
    expect(
      find.byKey(
        const Key('admin_default_role_catalog_publish_error_retry'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('admin_default_role_catalog_publish_error_retry')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Confirm version 4'), findsOneWidget);
  });

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
    expect(
      find.text('Publish a new default catalog version?'),
      findsOneWidget,
    );
  });
}

class _ThrowingGateway implements DefaultRoleCatalogAdminGateway {
  _ThrowingGateway(this.error);

  final Object error;

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
}
