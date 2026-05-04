// Phase 8.S.7S — 7shifts webhook payload fixtures.
//
// Documented per https://developers.7shifts.com/reference/webhooks
// (retrieved 2026-05-04). The signature verifier MUST sign the raw
// body bytes — no JSON re-serialization between the proxy and the
// verifier. The `payroll_period.closed` event is load-bearing for the
// Phase 7.58 Primary Driver audit and is the headline reason 7shifts
// is the only INTEGRATE scheduling vendor with autoRegister webhooks.

const String sevenShiftsWebhookEventTimePunchEdited = 'time_punch.edited';
const String sevenShiftsWebhookEventPayrollPeriodClosed =
    'payroll_period.closed';

/// Sample raw-body string for a `time_punch.edited` webhook.
const String sevenShiftsTimePunchEditedRawBody =
    '{"event_type":"time_punch.edited","time_punch":{"id":712001,"user_id":99001,"role":{"id":401,"name":"Server"},"clocked_in":"2026-05-03T18:30:00Z","clocked_out":"2026-05-03T23:45:00Z","approved":true,"modified":"2026-05-04T00:05:00Z"}}';

/// Pre-decoded payload that matches [sevenShiftsTimePunchEditedRawBody].
const Map<String, Object?> sevenShiftsTimePunchEditedPayload =
    <String, Object?>{
  'event_type': 'time_punch.edited',
  'time_punch': <String, Object?>{
    'id': 712001,
    'user_id': 99001,
    'role': <String, Object?>{'id': 401, 'name': 'Server'},
    'clocked_in': '2026-05-03T18:30:00Z',
    'clocked_out': '2026-05-03T23:45:00Z',
    'approved': true,
    'modified': '2026-05-04T00:05:00Z',
  },
};

/// Sample raw-body string for a `payroll_period.closed` webhook. Phase
/// 7.58 Primary Driver audit binds against this event's `closed_at`
/// instant.
const String sevenShiftsPayrollPeriodClosedRawBody =
    '{"event_type":"payroll_period.closed","payroll_period":{"id":55001,"closed_at":"2026-05-04T08:00:00Z","start":"2026-04-21T00:00:00Z","end":"2026-05-04T07:59:59Z"}}';

/// Pre-decoded payload that matches
/// [sevenShiftsPayrollPeriodClosedRawBody].
const Map<String, Object?> sevenShiftsPayrollPeriodClosedPayload =
    <String, Object?>{
  'event_type': 'payroll_period.closed',
  'payroll_period': <String, Object?>{
    'id': 55001,
    'closed_at': '2026-05-04T08:00:00Z',
    'start': '2026-04-21T00:00:00Z',
    'end': '2026-05-04T07:59:59Z',
  },
};
