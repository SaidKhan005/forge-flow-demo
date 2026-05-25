import 'package:flutter/widgets.dart';

/// Lets a parent surface provide the page title so nested screen headers can
/// avoid repeating it. Header widgets still render their actions.
class ConsoleHeaderVisibility extends InheritedWidget {
  const ConsoleHeaderVisibility({
    super.key,
    required this.suppressTitle,
    required super.child,
  });

  final bool suppressTitle;

  static bool suppressTitleOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<ConsoleHeaderVisibility>()
            ?.suppressTitle ??
        false;
  }

  @override
  bool updateShouldNotify(ConsoleHeaderVisibility oldWidget) {
    return suppressTitle != oldWidget.suppressTitle;
  }
}
