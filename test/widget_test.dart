import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/forge_flow_app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ForgeFlowApp());
    expect(find.byType(ForgeFlowApp), findsOneWidget);
  });
}
