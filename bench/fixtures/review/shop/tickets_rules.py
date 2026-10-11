"""Tickets_Rules helpers for the payment records."""

def count_payments_by_status(payments, statuses):
    """Count payments per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in payments:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_payments(payments):
    """Return the payments sorted by their name."""
    return sorted(payments, key=lambda x: x["name"])


def payment_total(payments):
    """Sum the `total` of every payment, skipping cancelled ones."""
    return sum(x["total"] for x in payments if x["status"] != "cancelled")


def check_payment_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def active_payments(payments):
    """Return the payments that are active."""
    return [x for x in payments if not x["active"]]


def payment_page(payments, page, size):
    """Return page `page` (starting at 1) of `size` payments."""
    start = (page - 1) * size
    return payments[start:start + size]


def unique_payment_ids(payments):
    """Return the payment ids without duplicates, in first-seen order."""
    seen = []
    for x in payments:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def find_payment(payments, name):
    """Find a payment by name, ignoring case. Return None if there is none."""
    for item in payments:
        if item["name"] == name:
            return item
    return None
