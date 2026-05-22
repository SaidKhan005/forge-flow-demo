import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'console_section_heading.dart';

enum OperatorWebPanelTone { surface, highlight }

enum OperatorWebBannerTone { neutral, success, warning, error }

class OperatorWebPanel extends StatelessWidget {
  const OperatorWebPanel({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
    this.tone = OperatorWebPanelTone.surface,
    this.padding = const EdgeInsets.all(18),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final OperatorWebPanelTone tone;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: _panelDecoration(tone),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OperatorWebSectionHeading(title: title, trailing: trailing),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                subtitle!,
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  static BoxDecoration _panelDecoration(OperatorWebPanelTone tone) {
    return BoxDecoration(
      color: tone == OperatorWebPanelTone.highlight
          ? AppColors.cardGlow
          : AppColors.backgroundSurface,
      border: Border.all(color: AppColors.borderSubtle, width: 1),
      borderRadius: BorderRadius.circular(8),
    );
  }
}

class OperatorWebBanner extends StatelessWidget {
  const OperatorWebBanner({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.tone = OperatorWebBannerTone.neutral,
    this.action,
  });

  final String? title;
  final String message;
  final IconData? icon;
  final OperatorWebBannerTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = _OperatorWebBannerColors.forTone(tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        border: Border.all(color: colors.border, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon ?? colors.icon, size: 18, color: colors.foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (title != null) ...<Widget>[
                    Text(
                      title!,
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                    const SizedBox(height: 2),
                  ],
                  Text(
                    message,
                    style: AppTextStyles.body13(
                      color: title == null
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (action != null) ...<Widget>[const SizedBox(width: 12), action!],
          ],
        ),
      ),
    );
  }
}

class OperatorWebDialog extends StatelessWidget {
  const OperatorWebDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
    this.icon,
    this.maxWidth = 460,
    this.showCloseButton = true,
    this.onClose,
  });

  final String title;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;
  final double maxWidth;
  final bool showCloseButton;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (icon != null) ...<Widget>[
                      Icon(icon, size: 20, color: AppColors.sunsetDark),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        style: AppTextStyles.display20(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (showCloseButton)
                      SizedBox(
                        width: 42,
                        height: 42,
                        child: IconButton(
                          key: const Key('operator_web_dialog_close'),
                          tooltip: 'Close',
                          onPressed:
                              onClose ?? () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.close,
                            size: 22,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                child,
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 10,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Title row for a popup body with a persistent, comfortably-sized
/// top-right close affordance. Use inside bare [Dialog] bodies that are
/// not yet migrated to [OperatorWebDialog] so every operator-facing
/// popup still offers one consistent close control, without re-inlining
/// the row (and inflating the host build method) at each call site.
class OperatorWebDialogHeader extends StatelessWidget {
  const OperatorWebDialogHeader({
    super.key,
    required this.title,
    this.onClose,
    this.closeKey,
  });

  final String title;
  final VoidCallback? onClose;
  final Key? closeKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            title,
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
        SizedBox(
          width: 42,
          height: 42,
          child: IconButton(
            key: closeKey,
            tooltip: 'Close',
            onPressed: onClose,
            icon: const Icon(
              Icons.close,
              size: 22,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

Future<T?> showOperatorWebDialog<T>({
  required BuildContext context,
  required String title,
  required Widget child,
  required List<Widget> actions,
  IconData? icon,
  double maxWidth = 460,
}) {
  return showDialog<T>(
    context: context,
    builder: (_) => OperatorWebDialog(
      title: title,
      icon: icon,
      maxWidth: maxWidth,
      actions: actions,
      child: child,
    ),
  );
}

Future<DateTimeRange?> showOperatorWebDateRangeDialog({
  required BuildContext context,
  required DateTimeRange initialRange,
  required DateTime firstDate,
  required DateTime lastDate,
  String title = 'Choose date range',
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (_) => OperatorWebDateRangeDialog(
      title: title,
      initialRange: initialRange,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

class OperatorWebDateRangeDialog extends StatefulWidget {
  const OperatorWebDateRangeDialog({
    super.key,
    required this.initialRange,
    required this.firstDate,
    required this.lastDate,
    this.title = 'Choose date range',
  });

  final String title;
  final DateTimeRange initialRange;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<OperatorWebDateRangeDialog> createState() =>
      _OperatorWebDateRangeDialogState();
}

class _OperatorWebDateRangeDialogState
    extends State<OperatorWebDateRangeDialog> {
  late DateTime _start = _dateOnly(widget.initialRange.start);
  late DateTime _end = _dateOnly(widget.initialRange.end);

  bool get _isValid => !_end.isBefore(_start);

  Future<void> _pickStart() async {
    final picked = await _pickDate(_start);
    if (picked == null) return;
    setState(() {
      _start = picked;
      if (_end.isBefore(_start)) _end = _start;
    });
  }

  Future<void> _pickEnd() async {
    final picked = await _pickDate(_end);
    if (picked == null) return;
    setState(() => _end = picked);
  }

  Future<DateTime?> _pickDate(DateTime initial) {
    return showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: widget.firstDate,
      lastDate: widget.lastDate,
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      title: widget.title,
      icon: Icons.date_range_outlined,
      maxWidth: 430,
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isValid
              ? () => Navigator.of(
                  context,
                ).pop(DateTimeRange(start: _start, end: _end))
              : null,
          child: const Text('Apply'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _DateRangeField(
            label: 'Start',
            value: _formatDate(_start),
            onPressed: _pickStart,
          ),
          const SizedBox(height: 10),
          _DateRangeField(
            label: 'End',
            value: _formatDate(_end),
            onPressed: _pickEnd,
          ),
          if (!_isValid) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'End date must be after the start date.',
              style: AppTextStyles.body12(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }
}

class _DateRangeField extends StatelessWidget {
  const _DateRangeField({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final String value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppTextStyles.uiLabel(color: AppColors.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
          const Icon(Icons.calendar_today_outlined, size: 16),
        ],
      ),
    );
  }
}

class _OperatorWebBannerColors {
  const _OperatorWebBannerColors({
    required this.background,
    required this.border,
    required this.foreground,
    required this.icon,
  });

  final Color background;
  final Color border;
  final Color foreground;
  final IconData icon;

  static _OperatorWebBannerColors forTone(OperatorWebBannerTone tone) {
    return switch (tone) {
      OperatorWebBannerTone.success => _OperatorWebBannerColors(
        background: AppColors.positive.withValues(alpha: 0.08),
        border: AppColors.positive.withValues(alpha: 0.32),
        foreground: AppColors.positive,
        icon: Icons.check_circle_outline,
      ),
      OperatorWebBannerTone.warning => _OperatorWebBannerColors(
        background: AppColors.warning.withValues(alpha: 0.10),
        border: AppColors.warning.withValues(alpha: 0.36),
        foreground: AppColors.warning,
        icon: Icons.warning_amber_outlined,
      ),
      OperatorWebBannerTone.error => _OperatorWebBannerColors(
        background: AppColors.negative.withValues(alpha: 0.08),
        border: AppColors.negative.withValues(alpha: 0.32),
        foreground: AppColors.negative,
        icon: Icons.error_outline,
      ),
      OperatorWebBannerTone.neutral => const _OperatorWebBannerColors(
        background: AppColors.backgroundSurface,
        border: AppColors.borderSubtle,
        foreground: AppColors.textMuted,
        icon: Icons.info_outline,
      ),
    };
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

String _formatDate(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
