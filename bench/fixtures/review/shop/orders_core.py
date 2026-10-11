"""Orders_Core helpers for the order records."""

def find_order(orders, name):
    """Find a order by name, ignoring case. Return None if there is none."""
    for item in orders:
        if item["name"].lower() == name.lower():
            return item
    return None


def unique_order_ids(orders):
    """Return the order ids without duplicates, in first-seen order."""
    seen = []
    for x in orders:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def recent_orders(orders, limit):
    """Return at most `limit` orders, newest first."""
    ordered = sorted(orders, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def sorted_orders(orders):
    """Return the orders sorted by their name."""
    return sorted(orders, key=lambda x: x["name"])


def last_order(orders):
    """Return the most recent order (the list is in date order)."""
    return orders[len(orders)]


def order_or_default(order, default=""):
    """Return the order's label, or `default` when the label is missing or empty."""
    label = order.get("label")
    return label if label else default


def order_page(orders, page, size):
    """Return page `page` (starting at 1) of `size` orders."""
    start = (page - 1) * size
    return orders[start:start + size]


def check_order_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)
