import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Small anchored help button for operator-web section headers and rows.
class OperatorWebInfoButton extends StatefulWidget {
  const OperatorWebInfoButton({
    super.key,
    required this.title,
    required this.tooltip,
    required this.body,
    this.showAbove = false,
    this.width = 320,
  });

  final String title;
  final String tooltip;
  final Widget body;
  final bool showAbove;
  final double width;

  @override
  State<OperatorWebInfoButton> createState() => _OperatorWebInfoButtonState();
}

class _OperatorWebInfoButtonState extends State<OperatorWebInfoButton> {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  bool get _isOpen => _overlayEntry != null;

  @override
  void dispose() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    super.dispose();
  }

  void _toggle() {
    if (_isOpen) {
      _hide();
    } else {
      _show();
    }
  }

  void _show() {
    final overlay = Overlay.of(context);
    _overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _hide,
                child: const SizedBox.expand(),
              ),
            ),
            CompositedTransformFollower(
              link: _layerLink,
              showWhenUnlinked: false,
              targetAnchor: widget.showAbove
                  ? Alignment.topRight
                  : Alignment.bottomRight,
              followerAnchor: widget.showAbove
                  ? Alignment.bottomRight
                  : Alignment.topRight,
              offset: widget.showAbove
                  ? const Offset(0, -8)
                  : const Offset(0, 8),
              child: _InfoPopover(
                title: widget.title,
                width: widget.width,
                child: widget.body,
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(_overlayEntry!);
    setState(() {});
  }

  void _hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: SizedBox.square(
        dimension: 26,
        child: IconButton(
          tooltip: widget.tooltip,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          onPressed: _toggle,
          icon: Icon(
            Icons.info_outline,
            color: _isOpen ? AppColors.sunsetDark : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

class _InfoPopover extends StatelessWidget {
  const _InfoPopover({
    required this.title,
    required this.child,
    required this.width,
  });

  final String title;
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.14),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppTextStyles.mono12(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
