// Phase 8.S.ADP — ADP webhook payload fixtures.
//
// Documented per the ADP developer-portal API catalog
// (https://developers.adp.com/articles/guides/adp-workforce-now-api-catalog),
// retrieval date 2026-05-04. The ADP Marketplace event-subscription
// payload shape mirrors the assumed `time.timeEvent.modify` event:
// the top-level envelope carries a `time_event` key (and a sibling
// `worker` block) whose value is the vendor-shape time-event row
// (same shape as the time-events endpoint row in
// `adp_punches_fixture.dart`). Every header and signature placement
// is an assumption flagged for verification in
// `8.S.ADP.live.sandbox`.

const String adpWebhookEventTimeEventModify = 'time.timeEvent.modify';

/// Sample raw-body string for a `time.timeEvent.modify` webhook. The
/// signature verifier MUST sign the raw bytes — no JSON
/// re-serialization between the proxy and the verifier.
const String adpTimeEventModifiedRawBody =
    '{"event_id":"evt-adp-001","time_event":{"id":"ADP-TE-12345","entry_date_time":"2026-05-04T15:00:00Z","exit_date_time":"2026-05-04T23:00:00Z","last_modified_date_time":"2026-05-04T23:00:30Z"},"worker":{"associate_oid":"G3WXX1Y2Z3A4B5C6","position":{"position_title":"Server"}}}';

/// Pre-decoded payload that matches [adpTimeEventModifiedRawBody].
/// The inbound handler hands the adapter both the raw bytes (for
/// HMAC) and the decoded JSON (for the field-mapping work).
const Map<String, Object?> adpTimeEventModifiedPayload =
    <String, Object?>{
  'event_id': 'evt-adp-001',
  'time_event': <String, Object?>{
    'id': 'ADP-TE-12345',
    'entry_date_time': '2026-05-04T15:00:00Z',
    'exit_date_time': '2026-05-04T23:00:00Z',
    'last_modified_date_time': '2026-05-04T23:00:30Z',
  },
  'worker': <String, Object?>{
    'associate_oid': 'G3WXX1Y2Z3A4B5C6',
    'position': <String, Object?>{
      'position_title': 'Server',
    },
  },
};
