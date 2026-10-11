"""Generate the M7 acceptance fixture: a support database to triage.

    python3 bench/gen_triage.py          # writes the ticket specs, or the fixture once bodies exist
    python3 bench/write_tickets.py       # an LLM writes each open ticket's body from its spec
    python3 bench/audit_triage.py        # gates: labels clear to haiku, no regex shortcut
    python3 bench/gen_triage.py          # builds the fixture

Writes bench/fixtures/triage/{data/support.db,instructions.md} and the answer
key bench/graders/triage_answers.json (outside the fixture, so the model never
sees it). The world (customers, orders, history, which tickets are open and
their labels) is seeded; the open tickets' bodies are written once by an LLM
(bench/graders/triage_bodies.json) so no template or regex covers them. A
first, template-written version was solved by a regex in the pilot.

Category is judgment over free text: each open ticket's real issue is one
category, with other categories' words in passing (resolved past problems,
asides). Priority needs lookups in the customer's history. Some tickets
mention a chargeback, half of them indirectly: the rule for those arrives
mid-run (see bench/README.md, M7 acceptance), not in instructions.md.
"""

import datetime as dt
import json
import pathlib
import random
import sqlite3

BENCH = pathlib.Path(__file__).resolve().parent
FIXTURE = BENCH / "fixtures" / "triage"
ANSWERS = BENCH / "graders" / "triage_answers.json"
SPECS = BENCH / "graders" / "triage_specs.json"
BODIES = BENCH / "graders" / "triage_bodies.json"

SEED = 7
TODAY = dt.date(2026, 10, 1)
N_CUSTOMERS = 3000
N_OPEN = 600

CATEGORIES = ["billing", "shipping", "account", "bug", "returns", "feature_request"]

# The real issue, in a few interchangeable sentences per category.
CORE = {
    "billing": [
        ["I was charged twice for order {order}.", "My statement shows two identical payments of ${amt} for order {order}.",
         "Order {order} was billed {amt} more than the price at checkout."],
        ["I cancelled my subscription on {date}, yet another monthly fee was taken.",
         "The coupon code was accepted on the page but the discount never showed up on what I paid.",
         "The invoice for {order} has the wrong company name and no VAT number, so accounting can't book it."],
        ["Please refund the extra amount to my card.", "Could someone correct the charge and send a fixed invoice?",
         "I'd like the overpayment returned, not store credit."],
    ],
    "shipping": [
        ["Order {order} still hasn't arrived and it has been {days} days.", "The tracking for {order} has said 'label created' for {days} days.",
         "The courier marked {order} as delivered on {date}, but nothing came."],
        ["The address on the shipping label is my old flat, not the one on my account.",
         "Your carrier's site says the parcel is held at a depot two cities away.",
         "Nobody rang the bell; there was no card and no parcel at the door."],
        ["Can you find out where it is and when it will get here?", "Please send it again or tell me what the courier says.",
         "I just need a delivery date I can plan around."],
    ],
    "account": [
        ["I can't sign in any more: it says my password is wrong even after a reset.",
         "The password reset email never arrives, I've checked spam.",
         "I lost the phone with my two-factor codes and now I'm locked out."],
        ["I also need to change the email on the account to {email}.", "My account shows someone else's name since last week.",
         "Every login attempt sends me back to the sign-in page."],
        ["Please help me get back into my account.", "Can you reset the login so I can get in?",
         "I need access restored before my next order."],
    ],
    "bug": [
        ["The app crashes every time I open the order history screen.", "Pressing 'Pay now' at checkout does nothing at all.",
         "The website shows 'Error 500' when I try to save my preferences."],
        ["It happens on both my phone and laptop, after updating to version {ver}.",
         "I cleared the cache and reinstalled; same result.", "The export to PDF produces an empty file."],
        ["Is this a known problem, and is a fix coming?", "Please pass this to your developers.",
         "Let me know if you need logs or screenshots."],
    ],
    "returns": [
        ["I'd like to return the {item} from order {order}; it doesn't fit.", "I want to exchange the {item} for a size larger.",
         "The prepaid return label you emailed won't scan at the drop-off point."],
        ["It's unworn and still in the original packaging.", "I'm still within the 30-day return window.",
         "The drop-off shop said the label's barcode is invalid."],
        ["How do I send it back?", "Please send a working return label.", "What are the next steps for the exchange?"],
    ],
    "feature_request": [
        ["It would be great if the app had a dark mode.", "Could you add a way to export my order history to CSV?",
         "Please consider letting us schedule repeat orders."],
        ["Several people on my team have asked for the same thing.", "Other shops I use already offer this.",
         "It would save me a lot of manual work each month."],
        ["Is this on your roadmap?", "Just a suggestion, thanks for listening.", "I'd happily test a beta of it."],
    ],
}

PERSONAS = [
    "a busy parent writing on a phone, short sentences, a typo or two",
    "a small-business owner, brisk and practical",
    "a retiree, polite and chatty, tells some backstory",
    "a student, casual, lowercase-heavy",
    "a non-native English speaker, simple but slightly unusual phrasing",
    "an IT professional, precise and detailed",
    "an angry long-time customer, sarcastic",
    "a very polite first-time customer, apologetic",
    "someone forwarding the problem on behalf of a relative",
    "a terse customer who writes in fragments",
]
ITEMS = ["linen shirt", "trail shoes", "desk lamp", "rain jacket", "wool scarf", "coffee grinder", "backpack", "yoga mat"]
FIRST = ["Ana", "Ben", "Chloé", "Dev", "Eitan", "Fatima", "Grace", "Hiro", "Ines", "Jonas", "Kofi", "Lena", "Marta", "Nils",
         "Omar", "Priya", "Quinn", "Rosa", "Sven", "Tara", "Umar", "Vera", "Wei", "Yara", "Zoe"]
LAST = ["Andersen", "Brooks", "Costa", "Dubois", "Eriksen", "Fischer", "Garcia", "Haddad", "Ivanova", "Jensen", "Khan",
        "Larsen", "Moreau", "Nakamura", "Okafor", "Petrov", "Quist", "Rossi", "Sato", "Torres", "Ueda", "Vargas", "Weber"]


def day(r, lo, hi):
    return TODAY - dt.timedelta(days=r.randint(lo, hi))


def main():
    r = random.Random(SEED)
    FIXTURE.joinpath("data").mkdir(parents=True, exist_ok=True)
    db_path = FIXTURE / "data" / "support.db"
    if db_path.exists():
        db_path.unlink()
    db = sqlite3.connect(db_path)
    db.executescript(
        """
        CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, email TEXT, signup_date TEXT, tier TEXT);
        CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, placed_at TEXT, status TEXT, total REAL);
        CREATE TABLE tickets (id INTEGER PRIMARY KEY, customer_id INTEGER, created_at TEXT, status TEXT,
                              subject TEXT, body TEXT, category TEXT);
        """
    )

    customers = []
    for cid in range(1, N_CUSTOMERS + 1):
        name = f"{r.choice(FIRST)} {r.choice(LAST)}"
        # A few recent sign-ups, so the "new customer" rule matters.
        signup = day(r, 1, 29) if r.random() < 0.08 else day(r, 30, 2200)
        email = f"{name.lower().replace(' ', '.').replace('é', 'e')}{cid}@example.com"
        customers.append((cid, name, email, signup.isoformat(), r.choice(["standard", "standard", "silver", "gold"])))
    db.executemany("INSERT INTO customers VALUES (?,?,?,?,?)", customers)

    orders = []
    oid = 100000
    for cid, _, _, signup, _ in customers:
        since = (TODAY - dt.date.fromisoformat(signup)).days
        for _ in range(r.choice([0, 1, 2, 3, 4, 5, 6, 8, 12])):
            oid += 1
            placed = TODAY - dt.timedelta(days=r.randint(0, max(since, 1)))
            status = r.choices(["delivered", "shipped", "refunded", "cancelled"], [70, 10, 8, 12])[0]
            total = round(r.choice([r.uniform(8, 120), r.uniform(8, 120), r.uniform(100, 700)]), 2)
            orders.append((oid, cid, placed.isoformat(), status, total))
    db.executemany("INSERT INTO orders VALUES (?,?,?,?,?)", orders)
    by_customer = {}
    for o in orders:
        by_customer.setdefault(o[1], []).append(o)

    tid = 5000
    history = []
    for _ in range(6000):
        tid += 1
        cid = r.randint(1, N_CUSTOMERS)
        cat = r.choice(CATEGORIES)
        body = " ".join(r.choice(part) for part in CORE[cat]).format(
            order="#" + str(r.randint(100001, oid)), amt="19.99", date="last week", days=9, email="new@example.com",
            ver="4.2", item=r.choice(ITEMS))
        history.append((tid, cid, day(r, 40, 900).isoformat(), "closed", cat.replace("_", " ").title(), body, cat))

    # Open tickets: some customers have several, and a few have pending ones.
    pending = []
    for _ in range(60):
        tid += 1
        cid = r.randint(1, N_CUSTOMERS)
        pending.append((tid, cid, day(r, 3, 20).isoformat(), "pending", "Follow-up", "Still waiting on this.", None))

    open_customers = [r.randint(1, N_CUSTOMERS) for _ in range(N_OPEN - 120)]
    open_customers += [c for c in r.sample(open_customers, 60) for _ in range(2)]
    r.shuffle(open_customers)
    # Some pending tickets belong to customers with an open one.
    for i, cid in enumerate(r.sample(open_customers, 50)):
        tid += 1
        pending.append((tid, cid, day(r, 3, 20).isoformat(), "pending", "Follow-up", "Any news?", None))

    specs, labels = {}, {}
    for cid in open_customers[:N_OPEN]:
        tid += 1
        cat = r.choice(CATEGORIES)
        name = customers[cid - 1][1]
        own = by_customer.get(cid, [])
        # A chargeback only comes up where money or a parcel is at stake;
        # half of those never use the word.
        chargeback = cat in ("billing", "shipping") and r.random() < 0.3
        specs[str(tid)] = {
            "category": cat,
            "chargeback": ("direct" if r.random() < 0.5 else "indirect") if chargeback else "none",
            "asides": r.sample([c for c in CATEGORIES if c != cat], r.choice([1, 2, 2])),
            "persona": r.choice(PERSONAS),
            "length": r.choice([500, 650, 800, 950, 1100, 1200]),
            "issue_last": r.random() < 0.1,
            "first_name": name.split()[0],
            "order": "#" + str(r.choice(own)[0] if own else r.randint(100001, oid)),
            "item": r.choice(ITEMS),
            "date": day(r, 2, 40).strftime("%-d %B"),
        }
        labels[tid] = {"category": cat, "chargeback": chargeback, "customer": cid,
                       "created": day(r, 0, 2).isoformat(),
                       "subject": r.choice(["Help please", "Problem with my order", "Question", "Urgent",
                                            "Re: my last message", "Hello", "(no subject)", "Order"])}

    SPECS.write_text(json.dumps(specs, indent=1) + "\n")
    bodies = json.loads(BODIES.read_text()) if BODIES.exists() else {}
    missing = [t for t in specs if t not in bodies]
    if missing:
        print(f"wrote {len(specs)} specs to {SPECS}; {len(missing)} bodies missing: run bench/write_tickets.py")
        db.close()
        db_path.unlink()
        return
    open_tickets = [(tid, lab["customer"], lab["created"], "open", lab["subject"], bodies[str(tid)], None)
                    for tid, lab in labels.items()]

    rows = history + pending + open_tickets
    r.shuffle(rows)
    db.executemany("INSERT INTO tickets VALUES (?,?,?,?,?,?,?)", rows)
    db.commit()

    # Priority from the rules in instructions.md, computed in SQL terms.
    unresolved = {}
    for t in pending + open_tickets:
        unresolved.setdefault(t[1], []).append(t[0])
    window = (TODAY - dt.timedelta(days=90)).isoformat()
    answers = {}
    for tid, lab in labels.items():
        cid = lab["customer"]
        others = [t for t in unresolved.get(cid, []) if t != tid]
        recent = sum(o[4] for o in by_customer.get(cid, [])
                     if o[3] in ("delivered", "shipped") and window <= o[2] <= TODAY.isoformat())
        refunded = any(o[3] == "refunded" for o in by_customer.get(cid, []))
        new = (TODAY - dt.date.fromisoformat(customers[cid - 1][3])).days < 30
        if len(others) >= 2 or recent >= 1000:
            base = "high"
        elif refunded or new:
            base = "medium"
        else:
            base = "low"
        answers[str(tid)] = {"category": lab["category"], "priority": base, "chargeback": lab["chargeback"]}

    ANSWERS.write_text(json.dumps(answers, indent=1, sort_keys=True) + "\n")
    (FIXTURE / "instructions.md").write_text(INSTRUCTIONS)

    counts = {p: sum(a["priority"] == p for a in answers.values()) for p in ("high", "medium", "low")}
    chars = sum(len(b) for b in bodies.values() if b)
    print(f"{len(answers)} open tickets · priorities {counts} · "
          f"{sum(a['chargeback'] for a in answers.values())} mention a chargeback · "
          f"{len(customers)} customers, {len(orders)} orders, {len(rows)} tickets · {chars:,} chars of open tickets")


INSTRUCTIONS = """# Ticket triage

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
"""

if __name__ == "__main__":
    main()
