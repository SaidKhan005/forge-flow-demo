import 'package:crypto/crypto.dart' as crypto;

import '../auth/auth_session.dart';
import '../infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import 'sync/sync_proxy_client.dart';

class ManualCoversWriteException implements Exception {
  const ManualCoversWriteException({
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
    return 'ManualCoversWriteException(code: $code$status)';
  }
}

class AuthSessionManualCoversWriter {
  AuthSessionManualCoversWriter({
    required ManualCoversWriteClient client,
    required AuthSession? Function() authSessionProvider,
    Future<void> Function(ManualCoverEntry entry)? localMirrorWriter,
  }) : _client = client,
       _authSessionProvider = authSessionProvider,
       _localMirrorWriter = localMirrorWriter ?? writeLocalMirror;

  final ManualCoversWriteClient _client;
  final AuthSession? Function() _authSessionProvider;
  final Future<void> Function(ManualCoverEntry entry) _localMirrorWriter;

  Future<void> save(ManualCoverEntry entry) async {
    final session = _authSessionProvider();
    if (session == null) {
      throw const ManualCoversWriteException(
        code: 'auth_session_required',
        message: 'Sign in again before saving covers.',
      );
    }
    final locationId = entry.restaurantId.trim();
    if (locationId.isEmpty) {
      throw const ManualCoversWriteException(
        code: 'active_location_required',
        message: 'Choose a location before saving covers.',
      );
    }

    try {
      await _client.submitManualCovers(
        operatorId: session.operatorId,
        locationId: locationId,
        restaurantId: locationId,
        businessDate: entry.businessDate,
        servicePeriodKey: entry.daypart,
        covers: entry.covers,
        recordedAt: entry.recordedAt,
        idempotencyKey: _idempotencyKey(
          operatorId: session.operatorId,
          locationId: locationId,
          restaurantId: locationId,
          businessDate: entry.businessDate,
          servicePeriodKey: entry.daypart,
          covers: entry.covers,
        ),
      );
    } on SyncProxyClientException catch (error) {
      throw ManualCoversWriteException(
        code: error.code,
        message: error.message,
        statusCode: error.statusCode,
      );
    }

    await _localMirrorWriter(entry);
  }

  static Future<void> writeLocalMirror(ManualCoverEntry entry) async {
    final db = await SqliteDatabase.instance.database;
    await ManualCoverEntryDao(db).upsert(entry);
  }

  static String _idempotencyKey({
    required String operatorId,
    required String locationId,
    required String restaurantId,
    required String businessDate,
    required String servicePeriodKey,
    required int covers,
  }) {
    final digest = crypto.sha1.convert(
      '$operatorId|$locationId|$restaurantId|$businessDate|'
              '$servicePeriodKey|$covers'
          .codeUnits,
    );
    return 'mobile-covers-${digest.toString().substring(0, 32)}';
  }
}
