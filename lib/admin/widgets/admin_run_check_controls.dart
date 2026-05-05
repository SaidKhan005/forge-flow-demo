import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import 'admin_responsive_layout.dart';

@immutable
class AdminRunCheckFact {
  const AdminRunCheckFact({
    required this.icon,
    required this.label,
    required this.text,
  });

  final IconData icon;
  final String label;
  final String text;
}

class AdminRunCheckButton extends StatelessWidget {
  const AdminRunCheckButton({
    super.key,
    required this.label,
    required this.loadingLabel,
    required this.icon,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final String loadingLabel;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: loading ? null : onPressed,
      style: AdminButtonStyles.secondary(
        minWidth: 172,
        minHeight: 40,
        emphasized: true,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(loading ? loadingLabel : label),
    );
  }
}

class AdminRunCheckPrompt extends StatelessWidget {
  const AdminRunCheckPrompt({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.facts,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<AdminRunCheckFact> facts;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final prompt = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: _PromptCard(
              icon: icon,
              title: title,
              description: description,
              facts: facts,
              buttonLabel: buttonLabel,
              onPressed: onPressed,
            ),
          ),
        );
        if (!constraints.maxHeight.isFinite) return prompt;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: (constraints.maxHeight - 24)
                  .clamp(0, double.infinity)
                  .toDouble(),
            ),
            child: prompt,
          ),
        );
      },
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.facts,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<AdminRunCheckFact> facts;
  final String buttonLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RunCheckIconBadge(icon: icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      description,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _RunCheckFactPanel(facts: facts),
          const SizedBox(height: 18),
          AdminRunCheckButton(
            label: buttonLabel,
            loadingLabel: 'Running...',
            icon: icon,
            loading: false,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }
}

class AdminRunCheckConfirmDialog extends StatelessWidget {
  const AdminRunCheckConfirmDialog({
    super.key,
    required this.dialogKey,
    required this.cancelButtonKey,
    required this.confirmButtonKey,
    required this.icon,
    required this.title,
    required this.description,
    required this.facts,
    required this.confirmLabel,
  });

  final Key dialogKey;
  final Key cancelButtonKey;
  final Key confirmButtonKey;
  final IconData icon;
  final String title;
  final String description;
  final List<AdminRunCheckFact> facts;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: dialogKey,
      scrollable: true,
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 14, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RunCheckIconBadge(icon: icon, compact: true),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: AppTextStyles.display20(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              description,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            _RunCheckFactPanel(facts: facts),
          ],
        ),
      ),
      actions: [
        OutlinedButton(
          key: cancelButtonKey,
          onPressed: () => Navigator.of(context).pop(false),
          style: AdminButtonStyles.secondary(minWidth: 92, minHeight: 40),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: confirmButtonKey,
          onPressed: () => Navigator.of(context).pop(true),
          style: AdminButtonStyles.primary,
          icon: const Icon(Icons.play_arrow, size: 16),
          label: Text(confirmLabel),
        ),
      ],
    );
  }
}

class _RunCheckIconBadge extends StatelessWidget {
  const _RunCheckIconBadge({required this.icon, this.compact = false});

  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 44.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.sunset.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: compact ? 18 : 20, color: AppColors.sunsetDark),
    );
  }
}

class _RunCheckFactPanel extends StatelessWidget {
  const _RunCheckFactPanel({required this.facts});

  final List<AdminRunCheckFact> facts;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid.withValues(alpha: 0.55),
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < facts.length; index++) ...[
            _RunCheckFactRow(fact: facts[index]),
            if (index < facts.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _RunCheckFactRow extends StatelessWidget {
  const _RunCheckFactRow({required this.fact});

  final AdminRunCheckFact fact;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(fact.icon, size: 16, color: AppColors.sunsetDark),
        const SizedBox(width: 10),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: AppTextStyles.body13(color: AppColors.textSecondary),
              children: [
                TextSpan(
                  text: '${fact.label}: ',
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                TextSpan(text: fact.text),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
