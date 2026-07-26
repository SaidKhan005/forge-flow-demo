// Shell-level MediaQuery override for the Barrio text-size stepper
// (accessibility pass, rec #12, 2026-07-24).
//
// Mounted once by BarrioApp's MaterialApp.builder, so every Barrio
// route (home shelf, readers, sheets, viewers) sees the composed
// scaler. The multiplier composes with the system setting (see the
// composition contract in ../services/barrio_text_size.dart); at the
// Standard step the MediaQuery passes through byte-identical, so
// existing layouts and tests see no change.

import 'package:flutter/material.dart';

import '../services/barrio_text_size.dart';

/// Applies the persisted Barrio text-size step on top of the system
/// text scaler for everything below it.
class BarrioTextScale extends StatefulWidget {
  final Widget child;

  const BarrioTextScale({super.key, required this.child});

  @override
  State<BarrioTextScale> createState() => _BarrioTextScaleState();
}

class _BarrioTextScaleState extends State<BarrioTextScale> {
  @override
  void initState() {
    super.initState();
    // Fire and forget: the notifier rebuilds us when the stored step
    // arrives (first frame renders Standard, the honest default).
    BarrioTextSizeController.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<BarrioTextSize>(
      valueListenable: BarrioTextSizeController.notifier,
      builder: (context, size, _) {
        if (size.multiplier == 1.0) return widget.child;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: BarrioComposedTextScaler(
              system: media.textScaler,
              multiplier: size.multiplier,
            ),
          ),
          child: widget.child,
        );
      },
    );
  }
}
