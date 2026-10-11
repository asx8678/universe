"""Generate the benchmark fixture: refund claims decided against the records.

    python3 bench/gen_claims.py          # writes claim specs, or the fixture once bodies exist
    python3 bench/write_claims.py        # an LLM writes each claim's text from its spec
    python3 bench/audit_claims.py        # gates: records needed, no regex+SQL shortcut, clear to a reader
    python3 bench/gen_claims.py          # builds the fixture

Writes bench/fixtures/claims/{data/shop.db,policy.md} and the answer key
bench/graders/claims_answers.json (outside the fixture).

Each claim is free text from a customer: what went wrong and with which
order, by number in about half of them, otherwise by a loose product name and
a rough date. Which records decide it (shipment dates, payments, refunds, the
shipped item) depends on what the text says, so a helper has to look things
up while it reads: the case for agents with a database service. About 30 %
of claims are contradicted by the records. Seeded.
"""

import datetime as dt
import json
import pathlib
import random
import sqlite3

BENCH = pathlib.Path(__file__).resolve().parent
FIXTURE = BENCH / "fixtures" / "claims"
ANSWERS = BENCH / "graders" / "claims_answers.json"
SPECS = BENCH / "graders" / "claims_specs.json"
BODIES = BENCH / "graders" / "claims_bodies.json"

SEED = 23
# Version 2 (Oct 11, 2026): a regex-and-SQL script decided 88.7 % of v1's
# claims. v2 adds what only reading settles: another order mentioned in
# passing, the problem described without its usual words, and exceptions
# the customer states (a gift sent elsewhere, damage they caused).
VERSION = 2
TODAY = dt.date(2026, 10, 1)
N_CUSTOMERS = 2000
N_CLAIMS = 300
TYPES = ["late", "defect", "duplicate", "wrong_item", "not_received"]

PRODUCTS = [
    ("Trail running shoes", "SHO-TR1", ["the running shoes", "my trainers", "the trail shoes"]),
    ("Linen shirt", "SHI-LN2", ["the linen shirt", "that shirt", "the summer shirt"]),
    ("Desk lamp", "LMP-DK3", ["the lamp", "my desk light", "the reading lamp"]),
    ("Rain jacket", "JKT-RN4", ["the rain jacket", "my raincoat", "the waterproof"]),
    ("Wool scarf", "SCF-WL5", ["the scarf", "the wool scarf", "that knitted scarf"]),
    ("Coffee grinder", "GRD-CF6", ["the grinder", "my coffee grinder", "the burr grinder"]),
    ("Backpack", "BAG-BP7", ["the backpack", "my rucksack", "the daypack"]),
    ("Yoga mat", "MAT-YG8", ["the yoga mat", "my mat", "the exercise mat"]),
    ("Water bottle", "BTL-WB9", ["the bottle", "my water bottle", "the flask"]),
    ("Headphones", "AUD-HP10", ["the headphones", "my headset", "the earphones"]),
    ("Cast iron pan", "PAN-CI11", ["the pan", "my skillet", "the cast iron"]),
    ("Bike light", "LGT-BK12", ["the bike light", "my front light", "the lamp for my bike"]),
]
STREETS = ["Linden Weg", "Harbour Rd", "Mill Lane", "Station St", "Oak Ave", "Kingsway", "Rue Haute",
           "Bergstraße", "Canal Walk", "Park Row"]
FIRST = ["Ana", "Ben", "Chloé", "Dev", "Eitan", "Fatima", "Grace", "Hiro", "Ines", "Jonas", "Kofi",
         "Lena", "Marta", "Nils", "Omar", "Priya", "Quinn", "Rosa", "Sven", "Tara", "Wei", "Yara"]
LAST = ["Andersen", "Brooks", "Costa", "Dubois", "Eriksen", "Fischer", "Garcia", "Haddad", "Ivanova",
        "Jensen", "Khan", "Larsen", "Moreau", "Nakamura", "Okafor", "Petrov", "Rossi", "Sato"]
PERSONAS = [
    "a busy parent on a phone, short sentences", "a small-business owner, brisk",
    "a retiree, polite, tells some backstory", "a student, casual, lowercase",
    "a non-native English speaker, simple phrasing", "an engineer, precise and detailed",
    "an angry long-time customer, sarcastic", "an apologetic first-time customer",
    "someone writing for an elderly relative", "a terse customer writing in fragments",
]


def iso(d):
    return d.isoformat()


def main():
    r = random.Random(SEED)
    customers = []
    for cid in range(1, N_CUSTOMERS + 1):
        name = f"{r.choice(FIRST)} {r.choice(LAST)}"
        addr = f"{r.randint(1, 140)} {r.choice(STREETS)}"
        customers.append((cid, name, f"c{cid}@example.com", addr))

    orders, shipments, payments, refunds = [], [], [], []
    oid = 300000
    by_customer = {}

    def add_order(cid, product, placed, *, promised_gap, delivered_gap, status="delivered",
                  addr=None, shipped_sku=None, double_pay=False, refunded=False):
        nonlocal oid
        oid += 1
        name, sku, _ = product
        amount = round(r.uniform(15, 260), 2)
        orders.append((oid, cid, iso(placed), name, sku, amount))
        promised = placed + dt.timedelta(days=promised_gap)
        delivered = placed + dt.timedelta(days=delivered_gap) if status == "delivered" else None
        shipments.append((oid, iso(promised), delivered and iso(delivered), status,
                          addr or customers[cid - 1][3], shipped_sku or sku))
        payments.append((oid, amount, iso(placed)))
        if double_pay:
            payments.append((oid, amount, iso(placed + dt.timedelta(minutes=0) )))
        if refunded:
            refunds.append((oid, round(amount * r.choice([0.5, 1.0]), 2), iso(placed + dt.timedelta(days=r.randint(5, 20)))))
        by_customer.setdefault(cid, []).append(oid)
        return oid

    # Background orders: most go fine, some with history.
    for cid in range(1, N_CUSTOMERS + 1):
        for _ in range(r.choice([0, 1, 2, 3, 4, 6])):
            placed = TODAY - dt.timedelta(days=r.randint(20, 400))
            add_order(cid, r.choice(PRODUCTS), placed, promised_gap=5, delivered_gap=r.randint(2, 5),
                      refunded=r.random() < 0.05)

    claim_customers = r.sample(range(1, N_CUSTOMERS + 1), N_CLAIMS)
    specs, answers = {}, {}
    cid_claim = 9000
    for cid in claim_customers:
        cid_claim += 1
        ctype = r.choice(TYPES)
        # The truth: approve 60 %, deny 30 % (records contradict), escalate 10 %.
        roll = r.random()
        truth = "approve" if roll < 0.6 else "deny" if roll < 0.9 else "escalate"
        owned = {orders[o - 300001][3] for o in by_customer.get(cid, [])}
        product = r.choice([p for p in PRODUCTS if p[0] not in owned] or PRODUCTS)
        placed = TODAY - dt.timedelta(days=r.randint(10, 60))
        kw = dict(promised_gap=5, delivered_gap=r.randint(2, 5))
        good = truth != "deny"
        if ctype == "late":
            kw["delivered_gap"] = r.randint(7, 14) if good else r.randint(2, 5)
        elif ctype == "defect":
            # Claim filed today: within 30 days of delivery, or not.
            placed = TODAY - dt.timedelta(days=r.randint(10, 30) if good else r.randint(40, 80))
        elif ctype == "duplicate":
            kw["double_pay"] = good
        elif ctype == "wrong_item":
            kw["shipped_sku"] = r.choice([p[1] for p in PRODUCTS if p != product]) if good else None
        elif ctype == "not_received":
            if good:
                if r.random() < 0.5:
                    kw.update(status=r.choice(["in_transit", "lost"]))
                else:
                    kw["addr"] = f"{r.randint(1, 140)} {r.choice(STREETS)} (neighbour)"
        kw["refunded"] = truth == "escalate"
        order = add_order(cid, product, placed, **kw)
        by_number = r.random() < 0.5
        # Another order of theirs, mentioned in passing (by number half the time).
        past = [o for o in by_customer.get(cid, []) if o != order]
        other = None
        if past and r.random() < 0.6:
            o = orders[r.choice(past) - 300001]
            other = f"order #{o[0]}" if r.random() < 0.5 else f"an earlier {o[3].lower()}"
        # Exceptions the customer states, which the records can't show.
        exception = None
        if truth == "approve" and ctype == "not_received" and kw.get("addr") and r.random() < 0.5:
            exception, truth = "gift", "deny"
        elif truth == "approve" and ctype == "defect" and r.random() < 0.25:
            exception, truth = "customer_caused", "deny"
        specs[str(cid_claim)] = {
            "type": ctype,
            "order_ref": f"order #{order}" if by_number else
            f"{r.choice(product[2])}, ordered around {(placed + dt.timedelta(days=r.randint(-3, 3))).strftime('%-d %B')}",
            "first_name": customers[cid - 1][1].split()[0],
            "persona": r.choice(PERSONAS),
            "length": r.choice([300, 450, 600, 750, 900]),
            "other_order": other,
            "indirect": r.random() < 0.5,
            "exception": exception,
        }
        answers[str(cid_claim)] = {"decision": truth, "type": ctype, "order": order, "customer": cid,
                                   "by_number": by_number, "exception": exception}

    SPECS.write_text(json.dumps(specs, indent=1, ensure_ascii=False) + "\n")
    bodies = json.loads(BODIES.read_text()) if BODIES.exists() else {}
    missing = [c for c in specs if c not in bodies]
    if missing:
        print(f"wrote {len(specs)} specs to {SPECS}; {len(missing)} bodies missing: run bench/write_claims.py")
        return

    FIXTURE.joinpath("data").mkdir(parents=True, exist_ok=True)
    db_path = FIXTURE / "data" / "shop.db"
    if db_path.exists():
        db_path.unlink()
    db = sqlite3.connect(db_path)
    db.executescript("""
        CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT, email TEXT, address TEXT);
        CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, placed_at TEXT, product TEXT,
                             sku TEXT, amount REAL);
        CREATE TABLE shipments (order_id INTEGER, promised_date TEXT, delivered_date TEXT, status TEXT,
                                delivered_address TEXT, shipped_sku TEXT);
        CREATE TABLE payments (order_id INTEGER, amount REAL, charged_at TEXT);
        CREATE TABLE refunds (order_id INTEGER, amount REAL, refunded_at TEXT);
        CREATE TABLE claims (id INTEGER PRIMARY KEY, customer_id INTEGER, created_at TEXT, body TEXT);
    """)
    db.executemany("INSERT INTO customers VALUES (?,?,?,?)", customers)
    db.executemany("INSERT INTO orders VALUES (?,?,?,?,?,?)", orders)
    db.executemany("INSERT INTO shipments VALUES (?,?,?,?,?,?)", shipments)
    db.executemany("INSERT INTO payments VALUES (?,?,?)", payments)
    db.executemany("INSERT INTO refunds VALUES (?,?,?)", refunds)
    db.executemany("INSERT INTO claims VALUES (?,?,?,?)",
                   [(int(c), a["customer"], iso(TODAY), bodies[c]) for c, a in answers.items()])
    db.commit()
    ANSWERS.write_text(json.dumps(answers, indent=1) + "\n")
    (FIXTURE / "policy.md").write_text(POLICY)
    counts = {d: sum(a["decision"] == d for a in answers.values()) for d in ("approve", "deny", "escalate")}
    print(f"{len(answers)} claims {counts} · {len(orders)} orders · "
          f"{sum(len(b) for b in bodies.values()):,} chars of claims")


POLICY = """# Refund claims policy

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
"""

if __name__ == "__main__":
    main()
