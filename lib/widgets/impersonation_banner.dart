// Phase 11W — Operator impersonation banner.
//
// Displays a slim red banner at the top of the operator-web and
// mobile apps when F&F support staff is signed in as an operator.
// The banner reads "F&F support is currently signed in as you" and
// provides a gentle visual cue that the session is under support
// observation.

import 'package:flutter/material.dart';

/// Global notifier for impersonation state. Defaults to `false`.
/// Can be updated by auth flows that detect F&F support delegation.
final impersonationStatusNotifier = ValueNotifier<bool>(false);

/// Displays a slim red banner when F&F support is signed in as the
/// operator.
///
/// Watches [impersonationStatusNotifier] and renders only when
/// impersonation is active.
class ImpersonationBanner extends StatelessWidget {
  const ImpersonationBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: impersonationStatusNotifier,
      builder: (context, isImpersonating, _) {
        if (!isImpersonating) {
          return const SizedBox.shrink();
        }

        return Container(
          width: double.infinity,
          color: Colors.red.shade700,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.info_outlined,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'F&F support is currently signed in as you',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
