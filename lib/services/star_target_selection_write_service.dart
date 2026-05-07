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
}

abstract class BaselineServerSelectionWriter {
  Future<void> replaceSelection({
    required String restaurantId,
    required Iterable<BaselineCandidateShift> selectedCandidates,
    required Iterable<BaselineCandidateShift> previouslySelectedCandidates,
  });
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
    DateTime Function()? clock,
  }) : _client = client,
       _authSessionProvider = authSessionProvider,
       _clock = clock ?? DateTime.now;

  final StarTargetSelectionWriteClient _client;
  final AuthSession? Function() _authSessionProvider;
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
}
