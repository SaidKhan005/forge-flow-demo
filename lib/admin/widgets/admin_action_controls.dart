import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';

enum AdminActionRole { primary, secondary, quiet, danger, dangerSecondary }

class AdminActionBar extends StatelessWidget {
  const AdminActionBar({
    super.key,
    required this.children,
    this.alignment = WrapAlignment.end,
    this.spacing = AppSpacing.sm,
    this.runSpacing = AppSpacing.sm,
  });

  final List<Widget> children;
  final WrapAlignment alignment;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}

class AdminDialogActionBar extends StatelessWidget {
  const AdminDialogActionBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AdminActionBar(children: children);
  }
}

class AdminActionButton extends StatelessWidget {
  const AdminActionButton({
    Key? key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.role = AdminActionRole.secondary,
    this.compact = false,
    this.minWidth,
  }) : _controlKey = key,
       super(key: null);

  final Key? _controlKey;
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final AdminActionRole role;
  final bool compact;
  final double? minWidth;

  @override
  Widget build(BuildContext context) {
    final style = _styleForRole(role);
    final child = Text(label);
    if (icon == null) return _buttonForRole(style: style, child: child);
    return _buttonForRole(
      style: style,
      child: child,
      icon: Icon(icon, size: 16),
    );
  }

  Widget _buttonForRole({
    required ButtonStyle style,
    required Widget child,
    Widget? icon,
  }) {
    switch (role) {
      case AdminActionRole.primary:
      case AdminActionRole.danger:
        if (icon != null) {
          return FilledButton.icon(
            key: _controlKey,
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        return FilledButton(
          key: _controlKey,
          onPressed: onPressed,
          style: style,
          child: child,
        );
      case AdminActionRole.secondary:
      case AdminActionRole.dangerSecondary:
        if (icon != null) {
          return OutlinedButton.icon(
            key: _controlKey,
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        return OutlinedButton(
          key: _controlKey,
          onPressed: onPressed,
          style: style,
          child: child,
        );
      case AdminActionRole.quiet:
        if (icon != null) {
          return TextButton.icon(
            key: _controlKey,
            onPressed: onPressed,
            style: style,
            icon: icon,
            label: child,
          );
        }
        return TextButton(
          key: _controlKey,
          onPressed: onPressed,
          style: style,
          child: child,
        );
    }
  }

  ButtonStyle _styleForRole(AdminActionRole role) {
    final base = switch (role) {
      AdminActionRole.primary => AdminButtonStyles.primary,
      AdminActionRole.secondary => AdminButtonStyles.secondary(),
      AdminActionRole.quiet => AdminButtonStyles.text,
      AdminActionRole.danger => AdminButtonStyles.danger,
      AdminActionRole.dangerSecondary => AdminButtonStyles.dangerSecondary(),
    };
    final height = compact
        ? AdminButtonStyles.denseControlHeight
        : AdminButtonStyles.controlHeight;
    final width =
        minWidth ?? (compact ? 72 : AdminButtonStyles.defaultMinWidth);
    return base.copyWith(
      minimumSize: WidgetStatePropertyAll(Size(width, height)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: compact ? 12 : 16,
          vertical: compact ? 8 : 10,
        ),
      ),
    );
  }
}

class AdminIconAction extends StatelessWidget {
  const AdminIconAction({
    Key? key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.destructive = false,
  }) : _controlKey = key,
       super(key: null);

  final Key? _controlKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final style = destructive
        ? AdminButtonStyles.icon.copyWith(
            foregroundColor: const WidgetStatePropertyAll(AppColors.negative),
          )
        : AdminButtonStyles.icon;
    return IconButton(
      key: _controlKey,
      tooltip: tooltip,
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
    );
  }
}

class AdminMenuAction<T> {
  const AdminMenuAction({
    required this.value,
    required this.label,
    this.icon,
    this.destructive = false,
    this.enabled = true,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool destructive;
  final bool enabled;
}

class AdminOverflowMenu<T> extends StatelessWidget {
  const AdminOverflowMenu({
    super.key,
    required this.tooltip,
    required this.actions,
    required this.onSelected,
  });

  final String tooltip;
  final List<AdminMenuAction<T>> actions;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      icon: const Icon(Icons.more_horiz),
      onSelected: onSelected,
      itemBuilder: (context) {
        return <PopupMenuEntry<T>>[
          for (final action in actions)
            PopupMenuItem<T>(
              value: action.value,
              enabled: action.enabled,
              child: Row(
                children: <Widget>[
                  if (action.icon != null) ...<Widget>[
                    Icon(
                      action.icon,
                      size: 16,
                      color: action.destructive
                          ? AppColors.negative
                          : AppColors.textMuted,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  Expanded(
                    child: Text(
                      action.label,
                      style: AppTextStyles.buttonLabel(
                        color: action.destructive
                            ? AppColors.negative
                            : AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ];
      },
    );
  }
}
