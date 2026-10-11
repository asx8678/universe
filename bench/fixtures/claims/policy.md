# Refund claims policy

The shop database is `data/shop.db` (SQLite): `customers`, `orders`,
`shipments` (one per order: promised and delivered dates, status, the address
it was delivered to, the SKU actually shipped), `payments`, `refunds`, and
`claims` (one per open claim, from the customer `customer_id`). Today is
2026-10-01; claims were filed today.

Decide every claim. First find the order it is about: the customer gives an
order number, or describes the product and roughly when they ordered it
(match it against that customer's orders). Then, first rule that applies:

1. `escalate` if that order already has a refund.
2. Otherwise check the claim against the records:
   - **late** (it came later than promised): approve if it was delivered after
     its promised date; deny if it arrived on or before it.
   - **defect** (it is broken or faulty): approve if the claim is within 30 days
     of delivery; deny if later.
   - **duplicate** (charged twice): approve if the order has two or more
     payments; deny otherwise.
   - **wrong_item** (sent the wrong product): approve if the shipped SKU differs
     from the ordered SKU; deny otherwise.
   - **not_received** (it never arrived): approve if the shipment is not
     `delivered`, or was delivered to an address other than the customer's;
     deny if delivered to their address. Also deny when the customer says
     they had it sent somewhere else on purpose (a gift, a friend's address).
   - A **defect** the customer says they caused (dropped it, misused it) is
     denied whatever the dates.

Customers often mention other orders in passing; decide only the one the
claim is about.

Write `decisions.md` with one line per claim, in claim id order:

    <claim id>. <approve|deny|escalate> | <type> | <order id>

For example: `9001. deny | late | 301234`.
