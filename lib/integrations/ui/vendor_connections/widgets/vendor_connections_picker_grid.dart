// Phase 8.0 / Wave C1 — Vendor catalog picker grid + card + title +
// selected-panel widgets for the shared Vendor Connections widget
// tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable. Splits the stateless catalog chrome
// out of the picker dialog so the dialog file stays focused on the
// stateful selection seam.

part of '../vendor_connections_widget.dart';

class _VendorPickerTitle extends StatelessWidget {
  const _VendorPickerTitle({
    required this.category,
    required this.title,
    required this.count,
  });

  final VendorCategory category;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _CategoryIcon(category: category, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title),
              const SizedBox(height: 3),
              Text(
                '$count available vendor options',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VendorPickerGrid extends StatelessWidget {
  const _VendorPickerGrid({
    required this.entries,
    required this.pickedVendorId,
    required this.summaryFor,
    required this.tagsFor,
    required this.onPick,
  });

  final List<VendorPickerEntry> entries;
  final String? pickedVendorId;
  final String Function(VendorPickerEntry entry) summaryFor;
  final List<String> Function(VendorPickerEntry entry) tagsFor;
  final ValueChanged<VendorPickerEntry> onPick;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 680 ? 2 : 1;
        const spacing = 10.0;
        final width =
            (constraints.maxWidth - (spacing * (columns - 1))) / columns;
        return Wrap(
          key: const Key('vendor_connections_picker_grid'),
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final entry in entries)
              SizedBox(
                width: width,
                child: _VendorPickerCard(
                  key: Key(
                    'vendor_connections_picker_choice_${entry.vendorId}',
                  ),
                  entry: entry,
                  subtitle: summaryFor(entry),
                  tags: tagsFor(entry),
                  selected: entry.vendorId == pickedVendorId,
                  onTap: () => onPick(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VendorPickerCard extends StatelessWidget {
  const _VendorPickerCard({
    super.key,
    required this.entry,
    required this.subtitle,
    required this.tags,
    required this.selected,
    required this.onTap,
  });

  final VendorPickerEntry entry;
  final String subtitle;
  final List<String> tags;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.sunset : AppColors.borderSubtle;
    return Material(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.08)
          : AppColors.backgroundSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor, width: selected ? 1.4 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _VendorLogo(
                    vendorId: entry.vendorId,
                    displayName: entry.displayName,
                    size: 54,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          entry.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.sectionTitle(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _categoryLabel(entry.category),
                          style: AppTextStyles.chipLabel(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected
                        ? AppColors.sunsetDark
                        : AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              if (tags.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final tag in tags)
                      _StatusChip(label: tag, color: _tagColor(tag)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _categoryLabel(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'POS system';
      case VendorCategory.labor:
        return 'Scheduling and labor';
      case VendorCategory.reservation:
        return 'Reservations';
    }
  }

  Color _tagColor(String tag) {
    return tag == 'Coming soon' || tag == 'Sandbox verified'
        ? AppColors.textMuted
        : AppColors.peacockDark;
  }
}

class _SelectedVendorPanel extends StatelessWidget {
  const _SelectedVendorPanel({
    required this.entry,
    required this.canContinue,
    required this.reason,
  });

  final VendorPickerEntry entry;
  final bool canContinue;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final color = canContinue ? AppColors.positive : AppColors.warning;
    return Container(
      key: const Key('vendor_connections_picker_selected_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _VendorLogo(
            vendorId: entry.vendorId,
            displayName: entry.displayName,
            size: 44,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  canContinue ? 'Ready to continue' : 'Not ready to connect',
                  style: AppTextStyles.sectionTitle(color: color),
                ),
                const SizedBox(height: 4),
                Text(
                  reason,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
