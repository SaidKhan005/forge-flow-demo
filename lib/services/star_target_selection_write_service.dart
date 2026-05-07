import 'package:crypto/crypto.dart' as crypto;

import '../auth/auth_session.dart';
import '../models/baseline_candidate_shift.dart';

enum StarTargetSelectionWriteAction { select, clear }

abstract class StarTargetSelectionWriteClient {
  Future<void> submitSelectedStarDecision({
    required String operatorId,
    required String locationId,
    required StarTargetSelectionWriteAction action,
    required String idempotencyKey,
    required Map<String, Object?> body,
  });

  Future<void> submitSelectedStarTargetProjection({
    required String operatorId,
    required String locationId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  });
}

abstract class BaselineServerSelectionWriter {
  Future<void> replaceSelection({
    required String restaurantId,
    required Iterable<BaselineCandidateShift> selectedCandidates,
    required Iterable<BaselineCandidateShift> previouslySelectedCandidates,
  });
}

typedef StarTargetProjectionContextProvider =
    Future<StarTargetProjectionContext?> Function({
      required String restaurantId,
      required Iterable<BaselineCandidateShift> selectedCandidates,
    });

class StarTargetProjectionContext {
  const StarTargetProjectionContext({
    required this.effectiveStart,
    required this.effectiveEnd,
    required this.calibrationWindowStart,
    required this.calibrationWindowEnd,
    required this.targetCplh,
    required this.targetSplh,
    required this.targetPpa,
    required this.fohWage,
    required this.bohWage,
    required this.opzFloorCplh,
    required this.opzCeilingCplh,
    required this.reason,
  });

  final String effectiveStart;
  final String effectiveEnd;
  final String calibrationWindowStart;
  final String calibrationWindowEnd;
  final double targetCplh;
  final double targetSplh;
  final double targetPpa;
  final double fohWage;
  final double bohWage;
  final double opzFloorCplh;
  final double opzCeilingCplh;
  final String reason;

  Map<String, Object?> toBody({required String restaurantId}) {
    return <String, Object?>{
      'restaurant_id': restaurantId,
      'effective_start': effectiveStart,
      'effective_end': effectiveEnd,
      'calibration_window_start': calibrationWindowStart,
      'calibration_window_end': calibrationWindowEnd,
      'standards': <String, Object?>{
        'target_cplh': targetCplh,
        'target_splh': targetSplh,
        'target_ppa': targetPpa,
        'foh_wage': fohWage,
        'boh_wage': bohWage,
        'opz_floor_cplh': opzFloorCplh,
        'opz_ceiling_cplh': opzCeilingCplh,
      },
      'reason': reason,
    };
  }
}

class StarTargetSelectionWriteException implements Exception {
  const StarTargetSelectionWriteException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() {
    final status = statusCode == null ? '' : ', statusCode: $statusCode';
    return 'StarTargetSelectionWriteException(code: $code$status)';
  }
}

class AuthSessionStarTargetSelectionWriter
    implements BaselineServerSelectionWriter {
  AuthSessionStarTargetSelectionWriter({
    required StarTargetSelectionWriteClient client,
    required AuthSession? Function() authSessionProvider,
    StarTargetProjectionContextProvider? projectionContextProvider,
    DateTime Function()? clock,
  }) : _client = client,
       _authSessionProvider = authSessionProvider,
       _projectionContextProvider = projectionContextProvider,
       _clock = clock ?? DateTime.now;

  final StarTargetSelectionWriteClient _client;
  final AuthSession? Function() _authSessionProvider;
  final StarTargetProjectionContextProvider? _projectionContextProvider;
  final DateTime Function() _clock;

  @override
  Future<void> replaceSelection({
    required String restaurantId,
    required Iterable<BaselineCandidateShift> selectedCandidates,
    required Iterable<BaselineCandidateShift> previouslySelectedCandidates,
  }) async {
    final session = _authSessionProvider();
    if (session == null) {
      throw const StarTargetSelectionWriteException(
        code: 'auth_session_required',
        message: 'Sign in again before changing star shifts.',
      );
    }

    final selectedByKey = <String, BaselineCandidateShift>{
      for (final candidate in selectedCandidates)
        candidate.recordKey: candidate,
    };
    final previousByKey = <String, BaselineCandidateShift>{
      for (final candidate in previouslySelectedCandidates)
        candidate.recordKey: candidate,
    };

    final toClear = previousByKey.entries
        .where((entry) => !selectedByKey.containsKey(entry.key))
        .map((entry) => entry.value)
        .toList(growable: false);
    final toSelect = selectedByKey.entries
        .where((entry) => !previousByKey.containsKey(entry.key))
        .map((entry) => entry.value)
        .toList(growable: false);

    for (final candidate in toClear) {
      await _submit(
        session: session,
        restaurantId: restaurantId,
        candidate: candidate,
        action: StarTargetSelectionWriteAction.clear,
      );
    }
    for (final candidate in toSelect) {
      await _submit(
        session: session,
        restaurantId: restaurantId,
        candidate: candidate,
        action: StarTargetSelectionWriteAction.select,
      );
    }
    if (selectedByKey.isNotEmpty &&
        (toSelect.isNotEmpty || toClear.isNotEmpty)) {
      await _submitProjection(
        session: session,
        restaurantId: restaurantId,
        selectedCandidates: selectedByKey.values,
      );
    }
  }

  Future<void> _submit({
    required AuthSession session,
    required String restaurantId,
    required BaselineCandidateShift candidate,
    required StarTargetSelectionWriteAction action,
  }) {
    final businessDate = candidate.businessDate;
    if (businessDate == null || businessDate.trim().isEmpty) {
      throw StarTargetSelectionWriteException(
        code: 'candidate_business_date_missing',
        message:
            'This star shift is missing a server business date. Sync closed '
            'history before changing the selection.',
      );
    }
    return _client.submitSelectedStarDecision(
      operatorId: session.operatorId,
      locationId: session.locationId,
      action: action,
      idempotencyKey: _idempotencyKey(
        action: action,
        restaurantId: restaurantId,
        recordKey: candidate.recordKey,
      ),
      body: _bodyFor(
        restaurantId: restaurantId,
        candidate: candidate,
        businessDate: businessDate,
        action: action,
      ),
    );
  }

  Future<void> _submitProjection({
    required AuthSession session,
    required String restaurantId,
    required Iterable<BaselineCandidateShift> selectedCandidates,
  }) async {
    final provider = _projectionContextProvider;
    if (provider == null) return;
    final selected = selectedCandidates.toList(growable: false);
    if (selected.isEmpty) return;
    final context = await provider(
      restaurantId: restaurantId,
      selectedCandidates: selected,
    );
    if (context == null) return;
    await _client.submitSelectedStarTargetProjection(
      operatorId: session.operatorId,
      locationId: session.locationId,
      idempotencyKey: _projectionIdempotencyKey(
        restaurantId: restaurantId,
        selectedRecordKeys: selected.map((candidate) => candidate.recordKey),
      ),
      body: context.toBody(restaurantId: restaurantId),
    );
  }

  Map<String, Object?> _bodyFor({
    required String restaurantId,
    required BaselineCandidateShift candidate,
    required String businessDate,
    required StarTargetSelectionWriteAction action,
  }) {
    final base = <String, Object?>{
      'restaurant_id': restaurantId,
      'record_key': candidate.recordKey,
      'week_id': candidate.weekId,
      'day_label': candidate.dayLabel,
      'daypart': candidate.daypart,
      'business_date': businessDate,
      'service_period_key': candidate.daypart,
      'reason': action == StarTargetSelectionWriteAction.clear
          ? 'manager cleared star on mobile'
          : 'manager selected star on mobile',
    };
    if (action == StarTargetSelectionWriteAction.clear) {
      return base;
    }
    return <String, Object?>{
      ...base,
      'covers': candidate.covers,
      'cplh': candidate.cplh,
      'splh': candidate.splh,
      'ppa': candidate.ppa,
      'primary_lever_id': candidate.primaryLeverId,
      'actual_labor_pct': candidate.actualLaborPct,
      'has_actual_labor_pct_truth': candidate.hasActualLaborPctTruth,
      'candidate_snapshot': <String, Object?>{
        'source': 'mobile_closed_shift_candidate',
        'record_key': candidate.recordKey,
        'week_id': candidate.weekId,
        'business_date': businessDate,
        'covers': candidate.covers,
        'cplh': candidate.cplh,
        'splh': candidate.splh,
        'ppa': candidate.ppa,
        'primary_lever_id': candidate.primaryLeverId,
        'actual_labor_pct': candidate.actualLaborPct,
        'has_actual_labor_pct_truth': candidate.hasActualLaborPctTruth,
      },
    };
  }

  String _idempotencyKey({
    required StarTargetSelectionWriteAction action,
    required String restaurantId,
    required String recordKey,
  }) {
    final digest = crypto.sha1.convert('$restaurantId|$recordKey'.codeUnits);
    final timestamp = _clock().toUtc().microsecondsSinceEpoch;
    return 'mobile-star-${action.name}-${digest.toString().substring(0, 20)}-$timestamp';
  }

  String _projectionIdempotencyKey({
    required String restaurantId,
    required Iterable<String> selectedRecordKeys,
  }) {
    final keys = selectedRecordKeys.toList(growable: false)..sort();
    final digest = crypto.sha1.convert(
      '$restaurantId|${keys.join('|')}'.codeUnits,
    );
    final timestamp = _clock().toUtc().microsecondsSinceEpoch;
    return 'mobile-star-project-${digest.toString().substring(0, 20)}-$timestamp';
  }
}
