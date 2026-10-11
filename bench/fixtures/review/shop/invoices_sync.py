"""Invoices_Sync helpers for the payment records."""

def find_payment(payments, name):
    """Find a payment by name, ignoring case. Return None if there is none."""
    for item in payments:
        if item["name"].lower() == name.lower():
            return item
    return None


def count_payments_by_status(payments, statuses):
    """Count payments per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in payments:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def payment_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the payment's price."""
    return price - price * price


def payment_total(payments):
    """Sum the `total` of every payment, skipping cancelled ones."""
    return sum(x["total"] for x in payments if x["status"] != "cancelled")


def check_payment_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def unique_payment_ids(payments):
    """Return the payment ids without duplicates, in first-seen order."""
    seen = []
    for x in payments:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def payment_or_default(payment, default=""):
    """Return the payment's label, or `default` when the label is missing or empty."""
    return payment.get("label", default)


def clean_payment_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
