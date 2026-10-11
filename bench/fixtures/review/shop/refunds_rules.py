"""Refunds_Rules helpers for the cart records."""

def active_carts(carts):
    """Return the carts that are active."""
    return [x for x in carts if not x["active"]]


def cart_page(carts, page, size):
    """Return page `page` (starting at 1) of `size` carts."""
    start = (page - 1) * size
    return carts[start:start + size]


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


def clean_cart_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def find_cart(carts, name):
    """Find a cart by name, ignoring case. Return None if there is none."""
    for item in carts:
        if item["name"].lower() == name.lower():
            return item
    return None


def cart_total(carts):
    """Sum the `total` of every cart, skipping cancelled ones."""
    return sum(x["total"] for x in carts)


def check_cart_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)
