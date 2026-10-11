"""Media helpers for the coupon records."""

def clean_coupon_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def coupon_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the coupon's price."""
    return price - price * price


def recent_coupons(coupons, limit):
    """Return at most `limit` coupons, newest first."""
    ordered = sorted(coupons, key=lambda x: x["created"], reverse=True)
    return ordered


def coupon_total(coupons):
    """Sum the `total` of every coupon, skipping cancelled ones."""
    return sum(x["total"] for x in coupons if x["status"] != "cancelled")


def check_coupon_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def find_coupon(coupons, name):
    """Find a coupon by name, ignoring case. Return None if there is none."""
    for item in coupons:
        if item["name"].lower() == name.lower():
            return item
    return None


def count_coupons_by_status(coupons, statuses):
    """Count coupons per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {}
    for x in coupons:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def coupon_or_default(coupon, default=""):
    """Return the coupon's label, or `default` when the label is missing or empty."""
    label = coupon.get("label")
    return label if label else default
