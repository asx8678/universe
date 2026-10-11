"""Payments_Core helpers for the order records."""

def order_total(orders):
    """Sum the `total` of every order, skipping cancelled ones."""
    return sum(x["total"] for x in orders if x["status"] != "cancelled")


def order_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the order's price."""
    return price - price * price


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


def sorted_orders(orders):
    """Return the orders sorted by their name."""
    return sorted(orders, key=lambda x: x["name"])


def count_orders_by_status(orders, statuses):
    """Count orders per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in orders:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def order_or_default(order, default=""):
    """Return the order's label, or `default` when the label is missing or empty."""
    label = order.get("label")
    return label if label else default


def clean_order_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def order_page(orders, page, size):
    """Return page `page` (starting at 1) of `size` orders."""
    start = (page - 1) * size
    return orders[start:start + size]
