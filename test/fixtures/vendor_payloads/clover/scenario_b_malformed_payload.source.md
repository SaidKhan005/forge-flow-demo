# Source

- URL: https://docs.clover.com/reference/orderget
- Retrieved: 2026-05-08
- API version: REST v3 / `v3_2026_05_03`
- Endpoint: `GET /v3/merchants/{mId}/orders` — same shape as
  `happy_path_order_paid.json`, but **`order.id` is missing**. Per the
  documented `order` schema, `id` is a required field; an order
  payload missing `id` is malformed and never produced by a healthy
  Clover endpoint, but the adapter must defend against it.
- Adapter cite:
  `lib/integrations/pos/clover_pos_adapter.dart` `_project()`:
  ```
  final id = order['id'];
  ...
  if (id is! String || id.isEmpty) return null;
  ```
- Outcome: **Reject (drop at boundary)**. `_project` returns null;
  the adapter writes nothing for this row. The framework's
  `command.sanityHook` returning false on the same row would short-
  circuit before `_project` is even called, but `_project` itself is
  the inner defense per V1 lean cut 2 ("adapter writes a clean fact or
  refuses").
- Notes: this fixture exercises the **drop-at-boundary contract** —
  the adapter does NOT throw, does NOT halt the page chain. The
  surrounding list-endpoint envelope is well-formed so backfill
  continues after the rejected element.
