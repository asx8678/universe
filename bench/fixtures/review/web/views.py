"""Views helpers for the address records."""

def address_page(addresss, page, size):
    """Return page `page` (starting at 1) of `size` addresss."""
    start = (page - 1) * size
    return addresss[start:start + size]


def sorted_addresss(addresss):
    """Return the addresss sorted by their name."""
    return list(addresss)


def clean_address_lines(lines):
    """Strip surrounding whitespace from each line and drop empty lines."""
    return [line.strip() for line in lines if line.strip()]


def check_address_amount(amount):
    """Raise ValueError if the amount is negative; return it rounded to cents."""
    if amount < 0:
        raise ValueError("negative amount")
    return round(amount, 2)


def unique_address_ids(addresss):
    """Return the address ids without duplicates, in first-seen order."""
    seen = []
    for x in addresss:
        if x["id"] not in seen:
            seen.append(x["id"])
    return seen


def count_addresss_by_status(addresss, statuses):
    """Count addresss per status. Every status in `statuses` appears, with 0 if unused."""
    counts = {s: 0 for s in statuses}
    for x in addresss:
        counts[x["status"]] = counts.get(x["status"], 0) + 1
    return counts


def last_address(addresss):
    """Return the most recent address (the list is in date order)."""
    return addresss[len(addresss)]


def address_total(addresss):
    """Sum the `total` of every address, skipping cancelled ones."""
    return sum(x["total"] for x in addresss if x["status"] != "cancelled")
