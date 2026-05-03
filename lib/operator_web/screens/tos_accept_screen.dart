// Phase 11W.0 — T&Cs click-through screen.
//
// Step 4 of the onboarding click path. Renders the universal
// inbound-vendor T&Cs from `tos_versions` (Phase 9.8 schema), gates
// the Continue button on the operator checking the agreement box, and
// writes a row to `tos_acceptances` (operator_id + user_id +
// version_id + scope) on submit.
//
// UX writing standard:
//
//   * Plain English summary above the legal text so the operator
//     understands the gist without reading the whole body.
//   * Scrollable region so the body markdown doesn't push the
//     Continue affordance off the screen.
//   * Plain English remediation copy if the version changed during
//     the session.

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';
import 'shared/onboarding_layout.dart';

/// T&Cs click-through surface. Renders when the auth source is in
/// [OperatorWebAcceptingTos].
class TosAcceptScreen extends StatefulWidget {
  const TosAcceptScreen({
    super.key,
    required this.session,
    required this.tosVersion,
    required this.tosBodyMarkdown,
    required this.onAccept,
    this.errorMessage,
    this.submitting = false,
  });

  final OperatorWebSession session;
  final TosVersion tosVersion;
  final String tosBodyMarkdown;

  /// Called when the operator presses Continue with the box checked.
  /// Writes a `tos_acceptances` row.
  final Future<void> Function({
    required String versionId,
    required String scope,
  })
  onAccept;

  final String? errorMessage;
  final bool submitting;

  @override
  State<TosAcceptScreen> createState() => _TosAcceptScreenState();
}

class _TosAcceptScreenState extends State<TosAcceptScreen> {
  bool _checked = false;
  String? _localError;

  Future<void> _submit() async {
    if (widget.submitting) return;
    if (!_checked) {
      setState(() {
        _localError =
            'Please tick the "I agree" box to continue. You can keep '
            'reading the terms above first if you need to.';
      });
      return;
    }
    setState(() => _localError = null);
    await widget.onAccept(
      versionId: widget.tosVersion.versionId,
      scope: widget.tosVersion.scope,
    );
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingLayout(
      stepLabel: 'Step 4 of 4 — Authorize data access',
      title: 'Authorize Forge & Flow to read your business data',
      subtitle:
          'Forge & Flow needs your permission to connect to your existing '
          'POS, reservation, and scheduling systems. Read the summary, then '
          'tick the box to continue.',
      errorMessage: _localError ?? widget.errorMessage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _PlainEnglishSummary(business: widget.session.businessName),
          const SizedBox(height: 18),
          _TosScrollPanel(body: widget.tosBodyMarkdown),
          const SizedBox(height: 14),
          _AgreementCheckbox(
            checked: _checked,
            enabled: !widget.submitting,
            onChanged: (value) => setState(() {
              _checked = value;
              if (value) _localError = null;
            }),
            business: widget.session.businessName,
          ),
          const SizedBox(height: 14),
          _SubmitButton(
            label: 'Continue to Forge & Flow',
            submitting: widget.submitting,
            onPressed: widget.submitting ? null : _submit,
          ),
          const SizedBox(height: 14),
          _VersionFooter(version: widget.tosVersion),
        ],
      ),
    );
  }
}

class _PlainEnglishSummary extends StatelessWidget {
  const _PlainEnglishSummary({required this.business});

  final String business;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_tos_summary'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'In plain English',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          Text(
            'You are giving Forge & Flow permission to read sales, '
            'reservation, and labor data for $business when you connect '
            'each system. We store the data in a secure database to power '
            'the Forge & Flow product. We never write back to your '
            'systems, never sell the data, and we will delete it within '
            '30 days of your written request.',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            'You can revoke this authorization any time from Settings → '
            'Account → Privacy. The full legal text is below.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _TosScrollPanel extends StatelessWidget {
  const _TosScrollPanel({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_tos_body_panel'),
      height: 220,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: SelectableText(
            body,
            key: const Key('operator_web_tos_body'),
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

class _AgreementCheckbox extends StatelessWidget {
  const _AgreementCheckbox({
    required this.checked,
    required this.enabled,
    required this.onChanged,
    required this.business,
  });

  final bool checked;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final String business;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!checked) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              key: const Key('operator_web_tos_agreement_checkbox'),
              value: checked,
              onChanged: enabled ? (v) => onChanged(v ?? false) : null,
              activeColor: AppColors.sunsetDark,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'I have read and agree to the Forge & Flow Terms of '
                  'Service, Privacy Policy, and the data-access '
                  'authorization on behalf of $business.',
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.label,
    required this.submitting,
    required this.onPressed,
  });

  final String label;
  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        key: const Key('operator_web_tos_submit'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.sunset,
          foregroundColor: AppColors.backgroundSurface,
          disabledBackgroundColor: AppColors.sunset.withValues(alpha: 0.55),
          disabledForegroundColor: AppColors.backgroundSurface.withValues(
            alpha: 0.85,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: AppTextStyles.mono14(
            color: AppColors.backgroundSurface,
            weight: FontWeight.w600,
          ),
        ),
        child: submitting
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.backgroundSurface,
                ),
              )
            : Text(label),
      ),
    );
  }
}

class _VersionFooter extends StatelessWidget {
  const _VersionFooter({required this.version});

  final TosVersion version;

  @override
  Widget build(BuildContext context) {
    final formatted = _formatDate(version.effectiveDate);
    return Text(
      'Terms version ${version.versionNumber} • Effective $formatted',
      key: const Key('operator_web_tos_version_footer'),
      style: AppTextStyles.body12(color: AppColors.textMuted),
    );
  }

  String _formatDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}
