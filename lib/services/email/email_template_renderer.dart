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
  /// `EmailProvider.send`, bypassing `email_outbox`). The real
  /// production invite path uses the Firebase Identity Platform
  /// password-reset action-link template (see
  /// `lib/services/auth/repository_auth_operations_gateway.dart:463`'s
  /// `firebaseAdmin.sendPasswordResetEmail` call) per addendum B4
  /// resolution path 1 ("keep Firebase as the production invite
  /// email"). A2.2 deleted the companion `operator_admin_invite.md`
  /// template + its id entry but PRESERVED this template because the
  /// admin test route is its live consumer. C-2 confirms the
  /// preservation: deleting this template would break the SendGrid
  /// connectivity test surface with no replacement. Source:
  /// `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`.
  static const String operatorInviteFirstAdmin =
      'operator_invite_first_admin';

  /// V1 status: TEMPLATE ONLY. Wire deferred per C-2 operator
  /// decision: no clear server-side "MFA factor changed" emission
  /// site exists today. MFA enrollment (`lib/services/mfa/mfa_enrollment_service.dart`)
  /// is a client-side seam — the server only sees `mfa_factors`
  /// rows after Firebase confirms TOTP enrollment, with no per-event
  /// "factor changed" hook surface. MFA removal (`lib/services/mfa/mfa_removal_worker.dart`)
  /// already emits to the `event_outbox` topic
  /// `auth.user.mfa_factor_removed` and the in-app inbox via
  /// `AppNotificationService.emitMfaAuthenticatorRemoved` — wiring
  /// email here means deciding whether email duplicates the existing
  /// inbox emit (UX-driven) and adding a recipient-resolution path
  /// (the worker holds `userId` but not the user's email). C-2 ships
  /// no wire; operator decision pending. Source:
  /// `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft C.
  static const String mfaFactorChangedNotice = 'mfa_factor_changed_notice';

  /// V1 status: TEMPLATE ONLY. Wire deferred per C-2 operator
  /// decision: no production "sustained sync failure" aggregator
  /// exists today. The polling tier emits per-tick `connector_sync_log`
  /// rows (`event_kind = 'auth_refresh' / 'auth_refresh_failed'`)
  /// but does not detect "first failure of a new outage" — wiring a
  /// per-row email would spam the operator on every transient hiccup.
  /// The OAuth refresh worker (`tool/oauth_refresh_worker/main.dart`)
  /// covers the auto-disable cap path, which `vendorConnectionAutoDisabled`
  /// owns. C-2 ships no wire; operator decision pending on either
  /// (a) build a new "first-failure-of-outage" detector, or
  /// (b) delete and rely on the existing `error` chip on the
  /// Connected services card (`lib/admin/screens/integration_admin_screen.dart`).
  /// Source: `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft D.
  static const String vendorSyncErrorAlert = 'vendor_sync_error_alert';

  /// V1 status: TEMPLATE ONLY. Phase 8 lean cut 2 explicitly deferred
  /// the OAuth-refresh-cron emitter that would enqueue an
  /// `email_outbox` row when a vendor connection auto-disables on
  /// 3 consecutive refresh failures (see
  /// `lib/services/integration/oauth_refresh_cron.dart:36-44` and
  /// the lean-cut block in
  /// `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md`
  /// 8.0 deliverables — "Email alert wiring to `9.8.email` deferred").
  /// C-2 reviewed reversal: the auto-disable trigger site IS clean
  /// (`tool/oauth_refresh_worker/main.dart:1196` + `:1226` both call
  /// `gateway.autoDisableConnection`, well-bounded for a single
  /// fanout-hook insertion). BUT: the worker is a Cloud Run binary
  /// with no current `NotificationEventFanout` dependency wired in
  /// its `WorkerRuntime` bootstrap. Wiring email here requires either
  /// (a) constructing a full fanout instance + recipient-resolution
  /// path in the worker (substantial new dependency wiring), or
  /// (b) a direct-enqueue path through `EmailOutboxEnqueueRepository`
  /// + an `OperatorAdminEmailLookup` seam (parallel to
  /// `VendorLifecycleNotificationDispatcher`'s pattern). C-2 ships
  /// no wire; operator decision pending on (a) vs (b) and on
  /// whether the V1 lean-cut decision should be reversed now (vs
  /// post-launch when alert volume justifies it). Source:
  /// `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md`
  /// Draft F.
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
  /// slice (`docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`
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
      'Welcome to Forge & Flow — set up your account',
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
