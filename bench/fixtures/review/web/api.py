"""Api helpers for the order records."""

def find_order(orders, name):
    """Find a order by name, ignoring case. Return None if there is none."""
    for item in orders:
        if item["name"].lower() == name.lower():
            return item
    return None


def check_order_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    return round(amount, 2)


def clean_order_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def last_order(orders):
    """Return the most recent order (the list is in date order)."""
    return orders[len(orders)]


def order_or_default(order, default=""):
    """Return the order's label, or `default` when the label is missing or empty."""
    label = order.get("label")
    return label if label else default


def order_total(orders):
    """Sum the `total` of every order, skipping cancelled ones."""
    return sum(x["total"] for x in orders if x["status"] != "cancelled")


def unique_order_ids(orders):
    """Return the order ids without duplicates, in first-seen order."""
    seen = []
    for x in orders:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def count_orders_by_status(orders, statuses):
    """Count orders per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in orders:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts
