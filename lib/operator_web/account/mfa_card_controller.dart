// Lane B9.3 - My Account MFA card state machine.
//
// The controller keeps the My Account MFA card presentation-only while
// reading the server-owned factor/removal state from the existing
// `/v1/auth/mfa/factors/list` route. The 24-hour grace timer is always
// derived from `mfa_factor_removal_requests.execute_after`; the client only
// formats the countdown and periodically refreshes so other devices stay in
// sync.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/web_security_gateway.dart';
import 'operator_web_account_actions.dart';

enum MfaCardStage { notEnrolled, enrolled, removalRequested, removable }

@immutable
class MfaCardState {
  const MfaCardState({
    required this.stage,
    required this.badgeLabel,
    required this.headline,
    required this.body,
    required this.primaryButtonLabel,
    required this.primaryButtonTooltip,
    required this.primaryActionKey,
    required this.factorCount,
    this.primaryFactor,
    this.pendingRemoval,
    this.loading = false,
    this.busy = false,
    this.errorMessage,
  });

  final MfaCardStage stage;
  final String badgeLabel;
  final String headline;
  final String body;
  final String primaryButtonLabel;
  final String primaryButtonTooltip;
  final String primaryActionKey;
  final int factorCount;
  final WebSecurityMfaFactor? primaryFactor;
  final WebSecurityMfaRemoval? pendingRemoval;
  final bool loading;
  final bool busy;
  final String? errorMessage;

  bool get hasPendingRemoval => pendingRemoval != null;
  bool get hasServerBackedPrimaryFactor => primaryFactor != null;
  bool get canRequestRemoval =>
      stage == MfaCardStage.enrolled && hasServerBackedPrimaryFactor;

  MfaCardState copyWith({
    bool? loading,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) {
    return MfaCardState(
      stage: stage,
      badgeLabel: badgeLabel,
      headline: headline,
      body: body,
      primaryButtonLabel: primaryButtonLabel,
      primaryButtonTooltip: primaryButtonTooltip,
      primaryActionKey: primaryActionKey,
      factorCount: factorCount,
      primaryFactor: primaryFactor,
      pendingRemoval: pendingRemoval,
      loading: loading ?? this.loading,
      busy: busy ?? this.busy,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class MfaCardController extends ChangeNotifier {
  MfaCardController({
    required bool initialMfaEnrolled,
    this.actions,
    DateTime Function()? now,
    Duration syncInterval = const Duration(minutes: 1),
    bool autoSync = false,
  }) : _locallyEnrolled = initialMfaEnrolled,
       _now = now ?? DateTime.now,
       _syncInterval = syncInterval,
       _autoSync = autoSync,
       _state = _localState(initialMfaEnrolled, now ?? DateTime.now);

  OperatorWebAccountActions? actions;
  bool _locallyEnrolled;
  final DateTime Function() _now;
  final Duration _syncInterval;
  final bool _autoSync;
  Timer? _syncTimer;
  MfaCardState _state;

  MfaCardState get state => _state;

  void start() {
    if (_autoSync) {
      _syncTimer ??= Timer.periodic(
        _syncInterval,
        (_) => unawaited(refresh(silent: true)),
      );
    }
    unawaited(refresh());
  }

  void update({
    required bool sessionMfaEnrolled,
    required OperatorWebAccountActions? actions,
  }) {
    this.actions = actions;
    if (sessionMfaEnrolled && !_locallyEnrolled) {
      _locallyEnrolled = true;
    }
    unawaited(refresh());
  }

  Future<void> refresh({bool silent = false}) async {
    final currentActions = actions;
    if (currentActions == null ||
        !currentActions.supportsAccountMfaServerState) {
      _setState(_deriveLocalState(loading: false));
      return;
    }
    if (!silent) {
      _setState(_state.copyWith(loading: true, clearError: true));
    }
    try {
      final listed = await currentActions.listAccountMfaFactors();
      if (listed == null) {
        _setState(_deriveLocalState(loading: false));
        return;
      }
      _locallyEnrolled = listed.factors.isNotEmpty;
      _setState(_deriveServerState(listed, loading: false));
    } catch (error) {
      _setState(
        _state.copyWith(
          loading: false,
          busy: false,
          errorMessage: _friendlyError(error),
        ),
      );
    }
  }

  Future<void> markEnrollmentConfirmed() async {
    _locallyEnrolled = true;
    await refresh();
  }

  Future<void> requestRemoval() async {
    final currentActions = actions;
    final factor = _state.primaryFactor;
    if (currentActions == null || factor == null) {
      _setState(
        _state.copyWith(
          errorMessage:
              'MFA status needs a server-confirmed authenticator before '
              'removal can be requested. Try again in a moment.',
        ),
      );
      return;
    }
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await currentActions.requestAccountMfaRemoval(factorId: factor.factorId);
      await refresh();
    } catch (error) {
      _setState(
        _state.copyWith(busy: false, errorMessage: _friendlyError(error)),
      );
    }
  }

  Future<void> cancelRemoval() async {
    final currentActions = actions;
    final removal = _state.pendingRemoval;
    if (currentActions == null || removal == null) {
      _setState(
        _state.copyWith(
          errorMessage: 'There is no pending MFA removal to cancel.',
        ),
      );
      return;
    }
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await currentActions.cancelAccountMfaRemoval(
        requestId: removal.requestId,
      );
      await refresh();
    } catch (error) {
      _setState(
        _state.copyWith(busy: false, errorMessage: _friendlyError(error)),
      );
    }
  }

  Future<void> turnOffAfterGrace() async {
    final currentActions = actions;
    if (currentActions == null) {
      _setState(
        _state.copyWith(
          errorMessage:
              'Two-factor sign-in status needs a server-confirmed authenticator '
              'before two-factor sign-in can be turned off.',
        ),
      );
      return;
    }
    _setState(_state.copyWith(busy: true, clearError: true));
    try {
      await currentActions.requireFreshMfaForAccountSecurity(
        actionLabel: 'turning off two-factor sign-in',
      );
      await refresh();
      if (_state.stage == MfaCardStage.removable) {
        _setState(
          _state.copyWith(
            busy: false,
            errorMessage:
                'Two-factor sign-in is ready to turn off, but the server '
                'still lists an active authenticator. Try again in a few '
                'minutes.',
          ),
        );
      }
    } catch (error) {
      _setState(
        _state.copyWith(busy: false, errorMessage: _friendlyError(error)),
      );
    }
  }

  MfaCardState _deriveLocalState({required bool loading}) {
    return _localState(_locallyEnrolled, _now).copyWith(loading: loading);
  }

  MfaCardState _deriveServerState(
    WebSecurityFactorsListed listed, {
    required bool loading,
  }) {
    final now = _now().toUtc();
    final factors = listed.factors;
    final activeFactor = factors.isEmpty ? null : factors.first;
    final pending = _pendingRemovalFor(activeFactor?.factorId, listed);
    if (activeFactor == null) {
      return _localState(false, _now).copyWith(loading: loading);
    }
    if (pending != null) {
      final stage = pending.executeAfter.isAfter(now)
          ? MfaCardStage.removalRequested
          : MfaCardStage.removable;
      return _stateFor(
        stage: stage,
        factorCount: factors.length,
        primaryFactor: activeFactor,
        pendingRemoval: pending,
        now: now,
      ).copyWith(loading: loading);
    }
    return _stateFor(
      stage: MfaCardStage.enrolled,
      factorCount: factors.length,
      primaryFactor: activeFactor,
      now: now,
    ).copyWith(loading: loading);
  }

  WebSecurityMfaRemoval? _pendingRemovalFor(
    String? factorId,
    WebSecurityFactorsListed listed,
  ) {
    if (factorId == null) return null;
    for (final removal in listed.removalRequests) {
      if (removal.factorId == factorId && removal.status == 'pending') {
        return removal;
      }
    }
    return null;
  }

  void _setState(MfaCardState next) {
    _state = next;
    notifyListeners();
  }

  static MfaCardState _localState(bool enrolled, DateTime Function() now) {
    return _stateFor(
      stage: enrolled ? MfaCardStage.enrolled : MfaCardStage.notEnrolled,
      factorCount: enrolled ? 1 : 0,
      now: now().toUtc(),
    );
  }

  static MfaCardState _stateFor({
    required MfaCardStage stage,
    required int factorCount,
    required DateTime now,
    WebSecurityMfaFactor? primaryFactor,
    WebSecurityMfaRemoval? pendingRemoval,
  }) {
    switch (stage) {
      case MfaCardStage.notEnrolled:
        return const MfaCardState(
          stage: MfaCardStage.notEnrolled,
          badgeLabel: 'Two-factor sign-in: Off',
          headline: 'Protect your sign-in',
          body:
              'Turn on two-factor sign-in so signing in requires your '
              'password and a one-time code from your authenticator app.',
          primaryButtonLabel: 'Enable two-factor sign-in',
          primaryButtonTooltip:
              'Start authenticator setup for this sign-in account.',
          primaryActionKey: 'account_section_mfa_enroll',
          factorCount: 0,
        );
      case MfaCardStage.enrolled:
        final factorCopy = factorCount == 1
            ? '1 method is enrolled.'
            : '$factorCount methods are enrolled.';
        final recoveryCodesViewed =
            primaryFactor?.recoveryCodesViewedAt != null;
        if (!recoveryCodesViewed) {
          return MfaCardState(
            stage: MfaCardStage.enrolled,
            badgeLabel: 'Two-factor sign-in: Enabled',
            headline: 'Save your recovery codes',
            body:
                '$factorCopy View your recovery codes before adding more '
                'sign-in methods or changing two-factor sign-in settings.',
            primaryButtonLabel: 'View recovery codes',
            primaryButtonTooltip:
                'Open the one-time recovery codes for this account.',
            primaryActionKey: 'account_section_mfa_view_recovery_codes',
            factorCount: factorCount,
            primaryFactor: primaryFactor,
          );
        }
        if (factorCount == 1) {
          return MfaCardState(
            stage: MfaCardStage.enrolled,
            badgeLabel: 'Two-factor sign-in: Enabled',
            headline: 'Add a backup sign-in method',
            body:
                '$factorCopy Recovery codes have been viewed. Add another '
                'method so one lost device does not block sign-in.',
            primaryButtonLabel: 'Add another method',
            primaryButtonTooltip:
                'Start setup for another two-factor sign-in method.',
            primaryActionKey: 'account_section_mfa_add_method',
            factorCount: factorCount,
            primaryFactor: primaryFactor,
          );
        }
        return MfaCardState(
          stage: MfaCardStage.enrolled,
          badgeLabel: 'Two-factor sign-in: Enabled',
          headline: 'Two-step verification is on',
          body:
              '$factorCopy Recovery codes have been viewed. You can manage '
              'methods or request removal from this account.',
          primaryButtonLabel: 'Manage two-factor sign-in',
          primaryButtonTooltip:
              'Open two-factor sign-in management for methods, recovery '
              'codes, and removal.',
          primaryActionKey: 'account_section_mfa_manage',
          factorCount: factorCount,
          primaryFactor: primaryFactor,
        );
      case MfaCardStage.removalRequested:
        final remaining = _formatRemaining(pendingRemoval!.executeAfter, now);
        return MfaCardState(
          stage: MfaCardStage.removalRequested,
          badgeLabel: 'Two-factor sign-in: Removal pending',
          headline: 'Two-step verification turns off in $remaining',
          body:
              'We wait 24 hours before turning off two-factor sign-in so '
              'that if someone got into your account, you have time to '
              'stop them.',
          primaryButtonLabel: 'Manage two-factor sign-in',
          primaryButtonTooltip:
              'Cancel the pending two-factor sign-in removal or review '
              'account protection.',
          primaryActionKey: 'account_section_mfa_cancel_removal',
          factorCount: factorCount,
          primaryFactor: primaryFactor,
          pendingRemoval: pendingRemoval,
        );
      case MfaCardStage.removable:
        return MfaCardState(
          stage: MfaCardStage.removable,
          badgeLabel: 'Two-factor sign-in: Ready to turn off',
          headline: 'Two-step verification can turn off now',
          body:
              'The 24-hour wait has passed. Turn off two-factor sign-in to '
              'complete the server check with a fresh sign-in.',
          primaryButtonLabel: 'Manage two-factor sign-in',
          primaryButtonTooltip:
              'Complete the requested two-factor sign-in removal after '
              'fresh sign-in.',
          primaryActionKey: 'account_section_mfa_turn_off_final',
          factorCount: factorCount,
          primaryFactor: primaryFactor,
          pendingRemoval: pendingRemoval,
        );
    }
  }

  static String _formatRemaining(DateTime executeAfter, DateTime now) {
    final remaining = executeAfter.toUtc().difference(now.toUtc());
    if (remaining.inMicroseconds <= 0) return 'now';
    final hours = remaining.inHours;
    final minutes = remaining.inMinutes.remainder(60);
    if (hours > 0) return '${hours}h ${minutes}m';
    final roundedMinutes = remaining.inMinutes < 1 ? 1 : remaining.inMinutes;
    return '${roundedMinutes}m';
  }

  String _friendlyError(Object error) {
    if (error is WebSecurityError) {
      if (error.code == 'mfa_freshness_required' ||
          error.code == 'insufficient_user_authentication') {
        return 'Please sign in again before changing two-factor sign-in. '
            'This protects your account settings.';
      }
      return 'Could not update two-factor sign-in (${error.code}). Try '
          'again in a moment.';
    }
    return 'Could not update two-factor sign-in. Try again in a moment.';
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }
}
