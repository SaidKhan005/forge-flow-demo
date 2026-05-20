// Phase 11W.live - conditional CSV download helper for Operator Web.

import 'web_team_audit_log_gateway.dart';
import 'operator_web_csv_download_stub.dart'
    if (dart.library.html) 'operator_web_csv_download_web.dart'
    as impl;

Future<void> downloadOperatorWebCsv(WebAuditLogCsvExport export) {
  return impl.downloadOperatorWebCsv(export);
}
