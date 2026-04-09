/// Metadata for one import execution against a restaurant.
library;

class ImportRun {
  final String importRunId;
  final String restaurantId;
  final String mode;
  final String startedAt;
  final String? completedAt;
  final String status;
  final String? cursorJson;
  final String? errorSummary;

  const ImportRun({
    required this.importRunId,
    required this.restaurantId,
    required this.mode,
    required this.startedAt,
    this.completedAt,
    required this.status,
    this.cursorJson,
    this.errorSummary,
  });

  Map<String, dynamic> toMap() => {
        'import_run_id': importRunId,
        'restaurant_id': restaurantId,
        'mode': mode,
        'started_at': startedAt,
        'completed_at': completedAt,
        'status': status,
        'cursor_json': cursorJson,
        'error_summary': errorSummary,
      };

  factory ImportRun.fromMap(Map<String, dynamic> m) => ImportRun(
        importRunId: m['import_run_id'] as String,
        restaurantId: m['restaurant_id'] as String,
        mode: m['mode'] as String,
        startedAt: m['started_at'] as String,
        completedAt: m['completed_at'] as String?,
        status: m['status'] as String,
        cursorJson: m['cursor_json'] as String?,
        errorSummary: m['error_summary'] as String?,
      );
}
