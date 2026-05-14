// Wave 2 W-5-mobile-FU — shared operator brand-mark widget for the
// Forge & Flow mobile shell.
//
// Mirrors the operator-web `_OperatorBrandMark` (Wave 2 W-5 / PR #686,
// lives privately inside `lib/operator_web/widgets/web_app_shell.dart`)
// so the mobile shell + post-login screens share the same render
// contract:
//
//   * When `logoUrl` is a non-blank string, render `Image.network` in
//     a circular clip at the requested size.
//   * On any network image error (CORS, 404, transient outage), fall
//     back to the F&F splash icon. The shell never blanks.
//   * When `logoUrl` is null or blank, render the splash icon
//     directly.
//
// The widget is intentionally not session-aware — callers thread
// `session.logoUrl` in explicitly so the widget is unit-testable
// without standing up a session notifier and so the same widget can
// render outside an `AuthSession` scope (e.g. inside a tab body that
// re-reads from `Provider.of<AuthSessionNotifier>` at a different
// frame).
//
// HP #2 (CLAUDE.md / demo-mode contract): no `kDemoMode` reader-side
// branch lives here. Demo and production sessions both flow through
// the same `session.logoUrl` projection — demo seeds a `data:` URI
// placeholder upstream so the demo walkthrough exercises the
// propagation path without a network round-trip.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Render the operator's uploaded brand-mark with a graceful F&F
/// splash fallback. See file header for the contract.
class OperatorBrandMark extends StatelessWidget {
  const OperatorBrandMark({
    super.key,
    required this.logoUrl,
    this.size = 36,
  });

  /// Operator's logo URL, typically `session.logoUrl`. Null or blank
  /// means "render the splash fallback".
  final String? logoUrl;

  /// Edge length of the circular brand-mark. Defaults to 36 px to
  /// match the existing notifications + settings AppBar splash size.
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl?.trim();
    final hasUrl = url != null && url.isNotEmpty;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: hasUrl
            ? Image.network(
                url,
                key: Key('operator_brand_mark_logo_${url.hashCode}'),
                width: size,
                height: size,
                fit: BoxFit.cover,
                // Defence in depth: a broken brand-mark URL (404, CORS,
                // transient AAD outage) must never blank the shell.
                errorBuilder: (_, __, ___) => _splashFallback(),
              )
            : _splashFallback(),
      ),
    );
  }

  Widget _splashFallback() {
    return Image.asset(
      'assets/images/forge_flow_splash_icon.png',
      key: const Key('operator_brand_mark_splash_fallback'),
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }
}

/// Padding shim around [OperatorBrandMark] for use inside the mobile
/// shell's standalone AppBar leading slot. The shell's other icons sit
/// inside `_AppShellIconButton` 36x36 hit-targets; this shim keeps the
/// brand-mark visually centered on the same baseline without changing
/// the shell's height.
class OperatorBrandMarkLeading extends StatelessWidget {
  const OperatorBrandMarkLeading({
    super.key,
    required this.logoUrl,
  });

  final String? logoUrl;

  @override
  Widget build(BuildContext context) {
    // Reuse the same colour token the shell uses for icon borders so
    // the brand-mark feels of-a-piece with the surrounding chrome.
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(1),
      child: OperatorBrandMark(logoUrl: logoUrl, size: 34),
    );
  }
}
