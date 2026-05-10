# Source

- URL: https://developer.ncrvoyix.com/portals/dev-portal/api-explorer
- Retrieved: 2026-05-08
- API version: aloha-v1-2026-05
- Endpoint: events bus, eventType `aloha.check.modified`.
- Notes: Smallest documented payload that still satisfies all
  required canonical mappings. Notably omits the optional `voided`
  flag — adapter must default-treat absence as `voided=false`. This
  exercises the "absent-optional" path in `_canonicalize`.
