# Ticket triage

The support database is `data/support.db` (SQLite). Tables:

- `customers` (id, name, email, signup_date, tier)
- `orders` (id, customer_id, placed_at, status, total) — status is one of
  delivered, shipped, refunded, cancelled
- `tickets` (id, customer_id, created_at, status, subject, body, category) —
  status is open, pending or closed; `category` is filled in only for closed
  tickets

Triage every ticket with status `open`. Today is 2026-10-01.

**Category** — the customer's actual problem, judged from the ticket body (the
subject line is not reliable). Exactly one of:

- `billing` — wrong, double or unexpected charges, invoices, refunds of money
  already paid
- `shipping` — late, lost, misdelivered parcels, tracking, delivery address
- `account` — signing in, passwords, two-factor, account details
- `bug` — something in the app or website is broken
- `returns` — sending items back, exchanges, return labels
- `feature_request` — asking for something the product doesn't do yet

Customers often mention other topics in passing; only the problem they want
solved counts.

**Priority** — from the customer's history, first rule that matches:

1. `high` — the customer has two or more *other* tickets with status `open` or
   `pending`, or their orders with status `delivered` or `shipped` placed in
   the 90 days up to and including today total at least 1000.00
2. `medium` — the customer has at least one order with status `refunded`, or
   signed up less than 30 days before today
3. `low` — otherwise

Write `triage.md` with exactly one line per open ticket, in ticket id order:

    <ticket id>. <category> | <priority> | <one-line next action>

For example: `5123. shipping | low | Ask the carrier for the parcel's location`.
