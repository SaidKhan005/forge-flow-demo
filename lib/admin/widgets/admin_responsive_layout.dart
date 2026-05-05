import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

const double kAdminMasterDetailBreakpoint = 720;
const double kAdminDefaultMasterWidth = 280;
const double kAdminDefaultCompactMasterHeight = 220;

class AdminMasterDetailLayout extends StatelessWidget {
  const AdminMasterDetailLayout({
    super.key,
    required this.master,
    required this.detail,
    this.masterWidth = kAdminDefaultMasterWidth,
    this.compactMasterHeight = kAdminDefaultCompactMasterHeight,
    this.breakpoint = kAdminMasterDetailBreakpoint,
    this.gap = 16,
  });

  final Widget master;
  final Widget detail;
  final double masterWidth;
  final double compactMasterHeight;
  final double breakpoint;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < breakpoint;
        if (compact) {
          final boundedHeight = constraints.maxHeight.isFinite
              ? constraints.maxHeight
              : compactMasterHeight + gap + 240;
          final masterHeight = math.min(
            compactMasterHeight,
            math.max(96.0, (boundedHeight - gap) * 0.45),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: masterHeight, child: master),
              SizedBox(height: gap),
              Expanded(child: detail),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: masterWidth, child: master),
            SizedBox(width: gap),
            Expanded(child: detail),
          ],
        );
      },
    );
  }
}

class AdminPageHeader extends StatelessWidget {
  const AdminPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.compactBreakpoint = 560,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;
  final double compactBreakpoint;

  @override
  Widget build(BuildContext context) {
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          style: AppTextStyles.pageTitle(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
    final action = trailing;
    if (action == null) return titleBlock;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < compactBreakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [titleBlock, const SizedBox(height: 10), action],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: titleBlock),
            const SizedBox(width: 12),
            action,
          ],
        );
      },
    );
  }
}

class AdminCard extends StatelessWidget {
  const AdminCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: AppColors.textPrimary.withValues(alpha: 0.035),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

class AdminDetailRow extends StatelessWidget {
  const AdminDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 160,
    this.muted = false,
  });

  final String label;
  final String value;
  final double labelWidth;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < labelWidth + 220;
          final labelText = Text(
            label,
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          );
          final valueText = Text(
            value,
            style: AppTextStyles.body14(color: AppColors.textPrimary),
            overflow: TextOverflow.ellipsis,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelText, const SizedBox(height: 2), valueText],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: labelWidth, child: labelText),
              Expanded(child: valueText),
            ],
          );
        },
      ),
    );
    if (!muted) return row;
    return Opacity(opacity: 0.45, child: row);
  }
}
