// Shared admin copy helpers for translating backend grouping IDs into
// readable labels while keeping the exact IDs visible for filtering.

import '../domain/models/forge_flow_polling_tier_assignment.dart'
    show PollingTierKey;
import 'models/debug_console_admin_models.dart' show RequestLogStatus;

const List<String> _adminMonthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class AdminRequestUseCaseCopy {
  const AdminRequestUseCaseCopy({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;
}

const List<AdminRequestUseCaseCopy> adminRequestUseCases =
    <AdminRequestUseCaseCopy>[
      AdminRequestUseCaseCopy(
        id: 'advisor_qa',
        label: 'Advisor answers',
        description: 'Questions answered by the AI advisor.',
      ),
      AdminRequestUseCaseCopy(
        id: 'coach_qa',
        label: 'Coaching help',
        description: 'Manager and staff coaching guidance.',
      ),
      AdminRequestUseCaseCopy(
        id: 'wf_pl',
        label: 'Workflow planning',
        description: 'Workflow planning before follow-up work is scheduled.',
      ),
      AdminRequestUseCaseCopy(
        id: 'wf_schedule',
        label: 'Workflow scheduling',
        description: 'Scheduled workflow follow-up and reminders.',
      ),
    ];

/// Plain-English labels for the support-help request classes that the
/// Support logs Type filter folds in alongside the four AI use cases
/// above. Kept SEPARATE from [adminRequestUseCases] so the four AI
/// labels stay byte-stable for the observability + pricing screens (and
/// their tests), while these support classes stop title-casing into
/// machine-ish strings like "Mfa Diagnostics". Mirrors the wording in
/// `debug_console_admin_gateway.dart`'s relationship/account use cases.
const List<AdminRequestUseCaseCopy> adminSupportRequestUseCases =
    <AdminRequestUseCaseCopy>[
      AdminRequestUseCaseCopy(
        id: 'relationship_review',
        label: 'Relationship review',
        description: 'Knowledge graph and relationship review support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'knowledge_relationship',
        label: 'Knowledge links',
        description: 'Knowledge-base relationship linking and review.',
      ),
      AdminRequestUseCaseCopy(
        id: 'corpus_relationship_review',
        label: 'Corpus review',
        description: 'Corpus relationship review and repair requests.',
      ),
      AdminRequestUseCaseCopy(
        id: 'account_help',
        label: 'Account help',
        description: 'General account assistance and operator access support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'auth_support',
        label: 'Sign-in help',
        description: 'Authentication and sign-in support requests.',
      ),
      AdminRequestUseCaseCopy(
        id: 'mfa_diagnostics',
        label: 'MFA help',
        description: 'Multi-factor setup and recovery diagnostics.',
      ),
      AdminRequestUseCaseCopy(
        id: 'session_support',
        label: 'Session help',
        description: 'Active session review and sign-out support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'notification_support',
        label: 'Notification help',
        description: 'Email, push, and notification delivery support.',
      ),
      AdminRequestUseCaseCopy(
        id: 'user_removal',
        label: 'Removal requests',
        description: 'User deactivation, removal, and erasure support.',
      ),
    ];

String adminRequestUseCaseLabel(String id) {
  final known = _findRequestUseCase(id);
  if (known != null) return known.label;
  if (id.trim().isEmpty) return 'Unknown request group';
  return _titleCaseId(id);
}

String adminRequestUseCaseDescription(String id) {
  final known = _findRequestUseCase(id);
  if (known != null) return known.description;
  return 'Custom backend request group. Use the ID when filtering.';
}

/// Display-only, plain-English wording for a request's coarse result on
/// the Support logs screen. This is NOT a wire value: it never feeds the
/// `status=` query param (that stays [requestLogStatusLabel] in the
/// models layer). Honesty (Metric Honesty Doctrine): an `unknown`
/// status — a request with no recorded outcome — reads "Not recorded",
/// NOT a fabricated "Worked". `success` reads "Worked"; the failure
/// wordings cover the queued failure/timeout telemetry (P1b.2) so they
/// render correctly the moment real error/timeout rows arrive.
String adminRequestResultWording(RequestLogStatus status) {
  switch (status) {
    case RequestLogStatus.success:
      return 'Worked';
    case RequestLogStatus.error:
      return 'Failed';
    case RequestLogStatus.timeout:
      return 'Timed out';
    case RequestLogStatus.unknown:
      return 'Not recorded';
  }
}

String adminPollingTierLabel(PollingTierKey tier) {
  switch (tier) {
    case PollingTierKey.standard:
      return 'Regular';
    case PollingTierKey.premium:
      return 'Premium';
    case PollingTierKey.custom:
      return 'Custom';
  }
}

String adminRequestUseCaseLabelWithId(String id) {
  final trimmed = id.trim();
  if (trimmed.isEmpty) return 'Unknown request group';
  return '${adminRequestUseCaseLabel(trimmed)} ($trimmed)';
}

String adminHumanDateTime(DateTime when) {
  final local = when.toLocal();
  final month = _adminMonthNames[local.month - 1];
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final period = local.hour >= 12 ? 'PM' : 'AM';
  final zone = local.timeZoneName.trim();
  final zoneSuffix = zone.isEmpty ? '' : ' $zone';
  return '$month ${local.day}, ${local.year} at $hour:$minute $period'
      '$zoneSuffix';
}

String adminRelativeUpdated(DateTime updatedAt, DateTime now) {
  final elapsed = now.toUtc().difference(updatedAt.toUtc());
  if (elapsed.isNegative || elapsed.inSeconds < 45) return 'just now';
  if (elapsed.inMinutes < 60) {
    final minutes = elapsed.inMinutes;
    return '$minutes minute${minutes == 1 ? '' : 's'} ago';
  }
  if (elapsed.inHours < 24) {
    final hours = elapsed.inHours;
    return '$hours hour${hours == 1 ? '' : 's'} ago';
  }
  final days = elapsed.inDays;
  return '$days day${days == 1 ? '' : 's'} ago';
}

AdminRequestUseCaseCopy? _findRequestUseCase(String id) {
  final normalized = id.trim().toLowerCase();
  for (final useCase in adminRequestUseCases) {
    if (useCase.id == normalized) return useCase;
  }
  for (final useCase in adminSupportRequestUseCases) {
    if (useCase.id == normalized) return useCase;
  }
  return null;
}

String _titleCaseId(String id) {
  final words = id
      .trim()
      .replaceAll(RegExp(r'[_\-]+'), ' ')
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty);
  if (words.isEmpty) return 'Unknown request group';
  return words
      .map((word) {
        if (word.length == 1) return word.toUpperCase();
        return word.substring(0, 1).toUpperCase() +
            word.substring(1).toLowerCase();
      })
      .join(' ');
}
