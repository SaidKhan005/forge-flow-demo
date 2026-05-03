// Phase 9.8 email-provider slice — EmailTemplateRenderer tests.
//
// Loads the actual 8 V1 templates + brand wrapper from
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
        'failedSignatureCount': '12',
        'observationWindowHumanReadable': '15 minutes',
        'rateLimitWindowHumanReadable': '1 hour',
        'disabledAtHumanReadable': '2026-05-04 12:30 UTC',
        'strikeCount': '3',
        'lastErrorSummary': 'invalid_grant',
        'publishedAtHumanReadable': '2026-05-04',
        'effectiveAtHumanReadable': '2026-06-03',
        'changeSummary': 'Updated data-processing terms.',
        'versionLabel': '2026-06-03',
        'tosUrl': 'https://forgeflow.app/legal/tos',
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
      final data = sampleData()..remove('businessName');
      expect(
        () => renderer.render(
          templateId: EmailTemplateIds.operatorAdminInvite,
          templateData: data,
        ),
        throwsA(isA<MissingTemplateVariableError>()
            .having((e) => e.variableName, 'variableName', 'businessName')
            .having((e) => e.templateId, 'templateId',
                EmailTemplateIds.operatorAdminInvite)),
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
          EmailTemplateIds.operatorAdminInvite,
          data,
        ),
        'Pat Manager invited you to join Acme Bistro',
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
    test('lists exactly the 8 V1 templates from the slice doc', () {
      expect(EmailTemplateIds.all, hasLength(8));
      expect(EmailTemplateIds.all, contains('operator_invite_first_admin'));
      expect(EmailTemplateIds.all, contains('operator_admin_invite'));
      expect(EmailTemplateIds.all, contains('password_reset_request'));
      expect(EmailTemplateIds.all, contains('mfa_factor_changed_notice'));
      expect(EmailTemplateIds.all, contains('vendor_sync_error_alert'));
      expect(
        EmailTemplateIds.all,
        contains('vendor_webhook_signature_alert'),
      );
      expect(
        EmailTemplateIds.all,
        contains('vendor_connection_auto_disabled'),
      );
      expect(EmailTemplateIds.all, contains('tos_version_updated_notice'));
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
