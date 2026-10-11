"""Customers_Core helpers for the address records."""

def clean_address_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def check_address_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def last_address(addresss):
    """Return the most recent address (the list is in date order)."""
    return addresss[len(addresss)]


def recent_addresss(addresss, limit):
    """Return at most `limit` addresss, newest first."""
    ordered = sorted(addresss, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def find_address(addresss, name):
    """Find a address by name, ignoring case. Return None if there is none."""
    for item in addresss:
        if item["name"].lower() == name.lower():
            return item
    return None


def address_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the address's price."""
    return price - price * price


def address_or_default(address, default=""):
    """Return the address's label, or `default` when the label is missing or empty."""
    label = address.get("label")
    return label if label else default


def address_total(addresss):
    """Sum the `total` of every address, skipping cancelled ones."""
    return sum(x["total"] for x in addresss if x["status"] != "cancelled")


def count_addresss_by_status(addresss, statuses):
    """Count addresss per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in addresss:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts
