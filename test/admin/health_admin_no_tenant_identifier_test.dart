// Phase 11A.UX.health (F.1) — invariant: no tenant identifiers leak
// into the rendered Health surface.
//
// `docs/contracts/proxy_health_contract.md` is explicit that the
// `/health` envelope must never carry tenant or operator
// identifiers. The admin screen is a pure consumer of that envelope
// — but a careless code change could still introduce an identifier
// (for example, by surfacing `metadata` blobs or surface owners that
// happen to embed an ID). This test pumps the screen against an
// envelope that contains a syntactically valid UUID inside an
// untrusted `metadata` slot, walks every rendered text, and asserts
// none of the identifier-shaped strings reach the output.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/health_admin_screen.dart';
import 'package:forge_and_flow/admin/services/health_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  void setLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('rendered text contains no operator_id/tenant_id-shaped values', (
    tester,
  ) async {
    setLargeViewport(tester);
    // The envelope below intentionally smuggles values into the
    // metadata slots that LOOK like tenant identifiers. The screen
    // must not surface them.
    const sentinelOperatorId = '00000000-0000-4000-8000-000000000fff';
    const sentinelTenantId = 'tenant-abc-123';
    const sentinelDeviceId = 'device-xyz-789';

    final envelope = <String, Object?>{
      'status': 'ok',
      'severity': 'green',
      'contract': 'proxy_health.v1',
      'schema_version': 1,
      'checked_at': '2026-05-02T12:00:00.000Z',
      'dependencies': <String, Object?>{
        'postgres': <String, Object?>{
          'status': 'green',
          'check': 'select_1',
          'legacy_key': 'postgres_select_1',
        },
        'age': <String, Object?>{
          'status': 'green',
          'check': 'cypher_match',
          'legacy_key': 'age_cypher_match',
        },
        'pgvector': <String, Object?>{
          'status': 'green',
          'check': 'similarity',
          'legacy_key': 'pgvector_similarity',
        },
      },
      'surfaces': <String, Object?>{},
      'metrics': <String, Object?>{
        'audit_chain_lag_seconds': <String, Object?>{
          'status': 'green',
          'value': 12,
          'unit': 'seconds',
          'description': 'audit lag',
          'owner': 'B37/B43',
          'observed_at': '2026-05-02T12:00:00.000Z',
          'metadata': <String, Object?>{
            'tier': 1,
            // SHOULD NOT REACH RENDER:
            'operator_id': sentinelOperatorId,
            'tenant_id': sentinelTenantId,
            'device_id': sentinelDeviceId,
          },
        },
      },
      'warnings': <Object?>[],
    };

    final gateway = InMemoryHealthAdminGateway(envelope: envelope);
    await tester.pumpWidget(
      wrap(
        HealthAdminScreen(
          gateway: gateway,
          now: () => DateTime.utc(2026, 5, 2, 12),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_health_refresh_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_health_confirm_run')));
    await tester.pumpAndSettle();

    // Walk every Text widget in the tree and assert no identifier-
    // shaped sentinel is present in either the data or the rich
    // text spans. We deliberately avoid matching the metadata `tier`
    // value (which is a plain integer the screen does render, e.g.
    // "T1" inside the chip) — that is not a tenant identifier.
    final allText = <String>[];
    void collect(Element element) {
      final widget = element.widget;
      if (widget is Text) {
        final data = widget.data;
        if (data != null) allText.add(data);
        final span = widget.textSpan;
        if (span != null) {
          allText.add(span.toPlainText());
        }
      }
      element.visitChildren(collect);
    }

    final root = tester.binding.rootElement!;
    root.visitChildren(collect);

    for (final text in allText) {
      expect(
        text.contains(sentinelOperatorId),
        isFalse,
        reason:
            'Health screen rendered an operator-shaped UUID: '
            '"$text" contains sentinel "$sentinelOperatorId"',
      );
      expect(
        text.contains(sentinelTenantId),
        isFalse,
        reason:
            'Health screen rendered a tenant-shaped identifier: '
            '"$text" contains sentinel "$sentinelTenantId"',
      );
      expect(
        text.contains(sentinelDeviceId),
        isFalse,
        reason:
            'Health screen rendered a device-shaped identifier: '
            '"$text" contains sentinel "$sentinelDeviceId"',
      );
      // Phrase-level check: the literal substrings "operator_id" /
      // "tenant_id" / "device_id" must not appear anywhere either,
      // since metadata key names would also leak the smuggled keys
      // if the screen ever prints raw metadata.
      expect(
        text.contains('operator_id'),
        isFalse,
        reason: 'Health screen leaked the metadata key "operator_id"',
      );
      expect(
        text.contains('tenant_id'),
        isFalse,
        reason: 'Health screen leaked the metadata key "tenant_id"',
      );
      expect(
        text.contains('device_id'),
        isFalse,
        reason: 'Health screen leaked the metadata key "device_id"',
      );
    }
  });
}
