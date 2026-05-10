# Source

- URL: https://developer.revelsystems.com/revelsystems/docs/webhooks
- Retrieved: 2026-05-08
- API version: v1-2026-05-03
- Endpoint: webhook subscription `order.finalized` — payload includes the optional `payments[]` array per the same vendor doc page (Revel documents the per-payment fields as PCI-scoped and only populated when the operator's PCI scope allows).
- Notes:
  - `final_total` is emitted here as a JSON number (not a string). The vendor doc shows both shapes; the adapter's `_parseSales` accepts `num` and string-decimal per `docs/integrations/revel/field_mapping.md` "Ambiguity calls" section.
  - `payments[].card_last4`, `card_brand`, `cardholder_name`, and per-payment `tip_amount` are explicitly listed as forbidden persistence fields in `docs/integrations/revel/field_mapping.md` "Forbidden fields" — included here so harnesses can verify the adapter ignores them at canonical-write time.
  - "_sourcing_gap": Revel's developer portal is partner-only past the public webhooks page; the per-`payments[]` field set was reconstructed from public Revel API references and the adapter's documented forbidden-fields list (`order.payments[].card_last4`, `order.payments[].card_brand`, `order.payments[].cardholder_name`, `order.tip_amount`). Adapter test fixture
    `test/integrations/pos/fixtures/revel_orders_fixture.dart` does not exercise the `payments` shape, so this fixture is the first place the field set lands.
