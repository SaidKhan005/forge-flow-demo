import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// One premium on/off switch pattern shared by BOTH consoles (admin +
/// operator-web).
///
/// A labeled row: a short label (key words first, describing the ON action)
/// with optional subcopy on the left, and a trailing [Switch] on the right.
/// The whole row keeps a comfortable >=44px tap target even though the visible
/// switch is smaller (NN/g toggle guidance), and dims when the control is
/// disabled so a read-only switch reads as inactive without looking broken.
///
/// Switch styling (accent ON, calm OFF, dimmed disabled) comes from the shared
/// [SwitchThemeData] in `AppTheme`, so this row never hand-sets switch colours.
///
/// The [switchKey] is forwarded onto the inner [Switch] itself (not a wrapper)
/// so existing widget tests that do `tester.widget<Switch>(find.byKey(...))`
/// and `find.byType(Switch)` keep working unchanged.
class ConsoleSwitchRow extends StatelessWidget {
  const ConsoleSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subcopy,
    this.switchKey,
    this.labelStyle,
    this.subcopyStyle,
    this.compact = false,
    this.maxLabelWidth,
  });

  /// Short label, key words first, describing what turning the switch ON does.
  final String label;

  /// Optional second line giving context for the toggle.
  final String? subcopy;

  /// Current on/off value.
  final bool value;

  /// Fired when the operator flips the switch. `null` renders the row disabled
  /// (dimmed label + inert switch), matching the underlying [Switch] contract.
  final ValueChanged<bool>? onChanged;

  /// Key placed directly on the inner [Switch] (preserves test finders).
  final Key? switchKey;

  /// Optional label style override (defaults to the shared body style).
  final TextStyle? labelStyle;

  /// Optional subcopy style override (defaults to the shared caption style).
  final TextStyle? subcopyStyle;

  /// When true the row sizes to its content (`MainAxisSize.min`) instead of
  /// stretching, for inline control strips (e.g. a header controls row).
  final bool compact;

  /// Optional cap on the label column width; the label ellipsizes past it.
  /// Useful inside a [Wrap] / narrow control strip so the row never overflows.
  final double? maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;
    final TextStyle resolvedLabelStyle =
        labelStyle ??
        AppTextStyles.body13(
          color: enabled ? AppColors.textPrimary : AppColors.textMuted,
        );
    final TextStyle resolvedSubcopyStyle =
        subcopyStyle ?? AppTextStyles.body12(color: AppColors.textSecondary);

    Widget labelColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: resolvedLabelStyle,
        ),
        if (subcopy != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(subcopy!, style: resolvedSubcopyStyle),
        ],
      ],
    );

    if (maxLabelWidth != null) {
      labelColumn = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLabelWidth!),
        child: labelColumn,
      );
    }

    final Widget labelSlot = compact
        ? Flexible(child: labelColumn)
        : Expanded(child: labelColumn);

    return ConstrainedBox(
      // >=44px target row even though the visible switch is smaller.
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          labelSlot,
          const SizedBox(width: 12),
          Switch(key: switchKey, value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Compact, vertical on/off cell shared by BOTH consoles' notification
/// preferences matrices (admin + operator-web): a short channel label stacked
/// over a [Switch].
///
/// This is the single shared form of the two near-identical private
/// `_ChannelToggle` classes that previously lived in
/// `lib/admin/screens/admin_notification_preferences_screen.dart` and
/// `lib/operator_web/screens/settings_notifications_screen.dart`. It keeps the
/// dense per-channel matrix layout (a label above a switch) rather than a wide
/// labeled row, which would not fit the per-event channel strip.
///
/// Colours come from the shared [SwitchThemeData]; [switchKey] is forwarded
/// onto the inner [Switch] so the per-console test keys keep resolving.
class ConsoleChannelToggle extends StatelessWidget {
  const ConsoleChannelToggle({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.switchKey,
  });

  /// Channel name shown above the switch (e.g. "Email", "Push Notifications").
  final String label;

  /// Current on/off value for this channel.
  final bool value;

  /// Fired when flipped. `null` renders the switch disabled (e.g. a
  /// "Coming soon" or "Always on" row).
  final ValueChanged<bool>? onChanged;

  /// Key placed directly on the inner [Switch] (preserves test finders).
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        Switch(key: switchKey, value: value, onChanged: onChanged),
      ],
    );
  }
}
