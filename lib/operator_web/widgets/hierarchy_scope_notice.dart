// Wave 2 H-1 — Reusable hierarchy-scope notice for operator-web screens.
//
// Hard Promise #11 (`CLAUDE.md`) requires every settings, roles, timing,
// pricing, accuracy, security, and support surface to show:
//
//   * Selected scope        — which level of the hierarchy this value is
//                             set at (Business / Region / Brand /
//                             Location, etc.).
//   * Inherited source      — when the current scope does not carry its
//                             own value, which higher scope supplied it.
//   * Effective value       — the value that actually applies after
//                             inheritance is walked.
//
// Six other operator-web surfaces already implement this triple field-
// by-field with real inheritance data (Business setup, Business timing
// editor, Settings notifications, Admin timing setup, Admin audit log,
// Data accuracy explainer). Two surfaces — Schedule and Wage Authority
// — read from per-(operator, location) fact tables (`weekly_plan_
// snapshot` + `wage_role_rows`) whose data layer does not yet carry
// per-field inheritance metadata. Until the inheritance backbone lands
// for those tables (tracked as a future-wave deliverable), HP #11 is
// honored on those screens by:
//
//   1. Rendering a top-of-screen scope notice that names the selected
//      scope, the inherited source (or "no inheritance" when none),
//      and the effective value summary in plain English.
//   2. Marking each editable field that is hierarchy-eligible-but-not-
//      yet-inheritance-aware with an inline backend-only carve-out
//      label inside this notice.
//
// This widget renders the notice. It is intentionally non-interactive;
// it does not change the value, it only explains the scope discipline.
// Once per-field inheritance lands for these surfaces the notice
// degrades to a quiet badge alongside each field — see
// `business_setup_screen.dart`'s `_InheritanceCard` / `_EffectiveFieldRow`
// for the long-term shape.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label, status, and copy line reads as training. Plain English.
// No engineering jargon (no scope_id=…, no inherited_from=null).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'operator_web_info_button.dart';
import 'operator_web_section_heading.dart';

/// Hierarchy level at which the screen's values are currently scoped.
/// Maps to the operator's `hierarchy_path` ltree depth on the proxy
/// side; the wire labels stay plain-English here.
enum HierarchyScopeLevel { business, region, brand, location }

extension on HierarchyScopeLevel {
  String get label {
    switch (this) {
      case HierarchyScopeLevel.business:
        return 'Business';
      case HierarchyScopeLevel.region:
        return 'Region';
      case HierarchyScopeLevel.brand:
        return 'Brand';
      case HierarchyScopeLevel.location:
        return 'Location';
    }
  }
}

/// Plain-English explanation of where a screen's settings come from.
///
/// All copy passes the UX writing standard: no `scope_id`, no
/// `inherited_from=null` jargon. The operator sees full sentences a
/// new hire can read on day one.
class HierarchyScopeNotice extends StatelessWidget {
  const HierarchyScopeNotice({
    super.key,
    required this.keyName,
    required this.selectedScope,
    required this.scopeName,
    required this.effectiveValueSummary,
    this.inheritedFromLabel,
    this.backendOnlyExplainer,
    this.backendOnlyHelpTitle,
    this.showBackendOnlyExplainer = true,
    this.showEffectiveValue = true,
  });

  /// Key prefix the widget stamps on its root container so screen tests
  /// can find it without colliding with sibling notices.
  final String keyName;

  /// Which level of the hierarchy the screen's values are currently
  /// scoped to. Schedule + Wage Authority are both location-scoped
  /// today; future waves may add region / brand rollups.
  final HierarchyScopeLevel selectedScope;

  /// Name of the scope target — the location name when the selected
  /// scope is `location`, the region name for `region`, etc. Renders
  /// verbatim, so callers pass the operator-facing display name.
  final String scopeName;

  /// Plain-English summary of what the operator is looking at on this
  /// screen, e.g. "this week's locked plan" / "the wage rows your team
  /// is paid against".
  final String effectiveValueSummary;

  /// When the screen reads a value inherited from a higher scope, name
  /// that source here (e.g. "Inherits the corporate wage floor from
  /// Business"). Pass null when no inheritance applies — the notice
  /// then renders the "set here, does not inherit" line.
  final String? inheritedFromLabel;

  /// When the data layer cannot yet expose per-field inheritance for
  /// this surface, pass a future-wave explainer here. The notice
  /// renders the explainer in a disabled-state row so the operator
  /// sees the gap explicitly instead of a silent omission. See HP #11
  /// final clause ("or document why the capability is backend-only /
  /// gated / incomplete").
  final String? backendOnlyExplainer;

  /// Optional heading help title for the backend-only explainer.
  final String? backendOnlyHelpTitle;

  /// Whether to show the backend-only explainer inline below the scope rows.
  final bool showBackendOnlyExplainer;

  /// Whether to show the effective value row inside the notice.
  final bool showEffectiveValue;

  @override
  Widget build(BuildContext context) {
    final inheritedLabel = inheritedFromLabel;
    final backendOnly = backendOnlyExplainer;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 360;
        final helpButton = backendOnly != null && backendOnlyHelpTitle != null
            ? OperatorWebInfoButton(
                key: Key('${keyName}_backend_only_help'),
                title: backendOnlyHelpTitle!,
                tooltip: backendOnlyHelpTitle!,
                body: Text(
                  backendOnly,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              )
            : null;
        return Container(
          key: Key(keyName),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: AppColors.cardGlow,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              OperatorWebSectionHeading(
                title: 'Hierarchy scope',
                trailing: compact
                    ? helpButton
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (helpButton != null) ...[
                            helpButton,
                            const SizedBox(width: 8),
                          ],
                          _ScopePill(
                            keyName: '${keyName}_scope_pill',
                            label: selectedScope.label,
                          ),
                        ],
                      ),
              ),
              if (compact) ...[
                const SizedBox(height: 8),
                _ScopePill(
                  keyName: '${keyName}_scope_pill',
                  label: selectedScope.label,
                ),
              ],
              const SizedBox(height: 12),
              _NoticeRow(
                keyName: '${keyName}_selected_row',
                label: 'Selected scope',
                value: '${selectedScope.label}: $scopeName',
              ),
              const SizedBox(height: 6),
              _NoticeRow(
                keyName: '${keyName}_inherited_row',
                label: 'Inherited from',
                value:
                    inheritedLabel ??
                    'Set here. Does not inherit from a higher scope.',
                muted: inheritedLabel == null,
              ),
              if (showEffectiveValue) ...<Widget>[
                const SizedBox(height: 6),
                _NoticeRow(
                  keyName: '${keyName}_effective_row',
                  label: 'Effective value',
                  value: effectiveValueSummary,
                ),
              ],
              if (backendOnly != null && showBackendOnlyExplainer) ...<Widget>[
                const SizedBox(height: 10),
                _BackendOnlyExplainer(
                  keyName: '${keyName}_backend_only',
                  message: backendOnly,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ScopePill extends StatelessWidget {
  const _ScopePill({required this.keyName, required this.label});

  final String keyName;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sunsetDark.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.sunsetDark.withValues(alpha: 0.42),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: AppColors.sunsetDark),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.keyName,
    required this.label,
    required this.value,
    this.muted = false,
  });

  final String keyName;
  final String label;
  final String value;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        final valueText = Text(
          value,
          style: AppTextStyles.body13(
            color: muted ? AppColors.textSecondary : AppColors.textPrimary,
          ),
        );
        if (compact) {
          return Column(
            key: Key(keyName),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
              const SizedBox(height: 2),
              valueText,
            ],
          );
        }
        return Row(
          key: Key(keyName),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 132,
              child: Text(
                label,
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: valueText),
          ],
        );
      },
    );
  }
}

class _BackendOnlyExplainer extends StatelessWidget {
  const _BackendOnlyExplainer({required this.keyName, required this.message});

  final String keyName;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.engineering_outlined,
            size: 14,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
