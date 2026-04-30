// Shared IANA timezone catalog helpers.
//
// The admin client and advisor proxy both validate operator/location timezone
// input. Keeping the catalog here prevents the web UI from accepting a value
// the server later rejects, and prevents production from storing shape-only
// names such as `Mars/Olympus`.

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _initialized = false;
List<String>? _names;

const Set<String> _bareZones = <String>{'UTC', 'GMT'};

void _ensureCatalog() {
  if (_initialized) return;
  tzdata.initializeTimeZones();
  _initialized = true;
}

bool isValidIanaTimezoneName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.contains(RegExp(r'\s'))) return false;
  _ensureCatalog();
  return _bareZones.contains(trimmed) ||
      tz.timeZoneDatabase.locations.containsKey(trimmed);
}

List<String> ianaTimezoneNames() {
  final cached = _names;
  if (cached != null) return cached;
  _ensureCatalog();
  final names = <String>{
    ..._bareZones,
    ...tz.timeZoneDatabase.locations.keys,
  }.toList()..sort();
  _names = List<String>.unmodifiable(names);
  return _names!;
}
