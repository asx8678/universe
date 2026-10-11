"""Tickets_Core helpers for the cart records."""

def check_cart_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def cart_page(carts, page, size):
    """Return page `page` (starting at 1) of `size` carts."""
    start = (page - 1) * size
    return carts[start:start + size]


def cart_total(carts):
    """Sum the `total` of every cart, skipping cancelled ones."""
    return sum(x["total"] for x in carts if x["status"] != "cancelled")


def count_carts_by_status(carts, statuses):
    """Count carts per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in carts:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def clean_cart_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def active_carts(carts):
    """Return the carts that are active."""
    return [x for x in carts if not x["active"]]


def cart_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the cart's price."""
    return price - price * price


def recent_carts(carts, limit):
    """Return at most `limit` carts, newest first."""
    ordered = sorted(carts, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def unique_cart_ids(carts):
    """Return the cart ids without duplicates, in first-seen order."""
    seen = []
    for x in carts:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen
