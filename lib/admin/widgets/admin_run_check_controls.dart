import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_action_bar.dart';
import '../../widgets/console/console_surface.dart';
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

class AdminRefreshHeaderActions extends StatelessWidget {
  const AdminRefreshHeaderActions({
    super.key,
    required this.statusText,
    required this.buttonKey,
    required this.buttonLabel,
    required this.loadingLabel,
    required this.icon,
    required this.loading,
    required this.onPressed,
    this.statusKey,
    this.leading = const <Widget>[],
    this.badges = const <Widget>[],
    this.maxWidth = 520,
  });

  final String statusText;
  final Key? statusKey;
  final Key buttonKey;
  final String buttonLabel;
  final String loadingLabel;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;
  final List<Widget> leading;
  final List<Widget> badges;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (badges.isNotEmpty) ...<Widget>[
            OperatorWebActionBar(spacing: 8, runSpacing: 6, children: badges),
            const SizedBox(height: 6),
          ],
          OperatorWebActionBar(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ...leading,
              AdminRunCheckButton(
                key: buttonKey,
                label: buttonLabel,
                loadingLabel: loadingLabel,
                icon: icon,
                loading: loading,
                onPressed: onPressed,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            statusText,
            key: statusKey,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

@immutable
class AdminRunCheckCue {
  const AdminRunCheckCue({required this.icon, required this.label});

  final IconData icon;
  final String label;
}

class AdminRunCheckLaunchPanel extends StatelessWidget {
  const AdminRunCheckLaunchPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.buttonKey,
    required this.buttonLabel,
    required this.loadingLabel,
    required this.loading,
    required this.onPressed,
    required this.cues,
    this.control,
  });

  final IconData icon;
  final String title;
  final String description;
  final Key buttonKey;
  final String buttonLabel;
  final String loadingLabel;
  final bool loading;
  final VoidCallback? onPressed;
  final List<AdminRunCheckCue> cues;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1600;
        final visual = _LaunchPanelIcon(icon: icon);
        final copy = _LaunchPanelCopy(
          title: title,
          description: description,
          cues: cues,
        );
        final actions = _LaunchPanelActions(
          control: control,
          button: AdminRunCheckButton(
            key: buttonKey,
            label: buttonLabel,
            loadingLabel: loadingLabel,
            icon: icon,
            loading: loading,
            onPressed: onPressed,
          ),
        );

        final children = wide
            ? <Widget>[
                visual,
                const SizedBox(width: 24),
                Expanded(child: copy),
                const SizedBox(width: 24),
                actions,
              ]
            : <Widget>[
                Center(child: visual),
                const SizedBox(height: 18),
                copy,
                const SizedBox(height: 18),
                actions,
              ];

        return Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 220),
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AppColors.textPrimary.withValues(alpha: 0.04),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: wide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: children,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: children,
                ),
        );
      },
    );
  }
}

class _LaunchPanelIcon extends StatelessWidget {
  const _LaunchPanelIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.sunset.withValues(alpha: 0.32)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.sunset.withValues(alpha: 0.45)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, size: 28, color: AppColors.sunsetDark),
        ),
      ),
    );
  }
}

class _LaunchPanelCopy extends StatelessWidget {
  const _LaunchPanelCopy({
    required this.title,
    required this.description,
    required this.cues,
  });

  final String title;
  final String description;
  final List<AdminRunCheckCue> cues;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          style: AppTextStyles.display28(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body15(color: AppColors.textSecondary),
        ),
        if (cues.isNotEmpty) ...<Widget>[
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final cue in cues) _LaunchPanelCue(cue: cue),
            ],
          ),
        ],
      ],
    );
  }
}

class _LaunchPanelCue extends StatelessWidget {
  const _LaunchPanelCue({required this.cue});

  final AdminRunCheckCue cue;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid.withValues(alpha: 0.55),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(cue.icon, size: 15, color: AppColors.sunsetDark),
          const SizedBox(width: 6),
          Text(
            cue.label,
            style: AppTextStyles.chipLabel(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _LaunchPanelActions extends StatelessWidget {
  const _LaunchPanelActions({required this.button, this.control});

  final Widget button;
  final Widget? control;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (control != null) ...<Widget>[control!, const SizedBox(height: 12)],
        button,
      ],
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
    return OperatorWebDialog(
      key: dialogKey,
      title: title,
      icon: icon,
      maxWidth: 520,
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
      child: SingleChildScrollView(
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
    );
  }
}

class _RunCheckIconBadge extends StatelessWidget {
  const _RunCheckIconBadge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    const size = 44.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.sunset.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 20, color: AppColors.sunsetDark),
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
