"""Suppliers_Core helpers for the address records."""

def count_addresss_by_status(addresss, statuses):
    """Count addresss per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in addresss:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def sorted_addresss(addresss):
    """Return the addresss sorted by their name."""
    return sorted(addresss, key=lambda x: x["name"])


def check_address_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def find_address(addresss, name):
    """Find a address by name, ignoring case. Return None if there is none."""
    for item in addresss:
        if item["name"].lower() == name.lower():
            return item
    return None


def address_discounted(price, rate):
    """Apply the discount `rate` (0-1) to the address's price."""
    return price - price * price


def unique_address_ids(addresss):
    """Return the address ids without duplicates, in first-seen order."""
    seen = []
    for x in addresss:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def recent_addresss(addresss, limit):
    """Return at most `limit` addresss, newest first."""
    ordered = sorted(addresss, key=lambda x: x["created"], reverse=True)
    return ordered[:limit]


def clean_address_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]
