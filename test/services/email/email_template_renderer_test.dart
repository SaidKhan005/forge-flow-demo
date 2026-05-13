// Phase 9.8 email-provider slice — EmailTemplateRenderer tests.
//
// Loads the actual V1 templates + brand wrapper from
// `tool/advisor_proxy/email_templates/` and asserts each renders
// with sample data. Also covers:
//
//   * Variable interpolation (Markdown + subject line).
//   * Missing variables → MissingTemplateVariableError.
//   * HTML escaping for hostile interpolated values.
//   * Brand wrapper {{body}} replacement.
//   * Subject patterns honored per locked map.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_template_renderer.dart';

void main() {
  // Resolve the templates directory relative to the package root.
  // `flutter test` runs from the package root, so the relative path
  // matches what the production proxy bootstrap uses.
  final templatesDir = Directory('tool/advisor_proxy/email_templates');

  EmailTemplateRenderer rendererFromDisk() {
    final wrapperFile = File('${templatesDir.path}/_brand_wrapper.html');
    final wrapper = wrapperFile.readAsStringSync();
    final templates = <String, String>{};
    for (final id in EmailTemplateIds.all) {
      final file = File('${templatesDir.path}/$id.md');
      templates[id] = file.readAsStringSync();
    }
    return EmailTemplateRenderer(
      templateSource: EmailTemplateRenderer.fromMap(templates),
      brandWrapperSource: EmailTemplateRenderer.fromString(wrapper),
    );
  }

  /// Sample data covering every variable referenced by every V1
  /// template. Updating a template to add a new variable means
  /// adding an entry here too — the suite asserts every template
  /// renders, so missing variables fail loudly.
  Map<String, String> sampleData() => <String, String>{
        'recipientName': 'Test Admin',
        'businessName': 'Acme Bistro',
        'inviterName': 'Pat Manager',
        'roleLabel': 'Location admin',
        'rolePermissionsSummary':
            'view this location\'s dashboard and act on recommendations',
        'setupUrl': 'https://app.forgeflow.app/onboarding/abc123',
        'acceptUrl': 'https://app.forgeflow.app/invite/abc123',
        'resetUrl': 'https://app.forgeflow.app/reset/abc123',
        'linkExpiryHumanReadable': 'in 24 hours',
        'occurredAtHumanReadable': '2026-05-04 09:14 UTC',
        'changeDescription': 'Authenticator app added',
        'accountSecurityUrl':
            'https://app.forgeflow.app/account/security',
        'vendorName': 'Toast',
        'firstFailureHumanReadable': '2026-05-04 03:00 UTC',
        'errorSummary': 'OAuth refresh token rejected',
        'integrationConsoleUrl':
            'https://app.forgeflow.app/admin/integrations',
        'escalationWindowHumanReadable': '4 hours',
        'disabledAtHumanReadable': '2026-05-04 12:30 UTC',
        'strikeCount': '3',
        'lastErrorSummary': 'invalid_grant',
        // B3 hot-fix templates (backfill complete / failed,
        // audit anchor failure).
        'completionTimestampHumanReadable': '2026-05-04 17:42 UTC',
        'dashboardUrl': 'https://app.forgeflow.app/dashboard',
        'errorCategory': 'network timeout during seed run',
        'vendorConnectionUrl':
            'https://app.forgeflow.app/admin/integrations/toast',
        'checkDateHumanReadable': '2026-05-04',
        'summary': 'one daily check did not finish before the next started',
        'retryStatusHumanReadable':
            'will retry on the next scheduled cycle',
      };

  group('EmailTemplateRenderer', () {
    test('every V1 template renders with sample data', () {
      final renderer = rendererFromDisk();
      final data = sampleData();
      for (final id in EmailTemplateIds.all) {
        final rendered = renderer.render(
          templateId: id,
          templateData: data,
        );
        expect(
          rendered.subject,
          isNotEmpty,
          reason: 'subject must render for $id',
        );
        // Subject lines should not contain raw {{var}} placeholders.
        expect(
          rendered.subject,
          isNot(contains('{{')),
          reason: '$id subject leaked an unrendered placeholder',
        );
        expect(
          rendered.htmlBody,
          isNotEmpty,
          reason: 'html body must render for $id',
        );
        expect(
          rendered.htmlBody,
          isNot(contains('{{')),
          reason: '$id html leaked an unrendered placeholder',
        );
        expect(
          rendered.textBody,
          isNotEmpty,
          reason: 'text body must render for $id',
        );
        // Brand wrapper is applied — every render contains the
        // wrapper's container class name.
        expect(rendered.htmlBody, contains('ff-container'));
      }
    });

    test('missing variable raises MissingTemplateVariableError', () {
      final renderer = rendererFromDisk();
      final data = sampleData()..remove('vendorName');
      expect(
        () => renderer.render(
          templateId: EmailTemplateIds.vendorNowAvailable,
          templateData: data,
        ),
        throwsA(isA<MissingTemplateVariableError>()
            .having((e) => e.variableName, 'variableName', 'vendorName')
            .having((e) => e.templateId, 'templateId',
                EmailTemplateIds.vendorNowAvailable)),
      );
    });

    test('subjectFor honors the locked subject pattern', () {
      final renderer = rendererFromDisk();
      final data = sampleData();
      expect(
        renderer.subjectFor(
          EmailTemplateIds.operatorInviteFirstAdmin,
          data,
        ),
        'Welcome to Forge & Flow — set up your account',
      );
      expect(
        renderer.subjectFor(
          EmailTemplateIds.vendorNowAvailable,
          data,
        ),
        'Toast is ready to connect in Forge & Flow',
      );
    });

    test('HTML escapes hostile interpolated values', () {
      final renderer = EmailTemplateRenderer(
        templateSource: EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.operatorInviteFirstAdmin:
              'Hello {{recipientName}}, welcome.',
        }),
        brandWrapperSource: EmailTemplateRenderer.fromString(
          '<html><body>{{body}}</body></html>',
        ),
      );
      final rendered = renderer.render(
        templateId: EmailTemplateIds.operatorInviteFirstAdmin,
        templateData: <String, String>{
          'recipientName': '<script>alert("xss")</script>',
        },
      );
      expect(rendered.htmlBody, contains('&lt;script&gt;'));
      expect(rendered.htmlBody, isNot(contains('<script>')));
    });

    test('throws ArgumentError when templateId is unknown', () {
      final renderer = EmailTemplateRenderer(
        templateSource:
            EmailTemplateRenderer.fromMap(<String, String>{}),
        brandWrapperSource: EmailTemplateRenderer.fromString('{{body}}'),
      );
      expect(
        () => renderer.render(
          templateId: 'nonexistent_template',
          templateData: <String, String>{},
        ),
        throwsArgumentError,
      );
    });

    test('throws StateError when wrapper lacks {{body}} placeholder', () {
      final renderer = EmailTemplateRenderer(
        templateSource:
            EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.operatorInviteFirstAdmin: 'Body',
        }),
        brandWrapperSource:
            EmailTemplateRenderer.fromString('<html><body>missing</body></html>'),
      );
      expect(
        () => renderer.render(
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          templateData: <String, String>{},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('renders Markdown bold + italic + link inline', () {
      final renderer = EmailTemplateRenderer(
        templateSource:
            EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.operatorInviteFirstAdmin:
              'This is **bold** and *italic* and a [link](https://forgeflow.app).',
        }),
        brandWrapperSource: EmailTemplateRenderer.fromString('{{body}}'),
      );
      final rendered = renderer.render(
        templateId: EmailTemplateIds.operatorInviteFirstAdmin,
        templateData: <String, String>{},
      );
      expect(rendered.htmlBody, contains('<strong>bold</strong>'));
      expect(rendered.htmlBody, contains('<em>italic</em>'));
      expect(
        rendered.htmlBody,
        contains('<a href="https://forgeflow.app">link</a>'),
      );
    });

    test('renders Markdown bullet list', () {
      final renderer = EmailTemplateRenderer(
        templateSource:
            EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.operatorInviteFirstAdmin:
              'List:\n\n- one\n- two\n- three\n',
        }),
        brandWrapperSource: EmailTemplateRenderer.fromString('{{body}}'),
      );
      final rendered = renderer.render(
        templateId: EmailTemplateIds.operatorInviteFirstAdmin,
        templateData: <String, String>{},
      );
      expect(rendered.htmlBody, contains('<ul>'));
      expect(rendered.htmlBody, contains('<li>one</li>'));
      expect(rendered.htmlBody, contains('<li>two</li>'));
      expect(rendered.htmlBody, contains('<li>three</li>'));
    });
  });

  group('EmailTemplateIds.all', () {
    test('lists the live repo-owned templates from the slice doc + V1.E '
        'fan-out template + B3 hot-fix templates', () {
      // A2.2 deleted the Firebase-superseded password reset and
      // operator-admin invite Markdown copies. Phase 8 V1.E added
      // `vendor_now_available` for the lifecycle-promotion fan-out.
      // B3 hot-fix (2026-05-12) added 3 more
      // (`backfill_complete`, `backfill_failed`, `audit_anchor_failure`)
      // that had hooks calling NotificationEventFanout but no
      // registered template id, so the email channel silently
      // no-op'd. C-2-Del (2026-05-13) deleted
      // `vendor_webhook_signature_alert` (E) +
      // `tos_version_updated_notice` (G) per the C-2 operator picks
      // (Cloud Logging alerts cover signature failures; in-app
      // accept-screen gate covers TOS updates).
      // Source: `docs/_execution/2026-05-06_v1_closure_dispatch_plan.md`
      // V1.E + addendum B3/C3 + C-2 decision matrix.
      expect(EmailTemplateIds.all, hasLength(8));
      expect(EmailTemplateIds.all, contains('operator_invite_first_admin'));
      expect(EmailTemplateIds.all, isNot(contains('operator_admin_invite')));
      expect(EmailTemplateIds.all, isNot(contains('password_reset_request')));
      expect(
        EmailTemplateIds.all,
        isNot(contains('vendor_webhook_signature_alert')),
      );
      expect(
        EmailTemplateIds.all,
        isNot(contains('tos_version_updated_notice')),
      );
      expect(EmailTemplateIds.all, contains('mfa_factor_changed_notice'));
      expect(EmailTemplateIds.all, contains('vendor_sync_error_alert'));
      expect(
        EmailTemplateIds.all,
        contains('vendor_connection_auto_disabled'),
      );
      expect(EmailTemplateIds.all, contains('vendor_now_available'));
      expect(EmailTemplateIds.all, contains('backfill_complete'));
      expect(EmailTemplateIds.all, contains('backfill_failed'));
      expect(EmailTemplateIds.all, contains('audit_anchor_failure'));
    });

    test('every V1 template has a matching .md file on disk', () {
      for (final id in EmailTemplateIds.all) {
        final file = File('${templatesDir.path}/$id.md');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'expected $id.md to exist',
        );
      }
    });

    test('brand wrapper exists on disk', () {
      final wrapperFile = File('${templatesDir.path}/_brand_wrapper.html');
      expect(wrapperFile.existsSync(), isTrue);
      expect(
        wrapperFile.readAsStringSync(),
        contains('{{body}}'),
        reason: 'brand wrapper must include the {{body}} slot',
      );
    });
  });
}
