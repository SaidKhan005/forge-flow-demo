// B10.1 - vendor_applicability JSONB metadata schemas.
//
// The table intentionally keeps the query dimensions relational and
// reserves JSONB for narrow per-kind details. New setting kinds must add a
// schema here before writes are accepted; unknown kinds are rejected instead
// of becoming an open-ended JSONB-as-EAV surface.

const Set<String> kVendorApplicabilitySettingKinds = <String>{
  VendorApplicabilitySettingKind.wage,
  VendorApplicabilitySettingKind.covers,
  VendorApplicabilitySettingKind.polling,
};

abstract final class VendorApplicabilitySettingKind {
  static const String wage = 'wage';
  static const String covers = 'covers';
  static const String polling = 'polling';
}

class ApplicabilityMetadataValidationResult {
  const ApplicabilityMetadataValidationResult._({
    required this.isValid,
    this.code,
    this.message,
  });

  const ApplicabilityMetadataValidationResult.valid() : this._(isValid: true);

  const ApplicabilityMetadataValidationResult.invalid({
    required String code,
    required String message,
  }) : this._(isValid: false, code: code, message: message);

  final bool isValid;
  final String? code;
  final String? message;
}

class ApplicabilityMetadataValidationException implements Exception {
  const ApplicabilityMetadataValidationException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() =>
      'ApplicabilityMetadataValidationException($code): $message';
}

typedef _Rule =
    ApplicabilityMetadataValidationResult Function(
      Map<String, Object?> metadata,
    );

class _MetadataSchema {
  const _MetadataSchema({required this.allowedKeys, required this.rules});

  final Set<String> allowedKeys;
  final List<_Rule> rules;
}

const Map<String, _MetadataSchema> _schemas = <String, _MetadataSchema>{
  VendorApplicabilitySettingKind.wage: _MetadataSchema(
    allowedKeys: <String>{
      'authority_basis',
      'requires_job_code',
      'vendor_field',
      'notes',
    },
    rules: <_Rule>[
      _validateAuthorityBasis,
      _validateRequiresJobCode,
      _validateVendorField,
      _validateNotes,
    ],
  ),
  VendorApplicabilitySettingKind.covers: _MetadataSchema(
    allowedKeys: <String>{
      'cover_filter',
      'service_periods',
      'exclude_voids',
      'notes',
    },
    rules: <_Rule>[
      _validateCoverFilter,
      _validateServicePeriods,
      _validateExcludeVoids,
      _validateNotes,
    ],
  ),
  VendorApplicabilitySettingKind.polling: _MetadataSchema(
    allowedKeys: <String>{
      'polling_seconds_override',
      'tier_key',
      'reason',
      'notes',
    },
    rules: <_Rule>[
      _validatePollingSeconds,
      _validateTierKey,
      _validateReason,
      _validateNotes,
    ],
  ),
};

ApplicabilityMetadataValidationResult validateApplicabilityMetadata({
  required String settingKind,
  required Map<String, Object?> metadata,
}) {
  final schema = _schemas[settingKind];
  if (schema == null) {
    return ApplicabilityMetadataValidationResult.invalid(
      code: 'unknown_setting_kind',
      message:
          'setting_kind "$settingKind" has no metadata schema; add a schema '
          'before writing vendor applicability metadata',
    );
  }

  for (final key in metadata.keys) {
    if (!schema.allowedKeys.contains(key)) {
      return ApplicabilityMetadataValidationResult.invalid(
        code: 'metadata_key_not_allowed',
        message:
            'metadata key "$key" is not allowed for setting_kind '
            '"$settingKind"',
      );
    }
  }

  for (final rule in schema.rules) {
    final result = rule(metadata);
    if (!result.isValid) return result;
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

void assertApplicabilityMetadataValid({
  required String settingKind,
  required Map<String, Object?> metadata,
}) {
  final result = validateApplicabilityMetadata(
    settingKind: settingKind,
    metadata: metadata,
  );
  if (!result.isValid) {
    throw ApplicabilityMetadataValidationException(
      code: result.code ?? 'invalid_metadata',
      message: result.message ?? 'metadata is invalid',
    );
  }
}

ApplicabilityMetadataValidationResult _validateAuthorityBasis(
  Map<String, Object?> metadata,
) {
  return _stringEnum(metadata, 'authority_basis', const <String>{
    'job_code',
    'vendor_pay_rate',
    'manual_mapping',
  });
}

ApplicabilityMetadataValidationResult _validateRequiresJobCode(
  Map<String, Object?> metadata,
) {
  return _optionalBool(metadata, 'requires_job_code');
}

ApplicabilityMetadataValidationResult _validateVendorField(
  Map<String, Object?> metadata,
) {
  return _optionalSlug(metadata, 'vendor_field', maxLength: 64);
}

ApplicabilityMetadataValidationResult _validateCoverFilter(
  Map<String, Object?> metadata,
) {
  return _stringEnum(metadata, 'cover_filter', const <String>{
    'dine_in_only',
    'all_covers',
    'exclude_cancelled',
  });
}

ApplicabilityMetadataValidationResult _validateServicePeriods(
  Map<String, Object?> metadata,
) {
  final value = metadata['service_periods'];
  if (value == null) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  if (value is! List || value.isEmpty) {
    return const ApplicabilityMetadataValidationResult.invalid(
      code: 'invalid_service_periods',
      message: 'service_periods must be a non-empty string array',
    );
  }
  final seen = <String>{};
  for (final entry in value) {
    if (entry is! String ||
        !_servicePeriodKeyPattern.hasMatch(entry) ||
        !seen.add(entry)) {
      return const ApplicabilityMetadataValidationResult.invalid(
        code: 'invalid_service_periods',
        message:
            'service_periods entries must be unique service-period keys '
            r'matching ^[a-z][a-z0-9_]{0,63}$',
      );
    }
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

ApplicabilityMetadataValidationResult _validateExcludeVoids(
  Map<String, Object?> metadata,
) {
  return _optionalBool(metadata, 'exclude_voids');
}

ApplicabilityMetadataValidationResult _validatePollingSeconds(
  Map<String, Object?> metadata,
) {
  final value = metadata['polling_seconds_override'];
  if (value == null) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  if (value is! int || value < 60 || value > 86400) {
    return const ApplicabilityMetadataValidationResult.invalid(
      code: 'invalid_polling_seconds_override',
      message:
          'polling_seconds_override must be an integer between 60 and 86400',
    );
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

ApplicabilityMetadataValidationResult _validateTierKey(
  Map<String, Object?> metadata,
) {
  return _stringEnum(metadata, 'tier_key', const <String>{
    'standard',
    'premium',
    'custom',
  });
}

ApplicabilityMetadataValidationResult _validateReason(
  Map<String, Object?> metadata,
) {
  return _optionalText(metadata, 'reason', maxLength: 200);
}

ApplicabilityMetadataValidationResult _validateNotes(
  Map<String, Object?> metadata,
) {
  return _optionalText(metadata, 'notes', maxLength: 500);
}

ApplicabilityMetadataValidationResult _stringEnum(
  Map<String, Object?> metadata,
  String key,
  Set<String> allowed,
) {
  final value = metadata[key];
  if (value == null) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  if (value is! String || !allowed.contains(value)) {
    return ApplicabilityMetadataValidationResult.invalid(
      code: 'invalid_$key',
      message: '$key must be one of: ${allowed.join(', ')}',
    );
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

ApplicabilityMetadataValidationResult _optionalBool(
  Map<String, Object?> metadata,
  String key,
) {
  final value = metadata[key];
  if (value == null || value is bool) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  return ApplicabilityMetadataValidationResult.invalid(
    code: 'invalid_$key',
    message: '$key must be a boolean',
  );
}

ApplicabilityMetadataValidationResult _optionalText(
  Map<String, Object?> metadata,
  String key, {
  required int maxLength,
}) {
  final value = metadata[key];
  if (value == null) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  if (value is! String || value.trim().isEmpty || value.length > maxLength) {
    return ApplicabilityMetadataValidationResult.invalid(
      code: 'invalid_$key',
      message: '$key must be a non-empty string no longer than $maxLength',
    );
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

ApplicabilityMetadataValidationResult _optionalSlug(
  Map<String, Object?> metadata,
  String key, {
  required int maxLength,
}) {
  final value = metadata[key];
  if (value == null) {
    return const ApplicabilityMetadataValidationResult.valid();
  }
  if (value is! String ||
      value.isEmpty ||
      value.length > maxLength ||
      !_slugPattern.hasMatch(value)) {
    return ApplicabilityMetadataValidationResult.invalid(
      code: 'invalid_$key',
      message:
          '$key must be a lowercase slug no longer than $maxLength '
          'characters',
    );
  }
  return const ApplicabilityMetadataValidationResult.valid();
}

final RegExp _slugPattern = RegExp(r'^[a-z][a-z0-9_]*$');
final RegExp _servicePeriodKeyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
