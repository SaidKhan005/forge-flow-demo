// Phase 11W.0 - Operator Web Console app shell tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/operator_web_app.dart';

void main() {
  testWidgets('browser metadata title uses plain hyphen copy', (tester) async {
    final source = DemoOperatorWebAuthSource.signedOut();
    addTearDown(source.dispose);

    await tester.pumpWidget(OperatorWebApp(authSource: source));

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.title, equals('Forge & Flow - Operator Web Console'));
  });
}
