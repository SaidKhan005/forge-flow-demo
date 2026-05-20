// Operator Web demo write gateways.
//
// README demo mode is the visual audit standard: every operator-facing edit
// layer should be reachable without touching Firebase, Postgres, vendors, or
// production accounts. These gateways keep writes in memory for the current
// browser session only.

import 'dart:convert';
import 'dart:typed_data';

import 'business_logo_upload_gateway.dart';
import 'web_account_gateway.dart';
import 'web_business_timing_gateway.dart';

class DemoBusinessLogoUploadGateway implements BusinessLogoUploadGateway {
  @override
  Future<BusinessLogoUploadOutcome> uploadLogo({
    required Uint8List pngBytes,
    required String filename,
  }) async {
    final trimmedName = filename.trim();
    if (trimmedName.isEmpty) {
      throw const BusinessLogoValidationException(
        code: 'invalid_filename',
        message: 'Pick a file before uploading.',
      );
    }
    if (!trimmedName.toLowerCase().endsWith('.png')) {
      throw const BusinessLogoValidationException(
        code: 'invalid_filename',
        message:
            'Only PNG files are accepted. Rename or convert your '
            'image and try again.',
      );
    }
    if (pngBytes.length > kOperatorWebBusinessLogoMaxBytes) {
      throw BusinessLogoValidationException(
        code: 'payload_too_large',
        message:
            'That file is larger than 600 KB. Pick a smaller logo or '
            'compress it first. (Yours: ${pngBytes.length} bytes.)',
      );
    }
    if (!_hasPngMagic(pngBytes)) {
      throw const BusinessLogoValidationException(
        code: 'invalid_png_magic',
        message:
            'That file is not a valid PNG. Save it again from your '
            'image editor and try once more.',
      );
    }
    return BusinessLogoUploadOutcome(
      logoUrl: 'data:image/png;base64,${base64Encode(pngBytes)}',
      sizeBytes: pngBytes.length,
    );
  }

  static bool _hasPngMagic(Uint8List bytes) {
    if (bytes.length < kOperatorWebPngMagic.length) return false;
    for (var i = 0; i < kOperatorWebPngMagic.length; i++) {
      if (bytes[i] != kOperatorWebPngMagic[i]) return false;
    }
    return true;
  }
}

class DemoOperatorWebBusinessTimingWriteGateway
    implements WebBusinessTimingGateway {
  DemoOperatorWebBusinessTimingWriteGateway({
    this.operatorId = 'demo-operator',
    this.locationId = 'demo-location',
    this.locationTimezone = 'America/Toronto',
  }) {
    final now = DateTime.now().toUtc();
    _profiles['demo-timing-operator'] = BusinessTimingProfileWriteResult(
      profileId: 'demo-timing-operator',
      versionId: 'demo-timing-operator',
      scopeKind: 'operator',
      scopeId: operatorId,
      effectiveAtBusinessDate: _todayIso(now),
      ianaTimezone: locationTimezone,
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: _demoServicePeriods(),
      createdAt: now,
      updatedAt: now,
    );
  }

  final String operatorId;
  final String locationId;
  final String locationTimezone;
  int _nextId = 1;
  final Map<String, BusinessTimingProfileWriteResult> _profiles =
      <String, BusinessTimingProfileWriteResult>{};

  @override
  Future<List<BusinessTimingProfileWriteResult>> listProfiles() async =>
      List<BusinessTimingProfileWriteResult>.unmodifiable(_profiles.values);

  @override
  Future<BusinessTimingResolutionResult> resolveForLocation({
    required String locationId,
    String? businessDate,
  }) async {
    final date = businessDate?.trim().isNotEmpty == true
        ? businessDate!.trim()
        : _todayIso(DateTime.now().toUtc());
    final ordered = _profiles.values.toList()
      ..sort(
        (a, b) => _scopeRank(a.scopeKind).compareTo(_scopeRank(b.scopeKind)),
      );
    return BusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: date,
      ianaTimezone: locationTimezone,
      candidates: <BusinessTimingResolutionCandidate>[
        for (final profile in ordered)
          if (profile.scopeKind == 'operator' ||
              profile.scopeId == locationId ||
              profile.scopeKind == 'org_unit')
            BusinessTimingResolutionCandidate(
              profileId: profile.profileId,
              scopeType: profile.scopeKind,
              scopeId: profile.scopeId,
              scopeLabel: _scopeLabel(profile.scopeKind),
              scopeDepthRank: _scopeRank(profile.scopeKind),
              ianaTimezone: profile.ianaTimezone,
              effectiveAtBusinessDate: profile.effectiveAtBusinessDate,
              weekStartDay: profile.weekStartDay,
              businessDayStartLocal: profile.businessDayStartLocal,
              servicePeriods: profile.servicePeriods,
            ),
      ],
    );
  }

  @override
  Future<BusinessTimingProfileWriteResult> createProfile(
    BusinessTimingProfileCreate request,
  ) async {
    final now = DateTime.now().toUtc();
    final id = 'demo-timing-${_nextId++}';
    final result = BusinessTimingProfileWriteResult(
      profileId: id,
      versionId: id,
      scopeKind: request.scopeKind,
      scopeId: request.scopeId,
      effectiveAtBusinessDate: request.effectiveAtBusinessDate,
      ianaTimezone: request.ianaTimezone,
      weekStartDay: request.weekStartDay,
      businessDayStartLocal: request.businessDayStartLocal,
      servicePeriods: request.servicePeriods.map(_toServicePeriod).toList(),
      createdAt: now,
      updatedAt: now,
    );
    _profiles[id] = result;
    return result;
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateProfile({
    required String profileId,
    required BusinessTimingProfilePatch patch,
  }) async {
    final current = _profiles[profileId] ?? _profiles.values.first;
    final now = DateTime.now().toUtc();
    final updated = BusinessTimingProfileWriteResult(
      profileId: current.profileId,
      versionId: current.versionId,
      scopeKind: patch.scopeKind ?? current.scopeKind,
      scopeId: patch.scopeId ?? current.scopeId,
      effectiveAtBusinessDate:
          patch.effectiveAtBusinessDate ?? current.effectiveAtBusinessDate,
      ianaTimezone: patch.ianaTimezone ?? current.ianaTimezone,
      weekStartDay: patch.weekStartDay ?? current.weekStartDay,
      businessDayStartLocal:
          patch.businessDayStartLocal ?? current.businessDayStartLocal,
      servicePeriods:
          patch.servicePeriods?.map(_toServicePeriod).toList() ??
          current.servicePeriods,
      createdAt: current.createdAt,
      updatedAt: now,
    );
    _profiles[updated.profileId] = updated;
    return updated;
  }

  @override
  Future<BusinessTimingProfileWriteResult> addServicePeriod({
    required String profileId,
    required ServicePeriodCreate period,
  }) async {
    final current = _profiles[profileId] ?? _profiles.values.first;
    return updateProfile(
      profileId: current.profileId,
      patch: BusinessTimingProfilePatch(
        servicePeriods: <ServicePeriodCreate>[
          for (final existing in current.servicePeriods)
            ServicePeriodCreate(
              key: existing.key,
              label: existing.label,
              startLocal: existing.startLocal,
              endLocal: existing.endLocal,
              applicableDays: existing.applicableDays,
              shortLabel: existing.shortLabel,
              sortOrder: existing.sortOrder,
            ),
          period,
        ],
      ),
    );
  }

  @override
  Future<BusinessTimingProfileWriteResult> updateServicePeriod({
    required String profileId,
    required String key,
    required ServicePeriodPatch patch,
  }) async {
    final current = _profiles[profileId] ?? _profiles.values.first;
    return updateProfile(
      profileId: current.profileId,
      patch: BusinessTimingProfilePatch(
        servicePeriods: <ServicePeriodCreate>[
          for (final existing in current.servicePeriods)
            ServicePeriodCreate(
              key: existing.key,
              label: existing.key == key
                  ? patch.label ?? existing.label
                  : existing.label,
              startLocal: existing.key == key
                  ? patch.startLocal ?? existing.startLocal
                  : existing.startLocal,
              endLocal: existing.key == key
                  ? patch.endLocal ?? existing.endLocal
                  : existing.endLocal,
              applicableDays: existing.key == key
                  ? patch.applicableDays ?? existing.applicableDays
                  : existing.applicableDays,
              shortLabel: existing.key == key
                  ? patch.shortLabel ?? existing.shortLabel
                  : existing.shortLabel,
              sortOrder: existing.key == key
                  ? patch.sortOrder ?? existing.sortOrder
                  : existing.sortOrder,
            ),
        ],
      ),
    );
  }

  static List<ServicePeriod> _demoServicePeriods() => const <ServicePeriod>[
    ServicePeriod(
      key: 'lunch',
      label: 'Lunch',
      startLocal: '11:00',
      endLocal: '15:00',
      rollsPastMidnight: false,
      shortLabel: 'L',
      sortOrder: 1,
    ),
    ServicePeriod(
      key: 'dinner',
      label: 'Dinner',
      startLocal: '17:00',
      endLocal: '22:00',
      rollsPastMidnight: false,
      shortLabel: 'D',
      sortOrder: 2,
    ),
    ServicePeriod(
      key: 'late_night',
      label: 'Late night',
      startLocal: '22:00',
      endLocal: '01:00',
      rollsPastMidnight: true,
      shortLabel: 'LN',
      sortOrder: 3,
    ),
  ];

  static ServicePeriod _toServicePeriod(ServicePeriodCreate period) =>
      ServicePeriod(
        key: period.key,
        label: period.label,
        startLocal: period.startLocal,
        endLocal: period.endLocal,
        rollsPastMidnight: _rollsPastMidnight(
          period.startLocal,
          period.endLocal,
        ),
        applicableDays: period.applicableDays,
        shortLabel: period.shortLabel,
        sortOrder: period.sortOrder,
      );

  static bool _rollsPastMidnight(String start, String end) =>
      end.compareTo(start) <= 0;

  static int _scopeRank(String scopeKind) => switch (scopeKind) {
    'operator' => 0,
    'org_unit' => 1,
    'location' => 2,
    _ => 3,
  };

  static String _scopeLabel(String scopeKind) => switch (scopeKind) {
    'operator' => 'Demo Restaurant Group',
    'org_unit' => 'Regional settings',
    'location' => 'Demo Main Street',
    _ => 'Demo scope',
  };

  static String _todayIso(DateTime now) =>
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

class DemoOperatorWebAccountGateway
    implements WebAccountGateway, WebAccountSessionGateway {
  DemoOperatorWebAccountGateway({
    this.operatorId = 'demo-operator',
    this.locationId = 'demo-location',
    String businessName = 'Demo Restaurant Group',
    String? logoUrl,
    String currencyCode = 'CAD',
    String localeTag = 'en-CA',
    String weekStartDay = 'monday',
    int rolloverHour = 4,
    String ianaTimezone = 'America/Toronto',
  }) : _identity = AccountIdentity(
         operatorId: operatorId,
         businessName: businessName,
         logoUrl: logoUrl,
         currencyCode: currencyCode,
         localeTag: localeTag,
         weekStartDay: weekStartDay,
         rolloverHour: rolloverHour,
         updatedAt: DateTime.now().toUtc(),
       ),
       _timezone = ianaTimezone;

  final String operatorId;
  final String locationId;
  AccountIdentity _identity;
  String _timezone;
  LocationAccountOverridesFieldSet _override =
      const LocationAccountOverridesFieldSet();

  @override
  Future<AccountIdentity> getAccount() async => _identity;

  @override
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch) async {
    _identity = AccountIdentity(
      operatorId: _identity.operatorId,
      businessName: patch.businessName ?? _identity.businessName,
      logoUrl: patch.clearLogo ? null : patch.logoUrl ?? _identity.logoUrl,
      currencyCode: patch.currencyCode ?? _identity.currencyCode,
      localeTag: patch.localeTag ?? _identity.localeTag,
      weekStartDay: patch.weekStartDay ?? _identity.weekStartDay,
      rolloverHour: patch.rolloverHour ?? _identity.rolloverHour,
      updatedAt: DateTime.now().toUtc(),
    );
    return _identity;
  }

  @override
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  ) async {
    _timezone = patch.ianaTimezone.trim();
    return AccountLocationTimezone(
      operatorId: operatorId,
      locationId: locationId,
      ianaTimezone: _timezone,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  ) async {
    return SelfProfilePatchResult(
      userId: 'demo-operator-owner',
      email: patch.email ?? 'owner@demo.forgeflow.test',
      displayName: patch.displayName ?? 'Demo Operator Owner',
      emailChanged: patch.email != null,
      displayNameChanged: patch.displayName != null,
    );
  }

  @override
  Future<LocationAccountOverridesEnvelope> getLocationAccountOverrides({
    required String locationId,
  }) async => _envelope(locationId);

  @override
  Future<LocationAccountOverridesEnvelope> patchLocationAccountOverrides({
    required String locationId,
    required LocationAccountOverridesPatchPayload patch,
  }) async {
    _override = LocationAccountOverridesFieldSet(
      ianaTimezone: patch.clearIanaTimezone
          ? null
          : patch.ianaTimezone ?? _override.ianaTimezone,
      localeCode: patch.clearLocaleCode
          ? null
          : patch.localeCode ?? _override.localeCode,
      currencyCode: patch.clearCurrencyCode
          ? null
          : patch.currencyCode ?? _override.currencyCode,
      businessDayRolloverHour: patch.clearBusinessDayRolloverHour
          ? null
          : patch.businessDayRolloverHour ?? _override.businessDayRolloverHour,
      contactEmail: patch.clearContactEmail
          ? null
          : patch.contactEmail ?? _override.contactEmail,
      contactPhone: patch.clearContactPhone
          ? null
          : patch.contactPhone ?? _override.contactPhone,
    );
    return _envelope(locationId);
  }

  @override
  Future<AccountActiveSessionsListed> listActiveSessions() async =>
      AccountActiveSessionsListed(
        sessions: <AccountActiveSessionEntry>[
          AccountActiveSessionEntry(
            sessionId: 'demo-session-current',
            lastActiveAt: DateTime.now().toUtc(),
            createdAt: DateTime.now().toUtc().subtract(
              const Duration(hours: 2),
            ),
            deviceLabel: 'Chrome on Windows',
            geoCity: 'Toronto',
            geoCountry: 'Canada',
          ),
        ],
      );

  @override
  Future<AccountSessionSignOutOthersResult> signOutOtherSessions({
    required Iterable<String> sessionIds,
  }) async =>
      AccountSessionSignOutOthersResult(revokedCount: sessionIds.length);

  LocationAccountOverridesEnvelope _envelope(String locationId) {
    final businessDefault = LocationAccountOverridesFieldSet(
      ianaTimezone: _timezone,
      localeCode: _identity.localeTag,
      currencyCode: _identity.currencyCode,
      businessDayRolloverHour: _identity.rolloverHour,
    );
    final effective = LocationAccountOverridesFieldSet(
      ianaTimezone: _override.ianaTimezone ?? businessDefault.ianaTimezone,
      localeCode: _override.localeCode ?? businessDefault.localeCode,
      currencyCode: _override.currencyCode ?? businessDefault.currencyCode,
      businessDayRolloverHour:
          _override.businessDayRolloverHour ??
          businessDefault.businessDayRolloverHour,
      contactEmail: _override.contactEmail,
      contactPhone: _override.contactPhone,
    );
    return LocationAccountOverridesEnvelope(
      operatorId: operatorId,
      locationId: locationId,
      effective: effective,
      override: _override,
      businessDefault: businessDefault,
      updatedAt: DateTime.now().toUtc(),
    );
  }
}
