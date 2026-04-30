// Phase 9.UX.1 - Settings -> Account -> MFA section.
//
// Self-service authenticator app enrollment and factor status. Production
// passes a proxy-backed MfaOperationsGateway; demo/test paths may explicitly
// allow the in-memory fallback.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../services/mfa/mfa_enrollment_service.dart';
import '../../services/mfa/mfa_operations_gateway.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

class MfaActorContext {
  const MfaActorContext({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.userEmail,
    this.issuerName = 'Forge & Flow',
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String userEmail;
  final String issuerName;
  final String authorizationIdToken;
}

const MfaActorContext kDemoMfaActorContext = MfaActorContext(
  actorUserId: 'demo-actor-user-id',
  operatorId: 'demo-operator-id',
  locationId: 'demo-location-id',
  userEmail: 'demo.operator@forgeflow.test',
);

class SettingsMfaSection extends StatefulWidget {
  const SettingsMfaSection({
    super.key,
    this.gateway,
    this.actor,
    this.allowDemoGatewayFallback = false,
  });

  final MfaOperationsGateway? gateway;
  final MfaActorContext? actor;
  final bool allowDemoGatewayFallback;

  @override
  State<SettingsMfaSection> createState() => _SettingsMfaSectionState();
}

enum _EnrollmentStage { idle, scanning, displayingRecoveryCodes }

class _SettingsMfaSectionState extends State<SettingsMfaSection> {
  late final MfaOperationsGateway _gateway;
  late final MfaActorContext _actor;
  late final TextEditingController _codeController;

  bool _loadingFactors = true;
  bool _busyEnroll = false;
  bool _busyRevoke = false;
  String? _errorMessage;
  String? _infoMessage;
  List<MfaFactorSummary> _factors = const <MfaFactorSummary>[];
  List<MfaFactorSummary> _optimisticFactors = const <MfaFactorSummary>[];
  _EnrollmentStage _enrollStage = _EnrollmentStage.idle;
  TotpEnrollmentSetup? _pendingSetup;
  List<String> _displayOnceRecoveryCodes = const <String>[];

  @override
  void initState() {
    super.initState();
    _gateway =
        widget.gateway ??
        (widget.allowDemoGatewayFallback
            ? DemoMfaOperationsGateway()
            : const _UnavailableMfaOperationsGateway());
    _actor = widget.actor ?? kDemoMfaActorContext;
    _codeController = TextEditingController();
    _refreshFactors();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _refreshFactors({bool clearMessages = true}) async {
    setState(() {
      _loadingFactors = true;
      if (clearMessages) {
        _errorMessage = null;
        _infoMessage = null;
      }
    });
    try {
      final result = await _gateway.listFactors(
        MfaListFactorsCommand(
          actorUserId: _actor.actorUserId,
          operatorId: _actor.operatorId,
          locationId: _actor.locationId,
          authorizationIdToken: _actor.authorizationIdToken,
        ),
      );
      if (!mounted) return;
      setState(() {
        _factors = result.factors;
        _optimisticFactors = _pendingOptimisticFactors(result.factors);
        _loadingFactors = false;
      });
    } on MfaOperationRejected catch (rejected) {
      if (!mounted) return;
      setState(() {
        _loadingFactors = false;
        _errorMessage = rejected.message;
      });
    }
  }

  Future<void> _onBeginEnrollment() async {
    setState(() {
      _busyEnroll = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final setup = await _gateway.beginTotpEnrollment(
        MfaTotpBeginCommand(
          actorUserId: _actor.actorUserId,
          operatorId: _actor.operatorId,
          locationId: _actor.locationId,
          authorizationIdToken: _actor.authorizationIdToken,
          userEmail: _actor.userEmail,
          issuerName: _actor.issuerName,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busyEnroll = false;
        _enrollStage = _EnrollmentStage.scanning;
        _pendingSetup = setup;
        _codeController.clear();
      });
    } on MfaOperationRejected catch (rejected) {
      if (!mounted) return;
      setState(() {
        _busyEnroll = false;
        _errorMessage = rejected.message;
      });
    }
  }

  Future<void> _onConfirmEnrollment() async {
    final pending = _pendingSetup;
    if (pending == null) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Enter the 6-digit code from your authenticator app.';
      });
      return;
    }
    setState(() {
      _busyEnroll = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final completed = await _gateway.confirmTotpEnrollment(
        MfaTotpConfirmCommand(
          actorUserId: _actor.actorUserId,
          operatorId: _actor.operatorId,
          locationId: _actor.locationId,
          authorizationIdToken: _actor.authorizationIdToken,
          factorId: pending.factorId,
          oneTimeCode: code,
          issuerName: _actor.issuerName,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busyEnroll = false;
        _enrollStage = _EnrollmentStage.displayingRecoveryCodes;
        _displayOnceRecoveryCodes = completed.recoveryCodesPlaintext;
        _optimisticFactors = _mergeOptimisticFactor(
          MfaFactorSummary(
            factorId: completed.factorId,
            factorType: 'totp',
            enrolledAt: DateTime.now().toUtc(),
            issuerLabel: _actor.issuerName,
          ),
        );
        _infoMessage = 'Authenticator app added. Save your recovery codes now.';
      });
      await _refreshFactors(clearMessages: false);
    } on MfaOperationRejected catch (rejected) {
      if (!mounted) return;
      setState(() {
        _busyEnroll = false;
        _errorMessage = rejected.message;
      });
    }
  }

  void _onAcknowledgeRecoveryCodes() {
    setState(() {
      _enrollStage = _EnrollmentStage.idle;
      _pendingSetup = null;
      _displayOnceRecoveryCodes = const <String>[];
      _codeController.clear();
    });
  }

  void _onCancelEnrollment() {
    setState(() {
      _enrollStage = _EnrollmentStage.idle;
      _pendingSetup = null;
      _displayOnceRecoveryCodes = const <String>[];
      _codeController.clear();
      _errorMessage = null;
      _infoMessage = null;
    });
  }

  Future<void> _onRevoke(MfaFactorSummary factor) async {
    setState(() {
      _busyRevoke = true;
      _errorMessage = null;
      _infoMessage = null;
    });
    try {
      final completed = await _gateway.revokeFactor(
        MfaRevokeFactorCommand(
          actorUserId: _actor.actorUserId,
          operatorId: _actor.operatorId,
          locationId: _actor.locationId,
          authorizationIdToken: _actor.authorizationIdToken,
          factorId: factor.factorId,
          stepUpProofId: _actor.authorizationIdToken,
        ),
      );
      if (!mounted) return;
      setState(() {
        _busyRevoke = false;
        _infoMessage = completed.revoked
            ? 'Authenticator app removed.'
            : 'MFA removal requested. The authenticator app stays active during the security window.';
      });
      if (completed.revoked) await _refreshFactors();
    } on MfaOperationRejected catch (rejected) {
      if (!mounted) return;
      setState(() {
        _busyRevoke = false;
        _errorMessage = rejected.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleFactors = _visibleFactors;
    return SettingsCard(
      key: const Key('settings_mfa_section'),
      children: [
        const _MfaHeader(),
        const SettingsRowDivider(),
        _MfaFactorsList(
          loading: _loadingFactors,
          factors: visibleFactors,
          onRevoke: _busyRevoke ? null : _onRevoke,
        ),
        const SettingsRowDivider(),
        if (_enrollStage == _EnrollmentStage.idle &&
            visibleFactors.isEmpty &&
            _errorMessage == null)
          _MfaEnrollButton(
            busy: _busyEnroll,
            onPressed: () => _onBeginEnrollment(),
          ),
        if (_enrollStage == _EnrollmentStage.scanning && _pendingSetup != null)
          _MfaScanRow(
            setup: _pendingSetup!,
            codeController: _codeController,
            busy: _busyEnroll,
            onConfirm: _onConfirmEnrollment,
            onCancel: _onCancelEnrollment,
          ),
        if (_enrollStage == _EnrollmentStage.displayingRecoveryCodes)
          _MfaRecoveryCodesRow(
            recoveryCodes: _displayOnceRecoveryCodes,
            onAcknowledge: _onAcknowledgeRecoveryCodes,
          ),
        if (_errorMessage != null) ...[
          const SettingsRowDivider(),
          _MfaStatusRow(
            key: const Key('mfa_error_row'),
            label: 'MFA ERROR',
            message: _errorMessage!,
            color: AppColors.negative,
          ),
        ],
        if (_infoMessage != null) ...[
          const SettingsRowDivider(),
          _MfaStatusRow(
            key: const Key('mfa_info_row'),
            label: 'MFA UPDATE',
            message: _infoMessage!,
            color: AppColors.positive,
          ),
        ],
      ],
    );
  }

  List<MfaFactorSummary> get _visibleFactors {
    if (_optimisticFactors.isEmpty) return _factors;
    final merged = <MfaFactorSummary>[..._factors];
    final ids = merged.map((factor) => factor.factorId).toSet();
    for (final factor in _optimisticFactors) {
      if (ids.add(factor.factorId)) merged.add(factor);
    }
    return List<MfaFactorSummary>.unmodifiable(merged);
  }

  List<MfaFactorSummary> _mergeOptimisticFactor(MfaFactorSummary factor) {
    return List<MfaFactorSummary>.unmodifiable(<MfaFactorSummary>[
      for (final existing in _optimisticFactors)
        if (existing.factorId != factor.factorId) existing,
      factor,
    ]);
  }

  List<MfaFactorSummary> _pendingOptimisticFactors(
    List<MfaFactorSummary> refreshed,
  ) {
    if (_optimisticFactors.isEmpty) return const <MfaFactorSummary>[];
    final refreshedIds = refreshed.map((factor) => factor.factorId).toSet();
    return List<MfaFactorSummary>.unmodifiable(
      _optimisticFactors.where(
        (factor) => !refreshedIds.contains(factor.factorId),
      ),
    );
  }
}

class _MfaHeader extends StatelessWidget {
  const _MfaHeader();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      key: Key('mfa_header'),
      padding: EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TWO-FACTOR AUTHENTICATION',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 11),
          ),
          SizedBox(height: 4),
          Text(
            'Use Microsoft Authenticator, Google Authenticator, 1Password, or another authenticator app.',
            style: TextStyle(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}

class _MfaFactorsList extends StatelessWidget {
  const _MfaFactorsList({
    required this.loading,
    required this.factors,
    required this.onRevoke,
  });

  final bool loading;
  final List<MfaFactorSummary> factors;
  final ValueChanged<MfaFactorSummary>? onRevoke;

  @override
  Widget build(BuildContext context) {
    if (loading && factors.isEmpty) {
      return const Padding(
        key: Key('mfa_factors_loading'),
        padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Text(
          'Checking status...',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    if (factors.isEmpty) {
      return const Padding(
        key: Key('mfa_factors_empty'),
        padding: EdgeInsets.fromLTRB(14, 16, 14, 16),
        child: Text(
          'No authenticator app enrolled.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }
    return Padding(
      key: const Key('mfa_factors_list'),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final factor in factors)
            _MfaFactorRow(
              factor: factor,
              onRevoke: onRevoke == null ? null : () => onRevoke!(factor),
            ),
        ],
      ),
    );
  }
}

class _MfaFactorRow extends StatelessWidget {
  const _MfaFactorRow({required this.factor, required this.onRevoke});

  final MfaFactorSummary factor;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final enrolledLabel = _formatDate(factor.enrolledAt);
    final lastUsedLabel = factor.lastUsedAt == null
        ? 'Not used yet'
        : 'Last used ${_formatDate(factor.lastUsedAt!)}';
    return Padding(
      key: Key('mfa_factor_row_${factor.factorId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Authenticator app',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Added $enrolledLabel. $lastUsedLabel.',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            key: Key('mfa_revoke_button_${factor.factorId}'),
            onPressed: factor.canRevoke ? onRevoke : null,
            child: const Text('Remove / reset'),
          ),
        ],
      ),
    );
  }
}

class _MfaEnrollButton extends StatelessWidget {
  const _MfaEnrollButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const Key('mfa_enroll_totp_button'),
          onPressed: busy ? null : onPressed,
          icon: busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_moderator_outlined, size: 18),
          label: Text(busy ? 'Starting...' : 'Add authenticator app'),
        ),
      ),
    );
  }
}

class _MfaScanRow extends StatelessWidget {
  const _MfaScanRow({
    required this.setup,
    required this.codeController,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
  });

  final TotpEnrollmentSetup setup;
  final TextEditingController codeController;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('mfa_enrollment_scan'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              key: const Key('mfa_qr_code'),
              color: Colors.white,
              padding: const EdgeInsets.all(12),
              child: CustomPaint(
                size: const Size.square(176),
                painter: QrPainter(
                  data: setup.otpAuthUrl,
                  version: QrVersions.auto,
                  gapless: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _CopyValueRow(
            label: 'Setup URL',
            value: setup.otpAuthUrl,
            textKey: const Key('mfa_otpauth_url'),
            copyButtonKey: const Key('mfa_copy_otpauth_url_button'),
          ),
          const SizedBox(height: 8),
          _CopyValueRow(
            label: 'Secret',
            value: setup.secretBase32,
            textKey: const Key('mfa_secret_base32'),
            copyButtonKey: const Key('mfa_copy_secret_button'),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('mfa_one_time_code_field'),
            controller: codeController,
            enabled: !busy,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '6-digit code',
              helperText: 'Displayed on your authenticator app.',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => onConfirm(),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                key: const Key('mfa_confirm_enrollment_button'),
                onPressed: busy ? null : onConfirm,
                child: Text(busy ? 'Verifying...' : 'Verify'),
              ),
              TextButton(
                key: const Key('mfa_cancel_enrollment_button'),
                onPressed: busy ? null : onCancel,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CopyValueRow extends StatelessWidget {
  const _CopyValueRow({
    required this.label,
    required this.value,
    required this.textKey,
    required this.copyButtonKey,
  });

  final String label;
  final String value;
  final Key textKey;
  final Key copyButtonKey;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 2),
                  SelectableText(
                    value,
                    key: textKey,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: copyButtonKey,
              tooltip: 'Copy',
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
              icon: const Icon(Icons.copy_rounded, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _MfaRecoveryCodesRow extends StatelessWidget {
  const _MfaRecoveryCodesRow({
    required this.recoveryCodes,
    required this.onAcknowledge,
  });

  final List<String> recoveryCodes;
  final VoidCallback onAcknowledge;

  @override
  Widget build(BuildContext context) {
    final joined = recoveryCodes.join('\n');
    return Padding(
      key: const Key('mfa_recovery_codes_row'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Recovery codes',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          for (final code in recoveryCodes)
            SelectableText(
              code,
              key: Key('mfa_recovery_code_$code'),
              style: const TextStyle(color: AppColors.textPrimary),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('mfa_copy_recovery_codes_button'),
                onPressed: () => Clipboard.setData(ClipboardData(text: joined)),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy recovery codes'),
              ),
              FilledButton(
                key: const Key('mfa_recovery_codes_acknowledge_button'),
                onPressed: onAcknowledge,
                child: const Text("I've saved them"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MfaStatusRow extends StatelessWidget {
  const _MfaStatusRow({
    super.key,
    required this.label,
    required this.message,
    required this.color,
  });

  final String label;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Text(
        '$label: $message',
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}

class DemoMfaOperationsGateway implements MfaOperationsGateway {
  DemoMfaOperationsGateway({DateTime? now})
    : _now = now ?? DateTime.utc(2026, 4, 30);

  final DateTime _now;
  final List<MfaFactorSummary> _factors = <MfaFactorSummary>[];

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(
    MfaTotpBeginCommand command,
  ) async {
    if (_factors.isNotEmpty) {
      throw const MfaOperationRejected(
        code: 'mfa_factor_already_enrolled',
        message: 'An authenticator app is already enrolled.',
        statusCode: 409,
      );
    }
    return const TotpEnrollmentSetup(
      factorId: 'demo-factor-session',
      secretBase32: 'JBSWY3DPEHPK3PXP',
      otpAuthUrl:
          'otpauth://totp/Forge%20%26%20Flow:demo.operator%40forgeflow.test?secret=JBSWY3DPEHPK3PXP&issuer=Forge%20%26%20Flow',
    );
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) async {
    const factorId = 'demo-totp-factor';
    _factors
      ..clear()
      ..add(
        MfaFactorSummary(
          factorId: factorId,
          factorType: 'totp',
          enrolledAt: _now,
          issuerLabel: command.issuerName,
        ),
      );
    return const MfaTotpConfirmCompleted(
      factorId: factorId,
      recoveryCodesPlaintext: <String>['AAAA-BBBB-CCCC', 'DDDD-EEEE-FFFF'],
    );
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(
    MfaListFactorsCommand command,
  ) async {
    return MfaListFactorsCompleted(
      factors: List<MfaFactorSummary>.unmodifiable(_factors),
    );
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) async {
    _factors.removeWhere((factor) => factor.factorId == command.factorId);
    return const MfaRevokeFactorCompleted(revoked: true);
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) async {
    return const RecoveryCodeConsumeCompleted(factorId: 'demo-recovery-factor');
  }
}

class _UnavailableMfaOperationsGateway implements MfaOperationsGateway {
  const _UnavailableMfaOperationsGateway();

  @override
  Future<TotpEnrollmentSetup> beginTotpEnrollment(MfaTotpBeginCommand command) {
    throw _rejected();
  }

  @override
  Future<MfaTotpConfirmCompleted> confirmTotpEnrollment(
    MfaTotpConfirmCommand command,
  ) {
    throw _rejected();
  }

  @override
  Future<MfaListFactorsCompleted> listFactors(MfaListFactorsCommand command) {
    throw _rejected();
  }

  @override
  Future<MfaRevokeFactorCompleted> revokeFactor(
    MfaRevokeFactorCommand command,
  ) {
    throw _rejected();
  }

  @override
  Future<RecoveryCodeConsumeCompleted> consumeRecoveryCode(
    RecoveryCodeConsumeCommand command,
  ) {
    throw _rejected();
  }

  MfaOperationRejected _rejected() {
    return const MfaOperationRejected(
      code: 'mfa_gateway_not_configured',
      message: 'MFA operations are not configured for this runtime.',
      statusCode: 503,
    );
  }
}

String _formatDate(DateTime when) {
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final utc = when.toUtc();
  return '${months[utc.month - 1]} ${utc.day}, ${utc.year}';
}
