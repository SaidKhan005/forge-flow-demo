import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/operator_web/widgets/operator_web_screen_header.dart';

void main() {
  Future<void> pumpHeader(
    WidgetTester tester, {
    required double width,
    String? subtitle,
    List<Widget> actions = const <Widget>[],
    Key? titleKey,
    Key? subtitleKey,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: OperatorWebScreenHeader(
                icon: Icons.business_outlined,
                title: 'Business account',
                titleKey: titleKey,
                subtitle: subtitle,
                subtitleKey: subtitleKey,
                actions: actions,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the leading icon and title', (tester) async {
    await pumpHeader(tester, width: 800);

    expect(find.text('Business account'), findsOneWidget);
    expect(find.byIcon(Icons.business_outlined), findsOneWidget);
  });

  testWidgets('applies the supplied titleKey to the title text', (
    tester,
  ) async {
    await pumpHeader(tester, width: 800, titleKey: const Key('header_title'));

    expect(find.byKey(const Key('header_title')), findsOneWidget);
  });

  testWidgets('renders the subtitle only when one is provided', (tester) async {
    await pumpHeader(tester, width: 800);
    expect(find.text('Manage your details'), findsNothing);

    await pumpHeader(tester, width: 800, subtitle: 'Manage your details');
    expect(find.text('Manage your details'), findsOneWidget);
  });

  testWidgets('applies the supplied subtitleKey to the subtitle text', (
    tester,
  ) async {
    await pumpHeader(
      tester,
      width: 800,
      subtitle: 'Manage your details',
      subtitleKey: const Key('header_subtitle'),
    );

    expect(find.byKey(const Key('header_subtitle')), findsOneWidget);
  });

  testWidgets('wide layout places actions beside the title (Row)', (
    tester,
  ) async {
    await pumpHeader(
      tester,
      width: 800,
      actions: <Widget>[
        FilledButton(
          key: const Key('header_action'),
          onPressed: () {},
          child: const Text('New'),
        ),
      ],
    );

    expect(find.byKey(const Key('header_action')), findsOneWidget);
    // Above the collapse width the title sits to the left of the action,
    // so the action's left edge is past the title's left edge.
    final titleX = tester.getTopLeft(find.text('Business account')).dx;
    final actionX = tester.getTopLeft(find.byKey(const Key('header_action'))).dx;
    expect(actionX, greaterThan(titleX));
  });

  testWidgets('narrow layout stacks actions beneath the title (Column)', (
    tester,
  ) async {
    await pumpHeader(
      tester,
      width: 360,
      actions: <Widget>[
        FilledButton(
          key: const Key('header_action'),
          onPressed: () {},
          child: const Text('New'),
        ),
      ],
    );

    expect(find.byKey(const Key('header_action')), findsOneWidget);
    // Below the collapse width the action drops under the title, so its
    // top edge is below the title's top edge.
    final titleY = tester.getTopLeft(find.text('Business account')).dy;
    final actionY = tester.getTopLeft(find.byKey(const Key('header_action'))).dy;
    expect(actionY, greaterThan(titleY));
  });
}
