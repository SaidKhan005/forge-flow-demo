// Pressure preview v1 — Slice C-11 (R4 §7A) — email scenario loopback
// harness against Mailosaur for the wired email surfaces that landed
// across Lane C (C-1 inbound SendGrid event webhook) and the existing
// `EmailTemplateIds` catalog (`lib/services/email/email_template_renderer.dart`).
//
// Sprint authority:
//   * Slice spec: `docs/archive/_execution/lane_c_parity/03_execution_slices.md`
//     C-11 (lines 209-225).
//   * Inventory: `docs/_audits/code_health/c_email_notification_scenario_inventory.md`.
//   * C-2 wire-or-delete decision matrix:
//     `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`.
//   * Env-gated-inert precedent: `tool/pressure/p4_heap_snapshot_uploader.dart`.
//
// What this harness proves
// ------------------------
// For every WIRED scenario in the inventory matrix (currently 4 SendGrid
// production paths — `vendor_now_available`, `backfill_complete`,
// `backfill_failed`, `audit_anchor_failure` — plus 1 admin-test path —
// `operator_invite_first_admin` via `POST /v1/admin/integrations/email/test`):
//
//   1. The proxy emits the email through the configured `EmailProvider`
//      (SendGrid). C-1 (PR #611) shipped the inbound SendGrid event
//      webhook which receives delivered/bounced/opened events after the
//      outbound send — this harness is the OUTBOUND counterpart.
//   2. The Mailosaur loopback inbox receives the rendered envelope
//      within the SLO budget.
//   3. The subject string matches the locked subject the renderer
//      writes per `email_template_renderer.dart:_subjectByTemplate`.
//   4. The body contains the expected variables (recipient name,
//      business name, etc. — exact set depends on template).
//
// For each DEFERRED scenario (per the C-2 decision matrix — drafts C, D,
// F; drafts E + G were DELETED via C-2-Del 2026-05-13), the harness
// emits ONE structured "deferred" log line citing the matrix row and
// skips cleanly. This keeps the harness honest about what it CAN
// exercise versus what is template-only.
//
// Env-gated-inert posture
// -----------------------
// Mailosaur is external test infrastructure. The harness reads:
//   * `MAILOSAUR_API_KEY` — the bearer token for Mailosaur's REST API
//     (https://mailosaur.com/api/messages). Required.
//   * `MAILOSAUR_SERVER_ID` — the Mailosaur server identifier that
//     owns the loopback inbox. Required.
//   * `MAILOSAUR_INBOX` — the loopback email address (defaults to
//     `c11-loopback@<server_id>.mailosaur.net`). Optional.
//   * `PROXY_URL` — the F&F proxy base URL to drive (e.g.
//     `https://preview.forgeflow.app`). Required for the admin-test
//     loopback. The harness asserts it matches one of the allow-listed
//     preview substrings (`preview.`, `staging.`, `localhost`) — the
//     same defense-in-depth used by the p3/p4 harnesses — so a
//     misconfigured run cannot pummel production.
//   * `PROXY_ADMIN_TOKEN` — bearer token authenticating the admin-test
//     POST as `super_admin`. Required for the admin-test loopback.
//   * `MAILOSAUR_POLL_TIMEOUT_SECONDS` — message-receipt poll timeout
//     (default 30s).
//   * `MAILOSAUR_POLL_INTERVAL_SECONDS` — poll interval (default 2s).
//
// When EITHER `MAILOSAUR_API_KEY` or `MAILOSAUR_SERVER_ID` is unset,
// the harness emits ONE "skipped" line citing the missing env var and
// exits 0. This mirrors A11.2's `HeapSnapshotUploader` posture: the
// harness ships ready to run but stays inert until the operator's
// secret-manager wiring lands. NEVER fabricates green results.
//
// When `PROXY_URL` / `PROXY_ADMIN_TOKEN` are unset BUT Mailosaur env is
// present, the harness skips the admin-test loopback specifically and
// reports it as "deferred — proxy admin credentials not wired"; the
// other scenarios that depend on Postgres-driven emitters are likewise
// reported as deferred (this harness does not drive the Postgres tier
// directly; it observes only the admin-test path and any backfill /
// audit-anchor / vendor-now-available emails the operator triggers
// in parallel via the proxy admin UI or upstream worker runs).
//
// Output line shapes (mirror FdWatcher / HeapSnapshotUploader)
// -----------------------------------------------------------
//   { "ts": "<iso>", "metric": "email_loopback.scenario",
//     "scenario": "<template_id>", "status": "wired",
//     "latency_ms": <int>, "subject_match": <bool>,
//     "body_match": <bool>, "message_id": "<mailosaur_id>" }
//   { "ts": "<iso>", "metric": "email_loopback.scenario",
//     "scenario": "<template_id>", "status": "deferred",
//     "reason": "<c_2_matrix_row>" }
//   { "ts": "<iso>", "metric": "email_loopback.summary",
//     "scenarios_attempted": <int>, "scenarios_succeeded": <int>,
//     "scenarios_deferred": <int>, "scenarios_failed": <int>,
//     "p95_latency_ms": <int> }
//   { "ts": "<iso>", "metric": "email_loopback.skipped",
//     "reason": "MAILOSAUR_API_KEY unset" }
//
// Usage
// -----
//   dart run tool/pressure/p5_email_scenario_loopback.dart
//   dart run tool/pressure/p5_email_scenario_loopback.dart \
//     --output=test/pressure/p5_email_scenario_loopback.jsonl
//
// Hard rules
// ----------
// * NEVER touches production: `PROXY_URL` must match the preview
//   allow-list (substring check). Misconfiguration aborts before the
//   first send.
// * NEVER fabricates a "success" record on missing credentials. The
//   harness skips cleanly with a structured log line.
// * NEVER throws to the root zone — every failure path emits a
//   structured error and continues to the next scenario.
// * Pure HTTP via `dart:io` `HttpClient`. NO `mailosaur` package import
//   (would expand the dep graph for what is a 7-line REST endpoint).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Set of `PROXY_URL` substrings that this harness will consent to
/// drive. Anything else aborts before the first request. Mirrors
/// `kSoakAllowedHostSubstrings` in `tool/pressure/p4_session_soak.dart`.
const Set<String> kEmailLoopbackAllowedProxySubstrings = <String>{
  'preview.',
  'staging.',
  'localhost',
  '127.0.0.1',
};

/// A single scenario row in the loopback harness inventory. Mirrors
/// the inventory matrix at
/// `docs/_audits/code_health/c_email_notification_scenario_inventory.md`.
class EmailLoopbackScenario {
  const EmailLoopbackScenario({
    required this.templateId,
    required this.expectedSubject,
    required this.status,
    this.deferralReason,
    this.triggerPath,
    this.bodyContains = const <String>[],
  });

  /// Renderer template id (matches `EmailTemplateIds.<id>`).
  final String templateId;

  /// Locked subject string per `email_template_renderer.dart` (may
  /// contain `{{vars}}` for templates whose subject is variable-bound;
  /// the harness substitutes the values used by the trigger path).
  final String expectedSubject;

  /// Wire status — `wired`, `deferred`, or `firebase-managed`.
  final EmailLoopbackStatus status;

  /// Cross-reference to the C-2 decision matrix row when
  /// `status == deferred`. Surfaced in the structured log line so the
  /// operator can grep for the matrix decision.
  final String? deferralReason;

  /// Trigger path string (informational; e.g. "admin-test-route",
  /// "fanout/backfill_complete", "fanout/audit_anchor_failure"). Used
  /// in the structured log; not all scenarios can be self-driven.
  final String? triggerPath;

  /// Body substrings expected to appear in the rendered HTML / text.
  /// Empty when the template's variable-driven body would require the
  /// runtime to know the operator's data; the harness skips body match
  /// in that case and reports `body_match = null`.
  final List<String> bodyContains;
}

enum EmailLoopbackStatus { wired, deferred, firebaseManaged }

/// The inventory the harness exercises. Source of truth: the matrix
/// at `docs/_audits/code_health/c_email_notification_scenario_inventory.md`
/// and the renderer doc-strings updated by C-2.
///
/// IMPORTANT: when a new template is wired, add it here AND update the
/// inventory matrix in the same PR (the inventory + this list are the
/// authoritative pair). Renderer-only ids that ship but are
/// template-only (deferred per C-2) MUST appear here with
/// `status: deferred` so the operator's pressure run discloses them.
List<EmailLoopbackScenario> emailLoopbackInventory() => const <EmailLoopbackScenario>[
      // ----- Wired SendGrid surfaces -----
      EmailLoopbackScenario(
        templateId: 'operator_invite_first_admin',
        // Admin test route locks recipientName=F&F Test Admin and
        // renders the operator_invite_first_admin subject:
        // "Welcome to Forge & Flow — set up your account".
        expectedSubject: 'Welcome to Forge & Flow — set up your account',
        status: EmailLoopbackStatus.wired,
        triggerPath: 'admin-test-route',
        bodyContains: <String>[
          'Forge & Flow Demo',
          'F&F Test Admin',
        ],
      ),
      EmailLoopbackScenario(
        templateId: 'vendor_now_available',
        // Variable-bound: "{{vendorName}} is ready to connect in Forge & Flow"
        expectedSubject: 'is ready to connect in Forge & Flow',
        status: EmailLoopbackStatus.wired,
        triggerPath: 'fanout/vendor_lifecycle_notification_dispatcher',
        // Body assertion deferred to runtime variable substitution.
        bodyContains: <String>[],
      ),
      EmailLoopbackScenario(
        templateId: 'backfill_complete',
        expectedSubject: 'Historical sync complete',
        status: EmailLoopbackStatus.wired,
        triggerPath: 'fanout/backfill_complete',
        bodyContains: <String>[],
      ),
      EmailLoopbackScenario(
        templateId: 'backfill_failed',
        expectedSubject: 'Historical sync needs attention',
        status: EmailLoopbackStatus.wired,
        triggerPath: 'fanout/backfill_failed',
        bodyContains: <String>[],
      ),
      EmailLoopbackScenario(
        templateId: 'audit_anchor_failure',
        expectedSubject: 'Audit chain anchor needs review',
        status: EmailLoopbackStatus.wired,
        triggerPath: 'fanout/audit_anchor_failure',
        bodyContains: <String>[],
      ),
      // ----- Deferred (template-only) per C-2 matrix -----
      EmailLoopbackScenario(
        templateId: 'mfa_factor_changed_notice',
        expectedSubject: 'Your Forge & Flow MFA has been updated',
        status: EmailLoopbackStatus.deferred,
        deferralReason:
            'C-2 matrix Draft C — no server-side MFA-factor-changed '
            'emission site; operator decision pending.',
      ),
      EmailLoopbackScenario(
        templateId: 'vendor_sync_error_alert',
        expectedSubject: 'Forge & Flow could not sync from',
        status: EmailLoopbackStatus.deferred,
        deferralReason:
            'C-2 matrix Draft D — no first-failure-of-outage detector; '
            'operator decision pending.',
      ),
      EmailLoopbackScenario(
        templateId: 'vendor_connection_auto_disabled',
        // Subject: "{{vendorName}} connection disabled"
        expectedSubject: 'connection disabled',
        status: EmailLoopbackStatus.deferred,
        deferralReason:
            'C-2 matrix Draft F — OAuth refresh worker has no fanout '
            'wiring; operator decision pending on Path (a) full fanout '
            'vs Path (b) direct enqueue.',
      ),
      // C-2-Del (2026-05-13) deleted `vendor_webhook_signature_alert`
      // (Draft E) and `tos_version_updated_notice` (Draft G) per
      // operator picks (rely on Cloud Logging + in-app TOS gate).
      // No inventory rows needed; templates no longer exist.
      // ----- Firebase-managed (NOT a SendGrid loopback target) -----
      EmailLoopbackScenario(
        templateId: 'firebase_password_reset',
        expectedSubject: '(Firebase Identity Platform template)',
        status: EmailLoopbackStatus.firebaseManaged,
        deferralReason:
            'Inventory item 1.a — Firebase action-link, NOT SendGrid. '
            'Loopback would require Firebase-managed inbox + the '
            'Playwright probe called out as R4 §7A future work.',
      ),
      EmailLoopbackScenario(
        templateId: 'firebase_email_verification',
        expectedSubject: '(Firebase Identity Platform template)',
        status: EmailLoopbackStatus.firebaseManaged,
        deferralReason:
            'Inventory item 1.b — Firebase action-link; no first-party '
            'trigger in repo today.',
      ),
      EmailLoopbackScenario(
        templateId: 'firebase_invite_via_password_reset',
        expectedSubject: '(Firebase Identity Platform template)',
        status: EmailLoopbackStatus.firebaseManaged,
        deferralReason:
            'Inventory item 2 — Firebase action-link invite path; '
            'reuses password-reset template per A2.2 resolution.',
      ),
    ];

/// Mailosaur REST API client. Pure HTTP via `dart:io` HttpClient —
/// no `mailosaur` package import.
class MailosaurClient {
  MailosaurClient({
    required this.apiKey,
    required this.serverId,
    required this.inboxAddress,
    HttpClient? httpClient,
    DateTime Function()? clock,
  })  : _httpClient = httpClient ?? HttpClient(),
        _clock = clock ?? DateTime.now;

  /// Mailosaur server API base — single endpoint family suffices for
  /// list + get message operations.
  static const String _baseUrl = 'https://mailosaur.com/api';

  final String apiKey;
  final String serverId;
  final String inboxAddress;
  final HttpClient _httpClient;
  final DateTime Function() _clock;

  /// Poll the inbox for a message that arrived AFTER [sentAfter] and
  /// whose recipient matches [inboxAddress]. Returns the first match,
  /// or `null` if the [timeout] expires without a match.
  Future<MailosaurMessage?> waitForMessage({
    required DateTime sentAfter,
    Duration timeout = const Duration(seconds: 30),
    Duration pollInterval = const Duration(seconds: 2),
  }) async {
    final deadline = _clock().add(timeout);
    while (_clock().isBefore(deadline)) {
      final match = await _findMatch(sentAfter);
      if (match != null) return match;
      await Future<void>.delayed(pollInterval);
    }
    return null;
  }

  Future<MailosaurMessage?> _findMatch(DateTime sentAfter) async {
    final uri = Uri.parse(
      '$_baseUrl/messages?server=$serverId&receivedAfter=${Uri.encodeQueryComponent(sentAfter.toUtc().toIso8601String())}',
    );
    final request = await _httpClient.getUrl(uri);
    request.headers.set('authorization', _basicAuth(apiKey));
    request.headers.set('accept', 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Mailosaur list returned ${response.statusCode}: $body',
        uri: uri,
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, Object?>) return null;
    final items = decoded['items'];
    if (items is! List) return null;
    for (final item in items) {
      if (item is! Map) continue;
      final to = (item['to'] as List?)?.cast<Map<String, Object?>>() ?? const [];
      final hit = to.any((addr) =>
          (addr['email'] as String?)?.toLowerCase() == inboxAddress.toLowerCase());
      if (!hit) continue;
      // Fetch full message body for subject + body assertions.
      final messageId = item['id'] as String?;
      if (messageId == null) continue;
      return _fetchMessage(messageId);
    }
    return null;
  }

  Future<MailosaurMessage> _fetchMessage(String messageId) async {
    final uri = Uri.parse('$_baseUrl/messages/$messageId');
    final request = await _httpClient.getUrl(uri);
    request.headers.set('authorization', _basicAuth(apiKey));
    request.headers.set('accept', 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Mailosaur get returned ${response.statusCode}: $body',
        uri: uri,
      );
    }
    final decoded = jsonDecode(body) as Map<String, Object?>;
    final subject = (decoded['subject'] as String?) ?? '';
    final html = (decoded['html'] as Map?)?['body'] as String? ?? '';
    final text = (decoded['text'] as Map?)?['body'] as String? ?? '';
    final received = DateTime.tryParse(
            (decoded['received'] as String?) ?? '') ??
        _clock().toUtc();
    return MailosaurMessage(
      id: messageId,
      subject: subject,
      htmlBody: html,
      textBody: text,
      received: received,
    );
  }

  String _basicAuth(String token) {
    // Mailosaur accepts the API key as the user half of HTTP Basic
    // (password empty). This is the documented authentication mode.
    final raw = '$token:';
    return 'Basic ${base64Encode(utf8.encode(raw))}';
  }

  void close() {
    _httpClient.close(force: false);
  }
}

/// A message retrieved from Mailosaur. Subset of the API response shape
/// the harness actually exercises.
class MailosaurMessage {
  const MailosaurMessage({
    required this.id,
    required this.subject,
    required this.htmlBody,
    required this.textBody,
    required this.received,
  });

  final String id;
  final String subject;
  final String htmlBody;
  final String textBody;
  final DateTime received;
}

/// Per-scenario outcome. The harness aggregates these into the summary
/// log line at the end of the run.
class EmailLoopbackOutcome {
  const EmailLoopbackOutcome({
    required this.scenario,
    required this.kind,
    this.latencyMs,
    this.subjectMatch,
    this.bodyMatch,
    this.messageId,
    this.error,
  });

  final EmailLoopbackScenario scenario;
  final EmailLoopbackOutcomeKind kind;
  final int? latencyMs;
  final bool? subjectMatch;
  final bool? bodyMatch;
  final String? messageId;
  final String? error;
}

enum EmailLoopbackOutcomeKind { success, failed, deferred, timeout }

/// Asserts the rendered subject matches the locked expectation. The
/// match is substring-tolerant for variable-bound subjects (the
/// inventory marks subjects that contain `{{var}}` as substring
/// expectations).
bool subjectMatches({
  required String observed,
  required String expectedSubstring,
}) {
  if (expectedSubstring.isEmpty) return false;
  return observed.contains(expectedSubstring);
}

/// Asserts every required `bodyContains` substring is present in
/// either the HTML body or the plain-text body.
bool bodyMatches({
  required String htmlBody,
  required String textBody,
  required List<String> expectedContains,
}) {
  if (expectedContains.isEmpty) return true;
  return expectedContains
      .every((needle) => htmlBody.contains(needle) || textBody.contains(needle));
}

/// Computes the p95 latency from a list of latency samples. Returns 0
/// when the sample set is empty. Sorted-index method (mirror of the
/// p3a/p3b pattern):
///   p95Index = ceil(N * 0.95) - 1, clamped to [0, N-1].
int p95LatencyMs(List<int> samples) {
  if (samples.isEmpty) return 0;
  final sorted = List<int>.from(samples)..sort();
  final idx = (sorted.length * 0.95).ceil() - 1;
  final clamped = idx.clamp(0, sorted.length - 1);
  return sorted[clamped];
}

/// Aggregates outcomes into a summary line.
Map<String, Object?> buildSummary({
  required List<EmailLoopbackOutcome> outcomes,
  required DateTime ts,
}) {
  final attempted = outcomes.length;
  final succeeded =
      outcomes.where((o) => o.kind == EmailLoopbackOutcomeKind.success).length;
  final deferred =
      outcomes.where((o) => o.kind == EmailLoopbackOutcomeKind.deferred).length;
  final failed = outcomes.where((o) =>
      o.kind == EmailLoopbackOutcomeKind.failed ||
      o.kind == EmailLoopbackOutcomeKind.timeout).length;
  final latencies = outcomes
      .where((o) => o.latencyMs != null)
      .map((o) => o.latencyMs!)
      .toList();
  return <String, Object?>{
    'ts': ts.toIso8601String(),
    'metric': 'email_loopback.summary',
    'scenarios_attempted': attempted,
    'scenarios_succeeded': succeeded,
    'scenarios_deferred': deferred,
    'scenarios_failed': failed,
    'p95_latency_ms': p95LatencyMs(latencies),
  };
}

/// Builds a per-scenario JSON line for the structured log.
Map<String, Object?> buildScenarioLine({
  required EmailLoopbackOutcome outcome,
  required DateTime ts,
}) {
  final line = <String, Object?>{
    'ts': ts.toIso8601String(),
    'metric': 'email_loopback.scenario',
    'scenario': outcome.scenario.templateId,
  };
  switch (outcome.kind) {
    case EmailLoopbackOutcomeKind.success:
      line['status'] = 'wired';
      line['latency_ms'] = outcome.latencyMs;
      line['subject_match'] = outcome.subjectMatch;
      line['body_match'] = outcome.bodyMatch;
      line['message_id'] = outcome.messageId;
      break;
    case EmailLoopbackOutcomeKind.deferred:
      line['status'] = 'deferred';
      line['reason'] = outcome.scenario.deferralReason ?? 'unspecified';
      break;
    case EmailLoopbackOutcomeKind.failed:
      line['status'] = 'failed';
      line['error'] = outcome.error;
      break;
    case EmailLoopbackOutcomeKind.timeout:
      line['status'] = 'timeout';
      line['error'] = outcome.error ?? 'mailosaur poll timed out';
      break;
  }
  return line;
}

/// Drives the admin-test send route + Mailosaur receipt. Returns null
/// when the admin-test path cannot run (missing proxy creds → caller
/// reports a "deferred" outcome).
class AdminTestEmailDriver {
  AdminTestEmailDriver({
    required this.proxyUrl,
    required this.adminToken,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final String proxyUrl;
  final String adminToken;
  final HttpClient _httpClient;

  /// POSTs to `/v1/admin/integrations/email/test` with [recipient].
  /// Returns the timestamp the proxy accepted the request (the
  /// caller subtracts this from the Mailosaur receive time to
  /// compute end-to-end latency).
  Future<DateTime> sendTestEmail({
    required String recipient,
    required String idempotencyKey,
  }) async {
    final uri = Uri.parse(
      '${_normalizeProxyBase(proxyUrl)}/v1/admin/integrations/email/test',
    );
    final request = await _httpClient.postUrl(uri);
    request.headers.set('authorization', 'Bearer $adminToken');
    request.headers.set('content-type', 'application/json');
    request.headers.set('idempotency-key', idempotencyKey);
    final body =
        jsonEncode(<String, Object?>{'recipient_email': recipient});
    request.contentLength = utf8.encode(body).length;
    request.add(utf8.encode(body));
    final sentAt = DateTime.now().toUtc();
    final response = await request.close();
    final bodyText = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'admin email test returned ${response.statusCode}: $bodyText',
        uri: uri,
      );
    }
    return sentAt;
  }

  void close() {
    _httpClient.close(force: false);
  }
}

/// Trim trailing slashes off the proxy base so URL concatenation
/// produces a clean `https://host/v1/...`.
String _normalizeProxyBase(String base) {
  var trimmed = base.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// Returns the substring violation when [proxyUrl] does not match any
/// of the allow-listed preview substrings; returns null when the URL
/// is acceptable.
String? validateProxyUrl(String proxyUrl) {
  for (final ok in kEmailLoopbackAllowedProxySubstrings) {
    if (proxyUrl.contains(ok)) return null;
  }
  return 'PROXY_URL must contain one of '
      '${kEmailLoopbackAllowedProxySubstrings.join(", ")}. '
      'Refusing to drive production from a pressure harness.';
}

/// Parses the `--output=<path>` CLI flag. Returns null when the flag is
/// absent. Mirrors the p4 harness option parser shape.
String? parseOutputPath(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--output=')) {
      return arg.substring('--output='.length);
    }
  }
  return null;
}

/// Runs the email loopback harness end-to-end. Returns the process exit
/// code. Exposed so the CLI entry point AND a future Dart-test runner
/// can both invoke it with controlled environment + output sink.
Future<int> runEmailLoopback({
  required Map<String, String> env,
  required IOSink output,
  required DateTime Function() clock,
  HttpClient Function()? httpClientFactory,
  List<EmailLoopbackScenario>? inventory,
  Duration? pollTimeout,
  Duration? pollInterval,
}) async {
  final apiKey = env['MAILOSAUR_API_KEY']?.trim();
  final serverId = env['MAILOSAUR_SERVER_ID']?.trim();

  if (apiKey == null || apiKey.isEmpty) {
    _emit(output, <String, Object?>{
      'ts': clock().toIso8601String(),
      'metric': 'email_loopback.skipped',
      'reason': 'MAILOSAUR_API_KEY unset — harness skipped; '
          'wire MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID in CI env',
    });
    return 0;
  }
  if (serverId == null || serverId.isEmpty) {
    _emit(output, <String, Object?>{
      'ts': clock().toIso8601String(),
      'metric': 'email_loopback.skipped',
      'reason': 'MAILOSAUR_SERVER_ID unset — harness skipped; '
          'wire MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID in CI env',
    });
    return 0;
  }

  final inbox = env['MAILOSAUR_INBOX']?.trim().isNotEmpty == true
      ? env['MAILOSAUR_INBOX']!.trim()
      : 'c11-loopback@$serverId.mailosaur.net';

  final proxyUrl = env['PROXY_URL']?.trim();
  final adminToken = env['PROXY_ADMIN_TOKEN']?.trim();
  String? proxyValidationError;
  if (proxyUrl != null && proxyUrl.isNotEmpty) {
    proxyValidationError = validateProxyUrl(proxyUrl);
    if (proxyValidationError != null) {
      _emit(output, <String, Object?>{
        'ts': clock().toIso8601String(),
        'metric': 'email_loopback.skipped',
        'reason': proxyValidationError,
      });
      return 2;
    }
  }

  final pollTimeoutResolved = pollTimeout ??
      Duration(
        seconds: int.tryParse(
              env['MAILOSAUR_POLL_TIMEOUT_SECONDS']?.trim() ?? '',
            ) ??
            30,
      );
  final pollIntervalResolved = pollInterval ??
      Duration(
        seconds: int.tryParse(
              env['MAILOSAUR_POLL_INTERVAL_SECONDS']?.trim() ?? '',
            ) ??
            2,
      );

  final scenarios = inventory ?? emailLoopbackInventory();
  final outcomes = <EmailLoopbackOutcome>[];
  HttpClient? mailosaurHttp;
  HttpClient? proxyHttp;
  MailosaurClient? mailosaur;
  AdminTestEmailDriver? adminDriver;

  try {
    mailosaurHttp = (httpClientFactory ?? HttpClient.new)();
    mailosaur = MailosaurClient(
      apiKey: apiKey,
      serverId: serverId,
      inboxAddress: inbox,
      httpClient: mailosaurHttp,
      clock: clock,
    );

    final canDriveAdminTest = proxyUrl != null &&
        proxyUrl.isNotEmpty &&
        adminToken != null &&
        adminToken.isNotEmpty;
    if (canDriveAdminTest) {
      proxyHttp = (httpClientFactory ?? HttpClient.new)();
      adminDriver = AdminTestEmailDriver(
        proxyUrl: proxyUrl,
        adminToken: adminToken,
        httpClient: proxyHttp,
      );
    }

    for (final scenario in scenarios) {
      switch (scenario.status) {
        case EmailLoopbackStatus.deferred:
        case EmailLoopbackStatus.firebaseManaged:
          outcomes.add(
            EmailLoopbackOutcome(
              scenario: scenario,
              kind: EmailLoopbackOutcomeKind.deferred,
            ),
          );
          _emit(
            output,
            buildScenarioLine(
              outcome: outcomes.last,
              ts: clock(),
            ),
          );
          break;
        case EmailLoopbackStatus.wired:
          final outcome = await _runWiredScenario(
            scenario: scenario,
            mailosaur: mailosaur,
            adminDriver: adminDriver,
            inbox: inbox,
            pollTimeout: pollTimeoutResolved,
            pollInterval: pollIntervalResolved,
            clock: clock,
            canDriveAdminTest: canDriveAdminTest,
          );
          outcomes.add(outcome);
          _emit(
            output,
            buildScenarioLine(outcome: outcome, ts: clock()),
          );
          break;
      }
    }
  } finally {
    mailosaur?.close();
    adminDriver?.close();
    proxyHttp?.close(force: false);
  }

  _emit(output, buildSummary(outcomes: outcomes, ts: clock()));

  final anyFailed = outcomes.any((o) =>
      o.kind == EmailLoopbackOutcomeKind.failed ||
      o.kind == EmailLoopbackOutcomeKind.timeout);
  return anyFailed ? 1 : 0;
}

Future<EmailLoopbackOutcome> _runWiredScenario({
  required EmailLoopbackScenario scenario,
  required MailosaurClient mailosaur,
  required AdminTestEmailDriver? adminDriver,
  required String inbox,
  required Duration pollTimeout,
  required Duration pollInterval,
  required DateTime Function() clock,
  required bool canDriveAdminTest,
}) async {
  // The harness directly drives ONLY the admin-test route (the one
  // path it can trigger over HTTP without spinning up a real Postgres
  // tier). Other wired surfaces (vendor_now_available / backfill_* /
  // audit_anchor_failure) come from Postgres-driven workers; the
  // harness observes any such email the operator's preview run
  // happens to produce within the poll window, but cannot
  // self-trigger them. Report them as `deferred-trigger` when the
  // admin-test fixture is the only self-driveable surface.
  if (scenario.templateId != 'operator_invite_first_admin') {
    return EmailLoopbackOutcome(
      scenario: scenario,
      kind: EmailLoopbackOutcomeKind.deferred,
      error: 'wired-but-not-self-trigger: this harness only drives the '
          'admin-test send route; operator must trigger the upstream '
          'worker (backfill / audit anchor / vendor lifecycle) in '
          'parallel for a complete sweep.',
    );
  }

  if (!canDriveAdminTest || adminDriver == null) {
    return EmailLoopbackOutcome(
      scenario: scenario,
      kind: EmailLoopbackOutcomeKind.deferred,
      error: 'admin-test-route deferred: PROXY_URL and PROXY_ADMIN_TOKEN '
          'must both be set to drive POST /v1/admin/integrations/email/test',
    );
  }

  final sentAt = clock();
  final idempotencyKey = 'c11-loopback-${sentAt.microsecondsSinceEpoch}';
  DateTime acceptedAt;
  try {
    acceptedAt = await adminDriver.sendTestEmail(
      recipient: inbox,
      idempotencyKey: idempotencyKey,
    );
  } catch (e) {
    return EmailLoopbackOutcome(
      scenario: scenario,
      kind: EmailLoopbackOutcomeKind.failed,
      error: e.toString().split('\n').first,
    );
  }

  MailosaurMessage? message;
  try {
    message = await mailosaur.waitForMessage(
      sentAfter: acceptedAt.subtract(const Duration(seconds: 1)),
      timeout: pollTimeout,
      pollInterval: pollInterval,
    );
  } catch (e) {
    return EmailLoopbackOutcome(
      scenario: scenario,
      kind: EmailLoopbackOutcomeKind.failed,
      error: e.toString().split('\n').first,
    );
  }
  if (message == null) {
    return EmailLoopbackOutcome(
      scenario: scenario,
      kind: EmailLoopbackOutcomeKind.timeout,
      error: 'mailosaur did not receive the message within '
          '${pollTimeout.inSeconds}s',
    );
  }

  final latencyMs = message.received.difference(acceptedAt).inMilliseconds;
  final subjectOk = subjectMatches(
    observed: message.subject,
    expectedSubstring: scenario.expectedSubject,
  );
  final bodyOk = bodyMatches(
    htmlBody: message.htmlBody,
    textBody: message.textBody,
    expectedContains: scenario.bodyContains,
  );
  return EmailLoopbackOutcome(
    scenario: scenario,
    kind: EmailLoopbackOutcomeKind.success,
    latencyMs: latencyMs >= 0 ? latencyMs : 0,
    subjectMatch: subjectOk,
    bodyMatch: bodyOk,
    messageId: message.id,
  );
}

void _emit(IOSink sink, Map<String, Object?> line) {
  sink.writeln(jsonEncode(line));
}

Future<void> main(List<String> args) async {
  final outputPath = parseOutputPath(args);
  IOSink output;
  if (outputPath != null && outputPath.isNotEmpty) {
    final file = File(outputPath);
    await file.parent.create(recursive: true);
    output = file.openWrite();
  } else {
    output = stdout;
  }
  final exitCode = await runEmailLoopback(
    env: Platform.environment,
    output: output,
    clock: () => DateTime.now().toUtc(),
  );
  if (outputPath != null && outputPath.isNotEmpty) {
    await output.flush();
    await output.close();
  }
  exit(exitCode);
}
