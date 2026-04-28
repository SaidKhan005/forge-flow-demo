// Phase 9.10 - Team Users list controller.
//
// Pure-logic controller that maps the user-facing filter state into
// a `(operator_id, location_id, status?, role?, mfaEnrolled?,
// search?)` query the proxy executes. The controller does not own
// the HTTP call — it owns the state + emits change notifications so
// the Material UI list can rebuild reactively.

import 'package:flutter/foundation.dart';

class TeamUsersFilter {
  const TeamUsersFilter({
    this.statusFilter,
    this.roleFilter,
    this.locationFilter,
    this.mfaEnrolledFilter,
    this.searchQuery = '',
  });

  /// Filter to a specific user status (e.g. 'active', 'suspended',
  /// 'dormant_30'). Null = no filter.
  final String? statusFilter;

  /// Filter to a specific role_key. Null = no filter.
  final String? roleFilter;

  /// Filter to a specific location_id. Null = all assigned
  /// locations the actor can see.
  final String? locationFilter;

  /// Filter by MFA enrollment status. Null = no filter.
  final bool? mfaEnrolledFilter;

  /// Plain-text search applied to email + display_name. Empty string
  /// means "no search".
  final String searchQuery;

  bool get hasAnyFilter {
    return statusFilter != null ||
        roleFilter != null ||
        locationFilter != null ||
        mfaEnrolledFilter != null ||
        searchQuery.trim().isNotEmpty;
  }

  TeamUsersFilter copyWith({
    Object? statusFilter = _sentinel,
    Object? roleFilter = _sentinel,
    Object? locationFilter = _sentinel,
    Object? mfaEnrolledFilter = _sentinel,
    String? searchQuery,
  }) {
    return TeamUsersFilter(
      statusFilter: identical(statusFilter, _sentinel)
          ? this.statusFilter
          : statusFilter as String?,
      roleFilter: identical(roleFilter, _sentinel)
          ? this.roleFilter
          : roleFilter as String?,
      locationFilter: identical(locationFilter, _sentinel)
          ? this.locationFilter
          : locationFilter as String?,
      mfaEnrolledFilter: identical(mfaEnrolledFilter, _sentinel)
          ? this.mfaEnrolledFilter
          : mfaEnrolledFilter as bool?,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }

  /// Maps the filter into the `(name, value)` parameter map the
  /// proxy lookup expects. Null filters are omitted entirely so the
  /// SQL builder doesn't have to special-case them.
  Map<String, Object?> toQueryParameters() {
    final params = <String, Object?>{};
    if (statusFilter != null) params['status'] = statusFilter;
    if (roleFilter != null) params['role_key'] = roleFilter;
    if (locationFilter != null) params['location_id'] = locationFilter;
    if (mfaEnrolledFilter != null) {
      params['mfa_enrolled'] = mfaEnrolledFilter;
    }
    final q = searchQuery.trim();
    if (q.isNotEmpty) params['q'] = q;
    return params;
  }
}

const Object _sentinel = Object();

class TeamUsersListController extends ChangeNotifier {
  TeamUsersListController({
    TeamUsersFilter initialFilter = const TeamUsersFilter(),
    int pageSize = defaultPageSize,
  }) : _filter = initialFilter,
       _pageSize = pageSize;

  static const int defaultPageSize = 50;

  TeamUsersFilter _filter;
  int _pageSize;
  int _pageIndex = 0;

  TeamUsersFilter get filter => _filter;
  int get pageSize => _pageSize;
  int get pageIndex => _pageIndex;

  void setFilter(TeamUsersFilter next) {
    if (identical(next, _filter)) return;
    _filter = next;
    _pageIndex = 0; // reset pagination on filter change
    notifyListeners();
  }

  void clearFilter() {
    setFilter(const TeamUsersFilter());
  }

  void setStatus(String? status) {
    setFilter(_filter.copyWith(statusFilter: status));
  }

  void setRole(String? roleKey) {
    setFilter(_filter.copyWith(roleFilter: roleKey));
  }

  void setLocation(String? locationId) {
    setFilter(_filter.copyWith(locationFilter: locationId));
  }

  void setMfaEnrolled(bool? value) {
    setFilter(_filter.copyWith(mfaEnrolledFilter: value));
  }

  void setSearchQuery(String query) {
    setFilter(_filter.copyWith(searchQuery: query));
  }

  void nextPage() {
    _pageIndex += 1;
    notifyListeners();
  }

  void previousPage() {
    if (_pageIndex == 0) return;
    _pageIndex -= 1;
    notifyListeners();
  }

  void setPageSize(int size) {
    if (size <= 0) {
      throw ArgumentError.value(size, 'size', 'must be > 0');
    }
    _pageSize = size;
    _pageIndex = 0;
    notifyListeners();
  }
}
