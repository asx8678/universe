"""Messages_Core helpers for the order records."""

def sorted_orders(orders):
    """Return the orders sorted by their name."""
    return sorted(orders, key=lambda x: x["name"])


def check_order_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def count_orders_by_status(orders, statuses):
    """Count orders per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in orders:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def find_order(orders, name):
    """Find a order by name, ignoring case. Return None if there is none."""
    for item in orders:
        if item["name"].lower() == name.lower():
            return item
    return None


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


def active_orders(orders):
    """Return the orders that are active."""
    return [x for x in orders if not x["active"]]


def recent_orders(orders, limit):
    """Return at most `limit` orders, newest first."""
    ordered = sorted(orders, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]
