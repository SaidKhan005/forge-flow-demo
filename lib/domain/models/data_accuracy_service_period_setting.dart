/// Hardening Wave B1 — keyed Data Accuracy setting per service period.
///
/// Authority:
///   * docs/contracts/data_accuracy_settings_contract.md
///     "Business timing compatibility amendment (2026-05-06)" + "Schema"
///     section. Mirrors `public.data_accuracy_service_period_settings`.
///   * docs/contracts/integration_spine_architecture_contract.md
///     (covers-source resolution at the aggregator layer keys on a
///     stable service_period_key, not display label).
///
/// Replaces the hardcoded `covers_source_lunch` / `covers_source_dinner`
/// / `covers_source_late_night` columns on `data_accuracy_settings`
/// with a row keyed by `service_period_key` so a 4th or custom service
/// period (e.g., `breakfast`, `brunch`) can be operator-configured
/// without schema churn.
///
/// This file pairs with `service_period_settings_repository.dart`. The
/// covers-source enum extends the legacy 3-way model with a 4th
/// `reservationPlusWalkin` value for the operator walk-in surface
/// follow-up; the wage-source enum carries the 4-way internal class
/// the contract's "Wage source resolution" section names.
library;

import 'data_accuracy_settings.dart';

/// Operator-controlled covers-source preference per service period.
enum ServicePeriodCoversSource {
  vendor,
  forecast,
  manual,
  reservationPlusWalkin,
}

extension ServicePeriodCoversSourceWire on ServicePeriodCoversSource {
  /// Wire encoding matches the SQL CHECK constraint values.
  String get wire {
    switch (this) {
      case ServicePeriodCoversSource.vendor:
        return 'vendor';
      case ServicePeriodCoversSource.forecast:
        return 'forecast';
      case ServicePeriodCoversSource.manual:
        return 'manual';
      case ServicePeriodCoversSource.reservationPlusWalkin:
        return 'reservation_plus_walkin';
    }
  }

  static ServicePeriodCoversSource fromWire(String value) {
    switch (value) {
      case 'vendor':
        return ServicePeriodCoversSource.vendor;
      case 'forecast':
        return ServicePeriodCoversSource.forecast;
      case 'manual':
        return ServicePeriodCoversSource.manual;
      case 'reservation_plus_walkin':
        return ServicePeriodCoversSource.reservationPlusWalkin;
      default:
        throw ArgumentError.value(
          value,
          'covers_source',
          'must be one of vendor / forecast / manual / '
              'reservation_plus_walkin',
        );
    }
  }
}

/// Operator-controlled wage-source preference per service period.
/// Carries the 4-way internal class from the data accuracy contract.
enum ServicePeriodWageSource {
  vendorPerEmployee,
  vendorPerPosition,
  targetSubstitution,
  manualMix,
}

extension ServicePeriodWageSourceWire on ServicePeriodWageSource {
  String get wire {
    switch (this) {
      case ServicePeriodWageSource.vendorPerEmployee:
        return 'vendor_per_employee';
      case ServicePeriodWageSource.vendorPerPosition:
        return 'vendor_per_position';
      case ServicePeriodWageSource.targetSubstitution:
        return 'target_substitution';
      case ServicePeriodWageSource.manualMix:
        return 'manual_mix';
    }
  }

  static ServicePeriodWageSource fromWire(String value) {
    switch (value) {
      case 'vendor_per_employee':
        return ServicePeriodWageSource.vendorPerEmployee;
      case 'vendor_per_position':
        return ServicePeriodWageSource.vendorPerPosition;
      case 'target_substitution':
        return ServicePeriodWageSource.targetSubstitution;
      case 'manual_mix':
        return ServicePeriodWageSource.manualMix;
      default:
        throw ArgumentError.value(
          value,
          'wage_source',
          'must be one of vendor_per_employee / vendor_per_position / '
              'target_substitution / manual_mix',
        );
    }
  }
}

class DataAccuracyServicePeriodSetting {
  DataAccuracyServicePeriodSetting({
    required this.id,
    required this.operatorId,
    required this.locationId,
    required this.servicePeriodKey,
    required this.coversSource,
    required this.wageSource,
    required this.effectiveAtBusinessDate,
    required this.createdAt,
    required this.updatedAt,
    this.coversSourceSource,
    this.updatedBy,
  });

  final String id;
  final String operatorId;
  final String locationId;
  final String servicePeriodKey;
  final ServicePeriodCoversSource coversSource;
  final ServicePeriodWageSource wageSource;
  final DataAccuracySettingSource? coversSourceSource;

  /// ISO `YYYY-MM-DD` business-local date the row becomes effective.
  /// Repository lookup picks the most recent row at-or-before the
  /// supplied closed-shift business date.
  final String effectiveAtBusinessDate;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String? updatedBy;

  /// Project from a row produced by the PostgresExecutor (UUIDs cast
  /// to text in SELECT, business_date cast to text).
  factory DataAccuracyServicePeriodSetting.fromRow(Map<String, Object?> row) {
    final id = row['id'];
    final operatorId = row['operator_id'];
    final locationId = row['location_id'];
    final servicePeriodKey = row['service_period_key'];
    final coversSource = row['covers_source'];
    final wageSource = row['wage_source'];
    final effectiveDateRaw = row['effective_at_business_date'];
    final createdAt = row['created_at'];
    final updatedAt = row['updated_at'];

    if (id is! String ||
        operatorId is! String ||
        locationId is! String ||
        servicePeriodKey is! String ||
        coversSource is! String ||
        wageSource is! String ||
        createdAt is! DateTime ||
        updatedAt is! DateTime) {
      throw StateError(
        'data_accuracy_service_period_settings row malformed: '
        'missing required fields',
      );
    }

    final effectiveDate = _coerceIsoDate(effectiveDateRaw);
    if (effectiveDate == null) {
      throw StateError(
        'data_accuracy_service_period_settings row malformed: '
        'effective_at_business_date is required',
      );
    }
    final updatedBy = row['updated_by'];

    return DataAccuracyServicePeriodSetting(
      id: id,
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: ServicePeriodCoversSourceWire.fromWire(coversSource),
      wageSource: ServicePeriodWageSourceWire.fromWire(wageSource),
      coversSourceSource: DataAccuracySettingSource.fromMap(
        row['covers_source_source'],
      ),
      effectiveAtBusinessDate: effectiveDate,
      createdAt: createdAt,
      updatedAt: updatedAt,
      updatedBy: updatedBy is String && updatedBy.isNotEmpty ? updatedBy : null,
    );
  }

  DataAccuracyServicePeriodSetting copyWith({
    DataAccuracySettingSource? coversSourceSource,
  }) {
    return DataAccuracyServicePeriodSetting(
      id: id,
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      coversSourceSource: coversSourceSource ?? this.coversSourceSource,
      effectiveAtBusinessDate: effectiveAtBusinessDate,
      createdAt: createdAt,
      updatedAt: updatedAt,
      updatedBy: updatedBy,
    );
  }

  static String? _coerceIsoDate(Object? raw) {
    if (raw == null) return null;
    if (raw is String) {
      if (raw.isEmpty) return null;
      return raw.length >= 10 ? raw.substring(0, 10) : raw;
    }
    if (raw is DateTime) {
      final utc = raw.toUtc();
      final y = utc.year.toString().padLeft(4, '0');
      final m = utc.month.toString().padLeft(2, '0');
      final d = utc.day.toString().padLeft(2, '0');
      return '$y-$m-$d';
    }
    return null;
  }
}
