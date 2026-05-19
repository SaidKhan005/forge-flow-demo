// Forge & Flow — EmailTemplateRenderer.
//
// Phase 9.8 email-provider slice. Renders Markdown email templates
// committed at `tool/advisor_proxy/email_templates/*.md` into:
//   * a plaintext body (Markdown source with header/footer trimmed),
//   * an HTML body wrapped in the brand-styled wrapper from
//     `tool/advisor_proxy/email_templates/_brand_wrapper.html`,
//   * the resolved subject line (locked per template_id, never
//     interpolated from user input).
//
// Variable interpolation: templates and the subject map use the
// `{{variableName}}` syntax. The renderer accepts a
// `Map<String, String>` from `email_outbox.template_data` (JSONB
// stored as flat key→string) and substitutes every occurrence.
// Missing variables surface a [MissingTemplateVariableError]
// because a half-rendered email is worse than a queued retry — the
// dispatcher dead-letters the row immediately.
//
// Markdown subset: this renderer implements the small subset the V1
// templates need (paragraphs, bold/italic emphasis, single-level
// headings, bullet lists, links). Production-grade Markdown is
// out of scope; templates are author-controlled so we do not need
// to defend against arbitrary user input.
//
// HTML escaping: every interpolated variable is HTML-escaped before
// being stitched into the rendered HTML body. The plaintext body
// keeps variables raw because plaintext has no escape semantics.
//
// Subject line policy: subject patterns are LOCKED in the slice doc
// (`docs/phases/phase_9_8/phase_9_8_email_provider_slice.md`). The
// renderer ships them as a const map so a deploy can grep
// `subjectFor(...)` to confirm the active pattern without reading
// every template file.

import 'dart:convert';

/// Thrown when a template references a variable that is missing
/// from the supplied [templateData]. The dispatcher treats this as
/// a permanent failure and dead-letters the row — retrying will not
/// fix the missing variable.
class MissingTemplateVariableError implements Exception {
  const MissingTemplateVariableError({
    required this.templateId,
    required this.variableName,
  });

  final String templateId;
  final String variableName;

  @override
  String toString() =>
      'MissingTemplateVariableError(template=$templateId, variable=$variableName)';
}

/// Rendered email envelope returned by [EmailTemplateRenderer.render].
class RenderedEmail {
  const RenderedEmail({
    required this.subject,
    required this.htmlBody,
    required this.textBody,
  });

  final String subject;
  final String htmlBody;
  final String textBody;
}

/// Source of one email template's Markdown body. Production binds
/// this to a file-system loader rooted at
/// `tool/advisor_proxy/email_templates/`; tests inject a map-backed
/// loader so the suite does not touch disk.
typedef EmailTemplateSource = String Function(String templateId);

/// Loader for the brand-styled HTML wrapper. The wrapper contains
/// the literal string `{{body}}` which the renderer replaces with
/// the rendered Markdown body. Headers / footers / brand styling
/// live entirely in the wrapper, so swapping the wrapper does not
/// touch any individual template.
typedef EmailBrandWrapperSource = String Function();

/// Locked V1 template ids. Adding a new template means: drop the
/// .md file alongside the existing templates, add the id + subject
/// pattern here, and ship a renderer test.
class EmailTemplateIds {
  EmailTemplateIds._();

  /// V1 status: WIRED (admin test-connection fixture only — NOT a
  /// production invite email path). Consumer:
  /// `tool/advisor_proxy/admin_email_routes.dart` (the
  /// `POST /v1/admin/integrations/email/test` route renders this
  /// template with sample data and sends it directly through
  /// `EmailProvider.send`, bypassing `email_outbox`).
  ///
  /// BC-1 invite-path resolution (Q-3 scaffold audit lane,
  /// 2026-05-13): the production invite path is Firebase Identity
  /// Platform's password-reset action-link template. See
  /// `lib/services/auth/repository_auth_operations_gateway.dart`
  /// `firebaseAdmin.sendPasswordResetEmail` call at the
  /// invite-completion site, the bootstrap path at the
  /// admin-initiated reset path, and the orientation comment in
  /// `lib/services/auth/user_invite_service.dart` for the full
  /// auth_invites bookkeeping <-> Firebase email split. The repo-owned
  /// `operator_admin_invite.md` template was deleted in A2.2
  /// (PR #540); this template is PRESERVED because the admin test
  /// route is its live consumer and deleting it would break the
  /// SendGrid connectivity test surface with no replacement.
  /// Sources:
  /// `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft A, addendum B4 path 1, and the Q-3 PR body.
  static const String operatorInviteFirstAdmin =
      'operator_invite_first_admin';

  /// V1 status: WIRED (C-2-C). Operator picked WIRE in the C-2
  /// matrix; the MFA removal worker emits the email when a 24-hour
  /// revocation completes. Trigger site:
  /// `lib/services/mfa/mfa_removal_worker.dart`'s completion path
  /// inside `MfaFactorRemovalRequestsRepository.withTenant` (after
  /// `markCompletedInTransaction` returns > 0). Dispatcher:
  /// `lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart` —
  /// single-recipient (the user whose factor changed), not operator-
  /// wide; enqueues to `email_outbox` on the same executor as the
  /// completion transaction. MFA enrollment (`lib/services/mfa/mfa_enrollment_service.dart`)
  /// remains client-side; no enrollment-side email is wired (per
  /// operator pick: removal only). Catalog entry:
  /// `notif.mfa.factor_changed` in
  /// `lib/domain/models/notification_event_catalog.dart`. Source:
  /// `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft C, operator pick 2026-05-13.
  static const String mfaFactorChangedNotice = 'mfa_factor_changed_notice';

  /// V1 status: WIRED (C-2-D). Operator picked WIRE in the C-2
  /// matrix; the polling tier emits per-tick `connector_sync_log`
  /// rows but does not natively detect "first failure of a new
  /// outage" — a per-row email would spam on transients. C-2-D
  /// added the missing aggregator: `VendorSyncOutageDetector`
  /// (`lib/services/vendor_sync/vendor_sync_outage_detector.dart`)
  /// tracks consecutive-failure streaks against the new
  /// `vendor_sync_outage_state` table
  /// (`db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql`)
  /// and enqueues one email per outage window (default threshold:
  /// 3 consecutive `poll_error` rows within a 30-minute lookback).
  /// The companion `VendorSyncErrorAlertDispatcher`
  /// (`lib/services/email/vendor_sync_error_alert_dispatcher.dart`)
  /// resolves the operator admin recipient + vendor display
  /// metadata and writes to `email_outbox` inside the same tenant
  /// transaction as the detector's state stamp. Wired into the
  /// polling tier via `tool/integration_sync_worker` so a crash
  /// between the email INSERT and the `notified_at` stamp rolls
  /// both back. Source:
  /// `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft D, operator pick 2026-05-13.
  static const String vendorSyncErrorAlert = 'vendor_sync_error_alert';

  /// V1 status: WIRED (C-2-F via Path b — direct outbox enqueue).
  /// Operator picked WIRE on 2026-05-13; worker pre-recommended the
  /// narrower Path b (~400 LoC outbox enqueue mirror of
  /// `VendorLifecycleNotificationDispatcher`) over Path a (~600 LoC
  /// full `NotificationEventFanout` bootstrap inside the Cloud Run
  /// worker). Trigger sites:
  /// `tool/oauth_refresh_worker/main.dart:1196` + `:1226` (both call
  /// `gateway.autoDisableConnection` after the 3-strike cap trips).
  /// Dispatcher:
  /// `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
  /// — resolves the operator admin recipient via
  /// `public.operators.owner_email` (auto-disable is a system notice
  /// to the operator's primary admin, not a per-user opt-in), stamps
  /// `(operator_id, credential_id, cap_tripped_at)` idempotency key,
  /// inserts on the same executor as the cap-trip transaction.
  /// Source:
  /// `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft F, operator pick 2026-05-13.
  static const String vendorConnectionAutoDisabled =
      'vendor_connection_auto_disabled';

  /// V1 status: WIRED. Phase 8 lifecycle fan-out worker
  /// (`tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart`)
  /// enqueues one outbox row per matching `vendor_lifecycle_notification`
  /// row whenever a vendor's lifecycle promotes to
  /// `production_credentialed`. Source:
  /// `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`
  /// ("Triggers the `vendor_now_available` email to operators who
  /// tapped Notify me when ready") and the V1.E lane in
  /// `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`.
  static const String vendorNowAvailable = 'vendor_now_available';

  /// V1 status: WIRED via `NotificationEventFanout` for the
  /// `notif.backfill.complete` event. Trigger site:
  /// `tool/integration_sync_worker/backfill_dispatch.dart`'s
  /// `markSucceeded`. Hook helper:
  /// `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`
  /// (`emitBackfillComplete`). Registered as part of the B3 hot-fix
  /// slice (`docs/archive/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`
  /// Block B, B3) which closed the silent-failure path where the
  /// hook referenced a template id that was not in `all`.
  static const String backfillComplete = 'backfill_complete';

  /// V1 status: WIRED via `NotificationEventFanout` for the
  /// `notif.backfill.failed` event. Trigger site:
  /// `tool/first_connect_backfill_worker/main.dart`'s
  /// `RetryCappingBackfillJobStore.markFailed`. Hook helper:
  /// `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`
  /// (`emitBackfillFailed`). Registered as part of the B3 hot-fix
  /// slice (see [backfillComplete]).
  static const String backfillFailed = 'backfill_failed';

  /// V1 status: WIRED via `NotificationEventFanout` for the
  /// `notif.audit.anchor_failure` event. Trigger site:
  /// `tool/audit_anchor/main.dart`'s `_runAnchorMode` /
  /// `_runSweepMode` failure branches. Hook helper:
  /// `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`
  /// (`emitAuditAnchorFailure`). Registered as part of the B3
  /// hot-fix slice (see [backfillComplete]). Operator-facing copy
  /// avoids the words "anchor" and "hash chain" per the addendum's
  /// plain-language directive.
  static const String auditAnchorFailure = 'audit_anchor_failure';

  /// All V1 template ids in the order they appear in the slice doc.
  /// Runtime tests iterate this list to confirm every file renders
  /// with sample data.
  static const List<String> all = <String>[
    operatorInviteFirstAdmin,
    mfaFactorChangedNotice,
    vendorSyncErrorAlert,
    vendorConnectionAutoDisabled,
    vendorNowAvailable,
    backfillComplete,
    backfillFailed,
    auditAnchorFailure,
  ];
}

/// Subject patterns LOCKED in the slice doc. Variables in the
/// pattern are interpolated through the same `{{name}}` substitution
/// as the body.
const Map<String, String> _subjectByTemplate = <String, String>{
  EmailTemplateIds.operatorInviteFirstAdmin:
      'Welcome to Forge & Flow: set up your account',
  EmailTemplateIds.mfaFactorChangedNotice:
      'Your Forge & Flow MFA has been updated',
  EmailTemplateIds.vendorSyncErrorAlert:
      'Forge & Flow could not sync from {{vendorName}}',
  EmailTemplateIds.vendorConnectionAutoDisabled:
      '{{vendorName}} connection disabled',
  EmailTemplateIds.vendorNowAvailable:
      '{{vendorName}} is ready to connect in Forge & Flow',
  EmailTemplateIds.backfillComplete:
      'Your {{vendorName}} historical sync is complete',
  EmailTemplateIds.backfillFailed:
      'Your {{vendorName}} historical sync needs attention',
  EmailTemplateIds.auditAnchorFailure:
      'A daily integrity check on your audit log did not complete',
};

class EmailTemplateRenderer {
  EmailTemplateRenderer({
    required EmailTemplateSource templateSource,
    required EmailBrandWrapperSource brandWrapperSource,
  })  : _templateSource = templateSource,
        _brandWrapperSource = brandWrapperSource;

  final EmailTemplateSource _templateSource;
  final EmailBrandWrapperSource _brandWrapperSource;

  /// Resolves the locked subject for [templateId] without rendering.
  /// The proxy's "Test connection" admin route uses this to surface
  /// the subject in the response payload alongside `provider_message_id`.
  String subjectFor(String templateId, Map<String, String> templateData) {
    final pattern = _subjectByTemplate[templateId];
    if (pattern == null) {
      throw ArgumentError('Unknown templateId: $templateId');
    }
    return _interpolate(
      pattern,
      templateData,
      templateId: templateId,
    );
  }

  /// Render the Markdown source for [templateId] into a
  /// [RenderedEmail] envelope. Throws on missing variables, unknown
  /// template ids, or a wrapper missing the `{{body}}` slot.
  RenderedEmail render({
    required String templateId,
    required Map<String, String> templateData,
  }) {
    if (!_subjectByTemplate.containsKey(templateId)) {
      throw ArgumentError('Unknown templateId: $templateId');
    }
    final markdown = _templateSource(templateId);
    final interpolatedMarkdown = _interpolate(
      markdown,
      templateData,
      templateId: templateId,
    );
    final renderedHtmlBody = _markdownToHtml(interpolatedMarkdown);
    final wrapper = _brandWrapperSource();
    if (!wrapper.contains('{{body}}')) {
      throw StateError(
        'Brand wrapper is missing the literal {{body}} placeholder',
      );
    }
    final wrappedHtml = wrapper.replaceAll('{{body}}', renderedHtmlBody);
    final subject = subjectFor(templateId, templateData);
    return RenderedEmail(
      subject: subject,
      htmlBody: wrappedHtml,
      textBody: interpolatedMarkdown.trim(),
    );
  }

  /// Map-backed [EmailTemplateSource] convenience constructor — used
  /// by the unit tests so the suite does not touch disk. Production
  /// loads templates from `tool/advisor_proxy/email_templates/`.
  static EmailTemplateSource fromMap(Map<String, String> templates) {
    return (templateId) {
      final value = templates[templateId];
      if (value == null) {
        throw ArgumentError(
          'Template source has no entry for $templateId',
        );
      }
      return value;
    };
  }

  static EmailBrandWrapperSource fromString(String wrapper) {
    return () => wrapper;
  }

  String _interpolate(
    String source,
    Map<String, String> data, {
    required String templateId,
  }) {
    final pattern = RegExp(r'\{\{\s*([a-zA-Z][a-zA-Z0-9_]*)\s*\}\}');
    return source.replaceAllMapped(pattern, (match) {
      final name = match.group(1)!;
      if (name == 'body') {
        // The brand wrapper uses {{body}} as a slot the renderer
        // fills after Markdown→HTML; templates themselves should
        // never reference {{body}} directly.
        throw StateError(
          'Template $templateId references reserved variable name "body"',
        );
      }
      final value = data[name];
      if (value == null) {
        throw MissingTemplateVariableError(
          templateId: templateId,
          variableName: name,
        );
      }
      return value;
    });
  }

  /// Tiny Markdown→HTML pipeline tuned for the V1 template surface.
  /// Implements paragraphs, single-level headings (`# `), bullet
  /// lists (`- `), bold (`**bold**`), italic (`*italic*`), and
  /// inline links (`[text](url)`). Anything else passes through with
  /// HTML-escaping so unsafe characters do not corrupt the output.
  String _markdownToHtml(String markdown) {
    final lines = const LineSplitter().convert(markdown);
    final buffer = StringBuffer();
    final paragraph = <String>[];
    final bullets = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      final text = paragraph.join(' ').trim();
      paragraph.clear();
      if (text.isEmpty) return;
      buffer.writeln('<p>${_renderInline(text)}</p>');
    }

    void flushBullets() {
      if (bullets.isEmpty) return;
      buffer.writeln('<ul>');
      for (final item in bullets) {
        buffer.writeln('  <li>${_renderInline(item)}</li>');
      }
      buffer.writeln('</ul>');
      bullets.clear();
    }

    for (final raw in lines) {
      final line = raw.trimRight();
      if (line.isEmpty) {
        flushParagraph();
        flushBullets();
        continue;
      }
      if (line.startsWith('# ')) {
        flushParagraph();
        flushBullets();
        buffer.writeln('<h1>${_renderInline(line.substring(2).trim())}</h1>');
        continue;
      }
      if (line.startsWith('## ')) {
        flushParagraph();
        flushBullets();
        buffer.writeln('<h2>${_renderInline(line.substring(3).trim())}</h2>');
        continue;
      }
      if (line.startsWith('- ')) {
        flushParagraph();
        bullets.add(line.substring(2).trim());
        continue;
      }
      paragraph.add(line.trim());
    }
    flushParagraph();
    flushBullets();
    return buffer.toString().trim();
  }

  String _renderInline(String text) {
    var working = _escapeHtml(text);
    // Bold (**text**) — must run before italics so the inner *...*
    // does not match.
    working = working.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => '<strong>${m.group(1)}</strong>',
    );
    // Italic (*text*) — single-asterisk pairs.
    working = working.replaceAllMapped(
      RegExp(r'\*([^*\s][^*]*[^*\s]|[^*\s])\*'),
      (m) => '<em>${m.group(1)}</em>',
    );
    // Inline links [text](url).
    working = working.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)'),
      (m) {
        final label = m.group(1)!;
        final href = m.group(2)!;
        return '<a href="$href">$label</a>';
      },
    );
    return working;
  }

  String _escapeHtml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }
}
