# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — minimal envelope, takeout / pickup order with `number_of_people = 0`.
- Notes:
  - Revel's `order.number_of_people` is documented as guest count for the order. Quick-service / pickup workflows often emit `0` because no guests are seated at a table.
  - The adapter's `_canonicalize` accepts `number_of_people = 0` (the field type guard `coversValue is! int && coversValue is! num` allows `0`), so this row writes a canonical fact with `covers = 0`.
  - `dining_option: 3` is the integer enum Revel uses for pickup / takeout. Per `docs/integrations/revel/field_mapping.md` "Ambiguity calls", the integer→label mapping is not fully published; the adapter currently ignores `dining_option` until verified at `*.live.sandbox`.
  - "_sourcing_gap": exact `dining_option` integer→label mapping (1 = dine-in vs 3 = pickup vs others) is not pinned on the public webhooks page. Mapping is reconstructed from third-party Revel integration writeups and is illustrative for harness purposes.
