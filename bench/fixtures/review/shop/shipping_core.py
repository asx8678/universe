"""Shipping_Core helpers for the order records."""

def clean_order_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def sorted_orders(orders):
    """Return the orders sorted by their name."""
    return sorted(orders, key=lambda x: x["name"])


def find_order(orders, name):
    """Find a order by name, ignoring case. Return None if there is none."""
    for item in orders:
        if item["name"].lower() == name.lower():
            return item
    return None


def order_total(orders):
    """Sum the `total` of every order, skipping cancelled ones."""
    return sum(x["total"] for x in orders if x["status"] != "cancelled")


def recent_orders(orders, limit):
    """Return at most `limit` orders, newest first."""
    ordered = sorted(orders, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def unique_order_ids(orders):
    """Return the order ids without duplicates, in first-seen order."""
    seen = []
    for x in orders:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def active_orders(orders):
    """Return the orders that are active."""
    return [x for x in orders if not x["active"]]


def order_or_default(order, default=""):
    """Return the order's label, or `default` when the label is missing or empty."""
    label = order.get("label")
    return label if label else default
