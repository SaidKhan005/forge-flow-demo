// Shared admin copy helpers for translating backend grouping IDs into
// readable labels while keeping the exact IDs visible for filtering.

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

AdminRequestUseCaseCopy? _findRequestUseCase(String id) {
  final normalized = id.trim().toLowerCase();
  for (final useCase in adminRequestUseCases) {
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
