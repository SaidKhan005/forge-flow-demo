// Phase 9.5 - Risk-signal resolver.
//
// Pure logic — given the previous-login geo + the current login geo
// + an optional country allow-list, decide whether the request is
// suspicious enough to:
//
//   * pass through (allow);
//   * require step-up auth (re-prompt password / MFA);
//   * trigger a soft block (refuse the login attempt for this IP +
//     account combo until a human reviews).
//
// IP reputation enrichment in 9.5 is geo / ASN / impossible-travel
// only. Paid VPN/Tor reputation is parked per the decision lock.
//
// "Impossible travel" is computed as: distance between the two
// geo coords / (time between them) > [maxFeasibleSpeedKmh]. The
// distance uses a haversine approximation (good enough for the
// granularity GeoIP provides — country-level is fine, city-level
// is bonus). Default speed cap is 1000 km/h (commercial jet
// cruising speed) so a reasonable hop between connected countries
// inside the same calendar day passes.

import 'dart:math';

class GeoLogin {
  const GeoLogin({
    required this.at,
    required this.latitude,
    required this.longitude,
    this.country,
    this.asn,
  });

  final DateTime at;
  final double latitude;
  final double longitude;
  final String? country;
  final String? asn;
}

enum RiskDecision {
  /// No risk signals tripped — proceed with the normal login flow.
  allow,

  /// Step-up auth required (re-prompt password or MFA on next
  /// request). The proxy emits an `auth.suspicious_login` event and
  /// returns the step-up requirement to the client.
  requireStepUp,

  /// Soft block: refuse the login until reviewed. Used when the
  /// signals are strongly inconsistent (impossible travel + ASN
  /// jump + denied country).
  softBlock,
}

class RiskSignalResolution {
  const RiskSignalResolution({
    required this.decision,
    required this.reasons,
  });

  final RiskDecision decision;
  final List<String> reasons;
}

class RiskSignalResolver {
  RiskSignalResolver({
    this.maxFeasibleSpeedKmh = 1000,
    this.deniedCountries = const <String>{},
  });

  /// Speed cap above which two logins are considered impossible-travel.
  /// 1000 km/h covers commercial jet cruising; raise for test scenarios
  /// that warp the clock.
  final double maxFeasibleSpeedKmh;

  /// ISO 3166-1 alpha-2 country codes that should soft-block on
  /// arrival. Empty by default; operators may opt in via admin UX
  /// (Phase 9.9).
  final Set<String> deniedCountries;

  RiskSignalResolution evaluate({
    required GeoLogin? previous,
    required GeoLogin current,
  }) {
    final reasons = <String>[];
    final tripped = <_RiskSignal>{};

    final country = current.country?.toUpperCase();
    if (country != null && deniedCountries.contains(country)) {
      tripped.add(_RiskSignal.deniedCountry);
      reasons.add('current geo country is on the deny list');
    }

    if (previous != null) {
      if ((previous.country ?? '').toUpperCase() !=
              (current.country ?? '').toUpperCase() &&
          previous.country != null &&
          current.country != null) {
        tripped.add(_RiskSignal.countryChange);
        reasons.add('country changed since previous login');
      }
      if (previous.asn != null &&
          current.asn != null &&
          previous.asn != current.asn) {
        tripped.add(_RiskSignal.asnChange);
        reasons.add('ASN changed since previous login');
      }
      final speed = _impossibleTravelSpeedKmh(previous, current);
      if (speed != null && speed > maxFeasibleSpeedKmh) {
        tripped.add(_RiskSignal.impossibleTravel);
        reasons.add(
          'impossible travel: ${speed.toStringAsFixed(0)} km/h '
          '(cap ${maxFeasibleSpeedKmh.toStringAsFixed(0)})',
        );
      }
    }

    final decision = _decide(tripped);
    return RiskSignalResolution(decision: decision, reasons: reasons);
  }

  RiskDecision _decide(Set<_RiskSignal> tripped) {
    if (tripped.isEmpty) return RiskDecision.allow;
    if (tripped.contains(_RiskSignal.deniedCountry)) {
      return RiskDecision.softBlock;
    }
    // Multiple weak signals stacking → soft block.
    if (tripped.length >= 3) return RiskDecision.softBlock;
    if (tripped.contains(_RiskSignal.impossibleTravel)) {
      return RiskDecision.requireStepUp;
    }
    if (tripped.contains(_RiskSignal.countryChange) ||
        tripped.contains(_RiskSignal.asnChange)) {
      return RiskDecision.requireStepUp;
    }
    return RiskDecision.allow;
  }

  /// Returns the implied travel speed (km/h) between [previous] and
  /// [current], or null when the timestamps are out of order
  /// (clocks skewed) or identical.
  static double? _impossibleTravelSpeedKmh(GeoLogin previous, GeoLogin current) {
    final hours = current.at.difference(previous.at).inSeconds / 3600.0;
    if (hours <= 0) return null;
    final distanceKm = _haversineKm(
      previous.latitude,
      previous.longitude,
      current.latitude,
      current.longitude,
    );
    if (distanceKm <= 0) return 0;
    return distanceKm / hours;
  }

  static double _haversineKm(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const earthRadiusKm = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a =
        pow(sin(dLat / 2), 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            pow(sin(dLon / 2), 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  static double _degToRad(double deg) => deg * pi / 180.0;
}

enum _RiskSignal {
  deniedCountry,
  countryChange,
  asnChange,
  impossibleTravel,
}
