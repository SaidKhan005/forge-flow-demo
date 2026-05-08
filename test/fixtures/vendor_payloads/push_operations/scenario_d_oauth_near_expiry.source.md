# Source

- URL: https://developers.pushoperations.com/
- Retrieved: 2026-05-08
- API version: v1 (REST API at /api/v1/...)
- Endpoint: GET /api/v1/company (auth round-trip + rotation)
- Notes: Push Operations is a **non-OAuth vendor** per
  `docs/POST_HARDENING_FOLLOWUPS.md` "Confirmed-clean" section
  (line 453: "Push/bearer ... intentionally have no closure"). The
  `oauth_shape.md` doc pack file is a single-line N/A. The README
  format spec at `test/fixtures/vendor_payloads/README.md` calls
  out this case explicitly: "For these vendors, scenario D is still
  required but covers the analogous credential-rotation path."

  Push Operations' substitute path is **bearer rotation out-of-band
  via the partner portal**, then a re-paste in the F&F admin
  connect dialog. There is no programmatic refresh hop; the
  `proxy.refresh_expiring_inbound_vendor_tokens()` cron is a no-op
  for `vendor_id = 'push_operations'`. The Phase 2A harness asserts:

  1. The OAuth refresh worker has **no closure registered** for
     `push_operations` (the registry skips this vendor by design).
  2. With the old (revoked) bearer, the next adapter call returns
     401; after 3 consecutive 401 failures the connection flips to
     `error`.
  3. With the new bearer (re-pasted via admin connect dialog), the
     next `GET /api/v1/company` returns 200 and the connection
     flips back to `connected`.
  4. Watermark is preserved across the rotation
     (`disconnect → reconnect` row of
     `live_verification_checklist.md`).
