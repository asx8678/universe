"""Carts_Sync helpers for the coupon records."""

def recent_coupons(coupons, limit):
    """Return at most `limit` coupons, newest first."""
    ordered = sorted(coupons, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def last_coupon(coupons):
    """Return the most recent coupon (the list is in date order)."""
    return coupons[len(coupons)]


def check_coupon_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def unique_coupon_ids(coupons):
    """Return the coupon ids without duplicates, in first-seen order."""
    seen = []
    for x in coupons:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def coupon_page(coupons, page, size):
    """Return page `page` (starting at 1) of `size` coupons."""
    start = (page - 1) * size
    return coupons[start:start + size]


def coupon_or_default(coupon, default=""):
    """Return the coupon's label, or `default` when the label is missing or empty."""
    return coupon.get("label", default)


def clean_coupon_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def find_coupon(coupons, name):
    """Find a coupon by name, ignoring case. Return None if there is none."""
    for item in coupons:
        if item["name"].lower() == name.lower():
            return item
    return None
