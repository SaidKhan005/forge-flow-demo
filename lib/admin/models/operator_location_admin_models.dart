// Phase 11A.1 — Operator + location admin value objects.
//
// Carry only the fields the F&F admin console needs to render and
// edit. Mirror the Postgres column shapes from
// `db/migrations/202604250005_advisor_cloud_foundation.sql` exactly:
// `operators(operator_id, business_name, owner_email, subscription_tier,
//            preferred_currency, primary_location_id, suspended_at)`,
// `locations(location_id, operator_id, name, address, timezone,
//            business_day_rollover_hour)`, and
// `operator_admins(user_id, operator_id, is_super_admin)`.
//
// The `suspended_at` field is admitted into the operator value object
// even though the foundation migration does not yet declare the
// column; the repository persists it as an additive `null`-default
// column the 11A.1 repository's UPDATE statements treat as optional.
// Suspension lives only in the admin console UI in this slice — Phase
// 9 enforcement will read it later.

import 'package:flutter/foundation.dart';

import '../../utils/iana_timezones.dart';

@immutable
class OperatorAdminRecord {
  const OperatorAdminRecord({
    required this.operatorId,
    required this.businessName,
    required this.ownerEmail,
    required this.subscriptionTier,
    required this.preferredCurrency,
    required this.primaryLocationId,
    required this.suspendedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String operatorId;
  final String businessName;
  final String ownerEmail;
  final String subscriptionTier;
  final String preferredCurrency;
  final String? primaryLocationId;
  final DateTime? suspendedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isSuspended => suspendedAt != null;

  static OperatorAdminRecord fromJson(Map<String, Object?> json) {
    return OperatorAdminRecord(
      operatorId: json['operator_id']! as String,
      businessName: json['business_name']! as String,
      ownerEmail: json['owner_email']! as String,
      subscriptionTier: json['subscription_tier']! as String,
      preferredCurrency: json['preferred_currency']! as String,
      primaryLocationId: json['primary_location_id'] as String?,
      suspendedAt: _dateTimeOrNull(json['suspended_at']),
      createdAt: DateTime.parse(json['created_at']! as String),
      updatedAt: DateTime.parse(json['updated_at']! as String),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'business_name': businessName,
    'owner_email': ownerEmail,
    'subscription_tier': subscriptionTier,
    'preferred_currency': preferredCurrency,
    'primary_location_id': primaryLocationId,
    'suspended_at': suspendedAt?.toUtc().toIso8601String(),
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

@immutable
class LocationAdminRecord {
  const LocationAdminRecord({
    required this.locationId,
    required this.operatorId,
    required this.name,
    required this.address,
    required this.timezone,
    required this.businessDayRolloverHour,
    required this.createdAt,
    required this.updatedAt,
  });

  final String locationId;
  final String operatorId;
  final String name;
  final String address;
  final String timezone;
  final int? businessDayRolloverHour;
  final DateTime createdAt;
  final DateTime updatedAt;

  static LocationAdminRecord fromJson(Map<String, Object?> json) {
    return LocationAdminRecord(
      locationId: json['location_id']! as String,
      operatorId: json['operator_id']! as String,
      name: json['name']! as String,
      address: (json['address'] as String?) ?? '',
      timezone: json['timezone']! as String,
      businessDayRolloverHour: json['business_day_rollover_hour'] as int?,
      createdAt: DateTime.parse(json['created_at']! as String),
      updatedAt: DateTime.parse(json['updated_at']! as String),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'location_id': locationId,
    'operator_id': operatorId,
    'name': name,
    'address': address,
    'timezone': timezone,
    'business_day_rollover_hour': businessDayRolloverHour,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

@immutable
class OperatorAdminBundle {
  const OperatorAdminBundle({required this.operator, required this.locations});

  final OperatorAdminRecord operator;
  final List<LocationAdminRecord> locations;

  LocationAdminRecord? get primaryLocation {
    final pid = operator.primaryLocationId;
    if (pid == null) return null;
    for (final l in locations) {
      if (l.locationId == pid) return l;
    }
    return null;
  }

  static OperatorAdminBundle fromJson(Map<String, Object?> json) {
    final locs = (json['locations'] as List?) ?? const [];
    return OperatorAdminBundle(
      operator: OperatorAdminRecord.fromJson(
        (json['operator'] as Map).cast<String, Object?>(),
      ),
      locations: <LocationAdminRecord>[
        for (final l in locs)
          LocationAdminRecord.fromJson((l as Map).cast<String, Object?>()),
      ],
    );
  }
}

@immutable
class OperatorOnboardCommand {
  const OperatorOnboardCommand({
    required this.businessName,
    required this.ownerEmail,
    required this.subscriptionTier,
    required this.preferredCurrency,
    required this.primaryLocationName,
    required this.primaryLocationTimezone,
    required this.primaryLocationRolloverHour,
    required this.adminUserEmail,
  });

  final String businessName;
  final String ownerEmail;
  final String subscriptionTier;
  final String preferredCurrency;
  final String primaryLocationName;
  final String primaryLocationTimezone;
  final int primaryLocationRolloverHour;
  final String adminUserEmail;

  Map<String, Object?> toJson() => <String, Object?>{
    'business_name': businessName,
    'owner_email': ownerEmail,
    'subscription_tier': subscriptionTier,
    'preferred_currency': preferredCurrency,
    'primary_location': <String, Object?>{
      'name': primaryLocationName,
      'timezone': primaryLocationTimezone,
      'business_day_rollover_hour': primaryLocationRolloverHour,
    },
    'admin_user_email': adminUserEmail,
  };
}

@immutable
class OperatorPatchCommand {
  const OperatorPatchCommand({
    required this.operatorId,
    this.businessName,
    this.ownerEmail,
    this.subscriptionTier,
    this.preferredCurrency,
    this.primaryLocationId,
  });

  final String operatorId;
  final String? businessName;
  final String? ownerEmail;
  final String? subscriptionTier;
  final String? preferredCurrency;
  final String? primaryLocationId;

  Map<String, Object?> toJson() {
    final body = <String, Object?>{};
    if (businessName != null) body['business_name'] = businessName;
    if (ownerEmail != null) body['owner_email'] = ownerEmail;
    if (subscriptionTier != null) body['subscription_tier'] = subscriptionTier;
    if (preferredCurrency != null) {
      body['preferred_currency'] = preferredCurrency;
    }
    if (primaryLocationId != null) {
      body['primary_location_id'] = primaryLocationId;
    }
    return body;
  }
}

@immutable
class LocationCreateCommand {
  const LocationCreateCommand({
    required this.operatorId,
    required this.name,
    required this.timezone,
    required this.businessDayRolloverHour,
    this.address = '',
  });

  final String operatorId;
  final String name;
  final String address;
  final String timezone;
  final int businessDayRolloverHour;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'name': name,
    'address': address,
    'timezone': timezone,
    'business_day_rollover_hour': businessDayRolloverHour,
  };
}

@immutable
class LocationPatchCommand {
  const LocationPatchCommand({
    required this.locationId,
    this.name,
    this.address,
    this.timezone,
    this.businessDayRolloverHour,
  });

  final String locationId;
  final String? name;
  final String? address;
  final String? timezone;
  final int? businessDayRolloverHour;

  Map<String, Object?> toJson() {
    final body = <String, Object?>{};
    if (name != null) body['name'] = name;
    if (address != null) body['address'] = address;
    if (timezone != null) body['timezone'] = timezone;
    if (businessDayRolloverHour != null) {
      body['business_day_rollover_hour'] = businessDayRolloverHour;
    }
    return body;
  }
}

DateTime? _dateTimeOrNull(Object? value) {
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : DateTime.parse(value);
  return null;
}

/// IANA timezone validation shared with the proxy.
bool isLikelyIanaTimezone(String value) {
  return isValidIanaTimezoneName(value);
}
