import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../services/data_accuracy_admin_gateway.dart';

class PerVendorCadenceEditor extends StatefulWidget {
  const PerVendorCadenceEditor({
    super.key,
    required this.initialCadence,
    required this.onChanged,
    this.enabled = true,
  });

  final Map<String, int> initialCadence;
  final ValueChanged<Map<String, int>> onChanged;
  final bool enabled;

  @override
  State<PerVendorCadenceEditor> createState() => _PerVendorCadenceEditorState();
}

class _PerVendorCadenceEditorState extends State<PerVendorCadenceEditor> {
  // Per-vendor minimum cadence comes from
  // `kPollOnlyVendorMinCadenceSeconds` (Oracle = 300, others = 60).
  // Framework cap is `kPollCadenceMaxSeconds` = 3600s. Picker enforces
  // the floor so the resolver never has to clamp + emit a warning
  // sync-log row for an admin-driven override.
  int _minFor(String vendorId) =>
      kPollOnlyVendorMinCadenceSeconds[vendorId] ?? 60;

  late final Map<String, TextEditingController> _controllers;
  final Map<String, String?> _errors = <String, String?>{};

  @override
  void initState() {
    super.initState();
    _controllers = <String, TextEditingController>{
      for (final id in kPollOnlyVendorIds)
        id: TextEditingController(
          text: widget.initialCadence[id]?.toString() ?? '',
        ),
    };
  }

  @override
  void didUpdateWidget(covariant PerVendorCadenceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-seed only when the parent passes a structurally different
    // initial map; avoids fighting user edits during a single session.
    if (!_mapsShallowEqual(oldWidget.initialCadence, widget.initialCadence)) {
      for (final id in kPollOnlyVendorIds) {
        final next = widget.initialCadence[id]?.toString() ?? '';
        if (_controllers[id]!.text != next) {
          _controllers[id]!.text = next;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onFieldChanged(String vendorId, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() => _errors[vendorId] = null);
      _emit();
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null) {
      setState(() => _errors[vendorId] = 'Enter a whole number');
      return;
    }
    final min = _minFor(vendorId);
    if (parsed < min || parsed > kPollCadenceMaxSeconds) {
      setState(() => _errors[vendorId] =
          'Must be $min–$kPollCadenceMaxSeconds seconds');
      return;
    }
    setState(() => _errors[vendorId] = null);
    _emit();
  }

  void _emit() {
    final fresh = <String, int>{};
    for (final id in kPollOnlyVendorIds) {
      final raw = _controllers[id]!.text.trim();
      if (raw.isEmpty) continue;
      final parsed = int.tryParse(raw);
      if (parsed == null) continue;
      final min = _minFor(id);
      if (parsed < min || parsed > kPollCadenceMaxSeconds) continue;
      fresh[id] = parsed;
    }
    widget.onChanged(fresh);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_cadence_editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Polling cadence per vendor (seconds; per-vendor minimum, max $kPollCadenceMaxSeconds)',
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          for (final id in kPollOnlyVendorIds)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 200,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 14),
                      child: Text(
                        '${kPollOnlyVendorDisplayNames[id] ?? id} '
                        '(min ${_minFor(id)}s)',
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 160,
                    child: TextField(
                      key: Key('admin_cadence_field_$id'),
                      controller: _controllers[id],
                      enabled: widget.enabled,
                      readOnly: !widget.enabled,
                      keyboardType: TextInputType.number,
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: InputDecoration(
                        hintText: 'e.g. ${_minFor(id)}',
                        errorText: _errors[id],
                        isDense: true,
                        border: const OutlineInputBorder(),
                      ),
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                      ),
                      onChanged: (v) => _onFieldChanged(id, v),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static bool _mapsShallowEqual(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
