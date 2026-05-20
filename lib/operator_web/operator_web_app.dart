// Phase 11W — Operator Web Console MaterialApp.
//
// Top-level Flutter Web app for the Operator Web Console. Wraps the
// `OperatorWebRouter` so the entire surface area lives behind the
// auth source's state machine. Brand styling reused verbatim from
// `lib/theme/app_theme.dart` per the 11W non-negotiable "brand
// styling identical to operator app".

import 'package:flutter/material.dart';

import 'auth/operator_web_auth_source.dart';
import 'router/operator_web_router.dart';
import '../theme/app_theme.dart';

/// Brand-styled MaterialApp for the operator-web console. Hosts the
/// [OperatorWebRouter] which keys off the auth source's state
/// machine.
class OperatorWebApp extends StatefulWidget {
  const OperatorWebApp({
    super.key,
    required this.authSource,
    this.initialNavId = kOperatorWebDefaultNavId,
  });

  final OperatorWebAuthSource authSource;
  final String initialNavId;

  @override
  State<OperatorWebApp> createState() => _OperatorWebAppState();
}

class _OperatorWebAppState extends State<OperatorWebApp> {
  @override
  void dispose() {
    widget.authSource.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Forge & Flow - Operator Web Console',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeData,
      home: OperatorWebRouter(
        source: widget.authSource,
        initialNavId: widget.initialNavId,
        initialUri: Uri.base,
      ),
    );
  }
}
