// Phase 7.55o.5 — Baseline Manager action bars.
// A9.SY1 — Done button now uses ConnectivityRequiredButton so the star
// target write is blocked with an explicit "Requires connection" label
// when the device is offline.
//
// Clear All bar and the bottom Cancel / Done bar. Extracted from
// baseline_manager_screen.dart. Callback wiring, copy, and disabled
// states are unchanged; the parent still owns the actual state
// transitions.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/connectivity_required_button.dart';

// ─── Clear All bar ────────────────────────────────────────────────────────────

class ClearAllBar extends StatelessWidget {
  final VoidCallback onClearAll;

  const ClearAllBar({super.key, required this.onClearAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          onTap: onClearAll,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.sunset, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'CLEAR ALL',
              style: AppTextStyles.mono8(color: AppColors.sunset),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Bottom action bar ─────────────────────────────────────────────────────────

class BottomBar extends StatelessWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onDone;

  const BottomBar({
    super.key,
    required this.onCancel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          // Cancel
          Expanded(
            child: GestureDetector(
              onTap: onCancel,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                alignment: Alignment.center,
                child: Text('CANCEL',
                    style: AppTextStyles.mono8(color: AppColors.textMuted)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Done — gated on connectivity (A9.SY1). Empty draft still
          // routes through _done() which clears the override server-side
          // only when online; offline taps are blocked.
          Expanded(
            flex: 2,
            child: ConnectivityRequiredButton(
              label: 'DONE',
              onPressed: () => onDone(),
            ),
          ),
        ],
      ),
    );
  }
}
