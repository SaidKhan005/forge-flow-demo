// Lane B B2.2 + B2.3 - Default Role catalog publish dialog.
//
// Double-confirm modal opened from
// `default_role_catalog_admin_screen.dart` when the F&F super_admin
// pushes "Publish" on the draft editor. Owns the safety net that
// protects a global role-catalog change from a single misclick:
//
//   1. Stage 1 reads the prior current version + describes what is
//      about to change. The super_admin presses "Continue" to move
//      past the awareness gate.
//   2. Stage 2 requires typing the proposed version number into the
//      confirm field. The "Publish" button stays disabled until the
//      typed value matches. Mirrors `feature_flags_admin_screen.dart`'s
//      destructive-confirmation idiom verbatim so the visual posture
//      is consistent across admin surfaces.
//   3. Optional notes field (0-2000 chars per the B2.1 schema CHECK).
//
// B2.3 — when [priorCurrent] is non-null the dialog fires a
// `getBlastRadius(priorCurrent.versionId)` call on open and renders
// the slice-specced "Affecting N businesses, N locations, N users"
// copy. The dialog falls back to plain-English consequence copy when:
//   * priorCurrent is null (genesis publish — nothing to supersede),
//   * counts are all zero (no operators pinned to the prior version
//     yet — common at PR-merge time when no live operator has
//     customized a version pointer),
//   * the gateway throws (404 unknown version, transient proxy
//     failure, timeout). A small error chip surfaces the proxy code
//     so the super_admin can decide whether to retry; the dialog never
//     blocks the publish path on a blast-radius preview failure.
//
// Tested by:
//   * test/admin/default_role_catalog_publish_dialog_test.dart

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/default_role_catalog_admin_gateway.dart';

/// Result returned to the caller via [Navigator.pop]. `null` means the
/// dialog was dismissed without publishing; non-null carries the new
/// catalog version row the gateway returned.
typedef DefaultRoleCatalogPublishResult = DefaultRoleCatalogVersionView?;

/// Opens the publish dialog and resolves with the new version (when
/// the super_admin confirms) or `null` (cancel / error / dismiss).
///
/// [priorCurrent] is the catalog version about to be superseded; pass
/// `null` for the genesis publish (no prior current row exists yet).
/// [nextVersionNumber] is what the new row's `version_number` will be
/// once the proxy assigns it; the dialog uses it for the type-confirm
/// step. Callers compute it from `priorCurrent?.versionNumber + 1` (or
/// 1 when null) before opening.
/// [proposedPayload] is the role-definition array the screen has built
/// in the draft editor; the dialog forwards it to the gateway verbatim.
Future<DefaultRoleCatalogPublishResult> showDefaultRoleCatalogPublishDialog({
  required BuildContext context,
  required DefaultRoleCatalogAdminGateway gateway,
  required DefaultRoleCatalogVersionView? priorCurrent,
  required int nextVersionNumber,
  required List<Object?> proposedPayload,
}) {
  return showDialog<DefaultRoleCatalogPublishResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DefaultRoleCatalogPublishDialog(
      gateway: gateway,
      priorCurrent: priorCurrent,
      nextVersionNumber: nextVersionNumber,
      proposedPayload: proposedPayload,
    ),
  );
}

/// Two-stage publish dialog. Exposed as a public widget so widget
/// tests can mount it directly without the host screen.
class DefaultRoleCatalogPublishDialog extends StatefulWidget {
  const DefaultRoleCatalogPublishDialog({
    super.key,
    required this.gateway,
    required this.priorCurrent,
    required this.nextVersionNumber,
    required this.proposedPayload,
  });

  final DefaultRoleCatalogAdminGateway gateway;
  final DefaultRoleCatalogVersionView? priorCurrent;
  final int nextVersionNumber;
  final List<Object?> proposedPayload;

  @override
  State<DefaultRoleCatalogPublishDialog> createState() =>
      _DefaultRoleCatalogPublishDialogState();
}

enum _Stage { awareness, typeConfirm, publishing, success, error }

class _DefaultRoleCatalogPublishDialogState
    extends State<DefaultRoleCatalogPublishDialog> {
  final TextEditingController _confirmController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();
  _Stage _stage = _Stage.awareness;
  bool _typedMatches = false;
  String? _errorMessage;
  DefaultRoleCatalogVersionView? _published;

  /// B2.3 — async result of the blast-radius preview fetch. Tri-state:
  ///   * `null` → still in flight (or skipped on genesis publish).
  ///   * non-null `counts` → render numeric copy when non-zero,
  ///     plain-English fallback when zero.
  ///   * non-null `errorCode` → render plain-English fallback + small
  ///     error chip surfacing the proxy code.
  _BlastRadiusFetch? _blastRadius;

  @override
  void initState() {
    super.initState();
    _confirmController.addListener(_recomputeMatch);
    _maybeFetchBlastRadius();
  }

  /// Fires the blast-radius preview when [priorCurrent] is non-null.
  /// Genesis publish skips the fetch — there is no prior version to
  /// preview against. Errors are caught and surfaced via the
  /// [_BlastRadiusFetch.errorCode] field so the dialog never blocks on
  /// a transient backend hiccup.
  Future<void> _maybeFetchBlastRadius() async {
    final prior = widget.priorCurrent;
    if (prior == null) return;
    try {
      final counts =
          await widget.gateway.getBlastRadius(versionId: prior.versionId);
      if (!mounted) return;
      setState(() {
        _blastRadius = _BlastRadiusFetch(counts: counts);
      });
    } on DefaultRoleCatalogAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _blastRadius = _BlastRadiusFetch(
          errorCode: error.errorCode,
          errorMessage: error.message,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _blastRadius = _BlastRadiusFetch(
          errorCode: 'unknown_error',
          errorMessage: error.toString(),
        );
      });
    }
  }

  void _recomputeMatch() {
    final next = _confirmController.text.trim() ==
        widget.nextVersionNumber.toString();
    if (next != _typedMatches) {
      setState(() => _typedMatches = next);
    }
  }

  @override
  void dispose() {
    _confirmController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    setState(() {
      _stage = _Stage.publishing;
      _errorMessage = null;
    });
    final notes = _notesController.text.trim();
    try {
      final result = await widget.gateway.publishVersion(
        payload: widget.proposedPayload,
        notes: notes.isEmpty ? null : notes,
      );
      if (!mounted) return;
      setState(() {
        _published = result;
        _stage = _Stage.success;
      });
    } on DefaultRoleCatalogAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = _friendlyError(error);
        _stage = _Stage.error;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Publish failed: $error. Retry or close.';
        _stage = _Stage.error;
      });
    }
  }

  String _friendlyError(DefaultRoleCatalogAdminGatewayError error) {
    // Translate the proxy's stable error codes into operator-readable
    // copy. Anything we have not mapped falls back to the message the
    // proxy returned so the super_admin still has a clue without
    // re-reading the route source.
    switch (error.errorCode) {
      case 'permission_denied':
        return 'Publish failed: only ecosystem admins can change the '
            'default catalog. Contact a super admin to publish.';
      case 'missing_idempotency_key':
      case 'idempotency_key_too_long':
        return 'Publish failed: request was rejected by the safety '
            'check. Retry once; if the problem keeps happening, contact '
            'engineering.';
      case 'empty_payload':
      case 'missing_payload':
        return 'Publish failed: the draft has no roles. Add at least '
            'one role before publishing.';
      case 'invalid_notes':
      case 'notes_too_long':
        return 'Publish failed: the notes field is invalid. Keep notes '
            'under 2000 characters and try again.';
      case 'actor_user_not_resolvable':
        return 'Publish failed: your admin account is not linked to a '
            'Forge & Flow user record. Contact engineering before retrying.';
      case 'timeout':
        return 'Publish timed out talking to the admin proxy. Wait a '
            'moment and try again.';
      default:
        return 'Publish failed: ${error.message} (${error.errorCode}). '
            'Retry or close.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_default_role_catalog_publish_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        _titleForStage(),
        style: AppTextStyles.display20(color: _titleColorForStage()),
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(child: _buildBody()),
      ),
      actions: _buildActions(),
    );
  }

  String _titleForStage() {
    switch (_stage) {
      case _Stage.awareness:
        return widget.priorCurrent == null
            ? 'Publish the first default catalog?'
            : 'Publish a new default catalog version?';
      case _Stage.typeConfirm:
        return 'Confirm version ${widget.nextVersionNumber}';
      case _Stage.publishing:
        return 'Publishing...';
      case _Stage.success:
        return 'Published version ${_published?.versionNumber ?? widget.nextVersionNumber}';
      case _Stage.error:
        return 'Publish failed';
    }
  }

  Color _titleColorForStage() {
    switch (_stage) {
      case _Stage.error:
        return AppColors.negative;
      case _Stage.success:
        return AppColors.positive;
      default:
        return AppColors.textPrimary;
    }
  }

  Widget _buildBody() {
    switch (_stage) {
      case _Stage.awareness:
        return _AwarenessBody(
          priorCurrent: widget.priorCurrent,
          nextVersionNumber: widget.nextVersionNumber,
          notesController: _notesController,
          blastRadius: _blastRadius,
        );
      case _Stage.typeConfirm:
        return _TypeConfirmBody(
          nextVersionNumber: widget.nextVersionNumber,
          controller: _confirmController,
        );
      case _Stage.publishing:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: SizedBox(
              key: Key('admin_default_role_catalog_publish_progress'),
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sunsetDark,
              ),
            ),
          ),
        );
      case _Stage.success:
        return _SuccessBody(version: _published!);
      case _Stage.error:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            _errorMessage ?? 'Publish failed. Retry or close.',
            key: const Key('admin_default_role_catalog_publish_error_text'),
            style: AppTextStyles.body13(color: AppColors.negative),
          ),
        );
    }
  }

  List<Widget> _buildActions() {
    switch (_stage) {
      case _Stage.awareness:
        return <Widget>[
          TextButton(
            key: const Key('admin_default_role_catalog_publish_cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('admin_default_role_catalog_publish_continue'),
            style: AdminButtonStyles.primary,
            onPressed: () => setState(() => _stage = _Stage.typeConfirm),
            child: const Text('Continue'),
          ),
        ];
      case _Stage.typeConfirm:
        return <Widget>[
          TextButton(
            key: const Key('admin_default_role_catalog_publish_back'),
            onPressed: () => setState(() => _stage = _Stage.awareness),
            child: const Text('Back'),
          ),
          FilledButton(
            key: const Key('admin_default_role_catalog_publish_confirm'),
            style: AdminButtonStyles.danger,
            onPressed: _typedMatches ? _publish : null,
            child: const Text('Publish'),
          ),
        ];
      case _Stage.publishing:
        return const <Widget>[];
      case _Stage.success:
        return <Widget>[
          FilledButton(
            key: const Key('admin_default_role_catalog_publish_done'),
            style: AdminButtonStyles.primary,
            onPressed: () => Navigator.of(context).pop(_published),
            child: const Text('Done'),
          ),
        ];
      case _Stage.error:
        return <Widget>[
          TextButton(
            key: const Key('admin_default_role_catalog_publish_error_close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const Key('admin_default_role_catalog_publish_error_retry'),
            style: AdminButtonStyles.primary,
            onPressed: () => setState(() {
              _stage = _Stage.typeConfirm;
              _errorMessage = null;
            }),
            child: const Text('Retry'),
          ),
        ];
    }
  }
}

class _AwarenessBody extends StatelessWidget {
  const _AwarenessBody({
    required this.priorCurrent,
    required this.nextVersionNumber,
    required this.notesController,
    required this.blastRadius,
  });

  final DefaultRoleCatalogVersionView? priorCurrent;
  final int nextVersionNumber;
  final TextEditingController notesController;
  final _BlastRadiusFetch? blastRadius;

  @override
  Widget build(BuildContext context) {
    final prior = priorCurrent;
    final headlineCopy = _composeHeadline(prior: prior);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          headlineCopy,
          key: const Key('admin_default_role_catalog_publish_headline'),
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        if (_shouldShowErrorChip)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              key: const Key(
                'admin_default_role_catalog_publish_blast_error_chip',
              ),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: BoxDecoration(
                color: AppColors.negative.withValues(alpha: 0.08),
                border: Border.all(
                  color: AppColors.negative.withValues(alpha: 0.40),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(
                    Icons.error_outline,
                    size: 14,
                    color: AppColors.negative,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Blast-radius preview unavailable '
                      '(${blastRadius!.errorCode}). Showing plain-English '
                      'consequences instead — publish still works.',
                      style: AppTextStyles.body12(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 14),
        Container(
          key: const Key('admin_default_role_catalog_publish_blast_notice'),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.10),
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.45),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.info_outline,
                size: 18,
                color: AppColors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Blast radius: this catalog is shared across every '
                  'business on Forge & Flow. The audit log records the '
                  'number of businesses pinned to the prior version at '
                  'publish time.',
                  style: AppTextStyles.body12(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Notes (optional)',
          style: AppTextStyles.mono11(color: AppColors.textSecondary)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        TextField(
          key: const Key('admin_default_role_catalog_publish_notes'),
          controller: notesController,
          maxLines: 3,
          maxLength: 2000,
          decoration: InputDecoration(
            hintText: 'What changed and why? Up to 2000 characters.',
            hintStyle: AppTextStyles.body12(color: AppColors.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: AppColors.borderSubtle,
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Headline copy logic (B2.3):
  ///
  /// 1. Genesis publish (prior == null) → plain-English first-publish
  ///    copy. The blast-radius preview is not fetched in this case.
  /// 2. Numeric copy when the gateway returned a non-zero count for the
  ///    prior version: "Publishing version N will supersede version M,
  ///    currently followed by X businesses (Y locations, Z users)…"
  /// 3. Zero-count fallback (gateway returned counts but all zero):
  ///    "This is the first published catalog with no businesses pinned
  ///    yet…". This is the common state at PR-merge time.
  /// 4. Error fallback (gateway threw): plain-English copy + the error
  ///    chip rendered separately above.
  /// 5. In-flight (still fetching): plain-English consequence copy.
  ///    Numeric copy will swap in when the fetch resolves.
  String _composeHeadline({required DefaultRoleCatalogVersionView? prior}) {
    if (prior == null) {
      return 'This will publish the first version of the default role '
          'catalog. Every Forge & Flow business will start with these '
          'roles when they sign up; existing businesses will keep their '
          'own copies unless they opt in to follow the latest version.';
    }
    final fetched = blastRadius;
    final hasNumericData = fetched != null &&
        fetched.counts != null &&
        !fetched.counts!.isZeroState;
    if (hasNumericData) {
      final counts = fetched.counts!;
      final businessLabel = counts.operatorCount == 1
          ? 'business'
          : 'businesses';
      final locationLabel = counts.locationCount == 1
          ? 'location'
          : 'locations';
      final userLabel = counts.userCount == 1 ? 'user' : 'users';
      return 'Publishing version $nextVersionNumber will supersede '
          'version ${prior.versionNumber}, currently followed by '
          '${counts.operatorCount} $businessLabel '
          '(${counts.locationCount} $locationLabel, '
          '${counts.userCount} $userLabel). Any business set to follow '
          'the latest default catalog will see version $nextVersionNumber '
          "immediately on the next role refresh. Businesses that have "
          'customized their roles are unaffected.';
    }
    // Zero-count OR error-fallback OR still-in-flight — same copy.
    return 'This will replace the current default role catalog '
        '(version ${prior.versionNumber}) with a new version '
        '$nextVersionNumber. Any business set to follow the latest '
        'default catalog will see the new roles immediately on the '
        'next role refresh. Businesses that have customized their '
        'roles are unaffected.';
  }

  bool get _shouldShowErrorChip {
    final fetched = blastRadius;
    return fetched != null && fetched.errorCode != null;
  }
}

/// Carry-shape for the async blast-radius preview fetch. Mutually
/// exclusive fields: a successful fetch populates [counts] and leaves
/// [errorCode]/[errorMessage] null; a failed fetch populates the error
/// pair and leaves [counts] null. The dialog reads both to decide
/// between numeric copy and plain-English fallback.
class _BlastRadiusFetch {
  const _BlastRadiusFetch({this.counts, this.errorCode, this.errorMessage});

  final DefaultRoleCatalogBlastRadius? counts;
  final String? errorCode;
  final String? errorMessage;
}

class _TypeConfirmBody extends StatelessWidget {
  const _TypeConfirmBody({
    required this.nextVersionNumber,
    required this.controller,
  });

  final int nextVersionNumber;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Type the version number to publish:',
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          '$nextVersionNumber',
          key: const Key(
            'admin_default_role_catalog_publish_target_version',
          ),
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('admin_default_role_catalog_publish_typed'),
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '$nextVersionNumber',
            hintStyle: AppTextStyles.mono11(color: AppColors.textMuted),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6),
              borderSide: const BorderSide(
                color: AppColors.borderSubtle,
                width: 1,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'After you press Publish the new catalog rolls out immediately to '
          'every business that follows the latest. This action is audited.',
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _SuccessBody extends StatelessWidget {
  const _SuccessBody({required this.version});

  final DefaultRoleCatalogVersionView version;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Version ${version.versionNumber} is now the current default '
          'catalog. Businesses set to follow the latest will pick up the '
          'new roles on their next refresh.',
          key: const Key('admin_default_role_catalog_publish_success_body'),
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 10),
        Text(
          'Content fingerprint: ${version.payloadSha256.substring(0, 12)}...',
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
      ],
    );
  }
}
