// Wave 2 W-5 — widget tests for the business logo upload section.
//
// Validates the operator-web Business Account screen's upload UX:
//   * Renders the "Choose PNG" + "Upload" buttons when a live gateway
//     is wired.
//   * Renders an explainer banner when the gateway is null (the URL
//     paste field still works in that branch).
//   * Picking a file shows the preview tile with filename + size.
//   * Successful upload calls onUploaded with the resolved URL.
//   * Client-side validation surfaces the error message inline.
//   * Proxy 4xx / 5xx surfaces the error message inline.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/business_logo_file_picker.dart';
import 'package:forge_and_flow/operator_web/services/business_logo_upload_gateway.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/widgets/business_logo_upload_section.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

class _FakeUploadGateway implements BusinessLogoUploadGateway {
  _FakeUploadGateway({this.failureMessage, this.proxyError});

  final String? failureMessage;
  final OperatorWebProxyException? proxyError;
  int calls = 0;
  Uint8List? lastBytes;
  String? lastFilename;

  @override
  Future<BusinessLogoUploadOutcome> uploadLogo({
    required Uint8List pngBytes,
    required String filename,
  }) async {
    calls += 1;
    lastBytes = pngBytes;
    lastFilename = filename;
    if (failureMessage != null) {
      throw BusinessLogoValidationException(
        code: 'invalid_png_magic',
        message: failureMessage!,
      );
    }
    if (proxyError != null) {
      throw proxyError!;
    }
    return BusinessLogoUploadOutcome(
      logoUrl: 'https://stub.example/operators/op-1/logo.png',
      sizeBytes: pngBytes.length,
    );
  }
}

Widget _wrap(Widget child) => MaterialApp(
  theme: AppTheme.themeData,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

PickedBusinessLogoFile _samplePicked() {
  return PickedBusinessLogoFile(
    bytes: Uint8List.fromList(<int>[
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x01,
      0x02,
      0x03,
    ]),
    filename: 'brio-logo.png',
  );
}

void main() {
  testWidgets('renders the choose + upload buttons when gateway is wired', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway();
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: true,
          onUploaded: (_) {},
        ),
      ),
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_upload_section')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_pick')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_upload')),
      findsOneWidget,
    );
    // Until the operator picks a file the Upload button is disabled.
    final uploadButton = tester.widget<FilledButton>(
      find.byKey(const Key('operator_web_account_logo_upload')),
    );
    expect(uploadButton.onPressed, isNull);
  });

  testWidgets('renders the unavailable banner when no gateway is wired', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: null,
          enabled: true,
          onUploaded: (_) {},
        ),
      ),
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_upload_unavailable')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_pick')),
      findsNothing,
    );
  });

  testWidgets('shows a plain reason when upload is disabled by the parent', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway();
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: false,
          disabledReason:
              'Logo changes are set at the Business level. Switch Managing '
              'to All locations to upload a PNG.',
          onUploaded: (_) {},
        ),
      ),
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_upload_unavailable')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operator_web_account_logo_upload_disabled_reason')),
      findsOneWidget,
    );
    final pickButton = tester.widget<OutlinedButton>(
      find.byKey(const Key('operator_web_account_logo_pick')),
    );
    expect(pickButton.onPressed, isNull);
  });

  testWidgets('picking a file shows the preview tile + filename', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway();
    final picked = _samplePicked();
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: true,
          onUploaded: (_) {},
          filePicker: () async => picked,
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('operator_web_account_logo_pick')));
    await tester.pump();
    expect(
      find.byKey(const Key('operator_web_account_logo_picked_tile')),
      findsOneWidget,
    );
    expect(find.text(picked.filename), findsOneWidget);
  });

  testWidgets('successful upload calls onUploaded with the resolved URL', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway();
    String? resolved;
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: true,
          onUploaded: (url) => resolved = url,
          filePicker: () async => _samplePicked(),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('operator_web_account_logo_pick')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('operator_web_account_logo_upload')));
    await tester.pump();
    await tester.pump();
    expect(gateway.calls, equals(1));
    expect(resolved, equals('https://stub.example/operators/op-1/logo.png'));
    expect(
      find.byKey(const Key('operator_web_account_logo_success')),
      findsOneWidget,
    );
  });

  testWidgets('client-side validation failure surfaces in the inline error', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway(
      failureMessage: 'That file is not a valid PNG.',
    );
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: true,
          onUploaded: (_) {},
          filePicker: () async => _samplePicked(),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('operator_web_account_logo_pick')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('operator_web_account_logo_upload')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('operator_web_account_logo_error')),
      findsOneWidget,
    );
    expect(find.text('That file is not a valid PNG.'), findsOneWidget);
  });

  testWidgets('proxy error surfaces in the inline error banner', (
    tester,
  ) async {
    final gateway = _FakeUploadGateway(
      proxyError: const OperatorWebProxyException(
        code: 'business_logo_uploader_not_configured',
        message: 'logo upload is not available on this build.',
      ),
    );
    await tester.pumpWidget(
      _wrap(
        BusinessLogoUploadSection(
          gateway: gateway,
          enabled: true,
          onUploaded: (_) {},
          filePicker: () async => _samplePicked(),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('operator_web_account_logo_pick')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('operator_web_account_logo_upload')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const Key('operator_web_account_logo_error')),
      findsOneWidget,
    );
    expect(
      find.text('logo upload is not available on this build.'),
      findsOneWidget,
    );
  });
}
