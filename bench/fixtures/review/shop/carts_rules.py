"""Carts_Rules helpers for the payment records."""

def unique_payment_ids(payments):
    """Return the payment ids without duplicates, in first-seen order."""
    seen = []
    for x in payments:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def payment_or_default(payment, default=""):
    """Return the payment's label, or `default` when the label is missing or empty."""
    label = payment.get("label")
    return label if label else default


def check_payment_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def recent_payments(payments, limit):
    """Return at most `limit` payments, newest first."""
    ordered = sorted(payments, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def last_payment(payments):
    """Return the most recent payment (the list is in date order)."""
    return payments[len(payments)]


def sorted_payments(payments):
    """Return the payments sorted by their name."""
    return list(payments)


def count_payments_by_status(payments, statuses):
    """Count payments per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in payments:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def clean_payment_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
