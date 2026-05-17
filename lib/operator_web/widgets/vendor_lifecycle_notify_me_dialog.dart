// Phase 11W.8 — Vendor lifecycle "Notify me when ready" dialog.
//
// Renders the operator-facing capture flow described in
// `docs/phases/phase_8/vendor_connections_admin_surface.md`
// ("Backend UX exposure" → "Notify me when ready"). The operator
// sees this when tapping the **Notify me when ready** CTA on a
// vendor row whose `VendorCapabilityProfile.lifecycle` is
// `documented` or `sandbox_verified`.
//
// On submit, the dialog inserts a row into
// `vendor_lifecycle_notification` (Phase 8.0.lifecycle migration)
// via [VendorLifecycleNotificationRepository]. The UNIQUE constraint
// on `(operator_id, vendor_id, email)` makes a duplicate submit a
// no-op at the data layer; the repository contract surfaces this
// as `VendorLifecycleNotificationOutcome.alreadySubscribed` so the
// caller can show "We'll email you when this is ready" instead of
// inserting twice.
//
// UPSTREAM SEAM (1) — Repository.
// The production `VendorLifecycleNotificationRepository`
// implementation lands as a follow-up to Phase 8.0.lifecycle (the
// 8.0.lifecycle slice shipped only the migration + the
// `VendorLifecycle` enum on `VendorCapabilityProfile`; the
// repository class was specified in the surface doc but not
// committed). This file declares the abstract seam the dialog
// depends on so 11W.8 can compile + test against an injected fake.
// When the production class lands, swap the import to point at it
// and delete the abstract class below.
//
// UPSTREAM SEAM (2) — Picker integration.
// The shared `VendorConnectionsWidget` from Phase 8.0 does not yet
// expose an `onNotifyMeRequested(vendorId, vendorDisplayName,
// lifecycle)` callback prop, and its picker dialog is a single
// dropdown with no per-row chrome where the Notify-me CTA could
// attach. The widget API is closed against
// `lib/integrations/ui/vendor_connections/*` (per the 11W.8
// "Files to leave alone" rule). The dialog UI lands in this file
// fully testable on its own; wiring it onto vendor rows in the
// shared widget is a Phase 8.0 follow-up. See the 11W.8 execution
// report blocker section for the exact widget-API delta needed.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_models.dart'
    show VendorLifecycle;
import '../../theme/app_theme.dart';

/// Outcome of a Notify-me capture attempt. Surfaces the UNIQUE
/// constraint result so the caller does not have to second-guess
/// duplicate submissions.
enum VendorLifecycleNotificationOutcome {
  /// Row inserted (first time this `(operator_id, vendor_id, email)`
  /// triple subscribed).
  inserted,

  /// Row already existed; the UNIQUE constraint made the insert a
  /// no-op. Caller displays "We'll email you when this is ready".
  alreadySubscribed,
}

/// Repository seam the dialog depends on. The production
/// implementation lands as a Phase 8.0.lifecycle follow-up that
/// targets the `vendor_lifecycle_notification` table. Until then,
/// this lane is wired against an injected fake (widget tests) or a
/// thin client stub (demo mode). See the file header for the
/// upstream-seam note.
abstract class VendorLifecycleNotificationRepository {
  /// Idempotent insert. Returns `inserted` on first subscribe;
  /// `alreadySubscribed` when the UNIQUE
  /// `(operator_id, vendor_id, email)` constraint blocks a
  /// duplicate.
  Future<VendorLifecycleNotificationOutcome> insertNotification({
    required String operatorId,
    required String vendorId,
    required String email,
  });

  /// Cancel a Notify-me subscription. Deletes the row matching
  /// `(operator_id, vendor_id, email)`. No-op if the row does not
  /// exist.
  Future<void> cancelNotification({
    required String operatorId,
    required String vendorId,
    required String email,
  });
}

/// Result returned by [showVendorLifecycleNotifyMeDialog]. Null when
/// the operator dismissed the dialog without submitting; otherwise
/// the captured email + the repository outcome.
@immutable
class VendorLifecycleNotifyMeResult {
  const VendorLifecycleNotifyMeResult({
    required this.email,
    required this.outcome,
  });

  final String email;
  final VendorLifecycleNotificationOutcome outcome;
}

/// Convenience entry point. Opens the [VendorLifecycleNotifyMeDialog]
/// as a modal route and returns the capture result.
Future<VendorLifecycleNotifyMeResult?> showVendorLifecycleNotifyMeDialog(
  BuildContext context, {
  required String operatorId,
  required String vendorId,
  required String vendorDisplayName,
  required VendorLifecycle lifecycle,
  required String defaultEmail,
  required VendorLifecycleNotificationRepository repository,
}) {
  return showDialog<VendorLifecycleNotifyMeResult>(
    context: context,
    builder: (_) => VendorLifecycleNotifyMeDialog(
      operatorId: operatorId,
      vendorId: vendorId,
      vendorDisplayName: vendorDisplayName,
      lifecycle: lifecycle,
      defaultEmail: defaultEmail,
      repository: repository,
    ),
  );
}

/// Modal dialog that captures a Notify-me subscription against a
/// vendor whose lifecycle is `documented` or `sandbox_verified`.
class VendorLifecycleNotifyMeDialog extends StatefulWidget {
  const VendorLifecycleNotifyMeDialog({
    super.key,
    required this.operatorId,
    required this.vendorId,
    required this.vendorDisplayName,
    required this.lifecycle,
    required this.defaultEmail,
    required this.repository,
  });

  final String operatorId;
  final String vendorId;
  final String vendorDisplayName;

  /// Lifecycle stage of the vendor at the time the dialog opened.
  /// Drives the secondary explainer ("documented" vs
  /// "sandbox-verified" wording) per the surface doc.
  final VendorLifecycle lifecycle;

  /// Email pre-filled into the field. The dialog uses
  /// `session.email` upstream, so the typical flow is one tap to
  /// confirm.
  final String defaultEmail;

  final VendorLifecycleNotificationRepository repository;

  @override
  State<VendorLifecycleNotifyMeDialog> createState() =>
      _VendorLifecycleNotifyMeDialogState();
}

class _VendorLifecycleNotifyMeDialogState
    extends State<VendorLifecycleNotifyMeDialog> {
  late final TextEditingController _emailController;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.defaultEmail);
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    final raw = _emailController.text.trim();
    if (raw.isEmpty || raw.length < 3 || !raw.contains('@')) {
      setState(() {
        _errorMessage =
            'Type a valid email address. We use this to email you '
            'the moment ${widget.vendorDisplayName} is ready to '
            'connect.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final outcome = await widget.repository.insertNotification(
        operatorId: widget.operatorId,
        vendorId: widget.vendorId,
        email: raw,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        VendorLifecycleNotifyMeResult(email: raw, outcome: outcome),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage =
            'We could not save your subscription. Try again in a '
            'moment, or contact Forge & Flow support if it keeps '
            'happening. (Details: $error)';
      });
    }
  }

  String _lifecycleSubline() {
    switch (widget.lifecycle) {
      case VendorLifecycle.documented:
        return "We've built the integration with "
            "${widget.vendorDisplayName} but we're still in the "
            "partnership process with them. As soon as they issue "
            "us production credentials, the Connect button "
            "activates and we'll email you.";
      case VendorLifecycle.sandboxVerified:
        return "We've verified the integration end-to-end against "
            "${widget.vendorDisplayName}'s sandbox. Production "
            "access is pending partnership clearance. We'll email "
            "you the moment it lands.";
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        // Defensive: the dialog should not open for these
        // lifecycles (the picker shows a live Connect button
        // instead). Render a neutral subline if it does.
        return "${widget.vendorDisplayName} is ready to connect. "
            "you do not need to subscribe to a notification.";
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_lifecycle_notify_me_dialog'),
      title: Text(
        "We'll email you the moment ${widget.vendorDisplayName} "
        "goes live for connecting.",
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _lifecycleSubline(),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('vendor_lifecycle_notify_me_email_field'),
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email',
                helperText:
                    'Pre-filled from your sign-in. Edit if a '
                    'different teammate should get this email.',
                errorText: _errorMessage,
              ),
              enabled: !_submitting,
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_lifecycle_notify_me_cancel'),
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('vendor_lifecycle_notify_me_submit'),
          onPressed: _submitting ? null : _onSubmit,
          child: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Notify me'),
        ),
      ],
    );
  }
}
