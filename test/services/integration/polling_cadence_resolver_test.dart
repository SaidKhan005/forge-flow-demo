// Phase 8 Wave B `8.spine-bridge.0a` polling cadence resolver tests.
//
// Acceptance items A-E from the lane prompt:
//   A. No tier assignment -> 'standard' presets used; emits a
//      `tier_assignment_missing` log row.
//   B. Override < vendor_min -> clamped to vendor_min; emits a
//      `cadence_clamped` log row.
//   C. Override within bounds -> returned as-is; no log row.
//   D. tier_key=custom + vendor unset -> vendor_min; emits a
//      `custom_tier_vendor_unset` log row.
//   E. Oracle vendor_min=300s; tier specifies 60s -> clamped to 300s.
//
// Pure-logic tests; no I/O. The resolver's only side-effect is the
// `onSyncLog` callback, captured in-memory.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/services/integration/polling_cadence_resolver.dart';
import 'package:forge_and_flow/services/integration/polling_tier_presets.dart';

const String _opId = '00000000-0000-4000-8000-000000000001';
const String _locId = '00000000-0000-4000-8000-0000000000a1';

void main() {
  group('PollingCadenceResolver — F&F-controlled tier model', () {
    late _LogRecorder log;

    setUp(() {
      log = _LogRecorder();
    });

    test(
        'A. tier assignment missing -> standard presets used; emits '
        'tier_assignment_missing log',
        () {
      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'oracle_micros_simphony',
        tierAssignment: null,
        vendorMinimumCadenceSeconds: 300,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, kStandardTierPresets['oracle_micros_simphony'],
          reason: 'fallback path uses standard presets verbatim '
              '(Oracle preset = 300s)');
      expect(log.events, hasLength(1));
      expect(log.events.single.eventKind, 'tier_assignment_missing');
      expect(log.events.single.payload['vendor_id'], 'oracle_micros_simphony');
      expect(log.events.single.payload['fallback_tier_key'],
          PollingTierKey.standard.wire);
    });

    test(
        'A.cont — vendor not in standard presets falls back to vendor '
        'minimum and still logs tier_assignment_missing', () {
      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'unknown_poll_only_vendor',
        tierAssignment: null,
        vendorMinimumCadenceSeconds: 90,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 90);
      expect(log.events.single.eventKind, 'tier_assignment_missing');
    });

    test(
        'B. override < vendor_min -> clamped to vendor_min; emits '
        'cadence_clamped log',
        () {
      final tier = _customAssignment(<String, int>{
        'oracle_micros_simphony': 60,
      });

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'oracle_micros_simphony',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 300,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 300);
      expect(log.events, hasLength(1));
      expect(log.events.single.eventKind, 'cadence_clamped');
      expect(log.events.single.payload['vendor_id'], 'oracle_micros_simphony');
      expect(log.events.single.payload['requested_seconds'], 60);
      expect(log.events.single.payload['clamped_seconds'], 300);
      expect(log.events.single.payload['bound'], 'vendor_minimum');
      expect(log.events.single.payload['tier_key'],
          PollingTierKey.custom.wire);
    });

    test(
        'B.cont — override > framework_max -> clamped down to framework '
        'maximum; emits cadence_clamped',
        () {
      final tier = _customAssignment(<String, int>{
        'oracle_micros_simphony': 99999,
      });

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'oracle_micros_simphony',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 300,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, kFrameworkMaximumCadenceSeconds);
      expect(log.events.single.eventKind, 'cadence_clamped');
      expect(log.events.single.payload['bound'], 'framework_maximum');
    });

    test(
        'C. override within [vendor_min, framework_max] -> returned '
        'as-is; no log row',
        () {
      final tier = _customAssignment(<String, int>{
        'quickbooks_time': 120,
      });

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'quickbooks_time',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 60,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 120);
      expect(log.events, isEmpty,
          reason: 'happy path: in-bounds override emits no log row');
    });

    test(
        'C.cont — boundary equality (override == vendor_min) is in-bounds '
        '(no clamp log)', () {
      final tier = _customAssignment(<String, int>{
        'quickbooks_time': 60,
      });

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'quickbooks_time',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 60,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 60);
      expect(log.events, isEmpty);
    });

    test(
        'D. tier_key=custom + vendor unset -> vendor_min; emits '
        'custom_tier_vendor_unset log',
        () {
      final tier = _customAssignment(const <String, int>{});

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'humanity',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 300,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 300);
      expect(log.events, hasLength(1));
      expect(log.events.single.eventKind, 'custom_tier_vendor_unset');
      expect(log.events.single.payload['vendor_id'], 'humanity');
      expect(log.events.single.payload['fallback_seconds'], 300);
    });

    test(
        'E. Oracle vendor_min=300s; tier specifies 60s -> clamped to '
        '300s (binding contract example)',
        () {
      final tier = _customAssignment(<String, int>{
        'oracle_micros_simphony': 60,
      });

      final cadence = PollingCadenceResolver.resolve(
        vendorId: 'oracle_micros_simphony',
        tierAssignment: tier,
        vendorMinimumCadenceSeconds: 300,
        frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
        onSyncLog: log.record,
      );

      expect(cadence, 300,
          reason: 'Oracle Simphony minimum is 5 minutes per the vendor '
              'rate-limit policy; tier override below that floor must '
              'clamp');
      expect(log.events.single.eventKind, 'cadence_clamped');
      expect(log.events.single.payload['bound'], 'vendor_minimum');
    });

    group('preset fallback when vendor absent from tier JSONB', () {
      test('tier_key=standard + vendor unset -> standard preset', () {
        final tier = _assignment(
          tierKey: PollingTierKey.standard,
          cadence: const <String, int>{},
        );

        final cadence = PollingCadenceResolver.resolve(
          vendorId: 'agendrix',
          tierAssignment: tier,
          vendorMinimumCadenceSeconds: 300,
          frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
          onSyncLog: log.record,
        );

        expect(cadence, kStandardTierPresets['agendrix']);
        expect(log.events, isEmpty,
            reason: 'standard-preset fallback is the happy path; no log');
      });

      test('tier_key=premium + vendor unset -> premium preset', () {
        final tier = _assignment(
          tierKey: PollingTierKey.premium,
          cadence: const <String, int>{},
        );

        final cadence = PollingCadenceResolver.resolve(
          vendorId: 'quickbooks_time',
          tierAssignment: tier,
          vendorMinimumCadenceSeconds: 60,
          frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
          onSyncLog: log.record,
        );

        expect(cadence, kPremiumTierPresets['quickbooks_time']);
        expect(log.events, isEmpty);
      });

      test(
          'tier_key=premium + vendor not in premium presets -> vendor '
          'minimum (no log; presets-table miss is engineering-side)',
          () {
        final tier = _assignment(
          tierKey: PollingTierKey.premium,
          cadence: const <String, int>{},
        );

        final cadence = PollingCadenceResolver.resolve(
          vendorId: 'unknown_poll_only_vendor',
          tierAssignment: tier,
          vendorMinimumCadenceSeconds: 120,
          frameworkMaximumCadenceSeconds: kFrameworkMaximumCadenceSeconds,
          onSyncLog: log.record,
        );

        expect(cadence, 120);
        expect(log.events, isEmpty);
      });
    });
  });
}

ForgeFlowPollingTierAssignment _assignment({
  required PollingTierKey tierKey,
  required Map<String, int> cadence,
}) {
  return ForgeFlowPollingTierAssignment(
    assignmentId: '00000000-0000-4000-8000-0000000000aa',
    operatorId: _opId,
    locationId: _locId,
    tierKey: tierKey,
    pollingCadencePerVendorSeconds: cadence,
    effectiveAt: DateTime.utc(2026, 5, 1),
    createdAt: DateTime.utc(2026, 5, 1),
  );
}

ForgeFlowPollingTierAssignment _customAssignment(Map<String, int> cadence) =>
    _assignment(tierKey: PollingTierKey.custom, cadence: cadence);

class _LogEvent {
  const _LogEvent(this.eventKind, this.payload);
  final String eventKind;
  final Map<String, Object?> payload;
}

class _LogRecorder {
  final List<_LogEvent> events = <_LogEvent>[];

  void record(String eventKind, Map<String, Object?> payload) {
    events.add(_LogEvent(eventKind, payload));
  }
}
