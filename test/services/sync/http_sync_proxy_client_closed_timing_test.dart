// V1.A closed-row proxy timing-provenance Lane: tests the
// HTTP sync client ingests the `business_timing_profile_id` /
// `business_timing_profile_version_id` / `service_period_key`
// triplet on closed `shift_records` payloads, and falls back
// gracefully when a legacy proxy doesn't emit them yet.
//
// Pairs with `test/proxy/closed_row_proxy_timing_provenance_test.dart`
// which proves the proxy emits those keys.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:forge_and_flow/services/sync/http_sync_proxy_client.dart';

void main() {
  group('HttpSyncProxyClient.fetchShiftRecords parses timing triplet', () {
    test('reads triplet from a payload that emits all three keys', () async {
      final client = HttpSyncProxyClient(
        proxyBaseUri: Uri.parse('https://proxy.example'),
        idTokenProvider: () async => 'token-1',
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'records': <Object?>[_closedShiftRowWithTriplet()],
              'next_cursor': null,
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final page = await client.fetchShiftRecords(
        operatorId: 'op-1',
        locationId: 'loc-1',
        cursor: null,
        pageSize: 50,
      );

      final record = page.records.single;
      expect(
        record.businessTimingProfileId,
        '44444444-4444-4444-8444-444444444444',
      );
      expect(
        record.businessTimingProfileVersionId,
        '44444444-4444-4444-8444-444444444444',
      );
      expect(record.servicePeriodKey, 'lunch');
      expect(record.daypartTargetCPLH, 11.5);
      expect(record.daypartTargetSPLH, 49.0);
      expect(record.daypartTargetPPA, 39.0);
      expect(record.daypartOpzFloorCPLH, 9.5);
      expect(record.daypartOpzCeilingCPLH, 13.5);
      // Legacy `daypart` field survives — closed-row resolvers may
      // still rely on it as the bucket key when the triplet is null.
      expect(record.daypart, 'lunch');
    });

    test(
      'legacy payload without the triplet still parses and reads null',
      () async {
        final client = HttpSyncProxyClient(
          proxyBaseUri: Uri.parse('https://proxy.example'),
          idTokenProvider: () async => 'token-1',
          httpClient: http_testing.MockClient((request) async {
            return http.Response(
              jsonEncode(<String, Object?>{
                'records': <Object?>[_legacyClosedShiftRow()],
                'next_cursor': null,
              }),
              200,
            );
          }),
        );

        final page = await client.fetchShiftRecords(
          operatorId: 'op-1',
          locationId: 'loc-1',
          cursor: null,
          pageSize: 50,
        );

        final record = page.records.single;
        expect(record.businessTimingProfileId, isNull);
        expect(record.businessTimingProfileVersionId, isNull);
        expect(record.servicePeriodKey, isNull);
        expect(record.daypartTargetCPLH, isNull);
        expect(record.daypartTargetSPLH, isNull);
        expect(record.daypartTargetPPA, isNull);
        expect(record.daypartOpzFloorCPLH, isNull);
        expect(record.daypartOpzCeilingCPLH, isNull);
        // Legacy daypart still present — the closed timing resolver
        // falls back to it when the triplet is absent.
        expect(record.daypart, 'dinner');
      },
    );

    test(
      'payload with explicit nulls in the triplet keys parses without throwing',
      () async {
        final client = HttpSyncProxyClient(
          proxyBaseUri: Uri.parse('https://proxy.example'),
          idTokenProvider: () async => 'token-1',
          httpClient: http_testing.MockClient((request) async {
            return http.Response(
              jsonEncode(<String, Object?>{
                'records': <Object?>[_closedShiftRowWithExplicitNulls()],
                'next_cursor': null,
              }),
              200,
            );
          }),
        );

        final page = await client.fetchShiftRecords(
          operatorId: 'op-1',
          locationId: 'loc-1',
          cursor: null,
          pageSize: 50,
        );

        final record = page.records.single;
        expect(record.businessTimingProfileId, isNull);
        expect(record.businessTimingProfileVersionId, isNull);
        expect(record.servicePeriodKey, isNull);
        expect(record.daypartTargetCPLH, isNull);
        expect(record.daypartTargetSPLH, isNull);
        expect(record.daypartTargetPPA, isNull);
        expect(record.daypartOpzFloorCPLH, isNull);
        expect(record.daypartOpzCeilingCPLH, isNull);
        expect(record.daypart, 'dinner');
      },
    );
  });
}

Map<String, Object?> _closedShiftRowWithTriplet() => <String, Object?>{
  'restaurant_id': 'loc-1',
  'week_id': '2026-W18',
  'day_label': 'Tue',
  'daypart': 'lunch',
  'status': 'closed',
  'business_date': '2026-05-05',
  'business_timing_profile_id': '44444444-4444-4444-8444-444444444444',
  'business_timing_profile_version_id': '44444444-4444-4444-8444-444444444444',
  'service_period_key': 'lunch',
  'daypart_target_cplh': 11.5,
  'daypart_target_splh': 49.0,
  'daypart_target_ppa': 39.0,
  'daypart_opz_floor_cplh': 9.5,
  'daypart_opz_ceiling_cplh': 13.5,
  'covers': 120,
  'forecast_covers': 110,
  'ppa': 42.0,
  'cplh': 13.5,
  'splh': 160.0,
  'foh_hours': 8,
  'boh_hours': 5,
  'theoretical_labor_pct': 24.0,
  'primary_lever': 'ON_MODEL',
};

Map<String, Object?> _legacyClosedShiftRow() => <String, Object?>{
  'restaurant_id': 'loc-1',
  'week_id': '2026-W17',
  'day_label': 'Mon',
  'daypart': 'dinner',
  'status': 'closed',
  'business_date': '2026-04-28',
  'covers': 80,
  'forecast_covers': 90,
  'ppa': 38.0,
  'cplh': 12.0,
  'splh': 150.0,
  'foh_hours': 7,
  'boh_hours': 5,
  'theoretical_labor_pct': 25.0,
  'primary_lever': 'ON_MODEL',
};

Map<String, Object?> _closedShiftRowWithExplicitNulls() {
  final row = Map<String, Object?>.from(_legacyClosedShiftRow());
  row['business_timing_profile_id'] = null;
  row['business_timing_profile_version_id'] = null;
  row['service_period_key'] = null;
  return row;
}
