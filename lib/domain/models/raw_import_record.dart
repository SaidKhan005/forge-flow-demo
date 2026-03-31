/// One raw imported record from an external source.

class RawImportRecord {
  final String rawImportId;
  final String importRunId;
  final String restaurantId;
  final String sourceType;
  final String sourceEntityType;
  final String sourceEntityId;
  final String payloadHash;
  final String businessDate;
  final String receivedAt;
  final String status;
  final String? payloadJson;
  final String? errorSummary;

  const RawImportRecord({
    required this.rawImportId,
    required this.importRunId,
    required this.restaurantId,
    required this.sourceType,
    required this.sourceEntityType,
    required this.sourceEntityId,
    required this.payloadHash,
    required this.businessDate,
    required this.receivedAt,
    required this.status,
    this.payloadJson,
    this.errorSummary,
  });

  Map<String, dynamic> toMap() => {
        'raw_import_id': rawImportId,
        'import_run_id': importRunId,
        'restaurant_id': restaurantId,
        'source_type': sourceType,
        'source_entity_type': sourceEntityType,
        'source_entity_id': sourceEntityId,
        'payload_hash': payloadHash,
        'business_date': businessDate,
        'received_at': receivedAt,
        'status': status,
        'payload_json': payloadJson,
        'error_summary': errorSummary,
      };

  factory RawImportRecord.fromMap(Map<String, dynamic> m) => RawImportRecord(
        rawImportId: m['raw_import_id'] as String,
        importRunId: m['import_run_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        sourceType: m['source_type'] as String,
        sourceEntityType: m['source_entity_type'] as String,
        sourceEntityId: m['source_entity_id'] as String,
        payloadHash: m['payload_hash'] as String,
        businessDate: m['business_date'] as String,
        receivedAt: m['received_at'] as String,
        status: m['status'] as String,
        payloadJson: m['payload_json'] as String?,
        errorSummary: m['error_summary'] as String?,
      );
}
