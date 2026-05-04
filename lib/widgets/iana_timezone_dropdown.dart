// Catalog-backed IANA timezone picker shared by admin/operator surfaces.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/iana_timezones.dart';

class IanaTimezoneDropdown extends StatelessWidget {
  const IanaTimezoneDropdown({
    super.key,
    this.fieldKey,
    required this.value,
    required this.onChanged,
    this.label = 'IANA timezone',
    this.enabled = true,
  });

  final Key? fieldKey;
  final String? value;
  final ValueChanged<String> onChanged;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final names = ianaTimezoneNames();
    final trimmedValue = value?.trim();
    final selectedValue = trimmedValue != null && names.contains(trimmedValue)
        ? trimmedValue
        : null;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );

    return DropdownButtonFormField<String>(
      key: fieldKey,
      initialValue: selectedValue,
      isExpanded: true,
      menuMaxHeight: 360,
      validator: _timezoneValidator,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        floatingLabelStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
        filled: true,
        fillColor: AppColors.backgroundSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sunset, width: 1.6),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final name in names)
          DropdownMenuItem<String>(
            value: name,
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
      ],
      onChanged: enabled
          ? (newValue) {
              if (newValue != null) onChanged(newValue);
            }
          : null,
    );
  }
}

String? _timezoneValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  if (!isValidIanaTimezoneName(value)) {
    return 'Use an IANA name like America/Toronto';
  }
  return null;
}
