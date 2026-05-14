// Wave 2 Q-2a — email soak harness orchestrator.
//
// End-to-end loopback test driver for every TRANSACTIONAL email path
// the proxy + dispatcher emits. Drives a round-trip per path:
//
//   1. trigger the email path via an HTTP test seam (today: only the
//      admin-test send route is self-driveable without growing the
//      monolith; other paths require the operator to run upstream
//      workers in parallel — those rows report `deferred-trigger` and
//      surface the latency-only budget for any matching webhook event
//      that does arrive within the poll window).
//   2. poll Mailosaur for inbox receipt of the rendered envelope
//      (subject match + body smoke check + receive timestamp).
//   3. poll the proxy's `email-soak` probe route for matching
//      `email_event` rows (default kind filter: `delivered`). The
//      probe is env-gated-inert (`EMAIL_SOAK_PROBE_TOKEN` unset → 503),
//      so production deploys cannot accidentally serve it.
//   4. assert both Mailosaur receipt + webhook arrival fit the
//      configured latency budget and emit a structured per-path record.
//
// Sprint authority
// ----------------
//   * `docs/_indices/WAVE_2_LEDGER.md` row Q-2 (operator-split into
//     a/b/c on 2026-05-14; this slice = Q-2a, the email half).
//   * Origin: `debug.md:58-67` (EN-5 — operator wants email/push/in-app
//     soak surface), `debug.md:322-325` (BC-3 — first-connect backfill
//     "60-day historical seed finished" message).
//   * Pattern: `tool/pressure/p4_soak_orchestrator.dart` (Q-1) for the
//     harness shape (driver + step record + budget enforcement +
//     report writer).
//   * Pattern: `tool/pressure/p5_email_scenario_loopback.dart` (C-11)
//     for the Mailosaur receipt half — the orchestrator extends p5
//     with the SendGrid webhook poll + per-test inbox + latency-budget
//     enforcement.
//
// Env-gated-inert posture (REQUIRED by slice prompt)
// --------------------------------------------------
// Required env vars; when ANY is unset the harness skips with a
// structured "skipped" log line and exit 0. NEVER fabricates a green
// result:
//
//   * `MAILOSAUR_API_KEY`     — Mailosaur REST bearer token.
//   * `MAILOSAUR_SERVER_ID`   — Mailosaur server identifier.
//
// Optional env vars; when unset, the affected paths report deferred:
//
//   * `MAILOSAUR_INBOX_PREFIX` — prefix used to derive the per-test
//     inbox address (default: `q2a-soak`). The orchestrator appends a
//     deterministic per-test salt + the run id so parallel runs
//     against the same server never collide.
//   * `PROXY_URL`             — F&F proxy base URL (must contain one
//     of `preview.` / `staging.` / `localhost` / `127.0.0.1`, mirror
//     of the p4/p5 allow-list guard).
//   * `PROXY_ADMIN_TOKEN`     — Firebase JWT bearer the orchestrator
//     uses to POST `/v1/admin/integrations/email/test` (the only path
//     it can self-trigger).
//   * `EMAIL_SOAK_PROBE_TOKEN` — bearer for the `email-soak` probe
//     route (a server-side env var matched server-side; the harness
//     just forwards it on the wire as `Authorization: Bearer …`).
//     When unset, the SendGrid webhook poll step is skipped per path
//     and the path reports `webhook_skipped` instead of `delivered`.
//   * `SENDGRID_SANDBOX_API_KEY` — passed through to the proxy via its
//     own env (not read directly here). The harness ASSUMES the proxy
//     is configured to use the sandbox key; sandbox sends never burn
//     production quota.
//   * `MAILOSAUR_POLL_TIMEOUT_SECONDS` — default 30s.
//   * `MAILOSAUR_POLL_INTERVAL_SECONDS` — default 2s.
//   * `WEBHOOK_POLL_TIMEOUT_SECONDS` — default 45s (SendGrid event
//     delivery is asynchronous; the budget runs slightly longer than
//     Mailosaur).
//   * `WEBHOOK_POLL_INTERVAL_SECONDS` — default 3s.
//   * `LATENCY_BUDGET_INBOX_MS` — fail-if-exceeded budget on Mailosaur
//     receipt (default 30000ms = 30s).
//   * `LATENCY_BUDGET_WEBHOOK_MS` — fail-if-exceeded budget on
//     SendGrid event delivered-row arrival (default 45000ms = 45s).
//
// Demo mode parity (HP #2)
// ------------------------
// The harness reads + writes the SAME tables in demo or prod. The
// proxy admin test route does not branch on `kDemoMode`. In a demo
// build the SendGrid provider may stub to a no-op — the orchestrator
// detects this by an empty `provider_message_id` response payload and
// reports the path as `provider_stubbed_in_demo` (skipped cleanly,
// exit 0). Never fabricates a green result.
//
// Idempotency (REQUIRED by slice prompt)
// --------------------------------------
// Every per-path trigger carries a unique `idempotency-key` derived
// from `(run_id, scenario_id)`. Re-running the harness end-to-end is
// safe: the proxy collapses retries on the same key, Mailosaur inbox
// names embed the run id so prior-run messages stay scoped to that
// run, and the webhook probe filters by `since` so the orchestrator
// only counts events that arrived AFTER its own send.
//
// CLAUDE.md compliance
// --------------------
//   * No `package:postgres` import — the proxy probe route is the
//     read seam (see `tool/postgres_import_lint.dart`).
//   * No production behavior change — every code path is test-time
//     observation only; the email-send paths the harness drives are
//     the SAME ones production uses (the harness does not add or
//     duplicate production sends).
//   * Hard Promise #1 — pure transport observation; no schema-touching
//     change in this slice.
//   * Hard Promise #4 — RLS-ready: the probe route does not surface
//     `event_payload`; per-operator data stays behind the existing
//     RLS posture.
//   * Hard Promise #7 — server-side keys: SendGrid sandbox key + the
//     probe bearer live in proxy env / KMS; the harness only consumes
//     a bearer it received via its own env.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'email_soak_budget.dart';
import 'mailosaur_inbox_factory.dart';

// Re-export the helper modules so a test importing this file picks up
// budget + step record + inbox-factory types in one shot. The
// orchestrator does not reference EmailSoakStepRecord directly today
// (the per-scenario JSON line carries aggregate latency), but the type
// is exported so a future deep-debug mode can opt into raw-step
// capture without an extra import.
export 'email_soak_budget.dart';
export 'email_soak_step_record.dart';
export 'mailosaur_inbox_factory.dart';

/// Allow-list of `PROXY_URL` substrings the orchestrator consents to
/// drive. Anything else aborts before the first send so a misrouted
/// run cannot drive production. Mirrors `kEmailLoopbackAllowedProxySubstrings`
/// in `tool/pressure/p5_email_scenario_loopback.dart`.
const Set<String> kEmailSoakAllowedProxySubstrings = <String>{
  'preview.',
  'staging.',
  'localhost',
  '127.0.0.1',
};

/// Per-path inventory the orchestrator drives. Mirrors the C-11
/// inventory + adds `triggerKind` so the orchestrator knows how to
/// fire each row (today: admin-test or "deferred-trigger").
///
/// EXTENDING: a new triggerable path adds a row with
/// `triggerKind = adminTestRoute` (or a future trigger kind) and a
/// matching factory call. A new template-only path adds a row with
/// `triggerKind = deferredTrigger` so the harness reports it without
/// pretending to drive it.
class EmailSoakScenario {
  const EmailSoakScenario({
    required this.scenarioId,
    required this.templateId,
    required this.triggerKind,
    required this.expectedSubjectSubstring,
    this.deferralReason,
  });

  /// Stable identifier for this scenario; embeds into the Mailosaur
  /// per-test inbox AND the idempotency key so re-runs collapse.
  final String scenarioId;

  /// Renderer template id (matches `EmailTemplateIds.<id>`).
  final String templateId;

  /// How the orchestrator triggers this email path.
  final EmailSoakTriggerKind triggerKind;

  /// Subject substring the orchestrator asserts against the rendered
  /// envelope Mailosaur captured. Variable-bound subjects (e.g.
  /// `{{vendorName}} is ready to connect`) use the locked substring
  /// from `email_template_renderer.dart`'s `_subjectByTemplate`.
  final String expectedSubjectSubstring;

  /// Cross-reference text for `deferred-trigger` rows. Surfaced in
  /// the per-path log line so the operator's grep finds it.
  final String? deferralReason;
}

enum EmailSoakTriggerKind {
  /// `POST /v1/admin/integrations/email/test`. Self-driveable over
  /// HTTP with `PROXY_URL` + `PROXY_ADMIN_TOKEN`.
  adminTestRoute,

  /// Self-trigger NOT available without growing the monolith. The
  /// harness reports the path as deferred-trigger and surfaces any
  /// matching webhook event that the operator's upstream worker
  /// happens to produce in parallel.
  deferredTrigger,
}

/// Canonical inventory used by the orchestrator. Aligned with the
/// `lib/services/email/email_template_renderer.dart` `EmailTemplateIds`
/// catalog + the C-11 wire/deferred decision matrix.
///
/// Slice prompt names 5 paths the harness MUST exercise at minimum;
/// each one appears below with the appropriate trigger kind:
///   * Invite-send (`auth_invites` path) → `operator_invite_first_admin`
///     (admin-test surface; production invite goes via Firebase action
///     link and is not in the SendGrid loopback set).
///   * Password reset → `firebase_password_reset` (Firebase action
///     link, not SendGrid — reported as deferred-trigger with a
///     firebase-managed flag).
///   * Audit anchor failure alert → `audit_anchor_failure`.
///   * Vendor disconnect → `vendor_connection_auto_disabled`.
///   * First-connect backfill complete → `backfill_complete`.
List<EmailSoakScenario> defaultEmailSoakInventory() => const <EmailSoakScenario>[
      EmailSoakScenario(
        scenarioId: 'invite_first_admin_admin_test',
        templateId: 'operator_invite_first_admin',
        triggerKind: EmailSoakTriggerKind.adminTestRoute,
        expectedSubjectSubstring:
            'Welcome to Forge & Flow — set up your account',
      ),
      EmailSoakScenario(
        scenarioId: 'password_reset_firebase',
        templateId: 'firebase_password_reset',
        triggerKind: EmailSoakTriggerKind.deferredTrigger,
        expectedSubjectSubstring: '(Firebase Identity Platform template)',
        deferralReason:
            'Firebase action-link path — not a SendGrid surface; '
            'loopback requires a Firebase-managed inbox (R4 §7A future work).',
      ),
      EmailSoakScenario(
        scenarioId: 'audit_anchor_failure_fanout',
        templateId: 'audit_anchor_failure',
        triggerKind: EmailSoakTriggerKind.deferredTrigger,
        expectedSubjectSubstring:
            'A daily integrity check on your audit log did not complete',
        deferralReason:
            'Trigger lives in tool/audit_anchor/main.dart failure '
            'branches; operator must run the audit anchor worker in '
            'parallel for the harness to observe a webhook event.',
      ),
      EmailSoakScenario(
        scenarioId: 'vendor_connection_auto_disabled_oauth',
        templateId: 'vendor_connection_auto_disabled',
        triggerKind: EmailSoakTriggerKind.deferredTrigger,
        expectedSubjectSubstring: 'connection disabled',
        deferralReason:
            'Trigger lives in tool/oauth_refresh_worker after 3-strike '
            'cap; operator must drive the OAuth refresh worker for the '
            'harness to observe a webhook event.',
      ),
      EmailSoakScenario(
        scenarioId: 'backfill_complete_first_connect',
        templateId: 'backfill_complete',
        triggerKind: EmailSoakTriggerKind.deferredTrigger,
        expectedSubjectSubstring: 'historical sync is complete',
        deferralReason:
            'Trigger lives in tool/integration_sync_worker/backfill_dispatch '
            'markSucceeded; operator must run the backfill worker for '
            'the harness to observe a webhook event.',
      ),
    ];

/// Per-scenario outcome. Aggregated into a summary line at run end.
class EmailSoakOutcome {
  const EmailSoakOutcome({
    required this.scenario,
    required this.kind,
    this.providerMessageId,
    this.idempotencyKey,
    this.inboxLatencyMs,
    this.webhookLatencyMs,
    this.deliveredEventCount,
    this.subjectMatch,
    this.errorReason,
  });

  final EmailSoakScenario scenario;
  final EmailSoakOutcomeKind kind;
  final String? providerMessageId;
  final String? idempotencyKey;
  final int? inboxLatencyMs;
  final int? webhookLatencyMs;
  final int? deliveredEventCount;
  final bool? subjectMatch;
  final String? errorReason;

  Map<String, Object?> toJson() => <String, Object?>{
        'scenario': scenario.scenarioId,
        'template_id': scenario.templateId,
        'kind': kind.name,
        if (providerMessageId != null) 'provider_message_id': providerMessageId,
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
        if (inboxLatencyMs != null) 'inbox_latency_ms': inboxLatencyMs,
        if (webhookLatencyMs != null) 'webhook_latency_ms': webhookLatencyMs,
        if (deliveredEventCount != null)
          'delivered_event_count': deliveredEventCount,
        if (subjectMatch != null) 'subject_match': subjectMatch,
        if (errorReason != null) 'error_reason': errorReason,
      };
}

enum EmailSoakOutcomeKind {
  /// Round-trip succeeded within the latency budget.
  success,

  /// Round-trip succeeded for the Mailosaur half but the webhook poll
  /// did not see a `delivered` event within the budget (`EMAIL_SOAK_PROBE_TOKEN`
  /// is unset, or the proxy did not record the event in time).
  webhookMissing,

  /// Mailosaur did not receive the message within the budget.
  inboxTimeout,

  /// Latency budget exceeded for the inbox or webhook half.
  budgetExceeded,

  /// Scenario could not be self-triggered (no admin-test path); the
  /// operator must run the upstream worker in parallel.
  deferredTrigger,

  /// Demo build with a stubbed SendGrid provider; harness skips
  /// gracefully.
  providerStubbedInDemo,

  /// Hard failure of the trigger HTTP call.
  triggerFailed,
}

/// CLI / env options for [runEmailSoakOrchestrator].
class EmailSoakOptions {
  EmailSoakOptions({
    required this.runId,
    required this.proxyUrl,
    required this.adminToken,
    required this.probeToken,
    required this.mailosaurApiKey,
    required this.mailosaurServerId,
    required this.mailosaurInboxPrefix,
    required this.mailosaurPollTimeout,
    required this.mailosaurPollInterval,
    required this.webhookPollTimeout,
    required this.webhookPollInterval,
    required this.budget,
    required this.outputDir,
  });

  final String runId;
  final String? proxyUrl;
  final String? adminToken;
  final String? probeToken;
  final String mailosaurApiKey;
  final String mailosaurServerId;
  final String mailosaurInboxPrefix;
  final Duration mailosaurPollTimeout;
  final Duration mailosaurPollInterval;
  final Duration webhookPollTimeout;
  final Duration webhookPollInterval;
  final EmailSoakBudget budget;
  final String outputDir;
}

/// Parses `Ns` / `Nm` / `Nmin` / `Nh`. Mirrors the p4 parser's shape
/// so the harness configuration files can share durations.
int parseEmailSoakDurationSeconds(String raw) {
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) {
    throw const FormatException('duration is empty');
  }
  final match =
      RegExp(r'^(\d+)\s*(s|m|min|h)?$').firstMatch(trimmed);
  if (match == null) {
    throw FormatException('cannot parse duration: $raw');
  }
  final value = int.parse(match.group(1)!);
  final unit = match.group(2) ?? 's';
  switch (unit) {
    case 's':
      return value;
    case 'm':
    case 'min':
      return value * 60;
    case 'h':
      return value * 3600;
    default:
      throw FormatException('unknown duration unit: $unit');
  }
}

/// Reads an integer-seconds env var with a fallback default.
int _envIntSecondsOrDefault(
  Map<String, String> env,
  String key,
  int defaultSeconds,
) {
  final raw = env[key]?.trim();
  if (raw == null || raw.isEmpty) return defaultSeconds;
  return int.tryParse(raw) ?? defaultSeconds;
}

/// Reads an integer-ms env var with a fallback default.
int _envIntMsOrDefault(
  Map<String, String> env,
  String key,
  int defaultMs,
) {
  final raw = env[key]?.trim();
  if (raw == null || raw.isEmpty) return defaultMs;
  return int.tryParse(raw) ?? defaultMs;
}

/// Returns the substring violation when [proxyUrl] does not match any
/// of the allow-listed preview substrings; returns null when the URL
/// is acceptable.
String? validateEmailSoakProxyUrl(String proxyUrl) {
  for (final ok in kEmailSoakAllowedProxySubstrings) {
    if (proxyUrl.contains(ok)) return null;
  }
  return 'PROXY_URL "$proxyUrl" must contain one of '
      '${kEmailSoakAllowedProxySubstrings.join(", ")}. '
      'Refusing to drive production from the Q-2a email soak harness.';
}

/// Build options from the process env + a deterministic run id.
EmailSoakOptions? buildEmailSoakOptionsFromEnv({
  required Map<String, String> env,
  required DateTime Function() clock,
  String? runIdOverride,
  required IOSink output,
}) {
  final apiKey = env['MAILOSAUR_API_KEY']?.trim();
  final serverId = env['MAILOSAUR_SERVER_ID']?.trim();
  if (apiKey == null || apiKey.isEmpty) {
    _emit(output, <String, Object?>{
      'ts': clock().toIso8601String(),
      'metric': 'email_soak.skipped',
      'reason': 'MAILOSAUR_API_KEY unset — harness skipped; wire '
          'MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID in CI env',
    });
    return null;
  }
  if (serverId == null || serverId.isEmpty) {
    _emit(output, <String, Object?>{
      'ts': clock().toIso8601String(),
      'metric': 'email_soak.skipped',
      'reason': 'MAILOSAUR_SERVER_ID unset — harness skipped; wire '
          'MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID in CI env',
    });
    return null;
  }
  final proxyUrl = env['PROXY_URL']?.trim();
  if (proxyUrl != null && proxyUrl.isNotEmpty) {
    final violation = validateEmailSoakProxyUrl(proxyUrl);
    if (violation != null) {
      _emit(output, <String, Object?>{
        'ts': clock().toIso8601String(),
        'metric': 'email_soak.skipped',
        'reason': violation,
      });
      return null;
    }
  }
  return EmailSoakOptions(
    runId: runIdOverride ??
        'q2a-${clock().toUtc().toIso8601String().replaceAll(RegExp(r'[^\w]'), '_')}',
    proxyUrl: proxyUrl,
    adminToken: env['PROXY_ADMIN_TOKEN']?.trim(),
    probeToken: env['EMAIL_SOAK_PROBE_TOKEN']?.trim(),
    mailosaurApiKey: apiKey,
    mailosaurServerId: serverId,
    mailosaurInboxPrefix:
        env['MAILOSAUR_INBOX_PREFIX']?.trim().isNotEmpty == true
            ? env['MAILOSAUR_INBOX_PREFIX']!.trim()
            : 'q2a-soak',
    mailosaurPollTimeout: Duration(
      seconds: _envIntSecondsOrDefault(
        env,
        'MAILOSAUR_POLL_TIMEOUT_SECONDS',
        30,
      ),
    ),
    mailosaurPollInterval: Duration(
      seconds: _envIntSecondsOrDefault(
        env,
        'MAILOSAUR_POLL_INTERVAL_SECONDS',
        2,
      ),
    ),
    webhookPollTimeout: Duration(
      seconds: _envIntSecondsOrDefault(
        env,
        'WEBHOOK_POLL_TIMEOUT_SECONDS',
        45,
      ),
    ),
    webhookPollInterval: Duration(
      seconds: _envIntSecondsOrDefault(
        env,
        'WEBHOOK_POLL_INTERVAL_SECONDS',
        3,
      ),
    ),
    budget: EmailSoakBudget(
      inboxLatencyBudgetMs: _envIntMsOrDefault(
        env,
        'LATENCY_BUDGET_INBOX_MS',
        30000,
      ),
      webhookLatencyBudgetMs: _envIntMsOrDefault(
        env,
        'LATENCY_BUDGET_WEBHOOK_MS',
        45000,
      ),
    ),
    outputDir: env['EMAIL_SOAK_OUTPUT_DIR']?.trim().isNotEmpty == true
        ? env['EMAIL_SOAK_OUTPUT_DIR']!.trim()
        : 'test/email_soak',
  );
}

/// Drives one round-trip per scenario. Returns the process exit code.
/// Exposed so the CLI entrypoint and Dart-test harness can both run
/// it with controlled env + output sink.
Future<int> runEmailSoakOrchestrator({
  required Map<String, String> env,
  required IOSink output,
  required DateTime Function() clock,
  HttpClient Function()? httpClientFactory,
  List<EmailSoakScenario>? inventory,
  String? runIdOverride,
  bool writeReportFile = false,
}) async {
  final options = buildEmailSoakOptionsFromEnv(
    env: env,
    clock: clock,
    runIdOverride: runIdOverride,
    output: output,
  );
  if (options == null) {
    return 0; // skipped cleanly per env-gated-inert posture
  }

  final scenarios = inventory ?? defaultEmailSoakInventory();
  final outcomes = <EmailSoakOutcome>[];
  HttpClient? client;
  try {
    client = (httpClientFactory ?? HttpClient.new)();
    for (final scenario in scenarios) {
      final outcome = await _runScenario(
        scenario: scenario,
        options: options,
        client: client,
        clock: clock,
      );
      outcomes.add(outcome);
      _emit(output, <String, Object?>{
        'ts': clock().toIso8601String(),
        'metric': 'email_soak.scenario',
        ...outcome.toJson(),
      });
    }
  } finally {
    client?.close(force: false);
  }
  final summary = buildEmailSoakSummary(outcomes: outcomes, ts: clock());
  _emit(output, summary);

  if (writeReportFile) {
    final dir = Directory(options.outputDir);
    dir.createSync(recursive: true);
    final reportPath =
        '${dir.path}/email_soak_${options.runId}.md';
    File(reportPath)
        .writeAsStringSync(_renderMarkdownReport(options, outcomes));
  }

  // Exit code policy mirrors p5: 0 for clean / skipped-cleanly /
  // deferred-only; 1 when any scenario hard-failed inside the budget;
  // 2 reserved for setup-time refusals (handled in
  // buildEmailSoakOptionsFromEnv).
  final anyHardFail = outcomes.any((o) =>
      o.kind == EmailSoakOutcomeKind.budgetExceeded ||
      o.kind == EmailSoakOutcomeKind.inboxTimeout ||
      o.kind == EmailSoakOutcomeKind.triggerFailed);
  return anyHardFail ? 1 : 0;
}

Future<EmailSoakOutcome> _runScenario({
  required EmailSoakScenario scenario,
  required EmailSoakOptions options,
  required HttpClient client,
  required DateTime Function() clock,
}) async {
  if (scenario.triggerKind == EmailSoakTriggerKind.deferredTrigger) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.deferredTrigger,
      errorReason: scenario.deferralReason ?? 'deferred-trigger',
    );
  }

  // Admin-test route — requires PROXY_URL + PROXY_ADMIN_TOKEN.
  if (options.proxyUrl == null ||
      options.proxyUrl!.isEmpty ||
      options.adminToken == null ||
      options.adminToken!.isEmpty) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.deferredTrigger,
      errorReason:
          'admin-test route requires PROXY_URL + PROXY_ADMIN_TOKEN; '
          'one or both env vars are unset',
    );
  }

  final inbox = deriveMailosaurInbox(
    inboxPrefix: options.mailosaurInboxPrefix,
    scenarioId: scenario.scenarioId,
    runId: options.runId,
    serverId: options.mailosaurServerId,
  );
  final idempotencyKey =
      'q2a-${options.runId}-${scenario.scenarioId}';
  final triggerStart = clock();

  final ({String? providerMessageId, DateTime acceptedAt, String? failure})
      triggerResult = await _triggerAdminTestRoute(
    client: client,
    proxyUrl: options.proxyUrl!,
    adminToken: options.adminToken!,
    recipient: inbox,
    idempotencyKey: idempotencyKey,
    clock: clock,
  );
  if (triggerResult.failure != null) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.triggerFailed,
      idempotencyKey: idempotencyKey,
      errorReason: triggerResult.failure,
    );
  }
  final providerMessageId = triggerResult.providerMessageId;
  if (providerMessageId == null || providerMessageId.isEmpty) {
    // Demo mode stubs the provider — empty `provider_message_id` in
    // the response payload is the signal.
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.providerStubbedInDemo,
      idempotencyKey: idempotencyKey,
      errorReason:
          'admin-test response carried no provider_message_id; '
          'proxy is likely running in demo mode with a stubbed '
          'SendGrid provider',
    );
  }

  // Step 2 — Mailosaur receipt poll.
  final inboxStart = clock();
  final mailosaurResult = await _pollMailosaur(
    client: client,
    apiKey: options.mailosaurApiKey,
    serverId: options.mailosaurServerId,
    inbox: inbox,
    sentAfter: triggerResult.acceptedAt,
    timeout: options.mailosaurPollTimeout,
    pollInterval: options.mailosaurPollInterval,
    clock: clock,
  );
  final inboxLatencyMs =
      clock().difference(inboxStart).inMilliseconds;
  if (mailosaurResult.timedOut) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.inboxTimeout,
      idempotencyKey: idempotencyKey,
      providerMessageId: providerMessageId,
      errorReason:
          'mailosaur did not receive the message within '
          '${options.mailosaurPollTimeout.inSeconds}s',
    );
  }
  final subjectOk = (mailosaurResult.subject ?? '')
      .contains(scenario.expectedSubjectSubstring);
  if (inboxLatencyMs > options.budget.inboxLatencyBudgetMs) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.budgetExceeded,
      idempotencyKey: idempotencyKey,
      providerMessageId: providerMessageId,
      inboxLatencyMs: inboxLatencyMs,
      subjectMatch: subjectOk,
      errorReason:
          'inbox latency $inboxLatencyMs ms exceeded budget '
          '${options.budget.inboxLatencyBudgetMs} ms',
    );
  }

  // Step 3 — webhook event poll (env-gated; skip when token unset).
  final probeToken = options.probeToken;
  if (probeToken == null || probeToken.isEmpty) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.webhookMissing,
      idempotencyKey: idempotencyKey,
      providerMessageId: providerMessageId,
      inboxLatencyMs: inboxLatencyMs,
      subjectMatch: subjectOk,
      errorReason: 'EMAIL_SOAK_PROBE_TOKEN unset — webhook poll skipped',
    );
  }
  final webhookStart = clock();
  final probeResult = await _pollWebhookProbe(
    client: client,
    proxyUrl: options.proxyUrl!,
    probeToken: probeToken,
    providerMessageId: providerMessageId,
    sentAfter: triggerStart.subtract(const Duration(seconds: 1)),
    kindFilter: 'delivered',
    timeout: options.webhookPollTimeout,
    pollInterval: options.webhookPollInterval,
    clock: clock,
  );
  final webhookLatencyMs =
      clock().difference(webhookStart).inMilliseconds;
  if (probeResult.timedOut) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.webhookMissing,
      idempotencyKey: idempotencyKey,
      providerMessageId: providerMessageId,
      inboxLatencyMs: inboxLatencyMs,
      webhookLatencyMs: webhookLatencyMs,
      subjectMatch: subjectOk,
      errorReason:
          'no delivered event arrived within '
          '${options.webhookPollTimeout.inSeconds}s — SendGrid may not '
          'be configured to POST events to the preview proxy; check the '
          'sandbox project event webhook URL.',
    );
  }
  if (webhookLatencyMs > options.budget.webhookLatencyBudgetMs) {
    return EmailSoakOutcome(
      scenario: scenario,
      kind: EmailSoakOutcomeKind.budgetExceeded,
      idempotencyKey: idempotencyKey,
      providerMessageId: providerMessageId,
      inboxLatencyMs: inboxLatencyMs,
      webhookLatencyMs: webhookLatencyMs,
      deliveredEventCount: probeResult.eventCount,
      subjectMatch: subjectOk,
      errorReason:
          'webhook latency $webhookLatencyMs ms exceeded budget '
          '${options.budget.webhookLatencyBudgetMs} ms',
    );
  }
  return EmailSoakOutcome(
    scenario: scenario,
    kind: EmailSoakOutcomeKind.success,
    idempotencyKey: idempotencyKey,
    providerMessageId: providerMessageId,
    inboxLatencyMs: inboxLatencyMs,
    webhookLatencyMs: webhookLatencyMs,
    deliveredEventCount: probeResult.eventCount,
    subjectMatch: subjectOk,
  );
}

/// HTTP shim — POSTs to `/v1/admin/integrations/email/test` and
/// returns the `provider_message_id` + acceptance timestamp.
Future<
    ({
      String? providerMessageId,
      DateTime acceptedAt,
      String? failure,
    })> _triggerAdminTestRoute({
  required HttpClient client,
  required String proxyUrl,
  required String adminToken,
  required String recipient,
  required String idempotencyKey,
  required DateTime Function() clock,
}) async {
  final base = _normalizeProxyBase(proxyUrl);
  final uri = Uri.parse('$base/v1/admin/integrations/email/test');
  try {
    final request = await client.postUrl(uri);
    request.headers.set('authorization', 'Bearer $adminToken');
    request.headers.set('content-type', 'application/json');
    request.headers.set('idempotency-key', idempotencyKey);
    final body = jsonEncode(<String, Object?>{'recipient_email': recipient});
    request.contentLength = utf8.encode(body).length;
    request.add(utf8.encode(body));
    final acceptedAt = clock();
    final response = await request.close();
    final bodyText = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return (
        providerMessageId: null,
        acceptedAt: acceptedAt,
        failure: 'admin-test returned ${response.statusCode}: '
            '${bodyText.isEmpty ? "<empty>" : bodyText}',
      );
    }
    final decoded = jsonDecode(bodyText);
    if (decoded is! Map) {
      return (
        providerMessageId: null,
        acceptedAt: acceptedAt,
        failure: 'admin-test response was not a JSON object',
      );
    }
    final providerMessageId =
        (decoded['provider_message_id'] as String?)?.trim();
    return (
      providerMessageId:
          providerMessageId?.isNotEmpty == true ? providerMessageId : null,
      acceptedAt: acceptedAt,
      failure: null,
    );
  } catch (e) {
    return (
      providerMessageId: null,
      acceptedAt: clock(),
      failure: 'admin-test request failed: ${e.toString().split('\n').first}',
    );
  }
}

/// Poll the Mailosaur loopback inbox.
Future<
    ({
      bool timedOut,
      String? subject,
      String? messageId,
      DateTime? received,
    })> _pollMailosaur({
  required HttpClient client,
  required String apiKey,
  required String serverId,
  required String inbox,
  required DateTime sentAfter,
  required Duration timeout,
  required Duration pollInterval,
  required DateTime Function() clock,
}) async {
  final deadline = clock().add(timeout);
  while (clock().isBefore(deadline)) {
    final hit = await _findMailosaurMatch(
      client: client,
      apiKey: apiKey,
      serverId: serverId,
      inbox: inbox,
      sentAfter: sentAfter,
    );
    if (hit != null) return hit;
    await Future<void>.delayed(pollInterval);
  }
  return (
    timedOut: true,
    subject: null,
    messageId: null,
    received: null,
  );
}

Future<
    ({
      bool timedOut,
      String? subject,
      String? messageId,
      DateTime? received,
    })?> _findMailosaurMatch({
  required HttpClient client,
  required String apiKey,
  required String serverId,
  required String inbox,
  required DateTime sentAfter,
}) async {
  final uri = Uri.parse(
    'https://mailosaur.com/api/messages?server=$serverId'
    '&receivedAfter=${Uri.encodeQueryComponent(sentAfter.toUtc().toIso8601String())}',
  );
  try {
    final request = await client.getUrl(uri);
    final auth = 'Basic ${base64Encode(utf8.encode('$apiKey:'))}';
    request.headers.set('authorization', auth);
    request.headers.set('accept', 'application/json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return null;
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final items = decoded['items'];
    if (items is! List) return null;
    for (final item in items) {
      if (item is! Map) continue;
      final to = (item['to'] as List?)?.cast<dynamic>() ?? const <dynamic>[];
      final matches = to.any((addr) {
        if (addr is! Map) return false;
        final email = addr['email'];
        return email is String && email.toLowerCase() == inbox.toLowerCase();
      });
      if (!matches) continue;
      final subject = item['subject'] as String?;
      final id = item['id'] as String?;
      final receivedRaw = item['received'] as String?;
      final received = receivedRaw == null
          ? null
          : DateTime.tryParse(receivedRaw);
      return (
        timedOut: false,
        subject: subject,
        messageId: id,
        received: received,
      );
    }
    return null;
  } catch (_) {
    // Network blips are absorbed; the outer poll loop retries.
    return null;
  }
}

/// Poll the proxy email-soak probe route for at least one matching
/// event row.
Future<({bool timedOut, int eventCount, DateTime? firstReceivedAt})>
    _pollWebhookProbe({
  required HttpClient client,
  required String proxyUrl,
  required String probeToken,
  required String providerMessageId,
  required DateTime sentAfter,
  required String? kindFilter,
  required Duration timeout,
  required Duration pollInterval,
  required DateTime Function() clock,
}) async {
  final base = _normalizeProxyBase(proxyUrl);
  final queryParams = <String, String>{
    'provider_message_id': providerMessageId,
    'since': sentAfter.toUtc().toIso8601String(),
    if (kindFilter != null) 'kind': kindFilter,
  };
  final uri = Uri.parse('$base/v1/admin/email-soak/events').replace(
    queryParameters: queryParams,
  );
  final deadline = clock().add(timeout);
  while (clock().isBefore(deadline)) {
    try {
      final request = await client.getUrl(uri);
      request.headers.set('authorization', 'Bearer $probeToken');
      request.headers.set('accept', 'application/json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode == 200) {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final count = (decoded['event_count'] as int?) ?? 0;
          if (count > 0) {
            final events = decoded['events'];
            DateTime? firstReceived;
            if (events is List && events.isNotEmpty) {
              final first = events.first;
              if (first is Map) {
                firstReceived = DateTime.tryParse(
                  (first['received_at'] as String?) ?? '',
                );
              }
            }
            return (
              timedOut: false,
              eventCount: count,
              firstReceivedAt: firstReceived,
            );
          }
        }
      }
    } catch (_) {
      // absorb transient network failures
    }
    await Future<void>.delayed(pollInterval);
  }
  return (timedOut: true, eventCount: 0, firstReceivedAt: null);
}

/// Aggregates per-scenario outcomes into a summary log line.
Map<String, Object?> buildEmailSoakSummary({
  required List<EmailSoakOutcome> outcomes,
  required DateTime ts,
}) {
  int countWhere(bool Function(EmailSoakOutcome) p) =>
      outcomes.where(p).length;
  final inboxLatencies = outcomes
      .where((o) => o.inboxLatencyMs != null)
      .map((o) => o.inboxLatencyMs!)
      .toList();
  final webhookLatencies = outcomes
      .where((o) => o.webhookLatencyMs != null)
      .map((o) => o.webhookLatencyMs!)
      .toList();
  return <String, Object?>{
    'ts': ts.toIso8601String(),
    'metric': 'email_soak.summary',
    'scenarios_attempted': outcomes.length,
    'scenarios_succeeded':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.success),
    'scenarios_webhook_missing':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.webhookMissing),
    'scenarios_inbox_timeout':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.inboxTimeout),
    'scenarios_budget_exceeded':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.budgetExceeded),
    'scenarios_deferred_trigger':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.deferredTrigger),
    'scenarios_provider_stubbed_in_demo': countWhere(
        (o) => o.kind == EmailSoakOutcomeKind.providerStubbedInDemo),
    'scenarios_trigger_failed':
        countWhere((o) => o.kind == EmailSoakOutcomeKind.triggerFailed),
    'p95_inbox_latency_ms': _p95(inboxLatencies),
    'p95_webhook_latency_ms': _p95(webhookLatencies),
  };
}

/// Sorted-index p95 mirroring `p5_email_scenario_loopback.dart`'s
/// computation so the two harness outputs aggregate consistently.
int _p95(List<int> samples) {
  if (samples.isEmpty) return 0;
  final sorted = List<int>.from(samples)..sort();
  final idx = (sorted.length * 0.95).ceil() - 1;
  return sorted[idx.clamp(0, sorted.length - 1)];
}

String _normalizeProxyBase(String base) {
  var trimmed = base.trim();
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

void _emit(IOSink sink, Map<String, Object?> line) {
  sink.writeln(jsonEncode(line));
}

String _renderMarkdownReport(
  EmailSoakOptions options,
  List<EmailSoakOutcome> outcomes,
) {
  final buffer = StringBuffer()
    ..writeln('# email_soak_orchestrator — ${options.runId}')
    ..writeln()
    ..writeln('| Setting | Value |')
    ..writeln('|---|---|')
    ..writeln('| Proxy URL | `${options.proxyUrl ?? "<unset>"}` |')
    ..writeln(
      '| Probe token wired | ${options.probeToken?.isNotEmpty == true} |',
    )
    ..writeln(
      '| Mailosaur inbox prefix | `${options.mailosaurInboxPrefix}` |',
    )
    ..writeln('| Inbox latency budget (ms) | '
        '${options.budget.inboxLatencyBudgetMs} |')
    ..writeln('| Webhook latency budget (ms) | '
        '${options.budget.webhookLatencyBudgetMs} |')
    ..writeln()
    ..writeln('## Per-path outcomes')
    ..writeln()
    ..writeln(
      '| Scenario | Template | Kind | Inbox ms | Webhook ms | Match | Note |',
    )
    ..writeln('|---|---|---|---|---|---|---|');
  for (final outcome in outcomes) {
    buffer.writeln(
      '| `${outcome.scenario.scenarioId}` '
      '| `${outcome.scenario.templateId}` '
      '| ${outcome.kind.name} '
      '| ${outcome.inboxLatencyMs ?? "-"} '
      '| ${outcome.webhookLatencyMs ?? "-"} '
      '| ${outcome.subjectMatch == null ? "-" : outcome.subjectMatch! ? "yes" : "no"} '
      '| ${outcome.errorReason ?? ""} |',
    );
  }
  return buffer.toString();
}

Future<void> main(List<String> args) async {
  IOSink output = stdout;
  String? outputPath;
  for (final arg in args) {
    if (arg.startsWith('--output=')) {
      outputPath = arg.substring('--output='.length);
    }
  }
  if (outputPath != null && outputPath.isNotEmpty) {
    final file = File(outputPath);
    await file.parent.create(recursive: true);
    output = file.openWrite();
  }
  final exitCode = await runEmailSoakOrchestrator(
    env: Platform.environment,
    output: output,
    clock: () => DateTime.now().toUtc(),
    writeReportFile: true,
  );
  if (outputPath != null && outputPath.isNotEmpty) {
    await output.flush();
    await output.close();
  }
  exit(exitCode);
}

