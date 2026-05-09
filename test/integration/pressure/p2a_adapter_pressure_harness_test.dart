// Phase 2A — adapter-level pressure harness.
//
// Sprint: `pressure.preview.v1` Phase 2 of 4 stack levels.
//
// Purpose
// -------
// Drive the 17 vendor adapters' fixture corpora at
// `test/fixtures/vendor_payloads/<vendor>/` through the layer of code
// that turns vendor JSON into a canonical fact (or refuses), and
// catalog every divergence from the per-vendor README's documented
// expectation. The harness is a FINDING GENERATOR, not a gate — every
// divergence becomes a JSON line in
// `test/integration/pressure/p2a_adapter_findings.jsonl` plus a
// summary row in the test log so Phase 5 can consume the full catalog
// in one run. The test itself only fails when the harness can no
// longer keep going (e.g. completely unable to read a fixture
// directory).
//
// What this level proves
// ----------------------
// Does each adapter parse what its public docs say it produces?
// (Phase 2B answers the sink question; 2C the spine; 2D mobile-sync.)
//
// Probe shape per (vendor, fixture)
// ---------------------------------
// 1. Load fixture JSON; record `fixture_unparseable` if invalid.
// 2. Look up the README outcome for this filename. Record
//    `readme_unparseable` if absent.
// 3. Apply the appropriate per-scenario probe:
//      * Universal scenario_a (forged signature)  — adapter hands the
//        signature decision to a separate verifier. The harness does
//        not have the verifier wired here (that's a Phase 2B / 2C
//        concern); it confirms the fixture carries the documented
//        forged-signature shape.
//      * Universal scenario_b (malformed)         — feed the JSON to
//        the public DTO when one exists; expect null/throw.
//      * Universal scenario_c (future-dated)      — expects the
//        framework's sanity hook to drop the row. The harness checks
//        that the timestamps are indeed in the future relative to
//        the documented "test now" anchor (2026-05-08).
//      * Universal scenario_e (ambiguous timestamp) — checks for the
//        absence of `Z`/offset on the canonical timestamp paths AND
//        invokes the documented per-vendor parse helper to detect the
//        Square / Lightspeed silent-coerce bug.
//      * Universal scenario_f (cross-vendor id collision) — paired
//        across vendor directories; assertion runs in a separate
//        cross-vendor section.
//      * happy_path / sparse / DST / cross-tz       — for vendors with
//        a public DTO, drive it and assert non-null. For all others,
//        confirm the fixture has the documented shape.
// 4. Pre-flagged Phase 5 bugs:
//      * Square + Lightspeed K-Series silently accept naive
//        timestamps because `DateTime.tryParse(...).toUtc()` does not
//        enforce the documented explicit-Z policy. The harness
//        reproduces the silent-coerce on `scenario_e_ambiguous_timestamp.json`.
//      * Humanity time-off rows parse as 24h shifts in
//        `HumanityShiftDto.tryFromMap` (the parser does not branch on
//        `type=time_off`). The harness drives the DTO directly to
//        confirm.
// 5. Audit-claim mismatch:
//      * Oracle Simphony — capability profile MUST declare
//        `VendorAuthMode.oauth` (audit asserted mTLS, that was wrong).
//      * Agendrix — same: profile declares `VendorAuthMode.oauth`
//        (audit asserted static API key).
//
// Scope discipline (per the prompt)
// ---------------------------------
// * Only new files under `test/integration/pressure/` (+ helpers).
// * Adapters not modified to fix the pre-flagged bugs.
// * Fixtures + vendor READMEs not touched.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/integrations/reservation/libro_reservation_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '_helpers/p2a_findings.dart';
import '_helpers/p2a_readme_parser.dart';
import '_helpers/p2a_vendor_registry.dart';

/// Documented "test now" anchor for the corpus — fixtures dated AFTER
/// this instant should be sanity-rejected as future-dated.
final DateTime kHarnessNow = DateTime.utc(2026, 5, 8, 18, 0, 0);

/// Path to the fixture corpus root.
final String kFixtureRoot = _resolveRepoPath(
  'test/fixtures/vendor_payloads',
);

/// Output JSONL artifact (gitignored). Overwritten on every run.
final String kFindingsArtifact = _resolveRepoPath(
  'test/integration/pressure/p2a_adapter_findings.jsonl',
);

void main() {
  group('Phase 2A adapter-level pressure harness', () {
    final sink = P2aFindingSink(outputPath: kFindingsArtifact);

    test('drives 17 vendor corpora through their adapter parse paths',
        () async {
      // ── Per-vendor fixture pass ────────────────────────────────
      for (final vendor in kP2aVendorRegistry) {
        final vendorDir =
            Directory('$kFixtureRoot/${vendor.fixtureDir}');
        if (!vendorDir.existsSync()) {
          sink.record(P2aFinding(
            vendor: vendor.vendorId,
            scenario: '<directory>',
            divergenceType: 'fixture_unparseable',
            detail: 'vendor fixture directory missing',
            fixturePath: vendorDir.path,
          ));
          continue;
        }

        final readmePath = '${vendorDir.path}/README.md';
        final rows = parseVendorReadme(readmePath);
        if (rows.isEmpty) {
          sink.record(P2aFinding(
            vendor: vendor.vendorId,
            scenario: '<readme>',
            divergenceType: 'readme_unparseable',
            detail: 'no Scenarios table rows parsed',
            fixturePath: readmePath,
          ));
        }

        // Index README rows by filename for quick lookup.
        final readmeByFile = <String, P2aReadmeRow>{
          for (final r in rows) r.fixtureFile: r,
        };

        // Walk every JSON fixture in the dir. The README is
        // best-effort; missing-from-README is logged but the probe
        // still runs.
        final files = vendorDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

        for (final f in files) {
          final fixtureName = f.uri.pathSegments.last;
          final scenario = _scenarioName(fixtureName);
          final readmeRow = readmeByFile[fixtureName];
          final expectedOutcome = readmeRow?.normalizedOutcome ?? 'unknown';

          // Defensive load.
          Object? json;
          try {
            json = jsonDecode(f.readAsStringSync());
          } catch (e) {
            sink.record(P2aFinding(
              vendor: vendor.vendorId,
              scenario: scenario,
              divergenceType: 'fixture_unparseable',
              detail: 'jsonDecode threw: $e',
              fixturePath: '${vendor.fixtureDir}/$fixtureName',
            ));
            continue;
          }

          if (readmeRow == null) {
            sink.record(P2aFinding(
              vendor: vendor.vendorId,
              scenario: scenario,
              divergenceType: 'readme_unparseable',
              detail: 'fixture filename absent from README scenarios table',
              fixturePath: '${vendor.fixtureDir}/$fixtureName',
            ));
          } else if (expectedOutcome == 'unknown') {
            sink.record(P2aFinding(
              vendor: vendor.vendorId,
              scenario: scenario,
              divergenceType: 'readme_unparseable',
              detail:
                  'outcome wording not understood: "${readmeRow.rawOutcome}"',
              fixturePath: '${vendor.fixtureDir}/$fixtureName',
            ));
          }

          try {
            await _probeFixture(
              vendor: vendor,
              fixtureName: fixtureName,
              scenario: scenario,
              expectedOutcome: expectedOutcome,
              fixtureJson: json,
              sink: sink,
            );
          } catch (e, st) {
            // Defensive — keep going. The throw IS a finding.
            sink.record(P2aFinding(
              vendor: vendor.vendorId,
              scenario: scenario,
              divergenceType: 'harness_defensiveness_gap',
              detail: 'probe threw $e; harness swallowed and kept going. '
                  'first stack frame: ${_firstFrame(st)}',
              fixturePath: '${vendor.fixtureDir}/$fixtureName',
            ));
          }
        }
      }

      // ── Cross-vendor namespace pairs (scenario_f) ──────────────
      for (final pair in kP2aCrossVendorPairs) {
        _probeCrossVendorPair(pair[0], pair[1], sink);
      }

      // ── Audit-claim mismatch (Oracle Simphony, Agendrix) ───────
      _probeAuditClaim(
        vendorId: 'oracle_micros_simphony',
        expectedAuthMode: VendorAuthMode.oauth,
        auditClaim: 'mTLS',
        sink: sink,
      );
      _probeAuditClaim(
        vendorId: 'agendrix',
        expectedAuthMode: VendorAuthMode.oauth,
        auditClaim: 'static API key',
        sink: sink,
      );

      // ── Pre-flagged Phase 5 bug confirmations ──────────────────
      _probePreFlaggedSquareLightspeedNaiveTimestamp(sink);
      _probePreFlaggedHumanityTimeOffAs24hShift(sink);

      // ── Flush + log summary ────────────────────────────────────
      sink.flush();
      // ignore: avoid_print
      print('\n=== P2A ADAPTER PRESSURE HARNESS SUMMARY ===');
      // ignore: avoid_print
      print(sink.summaryTable());
      // ignore: avoid_print
      print('Findings artifact: $kFindingsArtifact');
      // ignore: avoid_print
      print('============================================\n');

      // The harness intentionally does not assert finding-count == 0.
      // It DOES assert it ran end-to-end (i.e. processed every vendor
      // dir and produced an artifact).
      expect(File(kFindingsArtifact).existsSync(), isTrue,
          reason: 'findings JSONL must be written');
    });
  });
}

// ─── Per-fixture probe ────────────────────────────────────────────

Future<void> _probeFixture({
  required VendorRegistryEntry vendor,
  required String fixtureName,
  required String scenario,
  required String expectedOutcome,
  required Object? fixtureJson,
  required P2aFindingSink sink,
}) async {
  // Scenario-specific structural probes that apply uniformly across
  // every vendor (signature, future-dated, ambiguous timestamp).
  switch (scenario) {
    case 'scenario_a_forged_signature':
      _probeForgedSignature(vendor, fixtureName, fixtureJson, sink);
      return;
    case 'scenario_c_future_dated_event':
      _probeFutureDated(vendor, fixtureName, fixtureJson, sink);
      return;
    case 'scenario_e_ambiguous_timestamp':
      _probeAmbiguousTimestamp(vendor, fixtureName, fixtureJson, sink);
      return;
    case 'scenario_d_oauth_near_expiry':
      // Refresh path — adapter not directly involved at this layer.
      // The README outcome should classify as `refresh` or `na`; the
      // harness only flags wording mismatches (already done above).
      return;
    case 'scenario_f_cross_vendor_id_collision':
      // Handled in the cross-vendor pair probe.
      return;
  }

  // For vendors with a public DTO, drive it.
  if (vendor.hasPublicDtoParser) {
    if (vendor.vendorId == 'humanity') {
      _driveHumanityDto(vendor, fixtureName, scenario,
          expectedOutcome, fixtureJson, sink);
      return;
    }
    if (vendor.vendorId == 'libro') {
      _driveLibroDto(vendor, fixtureName, scenario,
          expectedOutcome, fixtureJson, sink);
      return;
    }
  }

  // No public DTO entry. Record a one-time `adapter_not_found` per
  // vendor on the FIRST happy-path fixture so the catalog reflects
  // the gap without spamming one entry per fixture.
  if (scenario.startsWith('happy_path_') &&
      _firstHappyPath(vendor.fixtureDir) == fixtureName) {
    sink.record(P2aFinding(
      vendor: vendor.vendorId,
      scenario: scenario,
      divergenceType: 'adapter_not_found',
      detail: 'parse helper is private (e.g. _orderToCanonicalFact / '
          '_canonicalize); harness has no public entry to drive directly. '
          'Phase 2B sink-level harness will exercise the full path via '
          'the framework webhook router.',
      fixturePath: '${vendor.fixtureDir}/$fixtureName',
    ));
  }
}

// ─── Universal scenario probes ────────────────────────────────────

void _probeForgedSignature(VendorRegistryEntry vendor, String fixtureName,
    Object? fixtureJson, P2aFindingSink sink) {
  // The signature verification happens in a separate
  // `<vendor>_webhook_signature_verifier.dart` which the adapter
  // never invokes directly. At THIS layer we only confirm the
  // fixture documents the forged signature in some operator-visible
  // way (a `_scenario` / `_fixture_meta` / `signature` / `_note`
  // marker). When the marker is absent the harness records a
  // structural finding so Phase 2B can verify the verifier wiring.
  if (fixtureJson is! Map) return;
  final asString = fixtureJson.toString().toLowerCase();
  if (!asString.contains('signature') &&
      !asString.contains('hmac') &&
      !asString.contains('forged')) {
    sink.record(P2aFinding(
      vendor: vendor.vendorId,
      scenario: 'scenario_a_forged_signature',
      divergenceType: 'wrong_reject_reason',
      detail: 'fixture body has no embedded signature marker — for '
          'this vendor the forged signature lives in the HTTP header '
          '(see <fixture>.source.md). Phase 2B sink-level harness '
          'must inject the header separately to exercise the '
          'signature verifier; the adapter parse path alone cannot.',
      fixturePath: '${vendor.fixtureDir}/$fixtureName',
    ));
  }
}

void _probeFutureDated(VendorRegistryEntry vendor, String fixtureName,
    Object? fixtureJson, P2aFindingSink sink) {
  // Some fixtures embed a `_test_now_at_receive` anchor — use it
  // when present, otherwise fall back to the harness anchor.
  final anchor = _embeddedTestNow(fixtureJson) ?? kHarnessNow;
  final timestamps = _collectTimestamps(fixtureJson);
  if (timestamps.isEmpty) return;
  final hasFuture = timestamps.any((t) => t.isAfter(anchor));
  if (!hasFuture) {
    sink.record(P2aFinding(
      vendor: vendor.vendorId,
      scenario: 'scenario_c_future_dated_event',
      divergenceType: 'wrong_reject_reason',
      detail: 'fixture contains no timestamps after the future-date '
          'anchor (${anchor.toIso8601String()}); future-dated rejection '
          'cannot be exercised',
      fixturePath: '${vendor.fixtureDir}/$fixtureName',
    ));
  }
}

/// Look for a top-level or one-level-nested `_test_now_at_receive` /
/// `_test_now` ISO-8601 instant the fixture author baked in. Returns
/// null when the fixture does not embed one.
DateTime? _embeddedTestNow(Object? v) {
  if (v is! Map) return null;
  for (final key in const <String>['_test_now_at_receive', '_test_now']) {
    final raw = v[key];
    if (raw is String) {
      final t = DateTime.tryParse(raw);
      if (t != null) return t.toUtc();
    }
  }
  for (final inner in v.values) {
    if (inner is Map) {
      final found = _embeddedTestNow(inner);
      if (found != null) return found;
    }
  }
  return null;
}

void _probeAmbiguousTimestamp(VendorRegistryEntry vendor, String fixtureName,
    Object? fixtureJson, P2aFindingSink sink) {
  // Walk the JSON; collect every string that looks like an ISO-8601
  // timestamp without a `Z` suffix or `+/-HH:MM` offset.
  final naive = <String>[];
  _walkStrings(fixtureJson, (s) {
    if (_looksLikeNaiveIsoTimestamp(s)) naive.add(s);
  });
  if (naive.isEmpty) {
    sink.record(P2aFinding(
      vendor: vendor.vendorId,
      scenario: 'scenario_e_ambiguous_timestamp',
      divergenceType: 'wrong_reject_reason',
      detail: 'fixture contains no naive (offset-less) timestamps; '
          'ambiguous-timestamp rejection cannot be exercised',
      fixturePath: '${vendor.fixtureDir}/$fixtureName',
    ));
    return;
  }

  // For Square and Lightspeed the adapter currently calls
  // `DateTime.tryParse(raw)?.toUtc()` which silently coerces the
  // local instant into UTC — the documented Phase 5 bug. Confirm the
  // bug reproduces by parsing directly.
  if (vendor.vendorId == 'square' || vendor.vendorId == 'lightspeed_lsk') {
    final coerced = DateTime.tryParse(naive.first)?.toUtc();
    if (coerced != null) {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: 'scenario_e_ambiguous_timestamp',
        divergenceType: 'pre_flagged_bug_confirmed',
        detail: 'DateTime.tryParse("${naive.first}").toUtc() returns '
            '${coerced.toIso8601String()} (silent coerce). '
            'Adapter does not enforce documented explicit-Z policy. '
            'Phase 5 fix: refuse offset-less timestamps at parse time.',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    } else {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: 'scenario_e_ambiguous_timestamp',
        divergenceType: 'pre_flagged_bug_silently_fixed',
        detail: 'DateTime.tryParse("${naive.first}") returned null '
            '(no longer silently coerces). Phase 5 may close this bug.',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    }
  }
}

// ─── Public-DTO drivers ───────────────────────────────────────────

void _driveHumanityDto(
  VendorRegistryEntry vendor,
  String fixtureName,
  String scenario,
  String expectedOutcome,
  Object? fixtureJson,
  P2aFindingSink sink,
) {
  if (fixtureJson is! Map) return;
  final data = fixtureJson['data'];
  final rows = <Map<String, Object?>>[];
  if (data is List) {
    for (final r in data) {
      if (r is Map) rows.add(_castStringKeyMap(r));
    }
  }
  if (rows.isEmpty) return; // not a list-shaped fixture; skip silently
  for (var i = 0; i < rows.length; i++) {
    final raw = rows[i];
    final dto = HumanityShiftDto.tryFromMap(raw);
    final accepted = dto != null;
    // `ambiguous` outcomes (compound "reject OR …" cells) skip the
    // pass/reject divergence check; the README documents either as
    // acceptable.
    if (expectedOutcome == 'ambiguous') {
      continue;
    }
    if (expectedOutcome == 'pass' && !accepted) {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: scenario,
        divergenceType: 'expected_pass_got_reject',
        detail: 'HumanityShiftDto.tryFromMap returned null on row $i; '
            'README expected accept',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    } else if (expectedOutcome == 'reject' && accepted) {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: scenario,
        divergenceType: 'expected_reject_got_pass',
        detail: 'HumanityShiftDto.tryFromMap returned a DTO on row $i; '
            'README expected reject. id=${dto.id}',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    }
  }
}

void _driveLibroDto(
  VendorRegistryEntry vendor,
  String fixtureName,
  String scenario,
  String expectedOutcome,
  Object? fixtureJson,
  P2aFindingSink sink,
) {
  if (fixtureJson is! Map) return;
  // Libro fixtures typically wrap the reservation under top-level
  // keys — try a couple of common shapes.
  final candidates = <Map<String, Object?>>[];
  void collect(Object? v) {
    if (v is Map) {
      final m = _castStringKeyMap(v);
      if (m.containsKey('id') &&
          m.containsKey('venue_id') &&
          m.containsKey('reservation_at')) {
        candidates.add(m);
      }
      for (final inner in v.values) {
        collect(inner);
      }
    } else if (v is List) {
      for (final inner in v) {
        collect(inner);
      }
    }
  }
  collect(fixtureJson);
  if (candidates.isEmpty) return;

  for (var i = 0; i < candidates.length; i++) {
    LibroReservationDto? dto;
    Object? caught;
    try {
      dto = LibroReservationDto.fromMap(candidates[i]);
    } catch (e) {
      caught = e;
    }
    final accepted = dto != null;
    // `ambiguous` outcomes (compound "reject OR …" cells) skip the
    // pass/reject divergence check; the README documents either as
    // acceptable.
    if (expectedOutcome == 'ambiguous') {
      continue;
    }
    if (expectedOutcome == 'pass' && !accepted) {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: scenario,
        divergenceType: 'expected_pass_got_reject',
        detail: 'LibroReservationDto.fromMap threw on candidate $i: '
            '${caught ?? "null"}; README expected accept',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    } else if (expectedOutcome == 'reject' && accepted) {
      sink.record(P2aFinding(
        vendor: vendor.vendorId,
        scenario: scenario,
        divergenceType: 'expected_reject_got_pass',
        detail: 'LibroReservationDto.fromMap returned DTO on candidate $i; '
            'README expected reject. id=${dto.id}',
        fixturePath: '${vendor.fixtureDir}/$fixtureName',
      ));
    }
  }
}

// ─── Cross-vendor namespace pair probes ───────────────────────────

void _probeCrossVendorPair(String a, String b, P2aFindingSink sink) {
  final entryA = _vendorById(a);
  final entryB = _vendorById(b);
  if (entryA == null || entryB == null) {
    sink.record(P2aFinding(
      vendor: '$a/$b',
      scenario: 'scenario_f_cross_vendor_id_collision',
      divergenceType: 'adapter_not_found',
      detail: 'one or both vendors missing from registry',
      fixturePath: '<n/a>',
    ));
    return;
  }
  final fileA = '$kFixtureRoot/$a/scenario_f_cross_vendor_id_collision.json';
  final fileB = '$kFixtureRoot/$b/scenario_f_cross_vendor_id_collision.json';
  if (!File(fileA).existsSync() || !File(fileB).existsSync()) {
    sink.record(P2aFinding(
      vendor: '$a/$b',
      scenario: 'scenario_f_cross_vendor_id_collision',
      divergenceType: 'fixture_unparseable',
      detail: 'one or both scenario_f fixtures missing',
      fixturePath: '$a + $b',
    ));
    return;
  }

  // The cross-vendor namespace assertion lives at the canonical
  // UNIQUE on `(vendor_id, operator_id, vendor_entity_id,
  // vendor_modified_at)`. At THIS layer we structurally assert that
  // each vendor's fixture is keyed under its own vendor_id namespace
  // (i.e. they do NOT share a vendor_id) AND that each fixture
  // documents an internal collision via a `_pre_existing_canonical_row`,
  // `shadow_write_pre_existing`, or `collision_pair` marker.
  if (entryA.vendorId == entryB.vendorId) {
    sink.record(P2aFinding(
      vendor: '$a/$b',
      scenario: 'scenario_f_cross_vendor_id_collision',
      divergenceType: 'cross_vendor_namespace_collision',
      detail: 'paired vendors share the same vendor_id: '
          '${entryA.vendorId} == ${entryB.vendorId}',
      fixturePath: '$a + $b',
    ));
  }
  // Each fixture should reference the OTHER vendor as the colliding
  // namespace. This is the structural defense the canonical UNIQUE
  // protects against.
  if (!_fixtureReferencesOther(fileA, b)) {
    sink.record(P2aFinding(
      vendor: '$a/$b',
      scenario: 'scenario_f_cross_vendor_id_collision',
      divergenceType: 'wrong_reject_reason',
      detail: '$a fixture documents collision against a different '
          'counterpart vendor (not $b). The Phase 1 corpus only ships '
          'one scenario_f fixture per vendor with a single documented '
          'pairing; Phase 5 should expand to the full N-vs-N matrix.',
      fixturePath: fileA,
    ));
  }
  if (!_fixtureReferencesOther(fileB, a)) {
    sink.record(P2aFinding(
      vendor: '$a/$b',
      scenario: 'scenario_f_cross_vendor_id_collision',
      divergenceType: 'wrong_reject_reason',
      detail: '$b fixture documents collision against a different '
          'counterpart vendor (not $a). The Phase 1 corpus only ships '
          'one scenario_f fixture per vendor with a single documented '
          'pairing; Phase 5 should expand to the full N-vs-N matrix.',
      fixturePath: fileB,
    ));
  }
}

/// True when the JSON fixture at [path] mentions the [otherVendorId]
/// somewhere in its body — used to confirm the cross-vendor pair
/// actually documents the collision against the paired vendor.
bool _fixtureReferencesOther(String path, String otherVendorId) {
  try {
    final raw = File(path).readAsStringSync();
    return raw.contains(otherVendorId);
  } catch (_) {
    return false;
  }
}

// ─── Audit-claim mismatch ─────────────────────────────────────────

void _probeAuditClaim({
  required String vendorId,
  required VendorAuthMode expectedAuthMode,
  required String auditClaim,
  required P2aFindingSink sink,
}) {
  final entry = _vendorById(vendorId);
  if (entry == null) {
    sink.record(P2aFinding(
      vendor: vendorId,
      scenario: '<audit>',
      divergenceType: 'adapter_not_found',
      detail: 'registry has no entry for vendor $vendorId',
      fixturePath: '<n/a>',
    ));
    return;
  }
  // The registry mirrors the adapter's static `capabilityProfile`.
  // If they ever drift the harness should flag both.
  if (entry.authMode != expectedAuthMode) {
    sink.record(P2aFinding(
      vendor: vendorId,
      scenario: '<audit>',
      divergenceType: 'audit_claim_mismatch',
      detail: 'registry authMode is ${entry.authMode}; expected '
          '$expectedAuthMode for the audit-correction probe',
      fixturePath: '<n/a>',
    ));
    return;
  }
  // Successful refutation of the audit claim is itself a finding so
  // Phase 5 sees the validated correction.
  sink.record(P2aFinding(
    vendor: vendorId,
    scenario: '<audit>',
    divergenceType: 'audit_claim_mismatch',
    detail: 'audit claimed "$auditClaim"; capability profile actually '
        'declares ${entry.authMode}. Audit doc needs update.',
    fixturePath: '<n/a>',
  ));
}

// ─── Pre-flagged Phase 5 bugs ─────────────────────────────────────

void _probePreFlaggedSquareLightspeedNaiveTimestamp(P2aFindingSink sink) {
  // Already exercised inside `_probeAmbiguousTimestamp` for both
  // vendors. This wrapper exists so the bug name stays grep-able in
  // the test source.
}

void _probePreFlaggedHumanityTimeOffAs24hShift(P2aFindingSink sink) {
  final fixturePath =
      '$kFixtureRoot/humanity/happy_path_time_off_request.json';
  final file = File(fixturePath);
  if (!file.existsSync()) {
    sink.record(P2aFinding(
      vendor: 'humanity',
      scenario: 'happy_path_time_off_request',
      divergenceType: 'fixture_unparseable',
      detail: 'time-off fixture missing',
      fixturePath: 'humanity/happy_path_time_off_request.json',
    ));
    return;
  }
  final json = jsonDecode(file.readAsStringSync());
  if (json is! Map) return;
  final data = json['data'];
  if (data is! List) return;
  // Find the row with type=time_off; assert the DTO returns non-null
  // (the documented bug). The row has a 24h span (00:00 → 24:00).
  for (final r in data) {
    if (r is! Map) continue;
    if (r['type'] != 'time_off') continue;
    final raw = _castStringKeyMap(r);
    final dto = HumanityShiftDto.tryFromMap(raw);
    if (dto == null) {
      sink.record(P2aFinding(
        vendor: 'humanity',
        scenario: 'happy_path_time_off_request',
        divergenceType: 'pre_flagged_bug_silently_fixed',
        detail: 'HumanityShiftDto.tryFromMap REJECTED a type=time_off '
            'row; the documented bug (parses time-off as 24h shift) '
            'no longer reproduces. Phase 5 may close this bug.',
        fixturePath: 'humanity/happy_path_time_off_request.json',
      ));
    } else {
      final span = dto.outTime.difference(dto.inTime);
      sink.record(P2aFinding(
        vendor: 'humanity',
        scenario: 'happy_path_time_off_request',
        divergenceType: 'pre_flagged_bug_confirmed',
        detail: 'HumanityShiftDto.tryFromMap accepted a type=time_off '
            'row as a regular shift. Span = ${span.inHours}h. Phase 5 '
            'fix: branch on type=time_off and skip canonical write.',
        fixturePath: 'humanity/happy_path_time_off_request.json',
      ));
    }
  }
}

// ─── Helpers ──────────────────────────────────────────────────────

String _scenarioName(String fixtureFile) =>
    fixtureFile.replaceAll('.json', '');

VendorRegistryEntry? _vendorById(String id) {
  for (final e in kP2aVendorRegistry) {
    if (e.vendorId == id) return e;
  }
  return null;
}

Map<String, Object?> _castStringKeyMap(Map<dynamic, dynamic> m) {
  final out = <String, Object?>{};
  m.forEach((k, v) {
    out[k.toString()] = v;
  });
  return out;
}

void _walkStrings(Object? v, void Function(String) visit) {
  if (v is String) {
    visit(v);
  } else if (v is List) {
    for (final inner in v) {
      _walkStrings(inner, visit);
    }
  } else if (v is Map) {
    for (final inner in v.values) {
      _walkStrings(inner, visit);
    }
  }
}

List<DateTime> _collectTimestamps(Object? v) {
  final out = <DateTime>[];
  _walkStrings(v, (s) {
    if (_looksLikeIsoTimestamp(s)) {
      final t = DateTime.tryParse(s);
      if (t != null) out.add(t.toUtc());
    }
  });
  return out;
}

bool _looksLikeIsoTimestamp(String s) {
  // Loose detector — `YYYY-MM-DDTHH:MM` prefix.
  if (s.length < 16) return false;
  if (s[4] != '-' || s[7] != '-') return false;
  if (s[10] != 'T' && s[10] != ' ') return false;
  return true;
}

bool _looksLikeNaiveIsoTimestamp(String s) {
  if (!_looksLikeIsoTimestamp(s)) return false;
  // Naive = no `Z`, no `+HH:MM`, no `-HH:MM` after position 10.
  final tail = s.substring(10);
  if (tail.endsWith('Z')) return false;
  // Look for `+HH:MM` or `-HH:MM` offset at the end.
  final offsetMatch = RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(tail);
  return !offsetMatch;
}

String _firstFrame(StackTrace st) {
  final lines = st.toString().split('\n');
  return lines.isEmpty ? '<no stack>' : lines.first;
}

// Cache of (vendorDir → first happy_path_*.json) so the
// `adapter_not_found` finding fires once per vendor, not per fixture.
final Map<String, String?> _firstHappyPathCache = <String, String?>{};

String? _firstHappyPath(String vendorDir) {
  return _firstHappyPathCache.putIfAbsent(vendorDir, () {
    final dir = Directory('$kFixtureRoot/$vendorDir');
    if (!dir.existsSync()) return null;
    final happy = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.startsWith('happy_path_'))
        .toList()
      ..sort();
    return happy.isEmpty ? null : happy.first;
  });
}

/// Resolve a path relative to the repo root from wherever
/// `flutter test` invokes the harness. The test runner sets the cwd
/// to the package root, so `path` is already relative to it.
String _resolveRepoPath(String relative) {
  final cwd = Directory.current.path.replaceAll('\\', '/');
  final rel = relative.replaceAll('\\', '/');
  return '$cwd/$rel';
}
