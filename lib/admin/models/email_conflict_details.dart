import 'package:flutter/foundation.dart';

@immutable
class AdminEmailConflictUsage {
  const AdminEmailConflictUsage({
    required this.email,
    this.userId,
    this.operatorId,
    this.operatorName,
    this.locationId,
    this.locationName,
    this.orgUnitId,
    this.orgUnitName,
    this.status,
    this.roleLabel,
    this.source,
    this.note,
  });

  final String email;
  final String? userId;
  final String? operatorId;
  final String? operatorName;
  final String? locationId;
  final String? locationName;
  final String? orgUnitId;
  final String? orgUnitName;
  final String? status;
  final String? roleLabel;
  final String? source;
  final String? note;

  String get sourceLabel {
    switch (source) {
      case 'pending_invite':
        return 'Pending invite';
      case 'firebase_account':
        return 'Firebase account';
      case 'team_member':
      default:
        return 'Team member';
    }
  }

  String get scopeLabel {
    final parts = <String>[
      if (operatorName != null && operatorName!.isNotEmpty) operatorName!,
      if (orgUnitName != null && orgUnitName!.isNotEmpty) orgUnitName!,
      if (locationName != null && locationName!.isNotEmpty) locationName!,
    ];
    if (parts.isNotEmpty) return parts.join(' / ');
    return note ?? 'Account exists, but no operator link was returned.';
  }

  static List<AdminEmailConflictUsage> listFromDetails(
    Map<String, Object?> details,
  ) {
    final conflicts = <AdminEmailConflictUsage>[];
    final rawList = details['email_conflicts'];
    if (rawList is List) {
      for (final raw in rawList) {
        final parsed = _fromAny(raw);
        if (parsed != null) conflicts.add(parsed);
      }
    }
    final rawSingle = details['email_conflict'];
    final parsedSingle = _fromAny(rawSingle);
    if (parsedSingle != null) conflicts.add(parsedSingle);
    if (conflicts.isNotEmpty) return conflicts;

    final email = _string(details['email']);
    final note = _string(details['email_conflict_note']);
    if (email == null && note == null) return const <AdminEmailConflictUsage>[];
    return <AdminEmailConflictUsage>[
      AdminEmailConflictUsage(
        email: email ?? '',
        source: 'firebase_account',
        note: note,
      ),
    ];
  }

  static AdminEmailConflictUsage? _fromAny(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final email = _string(json['email']);
    if (email == null && _string(json['note']) == null) return null;
    return AdminEmailConflictUsage(
      email: email ?? '',
      userId: _string(json['user_id']),
      operatorId: _string(json['operator_id']),
      operatorName:
          _string(json['operator_name']) ?? _string(json['business_name']),
      locationId:
          _string(json['location_id']) ?? _string(json['primary_location_id']),
      locationName:
          _string(json['location_name']) ?? _string(json['location_label']),
      orgUnitId: _string(json['org_unit_id']),
      orgUnitName:
          _string(json['org_unit_name']) ?? _string(json['org_unit_label']),
      status: _string(json['status']),
      roleLabel: _string(json['role_label']) ?? _string(json['role_key']),
      source: _string(json['source']),
      note: _string(json['note']),
    );
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
