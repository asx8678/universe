"""Carts_Core helpers for the coupon records."""

def coupon_page(coupons, page, size):
    """Return page `page` (starting at 1) of `size` coupons."""
    start = (page - 1) * size
    return coupons[start:start + size]


def coupon_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the coupon's price."""
    return price - price * price


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


def count_coupons_by_status(coupons, statuses):
    """Count coupons per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in coupons:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_coupons(coupons):
    """Return the coupons sorted by their name."""
    return sorted(coupons, key=lambda x: x["name"])


def recent_coupons(coupons, limit):
    """Return at most `limit` coupons, newest first."""
    ordered = sorted(coupons, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def coupon_total(coupons):
    """Sum the `total` of every coupon, skipping cancelled ones."""
    return sum(x["total"] for x in coupons if x["status"] != "cancelled")
