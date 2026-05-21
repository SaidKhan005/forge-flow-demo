# p3a_webhook_signature_failure_storm — Phase 3A signature-failure storm

**Runner:** `test/pressure/p3a_webhook_signature_failure_storm_test.dart`
(in-process pressure against
`PointyCastleSendGridSignatureVerifier` in
`tool/advisor_proxy/sendgrid_events_webhook.dart`; preview-proxy
storm env-gated).

**What it pressures:** webhook signature verification failures (HMAC
mismatch, malformed signature, malformed PEM, missing header, stale
timestamp) are absorbed defensively and do not accumulate unbounded
in-memory state. The production verifier is stateless by contract;
the route's failure-logging path must be bounded.

**Status at branch fork point:** PASS. In-memory pressure runs under
default `flutter test`; the preview-proxy forged-signature flood
skips behind its env gate.

## Inputs

- Env gate (proxy portion): `FF_RUN_PRESSURE_P3A_SIG_FAILURE=1`.
  Without it the live-proxy storm skips.
- In-memory inputs: malformed base64 signatures, garbage PEMs,
  empty signatures, stale/future timestamps; a bounded LRU
  rate-limiter model.

## What it asserts

- 1000 verify calls with malformed signature base64 all return
  false (no exception propagates).
- 1000 verify calls with malformed PEM all return false (parse
  errors absorbed).
- A bounded LRU failure rate-limiter never exceeds its cap under a
  100k-request flood with 5000 distinct keys.
- Stale-timestamp guard rejects a 10-minute-old timestamp (and a
  10-minute-future one — clock-skew defense); accepts a fresh one.
- Empty signature collapses cleanly to verify=false.

## How to read the output

- Healthy run: 5 in-memory test cases pass; the env-gate test skips.
- Regression: a verify call that throws (instead of returning false)
  or an unbounded rate-limiter would surface here. A throwing
  verifier is a DoS vector (one forged request could 500 the route).

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §2.3 #6.

## Backlog

Preview-proxy harness — sustained forged-signature flood against the
live SendGrid route; assert response time + memory don't degrade.
