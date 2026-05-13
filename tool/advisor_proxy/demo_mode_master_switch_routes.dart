// Slice C-4 - Demo -> Live master switch proxy route.
//
// POST /v1/operators/:operatorId/locations/:locationId/demo-mode-master-switch
//
// One-way operator write. Demo -> Live flips every existing
// demo_mode_state row for the scoped location to is_demo=false. Live -> Demo
// is rejected at the route boundary with 409.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart';
import 'package:forge_and_flow/services/integration/demo_mode_state.dart';

const String demoModeMasterSwitchResource = 'demo-mode-master-switch';

class DemoModeMasterSwitchMatch {
  const DemoModeMasterSwitchMatch({
    required this.operatorId,
    required this.locationId,
  });

  final String operatorId;
  final String locationId;
}

class DemoModeMasterSwitchRejected implements Exception {
  const DemoModeMasterSwitchRejected({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;
}

abstract class DemoModeMasterSwitchGateway {
  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  });
}

class RepositoryDemoModeMasterSwitchGateway
    implements DemoModeMasterSwitchGateway {
  RepositoryDemoModeMasterSwitchGateway({required this.repository});

  final DemoModeStateRepository repository;

  @override
  Future<DemoModeMasterSwitchResult> flipAllDemoRowsToLive({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required DateTime flippedAt,
    required String idempotencyKey,
    required String requestBodyHash,
  }) async {
    try {
      return await repository.flipAllDemoRowsToLive(
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        flippedAt: flippedAt,
        idempotencyKey: idempotencyKey,
        requestBodyHash: requestBodyHash,
      );
    } on DemoModeStateRepositoryRejected catch (error) {
      throw DemoModeMasterSwitchRejected(
        code: error.code,
        message: error.message,
        statusCode: error.statusCode,
      );
    }
  }
}

class DemoModeMasterSwitchRouter {
  DemoModeMasterSwitchRouter({
    required DemoModeMasterSwitchGateway gateway,
    DateTime Function()? now,
  }) : _gateway = gateway,
       _now = now ?? DateTime.now;

  final DemoModeMasterSwitchGateway _gateway;
  final DateTime Function() _now;

  static DemoModeMasterSwitchMatch? match(String path, String method) {
    if (method != 'POST') return null;
    const prefix = '/v1/operators/';
    if (!path.startsWith(prefix)) return null;
    final tail = path.substring(prefix.length);
    final parts = tail.split('/');
    if (parts.length != 4 ||
        parts[1] != 'locations' ||
        parts[3] != demoModeMasterSwitchResource) {
      return null;
    }
    return DemoModeMasterSwitchMatch(
      operatorId: Uri.decodeComponent(parts[0]),
      locationId: Uri.decodeComponent(parts[2]),
    );
  }

  Future<({int statusCode, Map<String, Object?> body})> handle({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String idempotencyKey,
    required Map<String, Object?> body,
  }) async {
    _rejectLiveToDemo(body);
    final result = await _gateway.flipAllDemoRowsToLive(
      operatorId: operatorId,
      locationId: locationId,
      actorUserId: actorUserId,
      flippedAt: _now().toUtc(),
      idempotencyKey: idempotencyKey,
      requestBodyHash: _hashBody(body),
    );
    if (!result.flippedAny) {
      throw const DemoModeMasterSwitchRejected(
        code: 'demo_mode_already_live',
        message: 'live data has arrived; demo mode cannot be restored',
        statusCode: 409,
      );
    }
    return (
      statusCode: 200,
      body: <String, Object?>{
        'demo_mode_states': <Map<String, Object?>>[
          for (final record in result.records) _recordJson(record),
        ],
        'flipped_count': result.flippedCount,
      },
    );
  }

  static void _rejectLiveToDemo(Map<String, Object?> body) {
    final targetMode = (body['target_mode'] ?? body['targetMode'])
        ?.toString()
        .trim()
        .toLowerCase();
    final requestedIsDemo = body['is_demo'] ?? body['isDemo'];
    if (targetMode == 'demo' || requestedIsDemo == true) {
      throw const DemoModeMasterSwitchRejected(
        code: 'live_to_demo_refused',
        message: 'live data has arrived; demo mode cannot be restored',
        statusCode: 409,
      );
    }
    if (targetMode != null && targetMode.isNotEmpty && targetMode != 'live') {
      throw const DemoModeMasterSwitchRejected(
        code: 'invalid_target_mode',
        message: 'target_mode must be live',
        statusCode: 400,
      );
    }
  }

  static Map<String, Object?> _recordJson(DemoModeRecord record) {
    return <String, Object?>{
      'operator_id': record.operatorId,
      'location_id': record.locationId,
      'category': record.category.name,
      'is_demo': record.isDemo,
      if (record.flippedToLiveAt != null)
        'flipped_to_live_at': record.flippedToLiveAt!.toUtc().toIso8601String(),
      if (record.flippedByConnectionId != null)
        'flipped_by_connection_id': record.flippedByConnectionId,
    };
  }
}

String _hashBody(Map<String, Object?> body) {
  return sha256.convert(utf8.encode(_canonicalJson(body))).toString();
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
  return jsonEncode(value);
}
