import 'package:flutter_test/flutter_test.dart';
import 'package:forge_flow_demo/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ForgeFlowApp());
    expect(find.byType(ForgeFlowApp), findsOneWidget);
  });
}
