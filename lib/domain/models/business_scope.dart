import 'restaurant_location.dart';

class BusinessScope {
  const BusinessScope({
    required this.scopeId,
    required this.scopeType,
    required this.operatorId,
    required this.label,
    this.locationId,
    this.parentScopeId,
    this.businessTimezone,
    this.sortPath,
  });

  final String scopeId;
  final String scopeType;
  final String operatorId;
  final String? locationId;
  final String? parentScopeId;
  final String label;
  final String? businessTimezone;
  final String? sortPath;

  bool get isLocationScope =>
      scopeType == 'location' && locationId != null && locationId!.isNotEmpty;

  String get stableKey => '$scopeType:$scopeId';

  RestaurantLocation toRestaurantLocation({
    required String createdAt,
    required String updatedAt,
  }) {
    final id = locationId ?? scopeId;
    return RestaurantLocation(
      restaurantId: id,
      displayName: label,
      businessTimezone: businessTimezone ?? '',
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'scope_id': scopeId,
    'scope_type': scopeType,
    'operator_id': operatorId,
    'location_id': locationId,
    'parent_scope_id': parentScopeId,
    'label': label,
    'business_timezone': businessTimezone,
    'sort_path': sortPath,
  };

  static BusinessScope fromJson(Map<String, Object?> json) {
    final scopeId = _requiredString(json['scope_id'], 'scope_id');
    final scopeType = _requiredString(json['scope_type'], 'scope_type');
    final operatorId = _requiredString(json['operator_id'], 'operator_id');
    return BusinessScope(
      scopeId: scopeId,
      scopeType: scopeType,
      operatorId: operatorId,
      locationId: _optionalString(json['location_id']),
      parentScopeId: _optionalString(json['parent_scope_id']),
      label: _optionalString(json['label']) ?? _fallbackLabel(scopeType),
      businessTimezone: _optionalString(json['business_timezone']),
      sortPath: _optionalString(json['sort_path']),
    );
  }

  static String _requiredString(Object? value, String field) {
    final parsed = _optionalString(value);
    if (parsed == null) {
      throw ArgumentError.value(value, field, 'must be a non-empty string');
    }
    return parsed;
  }

  static String? _optionalString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String _fallbackLabel(String scopeType) => switch (scopeType) {
    'operator' => 'Business',
    'org_unit' => 'Group',
    'location' => 'Location',
    _ => 'Business scope',
  };
}
